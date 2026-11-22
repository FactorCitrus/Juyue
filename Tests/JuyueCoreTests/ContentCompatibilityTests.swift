import XCTest
@testable import JuyueCore

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

    // MARK: JSON 响应的 result 绑定

    func testJSONContentStillSupportsPropertyAccessInJS() {
        let analyzer = RuleAnalyzer(content: #"{"titleZh":"宙斯","titleJp":"ゼウス"}"#)

        XCTAssertEqual(analyzer.getString("<js>result.titleZh</js>"), "宙斯")
    }

    func testJSONContentCoercesBackToRawTextForStringScripts() {
        // 番茄聚合正文：先 hexDecodeToString(result)，非十六进制时原样返回再 JSON.parse。
        let json = #"{"book_id":"123","content":"正文"}"#
        let analyzer = RuleAnalyzer(content: json)

        XCTAssertEqual(
            analyzer.getString(#"<js>String(java.hexDecodeToString(result))</js>"#),
            json
        )
        XCTAssertEqual(
            analyzer.getString(#"<js>JSON.parse(result).content</js>"#),
            "正文"
        )
    }

    // MARK: 段评标记解析

    func testReviewCommentMarkersTolerateStrippedSeparators() {
        // 用户替换规则会把 U+001F 当控制字符清掉，标记只剩 count 紧挨 URL。
        let separated = "正文\u{E000}C\u{1F}99\u{1F}https://example.com/para?book_id=1\u{E001}"
        let stripped = "正文\u{E000}C5632https://example.com/para?book_id=1\u{E001}"

        for text in [separated, stripped] {
            let marker = ReviewMarkerParser.comments(in: text).first
            XCTAssertEqual(marker?.url, "https://example.com/para?book_id=1")
        }
        XCTAssertEqual(ReviewMarkerParser.comments(in: stripped).first?.count, 5632)
        XCTAssertEqual(ReviewMarkerParser.comments(in: separated).first?.count, 99)
    }

    func testReviewMarkerURLDecodesHTMLEntities() {
        let text = "正文\u{E000}C\u{1F}12\u{1F}https://example.com/para?a=1&amp;b=2\u{E001}"

        XCTAssertEqual(
            ReviewMarkerParser.comments(in: text).first?.url,
            "https://example.com/para?a=1&b=2"
        )
    }

    func testResidualReviewMarkersAreRemoved() {
        let text = "前文\u{E000}C5632https://example.com/para\u{E001}后文"

        XCTAssertEqual(
            ReviewMarkerParser.removingResidualMarkers(text),
            "前文后文"
        )
    }

    func testLongResidualMarkerIsRemovedEntirely() {
        // 旧兜底限 2000 字符，带 data: 内嵌图的神评卡会整段漏成 base64。
        let text = "前文\u{E000}G\u{1F}\(String(repeating: "A", count: 3000))\u{E001}后文"

        XCTAssertEqual(ReviewMarkerParser.removingResidualMarkers(text), "前文后文")
    }

    func testResidualMarkerWithoutTerminatorIsRemoved() {
        let text = "前文\u{E000}C5632https://example.com/para"

        XCTAssertEqual(ReviewMarkerParser.removingResidualMarkers(text), "前文")
    }

    func testReplaceRulesSkipReviewMarkers() {
        let marked = "正文\u{E000}C\u{1F}12\u{1F}https://example.com/para?a=1&amp;b=2\u{E001}结尾"
        let stripURL = { (text: String) in
            text.replacingOccurrences(
                of: "(?i)(?:https?://|www\\.)[\\w\\-._~:/?#\\[\\]@!$&'()*+,;=%]+",
                with: "",
                options: .regularExpression
            )
        }

        XCTAssertFalse(stripURL(marked).contains("https://example.com/para"))

        let protected = ReviewMarkerParser.applyingOutsideMarkers(marked, stripURL)
        XCTAssertEqual(protected, marked)
        XCTAssertEqual(
            ReviewMarkerParser.comments(in: protected).first?.url,
            "https://example.com/para?a=1&b=2"
        )
    }

    func testControlCharacterRuleLeavesMarkersIntact() {
        let marked = "正文\u{E000}C\u{1F}99\u{1F}https://example.com/p\u{E001}"
        let protected = ReviewMarkerParser.applyingOutsideMarkers(marked) {
            $0.replacingOccurrences(of: "\\p{Cc}", with: "", options: .regularExpression)
        }

        XCTAssertEqual(protected, marked)
        XCTAssertEqual(ReviewMarkerParser.comments(in: protected).first?.count, 99)
    }

    // MARK: 段落边界与一行多标记

    func testCleanHtmlKeepsDivParagraphBoundaries() {
        let first = "第一段正文\u{E000}C\u{1F}11\u{1F}https://example.com/p1\u{E001}"
        let second = "第二段正文\u{E000}C\u{1F}22\u{1F}https://example.com/p2\u{E001}"
        let html = "<div class=\"rs-native\">\(first)</div><div class=\"rs-native\">\(second)</div>"

        let cleaned = BookContentService.cleanHtml(html)

        XCTAssertTrue(cleaned.contains("\(first)\n\n\(second)"), cleaned)
        XCTAssertEqual(ReviewMarkerParser.comments(in: cleaned).count, 2)
    }

    func testReviewMarkersSplitOneLineIntoSegments() {
        let line = "第一段正文\u{E000}C\u{1F}11\u{1F}https://example.com/p1\u{E001}"
            + "第二段正文\u{E000}C\u{1F}22\u{1F}https://example.com/p2\u{E001}"
            + "第三段正文"

        let segments = ReviewMarkerParser.segments(in: line)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].text, "第一段正文")
        XCTAssertEqual(segments[0].commentCount, 11)
        XCTAssertEqual(segments[0].commentURL, "https://example.com/p1")
        XCTAssertEqual(segments[1].text, "第二段正文")
        XCTAssertEqual(segments[1].commentCount, 22)
        XCTAssertEqual(segments[1].commentURL, "https://example.com/p2")
        XCTAssertEqual(segments[2].text, "第三段正文")
        XCTAssertEqual(segments[2].commentCount, 0)
    }

    func testReviewMarkersSplitChapterAndGodReviewInOneLine() {
        let godText = Data("好看".utf8).base64EncodedString()
        let line = "正文\u{E000}H\u{1F}https://example.com/ch\u{E001}"
            + "中段\u{E000}G\u{1F}\(godText)\u{1F}https://example.com/r1\u{E001}"
            + "尾"

        let segments = ReviewMarkerParser.segments(in: line)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].text, "正文")
        XCTAssertEqual(segments[0].chapterURLs, ["https://example.com/ch"])
        XCTAssertEqual(segments[1].text, "中段")
        XCTAssertEqual(segments[1].godReviews.count, 1)
        XCTAssertEqual(segments[1].godReviews[0].text, "好看")
        XCTAssertEqual(segments[1].godReviews[0].url, "https://example.com/r1")
        XCTAssertEqual(segments[2].text, "尾")
    }
}
