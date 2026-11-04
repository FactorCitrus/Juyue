import XCTest
@testable import LegadoCore

final class DataURLProtocolTests: XCTestCase {

    /// 聚合源的 bookUrl / 章节网址是 `data:;base64,<载荷>,<ext>`，宿主得把载荷解出来。
    func testDataURLPayload() throws {
        let payload = #"{"book_id":"7137595427590767141","sources":"番茄","tab":"小说","url":""}"#
        let b64 = Data(payload.utf8).base64EncodedString()
        let url = "data:;base64,\(b64),%7B%22type%22%3A%22qingtian%22%7D"
        XCTAssertEqual(NetworkClient.dataURLPayload(url), payload)

        // 普通网址不该被当成 data: 包
        XCTAssertNil(NetworkClient.dataURLPayload("https://v5.langge.uk/detail?book_id=1"))
        XCTAssertNil(NetworkClient.dataURLPayload("data:;base64,不是base64"))
    }

    /// 章节脚本回的是 `{"code":0,…,"data":[…]}`，条目要按 data 数组取。
    func testElementsFromJSONText() throws {
        let text = #"{"code":0,"msg":"","data":[{"title":"第1章 兔子美，惹人追"},{"title":"第2章"}]}"#
        let elements = try XCTUnwrap(RuleAnalyzer.elementsFromJSONText(text))
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual((elements.first as? [String: Any])?["title"] as? String, "第1章 兔子美，惹人追")

        XCTAssertEqual(RuleAnalyzer.elementsFromJSONText(#"[{"title":"a"}]"#)?.count, 1)
        XCTAssertNil(RuleAnalyzer.elementsFromJSONText("不是 JSON"))
        XCTAssertNil(RuleAnalyzer.elementsFromJSONText(#"{"code":0,"msg":"ok"}"#))
    }
}

final class JsRuleSuffixTests: XCTestCase {

    /// `<js>…</js>$.content`：尾巴那段规则要套在 JS 结果上。
    ///
    /// 聚合源的正文规则就是这么写的（脚本回 `{"content":"…"}`，后面挂 `$.content`），
    /// 不接尾巴的话正文会带着 JSON 壳和 `\n` 直接上屏。
    func testJsRuleWithJSONPathSuffix() throws {
        let analyzer = RuleAnalyzer(content: "")
        let rule = #"<js>JSON.stringify({content:"第1章 正文第一段"})</js>$.content"#
        XCTAssertEqual(analyzer.getString(rule), "第1章 正文第一段")

        // 没有尾巴的写法保持原样
        let plain = RuleAnalyzer(content: "")
        XCTAssertEqual(plain.getString(#"<js>"原样返回"</js>"#), "原样返回")
    }
}

final class SourceCompatibilityNetworkTests: XCTestCase {

    /// 相对地址统一走 URL(string:relativeTo:)，不带 `/` 的也要按 base 解析；
    /// fragment 在发请求前剥掉；base 不合法时不能拼出半截地址。
    func testRelativeAddressResolution() {
        let base = "https://example.com/book/index.html"

        XCTAssertEqual(
            NetworkClient.parseLegadoUrl("/chapter/1", baseUrl: base)?.url.absoluteString,
            "https://example.com/chapter/1"
        )
        XCTAssertEqual(
            NetworkClient.parseLegadoUrl("chapter/1", baseUrl: base)?.url.absoluteString,
            "https://example.com/book/chapter/1"
        )
        XCTAssertEqual(
            NetworkClient.parseLegadoUrl("https://other.example/a#part", baseUrl: base)?.url.absoluteString,
            "https://other.example/a"
        )

        XCTAssertEqual(
            NetworkClient.parseLegadoUrl("https://ok.example/a", baseUrl: "不是网址")?.url.absoluteString,
            "https://ok.example/a"
        )
        XCTAssertNil(NetworkClient.parseLegadoUrl("chapter/1", baseUrl: "不是网址"))
    }

    /// 书源站还大量用 GBK/GB2312：响应头优先，没有头就嗅 HTML meta。
    func testReplyPackagerDecodesGBK() throws {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding("GBK" as CFString)
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        let bytes = try XCTUnwrap("中文测试".data(using: encoding))

        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=GBK"]
        ))
        XCTAssertEqual(NetworkClient.package(bytes: bytes, response: response).bodyString, "中文测试")

        let html = #"<html><head><meta charset="gb2312"><title>中文测试</title></head></html>"#
        let htmlBytes = try XCTUnwrap(html.data(using: encoding))
        XCTAssertTrue(NetworkClient.package(bytes: htmlBytes, response: nil).bodyString.contains("中文测试"))
    }

    /// 非 base64 的 data: 文本也要能解出来。
    func testDataURLPlainTextPayload() {
        let payload = "<div>斗破苍穹</div>"
        let encoded = payload.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(NetworkClient.dataURLPayload("data:text/plain,\(encoded)"), payload)
        XCTAssertNil(NetworkClient.dataURLPayload("data:text/plain,"))
    }
}

final class SearchTemplateRenderTests: XCTestCase {

    /// JS 只拼出带 {{key}}/{{page}} 的地址时，要再用模板渲染一次；
    /// 但 <js> 块不能重复执行。
    func testSearchURLJSResultRendersPlaceholdersAgain() {
        let source = BookSource(bookSourceUrl: "https://example.com", bookSourceName: "js源")
        let engine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)

        let template = #"<js>var hits = (typeof hits === "undefined" ? 0 : hits) + 1; "https://m.example.com/search?q={{key}}&p={{page}}&hits=" + hits</js>"#
        let rendered = BookSearchService.renderSearchURL(template, key: "斗破苍穹", page: 2, engine: engine)

        XCTAssertEqual(rendered, "https://m.example.com/search?q=斗破苍穹&p=2&hits=1")
    }
}

final class DataURLSearchTests: XCTestCase {

    /// 搜索地址是 data: 包时直接在本机跑规则，不发网络请求。
    func testSearchFromDataURLWithoutNetwork() async throws {
        let html = #"<div class="item"><a href="https://example.com/book/1">斗破苍穹</a></div>"#
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let dataURL = "data:text/html,\(encoded)"

        var rule = SearchRule()
        rule.bookList = "class.item"
        rule.name = "tag.a@text"
        rule.bookUrl = "tag.a@href"

        var source = BookSource(bookSourceUrl: "https://example.com", bookSourceName: "data源")
        source.searchUrl = dataURL
        source.ruleSearch = rule

        let books = try await BookSearchService().search(source: source, key: "斗破")
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "斗破苍穹")
        XCTAssertEqual(books.first?.bookUrl, "https://example.com/book/1")
    }

    /// 并发窗口（10 个）不能漏源：源数超过窗口时每个源都要出一次结果。
    func testMultiSourceSearchCoversEverySourceBeyondWindow() async {
        let html = #"<div class="item"><a href="https://example.com/book/1">斗破苍穹</a></div>"#
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let dataURL = "data:text/html,\(encoded)"

        var rule = SearchRule()
        rule.bookList = "class.item"
        rule.name = "tag.a@text"
        rule.bookUrl = "tag.a@href"

        let sources = (0..<30).map { index -> BookSource in
            var source = BookSource(
                bookSourceUrl: "https://example.com/\(index)",
                bookSourceName: "源\(index)"
            )
            source.searchUrl = dataURL
            source.ruleSearch = rule
            return source
        }

        var outcomes: [SearchSourceOutcome] = []
        for await outcome in BookSearchService().searchMultiSourcesDetailed(sources: sources, key: "斗破") {
            outcomes.append(outcome)
        }

        XCTAssertEqual(outcomes.count, sources.count)
        XCTAssertEqual(Set(outcomes.map { $0.source.bookSourceUrl }).count, sources.count)
        XCTAssertTrue(outcomes.allSatisfy { $0.books.count == 1 })
    }
}
