import XCTest
@testable import JuyueCore

/// 规则结果进字符串位时的收口：JS 对象不能把 Swift 的字典描述漏到界面上。
final class ScalarTextTests: XCTestCase {

    func testPrimitives() {
        XCTAssertEqual(RuleAnalyzer.scalarText("佛前献花"), "佛前献花")
        XCTAssertEqual(RuleAnalyzer.scalarText(5314880), "5314880")
        XCTAssertEqual(RuleAnalyzer.scalarText(true), "true")
        XCTAssertEqual(RuleAnalyzer.scalarText(false), "false")
        XCTAssertEqual(RuleAnalyzer.scalarText(nil), "")
        XCTAssertEqual(RuleAnalyzer.scalarText(NSNull()), "")
    }

    func testArraysJoinLikeJs() {
        XCTAssertEqual(RuleAnalyzer.scalarText(["a", "b"]), "a,b")
        XCTAssertEqual(RuleAnalyzer.scalarText([1, 2, 3]), "1,2,3")
        XCTAssertEqual(RuleAnalyzer.scalarText([Any]()), "")
    }

    /// 聚合源的 init 脚本偶尔回对象；这里必须是 `[object Object]`，
    /// 不能是 `[AnyHashable("toString"): {}, …]`。
    func testObjectsNeverLeakSwiftDescription() {
        let object: [AnyHashable: Any] = ["toString": [String: Any](), "valueOf": [String: Any]()]
        let text = RuleAnalyzer.scalarText(object)
        XCTAssertEqual(text, "[object Object]")
        XCTAssertFalse(text.contains("AnyHashable"))

        XCTAssertEqual(RuleAnalyzer.scalarText(["book_name": "神秘复苏"]), "[object Object]")
    }

    /// 走完整条规则链：JS 返回对象时，`getString` 也只能拿到 `[object Object]`。
    func testRuleChainWithObjectResult() throws {
        let analyzer = RuleAnalyzer(content: "")
        let rule = "<js>JSON.parse('{\"a\":1}')</js>"
        XCTAssertEqual(analyzer.getString(rule), "[object Object]")
    }
}
