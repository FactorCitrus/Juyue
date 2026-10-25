import XCTest
@testable import LegadoCore

final class BookSourceGateTests: XCTestCase {
    private func makeSources() -> [BookSource] {
        [BookSource(bookSourceUrl: "https://example.test/s.json", bookSourceName: "测试源")]
    }

    /// 商店包：任何来源的书源都不进内存（导入、WebDAV 恢复、设置回灌共用这一闸）。
    func testStoreEditionRefusesSources() {
        XCTAssertNil(BookSourceGate.admitted(makeSources(), appStore: true))
        XCTAssertNil(BookSourceGate.admitted([], appStore: true))
        XCTAssertNil(BookSourceGate.admitted(nil, appStore: true))
    }

    /// 侧载包：原样放行，不许多一层拷贝或过滤。
    func testSideloadEditionPassesThrough() {
        let admitted = BookSourceGate.admitted(makeSources(), appStore: false)
        XCTAssertEqual(admitted?.count, 1)
        XCTAssertEqual(admitted?.first?.bookSourceUrl, "https://example.test/s.json")
        XCTAssertNil(BookSourceGate.admitted(nil, appStore: false))
    }
}
