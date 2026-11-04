import XCTest
@testable import LegadoCore

/// 书源兼容 P1：正文分页规划、`subContent` 兜底、常用 Java JS 桥。
final class ContentCompatibilityTests: XCTestCase {

    // MARK: 分页规划

    func testNextURLsSkipsVisitedAndDuplicates() {
        let urls = ContentPagination.nextURLs(
            candidates: [
                "https://example.com/2",
                " https://example.com/2 ",
                "https://example.com/1",
                "https://example.com/3"
            ],
            visited: ["https://example.com/1"],
            fetchedCount: 1
        )

        XCTAssertEqual(urls, ["https://example.com/2", "https://example.com/3"])
    }

    func testNextURLsRespectsPageLimit() {
        let candidates = (1...20).map { "https://example.com/\($0)" }

        let urls = ContentPagination.nextURLs(
            candidates: candidates,
            visited: ["https://example.com/0"],
            fetchedCount: 1
        )

        XCTAssertEqual(urls.count, 9)
        XCTAssertEqual(urls.first, "https://example.com/1")
        XCTAssertEqual(urls.last, "https://example.com/9")
    }

    func testNextURLsStopsWhenPageLimitReached() {
        XCTAssertTrue(
            ContentPagination.nextURLs(
                candidates: ["https://example.com/next"],
                visited: [],
                fetchedCount: ContentPagination.pageLimit
            ).isEmpty
        )
    }

    func testNextURLsStopsOnEmptyCandidates() {
        XCTAssertTrue(
            ContentPagination.nextURLs(candidates: [], visited: [], fetchedCount: 1).isEmpty
        )
        XCTAssertTrue(
            ContentPagination.nextURLs(
                candidates: ["   "],
                visited: [],
                fetchedCount: 1
            ).isEmpty
        )
    }

    func testPaginationDeadline() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ContentPagination.remaining(now.addingTimeInterval(5), now: now), 5)
        XCTAssertEqual(ContentPagination.remaining(now.addingTimeInterval(-5), now: now), 0)
    }

    // MARK: subContent 兜底

    func testContentRuleFallsBackToSubContent() {
        let analyzer = RuleAnalyzer(
            content: "<div id=\"main\"></div><div class=\"fallback\">备用正文</div>",
            baseUrl: "https://example.com/chapter/1"
        )
        var rule = ContentRule()
        rule.content = "#main"
        rule.subContent = ".fallback"

        XCTAssertEqual(ContentRuleExtractor.text(from: analyzer, rule: rule), "备用正文")
    }

    func testContentRulePrefersPrimaryContent() {
        let analyzer = RuleAnalyzer(
            content: "<div id=\"main\">主正文</div><div class=\"fallback\">备用正文</div>",
            baseUrl: "https://example.com/chapter/1"
        )
        var rule = ContentRule()
        rule.content = "#main"
        rule.subContent = ".fallback"

        XCTAssertEqual(ContentRuleExtractor.text(from: analyzer, rule: rule), "主正文")
    }

    func testContentRuleReturnsEmptyWhenBothMiss() {
        let analyzer = RuleAnalyzer(
            content: "<div id=\"other\">别的</div>",
            baseUrl: "https://example.com/chapter/1"
        )
        var rule = ContentRule()
        rule.content = "#main"
        rule.subContent = ".fallback"

        XCTAssertEqual(ContentRuleExtractor.text(from: analyzer, rule: rule), "")
    }

    // MARK: Java JS 桥

    func testEncodeURIKeepsReservedCharacters() {
        let engine = JSEngine()
        let value = engine.eval(script: "java.encodeURI('a b/中文?x=1&y=2')") as? String

        XCTAssertEqual(value, "a%20b/%E4%B8%AD%E6%96%87?x=1&y=2")
        XCTAssertNil(engine.lastError)
    }

    func testTimeFormatUTCUsesUTCAndExistingMillisecondRule() {
        let engine = JSEngine()
        let value = engine.eval(
            script: "java.timeFormatUTC(86400000, 'yyyy-MM-dd HH:mm:ss')"
        ) as? String

        XCTAssertEqual(value, "1970-01-02 00:00:00")
        XCTAssertNil(engine.lastError)
    }

    func testMessageDigestUpdateThenDigest() {
        let engine = JSEngine()
        let script = """
        var md = java.security.MessageDigest.getInstance('MD5');
        md.update(java.lang.String('abc').getBytes());
        md.digest().map(function(b){ var h = b.toString(16); return h.length < 2 ? '0' + h : h; }).join('')
        """
        let value = engine.eval(script: script) as? String

        XCTAssertEqual(value, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertNil(engine.lastError)
    }

    func testMessageDigestOneShotForSHA1AndSHA256() {
        let engine = JSEngine()
        let script = """
        var hex = function(bytes){ return bytes.map(function(b){ var h = b.toString(16); return h.length < 2 ? '0' + h : h; }).join(''); };
        hex(java.security.MessageDigest.getInstance('SHA-1').digest([97, 98, 99])) + '|' +
        hex(java.security.MessageDigest.getInstance('SHA-256').digest([97, 98, 99]))
        """
        let value = engine.eval(script: script) as? String

        XCTAssertEqual(
            value,
            "a9993e364706816aba3e25717850c26c9cd0d89d|ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertNil(engine.lastError)
    }

    func testAjaxAllHandlesEmptyArrayWithoutReferenceError() {
        let engine = JSEngine()
        let count = engine.eval(script: "java.ajaxAll([]).length") as? NSNumber

        XCTAssertEqual(count?.intValue, 0)
        XCTAssertNil(engine.lastError)
    }
}
