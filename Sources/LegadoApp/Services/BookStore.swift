import Foundation
import CoreGraphics
import ImageIO
import ZIPFoundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(LegadoCore)
import LegadoCore
#endif

public class BookStore: ObservableObject {
    public static let shared = BookStore()

    @Published public var bookshelf: [Book] = []
    @Published public var sources: [BookSource] = []

    /// 落盘键名集中在这里：结构变了要新开键再写迁移，直接改字面量会丢用户的架子和书源。
    private enum StoreKey {
        static let bookshelf = "legado_bookshelf_v1"
        static let sources = "legado_sources_v1"
    }

    private var booksKey: String { StoreKey.bookshelf }
    private var sourcesKey: String { StoreKey.sources }
    private let bookmarksKey = "legado_bookmarks_v1"
    private let groupsKey = "legado_book_groups_v1"
    private let replaceRulesKey = "legado_text_replace_v1"
    /// 按书的正文替换规则（阅读页里选的「把这段换成…」）
    @Published public var textReplaceRulesMap: [String: [TextReplaceRule]] = [:]

    /// 搜索实测的响应时间批量落盘，避免一搜 50 个源就写 50 次 UserDefaults。
    private var respondTimeSaveWorkItem: DispatchWorkItem?

    /// 书签 / 笔记：按书存，读取时按书过滤
    @Published public var bookmarks: [BookBookmark] = []

    public init() {
        loadData()
        loadBookmarks()
        loadGroups()
        if let data = UserDefaults.standard.data(forKey: replaceRulesKey),
           let decoded = try? JSONDecoder().decode([String: [TextReplaceRule]].self, from: data) {
            textReplaceRulesMap = decoded
        }
        // 脚本用 source.setVariable 存的状态要落盘：聚合源的「切换服务器」与书源设置中心
        // 结果都写在书源 variable 里，不写回去每次点击都从旧值重算（服务器永远停在同一台）。
        JSEngine.variableSink = { url, variable in
            guard !url.isEmpty else { return }
            DispatchQueue.main.async {
                let store = BookStore.shared
                guard let idx = store.sources.firstIndex(where: { $0.bookSourceUrl == url }) else { return }
                // 脚本爱怎么刷怎么刷，值没变就不写盘
                guard store.sources[idx].variable != variable else { return }
                store.sources[idx].variable = variable
                store.saveSources()
            }
        }
        // 脚本改写「当前这本书」（book.setVariable / book.setUseReplaceRule）也要落盘，
        // 否则聚合源每次都会重新按「没记过」处理，替换净化开关永远回默认。
        JSEngine.bookUpdateSink = { updated in
            guard !updated.bookUrl.isEmpty else { return }
            DispatchQueue.main.async {
                let store = BookStore.shared
                guard let idx = store.bookshelf.firstIndex(where: { $0.bookUrl == updated.bookUrl }) else { return }
                let old = store.bookshelf[idx]
                guard old.variable != updated.variable || old.useReplaceRule != updated.useReplaceRule else { return }
                store.bookshelf[idx].variable = updated.variable
                store.bookshelf[idx].useReplaceRule = updated.useReplaceRule
                store.saveBookshelf()
            }
        }
        // 搜索实测耗时写回书源 respondTime，下一次选源排序就有真实依据。
        BookSearchService.respondTimeSink = { url, milliseconds in
            guard !url.isEmpty, milliseconds > 0 else { return }
            DispatchQueue.main.async {
                let store = BookStore.shared
                guard let idx = store.sources.firstIndex(where: { $0.bookSourceUrl == url }) else { return }
                let old = store.sources[idx].respondTime
                // 抖动小于 50ms 不重写，避免每次搜索都刷 UserDefaults
                if let old, abs(old - milliseconds) < 50 { return }
                store.sources[idx].respondTime = milliseconds
                store.scheduleRespondTimeSave()
            }
        }
    }

    private func scheduleRespondTimeSave() {
        respondTimeSaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveSources()
        }
        respondTimeSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: bookmarksKey),
           let decoded = try? JSONDecoder().decode([BookBookmark].self, from: data) {
            bookmarks = decoded
        }
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: bookmarksKey)
        }
    }

    public func bookmarks(for bookUrl: String) -> [BookBookmark] {
        bookmarks.filter { $0.bookUrl == bookUrl }.sorted { $0.createdAt > $1.createdAt }
    }

    /// 段落级标注（下划线 / 底色）：同一段只留一种样式，重复点就是取消。
    /// 返回 true 表示这次是「加上」，false 表示「取消掉」。
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
        if charScoped {
            // 明确「清除」：不比较颜色，命中同段同区间的那条就删
            if forceRemove {
                let before = bookmarks.count
                bookmarks.removeAll {
                    $0.bookUrl == bookUrl && $0.chapterIndex == chapterIndex
                        && $0.blockId == blockId && $0.kind == kind
                        && $0.charOffset == charOffset && $0.length == length
                        && $0.rangeUnitRaw == "char"
                }
                if bookmarks.count != before { saveBookmarks() }
                return false
            }
            // 逐字标注：同一段可以有多个区间。同区间点同色 = 取消，点别的色 = 换色
            let sameRange = bookmarks.firstIndex {
                $0.bookUrl == bookUrl && $0.chapterIndex == chapterIndex
                    && $0.blockId == blockId && $0.kind == kind
                    && $0.charOffset == charOffset && $0.length == length
                    && $0.rangeUnitRaw == "char"
            }
            if let sameRange {
                let current = bookmarks[sameRange].color
                    ?? (kind == .underline ? "#2F7BF6" : "#FFF59D")
                let sameColor = current == color
                bookmarks.remove(at: sameRange)
                if sameColor {
                    saveBookmarks()
                    return false
                }
            }
            bookmarks.append(BookBookmark(
                bookUrl: bookUrl,
                chapterIndex: chapterIndex,
                chapterTitle: chapterTitle,
                charOffset: charOffset,
                snippet: String(snippet.prefix(60)),
                blockId: blockId,
                length: length,
                color: color,
                rangeUnit: "char",
                kind: kind
            ))
            saveBookmarks()
            return true
        }
        // 整段标注的「清除」：这一段这一类标注全部撤掉，不看颜色
        if forceRemove {
            let before = bookmarks.count
            bookmarks.removeAll {
                $0.bookUrl == bookUrl && $0.chapterIndex == chapterIndex
                    && $0.blockId == blockId && $0.kind == kind && $0.rangeUnitRaw == nil
            }
            if bookmarks.count != before { saveBookmarks() }
            return false
        }
        let existing = bookmarks.firstIndex {
            $0.bookUrl == bookUrl && $0.chapterIndex == chapterIndex
                && $0.blockId == blockId && $0.kind == kind && $0.rangeUnitRaw == nil
        }
        if let existing {
            let current = bookmarks[existing].color
                ?? (kind == .underline ? "#2F7BF6" : "#FFF59D")
            let sameColor = current == color
            bookmarks.remove(at: existing)
            if sameColor {
                saveBookmarks()
                return false
            }
        }
        // 一段只留一种样式：先把这一段其它标注清掉，免得下划线和底色打架
        bookmarks.removeAll {
            $0.bookUrl == bookUrl && $0.chapterIndex == chapterIndex
                && $0.blockId == blockId && $0.kind != .bookmark && $0.rangeUnitRaw == nil
        }
        bookmarks.append(BookBookmark(
            bookUrl: bookUrl,
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            charOffset: charOffset,
            snippet: String(snippet.prefix(60)),
            blockId: blockId,
            length: length,
            color: color,
            kind: kind
        ))
        saveBookmarks()
        return true
    }

    /// 把这一章的标注整体换成给定的一批：选段里按「取消」要还原格式时用
    public func replaceAnnotations(_ items: [BookBookmark], bookUrl: String, chapterIndex: Int) {
        bookmarks.removeAll {
            $0.bookUrl == bookUrl && $0.chapterIndex == chapterIndex && $0.kind != .bookmark
        }
        bookmarks.append(contentsOf: items)
        saveBookmarks()
    }

    /// 这一章的标注，按 blockId 索引 —— 渲染时按段查
    public func annotations(bookUrl: String, chapterIndex: Int) -> [Int: BookBookmark] {
        var map: [Int: BookBookmark] = [:]
        for item in bookmarks
        where item.bookUrl == bookUrl && item.chapterIndex == chapterIndex
            && item.kind != .bookmark && item.rangeUnitRaw == nil {
            if let blockId = item.blockId { map[blockId] = item }
        }
        return map
    }

    /// 这一章所有非书签标注（含逐字区间），逐字绘制用
    public func userAnnotations(bookUrl: String, chapterIndex: Int) -> [BookBookmark] {
        bookmarks.filter {
            $0.bookUrl == bookUrl && $0.chapterIndex == chapterIndex && $0.kind != .bookmark
        }
    }

    /// 选中范围里已有的标注：逐字选只认和选区有交集的逐字标注（段级标注也算）,
    /// 不给 charStart 就是整段口径。
    public func annotationsOverlapping(
        bookUrl: String,
        chapterIndex: Int,
        blockId: Int,
        charStart: Int? = nil,
        charLength: Int? = nil
    ) -> [BookBookmark] {
        bookmarks.filter {
            $0.bookUrl == bookUrl && $0.chapterIndex == chapterIndex
                && $0.blockId == blockId && $0.kind != .bookmark
                && overlap($0, charStart: charStart, charLength: charLength)
        }
    }

    private func overlap(_ item: BookBookmark, charStart: Int?, charLength: Int?) -> Bool {
        // 整段口径：这一段上的标注全算
        guard let charStart, let charLength else { return true }
        // 段级标注（rangeUnitRaw == nil）覆盖整段，逐字选区也算命中
        guard item.rangeUnitRaw == "char" else { return true }
        let start = item.charOffset
        let end = item.charOffset + max(1, item.length ?? 1)
        return start < charStart + max(1, charLength) && charStart < end
    }

    /// 撤标注：不看颜色、不挑种类，选中范围里有就删。
    /// 之前只认「同区间同色」才取消，改过颜色的标注于是永远撤不掉。
    @discardableResult
    public func removeAnnotations(
        bookUrl: String,
        chapterIndex: Int,
        blockId: Int,
        charStart: Int? = nil,
        charLength: Int? = nil
    ) -> Int {
        let before = bookmarks.count
        bookmarks.removeAll {
            $0.bookUrl == bookUrl && $0.chapterIndex == chapterIndex
                && $0.blockId == blockId && $0.kind != .bookmark
                && overlap($0, charStart: charStart, charLength: charLength)
        }
        let removed = before - bookmarks.count
        if removed > 0 { saveBookmarks() }
        return removed
    }

    // MARK: - 正文替换（阅读页选中一段做替换，按书生效）

    public func textReplaceRules(bookUrl: String) -> [TextReplaceRule] {
        textReplaceRulesMap[bookUrl] ?? []
    }

    public func addTextReplaceRule(bookUrl: String, from: String, to: String) {
        let trimmedFrom = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFrom.isEmpty else { return }
        var rules = textReplaceRulesMap[bookUrl] ?? []
        rules.removeAll { $0.from == trimmedFrom }
        rules.append(TextReplaceRule(from: trimmedFrom, to: to))
        textReplaceRulesMap[bookUrl] = rules
        saveTextReplaceRules()
    }

    public func clearTextReplaceRules(bookUrl: String) {
        textReplaceRulesMap[bookUrl] = nil
        saveTextReplaceRules()
    }

    private func saveTextReplaceRules() {
        if let data = try? JSONEncoder().encode(textReplaceRulesMap) {
            UserDefaults.standard.set(data, forKey: replaceRulesKey)
        }
    }

    public func addBookmark(_ bookmark: BookBookmark) {
        bookmarks.append(bookmark)
        saveBookmarks()
    }

    public func removeBookmark(_ bookmark: BookBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        saveBookmarks()
    }

    // MARK: - 书架分组
    @Published public var groups: [BookGroup] = []

    private func loadGroups() {
        if let data = UserDefaults.standard.data(forKey: groupsKey),
           let decoded = try? JSONDecoder().decode([BookGroup].self, from: data) {
            groups = decoded
        }
    }

    private func saveGroups() {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: groupsKey)
        }
    }

    @discardableResult
    public func addGroup(name: String) -> BookGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = BookGroup(name: trimmed.isEmpty ? "新分组" : trimmed)
        groups.append(group)
        saveGroups()
        return group
    }

    public func renameGroup(id: UUID, to name: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        groups[idx].name = trimmed
        saveGroups()
    }

    public func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        saveGroups()
        // 组内书回到未分组
        for i in 0..<bookshelf.count where bookshelf[i].groupId == id {
            bookshelf[i].groupId = nil
        }
        saveBookshelf()
    }

    /// 把书挪到某个分组（nil = 移出分组）
    public func assign(_ book: Book, toGroup groupId: UUID?) {
        guard let idx = bookshelf.firstIndex(where: { $0.bookUrl == book.bookUrl }) else { return }
        bookshelf[idx].groupId = groupId
        saveBookshelf()
    }

    public func books(inGroup groupId: UUID?) -> [Book] {
        guard let groupId else { return bookshelf }
        return bookshelf.filter { $0.groupId == groupId }
    }

    public func updateBookmarkNote(id: UUID, note: String) {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[idx].note = note
        saveBookmarks()
    }

    /// Documents 下的缓存目录；取不到时退回临时目录，这里不该成为崩溃点。
    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// 内置书源在 SPM 包里走 Bundle.module，装进 app 后走 Bundle.main。
    private var bundledSourcesURL: URL? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "bookSources", withExtension: "json") {
            return url
        }
        #endif
        return Bundle.main.url(forResource: "bookSources", withExtension: "json")
    }

    public func loadData() {
        if let stored = decode([BookSource].self, forKey: sourcesKey) {
            sources = stored
        }
        // 内置源每次都参与同步：本地为空整批灌入，非空只刷新规则，登录态由合并函数保住。
        loadBundledSources()
        if let stored = decode([Book].self, forKey: booksKey) {
            bookshelf = stored
        }
    }

    public func loadBundledSources(forceReset: Bool = false) {
        guard let url = bundledSourcesURL,
              let data = try? Data(contentsOf: url),
              let bundled = try? JSONDecoder().decode([BookSource].self, from: data) else {
            return
        }

        if forceReset || sources.isEmpty {
            sources = bundled
            saveSources()
            return
        }

        // 先把本地列表索引成字典：逐个内置源去线性扫本地表，条目一多就是 N×M。
        var offsetByUrl: [String: Int] = [:]
        var offsetByName: [String: Int] = [:]
        for (offset, source) in sources.enumerated() {
            offsetByUrl[source.bookSourceUrl] = offset
            offsetByName[source.bookSourceName] = offset
        }

        for incoming in bundled {
            // 先认 URL 再认书名：同一本书源换了域名时，靠书名把本地登录态接回来。
            let matched = offsetByUrl[incoming.bookSourceUrl] ?? offsetByName[incoming.bookSourceName]
            if let matched {
                sources[matched] = carryingLocalState(from: sources[matched], into: incoming)
            } else {
                sources.append(incoming)
            }
            // 新追加的条目也得进索引，否则后面同名的内置源会被重复插入。
            let offset = matched ?? (sources.count - 1)
            offsetByUrl[incoming.bookSourceUrl] = offset
            offsetByName[incoming.bookSourceName] = offset
        }
        saveSources()
    }

    /// 内置版本只负责规则；登录态、排序、启用开关是用户的，必须原样带过来。
    private func carryingLocalState(from local: BookSource, into bundled: BookSource) -> BookSource {
        var merged = bundled
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

    public func saveSources() {
        encode(sources, forKey: sourcesKey)
    }

    public func saveBookshelf() {
        encode(bookshelf, forKey: booksKey)
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Merges restored WebDAV books and sources into local storage
    /// 备份恢复的两种取向：合并保留本地进度/分组/封面；替换完全采用备份内容
    public enum RestoreMode {
        case merge
        case replace
    }

    public func restoreFromWebDAV(
        books: [Book]?,
        sources: [BookSource]?,
        mode: RestoreMode = .merge
    ) -> (booksAdded: Int, sourcesAdded: Int) {
        var addedBooks = 0
        var addedSources = 0

        if let backupBooks = books {
            for backup in backupBooks {
                guard let index = bookshelf.firstIndex(where: { $0.bookUrl == backup.bookUrl }) else {
                    bookshelf.append(backup)
                    addedBooks += 1
                    continue
                }
                bookshelf[index] = mode == .replace
                    ? backup
                    : adoptingProgress(from: backup, over: bookshelf[index])
            }
            saveBookshelf()
        }

        if let admitted = BookSourceGate.admitted(sources, appStore: AppEdition.isAppStoreClean) {
            var offsetByUrl: [String: Int] = [:]
            for (offset, local) in self.sources.enumerated() {
                offsetByUrl[local.bookSourceUrl] = offset
            }
            for incoming in admitted {
                if let offset = offsetByUrl[incoming.bookSourceUrl] {
                    self.sources[offset] = incoming
                } else {
                    self.sources.append(incoming)
                    offsetByUrl[incoming.bookSourceUrl] = self.sources.count - 1
                    addedSources += 1
                }
            }
            saveSources()
        }

        return (addedBooks, addedSources)
    }

    /// 合并恢复：备份只补本地缺的字段，阅读进度更旧的时候不往回倒。
    private func adoptingProgress(from backup: Book, over local: Book) -> Book {
        var result = backup
        if local.durChapterTime > result.durChapterTime {
            result.durChapterIndex = local.durChapterIndex
            result.durChapterTitle = local.durChapterTitle
            result.durChapterPos = local.durChapterPos
            result.durChapterTime = local.durChapterTime
        }
        if result.groupId == nil { result.groupId = local.groupId }
        if (result.coverUrl ?? "").isEmpty { result.coverUrl = local.coverUrl }
        return result
    }

    // MARK: - Book Management
    public func addBook(from searchResult: SearchBook) -> Book {
        if let existing = bookshelf.first(where: { $0.bookUrl == searchResult.bookUrl }) {
            AppLog.write("[书架] 加入网络书：已存在")
            return existing
        }

        let newBook = makeNetworkBook(from: searchResult)
        bookshelf.insert(newBook, at: 0)
        saveBookshelf()
        AppLog.write("[书架] 加入网络书：新增")
        return newBook
    }

    private func makeNetworkBook(from searchResult: SearchBook) -> Book {
        Book(
            bookUrl: searchResult.bookUrl,
            name: searchResult.name,
            author: searchResult.author,
            kind: searchResult.kind,
            coverUrl: searchResult.coverUrl,
            intro: searchResult.intro,
            origin: searchResult.origin,
            originName: searchResult.originName,
            latestChapterTitle: searchResult.latestChapterTitle
        )
    }

    /// 新书插到书架最前面并存盘。导入路径都走这里，免得每处重复「插入 + 保存」。
    private func prependToShelf(_ book: Book) {
        bookshelf.insert(book, at: 0)
        saveBookshelf()
    }

    /// 有就整条替换、没有就插到最前。EPUB / TXT 导入共用。
    private func upsertShelf(_ book: Book) {
        if let existing = bookshelf.firstIndex(where: { $0.bookUrl == book.bookUrl }) {
            bookshelf[existing] = book
            saveBookshelf()
        } else {
            prependToShelf(book)
        }
    }

    @discardableResult
    /// overwriteCover 为 true 时才用传入的封面覆盖本地封面。
    /// 刷新详情这类更新不传封面，不能覆盖用户自己设的封面。
    public func saveOrUpdateBook(_ book: Book, overwriteCover: Bool = false) -> Book {
        guard let index = bookshelf.firstIndex(where: { $0.bookUrl == book.bookUrl }) else {
            prependToShelf(book)
            return book
        }
        bookshelf[index] = mergingDetails(of: book, into: bookshelf[index], overwriteCover: overwriteCover)
        saveBookshelf()
        return bookshelf[index]
    }

    /// 详情刷新只补空字段，空值不覆盖已有内容。
    private func mergingDetails(of incoming: Book, into local: Book, overwriteCover: Bool) -> Book {
        var result = local
        if incoming.name.isEmpty == false {
            result.name = incoming.name
        }
        if incoming.author.isEmpty == false, incoming.author != "未知作者" {
            result.author = incoming.author
        }
        if overwriteCover {
            result.coverUrl = incoming.coverUrl
        } else if let cover = incoming.coverUrl, cover.isEmpty == false {
            result.coverUrl = cover
        }
        if let intro = incoming.intro, intro.isEmpty == false, intro.hasPrefix("源站：") == false {
            result.intro = intro
        }
        if let kind = incoming.kind, kind.isEmpty == false {
            result.kind = kind
        }
        if let wordCount = incoming.wordCount, wordCount.isEmpty == false {
            result.wordCount = wordCount
        }
        if let latest = incoming.latestChapterTitle, latest.isEmpty == false {
            result.latestChapterTitle = latest
        }
        if incoming.totalChapterNum > 0 {
            result.totalChapterNum = incoming.totalChapterNum
        }
        return result
    }

    public func removeBook(bookUrl: String) {
        AppLog.write("[书架] 删除书籍")
        bookshelf.removeAll { $0.bookUrl == bookUrl }
        saveBookshelf()
    }

    /// 换源：把阅读进度搬到新书源的同名书上，旧记录与旧目录缓存一并清掉。
    @discardableResult
    public func changeBookSource(from oldBook: Book, to newBook: Book) -> Book {
        AppLog.write("[书架] 更换书源")
        var target = newBook
        target.durChapterIndex = oldBook.durChapterIndex
        target.durChapterTitle = oldBook.durChapterTitle
        target.durChapterPos = oldBook.durChapterPos
        target.durChapterTime = oldBook.durChapterTime
        // 分组和用户设过的封面跟着书走，新源没封面时保留旧封面
        target.groupId = oldBook.groupId
        if (target.coverUrl ?? "").isEmpty, let oldCover = oldBook.coverUrl, !oldCover.isEmpty {
            target.coverUrl = oldCover
        }
        if target.bookUrl != oldBook.bookUrl {
            bookshelf.removeAll { $0.bookUrl == oldBook.bookUrl }
            chaptersCache.removeValue(forKey: oldBook.bookUrl)
        }
        if let index = bookshelf.firstIndex(where: { $0.bookUrl == target.bookUrl }) {
            bookshelf[index] = target
        } else {
            bookshelf.insert(target, at: 0)
        }
        saveBookshelf()
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
        saveBookshelf()

        // 本地进度已经落盘，WebDAV 只是副本：没配就跳过，失败也不回滚。
        let snapshot = bookshelf[index]
        let config = WebDAVService.shared.loadConfig()
        guard config.url.isEmpty == false, config.username.isEmpty == false else { return }
        Task {
            try? await WebDAVService.shared.uploadBookProgress(book: snapshot, config: config)
        }
    }

    /// 整架刷新：所有网络书并发拉详情，回来一条写一条，单本失败不影响其余。
    public func refreshAllBooks() async {
        let online = bookshelf.filter { $0.origin != "local" }
        guard online.isEmpty == false else { return }
        AppLog.write("[Bookshelf] 开始整架刷新，网络书 \(online.count) 本")

        await withTaskGroup(of: Book?.self) { group in
            for book in online {
                group.addTask { await self.refreshedDetail(of: book) }
            }
            for await refreshed in group {
                guard let refreshed else { continue }
                await MainActor.run { _ = self.saveOrUpdateBook(refreshed) }
            }
        }
        AppLog.write("[Bookshelf] ✅ 整架刷新完成")
    }

    /// 单本刷新。失败只记一条脱敏日志——书名不进日志，只留 md5 前缀。
    private func refreshedDetail(of book: Book) async -> Book? {
        guard let source = findSource(for: book) else { return nil }
        do {
            let (detail, chapters) = try await BookContentService.shared.fetchBookDetail(book: book, source: source)
            var refreshed = detail
            refreshed.totalChapterNum = chapters.count
            if let last = chapters.last {
                refreshed.latestChapterTitle = last.title
            }
            return refreshed
        } catch {
            let tag = String(CryptoUtils.md5(book.name).prefix(8))
            AppLog.write("[Bookshelf] ⚠️ 刷新失败 book#\(tag): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Source Management
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

    /// 只解析、不改仓库，供导入预览使用。
    public func planImportSources(json: String) throws -> [SourceImportEntry] {
        guard let data = json.data(using: .utf8) else { return [] }
        let imported = try JSONDecoder().decode([BookSource].self, from: data)

        var entries: [SourceImportEntry] = []
        var seenURLs = Set<String>()
        for source in imported where !source.bookSourceUrl.isEmpty {
            guard seenURLs.insert(source.bookSourceUrl).inserted else { continue }
            if let existing = sources.first(where: { $0.bookSourceUrl == source.bookSourceUrl }) {
                entries.append(SourceImportEntry(incoming: source, existing: existing, status: .update))
            } else if let sameName = sources.first(where: { $0.bookSourceName == source.bookSourceName }) {
                entries.append(SourceImportEntry(incoming: source, existing: sameName, status: .conflict))
            } else {
                entries.append(SourceImportEntry(incoming: source, existing: nil, status: .new))
            }
        }
        return entries
    }

    /// 应用已预览的导入计划。同名不同网址默认保留两边，勾选覆盖时按名字替换。
    @discardableResult
    public func applyImport(
        entries: [BookStore.SourceImportEntry],
        overwriteConflicts: Bool
    ) -> (added: Int, updated: Int, conflictsAdded: Int) {
        var added = 0
        var updated = 0
        var conflictsAdded = 0

        for entry in entries {
            switch entry.status {
            case .new:
                if !sources.contains(where: { $0.bookSourceUrl == entry.incoming.bookSourceUrl }) {
                    sources.append(entry.incoming)
                    added += 1
                }
            case .update:
                if let idx = sources.firstIndex(where: { $0.bookSourceUrl == entry.incoming.bookSourceUrl }) {
                    sources[idx] = entry.incoming
                    updated += 1
                }
            case .conflict:
                if overwriteConflicts,
                   let idx = sources.firstIndex(where: { $0.bookSourceUrl == entry.existing?.bookSourceUrl
                       || $0.bookSourceName == entry.incoming.bookSourceName }) {
                    sources[idx] = entry.incoming
                    updated += 1
                } else if !sources.contains(where: { $0.bookSourceUrl == entry.incoming.bookSourceUrl }) {
                    // 同名不同网址：名字后加标记，避免列表里两个同名源分不清。
                    var incoming = entry.incoming
                    if let existingName = entry.existing?.bookSourceName, existingName == incoming.bookSourceName {
                        incoming.bookSourceName += "（导入）"
                    }
                    sources.append(incoming)
                    conflictsAdded += 1
                }
            }
        }
        if added + updated + conflictsAdded > 0 { saveSources() }
        return (added, updated, conflictsAdded)
    }

    public func importSources(json: String) throws -> Int {
        guard let data = json.data(using: .utf8) else { return 0 }
        let imported = try JSONDecoder().decode([BookSource].self, from: data)

        var offsetByUrl: [String: Int] = [:]
        var offsetByName: [String: Int] = [:]
        for (offset, local) in sources.enumerated() {
            offsetByUrl[local.bookSourceUrl] = offset
            offsetByName[local.bookSourceName] = offset
        }

        for incoming in imported {
            // 同名但换了域名的源按书名认领，避免导入后列表里出现两条同名条目
            if let matched = offsetByUrl[incoming.bookSourceUrl] ?? offsetByName[incoming.bookSourceName] {
                sources[matched] = incoming
                offsetByUrl[incoming.bookSourceUrl] = matched
                offsetByName[incoming.bookSourceName] = matched
            } else {
                sources.append(incoming)
                offsetByUrl[incoming.bookSourceUrl] = sources.count - 1
                offsetByName[incoming.bookSourceName] = sources.count - 1
            }
        }
        saveSources()
        // 覆盖更新也算导入成功：只数新增的话，同一个文件导第二次会返回 0，
        // 界面就会误报「未在文件中发现有效书源」。
        return imported.count
    }

    public func toggleSource(sourceUrl: String) {
        guard let index = sources.firstIndex(where: { $0.bookSourceUrl == sourceUrl }) else { return }
        sources[index].enabled = !(sources[index].enabled ?? true)
        saveSources()
    }

    public func deleteSource(sourceUrl: String) {
        deleteSources(sourceUrls: [sourceUrl])
    }

    /// 批量删除：一次扫描、一次写盘、一次刷新。
    ///
    /// 逐条调 `deleteSource` 的话，删 500 条就会做 500 次「全表扫描 + 整张书源表
    /// 编码写进 UserDefaults + 发一次 @Published」，界面会卡住好一会儿。
    public func deleteSources(sourceUrls: Set<String>) {
        guard !sourceUrls.isEmpty else { return }
        sources.removeAll { sourceUrls.contains($0.bookSourceUrl) }
        saveSources()
    }

    /// 解析这本书所属的书源。
    ///
    /// 判定顺序与安卓一致：origin 精确匹配 → bookUrlPattern → 源名精确匹配 →
    /// 同域且路径相关。后缀模糊匹配只接受唯一候选，找不到就返回 nil；
    /// 以前兜底 `sources.first` 会把书串到完全无关的源上。
    public func findSource(for book: Book) -> BookSource? {
        BookSourceResolver.find(book: book, in: sources)
    }

    /// 搜索结果自身的来源：只按 origin / 源名 / bookUrlPattern 精确判定。
    /// 避免换源面板或搜索跳转把结果挂到另一个同站书源上。
    public func source(forSearchBook item: SearchBook) -> BookSource? {
        BookSourceResolver.find(searchBook: item, in: sources)
    }

    public func updateSource(originalSource: BookSource? = nil, newSource: BookSource) {
        let previousUrl = originalSource?.bookSourceUrl ?? newSource.bookSourceUrl
        let previousName = originalSource?.bookSourceName ?? newSource.bookSourceName
        let previousId = originalSource?.id ?? newSource.id

        if let index = sources.firstIndex(where: { $0.bookSourceUrl == previousUrl || $0.id == previousId }) {
            sources[index] = newSource
            saveSources()
        }

        // 书架上指向旧源的条目要跟着改，否则改完源名点开书就「找不到书源」。
        var touchedBookshelf = false
        for index in bookshelf.indices
        where bookshelf[index].origin == previousUrl || bookshelf[index].originName == previousName {
            bookshelf[index].origin = newSource.bookSourceUrl
            bookshelf[index].originName = newSource.bookSourceName
            touchedBookshelf = true
        }
        if touchedBookshelf {
            saveBookshelf()
        }
        SourceLoginService.shared.invalidate(sourceUrl: newSource.bookSourceUrl)
    }

    public func updateSource(_ source: BookSource) {
        let original = sources.first(where: { $0.id == source.id || $0.bookSourceUrl == source.bookSourceUrl })
        updateSource(originalSource: original, newSource: source)
    }

    /// 置顶书源。和书源列表里的「置顶」走同一条路，否则这里只挪位置、不写置顶状态。
    public func pinSource(sourceUrl: String) {
        setPinned(true, sourceUrl: sourceUrl)
    }

    /// 置顶 / 取消置顶。状态记在 `customOrder`（-1 = 置顶），
    /// 同时把条目挪到数组最前，让「默认顺序」也连续。
    public func setPinned(_ pinned: Bool, sourceUrl: String) {
        guard let idx = sources.firstIndex(where: { $0.bookSourceUrl == sourceUrl }) else { return }
        sources[idx].customOrder = pinned ? -1 : nil
        if pinned {
            let item = sources.remove(at: idx)
            sources.insert(item, at: 0)
        }
        saveSources()
    }

    public func isPinned(_ source: BookSource) -> Bool {
        (source.customOrder ?? 0) < 0
    }

    /// 改分组。传空串或 nil 为清掉分组
    public func setSourceGroup(sourceUrl: String, group: String?) {
        guard let idx = sources.firstIndex(where: { $0.bookSourceUrl == sourceUrl }) else { return }
        let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sources[idx].bookSourceGroup = trimmed.isEmpty ? nil : trimmed
        saveSources()
    }

    /// 按地址改一份书源再存回；找不到就什么都不做。
    private func mutateSource(_ sourceUrl: String, _ change: (inout BookSource) -> Void) {
        guard let idx = sources.firstIndex(where: { $0.bookSourceUrl == sourceUrl }) else { return }
        change(&sources[idx])
        saveSources()
    }

    public func updateSourceHeader(sourceUrl: String, header: String) {
        mutateSource(sourceUrl) { $0.loginHeader = header }
    }

    /// 表单登录：跑 loginUrl，再跑 loginUi 里挑出来的登录按钮 action。
    public func performLogin(source: BookSource, credentials: [String: String]) async throws -> String {
        try await runLoginFlow(source: source,
                               credentials: credentials,
                               actions: Self.loginButtonActions(from: source.loginUi),
                               requireCredentials: true)
    }

    /// 跑 `loginUi` 里某个按钮的 action。
    /// 登录面板每个按钮各带一段脚本（登录 / 注册 / 番茄登录 / 切换服务器 / 检测登录）。
    public func runLoginAction(source: BookSource, credentials: [String: String], action: String) async throws -> String {
        let header = try await runLoginFlow(source: source,
                                            credentials: credentials,
                                            actions: [action],
                                            // 非登录按钮（检测、切换服务器）不产出凭据，不算失败
                                            requireCredentials: false)
        // 退出登录只清 cookie，宿主这边的登录态一起清
        let lower = action.lowercased()
        if lower.hasPrefix("logout") || lower.contains("logout(") {
            await MainActor.run { logoutSource(sourceUrl: source.bookSourceUrl) }
        }
        return header
    }

    private func runLoginFlow(
        source: BookSource,
        credentials: [String: String],
        actions: [String],
        requireCredentials: Bool
    ) async throws -> String {
        // 面板手里的 source 是打开面板那一刻的快照，脚本上一轮改过的 variable（当前服务器、
        // 设置中心结果、token）不在里面。每一步都取仓库里最新的一份，否则「切换服务器」
        // 永远从同一个旧值算下一台。
        let source = await MainActor.run {
            BookStore.shared.sources.first { $0.bookSourceUrl == source.bookSourceUrl } ?? source
        }
        guard let loginScript = source.loginUrl, !loginScript.isEmpty else {
            throw NSError(domain: "BookStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "这个源没有登录脚本。"])
        }

        let credData = (try? JSONSerialization.data(withJSONObject: credentials)) ?? Data()
        let credJson = String(data: credData, encoding: .utf8) ?? "{}"

        var updatedSource = source
        updatedSource.loginInfo = credJson

        let jsEngine = JSEngine(bookSource: updatedSource, baseUrl: source.bookSourceUrl)

        var capturedHeader: String? = nil
        jsEngine.onLoginHeaderUpdated = { newH in
            capturedHeader = newH
        }
        var capturedLoginInfo: String? = nil
        jsEngine.onLoginInfoUpdated = { newInfo in
            capturedLoginInfo = newInfo
        }

        // 跑脚本前清掉「最近写入的 host」，只认这一次登录写的 cookie
        CookieJar.shared.resetLastWrite()

        // 表单值要注入脚本里的 result，源脚本靠 result['邮箱'] 这类取值
        _ = jsEngine.eval(script: JSEngine.unwrapJsScript(loginScript), result: credentials)

        // 很多书源的 loginUrl 只定义函数，真正触发登录的是按钮 action，
        // 例如 {"type":"button","action":"login(true)"}。
        if capturedHeader?.isEmpty ?? true {
            for action in actions {
                _ = jsEngine.eval(script: JSEngine.unwrapJsScript(action), result: credentials)
                if let header = capturedHeader, !header.isEmpty { break }
            }
        }

        // 脚本自己改写过的登录信息（聚合源把 token 存这儿）要落盘：登录失败时脚本
        // 也会删掉过期 token 再写回，跟着存才对。
        if let scriptLoginInfo = capturedLoginInfo {
            await MainActor.run {
                if let idx = sources.firstIndex(where: { $0.bookSourceUrl == source.bookSourceUrl }) {
                    sources[idx].loginInfo = scriptLoginInfo
                    saveSources()
                }
            }
        }

        var finalHeader = capturedHeader ?? updatedSource.loginHeader
        if finalHeader?.isEmpty ?? true {
            // 有些脚本（例：大灰狼聚合）只把 token 写进 cookie，从不调 putLoginHeader。
            // 这里给 cookie 兜底，否则脚本跑通了照样判失败。
            let jarCookies = CookieJar.shared.cookieString(for: source.bookSourceUrl)
            if !jarCookies.isEmpty {
                finalHeader = "Cookie: \(jarCookies)"
            } else if let hostKey = CookieJar.shared.lastWrittenHostKey {
                // bookSourceUrl 不是域名时（「大灰狼融合VIP5.0」这种），按它查 cookie 必然查不到。
                // 脚本刚把 cookie 写在了真实 host 上，用那个 host 再查一次。
                let hostCookies = CookieJar.shared.cookieString(for: hostKey)
                if !hostCookies.isEmpty {
                    finalHeader = "Cookie: \(hostCookies)"
                }
            }
        }

        guard let resolvedHeader = finalHeader, !resolvedHeader.isEmpty else {
            if !requireCredentials {
                // 非登录按钮：脚本没产出凭据是正常的，把脚本错误（如果有）捎回去就行
                if let err = jsEngine.lastError { throw NSError(domain: "BookStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "脚本报错：\(err)"]) }
                return ""
            }
            let detail = jsEngine.lastError.map { "（脚本报错：\($0)）" } ?? ""
            throw NSError(domain: "BookStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "登录未返回有效凭据，请检查账号密码\(detail)"])
        }

        // 取成不可变值再进并发闭包，别在闭包里读被脚本回调改写的 var
        let resolvedLoginInfo = capturedLoginInfo ?? credJson
        await MainActor.run {
            if let idx = sources.firstIndex(where: { $0.bookSourceUrl == source.bookSourceUrl }) {
                sources[idx].loginInfo = resolvedLoginInfo
                sources[idx].loginHeader = resolvedHeader
                saveSources()
            }
        }
        SourceLoginService.shared.invalidate(sourceUrl: source.bookSourceUrl)

        return resolvedHeader
    }

    /// 从 loginUi 里挑出真正「触发登录」的按钮 action。
    /// 跳过注册、退出、切服务器、番茄网页登录、检测、清设备这些会改状态或弹浏览器的按钮。
    static func loginButtonActions(from loginUi: String?) -> [String] {
        guard let loginUi,
              let data = loginUi.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var actions: [String] = []
        for item in items {
            guard (item["type"] as? String) == "button" else { continue }
            let name = (item["name"] as? String) ?? ""
            let action = ((item["action"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !action.isEmpty else { continue }

            let lower = action.lowercased()
            if name.contains("退出") || lower.hasPrefix("logout") { continue }
            if name.contains("注册") || lower.hasPrefix("register") { continue }
            if lower.hasPrefix("fq_login")
                || lower.hasPrefix("loginqt")
                || lower.hasPrefix("checkstatus")
                || lower.hasPrefix("cleardevice")
                || lower.hasPrefix("set_server")
                || lower.hasPrefix("vip")
                || lower.hasPrefix("api") { continue }

            if lower.hasPrefix("login") || name.contains("登录") || name.contains("登陆") {
                actions.append(action)
            }
        }
        return actions
    }

    public func logoutSource(sourceUrl: String) {
        mutateSource(sourceUrl) {
            $0.loginHeader = nil
            $0.loginInfo = nil
        }
        CookieJar.shared.remove(for: sourceUrl)
        if let host = CookieJar.shared.lastWrittenHostKey, !host.isEmpty {
            CookieJar.shared.remove(for: host)
        }
        SourceLoginService.shared.invalidate(sourceUrl: sourceUrl)
    }

    // MARK: - EPUB & Chapter Storage
    private var chaptersCache: [String: [BookChapter]] = [:]

    /// 目录落盘文件名按书地址的 md5 取，避免书名里有斜杠或冒号。
    private func chapterFileURL(for bookUrl: String) -> URL {
        getDocumentsDirectory()
            .appendingPathComponent("chapters_\(CryptoUtils.md5(bookUrl)).json")
    }

    public func saveChapters(_ chapters: [BookChapter], for bookUrl: String) {
        chaptersCache[bookUrl] = chapters
        guard let data = try? JSONEncoder().encode(chapters) else { return }
        try? data.write(to: chapterFileURL(for: bookUrl))
    }

    public func getChapters(for bookUrl: String) -> [BookChapter] {
        if let memory = chaptersCache[bookUrl] {
            return memory
        }
        let chapterFile = chapterFileURL(for: bookUrl)
        if let data = try? Data(contentsOf: chapterFile),
           var list = try? JSONDecoder().decode([BookChapter].self, from: data) {
            var needsRepair = false
            for i in 0..<list.count {
                if list[i].index != i {
                    list[i].index = i
                    needsRepair = true
                }
                if list[i].url.contains("%23") {
                    list[i].url = list[i].url.replacingOccurrences(of: "%23", with: "#")
                    needsRepair = true
                }
            }
            if needsRepair {
                saveChapters(list, for: bookUrl)
            }
            chaptersCache[bookUrl] = list
            return list
        }
        return []
    }

    public func importEpub(from fileUrl: URL) throws -> Book {
        let parsed = try EpubParser.shared.parse(epubUrl: fileUrl)
        saveChapters(parsed.chapters, for: parsed.book.bookUrl)
        upsertShelf(parsed.book)
        return parsed.book
    }

    /// TXT 编码没有统一约定：先按 UTF-8 试，再按 GB18030（老小说站主流），
    /// 最后按 UTF-8 容错解，保证任何字节都能出文本。
    private func decodeTxt(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let gbRaw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let legacy = String(data: data, encoding: String.Encoding(rawValue: gbRaw)) { return legacy }
        return String(decoding: data, as: UTF8.self)
    }

    public func importTxt(from fileUrl: URL) throws -> Book {
        guard let data = try? Data(contentsOf: fileUrl) else {
            throw NSError(domain: "BookStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取TXT文件内容"])
        }
        let content = decodeTxt(data)

        let bookTitle = fileUrl.deletingPathExtension().lastPathComponent
        let bookUrl = "txt://\(CryptoUtils.md5(fileUrl.absoluteString))"
        let bookId = CryptoUtils.md5(bookUrl)

        let docsDir = getDocumentsDirectory()
        let txtBookDir = docsDir.appendingPathComponent("Books/TXT/\(bookId)")
        try? FileManager.default.createDirectory(at: txtBookDir, withIntermediateDirectories: true)

        let pattern = "(?m)^\\s*(第[0-9一二三四五六七八九十百千]+[章回节卷].*)$"
        let regex = try? NSRegularExpression(pattern: pattern)
        let nsString = content as NSString
        let matches = regex?.matches(in: content, range: NSRange(location: 0, length: nsString.length)) ?? []

        var chapters: [BookChapter] = []

        if matches.isEmpty {
            let chFile = txtBookDir.appendingPathComponent("chapter_0.txt")
            try? content.write(to: chFile, atomically: true, encoding: .utf8)
            chapters.append(BookChapter(
                bookUrl: bookUrl,
                url: chFile.absoluteString,
                title: bookTitle,
                index: 0
            ))
        } else {
            for i in 0..<matches.count {
                let match = matches[i]
                let title = nsString.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                let startPos = match.range.location
                let endPos = (i + 1 < matches.count) ? matches[i + 1].range.location : nsString.length
                let chapterText = nsString.substring(with: NSRange(location: startPos, length: endPos - startPos))

                let chFile = txtBookDir.appendingPathComponent("chapter_\(i).txt")
                try? chapterText.write(to: chFile, atomically: true, encoding: .utf8)

                chapters.append(BookChapter(
                    bookUrl: bookUrl,
                    url: chFile.absoluteString,
                    title: title,
                    index: i
                ))
            }
        }

        let book = Book(
            bookUrl: bookUrl,
            name: bookTitle,
            author: "本地书籍",
            kind: "TXT 本地书籍",
            // 本地书没有封面；简介用固定文案，详情页不显示空行
            coverUrl: nil,
            intro: "本地导入的TXT小说",
            // 来源标记本地，详情页据此隐藏「换源」
            origin: "local",
            // 显示名走本地导入，目录由 TXT 切章自己生成
            originName: "本地导入",
            tocUrl: "",
            totalChapterNum: chapters.count
        )

        saveChapters(chapters, for: bookUrl)
        upsertShelf(book)
        return book
    }

    public func importFile(from fileUrl: URL) throws -> Book {
        let ext = fileUrl.pathExtension.lowercased()
        AppLog.write("[导入] 开始 type=\(ext.isEmpty ? "?" : ext)")
        switch ext {
        case "txt":
            return try importTxt(from: fileUrl)
        case "zip", "cbz":
            return try importComic(from: fileUrl)
        case "pdf":
            return try importPDF(from: fileUrl)
        default:
            return try importEpub(from: fileUrl)
        }
    }
}

// MARK: - 阅读统计
/// 阅读时长 / 字数 / 章节数，按天存，用来算连续天数
public final class ReadingStatsStore: ObservableObject {
    public static let shared = ReadingStatsStore()

    public struct Snapshot: Codable {
        public var dailySeconds: [String: Int] = [:]
        public var totalCharacters: Int = 0
        public var chaptersRead: Int = 0
    }

    @Published public private(set) var snapshot = Snapshot()

    private let key = "reading_stats_v1"
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func key(for date: Date) -> String { dayFormatter.string(from: date) }

    /// 记一段阅读：秒数 + 这次新读到的字数
    public func addReading(seconds: Int, characters: Int = 0, chapters: Int = 0) {
        guard seconds > 0 || characters > 0 || chapters > 0 else { return }
        if seconds > 0 {
            let k = key(for: Date())
            snapshot.dailySeconds[k, default: 0] += seconds
        }
        snapshot.totalCharacters += max(0, characters)
        snapshot.chaptersRead += max(0, chapters)
        save()
    }

    public var todaySeconds: Int { snapshot.dailySeconds[key(for: Date())] ?? 0 }
    public var totalSeconds: Int { snapshot.dailySeconds.values.reduce(0, +) }
    public var totalCharacters: Int { snapshot.totalCharacters }
    public var chaptersRead: Int { snapshot.chaptersRead }
    public var daysRead: Int { snapshot.dailySeconds.filter { $0.value > 0 }.count }

    /// 连续阅读天数：从今天往回数
    public var streakDays: Int {
        var streak = 0
        var date = Date()
        while true {
            let k = key(for: date)
            if (snapshot.dailySeconds[k] ?? 0) > 0 {
                streak += 1
                date = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
            } else if streak == 0 {
                // 今天还没读，从昨天开始数
                date = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
                if (snapshot.dailySeconds[key(for: date)] ?? 0) == 0 { break }
            } else {
                break
            }
            if streak > 3650 { break }
        }
        return streak
    }

    /// 最近 n 天，从早到晚
    public func recentDays(_ n: Int = 7) -> [(day: String, seconds: Int)] {
        var out: [(String, Int)] = []
        for offset in stride(from: n - 1, through: 0, by: -1) {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let k = key(for: date)
            out.append((k, snapshot.dailySeconds[k] ?? 0))
        }
        return out
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

/// 批量缓存章节：一次排队一批，能暂停/继续/取消，进度看得见
public final class ChapterDownloadManager: ObservableObject {
    public static let shared = ChapterDownloadManager()

    @Published public private(set) var jobs: [DownloadJob] = []

    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    /// indices：要下载的章节下标（对应 chapters 数组）
    @discardableResult
    public func start(book: Book, chapters: [BookChapter], source: BookSource?, indices: [Int]) -> UUID? {
        guard !indices.isEmpty else { return nil }
        let job = DownloadJob(bookUrl: book.bookUrl, bookName: book.name, total: indices.count)
        let jobId = job.id
        jobs.insert(job, at: 0)

        tasks[jobId] = Task { [weak self] in
            for index in indices {
                guard let self else { return }
                // 暂停原地等，取消就退出
                while true {
                    let state = await self.jobState(jobId)
                    if state == nil || state == .cancelled { return }
                    if state == .running { break }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }

                guard index >= 0, index < chapters.count else { continue }
                let chapter = chapters[index]
                if BookContentService.shared.hasCachedChapter(bookUrl: book.bookUrl, chapterIndex: chapter.index) {
                    // 已缓存的章也顺手补评论：上次缓存时开关可能还没开
                    if ReviewCache.enabled,
                       let cached = BookContentService.shared.getCachedChapterContent(bookUrl: book.bookUrl, chapterIndex: chapter.index) {
                        await ReviewCache.prefetchComments(inContent: cached)
                    }
                    await self.mark(jobId, finished: 1)
                } else {
                    await self.setCurrentChapter(jobId, chapter.title)
                    do {
                        let content = try await BookContentService.shared.fetchChapterContent(chapter: chapter, source: source, book: book)
                        // 书评一起缓存（可选）：只在抓到正文后补评论首页，别抢正文的带宽
                        if ReviewCache.enabled, !content.isEmpty {
                            await ReviewCache.prefetchComments(inContent: content)
                        }
                        await self.mark(jobId, finished: 1)
                    } catch {
                        await self.mark(jobId, failed: 1)
                    }
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            await self?.finish(jobId)
        }
        return jobId
    }

    enum JobState { case running, paused, cancelled }

    @MainActor private func jobState(_ id: UUID) -> JobState? {
        guard let job = jobs.first(where: { $0.id == id }) else { return nil }
        if job.isCancelled { return .cancelled }
        return job.isPaused ? .paused : .running
    }

    @MainActor private func setCurrentChapter(_ id: UUID, _ title: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].currentChapter = title
    }

    @MainActor private func mark(_ id: UUID, finished: Int = 0, failed: Int = 0) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].finished += finished
        jobs[i].failed += failed
    }

    @MainActor private func finish(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].isRunning = false
        jobs[i].currentChapter = ""
    }

    public func pause(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].isPaused = true
    }

    public func resume(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].isPaused = false
    }

    public func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].isCancelled = true
        jobs[i].isRunning = false
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    public func clearFinished() {
        jobs.removeAll { !$0.isRunning }
    }
}

// MARK: - OPDS 书库配置
public final class OPDSStore: ObservableObject {
    public static let shared = OPDSStore()

    @Published public var catalogs: [OPDSCatalog] = []

    private let key = "opds_catalogs_v1"

    public init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([OPDSCatalog].self, from: data) {
            catalogs = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(catalogs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public func add(name: String, url: String, username: String, password: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        catalogs.append(OPDSCatalog(name: name.trimmingCharacters(in: .whitespacesAndNewlines), url: trimmed, username: username, password: password))
        save()
        AppLog.write("[OPDS] 新增书库 \(catalogs.count) 个")
    }

    public func remove(_ catalog: OPDSCatalog) {
        catalogs.removeAll { $0.id == catalog.id }
        save()
        AppLog.write("[OPDS] 删除书库 \(catalogs.count) 个")
    }
}

// MARK: - 漫画（cbz / zip）与 PDF 导入
public extension BookStore {

    /// cbz / zip 漫画：解包出图片，按自然顺序一页一章
    @discardableResult
    func importComic(from fileUrl: URL) throws -> Book {
        guard let archive = Archive(url: fileUrl, accessMode: .read) else {
            throw NSError(domain: "Legado", code: 1, userInfo: [NSLocalizedDescriptionKey: "打不开这个压缩包"])
        }
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp"]
        var entries: [Entry] = []
        for entry in archive where imageExts.contains((entry.path as NSString).pathExtension.lowercased()) {
            entries.append(entry)
        }
        guard !entries.isEmpty else {
            throw NSError(domain: "Legado", code: 2, userInfo: [NSLocalizedDescriptionKey: "包里没有图片"])
        }
        entries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        let bookUrl = "comic://" + CryptoUtils.md5(fileUrl.absoluteString)
        let dir = getDocumentsDirectory().appendingPathComponent("Books/Comics/\(CryptoUtils.md5(bookUrl))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var chapters: [BookChapter] = []
        for (index, entry) in entries.enumerated() {
            let ext = (entry.path as NSString).pathExtension.lowercased()
            let dest = dir.appendingPathComponent(String(format: "page-%04d.%@", index + 1, ext))
            if !FileManager.default.fileExists(atPath: dest.path) {
                _ = try? archive.extract(entry, consumer: { data in
                    try? data.write(to: dest)
                })
            }
            let title = String(format: "第 %d 页", index + 1)
            chapters.append(BookChapter(bookUrl: bookUrl, url: "imgpage://" + dest.path, title: title, index: index))
        }

        let name = fileUrl.deletingPathExtension().lastPathComponent
        let book = Book(bookUrl: bookUrl, name: name, author: "", intro: "", origin: "local", originName: "本地漫画", tocUrl: "", latestChapterTitle: chapters.last?.title, totalChapterNum: chapters.count)
        saveChapters(chapters, for: bookUrl)
        upsertShelf(book)
        return book
    }

    /// PDF：每页渲染成图片，一页一章
    @discardableResult
    func importPDF(from fileUrl: URL) throws -> Book {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: fileUrl) else {
            throw NSError(domain: "Legado", code: 3, userInfo: [NSLocalizedDescriptionKey: "打不开这个 PDF"])
        }
        let bookUrl = "pdf://" + CryptoUtils.md5(fileUrl.absoluteString)
        let dir = getDocumentsDirectory().appendingPathComponent("Books/PDF/\(CryptoUtils.md5(bookUrl))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var chapters: [BookChapter] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let dest = dir.appendingPathComponent(String(format: "page-%04d.png", index + 1))
            if !FileManager.default.fileExists(atPath: dest.path) {
                let bounds = page.bounds(for: .mediaBox)
                let scale: CGFloat = 2
                let width = max(1, Int(bounds.width * scale))
                let height = max(1, Int(bounds.height * scale))
                guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { continue }
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
                guard let cgImage = ctx.makeImage(),
                      let out = CGImageDestinationCreateWithURL(dest as CFURL, "public.png" as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(out, cgImage, nil)
                CGImageDestinationFinalize(out)
            }
            chapters.append(BookChapter(bookUrl: bookUrl, url: "imgpage://" + dest.path, title: String(format: "第 %d 页", index + 1), index: index))
        }
        guard !chapters.isEmpty else {
            throw NSError(domain: "Legado", code: 4, userInfo: [NSLocalizedDescriptionKey: "PDF 没渲染出页面"])
        }

        let name = fileUrl.deletingPathExtension().lastPathComponent
        let book = Book(bookUrl: bookUrl, name: name, author: "", intro: "", origin: "local", originName: "本地 PDF", tocUrl: "", latestChapterTitle: chapters.last?.title, totalChapterNum: chapters.count)
        saveChapters(chapters, for: bookUrl)
        upsertShelf(book)
        return book
        #else
        throw NSError(domain: "Legado", code: 5, userInfo: [NSLocalizedDescriptionKey: "这个平台不支持 PDF"])
        #endif
    }
}

// MARK: - 书评缓存（段评 / 本章说 / 热评首页）

/// 评论接口的 JSON 落盘：书源没登录、断网时，之前抓过的评论还能翻。
/// 开关 `reader_cache_reviews`（设置 → 存储），默认关；只在缓存章节时顺手抓首页。
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

    /// 评论面板抓到内容就存；开关关掉时不写盘，读还是照读（老缓存别丢）
    public static func store(_ data: Data, for url: URL) {
        guard enabled, !data.isEmpty else { return }
        try? data.write(to: file(for: url), options: .atomic)
    }

    public static func load(for url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: file(for: url).path) else { return nil }
        return try? Data(contentsOf: file(for: url))
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

    /// 评论接口地址：跟阅读页评论面板同一套拼法（/para_review + hot=1 + 首页无 cursor）
    public static func apiURL(fromRaw raw: String, mode: String = "chapter") -> URL? {
        guard var components = URLComponents(string: raw) else { return nil }
        let query = components.queryItems ?? []
        let para = query.first(where: { $0.name == "para" || $0.name == "paragraph_id" })?.value ?? "0"
        components.path = "/para_review"
        components.queryItems = [
            URLQueryItem(name: "book_id", value: query.first(where: { $0.name == "book_id" })?.value ?? ""),
            URLQueryItem(name: "item_id", value: query.first(where: { $0.name == "item_id" })?.value ?? ""),
            URLQueryItem(name: "item_version", value: query.first(where: { $0.name == "item_version" })?.value ?? ""),
            URLQueryItem(name: "para", value: para),
            URLQueryItem(name: "source", value: query.first(where: { $0.name == "source" })?.value ?? "番茄"),
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "hot", value: "1")
        ]
        return components.url
    }

    /// 正文里的评论哨兵：段评（C）带地址和条数，本章说（H）只带地址。
    /// 神评论（G）正文和插图都在哨兵里，不需要再请求。
    public static func commentTargets(inContent content: String, limit: Int) -> [(raw: String, mode: String)] {
        var candidates: [(String, String)] = []
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let rx = try? NSRegularExpression(pattern: "\u{E000}C\u{1F}\\d+\u{1F}([^\u{E001}]*)\u{E001}") {
            for match in rx.matches(in: content, range: range) {
                let raw = ns.substring(with: match.range(at: 1))
                if !raw.isEmpty { candidates.append((raw, "paragraph")) }
            }
        }
        if let rx = try? NSRegularExpression(pattern: "\u{E000}H\u{1F}([^\u{E001}]*)\u{E001}") {
            for match in rx.matches(in: content, range: range) {
                let raw = ns.substring(with: match.range(at: 1))
                if !raw.isEmpty { candidates.append((raw, "chapter")) }
            }
        }
        var seen = Set<String>()
        var result: [(raw: String, mode: String)] = []
        for item in candidates where seen.insert(item.0).inserted {
            result.append((raw: item.0, mode: item.1))
            if result.count >= limit { break }
        }
        return result
    }

    /// 缓存章节时顺手抓评论首页。一条失败不影响其它，正文缓存才是主目标。
    public static func prefetchComments(inContent content: String, limit: Int = 3) async {
        guard enabled, !content.isEmpty else { return }
        let targets = commentTargets(inContent: content, limit: limit)
        guard !targets.isEmpty else { return }
        var saved = 0
        for target in targets {
            guard let api = apiURL(fromRaw: target.raw, mode: target.mode) else { continue }
            if hasCache(for: api) { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: api)
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["data"] != nil else { continue }
                try? data.write(to: file(for: api), options: .atomic)
                saved += 1
            } catch {
                continue
            }
        }
        AppLog.write("[书评] 缓存评论 \(saved)/\(targets.count) 条 · 抓取上限 \(limit)")
    }
}
