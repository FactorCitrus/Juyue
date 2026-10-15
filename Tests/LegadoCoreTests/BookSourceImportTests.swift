import XCTest
@testable import LegadoCore

/// 导入书源走的是 JSONDecoder().decode([BookSource].self)。
/// 这里拿一份安卓 Legado 实际导出的书源 JSON 钉住解析，防止模型漂移导致「导入失败」。
final class BookSourceImportTests: XCTestCase {
    private let sampleJSON = """
    [
      {
        "bookSourceComment": "",
        "bookSourceGroup": "测试分组",
        "bookSourceName": "示例书源",
        "bookSourceType": 0,
        "bookSourceUrl": "https://example.com",
        "bookUrlPattern": "",
        "customOrder": 0,
        "enabled": true,
        "enabledExplore": true,
        "exploreUrl": "",
        "header": "",
        "lastUpdateTime": 0,
        "loginUrl": "",
        "respondTime": 180000,
        "searchUrl": "https://example.com/search?q={{key}}",
        "weight": 0,
        "ruleBookInfo": {"name": "class.name@text"},
        "ruleContent": {"content": "id.content@html"},
        "ruleExplore": {},
        "ruleSearch": {"bookList": "class.list@li", "name": "tag.a@text"},
        "ruleToc": {"chapterList": "id.list@li"}
      }
    ]
    """

    func testDecodeLegadoExport() throws {
        let data = try XCTUnwrap(sampleJSON.data(using: .utf8))
        let sources = try JSONDecoder().decode([BookSource].self, from: data)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.bookSourceUrl, "https://example.com")
        XCTAssertEqual(sources.first?.bookSourceName, "示例书源")
    }
}
