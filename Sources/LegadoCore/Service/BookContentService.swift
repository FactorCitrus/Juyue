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

        LegadoLog.log("[BookDetail] [\(source.bookSourceName)] 抓详情与目录 host=\(URL(string: target)?.host ?? "-")")

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
        } catch {
            // 目录地址可能属于旧源或已失效：退回书页地址再抓一次。
            if !book.tocUrl.isEmpty, book.tocUrl != book.bookUrl {
                var fallback = book
                fallback.tocUrl = ""
                return try await fetchBookDetail(
                    book: fallback,
                    source: source,
                    onProgress: onProgress,
                    diagnostics: diagnostics,
                    includeChapters: includeChapters
                )
            }
            throw error
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

        // 目录页抓得到但一条章节都没有，同样按「旧目录地址失效」处理。
        if includeChapters, chapters.isEmpty, !book.tocUrl.isEmpty, book.tocUrl != book.bookUrl {
            var fallback = book
            fallback.tocUrl = ""
            if let retried = try? await fetchBookDetail(
                book: fallback,
                source: source,
                onProgress: onProgress,
                diagnostics: diagnostics,
                includeChapters: true
            ), !retried.chapters.isEmpty {
                return retried
            }
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
        LegadoLog.log("[BookDetail] ✅ [\(source.bookSourceName)] 解析完成 book#\(fingerprint) 书名/作者长度=\(updated.name.count)/\(updated.author.count) 简介=\(updated.intro?.count ?? 0) 章数=\(chapters.count)")
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

        LegadoLog.log("[Content] [\(source.bookSourceName)] 抓正文 第 \(chapter.index + 1) 章 host=\(URL(string: target)?.host ?? "-")")

        let page: ContentPage.Payload
        do {
            page = try await ContentPage.make(
                target: target,
                chapterIndex: chapter.index,
                book: book,
                source: source,
                contentRule: contentRule,
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

        let nextRule = contentRule.nextContentUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let text: String
        if nextRule.isEmpty {
            text = assembleSinglePage(
                analyzer: analyzer,
                contentRule: contentRule,
                baseURL: page.baseURL,
                extractedText: page.extractedText,
                book: book
            )
        } else {
            text = await assemblePaginatedContent(
                firstAnalyzer: analyzer,
                firstBaseURL: page.baseURL,
                firstExtractedText: page.extractedText,
                initialURL: target,
                chapter: chapter,
                contentRule: contentRule,
                nextRule: nextRule,
                source: source,
                header: header,
                book: book,
                diagnostics: diagnostics
            )
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

    // MARK: 正文拼页

    // 测试需要直接验证 payAction / callBackJs / imageStyle 不进入正文变换链，
    // 所以保持 internal 而不是 private。
    func assembleSinglePage(
        analyzer: RuleAnalyzer,
        contentRule: ContentRule,
        baseURL: String,
        extractedText: String? = nil,
        book: Book?
    ) -> String {
        var text = extractedText ?? ContentRuleExtractor.text(from: analyzer, rule: contentRule)
        text = Self.preserveReviewMarkers(text)

        if let replaceRegex = contentRule.replaceRegex, !replaceRegex.isEmpty {
            text = RegexReplacement.apply(replaceRegex, to: text)
        }

        text = Self.cleanHtml(text, baseUrl: baseURL)

        if book?.useReplaceRule != false {
            text = TextPurifier.shared.apply(text)
        }
        return text
    }

    /// 按 `nextContentUrl` 逐页取正文并拼接。
    ///
    /// 页数上限、URL 去重和整体 deadline 都在这里兜住：中途失败、超时或被取消时
    /// 返回已经拿到的页，而不是让整章失败。替换净化等全部拼完再跑一次，避免每页
    /// 重复套规则（水印类规则重复执行会把正文一起吃掉）。
    private func assemblePaginatedContent(
        firstAnalyzer: RuleAnalyzer,
        firstBaseURL: String,
        firstExtractedText: String?,
        initialURL: String,
        chapter: BookChapter,
        contentRule: ContentRule,
        nextRule: String,
        source: BookSource,
        header: String?,
        book: Book?,
        diagnostics: ((SourceRequestDiagnostic) -> Void)?
    ) async -> String {
        var segments: [String] = []
        let firstSegment = cleanPage(
            firstAnalyzer,
            rule: contentRule,
            baseURL: firstBaseURL,
            extractedText: firstExtractedText
        )
        if !firstSegment.isEmpty { segments.append(firstSegment) }

        var currentAnalyzer = firstAnalyzer
        var currentBaseURL = firstBaseURL
        var visited: Set<String> = [firstBaseURL, initialURL]
        var fetched = 1
        let deadline = Date().addingTimeInterval(ContentPagination.totalDeadline)

        pagination: while fetched < ContentPagination.pageLimit {
            if Task.isCancelled { break }
            let candidates = BookContentService.extractURLs(
                from: currentAnalyzer,
                rule: nextRule,
                baseUrl: currentBaseURL
            )
            let pending = ContentPagination.nextURLs(
                candidates: candidates,
                visited: visited,
                fetchedCount: fetched
            )
            guard !pending.isEmpty else { break }

            for url in pending {
                if Task.isCancelled { break pagination }
                guard fetched < ContentPagination.pageLimit else { break pagination }

                let remaining = ContentPagination.remaining(deadline)
                guard remaining > 0 else {
                    LegadoLog.log("[Content] [\(source.bookSourceName)] 分页超时，返回已抓 \(fetched) 页")
                    break pagination
                }

                visited.insert(url)
                guard let next = await fetchContentPage(
                    url: url,
                    chapter: chapter,
                    source: source,
                    contentRule: contentRule,
                    header: header,
                    book: book,
                    timeout: remaining,
                    diagnostics: diagnostics
                ) else {
                    LegadoLog.log("[Content] [\(source.bookSourceName)] 分页抓取失败，返回已抓 \(fetched) 页")
                    break pagination
                }

                fetched += 1
                let segment = cleanPage(
                    next.analyzer,
                    rule: contentRule,
                    baseURL: next.baseURL,
                    extractedText: next.extractedText
                )
                if !segment.isEmpty { segments.append(segment) }
                currentAnalyzer = next.analyzer
                currentBaseURL = next.baseURL
            }
        }

        if fetched > 1 {
            LegadoLog.log("[Content] [\(source.bookSourceName)] 正文分页 \(fetched) 页 / \(segments.count) 段")
        }

        var text = segments.joined(separator: "\n\n")
        if book?.useReplaceRule != false {
            text = TextPurifier.shared.apply(text)
        }
        return text
    }

    private struct PaginatedPage {
        let analyzer: RuleAnalyzer
        let baseURL: String
        let extractedText: String?

        init(analyzer: RuleAnalyzer, baseURL: String, extractedText: String? = nil) {
            self.analyzer = analyzer
            self.baseURL = baseURL
            self.extractedText = extractedText
        }
    }

    private func fetchContentPage(
        url: String,
        chapter: BookChapter,
        source: BookSource,
        contentRule: ContentRule,
        header: String?,
        book: Book?,
        timeout: TimeInterval,
        diagnostics: ((SourceRequestDiagnostic) -> Void)?
    ) async -> PaginatedPage? {
        let body: String
        let baseURL: String
        let engine: JSEngine
        var extractedText: String?

        if let packed = NetworkClient.dataURLPayload(url) {
            body = packed
            baseURL = url
            engine = JSEngine(bookSource: source, baseUrl: url, book: book)
        } else {
            guard let request = NetworkClient.parseJuyueUrl(
                url,
                defaultHeader: header,
                baseUrl: source.bookSourceUrl
            ) else {
                return nil
            }
            if let page = await ContentWebJs.payload(
                request: request,
                rule: contentRule,
                timeout: min(timeout, ContentWebJs.defaultTimeout),
                source: source,
                book: book
            ) {
                body = page.body
                baseURL = page.baseURL
                engine = page.engine
                extractedText = page.extractedText
            } else {
                guard let reply = try? await ContentRequest.perform(
                    request,
                    source: source,
                    step: "正文分页",
                    diagnostics: diagnostics,
                    timeout: timeout
                ) else {
                    return nil
                }
                body = reply.bodyString
                baseURL = request.url.absoluteString
                engine = JSEngine(bookSource: source, baseUrl: baseURL, book: book)
            }
        }

        engine.context.setObject(
            ["index": chapter.index, "title": chapter.title, "url": url],
            forKeyedSubscript: "chapter" as NSString
        )
        return PaginatedPage(
            analyzer: RuleAnalyzer(
                content: body,
                baseUrl: baseURL,
                bookSource: source,
                jsEngine: engine
            ),
            baseURL: baseURL,
            extractedText: extractedText
        )
    }

    /// 单页正文清洗：只做页面自己的事，替换净化留给拼接后的整段。
    private func cleanPage(
        _ analyzer: RuleAnalyzer,
        rule: ContentRule,
        baseURL: String,
        extractedText: String? = nil
    ) -> String {
        var text = extractedText ?? ContentRuleExtractor.text(from: analyzer, rule: rule)
        text = Self.preserveReviewMarkers(text)

        if let replaceRegex = rule.replaceRegex, !replaceRegex.isEmpty {
            text = RegexReplacement.apply(replaceRegex, to: text)
        }

        return Self.cleanHtml(text, baseUrl: baseURL)
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
        try? FileManager.default.removeItem(at: ChapterCache.allRoot)
    }

    public func hasCachedChapter(bookUrl: String, chapterIndex: Int) -> Bool {
        FileManager.default.fileExists(
            atPath: chapterCacheFile(bookUrl: bookUrl, chapterIndex: chapterIndex).path
        )
    }

    /// 只扫本地缓存统计字数，不发网络请求；没缓存的章节不返回。
    /// 不建目录、不碰章节模型，适合丢到后台队列跑。
    public static func cachedChapterWordCounts(bookUrl: String, indices: [Int]) -> [Int: Int] {
        let folder = ChapterCache.root
            .appendingPathComponent(CryptoUtils.md5(bookUrl), isDirectory: true)
        var counts: [Int: Int] = [:]
        for index in indices {
            let file = folder.appendingPathComponent("\(index).txt")
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            counts[index] = ChapterWordCounter.count(content)
        }
        return counts
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
                LegadoLog.log("[BookDetail] ⚠️ [\(source.bookSourceName)] 详情 init 脚本报错：\(error)")
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

        if let scheme = NetworkClient.unsupportedScheme(in: target) {
            let error = UnsupportedBookSourceSchemeError(
                scheme: scheme,
                sourceName: source.bookSourceName
            )
            LegadoLog.log("[BookDetail] ❌ [\(source.bookSourceName)] 自定义协议 \(scheme) 不支持")
            DiagnosticHub.emit(SourceRequestDiagnostic(
                step: "详情",
                sourceName: source.bookSourceName,
                url: target,
                failureKind: DiagnosticFailure.classify(error),
                note: error.localizedDescription
            ), to: diagnostics)
            throw error
        }

        guard let request = NetworkClient.parseJuyueUrl(
            target,
            defaultHeader: header,
            baseUrl: source.bookSourceUrl
        ) else {
            LegadoLog.log("[BookDetail] ❌ [\(source.bookSourceName)] 详情 URL 解析失败 host=\(URL(string: target)?.host ?? "-")")
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
        /// `webJs` 返回的非空结果；为空时正文仍走页面 HTML 上的原规则。
        let extractedText: String?

        init(body: String, baseURL: String, engine: JSEngine, extractedText: String? = nil) {
            self.body = body
            self.baseURL = baseURL
            self.engine = engine
            self.extractedText = extractedText
        }
    }

    static func make(
        target: String,
        chapterIndex: Int,
        book: Book?,
        source: BookSource,
        contentRule: ContentRule,
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

        if let scheme = NetworkClient.unsupportedScheme(in: target) {
            let error = UnsupportedBookSourceSchemeError(
                scheme: scheme,
                sourceName: source.bookSourceName
            )
            LegadoLog.log("[Content] ❌ [\(source.bookSourceName)] 自定义协议 \(scheme) 不支持 第 \(chapterIndex + 1) 章")
            DiagnosticHub.emit(SourceRequestDiagnostic(
                step: "正文",
                sourceName: source.bookSourceName,
                url: target,
                failureKind: DiagnosticFailure.classify(error),
                note: error.localizedDescription
            ), to: diagnostics)
            throw error
        }

        guard let request = NetworkClient.parseJuyueUrl(
            target,
            defaultHeader: header,
            baseUrl: source.bookSourceUrl
        ) else {
            LegadoLog.log("[Content] ❌ [\(source.bookSourceName)] 正文 URL 解析失败 第 \(chapterIndex + 1) 章 host=\(URL(string: target)?.host ?? "-")")
            throw ContentError.invalidURL
        }

        if let page = await ContentWebJs.payload(
            request: request,
            rule: contentRule,
            timeout: ContentWebJs.defaultTimeout,
            source: source,
            book: book
        ) {
            return page
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

/// `ContentRule.webJs`：用无声网页打开正文页，在 `didFinish` 后执行脚本。
///
/// 脚本返回非空文本时优先采用；返回空则保留渲染后的 HTML，交给原 `content` 规则。
/// 抓取器未安装、加载失败或超时都返回 nil，由调用方回退普通请求，不让整章失败。
private enum ContentWebJs {
    static let defaultTimeout: TimeInterval = 20

    static func payload(
        request: NetworkClient.ParsedRequest,
        rule: ContentRule,
        timeout: TimeInterval,
        source: BookSource,
        book: Book?
    ) async -> ContentPage.Payload? {
        guard let script = rule.webJs?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        let sourceRegex = rule.sourceRegex?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shouldSniff = !sourceRegex.isEmpty
        // `sourceRegex` 只在 WebView 加载正文页时才有意义；没有 webJs 时，
        // 只有 URL 明确要求走 WebView 才进来，避免把普通请求也拉去渲染。
        guard !script.isEmpty || (shouldSniff && request.usesWebView) else {
            return nil
        }
        guard HeadlessWebView.shared.loader != nil else {
            LegadoLog.log("[Content] [\(source.bookSourceName)] webJs 需要无声网页，当前未安装，改用普通抓取")
            return nil
        }

        await SourceRateLimiter.shared.acquire(key: source.bookSourceUrl, limit: source.rateLimit)
        let js = script.isEmpty ? nil : JSEngine.unwrapJsScript(script)
        do {
            let result = try await NetworkClient.shared.headlessFetch(
                parsed: request,
                javaScript: js,
                timeout: timeout,
                capturesResourceURLs: shouldSniff
            )
            let baseURL = result.finalURL.absoluteString
            if shouldSniff,
               let matched = SourceURLSniffer.firstMatch(in: result.resourceURLs, pattern: sourceRegex) {
                LegadoLog.log("[Content] [\(source.bookSourceName)] sourceRegex 命中资源 URL")
                return ContentPage.Payload(
                    body: matched,
                    baseURL: baseURL,
                    engine: JSEngine(bookSource: source, baseUrl: baseURL, book: book),
                    extractedText: nil
                )
            }
            if shouldSniff {
                LegadoLog.log("[Content] [\(source.bookSourceName)] sourceRegex 未命中，按页面 HTML 处理")
            }
            let extracted = WebJsContent.text(from: result.javaScriptResult)
            if extracted == nil,
               result.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                LegadoLog.log("[Content] [\(source.bookSourceName)] webJs 结果与页面 HTML 都为空，改用普通抓取")
                return nil
            }
            LegadoLog.log(
                "[Content] [\(source.bookSourceName)] webJs 命中 "
                    + (extracted == nil ? "空结果，用页面 HTML" : "\(extracted?.count ?? 0) 字")
            )
            return ContentPage.Payload(
                body: result.html,
                baseURL: baseURL,
                engine: JSEngine(bookSource: source, baseUrl: baseURL, book: book),
                extractedText: extracted
            )
        } catch {
            LegadoLog.log("[Content] [\(source.bookSourceName)] webJs 失败，回退普通抓取：\(error.localizedDescription)")
            return nil
        }
    }
}

private enum ContentError: Error, LocalizedError {
    case invalidURL

    var errorDescription: String? {
        "书源返回的请求地址无法解析"
    }
}

private enum ContentRequest {
    static func perform(
        _ request: NetworkClient.ParsedRequest,
        source: BookSource,
        step: String,
        diagnostics: ((SourceRequestDiagnostic) -> Void)?,
        timeout: TimeInterval? = nil
    ) async throws -> NetworkResponse {
        let started = Date()
        let reply: NetworkResponse
        do {
            reply = try await NetworkClient.shared.request(
                parsed: request,
                timeout: timeout,
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

        LegadoLog.log("[BookDetail] [\(source.bookSourceName)] 目录抓完 \(chapters.count) 章 / \(visitedPages.count) 页 / \(round) 轮")
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

// MARK: - 正文规则与分页规划

enum ContentRuleExtractor {
    /// `content` 取不到正文时回退 `subContent`；两者都空才算空。
    static func text(from analyzer: RuleAnalyzer, rule: ContentRule) -> String {
        let primary = analyzer.getString(rule.content)
        if !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return primary
        }
        return analyzer.getString(rule.subContent)
    }
}

/// 正文分页的纯逻辑：去重、页数上限、整体 deadline 判定。
enum ContentPagination {
    static let pageLimit = 10
    static let totalDeadline: TimeInterval = 30

    static func nextURLs(
        candidates: [String],
        visited: Set<String>,
        fetchedCount: Int,
        limit: Int = pageLimit
    ) -> [String] {
        guard fetchedCount < limit else { return [] }
        var seen = visited
        var urls: [String] = []
        for raw in candidates {
            let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, !seen.contains(address) else { continue }
            seen.insert(address)
            urls.append(address)
            if fetchedCount + urls.count >= limit { break }
        }
        return urls
    }

    static func remaining(_ deadline: Date, now: Date = Date()) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }
}

// MARK: - 章节缓存

private enum ChapterCache {
    /// 正文清洗规则变了就换命名空间：老版本缓存下来的脏正文否则会一直被读出来。
    static let namespace = "v2"

    static var allRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChapterCache", isDirectory: true)
    }

    static var root: URL {
        allRoot.appendingPathComponent(namespace, isDirectory: true)
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
        // 视频标签在纯文本里没法显示，换成 [video:url] 标记，由订阅正文那层换成播放器
        var text = replaceVideos(in: raw, baseUrl: baseUrl)
        text = replaceImages(in: text, baseUrl: baseUrl)
        text = replaceImportAnchors(in: text)
        // 成对标签里的脚本/样式不能只删标签：`@html` 类正文规则会把整段 JS 留在正文里。
        text = text.replacingOccurrences(
            of: "(?is)<script\\b[^>]*>.*?</script\\s*>", with: "", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?is)<style\\b[^>]*>.*?</style\\s*>", with: "", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?is)<noscript\\b[^>]*>.*?</noscript\\s*>", with: "", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?s)<!--.*?-->", with: "", options: .regularExpression
        )
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

    /// 导入类深链只写在 `href` 里（`legado://import/httpTTS?src=…`），剥标签后会整个丢失，
    /// 正文里只剩不可点的「一键导入」。转成 `[文字](地址)`，由正文视图还原成可点按钮。
    private func replaceImportAnchors(in raw: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(?is)<a\\b[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a\\s*>"
        ) else {
            return raw
        }
        let source = raw as NSString
        var text = raw
        for match in regex.matches(in: raw, range: NSRange(location: 0, length: source.length)).reversed() {
            let href = source.substring(with: match.range(at: 1))
            let lower = href.lowercased()
            guard lower.hasPrefix("legado://") || lower.hasPrefix("yuedu://") || lower.hasPrefix("juyue://") else {
                continue
            }
            let label = source.substring(with: match.range(at: 2))
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            text = (text as NSString).replacingCharacters(in: match.range, with: "[\(label)](\(href))")
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

    private func replaceVideos(in raw: String, baseUrl: String?) -> String {
        var text = raw
        if let videoRegex = try? NSRegularExpression(pattern: "(?is)<video\\b[^>]*>.*?</video\\s*>") {
            let nsText = text as NSString
            for match in videoRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed() {
                let tag = nsText.substring(with: match.range)
                let src = extractVideoSrc(from: tag, baseUrl: baseUrl)
                let replacement = src.map { "\n\n[video:\($0)]\n\n" } ?? "\n\n"
                text = (text as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }
        // <video> 里没写 src、只写了 <source>，或者散落在外面的 <source>：按扩展名认视频
        if let sourceRegex = try? NSRegularExpression(pattern: "(?i)<source\\b[^>]*>") {
            let nsText = text as NSString
            for match in sourceRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed() {
                let tag = nsText.substring(with: match.range)
                guard let src = extractVideoSrc(from: tag, baseUrl: baseUrl),
                      tag.lowercased().contains("video/") || looksLikeVideo(src) else { continue }
                text = (text as NSString).replacingCharacters(in: match.range, with: "\n\n[video:\(src)]\n\n")
            }
        }
        return text
    }

    private func extractVideoSrc(from tag: String, baseUrl: String?) -> String? {
        for attribute in ["src", "data-src"] {
            guard let found = capture(in: tag, attribute: attribute) else { continue }
            let cleaned = found.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !cleaned.hasPrefix("data:") else { continue }
            return resolveMediaURL(cleaned, baseUrl: baseUrl)
        }
        return nil
    }

    private func looksLikeVideo(_ url: String) -> Bool {
        let lower = url.lowercased()
        return [".m3u8", ".mp4", ".m4v", ".mov", ".webm", ".flv", ".mpd"]
            .contains { lower.contains($0) }
    }

    /// 图片和视频共用：绝对地址原样返回，`//` 补协议，相对地址按页面地址补全。
    private func resolveMediaURL(_ raw: String, baseUrl: String?) -> String {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        if raw.hasPrefix("//") { return "https:" + raw }
        guard let base = baseUrl, let baseObj = URL(string: base) else { return raw }
        if raw.hasPrefix("/") {
            return "\(baseObj.scheme ?? "https")://\(baseObj.host ?? "")" + raw
        }
        return baseObj.deletingLastPathComponent().appendingPathComponent(raw).absoluteString
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
        guard !rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@js:") else { return text }
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
    /// 证书链不完整的站点（ExHentai 等）显式要求放宽 TLS 校验。
    public var allowInsecureTLS: Bool?
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
    /// 安卓 `RssArticle.type`：0 普通、2 视频。原样带出来给阅读页判断。
    public var type: Int?

    public init(
        title: String,
        link: String,
        date: String? = nil,
        summary: String? = nil,
        imageUrl: String? = nil,
        type: Int? = nil
    ) {
        self.title = title
        self.link = link
        self.date = date
        self.summary = summary
        self.imageUrl = imageUrl
        self.type = type
    }
}

/// 订阅正文抓取结果：正文 + 基准地址 + 取图片/视频要带的请求头。
public struct SubscribeFetchedContent {
    public var text: String
    public var baseURL: String
    public var headers: [String: String]
    /// 规则产物是可直接渲染的网页（播放器、交互页）时留一份原始 HTML，
    /// 阅读页拿它进 WKWebView；纯文本源为 nil，继续走原生排版。
    public var html: String?

    public init(text: String, baseURL: String, headers: [String: String], html: String? = nil) {
        self.text = text
        self.baseURL = baseURL
        self.headers = headers
        self.html = html
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
            throw SubscribeFetchFailure(message: "订阅源地址无法解析：\(target)")
        } catch SubscribeError.badStatus {
            throw SubscribeFetchFailure(message: "请求被站点拒绝（非 2xx/3xx）：\(target)")
        }
        LegadoLog.log("[订阅源] \(source.sourceName) 抓取 host=\(URL(string: target)?.host ?? "-") 字节=\(fetched.body.count)")
        if fetched.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !target.lowercased().hasPrefix("data:") {
            // 安卓 RssParserByRule 遇到空 body 同样直接报错，只是它显示的是通用文案。
            throw SubscribeFetchFailure(
                message: "\(source.sourceName) 的上游返回空内容（0 字节），接口可能已失效或被区域限制：\(target)"
            )
        }

        var listRule = source.ruleArticles?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 安卓 RssParserByRule：规则以 `-` 开头表示整表倒序。
        var reverseList = false
        if listRule.hasPrefix("-") {
            reverseList = true
            listRule = String(listRule.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !listRule.isEmpty else {
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
        var pageBody = fetched.body
        var pageBase = fetched.baseURL
        var engine = JSEngine(bookSource: context, baseUrl: pageBase)
        engine.setSourceValue("sortUrl", source.sortUrl ?? "")
        var analyzer = RuleAnalyzer(
            content: pageBody,
            baseUrl: pageBase,
            bookSource: context,
            jsEngine: engine
        )
        var elements = analyzer.getElements(listRule)

        // 静态抓取命中 0 时交给无声网页再试一次（原版 webView:true 的源全靠这一步）。
        if elements.isEmpty,
           let rendered = try? await headlessDocument(target: target, source: source, header: header) {
            LegadoLog.log("[订阅源] \(source.sourceName) 规则命中 0，改用无声网页重抓")
            pageBody = rendered.body
            pageBase = rendered.baseURL
            engine = JSEngine(bookSource: context, baseUrl: pageBase)
            engine.setSourceValue("sortUrl", source.sortUrl ?? "")
            analyzer = RuleAnalyzer(
                content: pageBody,
                baseUrl: pageBase,
                bookSource: context,
                jsEngine: engine
            )
            elements = analyzer.getElements(listRule)
        }
        LegadoLog.log("[订阅源] \(source.sourceName) 规则 \(listRule) 命中=\(elements.count)")

        let articles = elements.compactMap { element -> SubscribeArticle? in
            let row = RuleAnalyzer(
                content: element,
                baseUrl: pageBase,
                bookSource: context,
                jsEngine: engine
            )
            let title = row.getString(source.ruleTitle)
            let link = stripLineOptions(
                row.resolveLazyJavaScript(row.getString(source.ruleLink), isUrl: true)
            )
            guard !title.isEmpty || !link.isEmpty else { return nil }

            let date = row.getString(source.rulePubDate)
            var summary = row.getString(source.ruleDescription)
            if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let html = element as? String {
                // 没配描述规则时安卓留空、阅读时再抓正文；列表里先拿条目自身的文字顶上，
                // 比空白行更有信息量，也不额外发请求。
                summary = String(BookContentService.cleanHtml(html).prefix(120))
            }
            let image = row.resolveLazyJavaScript(row.getString(source.ruleImage), isUrl: true)
            return SubscribeArticle(
                title: title.isEmpty ? link : title,
                link: link,
                date: date.isEmpty ? nil : date,
                summary: summary.isEmpty ? nil : BookContentService.cleanHtml(summary),
                imageUrl: image.isEmpty ? nil : image,
                type: source.type
            )
        }

        var nextPage: String?
        if let nextRule = source.ruleNextPage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nextRule.isEmpty {
            if nextRule.uppercased() == "PAGE" {
                // 安卓：`PAGE` 不是规则，直接用当前页地址再翻一次。
                nextPage = target
            } else {
                let rawValue = analyzer.getString(nextRule)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawValue.isEmpty {
                    if rawValue.allSatisfy({ $0.isASCII && $0.isNumber }) {
                        // 规则只回页码（源仓的 `page` 字段）时把当前地址的页码 +1，
                        // 直接当网址会把 "1" 拼成 `…/1` 这种假地址。
                        nextPage = bumpPage(in: target, from: Int(rawValue) ?? 1)
                    } else {
                        nextPage = analyzer.getString(nextRule, isUrl: true)
                    }
                }
            }
        }
        return (reverseList ? Array(articles.reversed()) : articles, nextPage)
    }

    public static func fetchSortUrls(source: SubscribeSource) async -> [(name: String, url: String)] {
        await sortEntries(source: source).map { (name: $0.name, url: $0.url) }
    }

    /// 分类行语法：`名称::地址`，地址尾部可带 `,{"webView": true}` 这类选项。
    static func sortEntries(source: SubscribeSource) async -> [(name: String, url: String, webView: Bool)] {
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

        let jsLib = await resolvedJsLib(source.jsLib)
        let context = source.ruleContext(jsLib: jsLib)
        let engine = JSEngine(bookSource: context, baseUrl: source.sourceUrl)
        let analyzer = RuleAnalyzer(
            content: "",
            baseUrl: source.sourceUrl,
            bookSource: context,
            jsEngine: engine
        )

        var rows: [(String, String, Bool)] = []
        for line in text.components(separatedBy: .newlines) {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            var webView = false
            if let optionRange = trimmed.range(of: #",\s*\{.*\}\s*$"#, options: .regularExpression),
               let data = trimmed[optionRange].dropFirst().data(using: .utf8),
               let options = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                webView = (options["webView"] as? Bool) ?? false
                trimmed.removeSubrange(optionRange)
            }

            let fields = trimmed.components(separatedBy: "::")
            let name = fields.count > 1 ? fields[0] : trimmed
            var address = fields.count > 1 ? fields[1] : trimmed
            address = expandFunctionTemplates(address, analyzer: analyzer)

            if address.hasPrefix("/"), let base = URL(string: source.sourceUrl),
               let resolved = URL(string: address, relativeTo: base) {
                address = resolved.absoluteString
            }
            guard !address.isEmpty else { continue }
            rows.append((name, address, webView))
        }
        return rows
    }

    /// 分类行/链接尾部残留的 `,{"webView": true}` 选项不是地址的一部分。
    private static func stripLineOptions(_ value: String) -> String {
        guard let range = value.range(of: #",\s*\{.*\}\s*$"#, options: .regularExpression) else {
            return value
        }
        return String(value[..<range.lowerBound])
    }

    /// 只展开 `{{bhost()}}` 这类函数模板，`{{page}}` 留给翻页逻辑。
    private static func expandFunctionTemplates(_ template: String, analyzer: RuleAnalyzer) -> String {
        guard let pattern = try? NSRegularExpression(
            pattern: #"\{\{([^{}]*\([^{}]*\)[^{}]*)\}\}"#
        ) else {
            return template
        }
        let source = template as NSString
        let matches = pattern.matches(in: template, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return template }

        var output = template
        for match in matches.reversed() {
            let expression = source.substring(with: match.range(at: 1))
            let value = analyzer.evaluateTemplate("{{\(expression)}}")
            output = (output as NSString).replacingCharacters(in: match.range, with: value)
        }
        return output
    }

    /// 抓正文：有 ruleContent 就按规则取，取不到就把整页按纯文本给出去
    public static func fetchContent(article: SubscribeArticle, source: SubscribeSource) async throws -> String {
        try await fetchContentDetail(article: article, source: source).text
    }

    /// 抓正文，连同基准地址和请求头一起带出去。
    /// 正文里的图片、视频要按同一套 header 去取，站点的反盗链才过得去。
    public static func fetchContentDetail(
        article: SubscribeArticle,
        source: SubscribeSource
    ) async throws -> SubscribeFetchedContent {
        let jsLib = await resolvedJsLib(source.jsLib)
        let header = await resolvedHeader(source: source, jsLib: jsLib)
        let mediaHeaders = mediaRequestHeaders(source: source, header: header, referer: article.link)
        var link = stripLineOptions(
            article.link.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !link.isEmpty else { return SubscribeFetchedContent(text: "", baseURL: article.link, headers: mediaHeaders) }

        // 行值里残留的 `@js:` / `<js>` 链接（洛娅橙用它拼 data: 地址）先求值一次。
        if let script = ScriptSnippet.body(in: link) {
            let context = source.ruleContext(jsLib: jsLib)
            let engine = JSEngine(bookSource: context, baseUrl: source.sourceUrl)
            if let value = engine.eval(script: script, result: link) as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                link = value
            }
        }

        let body: String
        let base: String
        if let packed = NetworkClient.dataURLPayload(link) {
            body = packed
            base = link
        } else if link.lowercased().hasPrefix("data:") {
            // 与列表抓取一致：解不出载荷的 data: 地址是拿 baseUrl 传参的写法，不发请求。
            body = ""
            base = link
        } else {
            guard let request = NetworkClient.parseJuyueUrl(
                link,
                defaultHeader: header,
                baseUrl: source.sourceUrl,
                insecureTLS: source.allowInsecureTLS ?? false
            ) else {
                return SubscribeFetchedContent(text: "", baseURL: link, headers: mediaHeaders)
            }
            let reply = try await NetworkClient.shared.request(parsed: request)
            guard (200..<400).contains(reply.statusCode) else {
                return SubscribeFetchedContent(text: "", baseURL: request.url.absoluteString, headers: mediaHeaders)
            }
            body = reply.bodyString
            base = request.url.absoluteString
        }

        var bestText = ""
        var ruleOutput = ""
        if let rule = source.ruleContent, !rule.isEmpty {
            let analyzer = subscribeAnalyzer(
                article: article,
                source: source,
                jsLib: jsLib,
                content: body,
                base: base
            )
            ruleOutput = analyzer.getString(rule)
            bestText = BookContentService.cleanHtml(ruleOutput, baseUrl: base)
        }
        var bestBase = base
        if bestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ruleOutput = body
            bestText = BookContentService.cleanHtml(body, baseUrl: base)
        }

        // 正文由页面脚本渲染时（源仓、洛娅橙这类），静态抓取只剩标题，
        // 交给无声网页渲染后再跑一次规则，取更长的那份。
        if bestText.trimmingCharacters(in: .whitespacesAndNewlines).count < 80,
           let rendered = try? await headlessDocument(target: link, source: source, header: header) {
            let renderAnalyzer = subscribeAnalyzer(
                article: article,
                source: source,
                jsLib: jsLib,
                content: rendered.body,
                base: rendered.baseURL
            )
            var renderedText = ""
            var renderedRaw = ""
            if let rule = source.ruleContent, !rule.isEmpty {
                renderedRaw = renderAnalyzer.getString(rule)
                renderedText = BookContentService.cleanHtml(
                    renderedRaw,
                    baseUrl: rendered.baseURL
                )
            }
            if renderedText.trimmingCharacters(in: .whitespacesAndNewlines).count < bestText.count {
                renderedRaw = rendered.body
                renderedText = BookContentService.cleanHtml(rendered.body, baseUrl: rendered.baseURL)
            }
            if renderedText.count > bestText.count {
                LegadoLog.log("[订阅源] \(source.sourceName) 正文改用无声网页渲染 长度=\(renderedText.count)")
                bestText = renderedText
                ruleOutput = renderedRaw
                bestBase = rendered.baseURL
            }
        }
        let html = looksLikeInteractiveHTML(ruleOutput) ? ruleOutput : nil
        return SubscribeFetchedContent(
            text: bestText,
            baseURL: bestBase,
            headers: mediaHeaders,
            html: html
        )
    }

    /// 交互式网页（视频播放器、需要页面脚本出内容）才交给 WKWebView；
    /// 普通正文片段继续走原生排版，免得把纯文本源也变成网页。
    static func looksLikeInteractiveHTML(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.contains("<") else { return false }
        if lower.contains("<!doctype") || lower.contains("<html") { return true }
        return lower.contains("<video") || lower.contains("<iframe") || lower.contains("<canvas")
    }

    private static func subscribeAnalyzer(
        article: SubscribeArticle,
        source: SubscribeSource,
        jsLib: String?,
        content: String,
        base: String
    ) -> RuleAnalyzer {
        let context = source.ruleContext(jsLib: jsLib)
        let engine = JSEngine(bookSource: context, baseUrl: base)
        engine.setRssArticle([
            "title": article.title,
            "link": article.link,
            "date": article.date ?? "",
            // 安卓 RssArticle 的原名是 pubDate；date 留着兼容既有脚本。
            "pubDate": article.date ?? "",
            "description": article.summary ?? "",
            "image": article.imageUrl ?? "",
            "sort": source.sourceName,
            "origin": source.sourceName,
            "group": source.sourceGroup ?? "",
            "type": "\(source.type ?? 0)",
            "order": "0",
            "read": "false",
            "variable": ""
        ])
        return RuleAnalyzer(
            content: content,
            baseUrl: base,
            bookSource: context,
            jsEngine: engine
        )
    }

    /// 用无声网页渲染页面；没有实现时返回 nil，调用方保持原结果。
    private static func headlessDocument(
        target: String,
        source: SubscribeSource,
        header: String?
    ) async throws -> FetchedDocument? {
        guard HeadlessWebView.shared.loader != nil,
              !target.lowercased().hasPrefix("data:"),
              let request = NetworkClient.parseJuyueUrl(
                  target,
                  defaultHeader: header,
                  baseUrl: source.sourceUrl,
                  insecureTLS: source.allowInsecureTLS ?? false
              ) else {
            return nil
        }
        let result = try await NetworkClient.shared.headlessFetch(parsed: request)
        return FetchedDocument(body: result.html, baseURL: result.finalURL.absoluteString)
    }

    /// 图片/视频请求复用的头：来源 header + Referer + 默认 UA。
    /// 反盗链站点主要看 Referer，缺了它图全是 403。
    public static func mediaRequestHeaders(
        source: SubscribeSource,
        header: String?,
        referer: String?
    ) -> [String: String] {
        var result = headerFields(from: header)
        if result.isEmpty { result = source.staticRequestHeaders }
        let hasReferer = result.keys.contains { $0.lowercased() == "referer" }
        if !hasReferer, let referer, !referer.isEmpty {
            result["Referer"] = referer
        }
        if result.keys.allSatisfy({ $0.lowercased() != "user-agent" }) {
            result["User-Agent"] = NetworkClient.defaultUserAgent
        }
        return result
    }

    /// header 既可能是 JSON 对象，也可能是每行 `Name: value`。
    static func headerFields(from raw: String?) -> [String: String] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return [:]
        }
        if raw.hasPrefix("{"),
           let data = raw.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict.reduce(into: [:]) { result, item in
                result[item.key] = String(describing: item.value)
            }
        }
        var result: [String: String] = [:]
        for line in raw.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, !parts[0].isEmpty {
                result[parts[0]] = parts[1]
            }
        }
        return result
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

    /// 规则只回了页码时，把当前地址里的页码改成下一页。
    static func bumpPage(in target: String, from page: Int) -> String? {
        let next = String(page + 1)
        if target.contains("{{page}}") {
            return target.replacingOccurrences(of: "{{page}}", with: next)
        }
        if let range = target.range(of: "%7B%7Bpage%7D%7D", options: .caseInsensitive) {
            return target.replacingCharacters(in: range, with: next)
        }
        let patterns = [
            "(?i)([?&](?:page|p|pageNum|pageNo)=)(\\d+)",
            "(?i)(/page/)(\\d+)"
        ]
        let source = target as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                      in: target,
                      range: NSRange(location: 0, length: source.length)
                  ),
                  match.numberOfRanges > 2 else { continue }
            return source.replacingCharacters(in: match.range(at: 2), with: next)
        }
        return nil
    }

    private static func fetchDocument(
        target: String,
        source: SubscribeSource,
        header: String?
    ) async throws -> FetchedDocument {
        if let packed = NetworkClient.dataURLPayload(target) {
            return FetchedDocument(body: packed, baseURL: target)
        }
        if target.lowercased().hasPrefix("data:") {
            // 解不出载荷的 `data:;base64,<占位>,<扩展>` 是源作者拿 baseUrl 传参的写法，
            // 不能真发请求；正文留空，规则脚本按 baseUrl 分支走。
            return FetchedDocument(body: "", baseURL: target)
        }

        guard let request = NetworkClient.parseJuyueUrl(
            target,
            defaultHeader: header,
            baseUrl: source.sourceUrl,
            insecureTLS: source.allowInsecureTLS ?? false
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

/// 抓取失败时带一句能直接展示给用户的话，界面不再笼统报「没抓到条目」。
public struct SubscribeFetchFailure: LocalizedError {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
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
        LegadoLog.log("[RSS] 新增订阅 \(sources.count) 个")
    }

    public func remove(_ source: RSSSource) {
        sources.removeAll { $0.id == source.id }
        save()
        LegadoLog.log("[RSS] 删除订阅 \(sources.count) 个")
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
            body: request.body,
            usesWebView: request.usesWebView
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
