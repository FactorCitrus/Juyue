import XCTest
@testable import LegadoCore

/// 聚合源的 bookUrl 是 `data:;base64,<载荷>,<ext>`。宿主该把载荷当 result 交给
/// ruleBookInfo.init，由脚本自己发请求并把响应体返回。这里确认脚本实际返回什么。
final class RealSourceDataURLProbe: XCTestCase {

    private func decodeDataURL(_ raw: String) -> (payload: String, ext: String)? {
        guard raw.hasPrefix("data:"), let b64 = raw.range(of: "base64,") else { return nil }
        let rest = String(raw[b64.upperBound...])
        let payload = String(rest.prefix(while: { $0 != "," }))
        let tail = String(rest.dropFirst(payload.count).dropFirst())
        guard let data = Data(base64Encoded: payload),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return (text, tail.removingPercentEncoding ?? tail)
    }

    func testDataURLDetailFlow() async throws {
        let path = ProcessInfo.processInfo.environment["BS_AGG"] ?? ""
        guard !path.isEmpty else { throw XCTSkip("no BS_AGG") }
        let source = try XCTUnwrap(try JSONDecoder()
            .decode([BookSource].self, from: Data(contentsOf: URL(fileURLWithPath: path))).first)

        let books = (try? await BookSearchService.shared.search(source: source, key: "凡人修仙传", page: 1)) ?? []
        guard let first = books.first else { print("没有搜索结果"); return }
        print("bookUrl:", first.bookUrl.prefix(80), "...")
        guard let (payload, ext) = decodeDataURL(first.bookUrl) else { print("不是 data: 包"); return }
        print("载荷:", payload)
        print("ext:", ext)

        let engine = JSEngine(bookSource: source, baseUrl: first.bookUrl)

        if let initRule = source.ruleBookInfo?.initRule {
            let out = engine.eval(script: JSEngine.unwrapJsScript(initRule), result: payload)
            print("init 返回类型:", type(of: out as Any), "长度:", (out as? String)?.count ?? -1)
            print("init 返回前 200:", String(describing: out).prefix(200))
            print("init lastError:", engine.lastError ?? "(无)")
        } else {
            print("没有 ruleBookInfo.init")
        }

        if let tocScript = source.ruleToc?.chapterList {
            let tocOut = engine.eval(script: JSEngine.unwrapJsScript(tocScript), result: payload)
            print("chapterList 返回类型:", type(of: tocOut as Any))
            print("chapterList 返回前 300:", String(describing: tocOut).prefix(300))
            print("chapterList lastError:", engine.lastError ?? "(无)")
        }
    }
}
