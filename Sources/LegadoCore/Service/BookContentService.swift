import Foundation
import Combine
import SwiftSoup

public class BookContentService {
    public static let shared = BookContentService()

    public init() {}

    /// Fetches detailed book information (author, intro, tags, word count) and TOC chapters in a unified request
    public func fetchBookDetail(
        book: Book,
        source: BookSource,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> (book: Book, chapters: [BookChapter]) {
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

        // 脱敏：URL 只记域名，path 与 query 常含私有参数
        LegadoLog.log("[BookDetail] [\(source.bookSourceName)] 抓详情与目录 host=\(URL(string: targetUrl)?.host ?? "-")")

        let bodyString: String
        let pageBaseUrl: String
        let jsEngine: JSEngine
        /// 目录脚本吃的内容：普通站是详情页本身，data: 包里是那份载荷
        let tocContent: Any

        if let payload = NetworkClient.dataURLPayload(targetUrl) {
            // data: 协议：聚合源把请求参数打包在 bookUrl 里，这个网址不用请求。
            // ruleBookInfo.init 拿到载荷自己发请求，把响应体作为返回值交回来。
            let js = JSEngine(bookSource: source, baseUrl: targetUrl, book: book)
            jsEngine = js
            pageBaseUrl = targetUrl
            tocContent = payload
            var detail = ""
            if let initRule = source.ruleBookInfo?.initRule, !initRule.isEmpty {
                if let out = js.eval(script: JSEngine.unwrapJsScript(initRule), result: payload) {
                    detail = out as? String ?? "\(out)"
                }
                if let err = js.lastError {
                    LegadoLog.log("[BookDetail] ⚠️ [\(source.bookSourceName)] 详情 init 脚本报错：\(err)")
                }
            }
            bodyString = detail
        } else {
            guard let parsedReq = NetworkClient.parseLegadoUrl(targetUrl, defaultHeader: headerToUse, baseUrl: source.bookSourceUrl) else {
                LegadoLog.log("[BookDetail] ❌ [\(source.bookSourceName)] 详情 URL 解析失败 host=\(URL(string: targetUrl)?.host ?? "-")")
                return (book, [])
            }
            let response = try await NetworkClient.shared.request(parsed: parsedReq)
            bodyString = response.bodyString
            pageBaseUrl = parsedReq.url.absoluteString
            jsEngine = JSEngine(bookSource: source, baseUrl: pageBaseUrl, book: book)
            tocContent = response.bodyString
        }

        let analyzer = RuleAnalyzer(
            content: bodyString,
            baseUrl: pageBaseUrl,
            bookSource: source,
            jsEngine: jsEngine
        )
        let tocAnalyzer = RuleAnalyzer(
            content: tocContent,
            baseUrl: pageBaseUrl,
            bookSource: source,
            jsEngine: jsEngine
        )

        // 1. Parse Chapters
        let chapterElements = tocAnalyzer.getElements(tocRule.chapterList)
        var chapters: [BookChapter] = []

        for (_, item) in chapterElements.enumerated() {
            let itemAnalyzer = RuleAnalyzer(
                content: item,
                baseUrl: pageBaseUrl,
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

        // 目录分页：有的站点一页只给 40 章，靠 nextTocUrl 把后面的翻出来。
        // 各页之间没有依赖（每页的页码表都列全），所以并发抓，不能一页一页等。
        if let nextRule = tocRule.nextTocUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !nextRule.isEmpty,
           // data: 包没有「下一页网址」这回事，别拿载荷当网址去翻页
           NetworkClient.dataURLPayload(targetUrl) == nil {
            let pageLimit = 60
            let pageTimeout: TimeInterval = 20

            var chapterURLs = Set(chapters.map(\.url))
            var discovered: Set<String> = [pageBaseUrl]
            var frontier = BookContentService.extractURLs(from: analyzer, rule: nextRule, baseUrl: pageBaseUrl)
            var round = 0

            while !frontier.isEmpty, discovered.count < pageLimit, round < 4 {
                round += 1
                let urls = Array(frontier
                    .filter { !discovered.contains($0) }
                    .prefix(pageLimit - discovered.count))
                if urls.isEmpty { break }
                urls.forEach { discovered.insert($0) }

                let bodies = await BookContentService.fetchBodies(
                    urls: urls,
                    header: headerToUse,
                    baseUrl: source.bookSourceUrl,
                    concurrency: 5,
                    timeout: pageTimeout
                )

                var nextURLs: [String] = []
                for (pageURL, body) in bodies {
                    let pageAnalyzer = RuleAnalyzer(
                        content: body,
                        baseUrl: pageURL,
                        bookSource: source,
                        jsEngine: jsEngine
                    )
                    for item in pageAnalyzer.getElements(tocRule.chapterList) {
                        let itemAnalyzer = RuleAnalyzer(
                            content: item,
                            baseUrl: pageURL,
                            bookSource: source,
                            jsEngine: jsEngine
                        )
                        let title = itemAnalyzer.getString(tocRule.chapterName)
                        let url = itemAnalyzer.getString(tocRule.chapterUrl, isUrl: true)
                        guard !title.isEmpty, !url.isEmpty else { continue }
                        guard chapterURLs.insert(url).inserted else { continue }
                        chapters.append(BookChapter(bookUrl: book.bookUrl, url: url, title: title, index: chapters.count))
                    }
                    nextURLs.append(contentsOf: BookContentService.extractURLs(
                        from: pageAnalyzer,
                        rule: nextRule,
                        baseUrl: pageURL
                    ))
                }
                frontier = nextURLs
                onProgress?(discovered.count, pageLimit)
            }
            LegadoLog.log("[BookDetail] [\(source.bookSourceName)] 目录抓完 \(chapters.count) 章 / \(discovered.count) 页 / \(round) 轮")
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
        if let data = bodyString.data(using: .utf8),
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

        // 脱敏：书名与作者不记原文，只记一个稳定指纹和长度
        let nameTag = String(CryptoUtils.md5(updatedBook.name).prefix(8))
        LegadoLog.log("[BookDetail] ✅ [\(source.bookSourceName)] 解析完成 book#\(nameTag) 书名/作者长度=\(updatedBook.name.count)/\(updatedBook.author.count) 简介=\(updatedBook.intro?.count ?? 0) 章数=\(chapters.count)")
        return (updatedBook, chapters)
    }

    /// Fetches and parses the chapter list (Table of Contents)
    public func fetchChapterList(
        book: Book,
        source: BookSource,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> [BookChapter] {
        let result = try await fetchBookDetail(book: book, source: source, onProgress: onProgress)
        return result.chapters
    }

    /// 并发抓一批页面，返回顺序与入参一致；抓失败的页直接跳过。
    public static func fetchBodies(
        urls: [String],
        header: String?,
        baseUrl: String,
        concurrency: Int,
        timeout: TimeInterval
    ) async -> [(String, String)] {
        var results: [(String, String)] = []
        var index = 0
        let batchSize = max(1, concurrency)

        while index < urls.count {
            let slice = Array(urls[index..<min(index + batchSize, urls.count)])
            index += slice.count

            let batch = await withTaskGroup(of: (Int, String, String?).self) { group -> [(String, String)] in
                for (offset, url) in slice.enumerated() {
                    group.addTask {
                        guard let parsed = NetworkClient.parseLegadoUrl(
                            url,
                            defaultHeader: header,
                            baseUrl: baseUrl
                        ) else {
                            return (offset, url, nil)
                        }
                        let response = try? await NetworkClient.shared.request(parsed: parsed, timeout: timeout)
                        return (offset, url, response?.bodyString)
                    }
                }
                var collected: [(Int, String, String?)] = []
                for await item in group {
                    collected.append(item)
                }
                return collected
                    .sorted { $0.0 < $1.0 }
                    .compactMap { item in
                        guard let body = item.2, !body.isEmpty else { return nil }
                        return (item.1, body)
                    }
            }
            results.append(contentsOf: batch)
        }
        return results
    }

    /// 从规则里取出下一页目录地址，href、value、纯文本三种写法都收。
    public static func extractURLs(from analyzer: RuleAnalyzer, rule: String, baseUrl: String) -> [String] {
        func resolve(_ raw: String) -> String? {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            if value.hasPrefix("http") { return value }
            return URL(string: value, relativeTo: URL(string: baseUrl))?.absoluteString
        }

        var results: [String] = []
        for element in analyzer.getElements(rule) {
            if let el = element as? Element {
                var resolved: String?
                for key in ["href", "value", "data-url"] {
                    if let raw = try? el.attr(key), !raw.isEmpty, let url = resolve(raw) {
                        resolved = url
                        break
                    }
                }
                if resolved == nil, let text = try? el.text(), let url = resolve(text) {
                    resolved = url
                }
                if let resolved, !results.contains(resolved) {
                    results.append(resolved)
                }
            } else if let text = element as? String, let url = resolve(text), !results.contains(url) {
                results.append(url)
            }
        }

        if results.isEmpty {
            let single = analyzer.getString(rule)
            if let url = resolve(single), !results.contains(url) {
                results.append(url)
            }
        }
        return results
    }

    /// Fetches and cleans chapter text content
    public func fetchChapterContent(chapter: BookChapter, source: BookSource? = nil, book: Book? = nil) async throws -> String {
        // 漫画 / PDF：章节就是一张本地图片，直接交给阅读器的图片链路
        if chapter.url.hasPrefix("imgpage://") {
            return "[image:" + String(chapter.url.dropFirst("imgpage://".count)) + "]"
        }
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

        // 脱敏：不记章节标题与 URL 路径
        LegadoLog.log("[Content] [\(source.bookSourceName)] 抓正文 第 \(chapter.index + 1) 章 host=\(URL(string: chapterUrl)?.host ?? "-")")

        let bodyString: String
        let pageBaseUrl: String
        let jsEngine: JSEngine

        if let payload = NetworkClient.dataURLPayload(chapterUrl) {
            // data: 协议：章节网址也是打包的，正文规则（ruleContent.content 那段 JS）
            // 拿着载荷自己发请求，把正文取回来。
            jsEngine = JSEngine(bookSource: source, baseUrl: chapterUrl, book: book)
            pageBaseUrl = chapterUrl
            bodyString = payload
        } else {
            guard let parsedReq = NetworkClient.parseLegadoUrl(chapterUrl, defaultHeader: headerToUse, baseUrl: source.bookSourceUrl) else {
                LegadoLog.log("[Content] ❌ [\(source.bookSourceName)] 正文 URL 解析失败 第 \(chapter.index + 1) 章 host=\(URL(string: chapterUrl)?.host ?? "-")")
                return ""
            }
            let response = try await NetworkClient.shared.request(parsed: parsedReq)
            jsEngine = JSEngine(bookSource: source, baseUrl: parsedReq.url.absoluteString, book: book)
            pageBaseUrl = parsedReq.url.absoluteString
            bodyString = response.bodyString
        }

        let analyzer = RuleAnalyzer(
            content: bodyString,
            baseUrl: pageBaseUrl,
            bookSource: source,
            jsEngine: jsEngine
        )

        var contentText = analyzer.getString(contentRule.content)

        // 书源把段评、本章说挂在 HTML 标记里；cleanHtml 会整段洗掉。
        // 先换成不可见哨兵，正文里保留评论数与跳转地址，阅读页再拆出来。
        contentText = Self.preserveReviewMarkers(contentText)

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
        contentText = BookContentService.cleanHtml(contentText, baseUrl: pageBaseUrl)
        // 替换净化：正则/普通文本规则过一遍，去广告水印
        // 这本书被源显式关掉替换净化时跳过（聚合源自己清理过正文，再净化一遍会误伤）
        if book?.useReplaceRule != false {
            contentText = TextPurifier.shared.apply(contentText)
        }

        if !contentText.isEmpty {
            saveCachedChapterContent(bookUrl: chapter.bookUrl, chapterIndex: chapter.index, content: contentText)
        }

        return contentText
    }

    private static let reviewCommentMarkerStart = "\u{E000}C\u{1F}"
    private static let reviewChapterMarkerStart = "\u{E000}H\u{1F}"
    private static let reviewGodMarkerStart = "\u{E000}G\u{1F}"
    private static let reviewMarkerEnd = "\u{E001}"

    /// `<comment count=… onPress=…>` → 段评哨兵；本章说卡片 → 本章说哨兵。
    private static func preserveReviewMarkers(_ html: String) -> String {
        var text = html
        let nsText = text as NSString

        if let tagRegex = try? NSRegularExpression(pattern: "(?is)<comment\\b[^>]*>") {
            let matches = tagRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                let tag = nsText.substring(with: match.range)
                guard let count = firstCapture(in: tag, pattern: "(?i)count\\s*=\\s*\"(\\d+)\""),
                      let url = firstCapture(in: tag, pattern: "(?i)showReadingBrowser\\(\\s*'([^']+)'") else { continue }
                let marker = reviewCommentMarkerStart + count + "\u{1F}" + url + reviewMarkerEnd
                text = (text as NSString).replacingCharacters(in: match.range, with: marker)
            }
        }

        if let imgRegex = try? NSRegularExpression(pattern: "(?is)<img\\b[^>]*>") {
            let nsText2 = text as NSString
            let matches = imgRegex.matches(in: text, range: NSRange(location: 0, length: nsText2.length))
            for match in matches.reversed() {
                let tag = nsText2.substring(with: match.range)
                let marker: String
                if tag.contains("showFanqieComment("),
                   let url = firstCapture(in: tag, pattern: "showFanqieComment\\(\\\\?\"([^\"\\\\]+)") {
                    marker = reviewChapterMarkerStart + url + reviewMarkerEnd
                } else if tag.contains("showCmt("),
                          let url = firstCapture(in: tag, pattern: "showCmt\\(\\s*'([^']+)'"),
                          let note = godReviewText(from: tag) {
                    let encoded = Data(note.utf8).base64EncodedString()
                    marker = reviewGodMarkerStart + encoded + "\u{1F}" + url + reviewMarkerEnd
                } else {
                    continue
                }
                text = (text as NSString).replacingCharacters(in: match.range, with: marker)
            }
        }
        return text
    }

    /// 神评 SVG 里的 `<text>` 就是评论正文；解出来交给阅读页画原生卡片。
    private static func godReviewText(from imgTag: String) -> String? {
        guard let src = firstCapture(in: imgTag, pattern: "(?i)src=\"([^\"]+)\""),
              let comma = src.firstIndex(of: ",") else { return nil }
        let dataPart = String(src[src.startIndex..<comma])
        guard dataPart.contains("base64"),
              let data = Data(base64Encoded: String(src[src.index(after: comma)...])),
              let svg = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: "(?is)<text\\b[^>]*>(.*?)</text>") else { return nil }
        let nsSvg = svg as NSString
        var values: [String] = []
        for match in regex.matches(in: svg, range: NSRange(location: 0, length: nsSvg.length)) {
            var value = nsSvg.substring(with: match.range(at: 1))
            for (entity, replacement) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                                          ("&quot;", "\""), ("&apos;", "'")] {
                value = value.replacingOccurrences(of: entity, with: replacement)
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != "神评论" {
                values.append(trimmed)
            }
        }
        return values.first
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1 else { return nil }
        return nsText.substring(with: match.range(at: 1))
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
        // 这个函数是多轮正则，开销不小；而列表里每一行的简介每次重绘都会调它一遍，
        // 长列表滚动时会反复做同样的事。结果按「baseUrl + 原文」缓存。
        let cacheKey = (baseUrl ?? "") + "\u{1}" + raw
        cleanCacheLock.lock()
        let cached = cleanCache[cacheKey]
        cleanCacheLock.unlock()
        if let cached { return cached }

        let result = cleanHtmlUncached(raw, baseUrl: baseUrl)
        cleanCacheLock.lock()
        if cleanCache.count > 128 { cleanCache.removeAll() }
        cleanCache[cacheKey] = result
        cleanCacheLock.unlock()
        return result
    }

    private static let cleanCacheLock = NSLock()
    private static var cleanCache: [String: String] = [:]

    private static func cleanHtmlUncached(_ raw: String, baseUrl: String? = nil) -> String {
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

// MARK: - 替换净化
/// 一条替换规则：普通文本替换，或者正则替换（去广告、去水印、去站点名）
public struct ReplacementRule: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var pattern: String
    public var replacement: String
    public var isRegex: Bool
    public var enabled: Bool

    public init(name: String = "", pattern: String, replacement: String = "", isRegex: Bool = true, enabled: Bool = true) {
        self.id = UUID()
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.isRegex = isRegex
        self.enabled = enabled
    }
}

/// 正文替换净化：规则存 UserDefaults，抓完正文依次过一遍
/// 阅读页里选一段做「替换」时记下来的规则，按书存、按书生效。
public struct TextReplaceRule: Codable, Equatable, Identifiable {
    public var id: UUID
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.id = UUID()
        self.from = from
        self.to = to
    }
}

public enum TextReplaceRules {
    /// 依次套用，长串优先 —— 否则短串先替换会把长串切碎。
    public static func apply(_ text: String, rules: [TextReplaceRule]) -> String {
        guard !text.isEmpty, !rules.isEmpty else { return text }
        var result = text
        for rule in rules.sorted(by: { $0.from.count > $1.from.count }) {
            guard !rule.from.isEmpty else { continue }
            result = result.replacingOccurrences(of: rule.from, with: rule.to)
        }
        return result
    }
}

public final class TextPurifier: ObservableObject {
    public static let shared = TextPurifier()

    private let key = "text_purifier_rules_v1"

    @Published public var rules: [ReplacementRule] = [] {
        didSet { save() }
    }

    public init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ReplacementRule].self, from: data) {
            rules = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public func apply(_ text: String) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var result = text
        for rule in rules where rule.enabled && !rule.pattern.isEmpty {
            if rule.isRegex {
                guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.dotMatchesLineSeparators]) else { continue }
                let range = NSRange(location: 0, length: (result as NSString).length)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: rule.replacement)
            } else {
                result = result.replacingOccurrences(of: rule.pattern, with: rule.replacement)
            }
        }
        return result
    }
}

// MARK: - 阅读订阅源（Legado RssSource）

/// 订阅源，字段名与安卓版 Legado 的 RssSource 对齐，JSON 可以直接互相导入
public struct SubscribeSource: Codable, Identifiable, Equatable {
    public var id: String { sourceUrl }

    public var sourceUrl: String
    public var sourceName: String
    public var sourceIcon: String?
    public var sourceGroup: String?
    public var sourceComment: String?
    public var enabled: Bool?
    public var variableComment: String?
    public var jsLib: String?
    public var header: String?
    public var loginUrl: String?
    public var loginUi: String?
    /// 单 URL 源：直接抓 sourceUrl；否则抓 sortUrl 分类页
    public var singleUrl: Bool?
    public var sortUrl: String?
    public var articleStyle: Int?
    public var ruleArticles: String?
    public var ruleNextPage: String?
    public var ruleTitle: String?
    public var rulePubDate: String?
    public var ruleDescription: String?
    public var ruleImage: String?
    public var ruleLink: String?
    public var ruleContent: String?
    public var lastUpdateTime: Int64?
    public var customOrder: Int?
    public var type: Int?
    public var preload: Bool?
    public var cacheFirst: Bool?
    public var enableJs: Bool?
    public var loadWithBaseUrl: Bool?
    public var searchUrl: String?

    public init(
        sourceUrl: String = "",
        sourceName: String = "",
        sourceGroup: String? = nil,
        singleUrl: Bool? = true,
        sortUrl: String? = nil,
        ruleArticles: String? = nil,
        ruleTitle: String? = nil,
        ruleLink: String? = nil,
        ruleContent: String? = nil
    ) {
        self.sourceUrl = sourceUrl
        self.sourceName = sourceName
        self.sourceGroup = sourceGroup
        self.singleUrl = singleUrl
        self.sortUrl = sortUrl
        self.ruleArticles = ruleArticles
        self.ruleTitle = ruleTitle
        self.ruleLink = ruleLink
        self.ruleContent = ruleContent
    }

    /// 规则引擎要一个 BookSource 当上下文（拿 header、jsLib、baseUrl），
    /// 订阅源没这层，就现场拼一个同地址的壳。
    var ruleContext: BookSource {
        var shim = BookSource(bookSourceUrl: sourceUrl, bookSourceName: sourceName)
        shim.header = header
        shim.enabled = enabled
        return shim
    }

    /// 抓列表的入口页
    public var listUrl: String {
        if singleUrl == false, let sortUrl, !sortUrl.isEmpty {
            return sortUrl
        }
        return sourceUrl
    }
}

/// 订阅源里的一篇文章
public struct SubscribeArticle: Identifiable, Equatable {
    public var id: String { link.isEmpty ? title : link }
    public var title: String
    public var link: String
    public var date: String?
    public var summary: String?
    public var imageUrl: String?
}

public enum SubscribeSourceService {
    /// 抓订阅源的文章列表。没写 ruleArticles 就当普通 RSS/Atom 处理。
    public static func fetchArticles(source: SubscribeSource, pageUrl: String? = nil) async throws -> [SubscribeArticle] {
        let target = pageUrl ?? source.listUrl
        guard let parsed = NetworkClient.parseLegadoUrl(target, defaultHeader: source.header, baseUrl: source.sourceUrl) else {
            return []
        }
        let response = try await NetworkClient.shared.request(parsed: parsed)
        guard response.statusCode >= 200 && response.statusCode < 400 else { return [] }
        let body = response.bodyString
        let base = parsed.url.absoluteString

        guard let listRule = source.ruleArticles, !listRule.isEmpty else {
            // 没配列表规则：按标准 RSS/Atom 解析
            let items = try await RSSService.shared.fetchFeed(url: target, sourceName: source.sourceName)
            return items.map {
                SubscribeArticle(title: $0.title, link: $0.link, date: $0.date, summary: $0.summary, imageUrl: nil)
            }
        }

        let jsEngine = JSEngine()
        let analyzer = RuleAnalyzer(content: body, baseUrl: base, bookSource: source.ruleContext, jsEngine: jsEngine)
        let elements = analyzer.getElements(listRule)

        var articles: [SubscribeArticle] = []
        for element in elements {
            let itemAnalyzer = RuleAnalyzer(content: element, baseUrl: base, bookSource: source.ruleContext, jsEngine: jsEngine)
            let title = itemAnalyzer.getString(source.ruleTitle)
            let link = itemAnalyzer.getString(source.ruleLink, isUrl: true)
            guard !title.isEmpty || !link.isEmpty else { continue }
            let date = itemAnalyzer.getString(source.rulePubDate)
            let summary = itemAnalyzer.getString(source.ruleDescription)
            let image = itemAnalyzer.getString(source.ruleImage, isUrl: true)
            articles.append(
                SubscribeArticle(
                    title: title.isEmpty ? link : title,
                    link: link,
                    date: date.isEmpty ? nil : date,
                    summary: summary.isEmpty ? nil : BookContentService.cleanHtml(summary),
                    imageUrl: image.isEmpty ? nil : image
                )
            )
        }
        return articles
    }

    /// 抓正文：有 ruleContent 就按规则取，取不到就把整页按纯文本给出去
    public static func fetchContent(article: SubscribeArticle, source: SubscribeSource) async throws -> String {
        guard !article.link.isEmpty,
              let parsed = NetworkClient.parseLegadoUrl(article.link, defaultHeader: source.header, baseUrl: source.sourceUrl) else {
            return ""
        }
        let response = try await NetworkClient.shared.request(parsed: parsed)
        guard response.statusCode >= 200 && response.statusCode < 400 else { return "" }
        let body = response.bodyString
        let base = parsed.url.absoluteString

        if let contentRule = source.ruleContent, !contentRule.isEmpty {
            let analyzer = RuleAnalyzer(content: body, baseUrl: base, bookSource: source.ruleContext, jsEngine: JSEngine())
            let raw = analyzer.getString(contentRule)
            let text = BookContentService.cleanHtml(raw, baseUrl: base)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return BookContentService.cleanHtml(body, baseUrl: base)
    }

    /// 导入：吃 Legado 的 rssSources.json（数组），也吃单个对象
    public static func decodeSources(from json: String) throws -> [SubscribeSource] {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([SubscribeSource].self, from: data) {
            return list.filter { !$0.sourceUrl.isEmpty }
        }
        let single = try decoder.decode(SubscribeSource.self, from: data)
        return single.sourceUrl.isEmpty ? [] : [single]
    }
}

// MARK: - RSS / Atom 订阅
public struct RSSSource: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var url: String

    public init(name: String = "", url: String) {
        self.id = UUID()
        self.name = name
        self.url = url
    }
}

public struct RSSItem: Identifiable, Equatable {
    public var id: String { link.isEmpty ? title : link }
    public var title: String
    public var link: String
    public var summary: String
    public var date: String
    public var sourceName: String
}

/// 拉取 RSS / Atom 并解析出条目（XMLParser，不依赖第三方库）
public final class RSSService {
    public static let shared = RSSService()

    public init() {}

    public func fetchFeed(url: String, sourceName: String = "") async throws -> [RSSItem] {
        guard let parsed = NetworkClient.parseLegadoUrl(url) else { return [] }
        let response = try await NetworkClient.shared.request(parsed: parsed)
        let parser = RSSXMLParser(sourceName: sourceName)
        let delegate = RSSParserDelegate(handler: parser)
        let xmlParser = XMLParser(data: Data(response.bodyString.utf8))
        xmlParser.delegate = delegate
        xmlParser.parse()
        return delegate.items
    }
}

private final class RSSXMLParser {
    let sourceName: String
    init(sourceName: String) { self.sourceName = sourceName }
    func makeItem(title: String, link: String, summary: String, date: String) -> RSSItem {
        RSSItem(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                link: link.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: BookContentService.cleanHtml(summary),
                date: date.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceName: sourceName)
    }
}

private final class RSSParserDelegate: NSObject, XMLParserDelegate {
    private let handler: RSSXMLParser
    private(set) var items: [RSSItem] = []

    private var inItem = false
    private var currentElement = ""
    private var title = ""
    private var link = ""
    private var summary = ""
    private var date = ""
    private var buffer = ""

    init(handler: RSSXMLParser) { self.handler = handler }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        buffer = ""
        if currentElement == "item" || currentElement == "entry" {
            inItem = true
            title = ""; link = ""; summary = ""; date = ""
        }
        if inItem, currentElement == "link", let href = attributeDict["href"], link.isEmpty {
            link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch name {
            case "title": if title.isEmpty { title = value }
            case "link": if link.isEmpty { link = value }
            case "description", "summary", "content", "content:encoded": if summary.isEmpty { summary = value }
            case "pubdate", "published", "updated", "dc:date": if date.isEmpty { date = value }
            case "item", "entry":
                inItem = false
                let item = handler.makeItem(title: title, link: link, summary: summary, date: date)
                if !item.title.isEmpty { items.append(item) }
            default: break
            }
        }
        buffer = ""
    }
}

// MARK: - 订阅源存储
public final class RSSStore: ObservableObject {
    public static let shared = RSSStore()

    @Published public var sources: [RSSSource] = []

    private let key = "rss_sources_v1"

    public init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([RSSSource].self, from: data) {
            sources = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public func add(name: String, url: String) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        sources.append(RSSSource(name: trimmedName, url: trimmedURL))
        save()
        LegadoLog.log("[RSS] 新增订阅 \(sources.count) 个")
    }

    public func remove(_ source: RSSSource) {
        sources.removeAll { $0.id == source.id }
        save()
        LegadoLog.log("[RSS] 删除订阅 \(sources.count) 个")
    }
}

// MARK: - OPDS / Calibre 书库
public struct OPDSCatalog: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var url: String
    public var username: String
    public var password: String

    public init(name: String = "", url: String, username: String = "", password: String = "") {
        self.id = UUID()
        self.name = name
        self.url = url
        self.username = username
        self.password = password
    }
}

public struct OPDSEntry: Identifiable, Equatable {
    public var id: String { href.isEmpty ? title : href }
    public var title: String
    public var href: String
    public var summary: String
    public var author: String
    public var isNavigation: Bool
    public var acquisitions: [(mime: String, href: String)]

    public static func == (lhs: OPDSEntry, rhs: OPDSEntry) -> Bool { lhs.id == rhs.id }
}

/// 拉 OPDS 目录（Calibre / Calibre-Web / 自建 OPDS 都能吃）
public final class OPDSService {
    public static let shared = OPDSService()

    public init() {}

    public func fetch(_ urlString: String, username: String = "", password: String = "") async throws -> (title: String, entries: [OPDSEntry]) {
        var parsed = NetworkClient.parseLegadoUrl(urlString)
        if parsed == nil, let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let u = URL(string: encoded) {
            parsed = NetworkClient.ParsedRequest(url: u, method: "GET", headers: [:], body: nil)
        }
        guard let request = parsed else { return ("", []) }

        var headers = request.headers
        if !username.isEmpty {
            let token = CryptoUtils.base64Encode("\(username):\(password)")
            headers["Authorization"] = "Basic \(token)"
        }
        let authorized = NetworkClient.ParsedRequest(url: request.url, method: request.method, headers: headers, body: request.body)
        let response = try await NetworkClient.shared.request(parsed: authorized)

        let delegate = OPDSXMLDelegate(baseURL: request.url)
        let parser = XMLParser(data: Data(response.bodyString.utf8))
        parser.delegate = delegate
        parser.parse()
        return (delegate.feedTitle, delegate.entries)
    }

    /// 下载一本（返回本地临时文件路径）
    public func download(_ href: String, username: String = "", password: String = "") async throws -> URL {
        var parsed = NetworkClient.parseLegadoUrl(href)
        if parsed == nil, let u = URL(string: href) {
            parsed = NetworkClient.ParsedRequest(url: u, method: "GET", headers: [:], body: nil)
        }
        guard let request = parsed else { throw URLError(.badURL) }
        var headers = request.headers
        if !username.isEmpty {
            headers["Authorization"] = "Basic " + CryptoUtils.base64Encode("\(username):\(password)")
        }
        let authorized = NetworkClient.ParsedRequest(url: request.url, method: "GET", headers: headers, body: nil)
        let response = try await NetworkClient.shared.request(parsed: authorized)

        let name = request.url.lastPathComponent.isEmpty ? "opds-book.epub" : request.url.lastPathComponent
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try response.data.write(to: dest)
        return dest
    }
}

private final class OPDSXMLDelegate: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private(set) var feedTitle = ""
    private(set) var entries: [OPDSEntry] = []

    private var inEntry = false
    private var inFeedTitle = false
    private var current = ""
    private var title = ""
    private var summary = ""
    private var author = ""
    private var href = ""
    private var isNavigation = false
    private var acquisitions: [(mime: String, href: String)] = []

    init(baseURL: URL) { self.baseURL = baseURL }

    private func absolute(_ link: String) -> String {
        guard !link.isEmpty else { return "" }
        if link.hasPrefix("http") { return link }
        return URL(string: link, relativeTo: baseURL)?.absoluteString ?? link
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        current = ""
        switch name {
        case "entry":
            inEntry = true
            title = ""; summary = ""; author = ""; href = ""; isNavigation = false; acquisitions = []
        case "title":
            if !inEntry { inFeedTitle = true }
        case "link":
            let rel = attributeDict["rel"] ?? ""
            let type = attributeDict["type"] ?? ""
            guard let raw = attributeDict["href"] else { break }
            let link = absolute(raw)
            if rel.contains("acquisition") {
                acquisitions.append((type, link))
            } else if rel.contains("subsection") || type.contains("atom") || rel.isEmpty {
                if href.isEmpty || rel.contains("subsection") {
                    href = link
                    if rel.contains("subsection") { isNavigation = true }
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if inEntry {
            switch name {
            case "title": if title.isEmpty { title = value }
            case "summary", "content": if summary.isEmpty { summary = value }
            case "name": if author.isEmpty { author = value }
            case "entry":
                inEntry = false
                if !title.isEmpty {
                    entries.append(OPDSEntry(title: title, href: href, summary: BookContentService.cleanHtml(summary), author: author, isNavigation: isNavigation && acquisitions.isEmpty, acquisitions: acquisitions))
                }
            default: break
            }
        } else if name == "title", inFeedTitle {
            feedTitle = value
            inFeedTitle = false
        }
        current = ""
    }
}
