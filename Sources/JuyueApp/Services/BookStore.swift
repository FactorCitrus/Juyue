import Foundation
import CoreGraphics
import ImageIO
import ZIPFoundation
#if canImport(PDFKit)
import PDFKit
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

    public init() {
        JuyueStorageMigration.runIfNeeded()
        reloadPersistedState()
        installJSEngineSinks()
        installSearchTimingSink()
    }

    // MARK: - 启动

    private func reloadPersistedState() {
        if let stored = Persisted.read([BookSource].self, key: Keys.sources) {
            sources = stored
        }
        // 内置源每次都参与同步：本地为空整批灌入，非空只刷新规则，登录态由合并函数保住。
        loadBundledSources()
        if let stored = Persisted.read([Book].self, key: Keys.books) {
            bookshelf = stored
        }
        if let stored = Persisted.read([BookBookmark].self, key: Keys.bookmarks) {
            bookmarks = stored
        }
        if let stored = Persisted.read([BookGroup].self, key: Keys.groups) {
            groups = stored
        }
        if let stored = Persisted.read([String: [TextReplaceRule]].self, key: Keys.replaceRules) {
            textReplaceRulesMap = stored
        }
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
    private func persistShelf() { Persisted.write(bookshelf, key: Keys.books) }

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
            bookshelf.removeAll { $0.bookUrl == oldBook.bookUrl }
            chapterMemory.removeValue(forKey: oldBook.bookUrl)
        }

        if let index = bookshelf.firstIndex(where: { $0.bookUrl == target.bookUrl }) {
            bookshelf[index] = target
        } else {
            bookshelf.insert(target, at: 0)
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
        persistShelf()

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
        let incomingList = try JSONDecoder().decode([BookSource].self, from: data)

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
        let incomingList = try JSONDecoder().decode([BookSource].self, from: data)

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
        UserDefaults.standard.set(data, forKey: key)
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

public struct DownloadJob: Identifiable, Equatable {
    public let id: UUID
    public var bookUrl: String
    public var bookName: String
    public var total: Int
    public var finished: Int
    public var failed: Int
    public var isPaused: Bool
    public var isCancelled: Bool
    public var isRunning: Bool
    public var currentChapter: String

    public var progress: Double {
        total > 0 ? Double(finished + failed) / Double(total) : 0
    }

    public init(bookUrl: String, bookName: String, total: Int) {
        self.id = UUID()
        self.bookUrl = bookUrl
        self.bookName = bookName
        self.total = total
        self.finished = 0
        self.failed = 0
        self.isPaused = false
        self.isCancelled = false
        self.isRunning = true
        self.currentChapter = ""
    }
}

public final class ChapterDownloadManager: ObservableObject {
    public static let shared = ChapterDownloadManager()

    @Published public private(set) var jobs: [DownloadJob] = []

    private var workers: [UUID: Task<Void, Never>] = [:]

    public init() {}

    @discardableResult
    public func start(book: Book, chapters: [BookChapter], source: BookSource?, indices: [Int]) -> UUID? {
        guard !indices.isEmpty else { return nil }

        let job = DownloadJob(bookUrl: book.bookUrl, bookName: book.name, total: indices.count)
        let jobID = job.id
        jobs.insert(job, at: 0)

        workers[jobID] = Task { [weak self] in
            for index in indices {
                guard let self else { return }

                while true {
                    guard let current = await self.state(of: jobID) else { return }
                    switch current {
                    case .cancelled:
                        return
                    case .paused:
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        continue
                    case .running:
                        break
                    }
                    break
                }

                guard index >= 0, index < chapters.count else { continue }
                let chapter = chapters[index]

                if BookContentService.shared.hasCachedChapter(bookUrl: book.bookUrl, chapterIndex: chapter.index) {
                    if ReviewCache.enabled,
                       let cached = BookContentService.shared.getCachedChapterContent(
                           bookUrl: book.bookUrl,
                           chapterIndex: chapter.index
                       ) {
                        await ReviewCache.prefetchComments(inContent: cached)
                    }
                    await self.increment(jobID, finished: 1)
                } else {
                    await self.setChapter(jobID, chapter.title)
                    do {
                        let content = try await BookContentService.shared.fetchChapterContent(
                            chapter: chapter,
                            source: source,
                            book: book
                        )
                        if ReviewCache.enabled, !content.isEmpty {
                            await ReviewCache.prefetchComments(inContent: content)
                        }
                        await self.increment(jobID, finished: 1)
                    } catch {
                        await self.increment(jobID, failed: 1)
                    }
                }

                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            await self?.complete(jobID)
        }
        return jobID
    }

    enum JobState { case running, paused, cancelled }

    @MainActor private func state(of id: UUID) -> JobState? {
        guard let job = jobs.first(where: { $0.id == id }) else { return nil }
        if job.isCancelled { return .cancelled }
        return job.isPaused ? .paused : .running
    }

    @MainActor private func setChapter(_ id: UUID, _ title: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].currentChapter = title
    }

    @MainActor private func increment(_ id: UUID, finished: Int = 0, failed: Int = 0) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].finished += finished
        jobs[index].failed += failed
    }

    @MainActor private func complete(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].isRunning = false
        jobs[index].currentChapter = ""
    }

    public func pause(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].isPaused = true
    }

    public func resume(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].isPaused = false
    }

    public func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].isCancelled = true
        jobs[index].isRunning = false
        workers[id]?.cancel()
        workers[id] = nil
    }

    public func clearFinished() {
        jobs.removeAll { !$0.isRunning }
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

    public static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    private static var root: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("ReviewCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    private static func file(for url: URL) -> URL {
        root.appendingPathComponent(CryptoUtils.md5(url.absoluteString) + ".json")
    }

    public static func store(_ data: Data, for url: URL) {
        guard enabled, !data.isEmpty else { return }
        try? data.write(to: file(for: url), options: .atomic)
    }

    public static func load(for url: URL) -> Data? {
        let path = file(for: url)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try? Data(contentsOf: path)
    }

    public static func hasCache(for url: URL) -> Bool {
        FileManager.default.fileExists(atPath: file(for: url).path)
    }

    public static func count() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count) ?? 0
    }

    public static func clearAll() {
        try? FileManager.default.removeItem(at: root)
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
        let text = content as NSString
        let fullRange = NSRange(location: 0, length: text.length)

        if let regex = try? NSRegularExpression(pattern: "\u{E000}C\u{1F}\\d+\u{1F}([^\u{E001}]*)\u{E001}") {
            for match in regex.matches(in: content, range: fullRange) {
                let raw = text.substring(with: match.range(at: 1))
                if !raw.isEmpty { found.append((raw, "paragraph")) }
            }
        }
        if let regex = try? NSRegularExpression(pattern: "\u{E000}H\u{1F}([^\u{E001}]*)\u{E001}") {
            for match in regex.matches(in: content, range: fullRange) {
                let raw = text.substring(with: match.range(at: 1))
                if !raw.isEmpty { found.append((raw, "chapter")) }
            }
        }

        var seen = Set<String>()
        var targets: [(raw: String, mode: String)] = []
        for item in found where seen.insert(item.0).inserted {
            targets.append((raw: item.0, mode: item.1))
            if targets.count >= limit { break }
        }
        return targets
    }

    public static func prefetchComments(inContent content: String, limit: Int = 3) async {
        guard enabled, !content.isEmpty else { return }
        let targets = commentTargets(inContent: content, limit: limit)
        guard !targets.isEmpty else { return }

        var stored = 0
        for target in targets {
            guard let api = apiURL(fromRaw: target.raw, mode: target.mode) else { continue }
            if hasCache(for: api) { continue }

            do {
                let (data, _) = try await URLSession.shared.data(from: api)
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["data"] != nil else { continue }
                try? data.write(to: file(for: api), options: .atomic)
                stored += 1
            } catch {
                continue
            }
        }
        AppLog.write("[书评] 缓存评论 \(stored)/\(targets.count) 条 · 抓取上限 \(limit)")
    }
}
