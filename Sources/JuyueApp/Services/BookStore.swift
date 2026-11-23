import Foundation
import CoreGraphics
import ImageIO
import ZIPFoundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#if canImport(JuyueCore)
import JuyueCore
#endif

public class BookStore: ObservableObject {
    public static let shared = BookStore()

    @Published public var bookshelf: [Book] = []
    @Published public var sources: [BookSource] = []
    @Published public var textReplaceRulesMap: [String: [TextReplaceRule]] = [:]
    @Published public var bookmarks: [BookBookmark] = []
    @Published public var groups: [BookGroup] = []

    private enum Keys {
        static let books = "juyue_bookshelf_v1"
        static let sources = "juyue_sources_v1"
        static let bookmarks = "juyue_bookmarks_v1"
        static let groups = "juyue_book_groups_v1"
        static let replaceRules = "juyue_text_replace_v1"
    }

    private var pendingRespondTimeWrite: DispatchWorkItem?
    private var chapterMemory: [String: [BookChapter]] = [:]
    /// 阅读进度这种高频改动走防抖；结构变化（增删书、换源、导入）仍然立刻写。
    private let shelfWriter = DebouncedPersistenceWriter<[Book]>(
        queue: DispatchQueue(label: "juyue.bookshelf.persist", qos: .utility),
        encode: { books in try? JSONEncoder().encode(books) },
        sink: { data in Persisted.writeData(data, key: Keys.books) }
    )

    public init() {
        JuyueStorageMigration.runIfNeeded()
        reloadPersistedState()
        installJSEngineSinks()
        installSearchTimingSink()
    }

    // MARK: - 启动

    private func reloadPersistedState() {
        if let stored = loadWithRescue([BookSource].self, key: Keys.sources) {
            sources = stored
        }
        // 内置源每次都参与同步：本地为空整批灌入，非空只刷新规则，登录态由合并函数保住。
        loadBundledSources()
        if let stored = loadWithRescue([Book].self, key: Keys.books) {
            bookshelf = stored
        }
        if let stored = loadWithRescue([BookBookmark].self, key: Keys.bookmarks) {
            bookmarks = stored
        }
        if let stored = loadWithRescue([BookGroup].self, key: Keys.groups) {
            groups = stored
        }
        if let stored = loadWithRescue([String: [TextReplaceRule]].self, key: Keys.replaceRules) {
            textReplaceRulesMap = stored
        }
    }

    /// Legado / Juyue 两套构建线的键名前缀不同。覆盖安装换了线，本线键名是空的，
    /// 数据其实还在另一套键名下面，这里按镜像键名再找一遍并写回本线。
    fileprivate static func mirroredKey(_ key: String) -> String? {
        for prefix in ["juyue_", "legado_"] where key.hasPrefix(prefix) {
            let other = prefix == "juyue_" ? "legado_" : "juyue_"
            return other + key.dropFirst(prefix.count)
        }
        return nil
    }

    private func loadWithRescue<T: Codable & Collection>(_ type: T.Type, key: String) -> T? {
        // 本键名解不出来但又确实有字节：先原样留一份，别让后面的写入把旧数据冲掉。
        if let raw = UserDefaults.standard.data(forKey: key),
           Persisted.read(type, key: key) == nil {
            let backupKey = key + ".unreadable"
            if UserDefaults.standard.data(forKey: backupKey) == nil {
                UserDefaults.standard.set(raw, forKey: backupKey)
                AppLog.write("[存储] \(key) 无法解析，已备份到 \(backupKey)")
            }
        }
        if let direct = Persisted.read(type, key: key), !direct.isEmpty {
            return direct
        }
        if let mirror = Self.mirroredKey(key),
           let rescued = Persisted.read(type, key: mirror),
           !rescued.isEmpty {
            Persisted.write(rescued, key: key)
            AppLog.write("[存储] 本线键名 \(key) 为空，已从 \(mirror) 恢复")
            return rescued
        }
        return Persisted.read(type, key: key)
    }

    private func installJSEngineSinks() {
        // 脚本用 source.setVariable 存的状态要落盘，否则聚合源的「切换服务器」每轮都从头算。
        JSEngine.variableSink = { sourceURL, variable in
            guard !sourceURL.isEmpty else { return }
            DispatchQueue.main.async {
                let store = BookStore.shared
                guard let index = store.sources.firstIndex(where: { $0.bookSourceUrl == sourceURL }) else { return }
                guard store.sources[index].variable != variable else { return }
                store.sources[index].variable = variable
                store.persistSources()
            }
        }

        // 脚本改写当前这本书的 variable / 替换开关时，也要写回书架。
        JSEngine.bookUpdateSink = { changed in
            guard !changed.bookUrl.isEmpty else { return }
            DispatchQueue.main.async {
                let store = BookStore.shared
                guard let index = store.bookshelf.firstIndex(where: { $0.bookUrl == changed.bookUrl }) else { return }
                let current = store.bookshelf[index]
                guard current.variable != changed.variable || current.useReplaceRule != changed.useReplaceRule else { return }
                store.bookshelf[index].variable = changed.variable
                store.bookshelf[index].useReplaceRule = changed.useReplaceRule
                store.persistShelf()
            }
        }
    }

    private func installSearchTimingSink() {
        BookSearchService.respondTimeSink = { sourceURL, milliseconds in
            guard !sourceURL.isEmpty, milliseconds > 0 else { return }
            DispatchQueue.main.async {
                let store = BookStore.shared
                guard let index = store.sources.firstIndex(where: { $0.bookSourceUrl == sourceURL }) else { return }
                if let previous = store.sources[index].respondTime, abs(previous - milliseconds) < 50 {
                    return
                }
                store.sources[index].respondTime = milliseconds
                store.scheduleRespondTimeFlush()
            }
        }
    }

    private func scheduleRespondTimeFlush() {
        pendingRespondTimeWrite?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.persistSources() }
        pendingRespondTimeWrite = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }

    // MARK: - 书签与标注

    public func bookmarks(for bookUrl: String) -> [BookBookmark] {
        bookmarks
            .filter { $0.bookUrl == bookUrl }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func addBookmark(_ bookmark: BookBookmark) {
        bookmarks.append(bookmark)
        persistBookmarks()
    }

    public func removeBookmark(_ bookmark: BookBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        persistBookmarks()
    }

    public func updateBookmarkNote(id: UUID, note: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].note = note
        persistBookmarks()
    }

    @discardableResult
    public func toggleAnnotation(
        bookUrl: String,
        chapterIndex: Int,
        chapterTitle: String,
        blockId: Int,
        charOffset: Int = 0,
        length: Int,
        kind: BookBookmark.Kind,
        color: String? = nil,
        snippet: String = "",
        charScoped: Bool = false,
        forceRemove: Bool = false
    ) -> Bool {
        if forceRemove {
            return removeMatchingAnnotation(
                bookUrl: bookUrl,
                chapterIndex: chapterIndex,
                blockId: blockId,
                kind: kind,
                charOffset: charScoped ? charOffset : nil,
                length: charScoped ? length : nil
            )
        }

        let scope: AnnotationScope = charScoped
            ? .characters(offset: charOffset, length: length)
            : .paragraph

        if let existing = bookmarks.firstIndex(where: {
            annotationMatches($0, bookUrl: bookUrl, chapterIndex: chapterIndex, blockId: blockId, kind: kind, scope: scope)
        }) {
            let activeColor = bookmarks[existing].color ?? defaultAnnotationColor(for: kind)
            let tappingSameColor = activeColor == color
            bookmarks.remove(at: existing)
            if tappingSameColor {
                persistBookmarks()
                return false
            }
        }

        if !charScoped {
            // 同一段只保留一种样式，避免下划线和底色互相覆盖。
            bookmarks.removeAll {
                $0.bookUrl == bookUrl && $0.chapterIndex == chapterIndex
                    && $0.blockId == blockId && $0.kind != .bookmark
                    && $0.rangeUnitRaw == nil
            }
        }

        let fresh = BookBookmark(
            bookUrl: bookUrl,
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            charOffset: charOffset,
            snippet: String(snippet.prefix(60)),
            blockId: blockId,
            length: length,
            color: color,
            rangeUnit: charScoped ? "char" : nil,
            kind: kind
        )
        bookmarks.append(fresh)
        persistBookmarks()
        return true
    }

    public func replaceAnnotations(_ items: [BookBookmark], bookUrl: String, chapterIndex: Int) {
        bookmarks.removeAll {
            $0.bookUrl == bookUrl && $0.chapterIndex == chapterIndex && $0.kind != .bookmark
        }
        bookmarks.append(contentsOf: items)
        persistBookmarks()
    }

    public func annotations(bookUrl: String, chapterIndex: Int) -> [Int: BookBookmark] {
        var result: [Int: BookBookmark] = [:]
        for item in bookmarks
        where item.bookUrl == bookUrl
            && item.chapterIndex == chapterIndex
            && item.kind != .bookmark
            && item.rangeUnitRaw == nil {
            if let block = item.blockId {
                result[block] = item
            }
        }
        return result
    }

    public func userAnnotations(bookUrl: String, chapterIndex: Int) -> [BookBookmark] {
        bookmarks.filter {
            $0.bookUrl == bookUrl && $0.chapterIndex == chapterIndex && $0.kind != .bookmark
        }
    }

    public func annotationsOverlapping(
        bookUrl: String,
        chapterIndex: Int,
        blockId: Int,
        charStart: Int? = nil,
        charLength: Int? = nil
    ) -> [BookBookmark] {
        bookmarks.filter { item in
            guard item.bookUrl == bookUrl,
                  item.chapterIndex == chapterIndex,
                  item.blockId == blockId,
                  item.kind != .bookmark else { return false }
            return annotationOverlaps(item, charStart: charStart, charLength: charLength)
        }
    }

    @discardableResult
    public func removeAnnotations(
        bookUrl: String,
        chapterIndex: Int,
        blockId: Int,
        charStart: Int? = nil,
        charLength: Int? = nil
    ) -> Int {
        let before = bookmarks.count
        bookmarks.removeAll { item in
            guard item.bookUrl == bookUrl,
                  item.chapterIndex == chapterIndex,
                  item.blockId == blockId,
                  item.kind != .bookmark else { return false }
            return annotationOverlaps(item, charStart: charStart, charLength: charLength)
        }
        let removed = before - bookmarks.count
        if removed > 0 { persistBookmarks() }
        return removed
    }

    private enum AnnotationScope {
        case paragraph
        case characters(offset: Int, length: Int)
    }

    private func annotationMatches(
        _ item: BookBookmark,
        bookUrl: String,
        chapterIndex: Int,
        blockId: Int,
        kind: BookBookmark.Kind,
        scope: AnnotationScope
    ) -> Bool {
        guard item.bookUrl == bookUrl,
              item.chapterIndex == chapterIndex,
              item.blockId == blockId,
              item.kind == kind else { return false }

        switch scope {
        case .paragraph:
            return item.rangeUnitRaw == nil
        case .characters(let offset, let length):
            return item.rangeUnitRaw == "char"
                && item.charOffset == offset
                && item.length == length
        }
    }

    private func removeMatchingAnnotation(
        bookUrl: String,
        chapterIndex: Int,
        blockId: Int,
        kind: BookBookmark.Kind,
        charOffset: Int?,
        length: Int?
    ) -> Bool {
        let before = bookmarks.count
        bookmarks.removeAll { item in
            guard item.bookUrl == bookUrl,
                  item.chapterIndex == chapterIndex,
                  item.blockId == blockId,
                  item.kind == kind else { return false }
            guard let charOffset, let length else {
                return item.rangeUnitRaw == nil
            }
            return item.rangeUnitRaw == "char"
                && item.charOffset == charOffset
                && item.length == length
        }
        if bookmarks.count != before { persistBookmarks() }
        return false
    }

    private func defaultAnnotationColor(for kind: BookBookmark.Kind) -> String {
        kind == .underline ? "#2F7BF6" : "#FFF59D"
    }

    private func annotationOverlaps(_ item: BookBookmark, charStart: Int?, charLength: Int?) -> Bool {
        guard let charStart, let charLength else { return true }
        guard item.rangeUnitRaw == "char" else { return true }
        let lower = item.charOffset
        let upper = item.charOffset + max(1, item.length ?? 1)
        return lower < charStart + max(1, charLength) && charStart < upper
    }

    private func persistBookmarks() {
        Persisted.write(bookmarks, key: Keys.bookmarks)
    }

    // MARK: - 正文替换

    public func textReplaceRules(bookUrl: String) -> [TextReplaceRule] {
        textReplaceRulesMap[bookUrl] ?? []
    }

    public func addTextReplaceRule(bookUrl: String, from: String, to: String) {
        let needle = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }

        var current = textReplaceRulesMap[bookUrl] ?? []
        current.removeAll { $0.from == needle }
        current.append(TextReplaceRule(from: needle, to: to))
        textReplaceRulesMap[bookUrl] = current
        persistTextReplaceRules()
    }

    public func clearTextReplaceRules(bookUrl: String) {
        textReplaceRulesMap[bookUrl] = nil
        persistTextReplaceRules()
    }

    private func persistTextReplaceRules() {
        Persisted.write(textReplaceRulesMap, key: Keys.replaceRules)
    }

    // MARK: - 分组

    @discardableResult
    public func addGroup(name: String) -> BookGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = BookGroup(name: trimmed.isEmpty ? "新分组" : trimmed)
        groups.append(group)
        persistGroups()
        return group
    }

    public func renameGroup(id: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        groups[index].name = trimmed
        persistGroups()
    }

    public func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        persistGroups()

        for index in bookshelf.indices where bookshelf[index].groupId == id {
            bookshelf[index].groupId = nil
        }
        persistShelf()
    }

    public func assign(_ book: Book, toGroup groupId: UUID?) {
        guard let index = bookshelf.firstIndex(where: { $0.bookUrl == book.bookUrl }) else { return }
        bookshelf[index].groupId = groupId
        persistShelf()
    }

    public func books(inGroup groupId: UUID?) -> [Book] {
        guard let groupId else { return bookshelf }
        return bookshelf.filter { $0.groupId == groupId }
    }

    private func persistGroups() {
        Persisted.write(groups, key: Keys.groups)
    }

    // MARK: - 磁盘与内置源

    private var documentsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private var bundledSourcesFile: URL? {
        #if SWIFT_PACKAGE
        if let resource = Bundle.module.url(forResource: "bookSources", withExtension: "json") {
            return resource
        }
        #endif
        return Bundle.main.url(forResource: "bookSources", withExtension: "json")
    }

    public func loadData() {
        sources = Persisted.read([BookSource].self, key: Keys.sources) ?? sources
        mergeBundledSources(forceReset: false)
        bookshelf = Persisted.read([Book].self, key: Keys.books) ?? bookshelf
    }

    public func loadBundledSources(forceReset: Bool = false) {
        mergeBundledSources(forceReset: forceReset)
    }

    private func mergeBundledSources(forceReset: Bool) {
        guard let bundled = decodedBundledSources() else { return }

        let replaceEverything = forceReset || sources.isEmpty
        if replaceEverything {
            sources = bundled
            persistSources()
            return
        }

        var indexByURL: [String: Int] = [:]
        var indexByName: [String: Int] = [:]
        for (offset, item) in sources.enumerated() {
            indexByURL[item.bookSourceUrl] = offset
            indexByName[item.bookSourceName] = offset
        }

        for incoming in bundled {
            // 先认 URL，再认书名：书源换域名时仍能把本地登录态接回来。
            let matched = indexByURL[incoming.bookSourceUrl] ?? indexByName[incoming.bookSourceName]
            if let matched {
                sources[matched] = mergingUserState(from: sources[matched], into: incoming)
            } else {
                sources.append(incoming)
            }
            let offset = matched ?? (sources.count - 1)
            indexByURL[incoming.bookSourceUrl] = offset
            indexByName[incoming.bookSourceName] = offset
        }
        persistSources()
    }

    private func decodedBundledSources() -> [BookSource]? {
        guard let file = bundledSourcesFile,
              let raw = try? Data(contentsOf: file) else {
            return .none
        }
        return try? JSONDecoder().decode([BookSource].self, from: raw)
    }

    private func mergingUserState(from local: BookSource, into fresh: BookSource) -> BookSource {
        var merged = fresh
        merged.loginHeader = local.loginHeader
        merged.loginInfo = local.loginInfo
        if let order = local.customOrder {
            merged.customOrder = order
        }
        if let enabled = local.enabled {
            merged.enabled = enabled
        }
        return merged
    }

    public func saveSources() { persistSources() }
    public func saveBookshelf() { persistShelf() }

    private func persistSources() { Persisted.write(sources, key: Keys.sources) }

    /// 结构变化（增删书、换源、导入、恢复）立刻写盘，并作废挂起的旧快照。
    private func persistShelf() { shelfWriter.writeNow(bookshelf) }

    /// 阅读进度这类高频变化只标脏，静默 0.8 秒后合并写一次。
    private func scheduleShelfPersist() { shelfWriter.schedule(bookshelf, delay: 0.8) }

    /// 进后台 / 退出阅读 / 退出 App：把还没落盘的进度立刻写完。
    public func flushShelf() { shelfWriter.flush() }

    // MARK: - WebDAV 恢复

    public enum RestoreMode {
        case merge
        case replace
    }

    public func restoreFromWebDAV(
        books: [Book]?,
        sources: [BookSource]?,
        mode: RestoreMode = .merge
    ) -> (booksAdded: Int, sourcesAdded: Int) {
        var newBooks = 0
        var newSources = 0

        if let backupBooks = books {
            for backup in backupBooks {
                guard let index = bookshelf.firstIndex(where: { $0.bookUrl == backup.bookUrl }) else {
                    bookshelf.append(backup)
                    newBooks += 1
                    continue
                }
                switch mode {
                case .replace:
                    bookshelf[index] = backup
                case .merge:
                    bookshelf[index] = mergingProgress(from: backup, over: bookshelf[index])
                }
            }
            persistShelf()
        }

        if let admitted = BookSourceGate.admitted(sources, appStore: AppEdition.isAppStoreClean) {
            var indexByURL: [String: Int] = [:]
            for (offset, local) in self.sources.enumerated() {
                indexByURL[local.bookSourceUrl] = offset
            }
            for incoming in admitted {
                if let offset = indexByURL[incoming.bookSourceUrl] {
                    self.sources[offset] = incoming
                } else {
                    self.sources.append(incoming)
                    indexByURL[incoming.bookSourceUrl] = self.sources.count - 1
                    newSources += 1
                }
            }
            persistSources()
        }

        return (newBooks, newSources)
    }

    /// 离线包导入：书与目录落地，正文/书评/封面已由 OfflineBookShare 写回缓存
    @discardableResult
    public func importOfflineBook(_ book: Book, chapters: [BookChapter]) -> Bool {
        var incoming = book
        incoming.origin = "local"
        incoming.totalChapterNum = chapters.count

        if let index = bookshelf.firstIndex(where: { $0.bookUrl == incoming.bookUrl }) {
            bookshelf[index] = mergingProgress(from: incoming, over: bookshelf[index])
            bookshelf[index].totalChapterNum = chapters.count
        } else {
            bookshelf.append(incoming)
        }
        // 本地书的目录键就是 bookUrl，阅读页打开时直接用这份，不必联网
        saveChapters(chapters, for: incoming.bookUrl)
        persistShelf()
        return true
    }

    private func mergingProgress(from backup: Book, over local: Book) -> Book {
        var result = backup
        if local.durChapterTime > result.durChapterTime {
            result.durChapterIndex = local.durChapterIndex
            result.durChapterTitle = local.durChapterTitle
            result.durChapterPos = local.durChapterPos
            result.durChapterTime = local.durChapterTime
        }
        if result.groupId == nil {
            result.groupId = local.groupId
        }
        if (result.coverUrl ?? "").isEmpty {
            result.coverUrl = local.coverUrl
        }
        return result
    }

    // MARK: - 书架

    public func addBook(from searchResult: SearchBook) -> Book {
        if let duplicate = bookshelf.first(where: { $0.bookUrl == searchResult.bookUrl }) {
            AppLog.write("[书架] 加入网络书：已存在")
            return duplicate
        }

        let fresh = networkBook(from: searchResult)
        bookshelf.insert(fresh, at: 0)
        persistShelf()
        AppLog.write("[书架] 加入网络书：新增")
        return fresh
    }

    private func networkBook(from result: SearchBook) -> Book {
        Book(
            bookUrl: result.bookUrl,
            name: result.name,
            author: result.author,
            kind: result.kind,
            coverUrl: result.coverUrl,
            intro: result.intro,
            origin: result.origin,
            originName: result.originName,
            latestChapterTitle: result.latestChapterTitle
        )
    }

    private func insertAtFront(_ book: Book) {
        bookshelf.insert(book, at: 0)
        persistShelf()
    }

    private func insertOrReplace(_ book: Book) {
        if let index = bookshelf.firstIndex(where: { $0.bookUrl == book.bookUrl }) {
            bookshelf[index] = book
            persistShelf()
        } else {
            insertAtFront(book)
        }
    }

    @discardableResult public func saveOrUpdateBook(_ book: Book, overwriteCover: Bool = false) -> Book {
        guard let index = bookshelf.firstIndex(where: { $0.bookUrl == book.bookUrl }) else {
            insertAtFront(book)
            return book
        }
        bookshelf[index] = mergingDetailFields(of: book, into: bookshelf[index], overwriteCover: overwriteCover)
        persistShelf()
        return bookshelf[index]
    }

    private func mergingDetailFields(of incoming: Book, into local: Book, overwriteCover: Bool) -> Book {
        var merged = local

        if !incoming.name.isEmpty {
            merged.name = incoming.name
        }
        if !incoming.author.isEmpty, incoming.author != "未知作者" {
            merged.author = incoming.author
        }
        if overwriteCover {
            merged.coverUrl = incoming.coverUrl
        } else if let cover = incoming.coverUrl, !cover.isEmpty {
            merged.coverUrl = cover
        }
        if let intro = incoming.intro, !intro.isEmpty, !intro.hasPrefix("源站：") {
            merged.intro = intro
        }
        if let kind = incoming.kind, !kind.isEmpty {
            merged.kind = kind
        }
        if let words = incoming.wordCount, !words.isEmpty {
            merged.wordCount = words
        }
        if let latest = incoming.latestChapterTitle, !latest.isEmpty {
            merged.latestChapterTitle = latest
        }
        if incoming.totalChapterNum > 0 {
            merged.totalChapterNum = incoming.totalChapterNum
        }
        return merged
    }

    public func removeBook(bookUrl: String) {
        AppLog.write("[书架] 删除书籍")
        bookshelf = bookshelf.filter { $0.bookUrl != bookUrl }
        persistShelf()
    }

    @discardableResult
    public func changeBookSource(from oldBook: Book, to newBook: Book) -> Book {
        AppLog.write("[书架] 更换书源")
        var target = newBook

        target.durChapterIndex = oldBook.durChapterIndex
        target.durChapterTitle = oldBook.durChapterTitle
        target.durChapterPos = oldBook.durChapterPos
        target.durChapterTime = oldBook.durChapterTime
        target.groupId = oldBook.groupId
        if (target.coverUrl ?? "").isEmpty, let cover = oldBook.coverUrl, !cover.isEmpty {
            target.coverUrl = cover
        }

        if target.bookUrl != oldBook.bookUrl {
            // 目录地址属于旧源：沿用它会让换源后的目录和正文继续从旧站抓。
            if target.tocUrl == oldBook.tocUrl {
                target.tocUrl = ""
            }
            target.totalChapterNum = 0
        }

        guard let oldIndex = bookshelf.firstIndex(where: { $0.bookUrl == oldBook.bookUrl }) else {
            // 未上架的书换源只用于阅读，不能被顺带写进书架。
            if target.bookUrl != oldBook.bookUrl {
                discardChapterCache(for: oldBook.bookUrl)
            }
            return target
        }

        if target.bookUrl != oldBook.bookUrl {
            bookshelf.remove(at: oldIndex)
            discardChapterCache(for: oldBook.bookUrl)
        }

        if let index = bookshelf.firstIndex(where: { $0.bookUrl == target.bookUrl }) {
            bookshelf[index] = target
        } else {
            // 旧书在书架时放回它原来的位置，别因为换源就顶到最前面。
            bookshelf.insert(target, at: min(oldIndex, bookshelf.count))
        }
        persistShelf()
        return target
    }

    public func updateProgress(bookUrl: String, chapterIndex: Int, chapterTitle: String, chapterPos: Int = 0) {
        guard let index = bookshelf.firstIndex(where: { $0.bookUrl == bookUrl }) else { return }

        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        bookshelf[index].durChapterIndex = chapterIndex
        bookshelf[index].durChapterPos = chapterPos
        bookshelf[index].durChapterTitle = chapterTitle
        bookshelf[index].durChapterTime = stamp
        bookshelf[index].lastCheckTime = stamp
        scheduleShelfPersist()

        // 本地进度已经写盘；WebDAV 只是副本，没配就跳过，失败也不回滚。
        let snapshot = bookshelf[index]
        let config = WebDAVService.shared.loadConfig()
        guard !config.url.isEmpty, !config.username.isEmpty else { return }
        Task {
            try? await WebDAVService.shared.uploadBookProgress(book: snapshot, config: config)
        }
    }

    public func refreshAllBooks() async {
        let online = bookshelf.filter { $0.origin != "local" }
        guard !online.isEmpty else { return }
        AppLog.write("[Bookshelf] 开始整架刷新，网络书 \(online.count) 本")

        await withTaskGroup(of: Optional<Book>.self) { group in
            for book in online {
                group.addTask { await self.reloadDetail(for: book) }
            }
            for await detail in group {
                guard let detail else { continue }
                await MainActor.run { _ = self.saveOrUpdateBook(detail) }
            }
        }
        AppLog.write("[Bookshelf] ✅ 整架刷新完成")
    }

    private func reloadDetail(for book: Book) async -> Book? {
        guard let source = findSource(for: book) else { return nil }
        do {
            let (detail, chapters) = try await BookContentService.shared.fetchBookDetail(book: book, source: source)
            var refreshed = detail
            refreshed.totalChapterNum = chapters.count
            if let final = chapters.last {
                refreshed.latestChapterTitle = final.title
            }
            if !chapters.isEmpty {
                saveChapters(chapters, for: book.bookUrl)
            }
            return refreshed
        } catch {
            let tag = String(CryptoUtils.md5(book.name).prefix(8))
            AppLog.write("[Bookshelf] ⚠️ 刷新失败 book#\(tag): \(error.localizedDescription)")
            return .none
        }
    }

    // MARK: - 书源导入

    public struct SourceImportEntry: Identifiable {
        public enum Status: String {
            case new = "新增"
            case update = "更新"
            case conflict = "同名冲突"
        }

        public var id: String { incoming.bookSourceUrl + "|" + (existing?.bookSourceUrl ?? "") }
        public let incoming: BookSource
        public let existing: BookSource?
        public let status: Status
    }

    public func planImportSources(json: String) throws -> [SourceImportEntry] {
        guard let data = json.data(using: .utf8) else { return [] }
        let incomingList = try BookSource.decodeList(from: data)

        var seen = Set<String>()
        var plan: [SourceImportEntry] = []

        for incoming in incomingList where !incoming.bookSourceUrl.isEmpty {
            guard seen.insert(incoming.bookSourceUrl).inserted else { continue }

            if let sameURL = sources.first(where: { $0.bookSourceUrl == incoming.bookSourceUrl }) {
                plan.append(SourceImportEntry(incoming: incoming, existing: sameURL, status: .update))
            } else if let sameName = sources.first(where: { $0.bookSourceName == incoming.bookSourceName }) {
                plan.append(SourceImportEntry(incoming: incoming, existing: sameName, status: .conflict))
            } else {
                plan.append(SourceImportEntry(incoming: incoming, existing: nil, status: .new))
            }
        }
        return plan
    }

    @discardableResult
    public func applyImport(
        entries: [BookStore.SourceImportEntry],
        overwriteConflicts: Bool
    ) -> (added: Int, updated: Int, conflictsAdded: Int) {
        var added = 0
        var updated = 0
        var conflicts = 0

        for entry in entries {
            switch entry.status {
            case .new:
                if !sources.contains(where: { $0.bookSourceUrl == entry.incoming.bookSourceUrl }) {
                    sources.append(entry.incoming)
                    added += 1
                }

            case .update:
                if let index = sources.firstIndex(where: { $0.bookSourceUrl == entry.incoming.bookSourceUrl }) {
                    sources[index] = entry.incoming
                    updated += 1
                }

            case .conflict:
                if overwriteConflicts,
                   let index = sources.firstIndex(where: {
                       $0.bookSourceUrl == entry.existing?.bookSourceUrl
                           || $0.bookSourceName == entry.incoming.bookSourceName
                   }) {
                    sources[index] = entry.incoming
                    updated += 1
                } else if !sources.contains(where: { $0.bookSourceUrl == entry.incoming.bookSourceUrl }) {
                    var incoming = entry.incoming
                    if let existingName = entry.existing?.bookSourceName,
                       existingName == incoming.bookSourceName {
                        incoming.bookSourceName += "（导入）"
                    }
                    sources.append(incoming)
                    conflicts += 1
                }
            }
        }

        if added + updated + conflicts > 0 {
            persistSources()
        }
        return (added, updated, conflicts)
    }

    public func importSources(json: String) throws -> Int {
        guard let data = json.data(using: .utf8) else { return 0 }
        let incomingList = try BookSource.decodeList(from: data)

        var byURL: [String: Int] = [:]
        var byName: [String: Int] = [:]
        for (offset, local) in sources.enumerated() {
            byURL[local.bookSourceUrl] = offset
            byName[local.bookSourceName] = offset
        }

        for incoming in incomingList {
            // 同名换域名的源按书名认领，避免导入后出现两条同名条目。
            if let matched = byURL[incoming.bookSourceUrl] ?? byName[incoming.bookSourceName] {
                sources[matched] = incoming
                byURL[incoming.bookSourceUrl] = matched
                byName[incoming.bookSourceName] = matched
            } else {
                sources.append(incoming)
                byURL[incoming.bookSourceUrl] = sources.count - 1
                byName[incoming.bookSourceName] = sources.count - 1
            }
        }
        persistSources()

        // 覆盖更新也算成功；只数新增会让同一个文件导第二次返回 0。
        return incomingList.count
    }

    public func toggleSource(sourceUrl: String) {
        guard let index = sources.firstIndex(where: { $0.bookSourceUrl == sourceUrl }) else { return }
        sources[index].enabled = !(sources[index].enabled ?? true)
        persistSources()
    }

    public func deleteSource(sourceUrl: String) {
        deleteSources(sourceUrls: [sourceUrl])
    }

    public func deleteSources(sourceUrls: Set<String>) {
        guard !sourceUrls.isEmpty else { return }
        sources.removeAll { sourceUrls.contains($0.bookSourceUrl) }
        persistSources()
    }

    public func findSource(for book: Book) -> BookSource? {
        BookSourceResolver.find(book: book, in: sources)
    }

    public func source(forSearchBook item: SearchBook) -> BookSource? {
        BookSourceResolver.find(searchBook: item, in: sources)
    }

    public func updateSource(originalSource: BookSource? = nil, newSource: BookSource) {
        let previousURL = originalSource?.bookSourceUrl ?? newSource.bookSourceUrl
        let previousName = originalSource?.bookSourceName ?? newSource.bookSourceName
        let previousID = originalSource?.id ?? newSource.id

        let matchIndex = sources.firstIndex { $0.bookSourceUrl == previousURL || $0.id == previousID }
        if let matchIndex {
            sources[matchIndex] = newSource
            persistSources()
        }

        var shelfChanged = false
        for index in bookshelf.indices
        where bookshelf[index].origin == previousURL || bookshelf[index].originName == previousName {
            bookshelf[index].origin = newSource.bookSourceUrl
            bookshelf[index].originName = newSource.bookSourceName
            shelfChanged = true
        }
        if shelfChanged {
            persistShelf()
        }

        SourceLoginService.shared.invalidate(sourceUrl: newSource.bookSourceUrl)
    }

    public func updateSource(_ source: BookSource) {
        let original = sources.first { $0.id == source.id || $0.bookSourceUrl == source.bookSourceUrl }
        updateSource(
            originalSource: original,
            newSource: source
        )
    }

    public func pinSource(sourceUrl: String) {
        setPinned(true, sourceUrl: sourceUrl)
    }

    public func setPinned(_ pinned: Bool, sourceUrl: String) {
        guard let index = sources.firstIndex(where: { $0.bookSourceUrl == sourceUrl }) else { return }
        sources[index].customOrder = pinned ? -1 : nil
        if pinned {
            let item = sources.remove(at: index)
            sources.insert(item, at: 0)
        }
        persistSources()
    }

    public func isPinned(_ source: BookSource) -> Bool {
        (source.customOrder ?? 0) < 0
    }

    public func setSourceGroup(sourceUrl: String, group: String?) {
        guard let index = sources.firstIndex(where: { $0.bookSourceUrl == sourceUrl }) else { return }
        let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sources[index].bookSourceGroup = trimmed.isEmpty ? nil : trimmed
        persistSources()
    }

    private func modifySource(_ sourceUrl: String, change: (inout BookSource) -> Void) {
        guard let index = sources.firstIndex(where: { $0.bookSourceUrl == sourceUrl }) else { return }
        change(&sources[index])
        persistSources()
    }

    public func updateSourceHeader(sourceUrl: String, header: String) {
        modifySource(sourceUrl) { $0.loginHeader = header }
    }

    // MARK: - 登录

    public func performLogin(source: BookSource, credentials: [String: String]) async throws -> String {
        try await executeLoginFlow(
            source: source,
            credentials: credentials,
            actions: Self.loginButtonActions(from: source.loginUi),
            credentialsRequired: true
        )
    }

    public func runLoginAction(source: BookSource, credentials: [String: String], action: String) async throws -> String {
        let header = try await executeLoginFlow(
            source: source,
            credentials: credentials,
            actions: [action],
            // 检测、切换服务器这类按钮不产出凭据，不算失败。
            credentialsRequired: false
        )

        let lower = action.lowercased()
        if lower.hasPrefix("logout") || lower.contains("logout(") {
            await MainActor.run { logoutSource(sourceUrl: source.bookSourceUrl) }
        }
        return header
    }

    private func executeLoginFlow(
        source supplied: BookSource,
        credentials: [String: String],
        actions: [String],
        credentialsRequired: Bool
    ) async throws -> String {
        // 面板拿到的是打开那一刻的快照；每一步都取仓库里最新的一份，
        // 否则「切换服务器」永远从同一个旧值开始算。
        let source = await MainActor.run {
            BookStore.shared.sources.first { $0.bookSourceUrl == supplied.bookSourceUrl } ?? supplied
        }
        guard let loginScript = source.loginUrl, !loginScript.isEmpty else {
            throw NSError(domain: "BookStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "这个源没有登录脚本。"
            ])
        }

        let credentialData = (try? JSONSerialization.data(withJSONObject: credentials)) ?? Data()
        let credentialJSON = String(data: credentialData, encoding: .utf8) ?? "{}"

        var working = source
        working.loginInfo = credentialJSON

        let engine = JSEngine(bookSource: working, baseUrl: source.bookSourceUrl)
        var capturedHeader: String?
        var capturedLoginInfo: String?

        engine.onLoginHeaderUpdated = { capturedHeader = $0 }
        engine.onLoginInfoUpdated = { capturedLoginInfo = $0 }

        CookieJar.shared.resetLastWrite()
        _ = engine.eval(script: JSEngine.unwrapJsScript(loginScript), result: credentials)

        if capturedHeader?.isEmpty ?? true {
            for action in actions {
                _ = engine.eval(script: JSEngine.unwrapJsScript(action), result: credentials)
                if let header = capturedHeader, !header.isEmpty {
                    break
                }
            }
        }

        if let scriptedInfo = capturedLoginInfo {
            await MainActor.run {
                if let index = sources.firstIndex(where: { $0.bookSourceUrl == source.bookSourceUrl }) {
                    sources[index].loginInfo = scriptedInfo
                    self.persistSources()
                }
            }
        }

        var resolved = capturedHeader ?? working.loginHeader
        if resolved?.isEmpty ?? true {
            resolved = cookieBackupHeader(for: source.bookSourceUrl)
        }
        // 已有登录态时脚本只 toast 一句「当前已登录」就返回，既不写 cookie 也不回传 header；
        // 宿主清空了「最近写入」记录，于是把好端端的登录判成失败。回问脚本它眼中的服务器 cookie。
        if resolved?.isEmpty ?? true {
            resolved = scriptCookieHeader(engine: engine)
        }

        guard let finalHeader = resolved, !finalHeader.isEmpty else {
            if !credentialsRequired {
                if let error = engine.lastError {
                    throw NSError(domain: "BookStore", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "脚本报错：\(error)"
                    ])
                }
                return ""
            }
            let suffix = engine.lastError.map { "（脚本报错：\($0)）" } ?? ""
            throw NSError(domain: "BookStore", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "登录未返回有效凭据，请检查账号密码\(suffix)"
            ])
        }

        let finalInfo = capturedLoginInfo ?? credentialJSON
        await MainActor.run {
            if let index = sources.firstIndex(where: { $0.bookSourceUrl == source.bookSourceUrl }) {
                sources[index].loginInfo = finalInfo
                sources[index].loginHeader = finalHeader
                self.persistSources()
            }
        }
        SourceLoginService.shared.invalidate(sourceUrl: source.bookSourceUrl)
        return finalHeader
    }

    private func cookieBackupHeader(for sourceURL: String) -> String? {
        let direct = CookieJar.shared.cookieString(for: sourceURL)
        if !direct.isEmpty {
            return "Cookie: \(direct)"
        }
        guard let host = CookieJar.shared.lastWrittenHostKey else { return nil }
        let byHost = CookieJar.shared.cookieString(for: host)
        return byHost.isEmpty ? nil : "Cookie: \(byHost)"
    }

    /// 脚本判断登录态用的是 `getArgument('server') || host[0]` 的 cookie，
    /// 宿主不知道这个地址，只能在同一份 JS 环境里按脚本的算法取。
    private func scriptCookieHeader(engine: JSEngine) -> String? {
        let probe = """
        (function(){
          try {
            var base = (typeof getArgument === 'function' ? getArgument('server') : '') || '';
            if (!base && typeof host !== 'undefined' && host && host.length) base = host[0];
            if (!base) return '';
            return String(cookie.getCookie(base) || '');
          } catch (e) { return ''; }
        })()
        """
        guard let cookie = engine.eval(script: probe) as? String, !cookie.isEmpty else {
            return nil
        }
        return "Cookie: \(cookie)"
    }

    static func loginButtonActions(from loginUi: String?) -> [String] {
        guard let loginUi,
              let data = loginUi.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        let blockedPrefixes = [
            "logout", "register", "fq_login", "loginqt", "checkstatus",
            "cleardevice", "set_server", "vip", "api"
        ]

        return items.compactMap { item in
            guard (item["type"] as? String) == "button" else { return nil }
            let name = (item["name"] as? String) ?? ""
            let action = ((item["action"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !action.isEmpty else { return nil }

            let lower = action.lowercased()
            if name.contains("退出") || name.contains("注册") {
                return nil
            }
            if blockedPrefixes.contains(where: { lower.hasPrefix($0) }) {
                return nil
            }
            let looksLikeLogin = lower.hasPrefix("login")
                || name.contains("登录")
                || name.contains("登陆")
            return looksLikeLogin ? action : nil
        }
    }

    public func logoutSource(sourceUrl: String) {
        modifySource(sourceUrl) {
            $0.loginHeader = nil
            $0.loginInfo = nil
        }
        CookieJar.shared.remove(for: sourceUrl)
        if let host = CookieJar.shared.lastWrittenHostKey, !host.isEmpty {
            CookieJar.shared.remove(for: host)
        }
        SourceLoginService.shared.invalidate(sourceUrl: sourceUrl)
    }

    // MARK: - 目录缓存

    private func chapterCacheURL(for bookUrl: String) -> URL {
        documentsFolder.appendingPathComponent("chapters_\(CryptoUtils.md5(bookUrl)).json")
    }

    /// 换源 / 删书时把旧 bookUrl 的内存和磁盘目录缓存一起丢掉，否则每次换源都留一份。
    /// 目录缓存键是「bookUrl#书源」，所以要把这条书的所有源都扫掉。
    private func discardChapterCache(for bookUrl: String) {
        let keys = Set([bookUrl]).union(
            chapterMemory.keys.filter { $0 == bookUrl || $0.hasPrefix(bookUrl + "#") }
        )
        for key in keys {
            chapterMemory.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: chapterCacheURL(for: key))
        }
    }

    public func saveChapters(_ chapters: [BookChapter], for bookUrl: String) {
        chapterMemory[bookUrl] = chapters
        let encoded = try? JSONEncoder().encode(chapters)
        if let encoded {
            try? encoded.write(to: chapterCacheURL(for: bookUrl))
        }
    }

    public func getChapters(for bookUrl: String) -> [BookChapter] {
        if let cached = chapterMemory[bookUrl] {
            return cached
        }

        let file = chapterCacheURL(for: bookUrl)
        guard let data = try? Data(contentsOf: file),
              var list = try? JSONDecoder().decode([BookChapter].self, from: data) else {
            return []
        }

        var repaired = false
        for index in list.indices {
            if list[index].index != index {
                list[index].index = index
                repaired = true
            }
            if list[index].url.contains("%23") {
                list[index].url = list[index].url.replacingOccurrences(of: "%23", with: "#")
                repaired = true
            }
        }
        if repaired {
            saveChapters(list, for: bookUrl)
        }

        chapterMemory[bookUrl] = list
        return list
    }

    // MARK: - 导入

    public func importEpub(from fileUrl: URL) throws -> Book {
        let package = try EpubParser.shared.parse(epubUrl: fileUrl)
        saveChapters(package.chapters, for: package.book.bookUrl)
        insertOrReplace(package.book)
        return package.book
    }

    /// MOBI/AZW3、FB2、UMD 走同一套：解析器负责拆章落盘，这里只管入库。
    public func importLocalBook(from fileUrl: URL) throws -> Book {
        let package = try LocalBookParser.shared.parse(url: fileUrl)
        saveChapters(package.chapters, for: package.book.bookUrl)
        insertOrReplace(package.book)
        return package.book
    }

    private func textFromTXTData(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let encoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let legacy = String(data: data, encoding: String.Encoding(rawValue: encoding)) {
            return legacy
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func importTxt(from fileUrl: URL) throws -> Book {
        guard let rawData = try? Data(contentsOf: fileUrl) else {
            throw NSError(domain: "BookStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法读取TXT文件内容"
            ])
        }

        let text = textFromTXTData(rawData)
        let title = fileUrl.deletingPathExtension().lastPathComponent
        let bookURL = "txt://\(CryptoUtils.md5(fileUrl.absoluteString))"
        let bookID = CryptoUtils.md5(bookURL)
        let directory = documentsFolder.appendingPathComponent("Books/TXT/\(bookID)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let pattern = #"(?m)^\s*(第[0-9一二三四五六七八九十百千]+[章回节卷].*)$"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let source = text as NSString
        let headings = regex?.matches(in: text, range: NSRange(location: 0, length: source.length)) ?? []

        let parsedChapters = headings.isEmpty
            ? singleTXTChapter(text: text, title: title, bookURL: bookURL, directory: directory)
            : splitTXTChapters(headings: headings, source: source, bookURL: bookURL, directory: directory)

        let localAuthor = "本地书籍"
        let localKind = "TXT 本地书籍"
        let localIntro = "本地导入的TXT小说"
        let localOrigin = "local"
        let localOriginName = "本地导入"

        let localBook = Book(
            bookUrl: bookURL,
            name: title,
            author: localAuthor,
            kind: localKind,
            intro: localIntro,
            origin: localOrigin,
            originName: localOriginName,
            totalChapterNum: parsedChapters.count
        )

        saveChapters(parsedChapters, for: bookURL)
        insertOrReplace(localBook)
        return localBook
    }

    private func singleTXTChapter(
        text: String,
        title: String,
        bookURL: String,
        directory: URL
    ) -> [BookChapter] {
        let file = directory.appendingPathComponent("chapter_0.txt")
        try? text.write(to: file, atomically: true, encoding: .utf8)
        return [BookChapter(bookUrl: bookURL, url: file.absoluteString, title: title, index: 0)]
    }

    private func splitTXTChapters(
        headings: [NSTextCheckingResult],
        source: NSString,
        bookURL: String,
        directory: URL
    ) -> [BookChapter] {
        var result: [BookChapter] = []
        for index in headings.indices {
            let heading = headings[index]
            let chapterTitle = source.substring(with: heading.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let begin = heading.range.location
            let end = index + 1 < headings.count ? headings[index + 1].range.location : source.length
            let body = source.substring(with: NSRange(location: begin, length: end - begin))

            let file = directory.appendingPathComponent("chapter_\(index).txt")
            try? body.write(to: file, atomically: true, encoding: .utf8)
            result.append(BookChapter(bookUrl: bookURL, url: file.absoluteString, title: chapterTitle, index: index))
        }
        return result
    }

    public func importFile(from fileUrl: URL) throws -> Book {
        let suffix = fileUrl.pathExtension.lowercased()
        AppLog.write("[导入] 开始 type=\(suffix.isEmpty ? "?" : suffix)")

        switch suffix {
        case "txt":
            return try textImport(from: fileUrl)
        case "zip", "cbz":
            return try comicImport(from: fileUrl)
        case "pdf":
            return try pdfImport(from: fileUrl)
        case "mobi", "azw", "azw3", "prc", "fb2", "umd":
            return try importLocalBook(from: fileUrl)
        default:
            return try epubImport(from: fileUrl)
        }
    }

    private func textImport(from url: URL) throws -> Book { try importTxt(from: url) }
    private func comicImport(from url: URL) throws -> Book { try importComic(from: url) }
    private func pdfImport(from url: URL) throws -> Book { try importPDF(from: url) }
    private func epubImport(from url: URL) throws -> Book { try importEpub(from: url) }
}

// MARK: - 持久化

private enum Persisted {
    static func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        writeData(data, key: key)
    }

    /// 两套构建线的键名互为镜像：写一份也写另一份，换线安装时才不会读到旧数据
    static func writeData(_ data: Data, key: String) {
        UserDefaults.standard.set(data, forKey: key)
        if let mirror = BookStore.mirroredKey(key) {
            UserDefaults.standard.set(data, forKey: mirror)
        }
    }
}

// MARK: - 阅读统计

public final class ReadingStatsStore: ObservableObject {
    public static let shared = ReadingStatsStore()

    public struct Snapshot: Codable {
        public var dailySeconds: [String: Int] = [:]
        public var totalCharacters: Int = 0
        public var chaptersRead: Int = 0
    }

    @Published public private(set) var snapshot = Snapshot()

    private let storageKey = "reading_stats_v1"
    private let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        }
    }

    private func flush() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func dayKey(for date: Date = Date()) -> String {
        dayFormat.string(from: date)
    }

    public func addReading(seconds: Int, characters: Int = 0, chapters: Int = 0) {
        guard seconds > 0 || characters > 0 || chapters > 0 else { return }

        if seconds > 0 {
            snapshot.dailySeconds[dayKey(), default: 0] += seconds
        }
        snapshot.totalCharacters += max(0, characters)
        snapshot.chaptersRead += max(0, chapters)
        flush()
    }

    public var todaySeconds: Int {
        snapshot.dailySeconds[dayKey()] ?? 0
    }

    public var totalSeconds: Int {
        snapshot.dailySeconds.values.reduce(0, +)
    }

    public var totalCharacters: Int { snapshot.totalCharacters }
    public var chaptersRead: Int { snapshot.chaptersRead }

    public var daysRead: Int {
        var count = 0
        for entry in snapshot.dailySeconds where entry.value > 0 {
            count += 1
        }
        return count
    }

    public var streakDays: Int {
        var streak = 0
        var cursor = Date()

        while streak <= 3650 {
            let seconds = snapshot.dailySeconds[dayKey(for: cursor)] ?? 0
            if seconds > 0 {
                streak += 1
                cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor) ?? cursor
                continue
            }

            if streak == 0 {
                cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor) ?? cursor
                if (snapshot.dailySeconds[dayKey(for: cursor)] ?? 0) == 0 {
                    break
                }
                continue
            }
            break
        }
        return streak
    }

    public func recentDays(_ n: Int = 7) -> [(day: String, seconds: Int)] {
        var result: [(String, Int)] = []
        for offset in stride(from: n - 1, through: 0, by: -1) {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let key = dayKey(for: date)
            result.append((key, snapshot.dailySeconds[key] ?? 0))
        }
        return result
    }
}

// MARK: - 书架分组

public struct BookGroup: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String

    public init(name: String) {
        self.id = UUID()
        self.name = name
    }
}

// MARK: - 批量下载

/// 一次下载要做什么：书评要不要抓、抓多少、几路并发
public struct DownloadOptions: Codable, Equatable {
    /// nil 不抓书评；0 全部；其余是每章条数
    public var reviewLimit: Int?
    public var refetchReviews: Bool
    public var concurrency: Int
    public var background: Bool

    public init(reviewLimit: Int? = 3, refetchReviews: Bool = false, concurrency: Int = 4, background: Bool = true) {
        self.reviewLimit = reviewLimit
        self.refetchReviews = refetchReviews
        self.concurrency = concurrency
        self.background = background
    }

    public static let `default` = DownloadOptions()
}

public struct DownloadJob: Identifiable, Equatable {
    /// 先把正文缓存完，再统一补书评
    public enum Phase: String {
        case chapters
        case reviews
    }

    public enum Status: String {
        case running
        case paused
        case cancelling
        case cancelled
        case finished
    }

    public let id: UUID
    public var bookUrl: String
    public var bookName: String
    public var total: Int
    public var finished: Int
    public var failed: Int
    /// 正文早已缓存、直接跳过的章数
    public var skipped: Int
    public var status: Status
    public var currentChapter: String
    public var phase: Phase
    /// 这本书当前已缓存的章数／书评条数（含下载前已有的），离线书库按它实时显示
    public var cachedChapters: Int
    public var cachedReviews: Int
    /// 预计剩余时间用：本阶段开始时刻与本阶段已处理条数
    public var phaseStartedAt: Date
    public var reviewTotal: Int
    public var reviewsDone: Int
    public var reviewChapterTotal: Int
    public var reviewChapterDone: Int
    public var concurrency: Int
    public var options: DownloadOptions
    /// 还没抓的章号，升序；worker 从这里出队
    var remaining: [Int]
    /// 本次范围的全部章号，书评阶段按它扫
    var plannedIndices: [Int]

    public var isRunning: Bool { status == .running }
    public var isPaused: Bool { status == .paused }
    public var isCancelled: Bool { status == .cancelled }

    public var progress: Double {
        if phase == .reviews {
            return reviewTotal > 0 ? Double(reviewsDone) / Double(reviewTotal) : 0
        }
        return total > 0 ? Double(finished + failed) / Double(total) : 0
    }

    public init(bookUrl: String, bookName: String, indices: [Int], options: DownloadOptions) {
        self.id = UUID()
        self.bookUrl = bookUrl
        self.bookName = bookName
        self.total = indices.count
        self.finished = 0
        self.failed = 0
        self.skipped = 0
        self.status = .running
        self.currentChapter = ""
        self.phase = .chapters
        self.cachedChapters = 0
        self.cachedReviews = 0
        self.phaseStartedAt = Date()
        self.reviewTotal = 0
        self.reviewsDone = 0
        self.reviewChapterTotal = 0
        self.reviewChapterDone = 0
        self.concurrency = options.concurrency
        self.options = options
        self.remaining = indices
        self.plannedIndices = indices
    }
}

public struct DownloadStartResult {
    public let jobID: UUID
    public let merged: Bool
    public let addedChapters: Int
    public let totalChapters: Int
}

/// 跨任务共享的并发闸门，几本书同时下也不会把书源打挂
actor DownloadLimiter {
    static let shared = DownloadLimiter(limit: 8)

    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        active += 1
    }

    func release() {
        active = max(0, active - 1)
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

/// 下载范围换算成章号，下载面板与断点恢复共用
public enum DownloadScope: String, Codable, CaseIterable, Identifiable {
    case all
    case unread
    case nextN

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "全书"
        case .unread: return "未读章节"
        case .nextN: return "往后 N 章"
        }
    }

    public func indices(chapterCount: Int, start: Int, count: Int) -> [Int] {
        guard chapterCount > 0 else { return [] }
        switch self {
        case .all:
            return Array(0..<chapterCount)
        case .unread:
            let begin = min(max(0, start), chapterCount - 1)
            return Array(begin..<chapterCount)
        case .nextN:
            let begin = min(max(0, start), chapterCount - 1)
            let end = min(chapterCount - 1, begin + max(1, count) - 1)
            return Array(begin...end)
        }
    }
}

public final class ChapterDownloadManager: ObservableObject {
    public static let shared = ChapterDownloadManager()

    @Published public private(set) var jobs: [DownloadJob] = []

    /// 本书实时已缓存章数／书评条数，离线书库行优先读它
    @Published public private(set) var liveCounts: [String: LiveCounts] = [:]

    public struct LiveCounts: Equatable {
        public var chapters: Int
        public var reviews: Int
    }

    private var workers: [UUID: Task<Void, Never>] = [:]

    /// 任务要用的书与目录：合并迟到、结束后又被追加章节时靠它重启 worker
    private struct JobContext {
        let book: Book
        let chapters: [BookChapter]
        let source: BookSource?
    }

    private var contexts: [UUID: JobContext] = [:]

    public init() {}

    @discardableResult
    public func start(
        book: Book,
        chapters: [BookChapter],
        source: BookSource?,
        indices: [Int],
        options: DownloadOptions = .default,
        remainingOverride: [Int]? = nil
    ) -> DownloadStartResult? {
        let requested = Array(Set(indices.filter { $0 >= 0 && $0 < chapters.count })).sorted()
        guard !requested.isEmpty else { return nil }

        // 已结束、已取消的旧条目不能并入（worker 已经退出），直接丢掉重来
        jobs.removeAll {
            $0.bookUrl == book.bookUrl && ($0.status == .finished || $0.status == .cancelled)
        }

        if let position = jobs.firstIndex(where: { $0.bookUrl == book.bookUrl }) {
            let jobID = jobs[position].id
            let newOnes = requested.filter { !jobs[position].plannedIndices.contains($0) }
            var mergedRemaining = Set(jobs[position].remaining)
            mergedRemaining.formUnion(newOnes)
            jobs[position].plannedIndices = Array(Set(jobs[position].plannedIndices).union(requested)).sorted()
            jobs[position].total = jobs[position].plannedIndices.count
            jobs[position].remaining = mergedRemaining.sorted()
            jobs[position].options.reviewLimit = Self.mergedReviewLimit(
                jobs[position].options.reviewLimit,
                options.reviewLimit
            )
            jobs[position].options.refetchReviews = jobs[position].options.refetchReviews || options.refetchReviews
            jobs[position].concurrency = max(jobs[position].concurrency, options.concurrency)
            jobs[position].options.concurrency = jobs[position].concurrency
            jobs[position].options.background = jobs[position].options.background || options.background
            if jobs[position].status == .paused {
                jobs[position].status = .running
            }
            if !newOnes.isEmpty && jobs[position].phase == .reviews {
                jobs[position].phase = .chapters
            }
            let context = JobContext(book: book, chapters: chapters, source: source)
            contexts[jobID] = context
            // worker 可能刚好在收尾：它退出了但还有新章，就重新拉起来
            if !jobs[position].remaining.isEmpty && workers[jobID] == nil {
                startWorker(jobID: jobID, context: context)
            }
            AppLog.write("[下载] 《\(book.name)》并入现有任务 \(newOnes.count) 章，共 \(jobs[position].total) 章")
            persistPending(book: book, chapters: chapters, source: source, job: jobs[position])
            DownloadBackground.shared.beginIfNeeded()
            return DownloadStartResult(
                jobID: jobID,
                merged: true,
                addedChapters: newOnes.count,
                totalChapters: jobs[position].total
            )
        }

        var job = DownloadJob(bookUrl: book.bookUrl, bookName: book.name, indices: requested, options: options)
        if let remainingOverride {
            job.remaining = Array(Set(remainingOverride.filter { requested.contains($0) })).sorted()
        }
        job.cachedChapters = OfflineBookStore.shared.cachedIndices(for: book.bookUrl).count
        job.cachedReviews = ReviewCache.count(for: book.bookUrl)
        let jobID = job.id
        jobs.insert(job, at: 0)
        publishLiveCounts()
        persistPending(book: book, chapters: chapters, source: source, job: job)
        DownloadBackground.shared.beginIfNeeded()

        startWorker(jobID: jobID, context: JobContext(book: book, chapters: chapters, source: source))
        return DownloadStartResult(
            jobID: jobID,
            merged: false,
            addedChapters: requested.count,
            totalChapters: requested.count
        )
    }

    private func startWorker(jobID: UUID, context: JobContext) {
        contexts[jobID] = context
        workers[jobID] = Task { [weak self] in
            await self?.runJob(
                jobID: jobID,
                book: context.book,
                chapters: context.chapters,
                source: context.source
            )
        }
    }

    /// 合并两次请求的书评上限：任一侧要「全部」就按全部，否则取大的；都不抓才是 nil
    private static func mergedReviewLimit(_ current: Int?, _ incoming: Int?) -> Int? {
        switch (current, incoming) {
        case (nil, nil):
            return nil
        case let (value?, nil):
            return value
        case let (nil, value?):
            return value
        case let (left?, right?):
            if left == 0 || right == 0 { return 0 }
            return max(left, right)
        }
    }

    // MARK: 任务主循环

    private func runJob(jobID: UUID, book: Book, chapters: [BookChapter], source: BookSource?) async {
        while true {
            guard let snapshot = await jobSnapshot(jobID) else { return }
            if snapshot.status == .cancelled || snapshot.status == .cancelling { return }

            if snapshot.phase == .chapters {
                await runChapterStage(
                    jobID: jobID,
                    book: book,
                    chapters: chapters,
                    source: source,
                    width: snapshot.concurrency
                )
                guard let after = await jobSnapshot(jobID) else { return }
                if after.status == .cancelled || after.status == .cancelling { return }
                if !after.remaining.isEmpty { continue }
                if after.options.reviewLimit == nil { break }
                await beginReviews(jobID)
                continue
            }

            await runReviewStage(jobID: jobID, book: book, chapters: chapters, source: source)
            guard let after = await jobSnapshot(jobID) else { return }
            if after.status == .cancelled || after.status == .cancelling { return }
            if !after.remaining.isEmpty {
                await setPhaseChapters(jobID)
                continue
            }
            break
        }

        await complete(jobID)
        persistOfflineMeta(book: book, chapters: chapters)
        clearPending(bookUrl: book.bookUrl)
        DownloadBackground.shared.endIfIdle()
    }

    private func runChapterStage(
        jobID: UUID,
        book: Book,
        chapters: [BookChapter],
        source: BookSource?,
        width: Int
    ) async {
        let workers = max(1, min(width, 8))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.chapterLoop(jobID: jobID, book: book, chapters: chapters, source: source)
                }
            }
        }
    }

    private enum TakeResult {
        case item(Int)
        case paused
        case empty
        case cancelled
    }

    private func chapterLoop(jobID: UUID, book: Book, chapters: [BookChapter], source: BookSource?) async {
        while true {
            switch await takeChapter(jobID) {
            case .cancelled, .empty:
                return
            case .paused:
                try? await Task.sleep(nanoseconds: 250_000_000)
            case .item(let index):
                await processChapter(jobID: jobID, index: index, book: book, chapters: chapters, source: source)
            }
        }
    }

    private func processChapter(
        jobID: UUID,
        index: Int,
        book: Book,
        chapters: [BookChapter],
        source: BookSource?
    ) async {
        guard index >= 0, index < chapters.count else { return }
        let chapter = chapters[index]

        if BookContentService.shared.hasCachedChapter(bookUrl: book.bookUrl, chapterIndex: chapter.index) {
            await increment(jobID, finished: 1, skipped: 1)
            return
        }

        await setChapter(jobID, chapter.title)
        await DownloadLimiter.shared.acquire()
        var stored = false
        for attempt in 0..<2 {
            do {
                let content = try await BookContentService.shared.fetchChapterContent(
                    chapter: chapter,
                    source: source,
                    book: book
                )
                stored = !content.isEmpty
                break
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                } else {
                    AppLog.write("[下载] 第 \(chapter.index + 1) 章失败：\(error.localizedDescription)")
                }
            }
        }
        await DownloadLimiter.shared.release()

        if stored {
            await increment(jobID, finished: 1, cachedChapters: 1)
        } else if BookContentService.shared.hasCachedChapter(bookUrl: book.bookUrl, chapterIndex: chapter.index) {
            await increment(jobID, finished: 1, skipped: 1)
        } else {
            await increment(jobID, failed: 1)
        }
    }

    @MainActor
    private func takeChapter(_ id: UUID) -> TakeResult {
        guard let position = jobs.firstIndex(where: { $0.id == id }) else { return .cancelled }
        switch jobs[position].status {
        case .cancelled, .cancelling, .finished:
            return .cancelled
        case .paused:
            return .paused
        case .running:
            break
        }
        guard !jobs[position].remaining.isEmpty else { return .empty }
        return .item(jobs[position].remaining.removeFirst())
    }

    @MainActor
    private func jobSnapshot(_ id: UUID) -> DownloadJob? {
        jobs.first { $0.id == id }
    }

    /// 任务结束写一份清单，下载管理里的「离线书库」靠它显示书名与总章数
    private func persistOfflineMeta(book: Book, chapters: [BookChapter]) {
        let reviews = OfflineBookStore.shared.reviewFiles(for: book.bookUrl)
        OfflineBookStore.shared.save(
            meta: OfflineBookMeta(book: book, chapters: chapters, reviewFiles: reviews),
            for: book.bookUrl
        )
        OfflineBookStore.shared.refresh()
    }

    /// 等任务结束（完成或被取消都算）
    public func wait(_ id: UUID) async {
        await workers[id]?.value
    }

    @MainActor private func setChapter(_ id: UUID, _ title: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].currentChapter = title
    }

    @MainActor private func increment(
        _ id: UUID,
        finished: Int = 0,
        failed: Int = 0,
        skipped: Int = 0,
        cachedChapters: Int = 0
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].finished += finished
        jobs[index].failed += failed
        jobs[index].skipped += skipped
        jobs[index].cachedChapters += cachedChapters
        // 第一次落章后补一条离线书库记录，让这本书能立刻出现在列表里
        if finished > 0 && jobs[index].finished == 1 {
            OfflineBookStore.shared.refresh()
        }
        publishLiveCounts()
    }

    @MainActor private func beginReviews(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].phase = .reviews
        jobs[index].currentChapter = ""
        jobs[index].phaseStartedAt = Date()
        jobs[index].reviewTotal = 0
        jobs[index].reviewsDone = 0
        jobs[index].reviewChapterTotal = 0
        jobs[index].reviewChapterDone = 0
        AppLog.write("[下载] 正文完成，开始补书评")
    }

    @MainActor private func beginReviewProgress(_ id: UUID, chapterTotal: Int, anchorTotal: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].reviewChapterTotal = chapterTotal
        jobs[index].reviewTotal = anchorTotal
        jobs[index].phaseStartedAt = Date()
    }

    @MainActor private func markReviewChapterDone(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].reviewChapterDone += 1
    }

    @MainActor private func setPhaseChapters(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].phase = .chapters
        jobs[index].currentChapter = ""
        jobs[index].phaseStartedAt = Date()
    }

    @MainActor private func incrementReviews(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].cachedReviews += 1
        jobs[index].reviewsDone += 1
        publishLiveCounts()
    }

    private func publishLiveCounts() {
        var counts: [String: LiveCounts] = [:]
        for job in jobs {
            counts[job.bookUrl] = LiveCounts(chapters: job.cachedChapters, reviews: job.cachedReviews)
        }
        liveCounts = counts
    }

    /// 书评阶段：先数一遍范围内所有锚点，再按章抓，缺失的才算失败
    private func runReviewStage(jobID: UUID, book: Book, chapters: [BookChapter], source: BookSource?) async {
        guard let snapshot = await jobSnapshot(jobID), let limit = snapshot.options.reviewLimit else { return }
        let refetch = snapshot.options.refetchReviews
        let header = source.map { SourceRequestSupport.headerDictionary(for: $0) } ?? [:]

        var perChapter: [(index: Int, anchors: Int)] = []
        var anchorTotal = 0
        for index in snapshot.plannedIndices {
            guard index >= 0, index < chapters.count else { continue }
            guard let content = BookContentService.shared.getCachedChapterContent(
                bookUrl: book.bookUrl,
                chapterIndex: chapters[index].index
            ), !content.isEmpty else { continue }
            let count = ReviewCache.commentTargets(
                inContent: content,
                limit: limit == 0 ? Int.max : limit
            ).count
            guard count > 0 else { continue }
            perChapter.append((index, count))
            anchorTotal += count
        }
        await beginReviewProgress(jobID, chapterTotal: perChapter.count, anchorTotal: anchorTotal)
        guard anchorTotal > 0 else { return }

        var failed = 0
        for item in perChapter {
            while true {
                guard let current = await jobSnapshot(jobID) else { return }
                if current.status == .cancelled || current.status == .cancelling { return }
                if current.status == .paused {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                break
            }
            guard let content = BookContentService.shared.getCachedChapterContent(
                bookUrl: book.bookUrl,
                chapterIndex: chapters[item.index].index
            ), !content.isEmpty else { continue }

            await DownloadLimiter.shared.acquire()
            let stored = await ReviewCache.prefetchComments(
                inContent: content,
                limit: limit,
                bookUrl: book.bookUrl,
                header: header,
                force: true,
                refetch: refetch
            ) { [weak self] in
                Task { @MainActor in self?.incrementReviews(jobID) }
            }
            await DownloadLimiter.shared.release()

            if stored < item.anchors {
                failed += item.anchors - stored
            }
            await markReviewChapterDone(jobID)
        }
        if failed > 0 {
            AppLog.write("[下载] 书评阶段有 \(failed) 个锚点没抓到")
        }
        AppLog.write("[下载] 书评阶段结束，扫过 \(perChapter.count) 章")
    }

    /// 任务收尾：置完成、刷新离线书库，停留半秒让界面看到 100% 再移除
    @MainActor private func complete(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        // 收尾瞬间又被并入新章：接着跑，别把任务结掉
        if !jobs[index].remaining.isEmpty, let context = contexts[id] {
            jobs[index].status = .running
            jobs[index].phase = .chapters
            workers[id] = nil
            startWorker(jobID: id, context: context)
            return
        }
        jobs[index].status = .finished
        jobs[index].currentChapter = ""
        OfflineBookStore.shared.refresh()
        workers[id] = nil
        contexts[id] = nil
        publishLiveCounts()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.jobs.removeAll { $0.id == id }
            self.publishLiveCounts()
        }
    }

    public func pause(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .running else { return }
        jobs[index].status = .paused
        persistPending(for: jobs[index])
        DownloadBackground.shared.endIfIdle()
    }

    public func resume(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .paused else { return }
        jobs[index].status = .running
        DownloadBackground.shared.beginIfNeeded()
    }

    public func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let bookUrl = jobs[index].bookUrl
        jobs[index].status = .cancelling
        workers[id]?.cancel()
        workers[id] = nil
        contexts[id] = nil
        jobs.removeAll { $0.id == id }
        clearPending(bookUrl: bookUrl)
        publishLiveCounts()
        DownloadBackground.shared.endIfIdle()
    }

    /// 对齐安卓：暂停的任务也算已结束，清理时一并移除，并停掉还在睡眠的 worker。
    public func clearFinished() {
        let ended = jobs.filter { $0.status == .cancelled || $0.status == .finished }
        guard !ended.isEmpty else { return }
        for job in ended {
            clearPending(bookUrl: job.bookUrl)
        }
        jobs.removeAll { $0.status == .cancelled || $0.status == .finished }
        publishLiveCounts()
    }

    public var hasRunningJobs: Bool {
        jobs.contains { $0.status == .running || $0.status == .cancelling }
    }

    public func pauseAll() {
        for index in jobs.indices where jobs[index].status == .running {
            jobs[index].status = .paused
            persistPending(for: jobs[index])
        }
        DownloadBackground.shared.endIfIdle()
    }

    /// 冷启动、回到前台或后台任务唤醒时，接着下没下完的书
    public func resumePendingDownloads() {
        for item in loadPending() {
            if let existing = jobs.first(where: { $0.bookUrl == item.book.bookUrl }),
               existing.status == .running || existing.status == .paused {
                continue
            }
            start(
                book: item.book,
                chapters: item.chapters,
                source: item.source,
                indices: item.plannedIndices ?? item.remaining,
                options: item.options,
                remainingOverride: item.remaining
            )
        }
    }

    // MARK: 断点续传

    private static let pendingKey = "offline_download_pending_v2"
    private static let legacyPendingKey = "offline_download_pending_v1"

    private struct PendingDownload: Codable {
        var book: Book
        var chapters: [BookChapter]
        var source: BookSource?
        var remaining: [Int]
        var options: DownloadOptions
        /// 上次任务范围；老数据没有就按 remaining 处理
        var plannedIndices: [Int]?
    }

    private struct LegacyPendingDownload: Codable {
        var book: Book
        var chapters: [BookChapter]
        var source: BookSource?
        var indices: [Int]
    }

    private func persistPending(book: Book, chapters: [BookChapter], source: BookSource?, job: DownloadJob) {
        var list = loadPending()
        list.removeAll { $0.book.bookUrl == job.bookUrl }
        list.append(PendingDownload(
            book: book,
            chapters: chapters,
            source: source,
            remaining: job.remaining,
            options: job.options,
            plannedIndices: job.plannedIndices
        ))
        savePending(list)
    }

    private func persistPending(for job: DownloadJob) {
        var list = loadPending()
        guard let position = list.firstIndex(where: { $0.book.bookUrl == job.bookUrl }) else { return }
        list[position].remaining = job.remaining
        list[position].options = job.options
        list[position].plannedIndices = job.plannedIndices
        savePending(list)
    }

    private func savePending(_ list: [PendingDownload]) {
        if list.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        } else if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.pendingKey)
        }
    }

    private func clearPending(bookUrl: String) {
        var list = loadPending()
        list.removeAll { $0.book.bookUrl == bookUrl }
        savePending(list)
    }

    private func loadPending() -> [PendingDownload] {
        if let data = UserDefaults.standard.data(forKey: Self.pendingKey),
           let list = try? JSONDecoder().decode([PendingDownload].self, from: data) {
            return list
        }
        guard let data = UserDefaults.standard.data(forKey: Self.legacyPendingKey),
              let old = try? JSONDecoder().decode([LegacyPendingDownload].self, from: data) else {
            return []
        }
        let migrated = old.map {
            PendingDownload(
                book: $0.book,
                chapters: $0.chapters,
                source: $0.source,
                remaining: $0.indices,
                options: .default,
                plannedIndices: $0.indices
            )
        }
        savePending(migrated)
        UserDefaults.standard.removeObject(forKey: Self.legacyPendingKey)
        return migrated
    }
}

// MARK: - 离线书导出/导入

/// 离线包清单：书籍元数据 + 完整目录 + 正文/书评文件列表
public struct OfflineBookManifest: Codable {
    public var version: Int
    public var book: Book
    public var chapters: [BookChapter]
    public var reviewFiles: [String]
    public var coverFile: String?
    public var avatarFiles: [String]?

    public init(
        version: Int,
        book: Book,
        chapters: [BookChapter],
        reviewFiles: [String],
        coverFile: String?,
        avatarFiles: [String]? = nil
    ) {
        self.version = version
        self.book = book
        self.chapters = chapters
        self.reviewFiles = reviewFiles
        self.coverFile = coverFile
        self.avatarFiles = avatarFiles
    }
}

public enum OfflineBookShare {
    public static let fileExtension = "jybook"

    public enum ShareError: LocalizedError {
        case unreadable
        case badManifest

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "离线包无法读取"
            case .badManifest: return "离线包缺少清单文件"
            }
        }
    }

    /// 打包已缓存的正文、书评与封面，返回可直接分享的 zip 文件
    public static func export(book: Book, chapters: [BookChapter]) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("OfflineExport-\(UUID().uuidString)", isDirectory: true)
        let chaptersDir = staging.appendingPathComponent("chapters", isDirectory: true)
        let reviewsDir = staging.appendingPathComponent("reviews", isDirectory: true)
        try fm.createDirectory(at: chaptersDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: reviewsDir, withIntermediateDirectories: true)

        var reviewNames = Set<String>()
        for chapter in chapters {
            guard let content = BookContentService.shared.getCachedChapterContent(
                bookUrl: book.bookUrl,
                chapterIndex: chapter.index
            ), !content.isEmpty else { continue }
            try content.write(
                to: chaptersDir.appendingPathComponent("\(chapter.index).txt"),
                atomically: true,
                encoding: .utf8
            )

            for target in ReviewCache.commentTargets(inContent: content, limit: 80) {
                guard let api = ReviewCache.apiURL(fromRaw: target.raw, mode: target.mode),
                      let data = ReviewCache.load(for: api, bookUrl: book.bookUrl) else { continue }
                let name = CryptoUtils.md5(api.absoluteString) + ".json"
                guard reviewNames.insert(name).inserted else { continue }
                try? data.write(to: reviewsDir.appendingPathComponent(name), options: .atomic)
            }
        }

        // 书目录里已经存下的评论一并带上，不依赖正文哨兵还能不能匹配到
        for name in OfflineBookStore.shared.reviewFiles(for: book.bookUrl) where reviewNames.insert(name).inserted {
            let source = OfflineBookPaths.reviewsDirectory(forBookUrl: book.bookUrl).appendingPathComponent(name)
            guard let data = try? Data(contentsOf: source) else { continue }
            try? data.write(to: reviewsDir.appendingPathComponent(name), options: .atomic)
        }

        // 评论/回复作者头像，离线打开书评时用
        var avatarNames: [String] = []
        let sourceAvatars = OfflineBookPaths.directory(forBookUrl: book.bookUrl)
            .appendingPathComponent("avatars", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: sourceAvatars, includingPropertiesForKeys: nil), !files.isEmpty {
            let avatarsDir = staging.appendingPathComponent("avatars", isDirectory: true)
            try? fm.createDirectory(at: avatarsDir, withIntermediateDirectories: true)
            for file in files where !file.hasDirectoryPath {
                let target = avatarsDir.appendingPathComponent(file.lastPathComponent)
                guard (try? fm.copyItem(at: file, to: target)) != nil else { continue }
                avatarNames.append(file.lastPathComponent)
            }
        }

        var coverFile: String?
        if let cover = book.coverUrl, let cached = BookCoverStorage.cachedFileURL(for: cover),
           fm.fileExists(atPath: cached.path) {
            let target = staging.appendingPathComponent("cover.img")
            if (try? fm.copyItem(at: cached, to: target)) != nil { coverFile = "cover.img" }
        }

        let manifest = OfflineBookManifest(
            version: 1,
            book: book,
            chapters: chapters,
            reviewFiles: reviewNames.sorted(),
            coverFile: coverFile,
            avatarFiles: avatarNames.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)

        OfflineBookStore.shared.save(
            meta: OfflineBookMeta(book: book, chapters: chapters, reviewFiles: reviewNames.sorted()),
            for: book.bookUrl
        )
        OfflineBookStore.shared.refresh()

        let safeName = book.name.replacingOccurrences(of: "/", with: "_")
        let target = fm.temporaryDirectory.appendingPathComponent("\(safeName).\(fileExtension)")
        try? fm.removeItem(at: target)
        let archive = try Archive(url: target, accessMode: .create)
        try addContents(of: staging, to: archive, prefix: "")
        try? fm.removeItem(at: staging)
        return target
    }

    /// 解包并把正文、书评、封面写回各自的缓存位置；书本身按本地书返回
    public static func unpack(at archiveURL: URL) throws -> OfflineBookManifest {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("OfflineImport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        guard let archive = Archive(url: archiveURL, accessMode: .read) else { throw ShareError.unreadable }
        for entry in archive {
            try archive.extract(entry, to: work.appendingPathComponent(entry.path))
        }

        let manifestURL = work.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(OfflineBookManifest.self, from: data) else {
            throw ShareError.badManifest
        }

        let chaptersDir = work.appendingPathComponent("chapters", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: chaptersDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "txt" {
                guard let index = Int(file.deletingPathExtension().lastPathComponent),
                      let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                BookContentService.shared.saveCachedChapterContent(
                    bookUrl: manifest.book.bookUrl,
                    chapterIndex: index,
                    content: content
                )
            }
        }

        let reviewsDir = work.appendingPathComponent("reviews", isDirectory: true)
        for name in manifest.reviewFiles {
            guard let review = try? Data(contentsOf: reviewsDir.appendingPathComponent(name)) else { continue }
            ReviewCache.restoreFile(named: name, data: review, bookUrl: manifest.book.bookUrl)
        }

        if let avatarFiles = manifest.avatarFiles, !avatarFiles.isEmpty {
            let avatarsDir = work.appendingPathComponent("avatars", isDirectory: true)
            let target = OfflineBookPaths.avatarsDirectory(forBookUrl: manifest.book.bookUrl)
            for name in avatarFiles {
                guard let avatar = try? Data(contentsOf: avatarsDir.appendingPathComponent(name)) else { continue }
                try? avatar.write(to: target.appendingPathComponent(name), options: .atomic)
            }
        }

        OfflineBookStore.shared.save(
            meta: OfflineBookMeta(
                book: manifest.book,
                chapters: manifest.chapters,
                reviewFiles: manifest.reviewFiles
            ),
            for: manifest.book.bookUrl
        )
        OfflineBookStore.shared.refresh()

        if let coverFile = manifest.coverFile,
           let cover = manifest.book.coverUrl,
           let cached = BookCoverStorage.cachedFileURL(for: cover) {
            let folder = BookCoverStorage.directory()
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fm.removeItem(at: cached)
            try? fm.copyItem(at: work.appendingPathComponent(coverFile), to: cached)
        }

        var imported = manifest.book
        // 导入的书不依赖书源：目录与正文都走离线缓存
        imported.origin = "local"
        return OfflineBookManifest(
            version: manifest.version,
            book: imported,
            chapters: manifest.chapters,
            reviewFiles: manifest.reviewFiles,
            coverFile: manifest.coverFile,
            avatarFiles: manifest.avatarFiles
        )
    }

    private static func addContents(of directory: URL, to archive: Archive, prefix: String) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let item as URL in enumerator {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDirectory else { continue }
            let relative = String(item.path.dropFirst(directory.path.count + 1))
            let name = prefix.isEmpty ? relative : "\(prefix)/\(relative)"
            try archive.addEntry(with: name, relativeTo: directory, compressionMethod: .deflate)
        }
    }
}

// MARK: - OPDS

public final class OPDSStore: ObservableObject {
    public static let shared = OPDSStore()

    @Published public var catalogs: [OPDSCatalog] = []

    private let storageKey = "opds_catalogs_v1"

    public init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([OPDSCatalog].self, from: data) {
            catalogs = decoded
        }
    }

    private func flush() {
        guard let data = try? JSONEncoder().encode(catalogs) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    public func add(name: String, url: String, username: String, password: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        catalogs.append(OPDSCatalog(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            url: trimmed,
            username: username,
            password: password
        ))
        flush()
        AppLog.write("[OPDS] 新增书库 \(catalogs.count) 个")
    }

    public func remove(_ catalog: OPDSCatalog) {
        catalogs.removeAll { $0.id == catalog.id }
        flush()
        AppLog.write("[OPDS] 删除书库 \(catalogs.count) 个")
    }
}

// MARK: - 漫画与 PDF

public extension BookStore {
    @discardableResult
    func importComic(from fileUrl: URL) throws -> Book {
        guard let archive = Archive(url: fileUrl, accessMode: .read) else {
            throw NSError(domain: "Juyue", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "打不开这个压缩包"
            ])
        }

        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp"]
        var pages: [Entry] = []
        for entry in archive where imageExtensions.contains((entry.path as NSString).pathExtension.lowercased()) {
            pages.append(entry)
        }
        guard !pages.isEmpty else {
            throw NSError(domain: "Juyue", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "包里没有图片"
            ])
        }
        pages.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        let bookURL = "comic://" + CryptoUtils.md5(fileUrl.absoluteString)
        let directory = documentsFolderForImports
            .appendingPathComponent("Books/Comics/\(CryptoUtils.md5(bookURL))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var pageChapters: [BookChapter] = []
        for (index, entry) in pages.enumerated() {
            let ext = (entry.path as NSString).pathExtension.lowercased()
            let destination = directory.appendingPathComponent(String(format: "page-%04d.%@", index + 1, ext))
            if !FileManager.default.fileExists(atPath: destination.path) {
                _ = try? archive.extract(entry, consumer: { data in
                    try? data.write(to: destination)
                })
            }
            pageChapters.append(BookChapter(
                bookUrl: bookURL,
                url: "imgpage://" + destination.path,
                title: String(format: "第 %d 页", index + 1),
                index: index
            ))
        }

        let title = fileUrl.deletingPathExtension().lastPathComponent
        let book = Book(
            bookUrl: bookURL,
            name: title,
            author: "",
            intro: "",
            origin: "local",
            originName: "本地漫画",
            tocUrl: "",
            latestChapterTitle: pageChapters.last?.title,
            totalChapterNum: pageChapters.count
        )
        saveChapters(pageChapters, for: bookURL)
        insertOrReplace(book)
        return book
    }

    @discardableResult
    func importPDF(from fileUrl: URL) throws -> Book {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: fileUrl) else {
            throw NSError(domain: "Juyue", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "打不开这个 PDF"
            ])
        }

        let bookURL = "pdf://" + CryptoUtils.md5(fileUrl.absoluteString)
        let directory = documentsFolderForImports
            .appendingPathComponent("Books/PDF/\(CryptoUtils.md5(bookURL))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var pageChapters: [BookChapter] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let destination = directory.appendingPathComponent(String(format: "page-%04d.png", index + 1))

            if !FileManager.default.fileExists(atPath: destination.path) {
                let bounds = page.bounds(for: .mediaBox)
                let scale: CGFloat = 2
                let width = max(1, Int(bounds.width * scale))
                let height = max(1, Int(bounds.height * scale))
                guard let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                ) else { continue }

                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
                context.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: context)

                guard let image = context.makeImage(),
                      let output = CGImageDestinationCreateWithURL(
                          destination as CFURL,
                          "public.png" as CFString,
                          1,
                          nil
                      ) else { continue }
                CGImageDestinationAddImage(output, image, nil)
                CGImageDestinationFinalize(output)
            }

            pageChapters.append(BookChapter(
                bookUrl: bookURL,
                url: "imgpage://" + destination.path,
                title: String(format: "第 %d 页", index + 1),
                index: index
            ))
        }

        guard !pageChapters.isEmpty else {
            throw NSError(domain: "Juyue", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "PDF 没渲染出页面"
            ])
        }

        let title = fileUrl.deletingPathExtension().lastPathComponent
        let book = Book(
            bookUrl: bookURL,
            name: title,
            author: "",
            intro: "",
            origin: "local",
            originName: "本地 PDF",
            tocUrl: "",
            latestChapterTitle: pageChapters.last?.title,
            totalChapterNum: pageChapters.count
        )
        saveChapters(pageChapters, for: bookURL)
        insertOrReplace(book)
        return book
        #else
        throw NSError(domain: "Juyue", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "这个平台不支持 PDF"
        ])
        #endif
    }
}

private extension BookStore {
    var documentsFolderForImports: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}

// MARK: - 书评缓存

public enum ReviewCache {
    public static let enabledKey = "reader_cache_reviews"
    public static let prefetchLimitKey = "reader_review_prefetch_limit"
    public static let refetchKey = "reader_review_refetch_cached"

    /// 每个锚点给前多少条评论抓回复
    public static let replyFetchLimit = 10
    /// 每条评论只留前多少条回复
    public static let replyKeepLimit = 10

    public static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    /// 每章抓多少条评论：0 表示全部
    public static var prefetchLimit: Int {
        UserDefaults.standard.object(forKey: prefetchLimitKey) as? Int ?? 3
    }

    /// 已有缓存要不要重新拉：默认沿用本地快照，由用户手动打开重拉
    public static var refetchCached: Bool {
        UserDefaults.standard.object(forKey: refetchKey) as? Bool ?? false
    }

    private static var legacyRoot: URL {
        let folder = OfflineBookPaths.legacyReviewRoot
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    private static func legacyFile(for url: URL) -> URL {
        legacyRoot.appendingPathComponent(CryptoUtils.md5(url.absoluteString) + ".json")
    }

    /// 书目录里的评论文件；不建目录，读的时候别为了查缓存把空目录建出来
    private static func bookFile(for url: URL, bookUrl: String) -> URL {
        OfflineBookPaths.directory(forBookUrl: bookUrl)
            .appendingPathComponent("reviews", isDirectory: true)
            .appendingPathComponent(CryptoUtils.md5(url.absoluteString) + ".json")
    }

    private static func bookFileForWriting(for url: URL, bookUrl: String) -> URL {
        OfflineBookPaths.reviewsDirectory(forBookUrl: bookUrl)
            .appendingPathComponent(CryptoUtils.md5(url.absoluteString) + ".json")
    }

    public static func store(_ data: Data, for url: URL, bookUrl: String? = nil, force: Bool = false) {
        guard force || enabled, !data.isEmpty else { return }
        let target = bookUrl.map { bookFileForWriting(for: url, bookUrl: $0) } ?? legacyFile(for: url)
        try? data.write(to: target, options: .atomic)
    }

    public static func load(for url: URL, bookUrl: String? = nil) -> Data? {
        if let bookUrl {
            let bookPath = bookFile(for: url, bookUrl: bookUrl)
            if FileManager.default.fileExists(atPath: bookPath.path) {
                return try? Data(contentsOf: bookPath)
            }
        }
        let path = legacyFile(for: url)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try? Data(contentsOf: path)
    }

    public static func hasCache(for url: URL, bookUrl: String? = nil) -> Bool {
        if let bookUrl, FileManager.default.fileExists(atPath: bookFile(for: url, bookUrl: bookUrl).path) {
            return true
        }
        return FileManager.default.fileExists(atPath: legacyFile(for: url).path)
    }

    /// 回复文件只按 comment_id 命名：评论 URL 的拼接顺序在下载端和阅读端不一定一致
    public static func replyFileName(commentID: String) -> String {
        CryptoUtils.md5(commentID) + ".reply.json"
    }

    public static func storeReply(_ data: Data, commentID: String, bookUrl: String?, force: Bool = false) {
        guard force || enabled, !data.isEmpty, let bookUrl else { return }
        let target = OfflineBookPaths.reviewsDirectory(forBookUrl: bookUrl)
            .appendingPathComponent(replyFileName(commentID: commentID))
        try? data.write(to: target, options: .atomic)
    }

    public static func loadReply(commentID: String, bookUrl: String?) -> Data? {
        guard let bookUrl else { return nil }
        let path = OfflineBookPaths.directory(forBookUrl: bookUrl)
            .appendingPathComponent("reviews", isDirectory: true)
            .appendingPathComponent(replyFileName(commentID: commentID))
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try? Data(contentsOf: path)
    }

    public static func hasReply(commentID: String, bookUrl: String?) -> Bool {
        loadReply(commentID: commentID, bookUrl: bookUrl) != nil
    }

    public static func count(for bookUrl: String? = nil) -> Int {
        let fm = FileManager.default
        if let bookUrl {
            let folder = OfflineBookPaths.directory(forBookUrl: bookUrl)
                .appendingPathComponent("reviews", isDirectory: true)
            return (try? fm.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".reply.json") }.count ?? 0
        }
        var total = (try? fm.contentsOfDirectory(atPath: legacyRoot.path))?.count ?? 0
        if let books = try? fm.contentsOfDirectory(atPath: OfflineBookPaths.root.path) {
            for key in books {
                let folder = OfflineBookPaths.root
                    .appendingPathComponent(key, isDirectory: true)
                    .appendingPathComponent("reviews", isDirectory: true)
                total += (try? fm.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".reply.json") }.count ?? 0
            }
        }
        return total
    }

    public static func clearAll() {
        try? FileManager.default.removeItem(at: legacyRoot)
        let fm = FileManager.default
        if let books = try? fm.contentsOfDirectory(atPath: OfflineBookPaths.root.path) {
            for key in books {
                let folder = OfflineBookPaths.root
                    .appendingPathComponent(key, isDirectory: true)
                    .appendingPathComponent("reviews", isDirectory: true)
                try? fm.removeItem(at: folder)
            }
        }
    }

    /// 离线包导入：文件名就是 md5(apiURL)，直接写回缓存目录
    public static func restoreFile(named name: String, data: Data, bookUrl: String? = nil) {
        let target: URL
        if let bookUrl {
            target = OfflineBookPaths.reviewsDirectory(forBookUrl: bookUrl).appendingPathComponent(name)
        } else {
            target = legacyRoot.appendingPathComponent(name)
        }
        try? data.write(to: target, options: .atomic)
    }

    public static func apiURL(fromRaw raw: String, mode: String = "chapter") -> URL? {
        guard var components = URLComponents(string: raw) else { return nil }
        let query = components.queryItems ?? []

        func value(_ names: [String], fallback: String) -> String {
            for name in names {
                if let found = query.first(where: { $0.name == name })?.value {
                    return found
                }
            }
            return fallback
        }

        components.path = "/para_review"
        components.queryItems = [
            URLQueryItem(name: "book_id", value: value(["book_id"], fallback: "")),
            URLQueryItem(name: "item_id", value: value(["item_id"], fallback: "")),
            URLQueryItem(name: "item_version", value: value(["item_version"], fallback: "")),
            URLQueryItem(name: "para", value: value(["para", "paragraph_id"], fallback: "0")),
            URLQueryItem(name: "source", value: value(["source"], fallback: "番茄")),
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "hot", value: "1")
        ]
        return components.url
    }

    public static func commentTargets(inContent content: String, limit: Int) -> [(raw: String, mode: String)] {
        var found: [(String, String)] = []

        for marker in ReviewMarkerParser.comments(in: content) where !marker.url.isEmpty {
            found.append((marker.url, "paragraph"))
        }
        for marker in ReviewMarkerParser.chapters(in: content) where !marker.url.isEmpty {
            found.append((marker.url, "chapter"))
        }

        var seen = Set<String>()
        var targets: [(raw: String, mode: String)] = []
        for item in found where seen.insert(item.0).inserted {
            targets.append((raw: item.0, mode: item.1))
            if targets.count >= limit { break }
        }
        return targets
    }

    /// 抓正文里所有书评锚点；返回成功落盘的条数，供下载进度和失败统计用
    @discardableResult
    public static func prefetchComments(
        inContent content: String,
        limit: Int? = nil,
        bookUrl: String? = nil,
        header: [String: String] = [:],
        force: Bool = false,
        refetch: Bool? = nil,
        onStored: (() -> Void)? = nil
    ) async -> Int {
        guard force || enabled, !content.isEmpty else { return 0 }
        let cap = limit ?? prefetchLimit
        let targets = commentTargets(inContent: content, limit: cap == 0 ? Int.max : cap)
        guard !targets.isEmpty else { return 0 }
        let shouldRefetch = refetch ?? refetchCached

        var stored = 0
        var avatars: [URL] = []
        for target in targets {
            guard let api = apiURL(fromRaw: target.raw, mode: target.mode) else { continue }
            if hasCache(for: api, bookUrl: bookUrl), !shouldRefetch { continue }

            do {
                let (data, _) = try await URLSession.shared.data(for: request(api, header: header))
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["data"] != nil else { continue }
                let destination = bookUrl.map { bookFileForWriting(for: api, bookUrl: $0) } ?? legacyFile(for: api)
                try? data.write(to: destination, options: .atomic)
                stored += 1
                onStored?()

                guard let bookUrl else { continue }
                let comments = parseComments(data)
                avatars.append(contentsOf: comments.compactMap(\.avatar))
                for comment in comments.prefix(replyFetchLimit) where comment.replyCount > 0 {
                    if hasReply(commentID: comment.id, bookUrl: bookUrl), !shouldRefetch { continue }
                    guard let replyURL = replyAPIURL(from: api, commentID: comment.id) else { continue }
                    avatars.append(contentsOf: await fetchReplies(
                        url: replyURL,
                        commentID: comment.id,
                        bookUrl: bookUrl,
                        header: header,
                        force: force
                    ))
                }
            } catch {
                continue
            }
        }
        if let bookUrl, !avatars.isEmpty {
            await prefetchAvatars(avatars, bookUrl: bookUrl, header: header)
        }
        AppLog.write("[书评] 缓存评论 \(stored)/\(targets.count) 条 · 抓取上限 \(cap == 0 ? "全部" : "\(cap)") · 重拉 \(shouldRefetch ? "开" : "关")")
        return stored
    }

    private static func request(_ url: URL, header: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        for (key, value) in header {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private struct CommentSummary {
        let id: String
        let replyCount: Int
        let avatar: URL?
    }

    private static func parseComments(_ data: Data) -> [CommentSummary] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any],
              let comments = payload["comments"] as? [[String: Any]] else { return [] }
        return comments.compactMap { item in
            guard let id = item["comment_id"] as? String else { return nil }
            return CommentSummary(
                id: id,
                replyCount: item["reply_count"] as? Int ?? 0,
                avatar: userAvatarURL(from: item)
            )
        }
    }

    private static func userAvatarURL(from item: [String: Any]) -> URL? {
        guard let user = item["user"] as? [String: Any],
              let raw = user["user_avatar"] as? String else { return nil }
        return absoluteURL(raw)
    }

    private static func absoluteURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") { return URL(string: "https:" + trimmed) }
        return URL(string: trimmed)
    }

    private static func replyAPIURL(from api: URL, commentID: String) -> URL? {
        guard var components = URLComponents(url: api, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != "comment_id" && $0.name != "cursor" }
        items.append(URLQueryItem(name: "comment_id", value: commentID))
        components.queryItems = items
        return components.url
    }

    /// 抓一条评论的回复并截断到 replyKeepLimit 条，返回本次遇到的作者头像
    private static func fetchReplies(
        url: URL,
        commentID: String,
        bookUrl: String,
        header: [String: String],
        force: Bool
    ) async -> [URL] {
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let (data, _) = try? await URLSession.shared.data(for: request(url, header: header)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var payload = object["data"] as? [String: Any],
              let replies = payload["replies"] as? [[String: Any]] else { return [] }
        payload["replies"] = Array(replies.prefix(replyKeepLimit))
        let envelope: [String: Any] = ["code": object["code"] ?? 0, "data": payload]
        guard let out = try? JSONSerialization.data(withJSONObject: envelope) else { return [] }
        storeReply(out, commentID: commentID, bookUrl: bookUrl, force: force)
        return replies.compactMap { userAvatarURL(from: $0) }
    }

    private static func prefetchAvatars(_ urls: [URL], bookUrl: String, header: [String: String]) async {
        var seen = Set<String>()
        for url in urls where seen.insert(url.absoluteString).inserted {
            guard !AvatarCache.hasCache(for: url, bookUrl: bookUrl) else { continue }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let (data, response) = try? await URLSession.shared.data(for: request(url, header: header)) else { continue }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { continue }
            AvatarCache.store(data, for: url, bookUrl: bookUrl)
        }
    }
}

// MARK: - 头像缓存

/// 评论/回复作者头像，离线也能显示；按 URL 哈希存在书目录下。
public enum AvatarCache {
    public static func fileURL(for url: URL, bookUrl: String) -> URL {
        OfflineBookPaths.directory(forBookUrl: bookUrl)
            .appendingPathComponent("avatars", isDirectory: true)
            .appendingPathComponent(CryptoUtils.md5(url.absoluteString))
    }

    public static func hasCache(for url: URL, bookUrl: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: url, bookUrl: bookUrl).path)
    }

    public static func store(_ data: Data, for url: URL, bookUrl: String) {
        guard !data.isEmpty, data.count <= 512 * 1024 else { return }
        let target = OfflineBookPaths.avatarsDirectory(forBookUrl: bookUrl)
            .appendingPathComponent(CryptoUtils.md5(url.absoluteString))
        try? data.write(to: target, options: .atomic)
    }

    public static func load(for url: URL, bookUrl: String) -> Data? {
        let path = fileURL(for: url, bookUrl: bookUrl)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try? Data(contentsOf: path)
    }
}

// MARK: - 后台下载

/// 退到后台后继续下载：先申请一段后台时间，系统收走前结束；
/// 同时注册 BGProcessingTask，系统空闲时唤醒接着下未完成的队列。
public final class DownloadBackground {
    public static let shared = DownloadBackground()
    public static let taskIdentifier = "com.factorcitrus.juyue.download"

    #if canImport(UIKit)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    private var registered = false

    /// 必须在启动完成前调用（JuyueApp.init），否则 BGTaskScheduler 注册不生效
    public func register() {
        guard !registered else { return }
        registered = true
        #if canImport(UIKit)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            task.expirationHandler = {
                DispatchQueue.main.async {
                    ChapterDownloadManager.shared.pauseAll()
                }
            }
            DispatchQueue.main.async {
                ChapterDownloadManager.shared.resumePendingDownloads()
            }
            task.setTaskCompleted(success: true)
        }
        #endif
    }

    public func beginIfNeeded() {
        #if canImport(UIKit)
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ChapterDownload") { [weak self] in
            self?.endBackgroundTask()
        }
        #endif
    }

    public func endIfIdle() {
        guard !ChapterDownloadManager.shared.hasRunningJobs else { return }
        #if canImport(UIKit)
        endBackgroundTask()
        #endif
    }

    public func scheduleIfNeeded() {
        guard ChapterDownloadManager.shared.hasRunningJobs else { return }
        #if canImport(UIKit)
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    #if canImport(UIKit)
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif
}
