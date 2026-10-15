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

    private let booksKey = "legado_bookshelf_v1"
    private let sourcesKey = "legado_sources_v1"
    private let bookmarksKey = "legado_bookmarks_v1"
    private let groupsKey = "legado_book_groups_v1"

    /// 书签 / 笔记：按书存，读取时按书过滤
    @Published public var bookmarks: [BookBookmark] = []

    public init() {
        loadData()
        loadBookmarks()
        loadGroups()
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

    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func getBundledSourcesUrl() -> URL? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "bookSources", withExtension: "json") {
            return url
        }
        #endif
        if let url = Bundle.main.url(forResource: "bookSources", withExtension: "json") {
            return url
        }
        return nil
    }

    public func loadData() {
        // Load sources
        if let data = UserDefaults.standard.data(forKey: sourcesKey),
           let decoded = try? JSONDecoder().decode([BookSource].self, from: data) {
            self.sources = decoded
        }

        // Merge or populate bundled default sources
        loadBundledSources()

        // Load bookshelf
        if let data = UserDefaults.standard.data(forKey: booksKey),
           let decoded = try? JSONDecoder().decode([Book].self, from: data) {
            self.bookshelf = decoded
        }

    }

    public func loadBundledSources(forceReset: Bool = false) {
        guard let url = getBundledSourcesUrl(),
              let data = try? Data(contentsOf: url),
              let defaultSources = try? JSONDecoder().decode([BookSource].self, from: data) else {
            return
        }

        if forceReset || sources.isEmpty {
            sources = defaultSources
            saveSources()
            return
        }

        var didChange = false
        for s in defaultSources {
            // Match existing source by URL or name
            if let idx = sources.firstIndex(where: {
                $0.bookSourceUrl == s.bookSourceUrl ||
                $0.bookSourceName == s.bookSourceName
            }) {
                // Update rules and configuration from bundled version while preserving user login state and toggles
                var updated = s
                updated.loginHeader = sources[idx].loginHeader
                updated.loginInfo = sources[idx].loginInfo
                if let customOrder = sources[idx].customOrder {
                    updated.customOrder = customOrder
                }
                if let enabled = sources[idx].enabled {
                    updated.enabled = enabled
                }
                sources[idx] = updated
                didChange = true
            } else if !sources.contains(where: { $0.bookSourceUrl == s.bookSourceUrl }) {
                sources.append(s)
                didChange = true
            }
        }
        if didChange {
            saveSources()
        }
    }

    public func saveSources() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: sourcesKey)
        }
    }

    public func saveBookshelf() {
        if let data = try? JSONEncoder().encode(bookshelf) {
            UserDefaults.standard.set(data, forKey: booksKey)
        }
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
        var booksCount = 0
        var sourcesCount = 0

        if let newBooks = books {
            for b in newBooks {
                if let idx = bookshelf.firstIndex(where: { $0.bookUrl == b.bookUrl }) {
                    if mode == .replace {
                        bookshelf[idx] = b
                        continue
                    }
                    // 合并：整条替换会把用户侧的东西冲掉，所以逐项来
                    var merged = b
                    let existing = bookshelf[idx]
                    // 远端备份比本地旧时，别把阅读进度倒退回去
                    if existing.durChapterTime > merged.durChapterTime {
                        merged.durChapterIndex = existing.durChapterIndex
                        merged.durChapterTitle = existing.durChapterTitle
                        merged.durChapterPos = existing.durChapterPos
                        merged.durChapterTime = existing.durChapterTime
                    }
                    if merged.groupId == nil { merged.groupId = existing.groupId }
                    if (merged.coverUrl ?? "").isEmpty { merged.coverUrl = existing.coverUrl }
                    bookshelf[idx] = merged
                } else {
                    bookshelf.append(b)
                    booksCount += 1
                }
            }
            saveBookshelf()
        }

        if let newSources = sources {
            for s in newSources {
                if let idx = self.sources.firstIndex(where: { $0.bookSourceUrl == s.bookSourceUrl }) {
                    self.sources[idx] = s
                } else {
                    self.sources.append(s)
                    sourcesCount += 1
                }
            }
            saveSources()
        }

        return (booksCount, sourcesCount)
    }

    // MARK: - Book Management
    public func addBook(from searchResult: SearchBook) -> Book {
        if let existing = bookshelf.first(where: { $0.bookUrl == searchResult.bookUrl }) {
            return existing
        }

        let newBook = Book(
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
        bookshelf.insert(newBook, at: 0)
        saveBookshelf()
        return newBook
    }

    @discardableResult
    /// overwriteCover 只在「用户明确改了封面」时为 true：
    /// 平时不带封面去更新（比如刷新详情）不该把用户自己设的封面冲掉。
    public func saveOrUpdateBook(_ book: Book, overwriteCover: Bool = false) -> Book {
        if let index = bookshelf.firstIndex(where: { $0.bookUrl == book.bookUrl }) {
            var existing = bookshelf[index]
            if !book.name.isEmpty { existing.name = book.name }
            if !book.author.isEmpty && book.author != "未知作者" { existing.author = book.author }
            if overwriteCover {
                existing.coverUrl = book.coverUrl
            } else if let cover = book.coverUrl, !cover.isEmpty {
                existing.coverUrl = cover
            }
            if let intro = book.intro, !intro.isEmpty, !intro.hasPrefix("源站：") { existing.intro = intro }
            if let kind = book.kind, !kind.isEmpty { existing.kind = kind }
            if let wordCount = book.wordCount, !wordCount.isEmpty { existing.wordCount = wordCount }
            if let latest = book.latestChapterTitle, !latest.isEmpty { existing.latestChapterTitle = latest }
            if book.totalChapterNum > 0 { existing.totalChapterNum = book.totalChapterNum }
            bookshelf[index] = existing
            saveBookshelf()
            return existing
        } else {
            bookshelf.insert(book, at: 0)
            saveBookshelf()
            return book
        }
    }

    public func removeBook(bookUrl: String) {
        bookshelf.removeAll { $0.bookUrl == bookUrl }
        saveBookshelf()
    }

    /// 换源：把阅读进度搬到新书源的同名书上，旧记录与旧目录缓存一并清掉。
    @discardableResult
    public func changeBookSource(from oldBook: Book, to newBook: Book) -> Book {
        var target = newBook
        target.durChapterIndex = oldBook.durChapterIndex
        target.durChapterTitle = oldBook.durChapterTitle
        target.durChapterPos = oldBook.durChapterPos
        target.durChapterTime = oldBook.durChapterTime
        // 用户侧的东西要跟着走：分了组、自己设过封面（新源没给封面时别把它冲掉）
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
        if let index = bookshelf.firstIndex(where: { $0.bookUrl == bookUrl }) {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            bookshelf[index].durChapterIndex = chapterIndex
            bookshelf[index].durChapterPos = chapterPos
            bookshelf[index].durChapterTitle = chapterTitle
            bookshelf[index].durChapterTime = now
            bookshelf[index].lastCheckTime = now
            saveBookshelf()

            // Asynchronously sync progress to WebDAV if configured
            let updatedBook = bookshelf[index]
            let config = WebDAVService.shared.loadConfig()
            if !config.url.isEmpty && !config.username.isEmpty {
                Task {
                    try? await WebDAVService.shared.uploadBookProgress(book: updatedBook, config: config)
                }
            }
        }
    }

    /// Refreshes all network books on the bookshelf concurrently
    public func refreshAllBooks() async {
        let networkBooks = bookshelf.filter { $0.origin != "local" }
        guard !networkBooks.isEmpty else { return }

        AppLog.write("[Bookshelf] 开始整架刷新，网络书 \(networkBooks.count) 本")

        await withTaskGroup(of: Book?.self) { group in
            for book in networkBooks {
                group.addTask {
                    guard let source = self.findSource(for: book) else { return nil }

                    do {
                        let (detailedBook, chapters) = try await BookContentService.shared.fetchBookDetail(book: book, source: source)
                        var updated = detailedBook
                        updated.totalChapterNum = chapters.count
                        if let lastCh = chapters.last {
                            updated.latestChapterTitle = lastCh.title
                        }
                        return updated
                    } catch {
                        // 脱敏：书名不记原文，只留指纹
                        let tag = String(CryptoUtils.md5(book.name).prefix(8))
                        AppLog.write("[Bookshelf] ⚠️ 刷新失败 book#\(tag): \(error.localizedDescription)")
                        return nil
                    }
                }
            }

            for await result in group {
                if let updatedBook = result {
                    _ = await MainActor.run {
                        self.saveOrUpdateBook(updatedBook)
                    }
                }
            }
        }
        AppLog.write("[Bookshelf] ✅ 整架刷新完成")
    }

    // MARK: - Source Management
    public func importSources(json: String) throws -> Int {
        guard let data = json.data(using: .utf8) else { return 0 }
        let imported = try JSONDecoder().decode([BookSource].self, from: data)

        for s in imported {
            if let idx = sources.firstIndex(where: { $0.bookSourceUrl == s.bookSourceUrl || $0.bookSourceName == s.bookSourceName }) {
                sources[idx] = s
            } else {
                sources.append(s)
            }
        }
        saveSources()
        // 已存在的书源是「覆盖更新」，也算导入成功。
        // 只返回新增数的话，第二次导入同一个文件会得到 0，
        // 界面那边就会误报「未在文件中发现有效书源」。
        return imported.count
    }

    public func toggleSource(sourceUrl: String) {
        if let idx = sources.firstIndex(where: { $0.bookSourceUrl == sourceUrl }) {
            var s = sources[idx]
            s.enabled = !(s.enabled ?? true)
            sources[idx] = s
            saveSources()
        }
    }

    public func deleteSource(sourceUrl: String) {
        sources.removeAll { $0.bookSourceUrl == sourceUrl }
        saveSources()
    }

    /// Robustly resolves the BookSource corresponding to a Book using URL, Name, Domain, or Aliases
    public func findSource(for book: Book) -> BookSource? {
        if book.origin == "local" || book.bookUrl.hasPrefix("file://") || book.bookUrl.hasPrefix("epub://") || book.bookUrl.hasPrefix("txt://") {
            return nil
        }

        // 1. Exact URL match
        if let s = sources.first(where: { $0.bookSourceUrl == book.origin }) {
            return s
        }

        // 2. Exact Name match
        if !book.originName.isEmpty, let s = sources.first(where: { $0.bookSourceName == book.originName }) {
            return s
        }

        // 3. Domain / Host Match
        let bookHost = URL(string: book.origin)?.host ?? URL(string: book.bookUrl)?.host ?? ""
        if !bookHost.isEmpty {
            for s in sources {
                let sHost = URL(string: s.bookSourceUrl)?.host ?? ""
                if !sHost.isEmpty && sHost == bookHost {
                    return s
                }
            }
        }

        // 4. Substring / URL contains matching
        if let s = sources.first(where: {
            book.origin.contains($0.bookSourceUrl) ||
            $0.bookSourceUrl.contains(book.origin) ||
            book.bookUrl.hasPrefix($0.bookSourceUrl) ||
            (!book.originName.isEmpty && $0.bookSourceName.contains(book.originName)) ||
            (!book.originName.isEmpty && book.originName.contains($0.bookSourceName))
        }) {
            return s
        }

        return sources.first
    }

    public func updateSource(originalSource: BookSource? = nil, newSource: BookSource) {
        let oldUrl = originalSource?.bookSourceUrl ?? newSource.bookSourceUrl
        let oldName = originalSource?.bookSourceName ?? newSource.bookSourceName

        if let idx = sources.firstIndex(where: { $0.bookSourceUrl == oldUrl || $0.id == (originalSource?.id ?? newSource.id) }) {
            sources[idx] = newSource
            saveSources()
        }

        // Synchronize all books on the bookshelf that referenced the old source name or URL
        var bookshelfModified = false
        for i in 0..<bookshelf.count {
            if bookshelf[i].origin == oldUrl ||
               bookshelf[i].originName == oldName {
                bookshelf[i].origin = newSource.bookSourceUrl
                bookshelf[i].originName = newSource.bookSourceName
                bookshelfModified = true
            }
        }
        if bookshelfModified {
            saveBookshelf()
        }
    }

    public func updateSource(_ source: BookSource) {
        let original = sources.first(where: { $0.id == source.id || $0.bookSourceUrl == source.bookSourceUrl })
        updateSource(originalSource: original, newSource: source)
    }

    public func pinSource(sourceUrl: String) {
        guard let idx = sources.firstIndex(where: { $0.bookSourceUrl == sourceUrl }) else { return }
        let item = sources.remove(at: idx)
        sources.insert(item, at: 0)
        saveSources()
    }

    public func updateSourceHeader(sourceUrl: String, header: String) {
        if let idx = sources.firstIndex(where: { $0.bookSourceUrl == sourceUrl }) {
            sources[idx].loginHeader = header
            saveSources()
        }
    }

    public func performLogin(source: BookSource, credentials: [String: String]) async throws -> String {
        guard let loginScript = source.loginUrl, !loginScript.isEmpty else {
            throw NSError(domain: "BookStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "该书源未配置登录脚本"])
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

        _ = jsEngine.eval(script: loginScript)

        guard let finalHeader = capturedHeader ?? updatedSource.loginHeader, !finalHeader.isEmpty else {
            throw NSError(domain: "BookStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "登录未返回有效凭据，请检查账号密码"])
        }

        await MainActor.run {
            if let idx = sources.firstIndex(where: { $0.bookSourceUrl == source.bookSourceUrl }) {
                sources[idx].loginInfo = credJson
                sources[idx].loginHeader = finalHeader
                saveSources()
            }
        }

        return finalHeader
    }

    public func logoutSource(sourceUrl: String) {
        if let idx = sources.firstIndex(where: { $0.bookSourceUrl == sourceUrl }) {
            sources[idx].loginHeader = nil
            sources[idx].loginInfo = nil
            saveSources()
        }
    }

    // MARK: - EPUB & Chapter Storage
    private var chaptersCache: [String: [BookChapter]] = [:]

    public func saveChapters(_ chapters: [BookChapter], for bookUrl: String) {
        chaptersCache[bookUrl] = chapters
        let chapterFile = getDocumentsDirectory().appendingPathComponent("chapters_\(CryptoUtils.md5(bookUrl)).json")
        if let data = try? JSONEncoder().encode(chapters) {
            try? data.write(to: chapterFile)
        }
    }

    public func getChapters(for bookUrl: String) -> [BookChapter] {
        if let memory = chaptersCache[bookUrl] {
            return memory
        }
        let chapterFile = getDocumentsDirectory().appendingPathComponent("chapters_\(CryptoUtils.md5(bookUrl)).json")
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
        if let idx = bookshelf.firstIndex(where: { $0.bookUrl == parsed.book.bookUrl }) {
            bookshelf[idx] = parsed.book
        } else {
            bookshelf.insert(parsed.book, at: 0)
        }
        saveBookshelf()
        return parsed.book
    }

    public func importTxt(from fileUrl: URL) throws -> Book {
        guard let data = try? Data(contentsOf: fileUrl) else {
            throw NSError(domain: "BookStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取TXT文件内容"])
        }
        let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) ?? String(decoding: data, as: UTF8.self)

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
            coverUrl: nil,
            intro: "本地导入的TXT小说",
            origin: "local",
            originName: "本地导入",
            tocUrl: "",
            totalChapterNum: chapters.count
        )

        saveChapters(chapters, for: bookUrl)
        if let idx = bookshelf.firstIndex(where: { $0.bookUrl == bookUrl }) {
            bookshelf[idx] = book
        } else {
            bookshelf.insert(book, at: 0)
        }
        saveBookshelf()
        return book
    }

    public func importFile(from fileUrl: URL) throws -> Book {
        let ext = fileUrl.pathExtension.lowercased()
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
                    await self.mark(jobId, finished: 1)
                } else {
                    await self.setCurrentChapter(jobId, chapter.title)
                    do {
                        _ = try await BookContentService.shared.fetchChapterContent(chapter: chapter, source: source)
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
    }

    public func remove(_ catalog: OPDSCatalog) {
        catalogs.removeAll { $0.id == catalog.id }
        save()
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
        if let idx = bookshelf.firstIndex(where: { $0.bookUrl == bookUrl }) {
            bookshelf[idx] = book
        } else {
            bookshelf.insert(book, at: 0)
        }
        saveBookshelf()
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
        if let idx = bookshelf.firstIndex(where: { $0.bookUrl == bookUrl }) {
            bookshelf[idx] = book
        } else {
            bookshelf.insert(book, at: 0)
        }
        saveBookshelf()
        return book
        #else
        throw NSError(domain: "Legado", code: 5, userInfo: [NSLocalizedDescriptionKey: "这个平台不支持 PDF"])
        #endif
    }
}
