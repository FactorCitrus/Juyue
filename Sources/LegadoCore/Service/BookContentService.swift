import Foundation

public class BookContentService {
    public static let shared = BookContentService()

    public init() {}

    /// Fetches detailed book information (author, intro, tags, word count) and TOC chapters in a unified request
    public func fetchBookDetail(book: Book, source: BookSource) async throws -> (book: Book, chapters: [BookChapter]) {
        guard let tocRule = source.ruleToc else {
            return (book, [])
        }

        let targetUrl = !book.tocUrl.isEmpty ? book.tocUrl : book.bookUrl
        var headerToUse = source.loginHeader ?? source.header
        if let h = headerToUse, (h.contains("<js>") || h.hasPrefix("@js:")) {
            let js = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
            let script = h.contains("<js>") ? String(h[h.range(of: "<js>")!.upperBound..<h.range(of: "</js>")!.lowerBound]) : String(h.dropFirst(4))
            if let evaluated = js.context.evaluateScript(script)?.toString(), !evaluated.isEmpty && evaluated != "undefined" {
                headerToUse = evaluated
            }
        }

        print("[BookDetail] 🚀 [\(source.bookSourceName)] Fetching details and TOC from: \(targetUrl)")
        guard let parsedReq = NetworkClient.parseLegadoUrl(targetUrl, defaultHeader: headerToUse, baseUrl: source.bookSourceUrl) else {
            print("[BookDetail] ❌ [\(source.bookSourceName)] Failed to parse URL: \(targetUrl)")
            return (book, [])
        }

        let response = try await NetworkClient.shared.request(parsed: parsedReq)
        let jsEngine = JSEngine(bookSource: source, baseUrl: parsedReq.url.absoluteString)

        let analyzer = RuleAnalyzer(
            content: response.bodyString,
            baseUrl: parsedReq.url.absoluteString,
            bookSource: source,
            jsEngine: jsEngine
        )

        // 1. Parse Chapters
        let chapterElements = analyzer.getElements(tocRule.chapterList)
        var chapters: [BookChapter] = []

        for (_, item) in chapterElements.enumerated() {
            let itemAnalyzer = RuleAnalyzer(
                content: item,
                baseUrl: parsedReq.url.absoluteString,
                bookSource: source,
                jsEngine: jsEngine
            )

            let title = itemAnalyzer.getString(tocRule.chapterName)
            let url = itemAnalyzer.getString(tocRule.chapterUrl, isUrl: true)

            guard !title.isEmpty, !url.isEmpty else { continue }

            let chapter = BookChapter(
                bookUrl: book.bookUrl,
                url: url,
                title: title,
                index: chapters.count
            )
            chapters.append(chapter)
        }

        // 2. Parse Book Metadata (Author, Intro, Kind, WordCount)
        var updatedBook = book
        updatedBook.totalChapterNum = chapters.count
        if let lastCh = chapters.last, updatedBook.latestChapterTitle == nil || updatedBook.latestChapterTitle?.isEmpty == true {
            updatedBook.latestChapterTitle = lastCh.title
        }

        // Apply ruleBookInfo if configured
        if let infoRule = source.ruleBookInfo {
            let authorVal = analyzer.getString(infoRule.author)
            if !authorVal.isEmpty { updatedBook.author = authorVal }

            let introVal = analyzer.getString(infoRule.intro)
            if !introVal.isEmpty { updatedBook.intro = BookContentService.cleanHtml(introVal) }

            let kindVal = analyzer.getString(infoRule.kind)
            if !kindVal.isEmpty { updatedBook.kind = kindVal }

            let wordCountVal = analyzer.getString(infoRule.wordCount)
            if !wordCountVal.isEmpty { updatedBook.wordCount = wordCountVal }

            let coverVal = analyzer.getString(infoRule.coverUrl, isUrl: true)
            if !coverVal.isEmpty { updatedBook.coverUrl = coverVal }
        }

        // Apply intelligent JSON metadata extraction (e.g. for Novelia and generic novel REST APIs)
        if let data = response.bodyString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // Author extraction from JSON
            if updatedBook.author.isEmpty || updatedBook.author == "未知作者" {
                if let authorsArr = json["authors"] as? [[String: Any]] {
                    let names = authorsArr.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
                    if !names.isEmpty {
                        updatedBook.author = names.joined(separator: ", ")
                    }
                } else if let authorStr = json["author"] as? String, !authorStr.isEmpty {
                    updatedBook.author = authorStr
                }
            }

            // Real Introduction extraction from JSON
            if let introZh = json["introductionZh"] as? String, !introZh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updatedBook.intro = introZh
            } else if let introJp = json["introductionJp"] as? String, !introJp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updatedBook.intro = introJp
            } else if let desc = json["description"] as? String, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updatedBook.intro = desc
            } else if let intro = json["intro"] as? String, !intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updatedBook.intro = intro
            }

            // Word Count
            if updatedBook.wordCount == nil || updatedBook.wordCount?.isEmpty == true {
                if let totalChars = json["totalCharacters"] as? Int {
                    if totalChars > 10000 {
                        updatedBook.wordCount = String(format: "%.1f万字", Double(totalChars) / 10000.0)
                    } else {
                        updatedBook.wordCount = "\(totalChars)字"
                    }
                }
            }

            // Kind / Tags
            if updatedBook.kind == nil || updatedBook.kind?.isEmpty == true {
                var tags: [String] = []
                if let t = json["type"] as? String, !t.isEmpty { tags.append(t) }
                if let kws = json["keywords"] as? [String] { tags.append(contentsOf: kws) }
                if !tags.isEmpty {
                    updatedBook.kind = tags.joined(separator: ",")
                }
            }
        }

        print("[BookDetail] ✅ [\(source.bookSourceName)] Parsed book '\(updatedBook.name)' by '\(updatedBook.author)', intro length: \(updatedBook.intro?.count ?? 0), chapters: \(chapters.count)")
        return (updatedBook, chapters)
    }

    /// Fetches and parses the chapter list (Table of Contents)
    public func fetchChapterList(book: Book, source: BookSource) async throws -> [BookChapter] {
        let result = try await fetchBookDetail(book: book, source: source)
        return result.chapters
    }

    /// Fetches and cleans chapter text content
    public func fetchChapterContent(chapter: BookChapter, source: BookSource? = nil) async throws -> String {
        // If chapter points to a local file, extract directly from disk
        if chapter.url.hasPrefix("file://") || chapter.url.hasPrefix("epub://") || chapter.url.hasPrefix("txt://") || chapter.bookUrl.hasPrefix("file://") || chapter.bookUrl.hasPrefix("txt://") || chapter.url.contains(".xhtml") || chapter.url.contains(".html") || chapter.url.contains(".txt") {
            if chapter.url.contains(".txt") {
                var localPath = ""
                if let u = URL(string: chapter.url), u.isFileURL {
                    localPath = u.path
                } else {
                    localPath = chapter.url.replacingOccurrences(of: "file://", with: "")
                }
                var targetFile = URL(fileURLWithPath: localPath)
                if !FileManager.default.fileExists(atPath: targetFile.path) {
                    let fileName = targetFile.lastPathComponent
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    targetFile = docs.appendingPathComponent("Books/TXT/\(CryptoUtils.md5(chapter.bookUrl))/\(fileName)")
                }
                if let text = try? String(contentsOf: targetFile, encoding: .utf8) {
                    return text
                }
            }

            let text = EpubParser.extractChapterContent(fromUrlString: chapter.url, bookUrl: chapter.bookUrl)
            if !text.isEmpty {
                return text
            }
        }

        // Check local chapter cache first
        if let cached = getCachedChapterContent(bookUrl: chapter.bookUrl, chapterIndex: chapter.index), !cached.isEmpty {
            return cached
        }

        guard let source = source, let contentRule = source.ruleContent else {
            return ""
        }

        var chapterUrl = chapter.url
        if chapterUrl.contains("/chapter/"), !chapterUrl.contains("/api/novel/"), chapter.bookUrl.contains("/api/novel/") {
            if let chapterId = chapterUrl.components(separatedBy: "/chapter/").last?.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines), !chapterId.isEmpty {
                let trimmedBookUrl = chapter.bookUrl.hasSuffix("/") ? String(chapter.bookUrl.dropLast()) : chapter.bookUrl
                chapterUrl = "\(trimmedBookUrl)/chapter/\(chapterId)"
            }
        }

        var headerToUse = source.loginHeader ?? source.header
        if let h = headerToUse, (h.contains("<js>") || h.hasPrefix("@js:")) {
            let js = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
            let script = h.contains("<js>") ? String(h[h.range(of: "<js>")!.upperBound..<h.range(of: "</js>")!.lowerBound]) : String(h.dropFirst(4))
            if let evaluated = js.context.evaluateScript(script)?.toString(), !evaluated.isEmpty && evaluated != "undefined" {
                headerToUse = evaluated
            }
        }

        print("[Content] 🚀 [\(source.bookSourceName)] Fetching chapter '\(chapter.title)' from: \(chapterUrl)")
        guard let parsedReq = NetworkClient.parseLegadoUrl(chapterUrl, defaultHeader: headerToUse, baseUrl: source.bookSourceUrl) else {
            print("[Content] ❌ [\(source.bookSourceName)] Failed to parse chapter URL: \(chapterUrl)")
            return ""
        }

        let response = try await NetworkClient.shared.request(parsed: parsedReq)
        let jsEngine = JSEngine(bookSource: source, baseUrl: parsedReq.url.absoluteString)

        let analyzer = RuleAnalyzer(
            content: response.bodyString,
            baseUrl: parsedReq.url.absoluteString,
            bookSource: source,
            jsEngine: jsEngine
        )

        var contentText = analyzer.getString(contentRule.content)

        // Apply regex cleanup if specified in source
        if let replaceRegex = contentRule.replaceRegex, !replaceRegex.isEmpty {
            let segments = replaceRegex.components(separatedBy: "##")
            if segments.count >= 2 {
                let pattern = segments[0]
                let replacement = segments[1]
                if let rx = try? NSRegularExpression(pattern: pattern) {
                    contentText = rx.stringByReplacingMatches(
                        in: contentText,
                        range: NSRange(location: 0, length: (contentText as NSString).length),
                        withTemplate: replacement
                    )
                }
            }
        }

        // Clean up common web garbage and sanitize HTML tags
        contentText = BookContentService.cleanHtml(contentText, baseUrl: parsedReq.url.absoluteString)

        if !contentText.isEmpty {
            saveCachedChapterContent(bookUrl: chapter.bookUrl, chapterIndex: chapter.index, content: contentText)
        }

        return contentText
    }

    // MARK: - Chapter Content Cache
    private func chapterCacheDirectory(bookUrl: String) -> URL {
        let hash = CryptoUtils.md5(bookUrl)
        let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = cacheBase.appendingPathComponent("ChapterCache/\(hash)")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func chapterCacheFile(bookUrl: String, chapterIndex: Int) -> URL {
        return chapterCacheDirectory(bookUrl: bookUrl).appendingPathComponent("\(chapterIndex).txt")
    }

    public func getCachedChapterContent(bookUrl: String, chapterIndex: Int) -> String? {
        let file = chapterCacheFile(bookUrl: bookUrl, chapterIndex: chapterIndex)
        return try? String(contentsOf: file, encoding: .utf8)
    }

    public func saveCachedChapterContent(bookUrl: String, chapterIndex: Int, content: String) {
        guard !content.isEmpty else { return }
        let file = chapterCacheFile(bookUrl: bookUrl, chapterIndex: chapterIndex)
        try? content.write(to: file, atomically: true, encoding: .utf8)
    }

    public func clearCache(for bookUrl: String) {
        let dir = chapterCacheDirectory(bookUrl: bookUrl)
        try? FileManager.default.removeItem(at: dir)
    }

    public func hasCachedChapter(bookUrl: String, chapterIndex: Int) -> Bool {
        let file = chapterCacheFile(bookUrl: bookUrl, chapterIndex: chapterIndex)
        return FileManager.default.fileExists(atPath: file.path)
    }

    private var preDownloadTask: Task<Void, Never>? = nil

    /// 仿照 Android Legado preDownload()：在后台自动预缓存当前章节前后各 10 章
    public func preDownloadChapters(around currentIndex: Int, chapters: [BookChapter], source: BookSource?, count: Int = 10) {
        preDownloadTask?.cancel()
        guard !chapters.isEmpty else { return }

        preDownloadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }

            // 1. 优先预下载后续章节 (currentIndex + 1 到 currentIndex + count)
            let maxIndex = min(currentIndex + count, chapters.count - 1)
            if currentIndex + 1 <= maxIndex {
                for i in (currentIndex + 1)...maxIndex {
                    if Task.isCancelled { return }
                    let ch = chapters[i]
                    if self.hasCachedChapter(bookUrl: ch.bookUrl, chapterIndex: ch.index) {
                        continue
                    }
                    _ = try? await self.fetchChapterContent(chapter: ch, source: source)
                    try? await Task.sleep(nanoseconds: 80_000_000) // 80ms 节奏间隔，避免被防爬虫限流
                }
            }

            // 2. 预下载前面的章节 (currentIndex - 1 倒序到 currentIndex - count)
            let minIndex = max(0, currentIndex - count)
            if currentIndex - 1 >= minIndex {
                for i in stride(from: currentIndex - 1, through: minIndex, by: -1) {
                    if Task.isCancelled { return }
                    let ch = chapters[i]
                    if self.hasCachedChapter(bookUrl: ch.bookUrl, chapterIndex: ch.index) {
                        continue
                    }
                    _ = try? await self.fetchChapterContent(chapter: ch, source: source)
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
            }
        }
    }

    public func getCacheCount(for bookUrl: String) -> Int {
        let dir = chapterCacheDirectory(bookUrl: bookUrl)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        return files.filter { $0.hasSuffix(".txt") }.count
    }

    /// Sanitizes HTML text, converting <img> to [image:url], <p> and <br> to paragraphs, and stripping other tags
    public static func cleanHtml(_ raw: String, baseUrl: String? = nil) -> String {
        var text = raw

        // Convert <img> tags to \n\n[image:url]\n\n before stripping HTML tags
        let imgPattern = "(?i)<img\\s+[^>]*?>"
        if let imgRegex = try? NSRegularExpression(pattern: imgPattern) {
            let nsText = text as NSString
            let matches = imgRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                let imgTag = nsText.substring(with: match.range)
                if let src = extractImageSrc(from: imgTag, baseUrl: baseUrl), !src.isEmpty {
                    text = (text as NSString).replacingCharacters(in: match.range, with: "\n\n[image:\(src)]\n\n")
                }
            }
        }

        // Convert <br> and <br/> to newlines
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        // Convert </p> to double newlines
        text = text.replacingOccurrences(of: "(?i)</p>", with: "\n\n", options: .regularExpression)
        // Strip <p ...> tags
        text = text.replacingOccurrences(of: "(?i)<p[^>]*>", with: "", options: .regularExpression)
        // Strip all other HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode common HTML entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&lrm;", with: "")
        text = text.replacingOccurrences(of: "&rlm;", with: "")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        // Collapse 3+ consecutive newlines to 2
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractImageSrc(from imgTag: String, baseUrl: String?) -> String? {
        let patterns = [
            "(?i)data-original\\s*=\\s*[\"']([^\"']+)[\"']",
            "(?i)data-src\\s*=\\s*[\"']([^\"']+)[\"']",
            "(?i)src\\s*=\\s*[\"']([^\"']+)[\"']"
        ]

        var rawSrc: String? = nil
        for pattern in patterns {
            if let rx = try? NSRegularExpression(pattern: pattern),
               let match = rx.firstMatch(in: imgTag, range: NSRange(location: 0, length: (imgTag as NSString).length)),
               match.numberOfRanges > 1 {
                let found = (imgTag as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !found.isEmpty && !found.hasPrefix("data:image") {
                    rawSrc = found
                    break
                }
            }
        }

        guard let src = rawSrc else { return nil }

        // Filter out decorative avatars/logos
        if src.contains("discord_logo") || src.contains("nophoto.png") {
            return nil
        }

        // Resolve relative URL
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            return src
        } else if src.hasPrefix("//") {
            return "https:" + src
        } else if let base = baseUrl, let baseObj = URL(string: base) {
            if src.hasPrefix("/") {
                let origin = "\(baseObj.scheme ?? "https")://\(baseObj.host ?? "")"
                return origin + src
            } else {
                return baseObj.deletingLastPathComponent().appendingPathComponent(src).absoluteString
            }
        }
        return src
    }
}
