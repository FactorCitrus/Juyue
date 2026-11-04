import Foundation

public class BookSearchService {
    public static let shared = BookSearchService()

    /// 搜完一次请求把实测耗时送回宿主，写回书源 `respondTime`。Core 不认识仓库，
    /// 和 `JSEngine.variableSink` 一样由 App 层注入。
    public static var respondTimeSink: ((_ sourceUrl: String, _ milliseconds: Int64) -> Void)?

    public init() {}

    /// 搜索地址先执行 `<js>`（如果有），再统一做一次 `{{key}}` / `{{page}}` 渲染。
    /// JS 常常只拼出带占位符的地址；二次渲染时不再执行 `<js>`，避免脚本副作用跑两遍。
    static func renderSearchURL(_ template: String, key: String, page: Int, engine: JSEngine) -> String {
        var renderedUrl = template
        if template.contains("<js>") || template.hasPrefix("@js:") {
            let script: String
            if template.contains("<js>") {
                let start = template.range(of: "<js>")?.upperBound ?? template.startIndex
                let end = template.range(of: "</js>")?.lowerBound ?? template.endIndex
                script = String(template[start..<end])
            } else {
                script = String(template.dropFirst(4))
            }

            if let result = engine.context.evaluateScript(script)?.toString(),
               !result.isEmpty && result != "undefined" && result != "null" {
                renderedUrl = result
            }
        }
        return fillTemplate(renderedUrl, key: key, page: page, engine: engine)
    }

    private static func fillTemplate(_ template: String, key: String, page: Int, engine: JSEngine) -> String {
        var address = template
            .replacingOccurrences(of: "searchKey", with: key)
            .replacingOccurrences(of: "{{key}}", with: key)
            .replacingOccurrences(of: "{{page}}", with: "\(page)")
            .replacingOccurrences(of: "{{searchPage}}", with: "\(page)")

        address = engine.renderTemplate(address, variables: [
            "key": key,
            "searchKey": key,
            "page": page,
            "searchPage": page
        ])
        return address
    }

    /// Searches books across a single BookSource
    /// 公开行为保持原样：HTTP 非 2xx、请求地址解析失败这类「源自身的问题」
    /// 仍按空结果返回；多源换源要走 `searchMultiSourcesDetailed` 才拿得到原因。
    public func search(
        source: BookSource,
        key: String,
        page: Int = 1,
        diagnostics: ((SourceRequestDiagnostic) -> Void)? = nil
    ) async throws -> [SearchBook] {
        do {
            return try await searchDetailed(source: source, key: key, page: page, diagnostics: diagnostics)
        } catch let failure as SearchRequestFailure {
            return []
        }
    }

    /// 搜索单个源，失败时抛 `SearchRequestFailure`，让上层能区分「没这本书」和「源坏了」。
    func searchDetailed(
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

        renderedUrl = Self.renderSearchURL(renderedUrl, key: key, page: page, engine: jsEngine)

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

        guard let searchRule = source.ruleSearch else {
            LegadoLog.log("[Search] ⚠️ [\(source.bookSourceName)] 没有配置搜索规则")
            return []
        }

        var bodyString: String
        var baseURLString: String
        var responseBytes: Int
        var statusCode = 200
        var headersSummary = ""
        var elapsedMs: Int64 = 0

        // 聚合源的搜索地址可能是 data: 包：直接在本机跑规则，不发网络请求。
        if let payload = NetworkClient.dataURLPayload(renderedUrl) {
            bodyString = payload
            baseURLString = renderedUrl
            responseBytes = payload.utf8.count
            LegadoLog.log("[Search] [\(source.bookSourceName)] data: 搜索载荷 \(responseBytes) 字节")
        } else {
            // 自定义协议在书源里常见于聚合源（如 moyue://），依赖外部 App / 服务端，
            // 不能交给 URLSession，否则只剩一句「不支持的 URL」。
            if let scheme = NetworkClient.unsupportedScheme(in: renderedUrl) {
                let error = UnsupportedBookSourceSchemeError(
                    scheme: scheme,
                    sourceName: source.bookSourceName
                )
                LegadoLog.log("[Search] ❌ [\(source.bookSourceName)] 自定义协议 \(scheme) 不支持")
                DiagnosticHub.emit(SourceRequestDiagnostic(
                    step: "搜索",
                    sourceName: source.bookSourceName,
                    url: renderedUrl,
                    failureKind: DiagnosticFailure.classify(error),
                    note: error.localizedDescription
                ), to: diagnostics)
                throw SearchRequestFailure(failure: .unsupportedScheme(scheme))
            }

            // 脱敏：渲染后的 URL 里带着搜索关键词，只记域名
            LegadoLog.log("[Search] [\(source.bookSourceName)] 请求已构造 host=\(URL(string: renderedUrl)?.host ?? "-")")

            guard let parsedReq = NetworkClient.parseLegadoUrl(renderedUrl, defaultHeader: headerToUse, baseUrl: source.bookSourceUrl) else {
                LegadoLog.log("[Search] ❌ [\(source.bookSourceName)] 请求 URL 解析失败 host=\(URL(string: renderedUrl)?.host ?? "-")")
                throw SearchRequestFailure(failure: .urlParseFailed(host: URL(string: renderedUrl)?.host))
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
            elapsedMs = Int64(Date().timeIntervalSince(requestStarted) * 1000)
            if response.statusCode >= 200 && response.statusCode < 400 {
                BookSearchService.respondTimeSink?(source.bookSourceUrl, elapsedMs)
            }
            LegadoLog.log("[Search] [\(source.bookSourceName)] HTTP \(response.statusCode)，收到 \(response.data.count) 字节")

            guard response.statusCode >= 200 && response.statusCode < 400 else {
                LegadoLog.log("[Search] ⚠️ [\(source.bookSourceName)] HTTP \(response.statusCode) 非成功状态，跳过")
                throw SearchRequestFailure(failure: .httpStatus(response.statusCode))
            }

            bodyString = response.bodyString
            baseURLString = parsedReq.url.absoluteString
            responseBytes = response.data.count
            statusCode = response.statusCode
            headersSummary = DiagnosticFailure.summarize(parsedReq.headers)
        }

        // Analyze result
        let analyzer = RuleAnalyzer(
            content: bodyString,
            baseUrl: baseURLString,
            bookSource: source,
            jsEngine: jsEngine
        )

        let ruleStarted = Date()
        let bookElements = analyzer.getElements(searchRule.bookList)
        let ruleEvalMs = Int64(Date().timeIntervalSince(ruleStarted) * 1000)
        DiagnosticHub.emit(SourceRequestDiagnostic(
            step: "搜索",
            sourceName: source.bookSourceName,
            url: baseURLString,
            statusCode: statusCode,
            elapsedMs: elapsedMs,
            responseBytes: responseBytes,
            responsePreview: DiagnosticPreview.make(bodyString),
            ruleHits: bookElements.count,
            ruleEvalMs: ruleEvalMs,
            headersSummary: headersSummary,
            note: "解析出 \(bookElements.count) 个候选"
        ), to: diagnostics)
        LegadoLog.log("[Search] [\(source.bookSourceName)] 候选条目 \(bookElements.count) 个")
        var searchBooks: [SearchBook] = []

        for item in bookElements {
            let itemAnalyzer = RuleAnalyzer(
                content: item,
                baseUrl: baseURLString,
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
                : CoverURLResolver.resolve(rawCover, source: source, baseUrl: baseURLString)
            let intro = itemAnalyzer.getString(searchRule.intro)
            let kind = itemAnalyzer.getString(searchRule.kind)
            let lastChapter = itemAnalyzer.getString(searchRule.lastChapter)
            let wordCount = itemAnalyzer.getString(searchRule.wordCount)

            let book = SearchBook(
                name: name,
                author: author,
                bookUrl: bookUrl,
                origin: source.bookSourceUrl,
                originName: source.bookSourceName,
                kind: kind.isEmpty ? nil : kind,
                coverUrl: coverUrl.isEmpty ? nil : coverUrl,
                intro: intro.isEmpty ? nil : intro,
                latestChapterTitle: lastChapter.isEmpty ? nil : lastChapter,
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
        AsyncStream { continuation in
            let worker = Task {
                for await outcome in self.searchMultiSourcesDetailed(sources: sources, key: key, page: page) {
                    continuation.yield((source: outcome.source, books: outcome.books))
                }
                continuation.finish()
            }
            // worker 是非结构化任务：消费端取消（暂停 / 退出）不会自动带上它，
            // 要显式取消，任务组里的 URLSession 请求才会一起中止。
            continuation.onTermination = { _ in
                worker.cancel()
            }
        }
    }

    /// 同时在跑的源上限。几百个源不能一次性建 JSEngine、发请求。
    static let maxConcurrentSources = 10

    /// 换源用的详细路径：每个源除了书单，还带一个可读的失败原因。
    /// 0 结果算成功（failure 为 nil），只有请求 / 解析真的失败才带原因。
    public func searchMultiSourcesDetailed(
        sources: [BookSource],
        key: String,
        page: Int = 1
    ) -> AsyncStream<SearchSourceOutcome> {
        let enabledSources = sources
            .filter { $0.enabled != false && $0.searchUrl != nil }
            .sorted(by: BookSource.selectionOrder)
        // 脱敏：不记关键词原文，也不列全部书源名
        LegadoLog.log("[Search] 开始多源搜索 page=\(page) 源数=\(enabledSources.count) 关键词长度=\(key.count)")

        return AsyncStream { continuation in
            let worker = Task {
                await withTaskGroup(of: SearchSourceOutcome.self) { group in
                    var pending = enabledSources.makeIterator()
                    var inFlight = 0
                    // 滑动窗口：先塞满，每完成一个再补一个，结果仍然按完成顺序流出。
                    while inFlight < Self.maxConcurrentSources, let source = pending.next() {
                        group.addTask { await self.searchOutcome(source: source, key: key, page: page) }
                        inFlight += 1
                    }
                    while let outcome = await group.next() {
                        continuation.yield(outcome)
                        if let source = pending.next() {
                            group.addTask { await self.searchOutcome(source: source, key: key, page: page) }
                        }
                    }
                }
                continuation.finish()
            }
            // worker 是非结构化任务：消费端取消（暂停 / 退出）不会自动带上它，
            // 要显式取消，任务组里的 URLSession 请求才会一起中止。
            continuation.onTermination = { _ in
                worker.cancel()
            }
        }
    }

    private func searchOutcome(source: BookSource, key: String, page: Int) async -> SearchSourceOutcome {
        do {
            let books = try await searchDetailed(source: source, key: key, page: page)
            return SearchSourceOutcome(source: source, books: books)
        } catch {
            LegadoLog.log("[Search] ❌ [\(source.bookSourceName)] 请求出错 page=\(page): \(error.localizedDescription)")
            return SearchSourceOutcome(
                source: source,
                books: [],
                failure: SearchSourceFailure.from(error: error)
            )
        }
    }

    /// Searches across multiple sources concurrently (defaults to page 1), returning an AsyncStream of book batches
    public func searchMultiSources(sources: [BookSource], key: String) -> AsyncStream<[SearchBook]> {
        AsyncStream { continuation in
            let worker = Task {
                for await (_, books) in self.searchMultiSources(sources: sources, key: key, page: 1) {
                    guard !books.isEmpty else { continue }
                    continuation.yield(books)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                worker.cancel()
            }
        }
    }
}

// MARK: - 换源失败归因

/// 单个书源搜索失败的可读原因。界面只看 `message`，不会带出完整请求地址。
public enum SearchSourceFailure: Equatable {
    case network(String)
    case loginExpired
    case urlParseFailed(host: String?)
    case unsupportedScheme(String)
    case httpStatus(Int)
    case other(String)

    public var message: String {
        switch self {
        case .network(let text):
            return text
        case .loginExpired:
            return "登录已失效，去书源详情重新登录"
        case .urlParseFailed(let host):
            guard let host, !host.isEmpty else { return "请求地址无法解析" }
            return "请求地址无法解析（\(host)）"
        case .unsupportedScheme(let scheme):
            return BookSourceSchemeClassifier.reason(for: scheme)
        case .httpStatus(let code):
            return "服务器返回 HTTP \(code)"
        case .other(let text):
            return text
        }
    }

    public static func from(error: Error) -> SearchSourceFailure {
        if let failure = error as? SearchRequestFailure {
            return failure.failure
        }
        if let schemeError = error as? UnsupportedBookSourceSchemeError {
            return .unsupportedScheme(schemeError.scheme)
        }
        if error is SourceLoginRequiredError {
            return .loginExpired
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .network("请求超时")
            case .notConnectedToInternet, .dataNotAllowed:
                return .network("网络不可用")
            case .networkConnectionLost:
                return .network("网络连接中断")
            case .cannotFindHost, .dnsLookupFailed:
                return .network("域名解析失败")
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return .network("SSL / 证书校验失败")
            case .cancelled:
                return .network("请求已取消")
            default:
                return .network("网络错误（代码 \(urlError.code.rawValue)）")
            }
        }
        return .other(sanitized(error.localizedDescription))
    }

    /// 兜底文案可能带着请求地址，统一换成占位符并限长。
    private static func sanitized(_ raw: String) -> String {
        var text = raw
        if let regex = try? NSRegularExpression(pattern: "https?://[^\\s，。；)）]+") {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "该地址")
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.count > 80 {
            text = String(text.prefix(80)) + "…"
        }
        return text.isEmpty ? "搜索失败" : text
    }
}

/// 单个源这一轮的完整结果：书单 + 失败原因。
public struct SearchSourceOutcome {
    public let source: BookSource
    public let books: [SearchBook]
    public let failure: SearchSourceFailure?

    public init(source: BookSource, books: [SearchBook], failure: SearchSourceFailure? = nil) {
        self.source = source
        self.books = books
        self.failure = failure
    }

    public var didFail: Bool { failure != nil }
}

/// 只在 Core 内部流转：把「源自身的问题」从返回空数组改成抛错，
/// 外层 `search(_:)` 再转回空数组，保持既有调用方行为不变。
struct SearchRequestFailure: LocalizedError {
    let failure: SearchSourceFailure
    var errorDescription: String? { failure.message }
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
/// 换源暂停时记下的「真正影响请求」的条件。
/// 匹配书名 / 作者 / 精确只过滤已返回结果，不参与请求，改它们不需要重搜。
public struct SourceSwitchCriteria: Equatable {
    public var keyword: String
    public var sourceUrls: Set<String>

    public init(keyword: String, sourceUrls: Set<String>) {
        self.keyword = keyword
        self.sourceUrls = sourceUrls
    }

    public static func requiresRestart(previous: SourceSwitchCriteria, current: SourceSwitchCriteria) -> Bool {
        previous != current
    }
}

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
