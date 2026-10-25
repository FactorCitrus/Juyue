import Foundation

public class BookSearchService {
    public static let shared = BookSearchService()

    /// 搜完一次请求把实测耗时送回宿主，写回书源 `respondTime`。Core 不认识仓库，
    /// 和 `JSEngine.variableSink` 一样由 App 层注入。
    public static var respondTimeSink: ((_ sourceUrl: String, _ milliseconds: Int64) -> Void)?

    public init() {}

    /// Searches books across a single BookSource
    public func search(
        source: BookSource,
        key: String,
        page: Int = 1,
        diagnostics: ((SourceRequestDiagnostic) -> Void)? = nil
    ) async throws -> [SearchBook] {
        guard let rawSearchUrl = source.searchUrl, !rawSearchUrl.isEmpty else {
            return []
        }
        try await SourceLoginService.shared.requireLoginIfNeeded(source: source)

        // Setup JS engine and render URL template
        let jsEngine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
        var renderedUrl = rawSearchUrl

        // Inject standard Legado search variables
        jsEngine.context.setObject(key, forKeyedSubscript: "key" as NSString)
        jsEngine.context.setObject(key, forKeyedSubscript: "searchKey" as NSString)
        jsEngine.context.setObject(page, forKeyedSubscript: "page" as NSString)
        jsEngine.context.setObject(page, forKeyedSubscript: "searchPage" as NSString)
        jsEngine.context.setObject(source.bookSourceUrl, forKeyedSubscript: "baseUrl" as NSString)

        if renderedUrl.contains("<js>") || renderedUrl.hasPrefix("@js:") {
            let script: String
            if renderedUrl.contains("<js>") {
                let start = renderedUrl.range(of: "<js>")?.upperBound ?? renderedUrl.startIndex
                let end = renderedUrl.range(of: "</js>")?.lowerBound ?? renderedUrl.endIndex
                script = String(renderedUrl[start..<end])
            } else {
                script = String(renderedUrl.dropFirst(4))
            }

            if let result = jsEngine.context.evaluateScript(script)?.toString(),
               !result.isEmpty && result != "undefined" && result != "null" {
                renderedUrl = result
            }
        } else {
            renderedUrl = renderedUrl
                .replacingOccurrences(of: "searchKey", with: key)
                .replacingOccurrences(of: "{{key}}", with: key)
                .replacingOccurrences(of: "{{page}}", with: "\(page)")
                .replacingOccurrences(of: "{{searchPage}}", with: "\(page)")

            renderedUrl = jsEngine.renderTemplate(renderedUrl, variables: [
                "key": key,
                "searchKey": key,
                "page": page,
                "searchPage": page
            ])
        }

        // Parse and send request with loginHeader priority and baseUrl fallback
        var headerToUse = source.loginHeader ?? source.header
        if let h = headerToUse, (h.contains("<js>") || h.hasPrefix("@js:")) {
            let script: String
            if h.contains("<js>") {
                let start = h.range(of: "<js>")?.upperBound ?? h.startIndex
                let end = h.range(of: "</js>")?.lowerBound ?? h.endIndex
                script = String(h[start..<end])
            } else {
                script = String(h.dropFirst(4))
            }
            if let evalResult = jsEngine.context.evaluateScript(script)?.toString(),
               !evalResult.isEmpty && evalResult != "undefined" && evalResult != "null" {
                headerToUse = evalResult
            }
        }

        // 脱敏：渲染后的 URL 里带着搜索关键词，只记域名
        LegadoLog.log("[Search] [\(source.bookSourceName)] 请求已构造 host=\(URL(string: renderedUrl)?.host ?? "-")")

        guard let parsedReq = NetworkClient.parseLegadoUrl(renderedUrl, defaultHeader: headerToUse, baseUrl: source.bookSourceUrl) else {
            LegadoLog.log("[Search] ❌ [\(source.bookSourceName)] 请求 URL 解析失败 host=\(URL(string: renderedUrl)?.host ?? "-")")
            return []
        }

        let requestStarted = Date()
        let response: NetworkResponse
        do {
            response = try await NetworkClient.shared.request(
                parsed: parsedReq,
                timeout: nil,
                rateKey: source.bookSourceUrl,
                rateLimit: source.rateLimit
            )
        } catch {
            DiagnosticHub.emit(SourceRequestDiagnostic(
                step: "搜索",
                sourceName: source.bookSourceName,
                url: parsedReq.url.absoluteString,
                elapsedMs: Int64(Date().timeIntervalSince(requestStarted) * 1000),
                headersSummary: DiagnosticFailure.summarize(parsedReq.headers),
                failureKind: DiagnosticFailure.classify(error),
                note: "请求失败：\(error.localizedDescription)"
            ), to: diagnostics)
            throw error
        }
        let elapsedMs = Int64(Date().timeIntervalSince(requestStarted) * 1000)
        if response.statusCode >= 200 && response.statusCode < 400 {
            BookSearchService.respondTimeSink?(source.bookSourceUrl, elapsedMs)
        }
        LegadoLog.log("[Search] [\(source.bookSourceName)] HTTP \(response.statusCode)，收到 \(response.data.count) 字节")

        guard response.statusCode >= 200 && response.statusCode < 400 else {
            LegadoLog.log("[Search] ⚠️ [\(source.bookSourceName)] HTTP \(response.statusCode) 非成功状态，跳过")
            return []
        }

        guard let searchRule = source.ruleSearch else {
            LegadoLog.log("[Search] ⚠️ [\(source.bookSourceName)] 没有配置搜索规则")
            return []
        }

        // Analyze result
        let analyzer = RuleAnalyzer(
            content: response.bodyString,
            baseUrl: parsedReq.url.absoluteString,
            bookSource: source,
            jsEngine: jsEngine
        )

        let ruleStarted = Date()
        let bookElements = analyzer.getElements(searchRule.bookList)
        let ruleEvalMs = Int64(Date().timeIntervalSince(ruleStarted) * 1000)
        DiagnosticHub.emit(SourceRequestDiagnostic(
            step: "搜索",
            sourceName: source.bookSourceName,
            url: parsedReq.url.absoluteString,
            statusCode: response.statusCode,
            elapsedMs: elapsedMs,
            responseBytes: response.data.count,
            responsePreview: DiagnosticPreview.make(response.bodyString),
            ruleHits: bookElements.count,
            ruleEvalMs: ruleEvalMs,
            headersSummary: DiagnosticFailure.summarize(parsedReq.headers),
            note: "解析出 \(bookElements.count) 个候选"
        ), to: diagnostics)
        LegadoLog.log("[Search] [\(source.bookSourceName)] 候选条目 \(bookElements.count) 个")
        var searchBooks: [SearchBook] = []

        for item in bookElements {
            let itemAnalyzer = RuleAnalyzer(
                content: item,
                baseUrl: parsedReq.url.absoluteString,
                bookSource: source,
                jsEngine: jsEngine
            )

            let name = itemAnalyzer.getString(searchRule.name)
            let author = itemAnalyzer.getString(searchRule.author)
            let bookUrl = itemAnalyzer.getString(searchRule.bookUrl, isUrl: true)

            guard !name.isEmpty, !bookUrl.isEmpty else { continue }

            let rawCover = itemAnalyzer.getString(searchRule.coverUrl, isUrl: true)
            let coverUrl = rawCover.isEmpty
                ? ""
                : CoverURLResolver.resolve(rawCover, source: source, baseUrl: parsedReq.url.absoluteString)
            let intro = itemAnalyzer.getString(searchRule.intro)
            let kind = itemAnalyzer.getString(searchRule.kind)
            let lastChapter = itemAnalyzer.getString(searchRule.lastChapter)
            let wordCount = itemAnalyzer.getString(searchRule.wordCount)

            let book = SearchBook(
                name: name,
                author: author,
                kind: kind.isEmpty ? nil : kind,
                bookUrl: bookUrl,
                coverUrl: coverUrl.isEmpty ? nil : coverUrl,
                intro: intro.isEmpty ? nil : intro,
                latestChapterTitle: lastChapter.isEmpty ? nil : lastChapter,
                origin: source.bookSourceUrl,
                originName: source.bookSourceName,
                wordCount: wordCount.isEmpty ? nil : wordCount
            )
            searchBooks.append(book)
        }

        LegadoLog.log("[Search] ✅ [\(source.bookSourceName)] 解析出 \(searchBooks.count) 本书")
        return searchBooks
    }

    /// Searches across multiple sources concurrently for a specific page, returning an AsyncStream of (source, books)
    public func searchMultiSources(
        sources: [BookSource],
        key: String,
        page: Int = 1
    ) -> AsyncStream<(source: BookSource, books: [SearchBook])> {
        let enabledSources = sources
            .filter { $0.enabled != false && $0.searchUrl != nil }
            .sorted(by: BookSource.selectionOrder)
        // 脱敏：不记关键词原文，也不列全部书源名
        LegadoLog.log("[Search] 开始多源搜索 page=\(page) 源数=\(enabledSources.count) 关键词长度=\(key.count)")

        return AsyncStream { continuation in
            Task {
                await withTaskGroup(of: (BookSource, [SearchBook]).self) { group in
                    for source in enabledSources {
                        group.addTask {
                            do {
                                let books = try await self.search(source: source, key: key, page: page)
                                return (source, books)
                            } catch {
                                LegadoLog.log("[Search] ❌ [\(source.bookSourceName)] 请求出错 page=\(page): \(error.localizedDescription)")
                                return (source, [])
                            }
                        }
                    }

                    for await result in group {
                        continuation.yield(result)
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Searches across multiple sources concurrently (defaults to page 1), returning an AsyncStream of book batches
    public func searchMultiSources(sources: [BookSource], key: String) -> AsyncStream<[SearchBook]> {
        return AsyncStream { continuation in
            Task {
                for await (_, books) in self.searchMultiSources(sources: sources, key: key, page: 1) {
                    if !books.isEmpty {
                        continuation.yield(books)
                    }
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - 换源时候选书的匹配口径

/// 换源界面用哪几个字段判定「这是同一本书」。
public struct SourceMatchOptions: Equatable {
    /// 要求书名中
    public var matchTitle: Bool
    /// 要求作者中
    public var matchAuthor: Bool
    /// 精确匹配：归一化后完全相等；否则双向包含
    public var exact: Bool

    public init(matchTitle: Bool = true, matchAuthor: Bool = false, exact: Bool = false) {
        self.matchTitle = matchTitle
        self.matchAuthor = matchAuthor
        self.exact = exact
    }
}

/// 候选书与目标书的匹配判定。
///
/// 开了几个字段就是几个字段都要中（AND）：开了书名和作者，就要求候选书名中、作者也中，
/// 只用 OR 的话同名不同作者的书会混进换源列表。
public enum SourceMatchRules {

    /// 搜索页只看一个关键词：命中选中字段里的任意一个就算。
    public enum SearchField: String, CaseIterable {
        case title
        case author
        case either
    }

    /// 搜索结果过滤：关键词落在选中的字段里就算命中。
    /// 换源那边两个字段是两个不同的目标、按 AND；搜索页只有一个关键词，所以是 OR。
    public static func matchesKeyword(
        _ candidate: SearchBook,
        keyword: String,
        field: SearchField,
        exact: Bool
    ) -> Bool {
        guard !normalized(keyword).isEmpty else { return true }
        switch field {
        case .title:
            return hit(candidate.name, keyword, exact: exact)
        case .author:
            return hit(candidate.author, keyword, exact: exact)
        case .either:
            return hit(candidate.name, keyword, exact: exact) || hit(candidate.author, keyword, exact: exact)
        }
    }

    /// 搜索范围：按「源名 / 分组含这几个字」和分组过滤要搜的源。
    public static func filterSources(
        _ sources: [BookSource],
        nameFilter: String,
        group: String?
    ) -> [BookSource] {
        var list = sources
        if let group, !group.isEmpty {
            list = list.filter { ($0.bookSourceGroup ?? "") == group }
        }
        let needle = nameFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return list }
        return list.filter {
            $0.bookSourceName.lowercased().contains(needle)
                || ($0.bookSourceGroup ?? "").lowercased().contains(needle)
        }
    }

    /// 归一化：去掉空白（含全角）、书名号 / 引号 / 间隔号，英文转小写。
    /// 「《凡人修仙传》」「凡人 修仙传」「凡人·修仙传」都算同一个书名。
    public static func normalized(_ text: String) -> String {
        let dropped: Set<Character> = [" ", "\t", "\n", "\u{3000}", "《", "》", "「", "」", "『", "』",
                                       "“", "”", "‘", "’", "\"", "'", "·", "•"]
        return String(text.filter { !dropped.contains($0) }).lowercased()
    }

    public static func matches(
        _ candidate: SearchBook,
        title: String,
        author: String,
        options: SourceMatchOptions
    ) -> Bool {
        var checked = 0
        if options.matchTitle {
            checked += 1
            guard hit(candidate.name, title, exact: options.exact) else { return false }
        }
        if options.matchAuthor {
            checked += 1
            guard hit(candidate.author, author, exact: options.exact) else { return false }
        }
        // 一个字段都没开就没法判定「是同一本书」
        return checked > 0
    }

    private static func hit(_ candidateValue: String, _ wanted: String, exact: Bool) -> Bool {
        let value = normalized(candidateValue)
        let target = normalized(wanted)
        guard !value.isEmpty, !target.isEmpty else { return false }
        return exact ? value == target : (value.contains(target) || target.contains(value))
    }
}
