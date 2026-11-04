import XCTest
@testable import LegadoCore

/// 正文规则剩余字段：sourceRegex / imageStyle / imageDecode / callBackJs / payAction。
/// payAction 在 iOS 没有付费入口，测试只确认它不进入正文变换链。
final class ContentRuleSupportTests: XCTestCase {

    // MARK: sourceRegex

    func testSourceRegexMatchesWholeResourceURL() {
        let urls = [
            "https://cdn.example/cover.jpg",
            "https://api.example.com/chapter/content?id=42&token=abc"
        ]

        XCTAssertEqual(
            SourceURLSniffer.firstMatch(
                in: urls,
                pattern: #"https://api\.example\.com/chapter/content\?.*"#
            ),
            "https://api.example.com/chapter/content?id=42&token=abc"
        )
    }

    func testSourceRegexRequiresWholeMatch() {
        XCTAssertNil(
            SourceURLSniffer.firstMatch(
                in: ["https://api.example.com/chapter/content"],
                pattern: "chapter/content"
            )
        )
    }

    func testSourceRegexReturnsNilForInvalidOrEmptyPattern() {
        XCTAssertNil(SourceURLSniffer.firstMatch(in: ["https://example.com/a"], pattern: "("))
        XCTAssertNil(SourceURLSniffer.firstMatch(in: ["https://example.com/a"], pattern: "   "))
        XCTAssertNil(SourceURLSniffer.firstMatch(in: ["https://example.com/a"], pattern: nil))
    }

    func testSourceRegexSkipsEmptyURLs() {
        XCTAssertEqual(
            SourceURLSniffer.firstMatch(
                in: ["   ", "https://example.com/a.js"],
                pattern: #"https://example\.com/.*"#
            ),
            "https://example.com/a.js"
        )
    }

    /// 走完整正文抓取链：无声网页采集到的资源 URL 命中 sourceRegex 后，
    /// 该 URL 作为正文响应体交给 `content` 规则（与安卓 BackstageWebView 一致）。
    func testSourceRegexSniffedURLBecomesContentBody() async throws {
        let previous = HeadlessWebView.shared.loader
        defer { HeadlessWebView.shared.loader = previous }
        HeadlessWebView.shared.loader = { request in
            HeadlessWebResult(
                finalURL: request.url,
                html: "<html><body>页面本身</body></html>",
                javaScriptResult: nil,
                resourceURLs: [
                    "https://static.example.com/app.js",
                    "https://api.example.com/content?id=42"
                ]
            )
        }

        var rule = ContentRule()
        rule.webJs = "document.title"
        rule.sourceRegex = #"https://api\.example\.com/content\?.*"#
        rule.content = "@js:result"
        let source = BookSource(
            bookSourceUrl: "https://example.com",
            bookSourceName: "嗅探源",
            ruleContent: rule
        )
        let bookUrl = "https://example.com/book/\(UUID().uuidString)"
        defer { BookContentService.shared.clearCache(for: bookUrl) }
        let chapter = BookChapter(
            bookUrl: bookUrl,
            url: "https://example.com/chapter/1",
            title: "第1章",
            index: 0
        )

        let text = try await BookContentService.shared.fetchChapterContent(
            chapter: chapter,
            source: source,
            book: nil
        )

        XCTAssertTrue(text.contains("https://api.example.com/content?id=42"), text)
        XCTAssertFalse(text.contains("页面本身"), text)
    }

    // MARK: imageStyle

    func testImageStyleParsingMatchesAndroidValues() {
        XCTAssertEqual(ContentImageStyle(raw: "FULL"), .full)
        XCTAssertEqual(ContentImageStyle(raw: " full "), .full)
        XCTAssertEqual(ContentImageStyle(raw: "TEXT"), .text)
        XCTAssertEqual(ContentImageStyle(raw: "SINGLE"), .single)
        XCTAssertEqual(ContentImageStyle(raw: "LEFT"), .left)
        XCTAssertEqual(ContentImageStyle(raw: "RIGHT"), .right)
    }

    func testImageStyleFallsBackToDefault() {
        XCTAssertEqual(ContentImageStyle(raw: nil), .defaultStyle)
        XCTAssertEqual(ContentImageStyle(raw: ""), .defaultStyle)
        XCTAssertEqual(ContentImageStyle(raw: "0"), .defaultStyle)
        XCTAssertEqual(ContentImageStyle(raw: "unknown"), .defaultStyle)
    }

    func testImageStyleAlignment() {
        XCTAssertEqual(ContentImageStyle(raw: "LEFT").horizontalAlignment, .leading)
        XCTAssertEqual(ContentImageStyle(raw: "RIGHT").horizontalAlignment, .trailing)
        XCTAssertEqual(ContentImageStyle(raw: "FULL").horizontalAlignment, .center)
    }

    // MARK: imageDecode

    func testImageDecodeRunsScriptOnBytes() {
        let input = Data([1, 2, 3])
        let output = ImageDecodeRule.decode(
            input,
            src: "https://cdn.example/a.jpg",
            script: "result.map(function (x) { return 255 - x; })",
            source: nil
        )

        XCTAssertEqual(output, Data([254, 253, 252]))
    }

    func testImageDecodeExposesSrcVariable() {
        let input = Data([7, 8])
        let output = ImageDecodeRule.decode(
            input,
            src: "https://cdn.example/a.jpg",
            script: "src.indexOf('cdn.example') >= 0 ? result : []",
            source: nil
        )

        XCTAssertEqual(output, input)
    }

    func testImageDecodeSupportsJavaByteArrayBridge() {
        let output = ImageDecodeRule.decode(
            Data([9]),
            src: "https://cdn.example/a.jpg",
            script: "java.base64DecodeToByteArray('AQID')",
            source: nil
        )

        XCTAssertEqual(output, Data([1, 2, 3]))
    }

    func testImageDecodeReturnsNilOnScriptError() {
        let output = ImageDecodeRule.decode(
            Data([1]),
            src: "https://cdn.example/a.jpg",
            script: "throw new Error('boom')",
            source: nil
        )

        XCTAssertNil(output)
    }

    func testImageDecodeReturnsNilOnEmptyOrNonByteResult() {
        XCTAssertNil(
            ImageDecodeRule.decode(
                Data([1]), src: "https://cdn.example/a.jpg", script: "[]", source: nil
            )
        )
        XCTAssertNil(
            ImageDecodeRule.decode(
                Data([1]), src: "https://cdn.example/a.jpg", script: "'not bytes'", source: nil
            )
        )
    }

    func testImageDecodeSkipsEmptyScriptOrData() {
        XCTAssertNil(
            ImageDecodeRule.decode(Data([1]), src: "x", script: "   ", source: nil)
        )
        XCTAssertNil(
            ImageDecodeRule.decode(Data(), src: "x", script: "result", source: nil)
        )
    }

    // MARK: callBackJs（事件回调，不是正文后处理）

    func testCallBackJsReceivesEventBookAndChapter() {
        var rule = ContentRule()
        rule.callBackJs = """
        event === 'startRead'
          && chapter && chapter.title === '第1章'
          && book && book.name === '测试书'
        """
        let source = BookSource(
            bookSourceUrl: "https://example.com",
            bookSourceName: "测试源",
            ruleContent: rule,
            eventListener: true
        )
        let book = Book(bookUrl: "https://example.com/book", name: "测试书", author: "作者")
        let chapter = BookChapter(
            bookUrl: book.bookUrl,
            url: "https://example.com/1",
            title: "第1章",
            index: 0
        )

        XCTAssertTrue(
            SourceEventCallback.fire(
                event: SourceEventCallback.startRead,
                source: source,
                book: book,
                chapter: chapter
            )
        )
    }

    func testCallBackJsDoesNotRunWithoutEventListener() {
        var rule = ContentRule()
        rule.callBackJs = "true"
        let source = BookSource(
            bookSourceUrl: "https://example.com",
            bookSourceName: "测试源",
            ruleContent: rule,
            eventListener: false
        )

        XCTAssertFalse(
            SourceEventCallback.fire(event: "startRead", source: source, book: nil, chapter: nil)
        )
    }

    func testCallBackJsSwallowsScriptError() {
        var rule = ContentRule()
        rule.callBackJs = "throw new Error('boom')"
        let source = BookSource(
            bookSourceUrl: "https://example.com",
            bookSourceName: "测试源",
            ruleContent: rule,
            eventListener: true
        )

        XCTAssertFalse(
            SourceEventCallback.fire(event: "endRead", source: source, book: nil, chapter: nil)
        )
    }

    // MARK: payAction 不进入正文变换链

    func testAssembleSinglePageIgnoresCallBackJsPayActionAndImageStyle() {
        let analyzer = RuleAnalyzer(
            content: #"<div class="body">正文内容</div>"#,
            baseUrl: "https://example.com/chapter/1"
        )
        var rule = ContentRule()
        rule.content = ".body"
        rule.callBackJs = "throw new Error('callBackJs should not run in content chain')"
        rule.payAction = "throw new Error('payAction should not run in content chain')"
        rule.imageStyle = "FULL"
        let book = Book(
            bookUrl: "https://example.com/book",
            name: "测试书",
            author: "作者",
            useReplaceRule: false
        )

        let text = BookContentService.shared.assembleSinglePage(
            analyzer: analyzer,
            contentRule: rule,
            baseURL: "https://example.com/chapter/1",
            extractedText: nil,
            book: book
        )

        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "正文内容")
    }
}
