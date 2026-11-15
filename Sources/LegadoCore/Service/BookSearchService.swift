import Foundation

public class BookSearchService {
    public static let shared = BookSearchService()

    /// 单次搜索的实测耗时回传给宿主，用来更新书源的 `respondTime`。
    public static var respondTimeSink: ((_ sourceUrl: String, _ milliseconds: Int64) -> Void)?

    public init() {}

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
        guard let template = source.searchUrl, !template.isEmpty else {
            return []
        }
        try await SourceLoginService.shared.requireLoginIfNeeded(source: source)

        let engine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
        bind(engine: engine, key: key, page: page, source: source)

        let address = SearchTemplate.renderURL(template, key: key, page: page, engine: engine)
        let header = SearchTemplate.renderHeader(source.loginHeader ?? source.header, engine: engine)

        guard let rule = source.ruleSearch else {
            LegadoLog.log("[Search] ⚠️ [\(source.bookSourceName)] 没有配置搜索规则")
            return []
        }

        var bodyString: String
        var baseURL: String
        var responseBytes: Int
        var statusCode = 200
        var headersSummary = ""
        var elapsed: Int64 = 0

        // 聚合源的搜索地址可能是 data: 包：直接在本机跑规则，不发网络请求。
        if let payload = NetworkClient.dataURLPayload(address) {
            bodyString = payload
            baseURL = address
            responseBytes = payload.utf8.count
            LegadoLog.log("[Search] [\(source.bookSourceName)] data: 搜索载荷 \(responseBytes) 字节")
        } else {
            // 自定义协议在书源里常见于聚合源（如 moyue://），依赖外部 App / 服务端，
            // 不能交给 URLSession，否则只剩一句「不支持的 URL」。
            if let scheme = NetworkClient.unsupportedScheme(in: address) {
                let error = UnsupportedBookSourceSchemeError(
                    scheme: scheme,
                    sourceName: source.bookSourceName
                )
                LegadoLog.log("[Search] ❌ [\(source.bookSourceName)] 自定义协议 \(scheme) 不支持")
                DiagnosticHub.emit(SourceRequestDiagnostic(
                    step: "搜索",
                    sourceName: source.bookSourceName,
                    url: address,
                    failureKind: DiagnosticFailure.classify(error),
                    note: error.localizedDescription
                ), to: diagnostics)
                throw SearchRequestFailure(failure: .unsupportedScheme(scheme))
            }

            LegadoLog.log("[Search] [\(source.bookSourceName)] 请求已构造 host=\(URL(string: address)?.host ?? "-")")

            guard let request = NetworkClient.parseJuyueUrl(
                address,
                defaultHeader: header,
                baseUrl: source.bookSourceUrl
            ) else {
                LegadoLog.log("[Search] ❌ [\(source.bookSourceName)] 请求 URL 解析失败 host=\(URL(string: address)?.host ?? "-")")
                throw SearchRequestFailure(failure: .urlParseFailed(host: URL(string: address)?.host))
            }

            let started = Date()
            let response: NetworkResponse
            do {
                response = try await NetworkClient.shared.request(
                    parsed: request,
                    timeout: nil,
                    rateKey: source.bookSourceUrl,
                    rateLimit: source.rateLimit
                )
            } catch {
                emitFailure(
                    source: source,
                    request: request,
                    started: started,
                    error: error,
                    diagnostics: diagnostics
                )
                throw error
            }

            elapsed = Int64(Date().timeIntervalSince(started) * 1000)
            let success = (200..<400).contains(response.statusCode)
            if success {
                BookSearchService.respondTimeSink?(source.bookSourceUrl, elapsed)
            }
            LegadoLog.log("[Search] [\(source.bookSourceName)] HTTP \(response.statusCode)，收到 \(response.data.count) 字节")

            guard success else {
                LegadoLog.log("[Search] ⚠️ [\(source.bookSourceName)] HTTP \(response.statusCode) 非成功状态，跳过")
                throw SearchRequestFailure(failure: .httpStatus(response.statusCode))
            }

            bodyString = response.bodyString
            baseURL = request.url.absoluteString
            responseBytes = response.data.count
            statusCode = response.statusCode
            headersSummary = DiagnosticFailure.summarize(request.headers)
        }

        let analyzer = RuleAnalyzer(
            content: bodyString,
            baseUrl: baseURL,
            bookSource: source,
            jsEngine: engine
        )

        let ruleStarted = Date()
        let elements = analyzer.getElements(rule.bookList)
        let ruleElapsed = Int64(Date().timeIntervalSince(ruleStarted) * 1000)

        DiagnosticHub.emit(SourceRequestDiagnostic(
            step: "搜索",
            sourceName: source.bookSourceName,
            url: baseURL,
            statusCode: statusCode,
            elapsedMs: elapsed,
            responseBytes: responseBytes,
            responsePreview: DiagnosticPreview.make(bodyString),
            ruleHits: elements.count,
            ruleEvalMs: ruleElapsed,
            headersSummary: headersSummary,
            note: "解析出 \(elements.count) 个候选"
        ), to: diagnostics)

        LegadoLog.log("[Search] [\(source.bookSourceName)] 候选条目 \(elements.count) 个")

        let books = elements.compactMap { element in
            makeBook(
                element: element,
                rule: rule,
                source: source,
                baseURL: baseURL,
                engine: engine
            )
        }

        LegadoLog.log("[Search] ✅ [\(source.bookSourceName)] 解析出 \(books.count) 本书")
        return books
    }

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
        let targets = sources
            .filter { $0.enabled != false && $0.searchUrl != nil }
            .sorted(by: BookSource.selectionOrder)

        LegadoLog.log("[Search] 开始多源搜索 page=\(page) 源数=\(targets.count) 关键词长度=\(key.count)")

        return AsyncStream { continuation in
            let worker = Task {
                await withTaskGroup(of: SearchSourceOutcome.self) { group in
                    var pending = targets.makeIterator()
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

    // MARK: - 组装请求

    private func bind(engine: JSEngine, key: String, page: Int, source: BookSource) {
        let context = engine.context
        context.setObject(key, forKeyedSubscript: "key" as NSString)
        context.setObject(key, forKeyedSubscript: "searchKey" as NSString)
        context.setObject(page, forKeyedSubscript: "page" as NSString)
        context.setObject(page, forKeyedSubscript: "searchPage" as NSString)
        context.setObject(source.bookSourceUrl, forKeyedSubscript: "baseUrl" as NSString)
    }

    private func makeBook(
        element: Any,
        rule: SearchRule,
        source: BookSource,
        baseURL: String,
        engine: JSEngine
    ) -> SearchBook? {
        let row = RuleAnalyzer(
            content: element,
            baseUrl: baseURL,
            bookSource: source,
            jsEngine: engine
        )

        let name = row.getString(rule.name)
        let bookURL = row.getString(rule.bookUrl, isUrl: true)
        guard !name.isEmpty, !bookURL.isEmpty else { return nil }

        let author = row.getString(rule.author)
        let cover = row.getString(rule.coverUrl, isUrl: true)
        let intro = row.getString(rule.intro)
        let kind = row.getString(rule.kind)
        let latest = row.getString(rule.lastChapter)
        let words = row.getString(rule.wordCount)

        return SearchBook(
            name: name,
            author: author,
            bookUrl: bookURL,
            origin: source.bookSourceUrl,
            originName: source.bookSourceName,
            kind: kind.isEmpty ? nil : kind,
            coverUrl: cover.isEmpty ? nil : CoverURLResolver.resolve(cover, source: source, baseUrl: baseURL),
            intro: intro.isEmpty ? nil : intro,
            latestChapterTitle: latest.isEmpty ? nil : latest,
            wordCount: words.isEmpty ? nil : words
        )
    }

    private func emitFailure(
        source: BookSource,
        request: NetworkClient.ParsedRequest,
        started: Date,
        error: Error,
        diagnostics: ((SourceRequestDiagnostic) -> Void)?
    ) {
        DiagnosticHub.emit(SourceRequestDiagnostic(
            step: "搜索",
            sourceName: source.bookSourceName,
            url: request.url.absoluteString,
            elapsedMs: Int64(Date().timeIntervalSince(started) * 1000),
            headersSummary: DiagnosticFailure.summarize(request.headers),
            failureKind: DiagnosticFailure.classify(error),
            note: "请求失败：\(error.localizedDescription)"
        ), to: diagnostics)
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

// MARK: - 模板渲染

enum SearchTemplate {
    static func renderURL(_ template: String, key: String, page: Int, engine: JSEngine) -> String {
        if let script = SearchScript.body(in: template),
           let rendered = SearchScript.evaluate(script, engine: engine),
           !rendered.isEmpty {
            // JS 常常只拼出带 {{key}} / {{page}} 的地址，再用模板渲染一次；
            // 这里不执行 <js>，否则脚本会被跑两遍。
            return fill(rendered, key: key, page: page, engine: engine)
        }
        guard SearchScript.body(in: template) == nil else { return template }
        return fill(template, key: key, page: page, engine: engine)
    }

    private static func fill(_ template: String, key: String, page: Int, engine: JSEngine) -> String {
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

    static func renderHeader(_ raw: String?, engine: JSEngine) -> String? {
        guard let raw, let script = SearchScript.body(in: raw) else { return raw }
        return SearchScript.evaluate(script, engine: engine) ?? raw
    }
}

private enum SearchScript {
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

    static func evaluate(_ script: String, engine: JSEngine) -> String? {
        guard let value = engine.context.evaluateScript(script)?.toString(),
              !value.isEmpty,
              value != "undefined",
              value != "null" else {
            return nil
        }
        return value
    }
}

// MARK: - 换源与搜索匹配

/// 换源界面用哪几个字段判定「这是同一本书」。
public struct SourceMatchOptions: Equatable {
    public var matchTitle: Bool
    public var matchAuthor: Bool
    public var exact: Bool

    public init(matchTitle: Bool = true, matchAuthor: Bool = false, exact: Bool = false) {
        self.matchTitle = matchTitle
        self.matchAuthor = matchAuthor
        self.exact = exact
    }
}

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
    public enum SearchField: String, CaseIterable {
        case title
        case author
        case either
    }

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
            let titleHit = hit(candidate.name, keyword, exact: exact)
            let authorHit = hit(candidate.author, keyword, exact: exact)
            return titleHit || authorHit
        }
    }

    public static func filterSources(
        _ sources: [BookSource],
        nameFilter: String,
        group: String?
    ) -> [BookSource] {
        var scoped = sources
        if let group, !group.isEmpty {
            scoped = scoped.filter { ($0.bookSourceGroup ?? "") == group }
        }

        let query = nameFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return scoped }

        return scoped.filter { source in
            let nameMatches = source.bookSourceName.lowercased().contains(query)
            let groupMatches = (source.bookSourceGroup ?? "").lowercased().contains(query)
            return nameMatches || groupMatches
        }
    }

    /// 去掉空白与书名号 / 引号 / 间隔号，英文转小写。
    public static func normalized(_ text: String) -> String {
        text.unicodeScalars
            .filter { !noise.contains($0) }
            .map { String($0) }
            .joined()
            .lowercased()
    }

    public static func matches(
        _ candidate: SearchBook,
        title: String,
        author: String,
        options: SourceMatchOptions
    ) -> Bool {
        var decisions: [Bool] = []
        if options.matchTitle {
            decisions.append(hit(candidate.name, title, exact: options.exact))
        }
        if options.matchAuthor {
            decisions.append(hit(candidate.author, author, exact: options.exact))
        }
        return !decisions.isEmpty && decisions.allSatisfy { $0 }
    }

    private static let noise = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "《》「」『』“”‘’\"'·•"))

    private static func hit(_ candidate: String, _ target: String, exact: Bool) -> Bool {
        let left = normalized(candidate)
        let right = normalized(target)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if exact { return left == right }
        return left.contains(right) || right.contains(left)
    }
}
