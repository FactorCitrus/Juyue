import XCTest
@testable import LegadoCore

final class LogRedactionTests: XCTestCase {

    // MARK: - 脱敏只换值，不丢行

    /// 旧实现整行丢弃：源名里带 token 的书源，日志一条都留不下来。
    func testSourceNameContainingTokenKeepsLine() {
        let line = "[Search] [Token小说] HTTP 200，收到 1234 字节"
        XCTAssertEqual(LogRedaction.redact(line), line)
    }

    func testRedactsSensitiveQueryValues() {
        let url = "https://a.example.com/search?key=凡人修仙传&token=abc123&page=2&sign=deadbeef"
        let out = LogRedaction.redact(url)
        XCTAssertFalse(out.contains("abc123"))
        XCTAssertFalse(out.contains("deadbeef"))
        XCTAssertTrue(out.contains("token=<redacted>"))
        XCTAssertTrue(out.contains("page=2"))
    }

    /// 不敏感的键不碰，否则诊断 URL 就废了，看不出请求的是哪一页。
    func testKeepsNonSensitiveQueryValues() {
        let url = "https://a.example.com/api/book?id=12345&page=3"
        XCTAssertEqual(LogRedaction.redact(url), url)
    }

    func testRedactsCookieHeaderAndBearer() {
        let out = LogRedaction.redact("Cookie: uid=42; sid=abcdef\nAuthorization: Bearer abcdefghijkl")
        XCTAssertFalse(out.contains("42"))
        XCTAssertFalse(out.contains("abcdefghijkl"))
    }

    func testRedactsEmailPhoneAndAbsolutePath() {
        let out = LogRedaction.redact("联系人 13812345678 / a.b@example.com / /Users/someone/Library/x.log")
        XCTAssertEqual(out, "联系人 <phone> / <email> / <path>")
    }

    func testPreviewIsRedactedAndClipped() {
        let html = String(repeating: "手机13812345678 ", count: 40)
        let preview = DiagnosticPreview.make(html, limit: 60)
        XCTAssertFalse(preview.contains("13812345678"))
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    // MARK: - 失败归因

    func testFailureClassification() {
        XCTAssertEqual(DiagnosticFailure.classify(URLError(.timedOut)), "timeout")
        XCTAssertEqual(DiagnosticFailure.classify(URLError(.cannotFindHost)), "dns")
        XCTAssertEqual(DiagnosticFailure.classify(URLError(.secureConnectionFailed)), "tls")
        XCTAssertEqual(DiagnosticFailure.classify(URLError(.notConnectedToInternet)), "offline")
        XCTAssertEqual(DiagnosticFailure.classify(URLError(.badServerResponse)), "network(-1011)")
    }

    func testHeadersSummaryOnlyReportsPresence() {
        let summary = DiagnosticFailure.summarize([
            "User-Agent": "x",
            "Referer": "https://a.example.com/secret?token=1",
        ])
        XCTAssertEqual(summary, "ua=1 referer=1 cookie=0 accept=0")
        XCTAssertFalse(summary.contains("secret"))
    }

    // MARK: - 环形缓冲

    func testHubKeepsOnlyCapacityItems() {
        let hub = DiagnosticHub()
        hub.capacity = 200
        hub.persistsToDisk = false
        for index in 0..<250 {
            hub.record(SourceRequestDiagnostic(step: "搜索", url: "https://a.example.com/\(index)"))
        }
        let snapshot = hub.snapshot()
        XCTAssertEqual(snapshot.count, 200)
        XCTAssertTrue(snapshot.first?.url.hasSuffix("/50") ?? false)
        XCTAssertTrue(snapshot.last?.url.hasSuffix("/249") ?? false)
    }

    /// 旧版本存在 UserDefaults 里的记录没有新字段，必须还能解码。
    func testLegacyDiagnosticJSONStillDecodes() throws {
        let legacy = """
        {"id":"2F0E7A32-1B1E-4C39-9A5B-0E0D6C3D7A11","step":"搜索",
         "url":"https://a.example.com/x","statusCode":200,"elapsedMs":120,
         "responseBytes":4096,"responsePreview":"abc","ruleHits":10,"note":"解析出 10 个候选"}
        """
        let decoded = try JSONDecoder().decode(SourceRequestDiagnostic.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.step, "搜索")
        XCTAssertEqual(decoded.statusCode, 200)
        XCTAssertEqual(decoded.sourceName, "")
        XCTAssertEqual(decoded.ruleEvalMs, 0)
        XCTAssertEqual(decoded.headersSummary, "")
        XCTAssertEqual(decoded.failureKind, "")
    }

    /// 新结构往返一次不丢字段。
    func testRoundTripKeepsNewFields() throws {
        let original = SourceRequestDiagnostic(
            step: "正文",
            sourceName: "某书源",
            url: "https://a.example.com/c/1?token=leak",
            statusCode: 200,
            elapsedMs: 88,
            responseBytes: 2048,
            responsePreview: "正文",
            ruleHits: 1,
            ruleEvalMs: 12,
            headersSummary: "ua=1 referer=0 cookie=0 accept=1",
            failureKind: "",
            note: "规则命中 900 字"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SourceRequestDiagnostic.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.url.contains("leak"))
    }
}
