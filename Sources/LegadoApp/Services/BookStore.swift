import Foundation
#if canImport(LegadoCore)
import LegadoCore
#endif

public class BookStore: ObservableObject {
    public static let shared = BookStore()

    @Published public var bookshelf: [Book] = []
    @Published public var sources: [BookSource] = []

    private let booksKey = "legado_bookshelf_v1"
    private let sourcesKey = "legado_sources_v1"

    public init() {
        loadData()
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

        // Migrate any legacy example books and remove example source
        var booksNeedSave = false
        for i in 0..<bookshelf.count {
            if bookshelf[i].origin.contains("example.com") {
                bookshelf[i].origin = "https://example.com"
                booksNeedSave = true
            }
            if bookshelf[i].bookUrl.contains("example.com") {
                bookshelf[i].bookUrl = bookshelf[i].bookUrl.replacingOccurrences(of: "example.com", with: "example.com")
                booksNeedSave = true
            }
            if bookshelf[i].tocUrl.contains("example.com") {
                bookshelf[i].tocUrl = bookshelf[i].tocUrl.replacingOccurrences(of: "example.com", with: "example.com")
                booksNeedSave = true
            }
        }
        if booksNeedSave {
            saveBookshelf()
        }

        if sources.contains(where: { $0.bookSourceUrl.contains("example.com") }) {
            sources.removeAll(where: { $0.bookSourceUrl.contains("example.com") })
            saveSources()
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
            // Match existing source by URL, name, or 示例书源 alias
            if let idx = sources.firstIndex(where: {
                $0.bookSourceUrl == s.bookSourceUrl ||
                $0.bookSourceName == s.bookSourceName ||
                (s.bookSourceName == "示例书源" && ($0.bookSourceName == "示例书源二" || $0.bookSourceName == "示例书源二"))
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
    public func restoreFromWebDAV(books: [Book]?, sources: [BookSource]?) -> (booksAdded: Int, sourcesAdded: Int) {
        var booksCount = 0
        var sourcesCount = 0

        if let newBooks = books {
            for var b in newBooks {
                // Normalize legacy example URLs to example.com directly at data level
                if b.origin.contains("example.com") {
                    b.origin = "https://example.com"
                }
                if b.bookUrl.contains("example.com") {
                    b.bookUrl = b.bookUrl.replacingOccurrences(of: "example.com", with: "example.com")
                }
                if b.tocUrl.contains("example.com") {
                    b.tocUrl = b.tocUrl.replacingOccurrences(of: "example.com", with: "example.com")
                }

                if let idx = bookshelf.firstIndex(where: { $0.bookUrl == b.bookUrl }) {
                    // Update metadata and reading progress
                    bookshelf[idx] = b
                } else {
                    bookshelf.append(b)
                    booksCount += 1
                }
            }
            saveBookshelf()
        }

        if let newSources = sources {
            for s in newSources {
                // Do not re-add old example source
                if s.bookSourceUrl.contains("example.com") {
                    continue
                }
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
    public func saveOrUpdateBook(_ book: Book) -> Book {
        if let index = bookshelf.firstIndex(where: { $0.bookUrl == book.bookUrl }) {
            var existing = bookshelf[index]
            if !book.author.isEmpty && book.author != "未知作者" { existing.author = book.author }
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

        print("[Bookshelf] 🔄 Starting full refresh for \(networkBooks.count) network books...")

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
                        print("[Bookshelf] ⚠️ Failed to refresh '\(book.name)': \(error.localizedDescription)")
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
        print("[Bookshelf] ✅ Finished refresh for all books")
    }

    // MARK: - Source Management
    public func importSources(json: String) throws -> Int {
        guard let data = json.data(using: .utf8) else { return 0 }
        let imported = try JSONDecoder().decode([BookSource].self, from: data)

        var count = 0
        for var s in imported {
            if s.bookSourceUrl == "https://example.com" || s.bookSourceUrl == "http://example.com" {
                s.bookSourceUrl = "https://example.com"
            }
            if let idx = sources.firstIndex(where: { $0.bookSourceUrl == s.bookSourceUrl || $0.bookSourceName == s.bookSourceName }) {
                sources[idx] = s
            } else {
                sources.append(s)
                count += 1
            }
        }
        saveSources()
        return count
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

        // 3. Domain / Host Match (e.g. example.com / example.com, example.com / example.com)
        let bookHost = URL(string: book.origin)?.host ?? URL(string: book.bookUrl)?.host ?? ""
        if !bookHost.isEmpty {
            for s in sources {
                let sHost = URL(string: s.bookSourceUrl)?.host ?? ""
                if !sHost.isEmpty && sHost == bookHost {
                    return s
                }
            }
        }

        // 4. Known aliases & proxies (Novelia <-> example / example)
        let isNoveliaBook = book.origin.contains("example.com") || book.origin.contains("example.com") || book.origin.contains("example.com") || book.bookUrl.contains("example.com") || book.bookUrl.contains("example.com")
        if isNoveliaBook {
            if let s = sources.first(where: { $0.bookSourceUrl.contains("example.com") || $0.bookSourceUrl.contains("example.com") || $0.bookSourceName.contains("示例书源") }) {
                return s
            }
        }

        // 5. 示例书源 aliases
        let isEsjBook = book.origin.lowercased().contains("esj") || book.bookUrl.lowercased().contains("esj")
        if isEsjBook {
            if let s = sources.first(where: { $0.bookSourceUrl.lowercased().contains("esj") || $0.bookSourceName.lowercased().contains("esj") }) {
                return s
            }
        }

        // 6. Substring / URL contains matching
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
               bookshelf[i].originName == oldName ||
               (oldUrl.contains("example.com") && (bookshelf[i].origin.contains("example.com") || bookshelf[i].originName.contains("示例书源"))) {
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
        if ext == "txt" {
            return try importTxt(from: fileUrl)
        } else {
            return try importEpub(from: fileUrl)
        }
    }
}
