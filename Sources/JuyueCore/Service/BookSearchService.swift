import Foundation

public class BookSearchService {
    public static let shared = BookSearchService()

    /// 单次搜索的实测耗时回传给宿主，用来更新书源的 `respondTime`。
    public static var respondTimeSink: ((_ sourceUrl: String, _ milliseconds: Int64) -> Void)?

    public init() {}

    public func search(
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

        JuyueLog.log("[Search] [\(source.bookSourceName)] 请求已构造 host=\(URL(string: address)?.host ?? "-")")

        guard let request = NetworkClient.parseJuyueUrl(
            address,
            defaultHeader: header,
            baseUrl: source.bookSourceUrl
        ) else {
            JuyueLog.log("[Search] ❌ [\(source.bookSourceName)] 请求 URL 解析失败 host=\(URL(string: address)?.host ?? "-")")
            return []
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

        let elapsed = Int64(Date().timeIntervalSince(started) * 1000)
        let success = (200..<400).contains(response.statusCode)
        if success {
            BookSearchService.respondTimeSink?(source.bookSourceUrl, elapsed)
        }
        JuyueLog.log("[Search] [\(source.bookSourceName)] HTTP \(response.statusCode)，收到 \(response.data.count) 字节")

        guard success else {
            JuyueLog.log("[Search] ⚠️ [\(source.bookSourceName)] HTTP \(response.statusCode) 非成功状态，跳过")
            return []
        }

        guard let rule = source.ruleSearch else {
            JuyueLog.log("[Search] ⚠️ [\(source.bookSourceName)] 没有配置搜索规则")
            return []
        }

        let analyzer = RuleAnalyzer(
            content: response.bodyString,
            baseUrl: request.url.absoluteString,
            bookSource: source,
            jsEngine: engine
        )

        let ruleStarted = Date()
        let elements = analyzer.getElements(rule.bookList)
        let ruleElapsed = Int64(Date().timeIntervalSince(ruleStarted) * 1000)

        DiagnosticHub.emit(SourceRequestDiagnostic(
            step: "搜索",
            sourceName: source.bookSourceName,
            url: request.url.absoluteString,
            statusCode: response.statusCode,
            elapsedMs: elapsed,
            responseBytes: response.data.count,
            responsePreview: DiagnosticPreview.make(response.bodyString),
            ruleHits: elements.count,
            ruleEvalMs: ruleElapsed,
            headersSummary: DiagnosticFailure.summarize(request.headers),
            note: "解析出 \(elements.count) 个候选"
        ), to: diagnostics)

        JuyueLog.log("[Search] [\(source.bookSourceName)] 候选条目 \(elements.count) 个")

        let books = elements.compactMap { element in
            makeBook(
                element: element,
                rule: rule,
                source: source,
                baseURL: request.url.absoluteString,
                engine: engine
            )
        }

        JuyueLog.log("[Search] ✅ [\(source.bookSourceName)] 解析出 \(books.count) 本书")
        return books
    }

    public func searchMultiSources(
        sources: [BookSource],
        key: String,
        page: Int = 1
    ) -> AsyncStream<(source: BookSource, books: [SearchBook])> {
        let targets = sources
            .filter { $0.enabled != false && $0.searchUrl != nil }
            .sorted(by: BookSource.selectionOrder)

        JuyueLog.log("[Search] 开始多源搜索 page=\(page) 源数=\(targets.count) 关键词长度=\(key.count)")

        return AsyncStream { continuation in
            Task {
                await withTaskGroup(of: (BookSource, [SearchBook]).self) { group in
                    for source in targets {
                        group.addTask {
                            do {
                                return (source, try await self.search(source: source, key: key, page: page))
                            } catch {
                                JuyueLog.log("[Search] ❌ [\(source.bookSourceName)] 请求出错 page=\(page): \(error.localizedDescription)")
                                return (source, [])
                            }
                        }
                    }
                    for await batch in group {
                        continuation.yield(batch)
                    }
                }
                continuation.finish()
            }
        }
    }

    public func searchMultiSources(sources: [BookSource], key: String) -> AsyncStream<[SearchBook]> {
        AsyncStream { continuation in
            Task {
                for await (_, books) in self.searchMultiSources(sources: sources, key: key, page: 1) {
                    guard !books.isEmpty else { continue }
                    continuation.yield(books)
                }
                continuation.finish()
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

// MARK: - 模板渲染

private enum SearchTemplate {
    static func renderURL(_ template: String, key: String, page: Int, engine: JSEngine) -> String {
        if let script = SearchScript.body(in: template),
           let rendered = SearchScript.evaluate(script, engine: engine),
           !rendered.isEmpty {
            return rendered
        }
        guard SearchScript.body(in: template) == nil else { return template }

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
