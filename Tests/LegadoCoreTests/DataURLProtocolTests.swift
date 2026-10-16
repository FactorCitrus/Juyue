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
