import XCTest
@testable import LegadoCore

/// 聚合源接口常把数据包在 `{"code":0,"data":{...}}` 里，规则却按 `$.field` 写。
/// 根路径取不到时要能往 data / result 里再找一层。
final class RuleAnalyzerContainerTests: XCTestCase {
    func testFieldFallsBackToDataContainer() {
        let json = #"{"code":0,"msg":"","data":{"book_name":"x","thumb_url":"https://e.com/a.jpg"}}"#
        let analyzer = RuleAnalyzer(content: json, baseUrl: "https://e.com")
        XCTAssertEqual(analyzer.getString("$.thumb_url"), "https://e.com/a.jpg")
        XCTAssertEqual(analyzer.getString("$.book_name"), "x")
    }

    func testExplicitDataPathStillWins() {
        let json = #"{"code":0,"data":{"thumb_url":"inner"},"thumb_url":"outer"}"#
        let analyzer = RuleAnalyzer(content: json, baseUrl: "https://e.com")
        XCTAssertEqual(analyzer.getString("$.data.thumb_url"), "inner")
        XCTAssertEqual(analyzer.getString("$.thumb_url"), "outer")
    }
}
