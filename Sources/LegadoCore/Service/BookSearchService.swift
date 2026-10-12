import Foundation

public class BookSearchService {
    public static let shared = BookSearchService()

    public init() {}

    /// Searches books across a single BookSource
    public func search(source: BookSource, key: String, page: Int = 1) async throws -> [SearchBook] {
        guard let rawSearchUrl = source.searchUrl, !rawSearchUrl.isEmpty else {
            return []
        }

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

        print("[Search] 🚀 [\(source.bookSourceName)] Rendered URL: \(renderedUrl)")

        guard let parsedReq = NetworkClient.parseLegadoUrl(renderedUrl, defaultHeader: headerToUse, baseUrl: source.bookSourceUrl) else {
            print("[Search] ❌ [\(source.bookSourceName)] Failed to parse request URL: \(renderedUrl)")
            return []
        }

        let response = try await NetworkClient.shared.request(parsed: parsedReq)
        print("[Search] 📡 [\(source.bookSourceName)] HTTP \(response.statusCode), received \(response.data.count) bytes")

        guard response.statusCode >= 200 && response.statusCode < 400 else {
            print("[Search] ⚠️ [\(source.bookSourceName)] Non-success HTTP status \(response.statusCode) - skipping")
            return []
        }

        guard let searchRule = source.ruleSearch else {
            print("[Search] ⚠️ [\(source.bookSourceName)] No ruleSearch configured")
            return []
        }

        // Analyze result
        let analyzer = RuleAnalyzer(
            content: response.bodyString,
            baseUrl: parsedReq.url.absoluteString,
            bookSource: source,
            jsEngine: jsEngine
        )

        let bookElements = analyzer.getElements(searchRule.bookList)
        print("[Search] 🔎 [\(source.bookSourceName)] Found \(bookElements.count) book candidate elements")
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

            let coverUrl = itemAnalyzer.getString(searchRule.coverUrl, isUrl: true)
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

        print("[Search] ✅ [\(source.bookSourceName)] Successfully parsed \(searchBooks.count) books")
        return searchBooks
    }

    /// Searches across multiple sources concurrently for a specific page, returning an AsyncStream of (source, books)
    public func searchMultiSources(
        sources: [BookSource],
        key: String,
        page: Int = 1
    ) -> AsyncStream<(source: BookSource, books: [SearchBook])> {
        let enabledSources = sources.filter { $0.enabled != false && $0.searchUrl != nil }
        print("[Search] 🔍 Multi-source search initiated for '\(key)' (page: \(page)) across \(enabledSources.count) enabled sources: \(enabledSources.map { $0.bookSourceName }.joined(separator: ", "))")

        return AsyncStream { continuation in
            Task {
                await withTaskGroup(of: (BookSource, [SearchBook]).self) { group in
                    for source in enabledSources {
                        group.addTask {
                            do {
                                let books = try await self.search(source: source, key: key, page: page)
                                return (source, books)
                            } catch {
                                print("[Search] ❌ [\(source.bookSourceName)] Request error (page: \(page)): \(error.localizedDescription)")
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
