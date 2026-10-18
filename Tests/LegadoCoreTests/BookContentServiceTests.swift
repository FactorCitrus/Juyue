import XCTest
@testable import LegadoCore

final class BookContentServiceTests: XCTestCase {
    func testCleanHtmlExtractsLazySrcsetAndCardImage() {
        let html = """
        <p><img data-src="//cdn.example/a.jpg" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="></p>
        <p><img srcset="https://cdn.example/b.jpg 1x, https://cdn.example/c.jpg 2x"></p>
        <p><img src="https://cdn.example/d.jpg,{&quot;click&quot;:&quot;showCmt('https://x','段评')&quot;}"></p>
        """

        let cleaned = BookContentService.cleanHtml(html, baseUrl: "https://example.com/chapter/1")

        XCTAssertTrue(cleaned.contains("[image:https://cdn.example/a.jpg]"), cleaned)
        XCTAssertTrue(cleaned.contains("[image:https://cdn.example/b.jpg]"), cleaned)
        XCTAssertTrue(cleaned.contains("[image:https://cdn.example/d.jpg]"), cleaned)
        XCTAssertFalse(cleaned.contains("showCmt"), cleaned)
    }

    func testPreserveReviewMarkersExtractsInlineGodCard() throws {
        let svg = "<svg><text>神评论</text><text>太好看了</text></svg>"
        let encoded = Data(svg.utf8).base64EncodedString()
        let html = "<img src=\"data:image/svg+xml;base64,\(encoded),{&quot;click&quot;:&quot;showCmt('https://example.com/comment','段评')&quot;}\">"

        let marker = try godMarker(in: BookContentService.preserveReviewMarkers(html))

        XCTAssertEqual(marker.text, "太好看了")
        XCTAssertEqual(marker.url, "https://example.com/comment")
        XCTAssertNil(marker.image)
    }

    func testPreserveReviewMarkersKeepsRemoteGodCardImage() throws {
        let html = "<img src=\"https://cdn.example/hot.jpg,{&quot;click&quot;:&quot;showCmt('https://example.com/comment','段评')&quot;}\">"

        let marker = try godMarker(in: BookContentService.preserveReviewMarkers(html))

        XCTAssertEqual(marker.text, "")
        XCTAssertEqual(marker.url, "https://example.com/comment")
        XCTAssertEqual(marker.image, "https://cdn.example/hot.jpg")
    }

    func testPreserveReviewMarkersKeepsMultipleGodCards() {
        let svg = "<svg><text>神评论</text><text>第一条</text></svg>"
        let encoded = Data(svg.utf8).base64EncodedString()
        let html = """
        <img src="data:image/svg+xml;base64,\(encoded),{&quot;click&quot;:&quot;showCmt('https://example.com/first','段评')&quot;}">
        <img src="https://cdn.example/second.jpg,{&quot;click&quot;:&quot;showCmt('https://example.com/second','段评')&quot;}">
        """

        let marked = BookContentService.preserveReviewMarkers(html)

        XCTAssertEqual(marked.components(separatedBy: "\u{E000}G").count - 1, 2, marked)
    }

    func testJSCacheMemoryHelpers() {
        let engine = JSEngine()
        let result = engine.eval(script: "cache.putMemory('k', 2); String(cache.getFromMemory('k'))")
        XCTAssertEqual(result as? String, "2")
    }

    private func godMarker(in text: String) throws -> (text: String, url: String, image: String?) {
        let pattern = "\u{E000}G\u{1F}([^\u{E001}]*)\u{E001}"
        let regex = try NSRegularExpression(pattern: pattern)
        let nsText = text as NSString
        let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)))
        let body = nsText.substring(with: match.range(at: 1))
        let parts = body.components(separatedBy: "\u{1F}")
        let decodedText = parts.first.flatMap { Data(base64Encoded: $0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let decodedImage = parts.count > 2
            ? Data(base64Encoded: parts[2]).flatMap { String(data: $0, encoding: .utf8) }
            : nil
        return (decodedText, parts.count > 1 ? parts[1] : "", decodedImage?.isEmpty == true ? nil : decodedImage)
    }
}
