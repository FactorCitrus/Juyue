import Foundation

public struct ExploreCategory: Identifiable, Hashable {
    public var id: String { "\(title)_\(url ?? "")" }
    public var title: String
    public var url: String?
    public var isHeader: Bool { url == nil || url?.isEmpty == true }

    public init(title: String, url: String? = nil) {
        self.title = title
        self.url = url
    }
}

public class BookExploreService {
    public static let shared = BookExploreService()

    public init() {}

    /// Parses the categories configured in a BookSource's `exploreUrl`
    public func parseExploreCategories(source: BookSource) -> [ExploreCategory] {
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
    public func fetchExploreBooks(source: BookSource, categoryUrl: String, page: Int = 1) async throws -> [SearchBook] {
        var renderedUrl = categoryUrl
        let jsEngine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
        jsEngine.context.setObject(page, forKeyedSubscript: "page" as NSString)
        jsEngine.context.setObject(page, forKeyedSubscript: "searchPage" as NSString)
        jsEngine.context.setObject(source.bookSourceUrl, forKeyedSubscript: "baseUrl" as NSString)

        renderedUrl = renderedUrl
            .replacingOccurrences(of: "{{page}}", with: "\(page)")
            .replacingOccurrences(of: "{{(page-1)}}", with: "\(page - 1)")
            .replacingOccurrences(of: "{{page-1}}", with: "\(page - 1)")

        if renderedUrl.contains("{{") && renderedUrl.contains("}}") {
            renderedUrl = jsEngine.renderTemplate(renderedUrl, variables: ["page": page])
        }

        guard let parsedReq = NetworkClient.parseLegadoUrl(
            renderedUrl,
            defaultHeader: source.loginHeader ?? source.header,
            baseUrl: source.bookSourceUrl
        ) else {
            throw NSError(domain: "Legado", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析分类网址: \(categoryUrl)"])
        }

        let response = try await NetworkClient.shared.request(parsed: parsedReq)
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

            let coverUrl = itemAnalyzer.getString(coverUrlRule, isUrl: true)
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
}
