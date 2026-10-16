import XCTest
@testable import LegadoCore

final class ScriptVariableSinkTests: XCTestCase {

    /// `source.setVariable` 要把新值交回宿主。
    ///
    /// 聚合源的 `setArgument` 就是「读 variable → 改一项 → 写回 variable」，切服务器、
    /// 书源设置中心结果、token 全走它。宿主不落盘的话，每次点击都从旧值重算，
    /// 服务器永远停在同一台。
    func testSetVariableReportsToSink() throws {
        var received: [(url: String, variable: String)] = []
        JSEngine.variableSink = { url, variable in received.append((url, variable)) }
        defer { JSEngine.variableSink = nil }

        var source = BookSource(bookSourceUrl: "https://example.invalid/book", bookSourceName: "示例")
        source.variable = #"{"server":"https://a.example"}"#

        let engine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
        _ = engine.eval(script: #"source.setVariable('{"server":"https://b.example"}')"#)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.url, "https://example.invalid/book")
        XCTAssertEqual(received.first?.variable, #"{"server":"https://b.example"}"#)
    }

    /// 落盘之后，下一次点击新建的引擎要读到新值，切换才会往下走而不是原地打转。
    func testVariableRoundTripAcrossEngines() throws {
        var stored = #"{"server":"https://a.example"}"#
        JSEngine.variableSink = { _, variable in stored = variable }
        defer { JSEngine.variableSink = nil }

        var source = BookSource(bookSourceUrl: "https://example.invalid/book", bookSourceName: "示例")
        source.variable = stored

        let first = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
        _ = first.eval(script: #"source.setVariable('{"server":"https://b.example"}')"#)

        source.variable = stored
        let second = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
        XCTAssertEqual(second.eval(script: "source.getVariable()") as? String, #"{"server":"https://b.example"}"#)
    }
}
