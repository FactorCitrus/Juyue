import Foundation
import Combine
import SwiftSoup

// MARK: - 正文与目录

public class BookContentService {
    public static let shared = BookContentService()

    public init() {}

    public func fetchBookDetail(
        book: Book,
        source: BookSource,
        onProgress: ((Int, Int) -> Void)? = nil,
        diagnostics: ((SourceRequestDiagnostic) -> Void)? = nil,
        includeChapters: Bool = true
    ) async throws -> (book: Book, chapters: [BookChapter]) {
        guard let tocRule = source.ruleToc else {
            return (book, [])
        }
        try await SourceLoginService.shared.requireLoginIfNeeded(source: source)

        let target = book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl
        let header = ScriptSnippet.resolveHeader(source.loginHeader ?? source.header, source: source)

        JuyueLog.log("[BookDetail] [\(source.bookSourceName)] 抓详情与目录 host=\(URL(string: target)?.host ?? "-")")

        let page: DetailPage.Payload
        do {
            page = try await DetailPage.make(
                target: target,
                book: book,
                source: source,
                header: header,
                diagnostics: diagnostics
            )
        } catch ContentError.invalidURL {
            return (book, [])
        }

        let documentAnalyzer = RuleAnalyzer(
            content: page.body,
            baseUrl: page.baseURL,
            bookSource: source,
            jsEngine: page.engine
        )
        let tocAnalyzer = RuleAnalyzer(
            content: page.tocContent,
            baseUrl: page.baseURL,
            bookSource: source,
            jsEngine: page.engine
        )

        var chapters: [BookChapter] = []
        if includeChapters {
            chapters = await ChapterCollector(
                book: book,
                source: source,
                rule: tocRule,
                engine: page.engine,
                header: header
            ).collect(
                firstPage: tocAnalyzer,
                firstPageURL: page.baseURL,
                nextRuleSeed: documentAnalyzer,
                targetUsesDataURL: NetworkClient.dataURLPayload(target) != nil,
                onProgress: onProgress
            )
        }

        var updated = book
        if includeChapters {
            updated.totalChapterNum = chapters.count
        }

        DiagnosticHub.emit(SourceRequestDiagnostic(
            step: "目录",
            sourceName: source.bookSourceName,
            url: page.baseURL,
            ruleHits: chapters.count,
            note: "目录 \(chapters.count) 章"
        ), to: diagnostics)

        if includeChapters,
           updated.latestChapterTitle == nil || updated.latestChapterTitle?.isEmpty == true,
           let last = chapters.last {
            updated.latestChapterTitle = last.title
        }

        updated = MetadataApplier.apply(
            to: updated,
            body: page.body,
            baseURL: page.baseURL,
            source: source,
            analyzer: documentAnalyzer
        )

        let fingerprint = String(CryptoUtils.md5(updated.name).prefix(8))
        JuyueLog.log("[BookDetail] ✅ [\(source.bookSourceName)] 解析完成 book#\(fingerprint) 书名/作者长度=\(updated.name.count)/\(updated.author.count) 简介=\(updated.intro?.count ?? 0) 章数=\(chapters.count)")
        return (updated, chapters)
    }

    public func fetchBookCover(book: Book, source: BookSource) async -> String? {
        var probe = book
        probe.coverUrl = nil
        guard let result = try? await fetchBookDetail(book: probe, source: source, includeChapters: false) else {
            return nil
        }
        guard let cover = result.book.coverUrl, !cover.isEmpty else { return nil }
        return cover
    }

    public func fetchChapterList(
        book: Book,
        source: BookSource,
        onProgress: ((Int, Int) -> Void)? = nil,
        diagnostics: ((SourceRequestDiagnostic) -> Void)? = nil
    ) async throws -> [BookChapter] {
        let result = try await fetchBookDetail(
            book: book,
            source: source,
            onProgress: onProgress,
            diagnostics: diagnostics
        )
        return result.chapters
    }

    public static func fetchBodies(
        urls: [String],
        header: String?,
        baseUrl: String,
        concurrency: Int,
        timeout: TimeInterval,
        rateKey: String? = nil,
        rateLimit: SourceRateLimit? = nil
    ) async -> [(String, String)] {
        guard !urls.isEmpty else { return [] }
        let width = max(1, concurrency)
        var output: [(String, String)] = []

        for start in stride(from: 0, to: urls.count, by: width) {
            let end = min(start + width, urls.count)
            let slice = Array(urls[start..<end])

            let batch = await withTaskGroup(of: (Int, String, String?).self) { group -> [(String, String)] in
                for (offset, address) in slice.enumerated() {
                    group.addTask {
                        guard let request = NetworkClient.parseJuyueUrl(
                            address,
                            defaultHeader: header,
                            baseUrl: baseUrl
                        ) else {
                            return (offset, address, nil)
                        }
                        let reply = try? await NetworkClient.shared.request(
                            parsed: request,
                            timeout: timeout,
                            rateKey: rateKey,
                            rateLimit: rateLimit
                        )
                        return (offset, address, reply?.bodyString)
                    }
                }

                var gathered: [(Int, String, String?)] = []
                for await item in group {
                    gathered.append(item)
                }
                return gathered
                    .sorted { $0.0 < $1.0 }
                    .compactMap { item in
                        guard let body = item.2, !body.isEmpty else { return nil }
                        return (item.1, body)
                    }
            }
            output.append(contentsOf: batch)
        }
        return output
    }

    public static func extractURLs(from analyzer: RuleAnalyzer, rule: String, baseUrl: String) -> [String] {
        var collected: [String] = []

        func add(_ address: String?) {
            guard let address, !collected.contains(address) else { return }
            collected.append(address)
        }

        func absolute(_ raw: String) -> String? {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            if value.hasPrefix("http") { return value }
            return URL(string: value, relativeTo: URL(string: baseUrl))?.absoluteString
        }

        for candidate in analyzer.getElements(rule) {
            if let element = candidate as? Element {
                var resolved: String?
                for attribute in ["href", "value", "data-url"] {
                    if let raw = try? element.attr(attribute),
                       !raw.isEmpty,
                       let address = absolute(raw) {
                        resolved = address
                        break
                    }
                }
                if resolved == nil, let text = try? element.text(), let address = absolute(text) {
                    resolved = address
                }
                add(resolved)
            } else if let text = candidate as? String {
                add(absolute(text))
            }
        }

        if collected.isEmpty {
            add(absolute(analyzer.getString(rule)))
        }
        return collected
    }

    public func fetchChapterContent(
        chapter: BookChapter,
        source: BookSource? = nil,
        book: Book? = nil,
        diagnostics: ((SourceRequestDiagnostic) -> Void)? = nil
    ) async throws -> String {
        if chapter.url.hasPrefix("imgpage://") {
            return "[image:" + String(chapter.url.dropFirst("imgpage://".count)) + "]"
        }

        if let local = LocalChapterLoader.read(chapter: chapter) {
            return local
        }

        if let cached = getCachedChapterContent(bookUrl: chapter.bookUrl, chapterIndex: chapter.index), !cached.isEmpty {
            return cached
        }

        guard let source, let contentRule = source.ruleContent else {
            return ""
        }
        try await SourceLoginService.shared.requireLoginIfNeeded(source: source)

        let target = resolvedChapterURL(chapter: chapter)
        let header = ScriptSnippet.resolveHeader(source.loginHeader ?? source.header, source: source)

        JuyueLog.log("[Content] [\(source.bookSourceName)] 抓正文 第 \(chapter.index + 1) 章 host=\(URL(string: target)?.host ?? "-")")

        let page: ContentPage.Payload
        do {
            page = try await ContentPage.make(
                target: target,
                chapterIndex: chapter.index,
                book: book,
                source: source,
                header: header,
                diagnostics: diagnostics
            )
        } catch ContentError.invalidURL {
            return ""
        }

        page.engine.context.setObject(
            ["index": chapter.index, "title": chapter.title, "url": target],
            forKeyedSubscript: "chapter" as NSString
        )

        let analyzer = RuleAnalyzer(
            content: page.body,
            baseUrl: page.baseURL,
            bookSource: source,
            jsEngine: page.engine
        )

        var text = analyzer.getString(contentRule.content)
        text = Self.preserveReviewMarkers(text)

        if let replaceRegex = contentRule.replaceRegex, !replaceRegex.isEmpty {
            text = RegexReplacement.apply(replaceRegex, to: text)
        }

        text = Self.cleanHtml(text, baseUrl: page.baseURL)

        if book?.useReplaceRule != false {
            text = TextPurifier.shared.apply(text)
        }

        if !text.isEmpty {
            saveCachedChapterContent(bookUrl: chapter.bookUrl, chapterIndex: chapter.index, content: text)
        }

        DiagnosticHub.emit(SourceRequestDiagnostic(
            step: "正文",
            sourceName: source.bookSourceName,
            url: page.baseURL,
            statusCode: 0,
            elapsedMs: 0,
            responseBytes: text.utf8.count,
            ruleHits: text.isEmpty ? 0 : 1,
            note: "规则命中 \(text.count) 字"
        ), to: diagnostics)

        return text
    }

    private func resolvedChapterURL(chapter: BookChapter) -> String {
        var target = chapter.url
        guard target.contains("/chapter/"),
              !target.contains("/api/novel/"),
              chapter.bookUrl.contains("/api/novel/") else {
            return target
        }

        let tail = target.components(separatedBy: "/chapter/").last ?? ""
        let identifier = tail.components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !identifier.isEmpty else { return target }

        let stem = chapter.bookUrl.hasSuffix("/") ? String(chapter.bookUrl.dropLast()) : chapter.bookUrl
        target = "\(stem)/chapter/\(identifier)"
        return target
    }

    // MARK: 评论哨兵

    static func preserveReviewMarkers(_ html: String) -> String {
        ReviewMarkerCodec.encode(html)
    }

    // MARK: 缓存

    private func chapterCacheDirectory(bookUrl: String) -> URL {
        ChapterCache.directory(for: bookUrl)
    }

    private func chapterCacheFile(bookUrl: String, chapterIndex: Int) -> URL {
        ChapterCache.file(bookUrl: bookUrl, index: chapterIndex)
    }

    public func getCachedChapterContent(bookUrl: String, chapterIndex: Int) -> String? {
        try? String(contentsOf: chapterCacheFile(bookUrl: bookUrl, chapterIndex: chapterIndex), encoding: .utf8)
    }

    public func saveCachedChapterContent(bookUrl: String, chapterIndex: Int, content: String) {
        guard !content.isEmpty else { return }
        try? content.write(
            to: chapterCacheFile(bookUrl: bookUrl, chapterIndex: chapterIndex),
            atomically: true,
            encoding: .utf8
        )
    }

    public func clearCache(for bookUrl: String) {
        try? FileManager.default.removeItem(at: chapterCacheDirectory(bookUrl: bookUrl))
    }

    public func clearAllChapterCaches() {
        try? FileManager.default.removeItem(at: ChapterCache.root)
    }

    public func hasCachedChapter(bookUrl: String, chapterIndex: Int) -> Bool {
        FileManager.default.fileExists(
            atPath: chapterCacheFile(bookUrl: bookUrl, chapterIndex: chapterIndex).path
        )
    }

    private var preDownloadTask: Task<Void, Never>?

    public func preDownloadChapters(
        around currentIndex: Int,
        chapters: [BookChapter],
        source: BookSource?,
        count: Int = 10
    ) {
        preDownloadTask?.cancel()
        guard !chapters.isEmpty else { return }

        preDownloadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            let nextStart = currentIndex + 1
            let nextEnd = min(currentIndex + count, chapters.count - 1)
            if nextStart <= nextEnd {
                for index in nextStart...nextEnd {
                    if Task.isCancelled { return }
                    await self.prefetch(chapters[index], source: source)
                }
            }

            let previousEnd = max(0, currentIndex - count)
            if currentIndex - 1 >= previousEnd {
                for index in stride(from: currentIndex - 1, through: previousEnd, by: -1) {
                    if Task.isCancelled { return }
                    await self.prefetch(chapters[index], source: source)
                }
            }
        }
    }

    private func prefetch(_ chapter: BookChapter, source: BookSource?) async {
        guard !hasCachedChapter(bookUrl: chapter.bookUrl, chapterIndex: chapter.index) else { return }
        _ = try? await fetchChapterContent(chapter: chapter, source: source)
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    public func getCacheCount(for bookUrl: String) -> Int {
        ChapterCache.count(in: chapterCacheDirectory(bookUrl: bookUrl))
    }

    public func getTotalCacheCount() -> Int {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: ChapterCache.root,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }
        return folders.reduce(0) { total, folder in
            total + ChapterCache.count(in: folder)
        }
    }

    // MARK: HTML 清洗

    public static func cleanHtml(_ raw: String, baseUrl: String? = nil) -> String {
        HTMLCleaner.shared.clean(raw, baseUrl: baseUrl)
    }
}

// MARK: - 详情页准备

private enum DetailPage {
    struct Payload {
        let body: String
        let baseURL: String
        let engine: JSEngine
        let tocContent: Any
    }

    static func make(
        target: String,
        book: Book,
        source: BookSource,
        header: String?,
        diagnostics: ((SourceRequestDiagnostic) -> Void)?
    ) async throws -> Payload {
        if let packed = NetworkClient.dataURLPayload(target) {
            let engine = JSEngine(bookSource: source, baseUrl: target, book: book)
            var detail = ""

            if let initRule = source.ruleBookInfo?.initRule, !initRule.isEmpty,
               let result = engine.eval(script: JSEngine.unwrapJsScript(initRule), result: packed) {
                detail = result as? String ?? "\(result)"
            }
            if let error = engine.lastError {
                JuyueLog.log("[BookDetail] ⚠️ [\(source.bookSourceName)] 详情 init 脚本报错：\(error)")
            }

            DiagnosticHub.emit(SourceRequestDiagnostic(
                step: "详情",
                sourceName: source.bookSourceName,
                url: target,
                responseBytes: detail.utf8.count,
                responsePreview: DiagnosticPreview.make(detail),
                note: "data: 载荷，由 init 脚本取回"
            ), to: diagnostics)

            return Payload(body: detail, baseURL: target, engine: engine, tocContent: packed)
        }

        guard let request = NetworkClient.parseJuyueUrl(
            target,
            defaultHeader: header,
            baseUrl: source.bookSourceUrl
        ) else {
            JuyueLog.log("[BookDetail] ❌ [\(source.bookSourceName)] 详情 URL 解析失败 host=\(URL(string: target)?.host ?? "-")")
            throw ContentError.invalidURL
        }

        let reply = try await ContentRequest.perform(
            request,
            source: source,
            step: "详情",
            diagnostics: diagnostics
        )
        let engine = JSEngine(bookSource: source, baseUrl: request.url.absoluteString, book: book)
        return Payload(
            body: reply.bodyString,
            baseURL: request.url.absoluteString,
            engine: engine,
            tocContent: reply.bodyString
        )
    }
}

private enum ContentPage {
    struct Payload {
        let body: String
        let baseURL: String
        let engine: JSEngine
    }

    static func make(
        target: String,
        chapterIndex: Int,
        book: Book?,
        source: BookSource,
        header: String?,
        diagnostics: ((SourceRequestDiagnostic) -> Void)?
    ) async throws -> Payload {
        if let packed = NetworkClient.dataURLPayload(target) {
            return Payload(
                body: packed,
                baseURL: target,
                engine: JSEngine(bookSource: source, baseUrl: target, book: book)
            )
        }

        guard let request = NetworkClient.parseJuyueUrl(
            target,
            defaultHeader: header,
            baseUrl: source.bookSourceUrl
        ) else {
            JuyueLog.log("[Content] ❌ [\(source.bookSourceName)] 正文 URL 解析失败 第 \(chapterIndex + 1) 章 host=\(URL(string: target)?.host ?? "-")")
            throw ContentError.invalidURL
        }

        let reply = try await ContentRequest.perform(
            request,
            source: source,
            step: "正文",
            diagnostics: diagnostics
        )
        return Payload(
            body: reply.bodyString,
            baseURL: request.url.absoluteString,
            engine: JSEngine(bookSource: source, baseUrl: request.url.absoluteString, book: book)
        )
    }
}

private enum ContentError: Error {
    case invalidURL
}

private enum ContentRequest {
    static func perform(
        _ request: NetworkClient.ParsedRequest,
        source: BookSource,
        step: String,
        diagnostics: ((SourceRequestDiagnostic) -> Void)?
    ) async throws -> NetworkResponse {
        let started = Date()
        let reply: NetworkResponse
        do {
            reply = try await NetworkClient.shared.request(
                parsed: request,
                timeout: nil,
                rateKey: source.bookSourceUrl,
                rateLimit: source.rateLimit
            )
        } catch {
            DiagnosticHub.emit(SourceRequestDiagnostic(
                step: step,
                sourceName: source.bookSourceName,
                url: request.url.absoluteString,
                elapsedMs: Int64(Date().timeIntervalSince(started) * 1000),
                headersSummary: DiagnosticFailure.summarize(request.headers),
                failureKind: DiagnosticFailure.classify(error),
                note: "请求失败：\(error.localizedDescription)"
            ), to: diagnostics)
            throw error
        }

        DiagnosticHub.emit(SourceRequestDiagnostic(
            step: step,
            sourceName: source.bookSourceName,
            url: request.url.absoluteString,
            statusCode: reply.statusCode,
            elapsedMs: Int64(Date().timeIntervalSince(started) * 1000),
            responseBytes: reply.data.count,
            responsePreview: DiagnosticPreview.make(reply.bodyString),
            headersSummary: DiagnosticFailure.summarize(request.headers)
        ), to: diagnostics)
        return reply
    }
}

// MARK: - 目录收集

private final class ChapterCollector {
    private let book: Book
    private let source: BookSource
    private let rule: TocRule
    private let engine: JSEngine
    private let header: String?

    private let pageLimit = 60
    private let pageTimeout: TimeInterval = 20
    private var chapters: [BookChapter] = []
    private var chapterURLs: Set<String> = []
    private var visitedPages: Set<String> = []

    init(book: Book, source: BookSource, rule: TocRule, engine: JSEngine, header: String?) {
        self.book = book
        self.source = source
        self.rule = rule
        self.engine = engine
        self.header = header
    }

    func collect(
        firstPage: RuleAnalyzer,
        firstPageURL: String,
        nextRuleSeed: RuleAnalyzer,
        targetUsesDataURL: Bool,
        onProgress: ((Int, Int) -> Void)?
    ) async -> [BookChapter] {
        parse(from: firstPage, pageURL: firstPageURL)
        visitedPages.insert(firstPageURL)

        guard let nextRule = rule.nextTocUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !nextRule.isEmpty,
              !targetUsesDataURL else {
            return chapters
        }

        var frontier = BookContentService.extractURLs(
            from: nextRuleSeed,
            rule: nextRule,
            baseUrl: firstPageURL
        )
        var round = 0

        while !frontier.isEmpty, visitedPages.count < pageLimit, round < 4 {
            round += 1
            let pending = Array(
                frontier.filter { !visitedPages.contains($0) }
                    .prefix(pageLimit - visitedPages.count)
            )
            guard !pending.isEmpty else { break }
            pending.forEach { visitedPages.insert($0) }

            let pages = await BookContentService.fetchBodies(
                urls: pending,
                header: header,
                baseUrl: source.bookSourceUrl,
                concurrency: 5,
                timeout: pageTimeout,
                rateKey: source.bookSourceUrl,
                rateLimit: source.rateLimit
            )

            var discovered: [String] = []
            for (pageURL, body) in pages {
                let analyzer = RuleAnalyzer(
                    content: body,
                    baseUrl: pageURL,
                    bookSource: source,
                    jsEngine: engine
                )
                parse(from: analyzer, pageURL: pageURL)
                discovered.append(contentsOf: BookContentService.extractURLs(
                    from: analyzer,
                    rule: nextRule,
                    baseUrl: pageURL
                ))
            }
            frontier = discovered
            onProgress?(visitedPages.count, pageLimit)
        }

        JuyueLog.log("[BookDetail] [\(source.bookSourceName)] 目录抓完 \(chapters.count) 章 / \(visitedPages.count) 页 / \(round) 轮")
        return chapters
    }

    private func parse(from analyzer: RuleAnalyzer, pageURL: String) {
        for candidate in analyzer.getElements(rule.chapterList) {
            let row = RuleAnalyzer(
                content: candidate,
                baseUrl: pageURL,
                bookSource: source,
                jsEngine: engine
            )
            let title = row.getString(rule.chapterName)
            let address = row.getString(rule.chapterUrl, isUrl: true)
            guard !title.isEmpty, !address.isEmpty else { continue }
            guard chapterURLs.insert(address).inserted else { continue }
            chapters.append(BookChapter(
                bookUrl: book.bookUrl,
                url: address,
                title: title,
                index: chapters.count
            ))
        }
    }
}

// MARK: - 书籍元数据

private enum MetadataApplier {
    static func apply(
        to input: Book,
        body: String,
        baseURL: String,
        source: BookSource,
        analyzer: RuleAnalyzer
    ) -> Book {
        var book = input

        if let infoRule = source.ruleBookInfo {
            applyRule(infoRule, to: &book, analyzer: analyzer, source: source, baseURL: baseURL)
        }
        applyJSON(body, to: &book)
        return book
    }

    private static func applyRule(
        _ rule: BookInfoRule,
        to book: inout Book,
        analyzer: RuleAnalyzer,
        source: BookSource,
        baseURL: String
    ) {
        let author = analyzer.getString(rule.author)
        if !author.isEmpty { book.author = author }

        let intro = analyzer.getString(rule.intro)
        if !intro.isEmpty { book.intro = BookContentService.cleanHtml(intro) }

        let kind = analyzer.getString(rule.kind)
        if !kind.isEmpty { book.kind = kind }

        let words = analyzer.getString(rule.wordCount)
        if !words.isEmpty { book.wordCount = words }

        let rawCover = analyzer.getString(rule.coverUrl, isUrl: true)
        guard !rawCover.isEmpty else { return }
        let cover = CoverURLResolver.resolve(rawCover, source: source, baseUrl: baseURL)
        if !cover.isEmpty { book.coverUrl = cover }
    }

    private static func applyJSON(_ body: String, to book: inout Book) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if book.author.isEmpty || book.author == "未知作者" {
            if let authors = json["authors"] as? [[String: Any]] {
                let names = authors.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
                if !names.isEmpty {
                    book.author = names.joined(separator: ", ")
                }
            } else if let author = json["author"] as? String, !author.isEmpty {
                book.author = author
            }
        }

        let introKeys = ["introductionZh", "introductionJp", "description", "intro"]
        if let intro = introKeys
            .compactMap({ json[$0] as? String })
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            book.intro = intro
        }

        if book.wordCount == nil || book.wordCount?.isEmpty == true,
           let total = json["totalCharacters"] as? Int {
            book.wordCount = total > 10000
                ? String(format: "%.1f万字", Double(total) / 10000.0)
                : "\(total)字"
        }

        if book.kind == nil || book.kind?.isEmpty == true {
            var tags: [String] = []
            if let type = json["type"] as? String, !type.isEmpty { tags.append(type) }
            if let keywords = json["keywords"] as? [String] { tags.append(contentsOf: keywords) }
            if !tags.isEmpty { book.kind = tags.joined(separator: ",") }
        }
    }
}

// MARK: - 脚本片段

private enum ScriptSnippet {
    static func body(in text: String) -> String? {
        if let open = text.range(of: "<js>") {
            let close = text.range(of: "</js>")?.lowerBound ?? text.endIndex
            return String(text[open.upperBound..<close])
        }
        if text.hasPrefix("@js:") {
            return String(text.dropFirst(4))
        }
        return nil
    }

    static func resolveHeader(_ raw: String?, source: BookSource) -> String? {
        guard let raw, let script = body(in: raw) else { return raw }
        let engine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
        guard let value = engine.context.evaluateScript(script)?.toString(),
              !value.isEmpty,
              value != "undefined" else {
            return raw
        }
        return value
    }
}

private enum RegexReplacement {
    static func apply(_ spec: String, to text: String) -> String {
        let fields = spec.components(separatedBy: "##")
        guard fields.count >= 2,
              let regex = try? NSRegularExpression(pattern: fields[0]) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: fields[1])
    }
}

// MARK: - 本地章节

private enum LocalChapterLoader {
    static func read(chapter: BookChapter) -> String? {
        let address = chapter.url
        let book = chapter.bookUrl
        let looksLocal = address.hasPrefix("file://")
            || address.hasPrefix("epub://")
            || address.hasPrefix("txt://")
            || book.hasPrefix("file://")
            || book.hasPrefix("txt://")
            || address.contains(".xhtml")
            || address.contains(".html")
            || address.contains(".txt")
        guard looksLocal else { return nil }

        if address.contains(".txt"), let text = readPlainText(chapter: chapter) {
            return text
        }

        let epubText = EpubParser.extractChapterContent(fromUrlString: address, bookUrl: book)
        return epubText.isEmpty ? nil : epubText
    }

    private static func readPlainText(chapter: BookChapter) -> String? {
        var path = ""
        if let url = URL(string: chapter.url), url.isFileURL {
            path = url.path
        } else {
            path = chapter.url.replacingOccurrences(of: "file://", with: "")
        }

        var file = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: file.path) {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            file = documents
                .appendingPathComponent("Books/TXT/\(CryptoUtils.md5(chapter.bookUrl))")
                .appendingPathComponent(file.lastPathComponent)
        }
        return try? String(contentsOf: file, encoding: .utf8)
    }
}

// MARK: - 章节缓存

private enum ChapterCache {
    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChapterCache", isDirectory: true)
    }

    static func directory(for bookUrl: String) -> URL {
        let folder = root
            .appendingPathComponent(CryptoUtils.md5(bookUrl), isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    static func file(bookUrl: String, index: Int) -> URL {
        directory(for: bookUrl).appendingPathComponent("\(index).txt")
    }

    static func count(in folder: URL) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return 0
        }
        return files.filter { $0.hasSuffix(".txt") }.count
    }
}

// MARK: - 评论标记编解码

private enum ReviewMarkerCodec {
    static let commentStart = "\u{E000}C\u{1F}"
    static let chapterStart = "\u{E000}H\u{1F}"
    static let godStart = "\u{E000}G\u{1F}"
    static let end = "\u{E001}"

    struct GodCard {
        let text: String
        let imageURL: String?
    }

    static func encode(_ html: String) -> String {
        var text = encodeComments(html)
        text = encodeImages(text)
        return text
    }

    private static func encodeComments(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<comment\\b[^>]*>") else {
            return html
        }
        let source = html as NSString
        var output = html

        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
            let tag = source.substring(with: match.range)
            guard let count = firstCapture(in: tag, pattern: "(?i)count\\s*=\\s*\"(\\d+)\""),
                  let url = firstCapture(in: tag, pattern: "(?i)showReadingBrowser\\(\\s*'([^']+)'") else {
                continue
            }
            let marker = commentStart + count + "\u{1F}" + url + end
            output = (output as NSString).replacingCharacters(in: match.range, with: marker)
        }
        return output
    }

    private static func encodeImages(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<img\\b[^>]*>") else {
            return html
        }
        let source = html as NSString
        var output = html

        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
            let tag = source.substring(with: match.range)
            guard let marker = marker(for: tag) else { continue }
            output = (output as NSString).replacingCharacters(in: match.range, with: marker)
        }
        return output
    }

    private static func marker(for tag: String) -> String? {
        if tag.contains("showFanqieComment("),
           let url = firstCapture(in: tag, pattern: "showFanqieComment\\(\\\\?\"([^\"\\\\]+)") {
            return chapterStart + url + end
        }

        if tag.contains("showCmt("),
           let url = firstCapture(in: tag, pattern: "showCmt\\(\\s*'([^']+)'"),
           let card = godCard(from: tag) {
            return godMarker(card, url: url)
        }

        if tag.range(of: "data:image/svg+xml", options: .caseInsensitive) != nil,
           let card = godCard(from: tag),
           !card.text.isEmpty {
            let url = firstCapture(in: tag, pattern: "showCmt\\(\\s*'([^']+)'") ?? ""
            return godMarker(card, url: url)
        }

        return nil
    }

    private static func godMarker(_ card: GodCard, url: String) -> String {
        let body = Data(card.text.utf8).base64EncodedString()
        let image = Data((card.imageURL ?? "").utf8).base64EncodedString()
        return godStart + body + "\u{1F}" + url + "\u{1F}" + image + end
    }

    static func godCard(from imageTag: String) -> GodCard? {
        guard let raw = firstCapture(in: imageTag, pattern: "(?i)src\\s*=\\s*[\"']([^\"']+)[\"']") else {
            return nil
        }
        let source = ImageSourceNormalizer.normalize(raw)
        guard !source.isEmpty else { return nil }

        if source.hasPrefix("data:image/svg+xml") {
            guard let payload = ImageSourceNormalizer.dataURIPayload(source),
                  let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
                  let svg = String(data: data, encoding: .utf8) else {
                return nil
            }
            let text = svgText(in: svg)
            let image = svgImageURL(in: svg)
            guard !text.isEmpty || image != nil else { return nil }
            return GodCard(text: text, imageURL: image)
        }

        if source.lowercased().hasPrefix("data:") {
            return GodCard(text: "", imageURL: source)
        }

        let text = remoteCardText(source)
        let lower = source.lowercased()
        let svgCard = lower.contains("_svg") || lower.hasSuffix(".svg")
        return GodCard(text: text, imageURL: svgCard ? nil : source)
    }

    private static func svgText(in svg: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<text\\b[^>]*>(.*?)</text>") else {
            return ""
        }
        let source = svg as NSString
        for match in regex.matches(in: svg, range: NSRange(location: 0, length: source.length)) {
            let value = decodeEntities(source.substring(with: match.range(at: 1)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, value != "神评论" {
                return value
            }
        }
        return ""
    }

    private static func svgImageURL(in svg: String) -> String? {
        firstCapture(
            in: svg,
            pattern: "(?is)<image\\b[^>]*(?:href|xlink:href)\\s*=\\s*[\"']([^\"']+)[\"']"
        )
    }

    private static func remoteCardText(_ source: String) -> String {
        guard let components = URLComponents(string: source),
              let value = components.queryItems?.first(where: { $0.name == "text" })?.value else {
            return ""
        }
        return decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ value: String) -> String {
        let table = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'")
        ]
        return table.reduce(value) { text, pair in
            text.replacingOccurrences(of: pair.0, with: pair.1)
        }
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let source = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: source.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return source.substring(with: match.range(at: 1))
    }
}

// MARK: - HTML 清洗

private final class HTMLCleaner {
    static let shared = HTMLCleaner()

    private let lock = NSLock()
    private var cache: [String: String] = [:]

    func clean(_ raw: String, baseUrl: String?) -> String {
        let key = (baseUrl ?? "") + "\u{1}" + raw
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit { return hit }

        let value = performClean(raw, baseUrl: baseUrl)

        lock.lock()
        if cache.count > 128 { cache.removeAll() }
        cache[key] = value
        lock.unlock()
        return value
    }

    private func performClean(_ raw: String, baseUrl: String?) -> String {
        var text = replaceImages(in: raw, baseUrl: baseUrl)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</p>", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<p[^>]*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&lrm;", ""), ("&rlm;", ""), ("&quot;", "\""),
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">")
        ]
        for pair in entities {
            text = text.replacingOccurrences(of: pair.0, with: pair.1)
        }

        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replaceImages(in raw: String, baseUrl: String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?i)<img\\s+[^>]*?>") else {
            return raw
        }
        let source = raw as NSString
        var text = raw

        for match in regex.matches(in: raw, range: NSRange(location: 0, length: source.length)).reversed() {
            let tag = source.substring(with: match.range)
            guard let image = imageSource(from: tag, baseUrl: baseUrl), !image.isEmpty else { continue }
            text = (text as NSString).replacingCharacters(in: match.range, with: "\n\n[image:\(image)]\n\n")
        }
        return text
    }

    private func imageSource(from tag: String, baseUrl: String?) -> String? {
        let directAttributes = [
            "data-original", "data-original-src", "data-src", "data-lazy-src",
            "data-echo", "data-url", "src"
        ]
        for attribute in directAttributes {
            guard let raw = capture(in: tag, attribute: attribute) else { continue }
            let normalized = ImageSourceNormalizer.normalize(raw)
            if !normalized.isEmpty, !isPlaceholder(normalized) {
                return resolve(normalized, baseUrl: baseUrl)
            }
        }

        for attribute in ["data-srcset", "srcset"] {
            guard let raw = capture(in: tag, attribute: attribute),
                  let first = firstURLValue(in: raw) else { continue }
            let normalized = ImageSourceNormalizer.normalize(first)
            return resolve(normalized, baseUrl: baseUrl)
        }
        return nil
    }

    private func capture(in tag: String, attribute: String) -> String? {
        let pattern = "(?i)\(attribute)\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let source = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: source.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return source.substring(with: match.range(at: 1))
    }

    private func firstURLValue(in srcset: String) -> String? {
        let firstEntry = srcset.split(separator: ",").first.map(String.init) ?? srcset
        let token = firstEntry
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .first.map(String.init) ?? firstEntry
        return token.isEmpty ? nil : token
    }

    private func isPlaceholder(_ source: String) -> Bool {
        let lower = source.lowercased()
        if lower.hasPrefix("data:image") {
            return !isUsableDataImage(source)
        }
        return lower == "about:blank" || lower.isEmpty
    }

    private func isUsableDataImage(_ source: String) -> Bool {
        let lower = source.lowercased()
        if lower.contains("r0lgodlh") { return false }
        return source.count > 512
    }

    private func resolve(_ source: String, baseUrl: String?) -> String? {
        if source.hasPrefix("data:") {
            return isUsableDataImage(source) ? source : nil
        }
        if source.contains("discord_logo") || source.contains("nophoto.png") {
            return nil
        }
        if source.hasPrefix("http://") || source.hasPrefix("https://") { return source }
        if source.hasPrefix("//") { return "https:" + source }

        guard let baseUrl, let base = URL(string: baseUrl) else { return source }
        if source.hasPrefix("/") {
            return "\(base.scheme ?? "https")://\(base.host ?? "")" + source
        }
        return base.deletingLastPathComponent().appendingPathComponent(source).absoluteString
    }
}

// MARK: - 替换净化

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
    public static func apply(_ text: String, rules: [TextReplaceRule]) -> String {
        guard !text.isEmpty, !rules.isEmpty else { return text }
        let ordered = rules.sorted { $0.from.count > $1.from.count }
        return ordered.reduce(text) { result, rule in
            guard !rule.from.isEmpty else { return result }
            return result.replacingOccurrences(of: rule.from, with: rule.to)
        }
    }
}

public final class TextPurifier: ObservableObject {
    public static let shared = TextPurifier()

    private let key = "text_purifier_rules_v1"

    @Published public var rules: [ReplacementRule] = [] {
        didSet { save() }
    }

    public init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ReplacementRule].self, from: data) else {
            return
        }
        rules = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    public func apply(_ text: String) -> String {
        guard !text.isEmpty, !rules.isEmpty else { return text }
        return rules.reduce(text) { result, rule in
            guard rule.enabled, !rule.pattern.isEmpty else { return result }
            return apply(rule, to: result)
        }
    }

    private func apply(_ rule: ReplacementRule, to text: String) -> String {
        guard rule.isRegex else {
            return text.replacingOccurrences(of: rule.pattern, with: rule.replacement)
        }
        guard let regex = try? NSRegularExpression(
            pattern: rule.pattern,
            options: [.dotMatchesLineSeparators]
        ) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: rule.replacement
        )
    }
}

// MARK: - 阅读订阅源

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
    public var loginCheckJs: String?
    public var enabledCookieJar: Bool?
    public var shouldOverrideUrlLoading: String?
    public var showWebLog: Bool?
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

    func ruleContext(jsLib: String? = nil) -> BookSource {
        var shim = BookSource(bookSourceUrl: sourceUrl, bookSourceName: sourceName)
        shim.header = header
        shim.enabled = enabled
        shim.jsLib = jsLib ?? self.jsLib
        shim.loginUrl = loginUrl
        shim.loginUi = loginUi
        return shim
    }

    public var listUrl: String {
        if singleUrl == false, let sortUrl, !sortUrl.isEmpty {
            return sortUrl
        }
        return sourceUrl
    }

    private var hasArticleRules: Bool {
        !(ruleArticles ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var usesDirectWebPage: Bool {
        guard singleUrl == true, !hasArticleRules else { return false }
        guard let url = URL(string: sourceUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }
        return true
    }

    public var isExternalDeepLink: Bool {
        guard singleUrl == true, !hasArticleRules else { return false }
        guard let url = URL(string: sourceUrl),
              let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty,
              scheme != "http",
              scheme != "https" else {
            return false
        }
        return true
    }

    public var staticRequestHeaders: [String: String] {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !header.isEmpty,
              !header.contains("<js>"),
              !header.hasPrefix("@js:") else {
            return [:]
        }

        if let data = header.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object.reduce(into: [:]) { fields, pair in
                fields[pair.key] = String(describing: pair.value)
            }
        }

        var fields: [String: String] = [:]
        for line in header.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            fields[parts[0]] = parts[1]
        }
        return fields
    }
}

public struct SubscribeArticle: Identifiable, Equatable {
    public var id: String { link.isEmpty ? title : link }
    public var title: String
    public var link: String
    public var date: String?
    public var summary: String?
    public var imageUrl: String?

    public init(
        title: String,
        link: String,
        date: String? = nil,
        summary: String? = nil,
        imageUrl: String? = nil
    ) {
        self.title = title
        self.link = link
        self.date = date
        self.summary = summary
        self.imageUrl = imageUrl
    }
}

public enum SubscribeSourceService {
    public static func fetchArticles(source: SubscribeSource, pageUrl: String? = nil) async throws -> [SubscribeArticle] {
        try await fetchPage(source: source, pageUrl: pageUrl).articles
    }

    public static func fetchPage(
        source: SubscribeSource,
        pageUrl: String? = nil
    ) async throws -> (articles: [SubscribeArticle], nextPage: String?) {
        let target = await resolveTarget(source: source, pageUrl: pageUrl)
        let jsLib = await resolvedJsLib(source.jsLib)
        let header = await resolvedHeader(source: source, jsLib: jsLib)

        let fetched: FetchedDocument
        do {
            fetched = try await fetchDocument(
                target: target,
                source: source,
                header: header
            )
        } catch SubscribeError.invalidURL {
            return ([], nil)
        } catch SubscribeError.badStatus {
            return ([], nil)
        }
        JuyueLog.log("[订阅源] \(source.sourceName) 抓取 host=\(URL(string: target)?.host ?? "-") 字节=\(fetched.body.count)")

        guard let listRule = source.ruleArticles, !listRule.isEmpty else {
            let items = try await RSSService.shared.fetchFeed(url: target, sourceName: source.sourceName)
            let articles = items.map {
                SubscribeArticle(
                    title: $0.title,
                    link: $0.link,
                    date: $0.date,
                    summary: $0.summary,
                    imageUrl: nil
                )
            }
            return (articles, nil)
        }

        let context = source.ruleContext(jsLib: jsLib)
        let engine = JSEngine(bookSource: context, baseUrl: fetched.baseURL)
        let analyzer = RuleAnalyzer(
            content: fetched.body,
            baseUrl: fetched.baseURL,
            bookSource: context,
            jsEngine: engine
        )
        let elements = analyzer.getElements(listRule)
        JuyueLog.log("[订阅源] \(source.sourceName) 规则 \(listRule) 命中=\(elements.count)")

        let articles = elements.compactMap { element -> SubscribeArticle? in
            let row = RuleAnalyzer(
                content: element,
                baseUrl: fetched.baseURL,
                bookSource: context,
                jsEngine: engine
            )
            let title = row.getString(source.ruleTitle)
            let link = row.getString(source.ruleLink, isUrl: true)
            guard !title.isEmpty || !link.isEmpty else { return nil }

            let date = row.getString(source.rulePubDate)
            let summary = row.getString(source.ruleDescription)
            let image = row.getString(source.ruleImage, isUrl: true)
            return SubscribeArticle(
                title: title.isEmpty ? link : title,
                link: link,
                date: date.isEmpty ? nil : date,
                summary: summary.isEmpty ? nil : BookContentService.cleanHtml(summary),
                imageUrl: image.isEmpty ? nil : image
            )
        }

        var nextPage: String?
        if let nextRule = source.ruleNextPage, !nextRule.isEmpty {
            let value = analyzer.getString(nextRule, isUrl: true)
            if !value.isEmpty { nextPage = value }
        }
        return (articles, nextPage)
    }

    public static func fetchSortUrls(source: SubscribeSource) async -> [(name: String, url: String)] {
        guard let raw = source.sortUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return []
        }

        let text: String
        if let script = ScriptSnippet.body(in: raw) {
            let jsLib = await resolvedJsLib(source.jsLib)
            let context = source.ruleContext(jsLib: jsLib)
            let engine = JSEngine(bookSource: context, baseUrl: source.sourceUrl)
            text = (engine.eval(script: script) as? String) ?? ""
        } else {
            text = raw
        }

        var rows: [(String, String)] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let fields = trimmed.components(separatedBy: "::")
            let name = fields.count > 1 ? fields[0] : trimmed
            var address = fields.count > 1 ? fields[1] : trimmed

            if address.hasPrefix("/"), let base = URL(string: source.sourceUrl),
               let resolved = URL(string: address, relativeTo: base) {
                address = resolved.absoluteString
            }
            guard !address.isEmpty else { continue }
            rows.append((name, address))
        }
        return rows
    }

    public static func fetchContent(article: SubscribeArticle, source: SubscribeSource) async throws -> String {
        let jsLib = await resolvedJsLib(source.jsLib)
        let header = await resolvedHeader(source: source, jsLib: jsLib)
        guard !article.link.isEmpty,
              let request = NetworkClient.parseJuyueUrl(
                article.link,
                defaultHeader: header,
                baseUrl: source.sourceUrl
              ) else {
            return ""
        }

        let reply = try await NetworkClient.shared.request(parsed: request)
        guard (200..<400).contains(reply.statusCode) else { return "" }

        let base = request.url.absoluteString
        if let rule = source.ruleContent, !rule.isEmpty {
            let context = source.ruleContext(jsLib: jsLib)
            let analyzer = RuleAnalyzer(
                content: reply.bodyString,
                baseUrl: base,
                bookSource: context,
                jsEngine: JSEngine(bookSource: context, baseUrl: base)
            )
            let extracted = BookContentService.cleanHtml(analyzer.getString(rule), baseUrl: base)
            if !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return extracted
            }
        }
        return BookContentService.cleanHtml(reply.bodyString, baseUrl: base)
    }

    public static func decodeSources(from json: String) throws -> [SubscribeSource] {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()

        if let list = try? decoder.decode([SubscribeSource].self, from: data) {
            return list.filter { !$0.sourceUrl.isEmpty }
        }
        let single = try decoder.decode(SubscribeSource.self, from: data)
        return single.sourceUrl.isEmpty ? [] : [single]
    }

    // MARK: 内部

    private struct FetchedDocument {
        let body: String
        let baseURL: String
    }

    private static func resolveTarget(source: SubscribeSource, pageUrl: String?) async -> String {
        var target: String
        if let pageUrl, !pageUrl.isEmpty {
            target = pageUrl
        } else if source.singleUrl == false {
            let categories = await fetchSortUrls(source: source)
            target = categories.first?.url ?? source.listUrl
        } else {
            target = source.listUrl
        }

        return target
            .replacingOccurrences(of: "{{page}}", with: "1")
            .replacingOccurrences(of: "{{searchPage}}", with: "1")
            .replacingOccurrences(of: "{{key}}", with: "")
            .replacingOccurrences(of: "{{searchKey}}", with: "")
    }

    private static func fetchDocument(
        target: String,
        source: SubscribeSource,
        header: String?
    ) async throws -> FetchedDocument {
        if let packed = NetworkClient.dataURLPayload(target) {
            return FetchedDocument(body: packed, baseURL: target)
        }

        guard let request = NetworkClient.parseJuyueUrl(
            target,
            defaultHeader: header,
            baseUrl: source.sourceUrl
        ) else {
            throw SubscribeError.invalidURL
        }

        let reply = try await NetworkClient.shared.request(parsed: request)
        guard (200..<400).contains(reply.statusCode) else {
            throw SubscribeError.badStatus
        }
        return FetchedDocument(body: reply.bodyString, baseURL: request.url.absoluteString)
    }

    private static func resolvedJsLib(_ raw: String?) async -> String? {
        guard let library = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !library.isEmpty else {
            return nil
        }
        guard let data = library.data(using: .utf8),
              let mapping = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return library
        }

        var scripts: [String] = []
        for address in mapping.values {
            guard let url = URL(string: address),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            scripts.append(text)
        }
        return scripts.isEmpty ? nil : scripts.joined(separator: "\n")
    }

    private static func resolvedHeader(source: SubscribeSource, jsLib: String?) async -> String? {
        guard let header = source.header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !header.isEmpty else {
            return nil
        }
        guard let script = ScriptSnippet.body(in: header) else {
            return header
        }

        let context = source.ruleContext(jsLib: jsLib)
        let engine = JSEngine(bookSource: context, baseUrl: source.sourceUrl)
        guard let value = engine.eval(script: script) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private enum SubscribeError: Error {
        case invalidURL
        case badStatus
    }
}

// MARK: - RSS / Atom

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

public final class RSSService {
    public static let shared = RSSService()

    public init() {}

    public func fetchFeed(url: String, sourceName: String = "") async throws -> [RSSItem] {
        guard let request = NetworkClient.parseJuyueUrl(url) else { return [] }
        let reply = try await NetworkClient.shared.request(parsed: request)

        let delegate = RSSParserDelegate(sourceName: sourceName)
        let parser = XMLParser(data: Data(reply.bodyString.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }
}

private final class RSSParserDelegate: NSObject, XMLParserDelegate {
    private let sourceName: String
    private(set) var items: [RSSItem] = []

    private var insideItem = false
    private var current = ""
    private var buffer = ""
    private var title = ""
    private var link = ""
    private var summary = ""
    private var date = ""

    init(sourceName: String) {
        self.sourceName = sourceName
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        current = elementName.lowercased()
        buffer = ""
        if current == "item" || current == "entry" {
            insideItem = true
            title = ""
            link = ""
            summary = ""
            date = ""
        }
        if insideItem, current == "link", link.isEmpty, let href = attributeDict["href"] {
            link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if insideItem {
            switch name {
            case "title":
                if title.isEmpty { title = value }
            case "link":
                if link.isEmpty { link = value }
            case "description", "summary", "content", "content:encoded":
                if summary.isEmpty { summary = value }
            case "pubdate", "published", "updated", "dc:date":
                if date.isEmpty { date = value }
            case "item", "entry":
                insideItem = false
                let item = RSSItem(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    link: link.trimmingCharacters(in: .whitespacesAndNewlines),
                    summary: BookContentService.cleanHtml(summary),
                    date: date.trimmingCharacters(in: .whitespacesAndNewlines),
                    sourceName: sourceName
                )
                if !item.title.isEmpty { items.append(item) }
            default:
                break
            }
        }
        buffer = ""
    }
}

public final class RSSStore: ObservableObject {
    public static let shared = RSSStore()

    @Published public var sources: [RSSSource] = []

    private let key = "rss_sources_v1"

    public init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RSSSource].self, from: data) else {
            return
        }
        sources = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    public func add(name: String, url: String) {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        sources.append(RSSSource(name: label, url: address))
        save()
        JuyueLog.log("[RSS] 新增订阅 \(sources.count) 个")
    }

    public func remove(_ source: RSSSource) {
        sources.removeAll { $0.id == source.id }
        save()
        JuyueLog.log("[RSS] 删除订阅 \(sources.count) 个")
    }
}

// MARK: - OPDS

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

    public static func == (lhs: OPDSEntry, rhs: OPDSEntry) -> Bool {
        lhs.id == rhs.id
    }
}

public final class OPDSService {
    public static let shared = OPDSService()

    public init() {}

    public func fetch(
        _ urlString: String,
        username: String = "",
        password: String = ""
    ) async throws -> (title: String, entries: [OPDSEntry]) {
        guard let request = authorizedRequest(urlString, username: username, password: password) else {
            return ("", [])
        }

        let reply = try await NetworkClient.shared.request(parsed: request)
        let delegate = OPDSXMLDelegate(baseURL: request.url)
        let parser = XMLParser(data: Data(reply.bodyString.utf8))
        parser.delegate = delegate
        parser.parse()
        return (delegate.feedTitle, delegate.entries)
    }

    public func download(_ href: String, username: String = "", password: String = "") async throws -> URL {
        guard var request = authorizedRequest(href, username: username, password: password) else {
            throw URLError(.badURL)
        }
        request = NetworkClient.ParsedRequest(
            url: request.url,
            method: "GET",
            headers: request.headers,
            body: nil
        )

        let reply = try await NetworkClient.shared.request(parsed: request)
        let name = request.url.lastPathComponent.isEmpty ? "opds-book.epub" : request.url.lastPathComponent
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try reply.data.write(to: destination)
        return destination
    }

    private func authorizedRequest(
        _ raw: String,
        username: String,
        password: String
    ) -> NetworkClient.ParsedRequest? {
        var request = NetworkClient.parseJuyueUrl(raw)
        if request == nil, let url = URL(string: raw) {
            request = NetworkClient.ParsedRequest(url: url, method: "GET", headers: [:], body: nil)
        }
        if request == nil,
           let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: encoded) {
            request = NetworkClient.ParsedRequest(url: url, method: "GET", headers: [:], body: nil)
        }
        guard let request else { return nil }
        guard !username.isEmpty else { return request }

        var headers = request.headers
        headers["Authorization"] = "Basic " + CryptoUtils.base64Encode("\(username):\(password)")
        return NetworkClient.ParsedRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        )
    }
}

private final class OPDSXMLDelegate: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private(set) var feedTitle = ""
    private(set) var entries: [OPDSEntry] = []

    private var insideEntry = false
    private var collectingFeedTitle = false
    private var current = ""
    private var title = ""
    private var summary = ""
    private var author = ""
    private var href = ""
    private var navigation = false
    private var acquisitions: [(mime: String, href: String)] = []

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        current = ""

        switch name {
        case "entry":
            insideEntry = true
            title = ""
            summary = ""
            author = ""
            href = ""
            navigation = false
            acquisitions = []
        case "title":
            if !insideEntry { collectingFeedTitle = true }
        case "link":
            handleLink(attributes: attributeDict)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)

        if insideEntry {
            switch name {
            case "title":
                if title.isEmpty { title = value }
            case "summary", "content":
                if summary.isEmpty { summary = value }
            case "name":
                if author.isEmpty { author = value }
            case "entry":
                insideEntry = false
                if !title.isEmpty {
                    entries.append(OPDSEntry(
                        title: title,
                        href: href,
                        summary: BookContentService.cleanHtml(summary),
                        author: author,
                        isNavigation: navigation && acquisitions.isEmpty,
                        acquisitions: acquisitions
                    ))
                }
            default:
                break
            }
        } else if name == "title", collectingFeedTitle {
            feedTitle = value
            collectingFeedTitle = false
        }
        current = ""
    }

    private func handleLink(attributes: [String: String]) {
        guard let raw = attributes["href"] else { return }
        let rel = attributes["rel"] ?? ""
        let type = attributes["type"] ?? ""
        let link = absolute(raw)

        if rel.contains("acquisition") {
            acquisitions.append((type, link))
            return
        }
        guard rel.contains("subsection") || type.contains("atom") || rel.isEmpty else { return }

        if href.isEmpty || rel.contains("subsection") {
            href = link
            if rel.contains("subsection") { navigation = true }
        }
    }

    private func absolute(_ link: String) -> String {
        guard !link.isEmpty else { return "" }
        if link.hasPrefix("http") { return link }
        return URL(string: link, relativeTo: baseURL)?.absoluteString ?? link
    }
}
