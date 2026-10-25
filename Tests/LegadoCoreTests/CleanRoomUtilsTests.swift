import XCTest
@testable import LegadoCore

/// 重写工具类的行为锁：只断言公开行为，不依赖内部结构。
final class CleanRoomUtilsTests: XCTestCase {

    func testMD5MatchesKnownVectors() {
        XCTAssertEqual(CryptoUtils.md5(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(CryptoUtils.md5("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(CryptoUtils.md5("橘阅").count, 32)
    }

    func testBase64RoundTripAndTrimming() {
        let text = "第1章 测试"
        let encoded = CryptoUtils.base64Encode(text)
        XCTAssertEqual(CryptoUtils.base64Decode(encoded), text)
        XCTAssertEqual(CryptoUtils.base64Decode(" " + encoded + "\n"), text)
        XCTAssertEqual(CryptoUtils.base64Decode("!!!not-base64!!!"), "")
    }

    private var sample: [String: Any] {
        [
            "store": [
                "name": "橘阅",
                "book": [
                    ["title": "A", "price": 8],
                    ["title": "B", "price": 12]
                ]
            ],
            "deep": ["one": ["two": ["needle": 42]]]
        ]
    }

    func testKeyIndexAndNegativeIndex() {
        XCTAssertEqual(JSONPath.evaluate(path: "$.store.name", json: sample) as? String, "橘阅")
        XCTAssertEqual(JSONPath.evaluate(path: "$.store.book[0].title", json: sample) as? String, "A")
        XCTAssertEqual(JSONPath.evaluate(path: "$.store.book[-1].title", json: sample) as? String, "B")
        XCTAssertEqual(JSONPath.evaluate(path: "store.book[1].price", json: sample) as? Int, 12)
    }

    func testWildcardFlattens() {
        let titles = JSONPath.evaluate(path: "$.store.book[*].title", json: sample) as? [String]
        XCTAssertEqual(titles, ["A", "B"])
    }

    func testRecursiveDescent() {
        XCTAssertEqual(JSONPath.evaluate(path: "$..needle", json: sample) as? Int, 42)
        XCTAssertNil(JSONPath.evaluate(path: "$..missing", json: sample))
    }

    func testEmptyPathReturnsRootAndMissesReturnNil() {
        XCTAssertNotNil(JSONPath.evaluate(path: "$", json: sample) as? [String: Any])
        XCTAssertNil(JSONPath.evaluate(path: "$.store.missing", json: sample))
        XCTAssertNil(JSONPath.evaluate(path: "$.store.book[9]", json: sample))
        XCTAssertNil(JSONPath.evaluate(path: "$.store.name[0]", json: sample))
    }

    func testSliceAndRecursiveWithBrackets() {
        let sliced = JSONPath.evaluate(path: "$.store.book[:2]", json: sample) as? [Any]
        XCTAssertEqual(sliced?.count, 2)
        let last = JSONPath.evaluate(path: "$.store.book[-1:]", json: sample) as? [Any]
        XCTAssertEqual(last?.count, 1)
        let titles = JSONPath.evaluate(path: "$..book[*].title", json: sample) as? [String]
        XCTAssertEqual(titles, ["A", "B"])
        XCTAssertNil(JSONPath.evaluate(path: "$.store.book[1:2:3]", json: sample))
    }

    private func types(_ rule: String) -> [RuleStep.StepType] {
        RuleTokenizer.parse(rule).map(\.type)
    }

    func testEmptyRule() {
        XCTAssertEqual(RuleTokenizer.parse("   "), [])
    }

    func testAttributeAndLegacyPrefix() {
        XCTAssertEqual(types("id.list@text"), [.css("#list"), .attribute("text")])
        XCTAssertEqual(types("class.row@html"), [.css(".row"), .attribute("html")])
        XCTAssertEqual(types("tag.div"), [.css("div")])
    }

    func testXPathKeepsPredicateAtAndSplitsOnlyTailAttribute() {
        XCTAssertEqual(types("//div[@id='x']"), [.xpath("//div[@id='x']")])
        XCTAssertEqual(
            types("//div[@id='x']/a@href"),
            [.xpath("//div[@id='x']/a"), .attribute("href")]
        )
    }

    func testJSONPathRoot() {
        XCTAssertEqual(
            types("$.data.list[*]@text"),
            [.jsonPath("$.data.list[*]"), .attribute("text")]
        )
    }

    func testJavaScriptAndRegexOrdering() {
        XCTAssertEqual(
            types("div.content@js:java.log('x')##<br>##|"),
            [.css("div.content"), .js("java.log('x')"), .regex(pattern: "<br>", replacement: "|")]
        )
        XCTAssertEqual(types("tag.p<js>1+1</js>"), [.css("p"), .js("1+1")])
    }

    /// `##` 的分段先于脚本识别：写在替换段里的 `@js:` 属于替换文本，不是脚本。
    func testJavaScriptAfterRegexMarkerStaysText() {
        XCTAssertEqual(
            types("div##<br>##\n@js:x"),
            [.css("div"), .regex(pattern: "<br>", replacement: "\n@js:x")]
        )
    }

    func testSecondarySelectorBecomesCSS() {
        XCTAssertEqual(
            types("div.list@class.item@text"),
            [.css("div.list"), .css(".item"), .attribute("text")]
        )
    }
}
