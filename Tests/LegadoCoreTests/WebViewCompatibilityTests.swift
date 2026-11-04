import XCTest
@testable import LegadoCore

/// 书源兼容 P2：`webView` 请求选项与 `ContentRule.webJs` 正文兜底。
final class WebViewCompatibilityTests: XCTestCase {

    override func tearDown() {
        HeadlessWebView.shared.loader = nil
        HeadlessFallbackURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: webView 选项解析

    func testParseWebViewOptionVariants() {
        XCTAssertTrue(parse(#"https://example.com/search,{"body":"searchkey=1","webView":true}"#).usesWebView)
        XCTAssertTrue(parse(#"https://example.com/search,{"webView":"true"}"#).usesWebView)
        XCTAssertTrue(parse(#"https://example.com/search,{"webView":1}"#).usesWebView)
        XCTAssertFalse(parse(#"https://example.com/search,{"webView":false}"#).usesWebView)
        XCTAssertFalse(parse(#"https://example.com/search,{"webView":"false"}"#).usesWebView)
        XCTAssertFalse(parse(#"https://example.com/search,{"body":"x"}"#).usesWebView)
        XCTAssertFalse(parse("https://example.com/search").usesWebView)
    }

    func testParseWebViewKeepsOtherOptions() {
        let request = parse(#"https://example.com/search,{"method":"post","body":"key=1","webView":true}"#)

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.body.flatMap { String(data: $0, encoding: .utf8) }, "key=1")
        XCTAssertTrue(request.usesWebView)
    }

    // MARK: NetworkClient 路由

    func testRequestRoutesWebViewThroughHeadlessLoader() async throws {
        var seen: HeadlessWebRequest?
        let client = NetworkClient(session: .shared, headlessLoader: { request in
            seen = request
            return HeadlessWebResult(finalURL: request.url, html: "<html>渲染后</html>")
        })

        let response = try await client.request(parsed: request(usesWebView: true))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.bodyString, "<html>渲染后</html>")
        XCTAssertEqual(String(data: response.data, encoding: .utf8), "<html>渲染后</html>")
        XCTAssertEqual(seen?.url.absoluteString, "https://example.com/book")
        XCTAssertEqual(seen?.headers["Cookie"], "a=1")
        XCTAssertNil(seen?.javaScript)
    }

    func testWebViewPostPrefetchesResponseThenRendersIt() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeadlessFallbackURLProtocol.self]
        HeadlessFallbackURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )), Data("<html>搜索页</html>".utf8))
        }

        var seen: HeadlessWebRequest?
        let client = NetworkClient(
            session: URLSession(configuration: config),
            headlessLoader: { request in
                seen = request
                return HeadlessWebResult(finalURL: request.url, html: "<html>渲染后</html>")
            }
        )
        let parsed = NetworkClient.ParsedRequest(
            url: URL(string: "https://example.com/search")!,
            method: "POST",
            headers: ["Cookie": "a=1"],
            body: Data("key=1".utf8),
            usesWebView: true
        )

        let response = try await client.request(parsed: parsed)

        XCTAssertEqual(response.bodyString, "<html>渲染后</html>")
        XCTAssertEqual(seen?.html, "<html>搜索页</html>")
        XCTAssertEqual(seen?.url.absoluteString, "https://example.com/search")
    }

    func testRequestWithoutWebViewSkipsHeadlessLoader() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeadlessFallbackURLProtocol.self]
        HeadlessFallbackURLProtocol.handler = { request in
            (try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )), Data("普通响应".utf8))
        }

        let client = NetworkClient(
            session: URLSession(configuration: config),
            headlessLoader: { _ in
                XCTFail("没有 webView 的请求不该走无声网页")
                return HeadlessWebResult(finalURL: URL(string: "https://example.com")!, html: "")
            }
        )

        let response = try await client.request(parsed: request(usesWebView: false))

        XCTAssertEqual(response.bodyString, "普通响应")
    }

    func testRequestFallsBackToURLSessionWhenHeadlessFails() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeadlessFallbackURLProtocol.self]
        HeadlessFallbackURLProtocol.handler = { request in
            (try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )), Data("回退正文".utf8))
        }

        let client = NetworkClient(
            session: URLSession(configuration: config),
            headlessLoader: { _ in throw HeadlessWebError.timedOut }
        )

        let response = try await client.request(parsed: request(usesWebView: true))

        XCTAssertEqual(response.bodyString, "回退正文")
    }

    // MARK: webJs 结果选择

    func testWebJsContentPrefersNonEmptyScriptResult() {
        XCTAssertEqual(WebJsContent.text(from: "  JS正文 \n"), "JS正文")
        XCTAssertEqual(WebJsContent.text(from: "第一行\n第二行"), "第一行\n第二行")
    }

    func testWebJsContentFallsBackWhenScriptResultEmpty() {
        XCTAssertNil(WebJsContent.text(from: ""))
        XCTAssertNil(WebJsContent.text(from: "   \n\t"))
        XCTAssertNil(WebJsContent.text(from: nil))
    }

    // MARK: webJs 正文兜底

    func testChapterContentUsesWebJsResult() async throws {
        let bookUrl = "https://webjs.test/\(UUID().uuidString)/book"
        defer { BookContentService.shared.clearCache(for: bookUrl) }
        HeadlessWebView.shared.loader = { request in
            HeadlessWebResult(
                finalURL: request.url,
                html: #"<div id="content">HTML正文</div>"#,
                javaScriptResult: "JS正文"
            )
        }

        let text = try await BookContentService.shared.fetchChapterContent(
            chapter: chapter(bookUrl: bookUrl, url: "https://webjs.test/chapter/1"),
            source: source(webJs: "document.querySelector('#content').innerText")
        )

        XCTAssertEqual(text, "JS正文")
    }

    func testChapterContentFallsBackToHtmlWhenWebJsReturnsEmpty() async throws {
        let bookUrl = "https://webjs.test/\(UUID().uuidString)/book"
        defer { BookContentService.shared.clearCache(for: bookUrl) }
        HeadlessWebView.shared.loader = { request in
            HeadlessWebResult(
                finalURL: request.url,
                html: #"<div id="content">HTML正文</div>"#,
                javaScriptResult: "  "
            )
        }

        let text = try await BookContentService.shared.fetchChapterContent(
            chapter: chapter(bookUrl: bookUrl, url: "https://webjs.test/chapter/1"),
            source: source(webJs: "document.querySelector('#content').innerText")
        )

        XCTAssertEqual(text, "HTML正文")
    }

    func testPaginatedContentAppliesWebJsPerPage() async throws {
        let bookUrl = "https://webjs.test/\(UUID().uuidString)/book"
        defer { BookContentService.shared.clearCache(for: bookUrl) }
        HeadlessWebView.shared.loader = { request in
            if request.url.absoluteString.contains("_2") {
                return HeadlessWebResult(
                    finalURL: request.url,
                    html: #"<div id="content">第二页</div>"#,
                    javaScriptResult: "第二页"
                )
            }
            return HeadlessWebResult(
                finalURL: request.url,
                html: #"<div id="content">第一页</div><a id="next" href="/chapter/1_2">下一页</a>"#,
                javaScriptResult: "第一页"
            )
        }

        var rule = ContentRule()
        rule.content = "#content"
        rule.webJs = "document.querySelector('#content').innerText"
        rule.nextContentUrl = "#next@href"

        let text = try await BookContentService.shared.fetchChapterContent(
            chapter: chapter(bookUrl: bookUrl, url: "https://webjs.test/chapter/1"),
            source: BookSource(bookSourceUrl: "https://webjs.test", bookSourceName: "webJs分页", ruleContent: rule)
        )

        XCTAssertEqual(text, "第一页\n\n第二页")
    }

    // MARK: 辅助

    private func parse(_ raw: String) -> NetworkClient.ParsedRequest {
        guard let request = NetworkClient.parseLegadoUrl(raw) else {
            XCTFail("URL 解析失败：\(raw)")
            return request(usesWebView: false)
        }
        return request
    }

    private func request(usesWebView: Bool) -> NetworkClient.ParsedRequest {
        NetworkClient.ParsedRequest(
            url: URL(string: "https://example.com/book")!,
            method: "GET",
            headers: ["Cookie": "a=1"],
            body: nil,
            usesWebView: usesWebView
        )
    }

    private func source(webJs: String) -> BookSource {
        var rule = ContentRule()
        rule.content = "#content"
        rule.webJs = webJs
        return BookSource(
            bookSourceUrl: "https://webjs.test",
            bookSourceName: "webJs测试",
            ruleContent: rule
        )
    }

    private func chapter(bookUrl: String, url: String) -> BookChapter {
        BookChapter(bookUrl: bookUrl, url: url, title: "第一章", index: 0)
    }
}

final class HeadlessFallbackURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("Handler not set.")
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
