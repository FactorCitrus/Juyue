import XCTest
@testable import LegadoCore

final class BookSourceSchemeTests: XCTestCase {

    func testClassifyCommonSchemes() {
        XCTAssertEqual(BookSourceSchemeClassifier.classify("https://www.example.com"), .https)
        XCTAssertEqual(BookSourceSchemeClassifier.classify("HTTP://www.example.com"), .http)
        XCTAssertEqual(BookSourceSchemeClassifier.classify("data:;base64,abc"), .data)
        XCTAssertEqual(BookSourceSchemeClassifier.classify("moyue://rapid"), .custom("moyue"))
        XCTAssertEqual(BookSourceSchemeClassifier.classify("MOYUE://rapid"), .custom("moyue"))
    }

    /// 聚合源的 bookSourceUrl 常写成纯标识，不能当成坏源；
    /// 空串/纯空白才是真的无效。
    func testClassifyLabelsAndInvalid() {
        XCTAssertEqual(BookSourceSchemeClassifier.classify("书山聚合"), .identifier)
        XCTAssertEqual(BookSourceSchemeClassifier.classify("光遇聚合"), .identifier)
        XCTAssertEqual(BookSourceSchemeClassifier.classify("番茄，书旗"), .identifier)
        XCTAssertEqual(BookSourceSchemeClassifier.classify(nil), .invalid)
        XCTAssertEqual(BookSourceSchemeClassifier.classify("   "), .invalid)
        XCTAssertEqual(BookSourceSchemeClassifier.classify("不是 网址"), .invalid)
    }

    /// 渲染后的地址可能带 `,{...}` 选项，协议判断只看地址本体。
    func testUnsupportedSchemeDetection() {
        XCTAssertEqual(
            NetworkClient.unsupportedScheme(in: "moyue://rapid/legado/search?key=1"),
            "moyue"
        )
        XCTAssertEqual(
            NetworkClient.unsupportedScheme(in: #"moyue://rapid/legado/search,{"method":"POST"}"#),
            "moyue"
        )
        XCTAssertNil(NetworkClient.unsupportedScheme(in: "https://v1.vossc.com/search"))
        XCTAssertNil(NetworkClient.unsupportedScheme(in: "data:;base64,eyJrZXkiOiIxIn0="))
        XCTAssertNil(NetworkClient.unsupportedScheme(in: "书山聚合"))
    }

    func testParseLegadoUrlRejectsCustomScheme() {
        XCTAssertNil(NetworkClient.parseLegadoUrl("moyue://rapid/legado/search"))
        XCTAssertNil(
            NetworkClient.parseLegadoUrl("/legado/search", baseUrl: "moyue://rapid")
        )

        XCTAssertEqual(
            NetworkClient.parseLegadoUrl("https://example.com/a")?.url.absoluteString,
            "https://example.com/a"
        )
        XCTAssertNotNil(NetworkClient.parseLegadoUrl("data:;base64,eyJrZXkiOiIxIn0="))
    }

    func testReadableUnsupportedMessages() {
        let moyue = BookSourceSchemeClassifier.reason(for: "moyue")
        XCTAssertTrue(moyue.contains("moyue"))
        XCTAssertTrue(moyue.contains("iOS 暂不支持"))
        XCTAssertTrue(moyue.contains("墨阅"))

        let generic = BookSourceSchemeClassifier.reason(for: "foo")
        XCTAssertEqual(generic, "该源使用 foo 协议，iOS 暂不支持")

        let error = UnsupportedBookSourceSchemeError(scheme: "moyue", sourceName: "墨阅聚合")
        XCTAssertEqual(error.errorDescription, "「墨阅聚合」" + moyue)
    }

    func testSearchFailureMapsUnsupportedScheme() {
        let error = UnsupportedBookSourceSchemeError(scheme: "moyue", sourceName: "墨阅聚合")
        let failure = SearchSourceFailure.from(error: error)
        XCTAssertEqual(failure, .unsupportedScheme("moyue"))
        XCTAssertEqual(failure.message, BookSourceSchemeClassifier.reason(for: "moyue"))
        XCTAssertEqual(DiagnosticFailure.classify(error), "scheme(moyue)")
    }

    func testBadgeOnlyForCustomSchemes() {
        var source = BookSource(bookSourceUrl: "moyue://rapid", bookSourceName: "墨阅聚合")
        XCTAssertEqual(BookSourceSchemeClassifier.unsupportedBadge(for: source), "moyue · iOS 不支持")

        source.bookSourceUrl = "书山聚合"
        XCTAssertNil(BookSourceSchemeClassifier.unsupportedBadge(for: source))

        source.bookSourceUrl = "https://example.com"
        XCTAssertNil(BookSourceSchemeClassifier.unsupportedBadge(for: source))
    }

    /// 换源路径要拿到具体原因，而不是笼统的「请求地址无法解析」。
    func testSearchDetailedReportsUnsupportedScheme() async {
        var source = BookSource(bookSourceUrl: "moyue://rapid", bookSourceName: "墨阅聚合")
        source.searchUrl = "moyue://rapid/legado/search?key={{key}}"
        source.ruleSearch = SearchRule()

        do {
            _ = try await BookSearchService().searchDetailed(source: source, key: "斗破苍穹")
            XCTFail("moyue 协议不该被当成可请求地址")
        } catch let failure as SearchRequestFailure {
            XCTAssertEqual(failure.failure, .unsupportedScheme("moyue"))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }
}
