import XCTest
@testable import LegadoCore

final class RealSourceHostProbe: XCTestCase {
    func testRealSourceExposesHost() throws {
        let path = ProcessInfo.processInfo.environment["BS_AGG"] ?? ""
        guard !path.isEmpty else { throw XCTSkip("no BS_AGG") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let source = try XCTUnwrap(try JSONDecoder().decode([BookSource].self, from: data).first)
        let engine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
        print("jsLib 长度:", source.jsLib?.count ?? -1)
        let h = engine.eval(script: "typeof host")
        print("typeof host =", h as? String ?? "(nil)")
        if let e = engine.lastError { print("注入阶段 lastError:", e) }
        print("host[0] =", engine.eval(script: "host[0]") as? String ?? "(nil)")
        if let e = engine.lastError { print("取值阶段 lastError:", e) }
    }
}
