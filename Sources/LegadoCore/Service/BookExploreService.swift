import Foundation

public struct ExploreCategory: Identifiable, Hashable {
    public var id: String { "\(title)_\(url ?? "")" }
    public var title: String
    public var url: String?
    public var isHeader: Bool { url == nil || url?.isEmpty == true }

    /// 「点一下执行脚本」的分类条目：url 本身是一段 java 调用，渲染后没有网址可抓，
    /// 例如 `{java.startBrowser("https://fanqienovel.com/","番茄登录");}`。
    public var isAction: Bool {
        let raw = (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.hasPrefix("{") && raw.contains("java.") && raw.hasSuffix("}")
    }

    public init(title: String, url: String? = nil) {
        self.title = title
        self.url = url
    }
}

public class BookExploreService {
    public static let shared = BookExploreService()

    public init() {}

    /// 分类解析缓存。解析要跑一遍书源 JS（聚合源的 jsLib 三万字符），手机上几秒。
    /// 缓存键是 bookSourceUrl，值里带 exploreUrl 和源变量做签名，源一变就失效。
    private var categoryCache: [String: (signature: String, value: [ExploreCategory])] = [:]
    private var filterCache: [String: (signature: String, value: [ExploreFilter])] = [:]
    private let categoryLock = NSLock()

    public func parseExploreCategories(source: BookSource) -> [ExploreCategory] {
        let signature = "\(source.exploreUrl ?? "")|\(source.variable ?? "")"
        let key = source.bookSourceUrl

        categoryLock.lock()
        if let cached = categoryCache[key], cached.signature == signature {
            categoryLock.unlock()
            return cached.value
        }
        categoryLock.unlock()

        let result = computeExploreCategories(source: source)

        categoryLock.lock()
        categoryCache[key] = (signature, result)
        categoryLock.unlock()
        return result
    }

    /// 执行动作类分类：脚本弹浏览器或弹提示，没有书可抓。
    public func runActionCategory(source: BookSource, categoryUrl: String) async {
        _ = try? await fetchExploreBooks(source: source, categoryUrl: categoryUrl, page: 1)
    }

    /// 解析 `exploreScreen`。有的源把它写成 `<js>`，先执行脚本再按 JSON 解析。
    public func parseExploreFilters(source: BookSource) -> [ExploreFilter] {
        let signature = source.exploreScreen ?? ""
        let key = source.bookSourceUrl

        categoryLock.lock()
        if let cached = filterCache[key], cached.signature == signature {
            categoryLock.unlock()
            return cached.value
        }
        categoryLock.unlock()

        var raw = signature
        if raw.contains("<js>") || raw.hasPrefix("@js:") {
            let engine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
            if let value = engine.eval(script: JSEngine.unwrapJsScript(raw)) {
                if let text = value as? String {
                    raw = text
                } else if let array = value as? [[String: Any]],
                          let data = try? JSONSerialization.data(withJSONObject: array),
                          let text = String(data: data, encoding: .utf8) {
                    raw = text
                }
            }
        }
        let result = ExploreScreenParser.parse(raw)

        categoryLock.lock()
        filterCache[key] = (signature, result)
        categoryLock.unlock()
        return result
    }

    /// Parses the categories configured in a BookSource's `exploreUrl`
    private func computeExploreCategories(source: BookSource) -> [ExploreCategory] {
        guard let exploreUrl = source.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !exploreUrl.isEmpty else {
            return []
        }

        var jsonString: String = exploreUrl

        // If JS script enclosed in <js>...</js> or starting with @js:
        if exploreUrl.contains("<js>") {
            let start = exploreUrl.range(of: "<js>")?.upperBound ?? exploreUrl.startIndex
            let end = exploreUrl.range(of: "</js>")?.lowerBound ?? exploreUrl.endIndex
            let script = String(exploreUrl[start..<end])
            let engine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
            if let result = engine.eval(script: script) {
                if let str = result as? String {
                    jsonString = str
                } else if let arr = result as? [[String: Any]],
                          let data = try? JSONSerialization.data(withJSONObject: arr),
                          let str = String(data: data, encoding: .utf8) {
                    jsonString = str
                }
            }
        } else if exploreUrl.hasPrefix("@js:") {
            let script = String(exploreUrl.dropFirst(4))
            let engine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
            if let result = engine.eval(script: script) as? String {
                jsonString = result
            }
        }

        // Try parsing JSON array
        if let data = jsonString.data(using: .utf8),
           let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var categories: [ExploreCategory] = []
            for item in rawArray {
                guard let title = item["title"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
                    continue
                }
                let rawUrl = item["url"] as? String
                let cleanUrl = rawUrl?.isEmpty == true ? nil : rawUrl
                categories.append(ExploreCategory(title: title, url: cleanUrl))
            }
            if !categories.isEmpty {
                return categories
            }
        }

        // Fallback: parse newline format: "Title::url" or "Title"
        var categories: [ExploreCategory] = []
        let lines = jsonString.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.contains("::") {
                let parts = trimmed.components(separatedBy: "::")
                let title = parts[0].trimmingCharacters(in: .whitespaces)
                let url = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
                categories.append(ExploreCategory(title: title, url: url?.isEmpty == true ? nil : url))
            } else {
                categories.append(ExploreCategory(title: trimmed, url: nil))
            }
        }
        return categories
    }

    /// Fetches books from a given category URL of a BookSource
    public func fetchExploreBooks(
        source: BookSource,
        categoryUrl: String,
        page: Int = 1,
        filters: [String: String] = [:]
    ) async throws -> [SearchBook] {
        try await SourceLoginService.shared.requireLoginIfNeeded(source: source)
        var renderedUrl = categoryUrl
        let jsEngine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
        jsEngine.context.setObject(page, forKeyedSubscript: "page" as NSString)
        jsEngine.context.setObject(page, forKeyedSubscript: "searchPage" as NSString)
        jsEngine.context.setObject(source.bookSourceUrl, forKeyedSubscript: "baseUrl" as NSString)
        jsEngine.context.setObject(filters, forKeyedSubscript: "screen" as NSString)
        for (name, value) in filters {
            jsEngine.context.setObject(value, forKeyedSubscript: name as NSString)
        }

        renderedUrl = renderedUrl
            .replacingOccurrences(of: "{{page}}", with: "\(page)")
            .replacingOccurrences(of: "{{(page-1)}}", with: "\(page - 1)")
            .replacingOccurrences(of: "{{page-1}}", with: "\(page - 1)")

        if renderedUrl.contains("{{") && renderedUrl.contains("}}") {
            var variables: [String: Any] = ["page": page, "screen": filters]
            for (name, value) in filters { variables[name] = value }
            renderedUrl = jsEngine.renderTemplate(renderedUrl, variables: variables)
        }

        renderedUrl = Self.applying(filters: filters, to: renderedUrl)

        // 有些分类条目是「点一下执行脚本」，例如大灰狼的「登录番茄」，url 就是
        // `{{java.startBrowser("https://fanqienovel.com/","番茄登录");}}`。
        // 渲染后 url 为空，动作已执行，返回空列表，不按解析失败处理。
        guard !renderedUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        guard let parsedReq = NetworkClient.parseLegadoUrl(
            renderedUrl,
            defaultHeader: source.loginHeader ?? source.header,
            baseUrl: source.bookSourceUrl
        ) else {
            throw NSError(domain: "Legado", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析分类网址: \(categoryUrl)"])
        }

        let response = try await NetworkClient.shared.request(
            parsed: parsedReq,
            timeout: nil,
            rateKey: source.bookSourceUrl,
            rateLimit: source.rateLimit
        )
        guard (200..<400).contains(response.statusCode) else {
            throw NSError(domain: "Legado", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "服务器响应错误: HTTP \(response.statusCode)"])
        }

        let bookListRule = source.ruleExplore?.bookList ?? source.ruleSearch?.bookList
        let nameRule = source.ruleExplore?.name ?? source.ruleSearch?.name
        let authorRule = source.ruleExplore?.author ?? source.ruleSearch?.author
        let bookUrlRule = source.ruleExplore?.bookUrl ?? source.ruleSearch?.bookUrl
        let coverUrlRule = source.ruleExplore?.coverUrl ?? source.ruleSearch?.coverUrl
        let introRule = source.ruleExplore?.intro ?? source.ruleSearch?.intro
        let kindRule = source.ruleExplore?.kind ?? source.ruleSearch?.kind
        let lastChapterRule = source.ruleExplore?.lastChapter ?? source.ruleSearch?.lastChapter
        let wordCountRule = source.ruleExplore?.wordCount ?? source.ruleSearch?.wordCount

        let analyzer = RuleAnalyzer(
            content: response.bodyString,
            baseUrl: parsedReq.url.absoluteString,
            bookSource: source,
            jsEngine: jsEngine
        )

        let bookElements = analyzer.getElements(bookListRule)
        var books: [SearchBook] = []

        for item in bookElements {
            let itemAnalyzer = RuleAnalyzer(
                content: item,
                baseUrl: parsedReq.url.absoluteString,
                bookSource: source,
                jsEngine: jsEngine
            )

            let name = itemAnalyzer.getString(nameRule)
            let author = itemAnalyzer.getString(authorRule)
            let bookUrl = itemAnalyzer.getString(bookUrlRule, isUrl: true)

            guard !name.isEmpty, !bookUrl.isEmpty else { continue }

            let rawCover = itemAnalyzer.getString(coverUrlRule, isUrl: true)
            let coverUrl = rawCover.isEmpty
                ? ""
                : CoverURLResolver.resolve(rawCover, source: source, baseUrl: parsedReq.url.absoluteString)
            let intro = itemAnalyzer.getString(introRule)
            let kind = itemAnalyzer.getString(kindRule)
            let lastChapter = itemAnalyzer.getString(lastChapterRule)
            let wordCount = itemAnalyzer.getString(wordCountRule)

            let cleanedIntro = intro.isEmpty ? nil : BookContentService.cleanHtml(intro)
            let cleanedAuthor = (author.isEmpty || author == "未知作者") ? "" : author

            let book = SearchBook(
                name: name,
                author: cleanedAuthor,
                kind: kind.isEmpty ? nil : kind,
                bookUrl: bookUrl,
                coverUrl: coverUrl.isEmpty ? nil : coverUrl,
                intro: cleanedIntro,
                latestChapterTitle: lastChapter.isEmpty ? nil : lastChapter,
                origin: source.bookSourceUrl,
                originName: source.bookSourceName,
                wordCount: wordCount.isEmpty ? nil : wordCount
            )
            books.append(book)
        }

        return books
    }

    /// 筛选值按查询参数追加到分类 URL。`url,{json options}` 的请求选项要留在末尾。
    public static func applying(filters: [String: String], to rawURL: String) -> String {
        guard !filters.isEmpty else { return rawURL }

        var urlPart = rawURL
        var optionsPart = ""
        if let comma = rawURL.firstIndex(of: ","),
           rawURL[rawURL.index(after: comma)...].trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            urlPart = String(rawURL[..<comma]).trimmingCharacters(in: .whitespaces)
            optionsPart = String(rawURL[comma...])
        }
        guard !urlPart.isEmpty, !urlPart.hasPrefix("{") else { return rawURL }

        var components = URLComponents(string: urlPart)
        var items = components?.queryItems ?? []
        for (name, value) in filters where !name.isEmpty && !value.isEmpty {
            items.removeAll { $0.name == name }
            items.append(URLQueryItem(name: name, value: value))
        }
        components?.queryItems = items.isEmpty ? nil : items
        let result = components?.string ?? urlPart
        return result + optionsPart
    }
}
