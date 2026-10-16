import XCTest
@testable import LegadoCore

final class RealSourceHostProbe: XCTestCase {

    /// jsLib 单独注入一次到底会不会报错，以及再注一次会不会报重复声明。
    /// 规则脚本用块级作用域包一层，能不能既保住返回值又允许重复执行。
    func testBlockScopedRuleScript() throws {
        let script = """
        let sources = '番茄';
        let book_id = 42;
        `${sources}-${book_id}`
        """
        let wrapped = "{ \(script)\n }"

        let engine = JSEngine(bookSource: nil, baseUrl: "https://example.invalid")
        print("直接跑第一次:", String(describing: engine.eval(script: script) ?? "(nil)"))
        print("直接跑第二次:", String(describing: engine.eval(script: script) ?? "(nil)"), "错误:", engine.lastError ?? "(无)")

        let engine2 = JSEngine(bookSource: nil, baseUrl: "https://example.invalid")
        print("包裹第一次:", String(describing: engine2.eval(script: wrapped) ?? "(nil)"))
        print("包裹第二次:", String(describing: engine2.eval(script: wrapped) ?? "(nil)"), "错误:", engine2.lastError ?? "(无)")
        print("变量有没有漏到全局:", engine2.eval(script: "typeof sources") as? String ?? "(nil)")
    }

    /// 搜索路径会不会刷 duplicate variable。
    func testSearchDoesNotSpamDuplicateVariable() async throws {
        let path = ProcessInfo.processInfo.environment["BS_AGG"] ?? ""
        guard !path.isEmpty else { throw XCTSkip("no BS_AGG") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let source = try XCTUnwrap(try JSONDecoder().decode([BookSource].self, from: data).first)
        let books = (try? await BookSearchService.shared.search(source: source, key: "凡人修仙传", page: 1)) ?? []
        print("搜索结果:", books.count, "条")
    }

    func testJsLibInjectionTwice() throws {
        let path = ProcessInfo.processInfo.environment["BS_AGG"] ?? ""
        guard !path.isEmpty else { throw XCTSkip("no BS_AGG") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let source = try XCTUnwrap(try JSONDecoder().decode([BookSource].self, from: data).first)

        let engine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
        print("注入一次后 lastError:", engine.lastError ?? "(nil)")

        // 同一个上下文里再注一次，看报什么
        _ = engine.eval(script: JSEngine.unwrapJsScript(source.jsLib ?? ""))
        print("注入两次后 lastError:", engine.lastError ?? "(nil)")

        // 关键值能不能拿到
        print("typeof host:", engine.eval(script: "typeof host") as? String ?? "(nil)")
        print("host[0]:", engine.eval(script: "host[0]") as? String ?? "(nil)")
    }

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
