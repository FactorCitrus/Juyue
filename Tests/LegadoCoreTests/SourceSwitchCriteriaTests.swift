import XCTest
@testable import LegadoCore

/// 暂停后继续：只有关键词或限定源变了才重搜；匹配开关只过滤展示。
final class SourceSwitchCriteriaTests: XCTestCase {

    private let sources: Set<String> = ["a", "b"]

    func testSameCriteriaKeepsResults() {
        let previous = SourceSwitchCriteria(keyword: "凡人修仙传", sourceUrls: sources)
        let current = SourceSwitchCriteria(keyword: "凡人修仙传", sourceUrls: sources)
        XCTAssertFalse(SourceSwitchCriteria.requiresRestart(previous: previous, current: current))
    }

    func testKeywordChangeRequiresRestart() {
        let previous = SourceSwitchCriteria(keyword: "凡人修仙传", sourceUrls: sources)
        let current = SourceSwitchCriteria(keyword: "星辰变", sourceUrls: sources)
        XCTAssertTrue(SourceSwitchCriteria.requiresRestart(previous: previous, current: current))
    }

    func testSourceSelectionChangeRequiresRestart() {
        let previous = SourceSwitchCriteria(keyword: "凡人修仙传", sourceUrls: sources)
        let current = SourceSwitchCriteria(keyword: "凡人修仙传", sourceUrls: ["a"])
        XCTAssertTrue(SourceSwitchCriteria.requiresRestart(previous: previous, current: current))
    }

    /// 两次比较的对象只装请求条件，匹配开关不在其中——改开关不触发重搜。
    func testMatchTogglesAreNotPartOfCriteria() {
        let before = SourceSwitchCriteria(keyword: "凡人修仙传", sourceUrls: sources)
        let optionsBefore = SourceMatchOptions(matchTitle: true, matchAuthor: false, exact: false)
        let optionsAfter = SourceMatchOptions(matchTitle: true, matchAuthor: true, exact: true)
        XCTAssertNotEqual(optionsBefore, optionsAfter)
        XCTAssertFalse(SourceSwitchCriteria.requiresRestart(previous: before, current: before))
    }
}
