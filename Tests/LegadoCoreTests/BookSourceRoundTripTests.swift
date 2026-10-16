import XCTest
@testable import LegadoCore

final class BookSourceRoundTripTests: XCTestCase {

    /// 书源导入后 encode 进本地存储，下次启动 decode 出来。
    /// 这一进一出丢了 jsLib，规则脚本会在 `host` / `getArguments` 上抛错。
    func testJsLibSurvivesEncodeDecodeRoundTrip() throws {
        let original = BookSource(
            bookSourceUrl: "示例标识",
            bookSourceName: "示例书源",
            exploreUrl: "<js>host[0]</js>",
            jsLib: "var host = ['https://v5.langge.uk'];"
        )

        let encoded = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([BookSource].self, from: encoded)

        XCTAssertEqual(decoded.first?.jsLib, "var host = ['https://v5.langge.uk'];",
                       "encode/decode 把 jsLib 弄丢了，脚本必然 ReferenceError")
        XCTAssertEqual(decoded.first?.exploreUrl, "<js>host[0]</js>")
    }
}
