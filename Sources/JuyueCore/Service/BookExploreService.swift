import Foundation

public struct ExploreCategory: Identifiable, Hashable {
    public var id: String { "\(title)_\(url ?? "")" }
    public var title: String
    public var url: String?
    public var isHeader: Bool { (url ?? "").isEmpty }

    /// 有的分类条目不是网址，而是一段 `{java.startBrowser(...)}` 动作脚本。
    public var isAction: Bool {
        let body = (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.hasPrefix("{") && body.hasSuffix("}") && body.contains("java.")
    }

    public init(title: String, url: String? = nil) {
        self.title = title
        self.url = url
    }
}

public class BookExploreService {
    public static let shared = BookExploreService()

    private let categoryCache = ExploreCache<[ExploreCategory]>()
    private let filterCache = ExploreCache<[ExploreFilter]>()

    public init() {}

    public func parseExploreCategories(source: BookSource) -> [ExploreCategory] {
        let key = source.bookSourceUrl
        let signature = "\(source.exploreUrl ?? "")|\(source.variable ?? "")"
        if let hit = categoryCache.read(key: key, signature: signature) {
            return hit
        }
        let computed = categoryList(from: source)
        categoryCache.write(computed, key: key, signature: signature)
        return computed
    }

    public func runActionCategory(source: BookSource, categoryUrl: String) async {
        _ = try? await fetchExploreBooks(source: source, categoryUrl: categoryUrl, page: 1)
    }

    public func parseExploreFilters(source: BookSource) -> [ExploreFilter] {
        let key = source.bookSourceUrl
        let signature = source.exploreScreen ?? ""
        if let hit = filterCache.read(key: key, signature: signature) {
            return hit
        }
        let text = ExploreScript.text(from: signature, source: source)
        let parsed = ExploreScreenParser.parse(text)
        filterCache.write(parsed, key: key, signature: signature)
        return parsed
    }

    // MARK: - 分类

    private func categoryList(from source: BookSource) -> [ExploreCategory] {
        guard let config = source.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !config.isEmpty else {
            return []
        }
        let rendered = ExploreScript.text(from: config, source: source)
        let jsonCategories = categories(fromJSON: rendered)
        return jsonCategories.isEmpty ? categories(fromLines: rendered) : jsonCategories
    }

    private func categories(fromJSON text: String) -> [ExploreCategory] {
        guard let data = text.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let rawTitle = row["title"] as? String else { return nil }
            let title = rawTitle.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            let rawURL = row["url"] as? String
            return ExploreCategory(title: title, url: rawURL.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    private func categories(fromLines text: String) -> [ExploreCategory] {
        text.components(separatedBy: .newlines).compactMap { row in
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            guard let separator = trimmed.range(of: "::") else {
                return ExploreCategory(title: trimmed)
            }
            let title = String(trimmed[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let target = String(trimmed[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            return ExploreCategory(title: title, url: target.isEmpty ? nil : target)
        }
    }

    // MARK: - 抓取

    public func fetchExploreBooks(
        source: BookSource,
        categoryUrl: String,
        page: Int = 1,
        filters: [String: String] = [:]
    ) async throws -> [SearchBook] {
        try await SourceLoginService.shared.requireLoginIfNeeded(source: source)

        let engine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
        prepare(engine: engine, page: page, source: source, filters: filters)

        let address = try render(categoryUrl: categoryUrl, page: page, filters: filters, engine: engine)
        guard !address.isEmpty else { return [] }

        guard let request = NetworkClient.parseJuyueUrl(
            address,
            defaultHeader: source.loginHeader ?? source.header,
            baseUrl: source.bookSourceUrl
        ) else {
            throw NSError(domain: "Juyue", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "无法解析分类网址: \(categoryUrl)"
            ])
        }

        let response = try await NetworkClient.shared.request(
            parsed: request,
            timeout: nil,
            rateKey: source.bookSourceUrl,
            rateLimit: source.rateLimit
        )
        guard (200..<400).contains(response.statusCode) else {
            throw NSError(domain: "Juyue", code: response.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "服务器响应错误: HTTP \(response.statusCode)"
            ])
        }

        return extractBooks(
            html: response.bodyString,
            baseURL: request.url.absoluteString,
            source: source,
            engine: engine
        )
    }

    private func prepare(engine: JSEngine, page: Int, source: BookSource, filters: [String: String]) {
        engine.context.setObject(page, forKeyedSubscript: "page" as NSString)
        engine.context.setObject(page, forKeyedSubscript: "searchPage" as NSString)
        engine.context.setObject(source.bookSourceUrl, forKeyedSubscript: "baseUrl" as NSString)
        engine.context.setObject(filters, forKeyedSubscript: "screen" as NSString)
        for (name, value) in filters {
            engine.context.setObject(value, forKeyedSubscript: name as NSString)
        }
    }

    private func render(
        categoryUrl: String,
        page: Int,
        filters: [String: String],
        engine: JSEngine
    ) throws -> String {
        var target = categoryUrl
            .replacingOccurrences(of: "{{page}}", with: "\(page)")
            .replacingOccurrences(of: "{{(page-1)}}", with: "\(page - 1)")
            .replacingOccurrences(of: "{{page-1}}", with: "\(page - 1)")

        if target.contains("{{") && target.contains("}}") {
            var variables: [String: Any] = ["page": page, "screen": filters]
            for (name, value) in filters {
                variables[name] = value
            }
            target = engine.renderTemplate(target, variables: variables)
        }

        target = Self.applying(filters: filters, to: target)
        return target.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractBooks(
        html: String,
        baseURL: String,
        source: BookSource,
        engine: JSEngine
    ) -> [SearchBook] {
        let rules = ExploreRules(source: source)
        let listAnalyzer = RuleAnalyzer(
            content: html,
            baseUrl: baseURL,
            bookSource: source,
            jsEngine: engine
        )

        return listAnalyzer.getElements(rules.list).compactMap { element in
            let row = RuleAnalyzer(
                content: element,
                baseUrl: baseURL,
                bookSource: source,
                jsEngine: engine
            )

            let name = row.getString(rules.name)
            let bookURL = row.getString(rules.bookURL, isUrl: true)
            guard !name.isEmpty, !bookURL.isEmpty else { return nil }

            let author = row.getString(rules.author)
            let cover = row.getString(rules.cover, isUrl: true)
            let intro = row.getString(rules.intro)
            let kind = row.getString(rules.kind)
            let latest = row.getString(rules.latestChapter)
            let words = row.getString(rules.wordCount)

            return SearchBook(
                name: name,
                author: (author.isEmpty || author == "未知作者") ? "" : author,
                bookUrl: bookURL,
                origin: source.bookSourceUrl,
                originName: source.bookSourceName,
                kind: kind.isEmpty ? nil : kind,
                coverUrl: cover.isEmpty ? nil : CoverURLResolver.resolve(cover, source: source, baseUrl: baseURL),
                intro: intro.isEmpty ? nil : BookContentService.cleanHtml(intro),
                latestChapterTitle: latest.isEmpty ? nil : latest,
                wordCount: words.isEmpty ? nil : words
            )
        }
    }

    // MARK: - 筛选参数

    public static func applying(filters: [String: String], to rawURL: String) -> String {
        guard !filters.isEmpty else { return rawURL }

        let split = splitOptions(rawURL)
        guard !split.address.isEmpty, !split.address.hasPrefix("{") else { return rawURL }

        var parts = URLComponents(string: split.address)
        var queries = parts?.queryItems ?? []
        for (key, value) in filters where !key.isEmpty && !value.isEmpty {
            queries.removeAll { $0.name == key }
            queries.append(URLQueryItem(name: key, value: value))
        }
        parts?.queryItems = queries.isEmpty ? nil : queries
        return (parts?.string ?? split.address) + split.options
    }

    private static func splitOptions(_ raw: String) -> (address: String, options: String) {
        guard let comma = raw.firstIndex(of: ",") else { return (raw, "") }
        let rest = raw[raw.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("{") else { return (raw, "") }
        return (String(raw[..<comma]).trimmingCharacters(in: .whitespaces), String(raw[comma...]))
    }
}

// MARK: - 缓存

private final class ExploreCache<Value> {
    private struct Entry {
        let signature: String
        let value: Value
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    func read(key: String, signature: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.signature == signature else { return nil }
        return entry.value
    }

    func write(_ value: Value, key: String, signature: String) {
        lock.lock()
        entries[key] = Entry(signature: signature, value: value)
        lock.unlock()
    }
}

// MARK: - 脚本与规则

private enum ExploreScript {
    static func text(from config: String, source: BookSource) -> String {
        if let open = config.range(of: "<js>") {
            let close = config.range(of: "</js>")?.lowerBound ?? config.endIndex
            return evaluated(String(config[open.upperBound..<close]), source: source) ?? config
        }
        if config.hasPrefix("@js:") {
            return evaluated(String(config.dropFirst(4)), source: source) ?? config
        }
        return config
    }

    private static func evaluated(_ script: String, source: BookSource) -> String? {
        let engine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
        guard let value = engine.eval(script: script) else { return nil }
        if let text = value as? String { return text }
        if let rows = value as? [[String: Any]],
           let data = try? JSONSerialization.data(withJSONObject: rows) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}

private struct ExploreRules {
    let list: String?
    let name: String?
    let author: String?
    let bookURL: String?
    let cover: String?
    let intro: String?
    let kind: String?
    let latestChapter: String?
    let wordCount: String?

    init(source: BookSource) {
        let explore = source.ruleExplore
        let search = source.ruleSearch
        list = explore?.bookList ?? search?.bookList
        name = explore?.name ?? search?.name
        author = explore?.author ?? search?.author
        bookURL = explore?.bookUrl ?? search?.bookUrl
        cover = explore?.coverUrl ?? search?.coverUrl
        intro = explore?.intro ?? search?.intro
        kind = explore?.kind ?? search?.kind
        latestChapter = explore?.lastChapter ?? search?.lastChapter
        wordCount = explore?.wordCount ?? search?.wordCount
    }
}
