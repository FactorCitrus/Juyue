import XCTest
@testable import JuyueCore

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

    private var tabs: [String: Any] {
        [
            "search_tabs": [
                ["title": "推荐", "order": 1, "vip": false, "data": [["name": "a"], ["name": "b"]]],
                ["title": "短剧", "order": 2, "vip": false, "data": [["name": "c"]]],
                ["title": "a.b", "order": 5, "vip": true, "data": [["name": "d"]]],
                ["title": "末尾", "order": 9, "vip": false]
            ]
        ]
    }

    func testFilterEqualsKeepsQuotedDotIntact() {
        let hit = JSONPath.evaluate(path: "$.search_tabs[?(@.title == '短剧')].data[*].name", json: tabs) as? [String]
        XCTAssertEqual(hit, ["c"])
        let dotted = JSONPath.evaluate(path: "$.search_tabs[?(@.title == 'a.b')].title", json: tabs) as? [String]
        XCTAssertEqual(dotted, ["a.b"])
        let root = JSONPath.evaluate(path: "$.search_tabs[?(@.title == '短剧')]", json: tabs) as? [Any]
        XCTAssertEqual(root?.count, 1)
    }

    func testFilterNotEquals() {
        let titles = JSONPath.evaluate(path: "$.search_tabs[?(@.title != '短剧')].title", json: tabs) as? [String]
        XCTAssertEqual(titles, ["推荐", "a.b", "末尾"])
    }

    func testFilterNumericComparisons() {
        func titles(_ condition: String) -> [String]? {
            JSONPath.evaluate(path: "$.search_tabs[?(@.order \(condition))].title", json: tabs) as? [String]
        }
        XCTAssertEqual(titles("> 2"), ["a.b", "末尾"])
        XCTAssertEqual(titles("< 2"), ["推荐"])
        XCTAssertEqual(titles(">= 5"), ["a.b", "末尾"])
        XCTAssertEqual(titles("<= 2"), ["推荐", "短剧"])
    }

    func testFilterExistsAndBoolean() {
        let withData = JSONPath.evaluate(path: "$.search_tabs[?(@.data)].title", json: tabs) as? [String]
        XCTAssertEqual(withData, ["推荐", "短剧", "a.b"])
        let vip = JSONPath.evaluate(path: "$.search_tabs[?(@.vip == true)].title", json: tabs) as? [String]
        XCTAssertEqual(vip, ["a.b"])
    }

    func testFilterCompoundConditions() {
        let and = JSONPath.evaluate(path: "$.search_tabs[?(@.order > 2 && @.vip == true)].title", json: tabs) as? [String]
        XCTAssertEqual(and, ["a.b"])
        let or = JSONPath.evaluate(path: "$.search_tabs[?(@.title == '短剧' || @.order < 2)].title", json: tabs) as? [String]
        XCTAssertEqual(or, ["推荐", "短剧"])
    }

    func testFilterNoHitReturnsNil() {
        XCTAssertNil(JSONPath.evaluate(path: "$.search_tabs[?(@.title == '不存在')]", json: tabs))
        XCTAssertNil(JSONPath.evaluate(path: "$.search_tabs[?(@.title == '不存在')].data[*].name", json: tabs))
    }

    func testRecursiveWildcardCollectsEverySubtree() {
        let json: [String: Any] = [
            "first": ["blobs": [["name": "1"]]],
            "second": ["blobs": [["name": "2"]]]
        ]
        let names = JSONPath.evaluate(path: "$..blobs[*].name", json: json) as? [String]
        XCTAssertEqual(Set(names ?? []), ["1", "2"])
    }

    func testElementFallbackRulesTakeFirstNonEmptyCandidate() {
        let json: [String: Any] = [
            "data": ["cell_view": ["cell_data": [Any]()]],
            "search_tabs": [
                ["title": "推荐", "data": [["name": "x"]]] as [String: Any],
                ["title": "短剧", "data": [["name": "a"], ["name": "b"]]] as [String: Any]
            ]
        ]
        let analyzer = RuleAnalyzer(content: json)
        let items = analyzer.getElements("$.data.cell_view.cell_data[*]||$.search_tabs[?(@.title == '短剧')].data[*]")
        XCTAssertEqual(items.count, 2)
    }

    func testJSONItemRulesWithFallbackAndTemplate() {
        let json: [String: Any] = [
            "video_data": [["title": "T1", "video_desc": "简介"]],
            "book_id": "B1"
        ]
        let analyzer = RuleAnalyzer(content: json)
        XCTAssertEqual(analyzer.getString("$.video_data[0].title"), "T1")
        XCTAssertEqual(analyzer.getString("$.video_data[0].series_id||$.book_id"), "B1")

        let item: [String: Any] = ["name": "源A", "id": 12747]
        let row = RuleAnalyzer(content: item)
        XCTAssertEqual(row.getString("{{$.name}}"), "源A")
        XCTAssertEqual(row.getString("https://yuancang.cc/api/v1/sources/{{$.id}}"), "https://yuancang.cc/api/v1/sources/12747")
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
