import XCTest
@testable import LegadoCore

final class SourceMatchRulesTests: XCTestCase {

    private func candidate(_ name: String, author: String = "") -> SearchBook {
        SearchBook(name: name, author: author, bookUrl: "https://example.invalid/\(name)",
                   origin: "x", originName: "x")
    }

    /// 宽松：双向包含（换源老口径）
    func testLooseTitle() {
        let loose = SourceMatchOptions(matchTitle: true, matchAuthor: false, exact: false)
        XCTAssertTrue(SourceMatchRules.matches(candidate("凡人修仙传"), title: "凡人修仙传", author: "", options: loose))
        XCTAssertTrue(SourceMatchRules.matches(candidate("凡人修仙传（完本）"), title: "凡人修仙传", author: "", options: loose))
        XCTAssertTrue(SourceMatchRules.matches(candidate("凡人修仙传"), title: "凡人修仙", author: "", options: loose))
        XCTAssertFalse(SourceMatchRules.matches(candidate("星辰变"), title: "凡人修仙传", author: "", options: loose))
    }

    /// 精确：归一化后完全相等（空格、书名号、引号、英文大小写都不算差异）
    func testExactTitle() {
        let exact = SourceMatchOptions(matchTitle: true, matchAuthor: false, exact: true)
        XCTAssertTrue(SourceMatchRules.matches(candidate("《凡人修仙传》"), title: "凡人修仙传", author: "", options: exact))
        XCTAssertTrue(SourceMatchRules.matches(candidate("凡人 修仙传"), title: "凡人修仙传", author: "", options: exact))
        XCTAssertTrue(SourceMatchRules.matches(candidate("the great gatsby"), title: "The Great Gatsby", author: "", options: exact))
        XCTAssertFalse(SourceMatchRules.matches(candidate("凡人修仙传（完本）"), title: "凡人修仙传", author: "", options: exact))
        XCTAssertFalse(SourceMatchRules.matches(candidate("凡人修仙"), title: "凡人修仙传", author: "", options: exact))
    }

    /// 精确 + 作者
    func testExactAuthor() {
        let exact = SourceMatchOptions(matchTitle: false, matchAuthor: true, exact: true)
        XCTAssertTrue(SourceMatchRules.matches(candidate("任意书名", author: "忘语 "), title: "", author: "忘语", options: exact))
        XCTAssertFalse(SourceMatchRules.matches(candidate("任意书名", author: "忘语著"), title: "", author: "忘语", options: exact))
        // 候选没写作者：不能算中
        XCTAssertFalse(SourceMatchRules.matches(candidate("任意书名"), title: "", author: "忘语", options: exact))
    }

    /// 两个都开是 AND：书名中、作者不中就不算
    func testBothFieldsAreAnd() {
        let both = SourceMatchOptions(matchTitle: true, matchAuthor: true, exact: false)
        XCTAssertTrue(SourceMatchRules.matches(candidate("凡人修仙传", author: "忘语"), title: "凡人修仙传", author: "忘语", options: both))
        XCTAssertFalse(SourceMatchRules.matches(candidate("凡人修仙传", author: "别人"), title: "凡人修仙传", author: "忘语", options: both))
        XCTAssertFalse(SourceMatchRules.matches(candidate("凡人修仙传"), title: "凡人修仙传", author: "忘语", options: both))

        // 只开书名时，作者不参与判定
        let titleOnly = SourceMatchOptions(matchTitle: true, matchAuthor: false, exact: false)
        XCTAssertTrue(SourceMatchRules.matches(candidate("凡人修仙传", author: "别人"), title: "凡人修仙传", author: "忘语", options: titleOnly))
    }

    /// 一个字段都没开：不算命中（界面那边同时会禁用搜索）
    func testNoFieldSelected() {
        let none = SourceMatchOptions(matchTitle: false, matchAuthor: false, exact: false)
        XCTAssertFalse(SourceMatchRules.matches(candidate("凡人修仙传", author: "忘语"), title: "凡人修仙传", author: "忘语", options: none))
    }

    /// 目标串是空的：这个字段废弃，不参与判定
    func testEmptyWantedValue() {
        let titleOnly = SourceMatchOptions(matchTitle: true, matchAuthor: false, exact: true)
        XCTAssertFalse(SourceMatchRules.matches(candidate("凡人修仙传"), title: "", author: "", options: titleOnly))
    }

    /// 搜索页：字段单选，命中任意选中字段就算（OR）；关键词为空就不过滤
    func testSearchFieldMatching() {
        let book = candidate("凡人修仙传", author: "忘语")
        XCTAssertTrue(SourceMatchRules.matchesKeyword(book, keyword: "凡人", field: .title, exact: false))
        XCTAssertFalse(SourceMatchRules.matchesKeyword(book, keyword: "忘语", field: .title, exact: false))
        XCTAssertTrue(SourceMatchRules.matchesKeyword(book, keyword: "忘语", field: .author, exact: false))
        XCTAssertTrue(SourceMatchRules.matchesKeyword(book, keyword: "忘语", field: .either, exact: false))
        XCTAssertTrue(SourceMatchRules.matchesKeyword(book, keyword: "凡人", field: .either, exact: false))
        XCTAssertFalse(SourceMatchRules.matchesKeyword(book, keyword: "星辰变", field: .either, exact: false))

        XCTAssertFalse(SourceMatchRules.matchesKeyword(book, keyword: "凡人", field: .title, exact: true))
        XCTAssertTrue(SourceMatchRules.matchesKeyword(book, keyword: "《凡人修仙传》", field: .title, exact: true))
        XCTAssertTrue(SourceMatchRules.matchesKeyword(book, keyword: "   ", field: .title, exact: false))
    }

    /// 搜索范围：限定源（源名 / 分组名）+ 分组
    func testFilterSources() {
        var wolf = BookSource(bookSourceUrl: "a", bookSourceName: "大灰狼聚合")
        wolf.bookSourceGroup = "聚合"
        var tomato = BookSource(bookSourceUrl: "b", bookSourceName: "番茄小说")
        tomato.bookSourceGroup = "聚合"
        var book69 = BookSource(bookSourceUrl: "c", bookSourceName: "69书吧")
        book69.bookSourceGroup = "常规"
        let all = [wolf, tomato, book69]

        XCTAssertEqual(SourceMatchRules.filterSources(all, nameFilter: "番茄", group: nil).map(\.bookSourceUrl), ["b"])
        // 分组名也算命中
        XCTAssertEqual(SourceMatchRules.filterSources(all, nameFilter: "聚合", group: nil).map(\.bookSourceUrl), ["a", "b"])
        XCTAssertEqual(SourceMatchRules.filterSources(all, nameFilter: "", group: "聚合").map(\.bookSourceUrl), ["a", "b"])
        XCTAssertEqual(SourceMatchRules.filterSources(all, nameFilter: "69", group: "聚合").map(\.bookSourceUrl), [])
        XCTAssertEqual(SourceMatchRules.filterSources(all, nameFilter: "  ", group: nil).count, 3)
    }
}
