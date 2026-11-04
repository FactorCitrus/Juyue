import XCTest
@testable import LegadoCore

/// 书源兼容 P2：`org.jsoup` shim 与 `java.getElements`。
final class JsoupCompatibilityTests: XCTestCase {
    private let html = """
    <html><head><title>示例页</title></head><body>
    <div id="list" class="list">
      <a class="item" href="b/1" data-id="1">第一本</a>
      <a class="item" href="b/2" data-id="2">第二本</a>
    </div>
    </body></html>
    """

    private func makeEngine() -> JSEngine {
        let engine = JSEngine(baseUrl: "https://example.com/book/")
        engine.context.setObject(html, forKeyedSubscript: "page" as NSString)
        return engine
    }

    // MARK: - org.jsoup

    func testParseSelectTextSizeAndAttr() {
        let engine = makeEngine()

        XCTAssertEqual(
            engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').text()") as? String,
            "第一本 第二本"
        )
        XCTAssertEqual(
            engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').size()") as? Int,
            2
        )
        XCTAssertEqual(
            engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').get(0).attr('href')") as? String,
            "b/1"
        )
        XCTAssertEqual(
            engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').attr('data-id')") as? String,
            "1"
        )
        XCTAssertEqual(
            engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').get(1).text()") as? String,
            "第二本"
        )
        XCTAssertNil(engine.lastError)
    }

    func testElementAndCollectionApis() {
        let engine = makeEngine()

        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').first().text()") as? String, "第一本")
        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').last().text()") as? String, "第二本")
        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').eq(1).text()") as? String, "第二本")
        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').get(1).tagName()") as? String, "a")
        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').get(0).className()") as? String, "item")
        XCTAssertEqual(
            engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').get(0).hasAttr('href')") as? Bool,
            true
        )
        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').get(0).ownText()") as? String, "第一本")
        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse(page).select('#list').id()") as? String, "list")
        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse(page).select('#list').children().size()") as? Int, 2)
        XCTAssertEqual(
            engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').get(0).parent().tagName()") as? String,
            "div"
        )
        XCTAssertNil(engine.lastError)
    }

    func testOuterHtmlAndDocumentApis() {
        let engine = makeEngine()

        let outer = engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').get(0).outerHtml()") as? String
        XCTAssertTrue(outer?.hasPrefix("<a") == true)
        XCTAssertTrue(outer?.contains("第一本") == true)

        let inner = engine.eval(script: "org.jsoup.Jsoup.parse(page).select('#list').html()") as? String
        XCTAssertTrue(inner?.contains("第一本") == true)

        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse(page).title()") as? String, "示例页")
        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse(page).body().tagName()") as? String, "body")

        let stringified = engine.eval(script: "String(org.jsoup.Jsoup.parse(page).select('a.item').first())") as? String
        XCTAssertTrue(stringified?.hasPrefix("<a") == true)
        XCTAssertNil(engine.lastError)
    }

    func testAbsUrlUsesBaseUri() {
        let engine = makeEngine()

        XCTAssertEqual(
            engine.eval(script: "org.jsoup.Jsoup.parse(page, 'https://example.com/book/').select('a').get(0).absUrl('href')") as? String,
            "https://example.com/book/b/1"
        )
        XCTAssertNil(engine.lastError)
    }

    func testInvalidSelectorAndEmptyHtmlDoNotThrow() {
        let engine = makeEngine()

        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse('').select('a').size()") as? Int, 0)
        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse(page).select('div[').size()") as? Int, 0)
        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse(page).select(null).size()") as? Int, 0)
        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a').get(9).text()") as? String, "")
        XCTAssertEqual(engine.eval(script: "org.jsoup.Jsoup.parse(page).select('span').first().text()") as? String, "")
        XCTAssertNil(engine.lastError)
    }

    func testPackagesAndJavaImporterExposeJsoup() {
        let engine = makeEngine()

        XCTAssertEqual(
            engine.eval(script: "Packages.org.jsoup.Jsoup.parse(page).select('a.item').size()") as? Int,
            2
        )
        XCTAssertEqual(
            engine.eval(script: "JavaImporter(org.jsoup).Jsoup.parse(page).select('a.item').size()") as? Int,
            2
        )
        XCTAssertNil(engine.lastError)
    }

    func testCollectionWorksLikeJavaList() {
        let engine = makeEngine()

        XCTAssertEqual(
            engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').length") as? Int,
            2
        )
        XCTAssertEqual(
            engine.eval(script: "Array.from(org.jsoup.Jsoup.parse(page).select('a.item')).map(function(a){return a.text()}).join(',')") as? String,
            "第一本,第二本"
        )
        XCTAssertEqual(
            engine.eval(script: "org.jsoup.Jsoup.parse(page).select('a.item').toArray().map(function(a){return a.attr('data-id')}).join(',')") as? String,
            "1,2"
        )
        XCTAssertEqual(
            engine.eval(script: """
            var out = [];
            var els = org.jsoup.Jsoup.parse(page).select('a.item');
            for (var i in els) { out.push(i + ':' + els[i].text()); }
            out.join(',')
            """) as? String,
            "0:第一本,1:第二本"
        )
        XCTAssertNil(engine.lastError)
    }

    func testRemoveMutatesDocument() {
        let engine = makeEngine()

        XCTAssertEqual(
            engine.eval(script: "var doc = org.jsoup.Jsoup.parse(page); doc.select('a.item').remove(); doc.select('a').size()") as? Int,
            0
        )
        XCTAssertNil(engine.lastError)
    }

    func testConnectIsChainableWithoutNetwork() {
        let engine = makeEngine()

        XCTAssertEqual(
            engine.eval(script: "typeof org.jsoup.Jsoup.connect('https://example.invalid').get") as? String,
            "function"
        )
        XCTAssertEqual(
            engine.eval(script: "typeof org.jsoup.Jsoup.connect('https://example.invalid').timeout(100).header('a','b').get") as? String,
            "function"
        )
        XCTAssertNil(engine.lastError)
    }

    // MARK: - java.getElements

    func testJavaGetElementsMatchesJsoup() {
        let engine = makeEngine()

        XCTAssertEqual(engine.eval(script: "java.getElements(page, 'a.item').size()") as? Int, 2)
        XCTAssertEqual(engine.eval(script: "java.getElements(page, 'a.item').text()") as? String, "第一本 第二本")
        XCTAssertEqual(engine.eval(script: "java.getElements(page, 'a.item').get(0).attr('href')") as? String, "b/1")
        XCTAssertEqual(engine.eval(script: "java.getElements(page, 'a.item').first().text()") as? String, "第一本")
        XCTAssertEqual(
            engine.eval(script: "java.getElements(page, '#list a.item').last().text()") as? String,
            "第二本"
        )
        XCTAssertNil(engine.lastError)
    }

    func testJavaGetElementsEmptyRuleReturnsDocument() {
        let engine = makeEngine()

        XCTAssertEqual(engine.eval(script: "java.getElements(page, '').select('a.item').size()") as? Int, 2)
        XCTAssertNil(engine.lastError)
    }

    func testJavaGetElementsSingleArgumentUsesCurrentResult() {
        let engine = makeEngine()
        let html = "<dl><dd>A</dd><dd>B</dd><dd>C</dd></dl>"

        XCTAssertEqual(engine.eval(script: "java.getElements('dd!-1').text()", result: html) as? String, "C")
        XCTAssertEqual(engine.eval(script: "java.getElements('dd').length", result: html) as? Int, 3)
        XCTAssertEqual(engine.eval(script: "java.getElements('dd')[1].text()", result: html) as? String, "B")
        XCTAssertNil(engine.lastError)
    }

    func testJavaGetElementsClassAndTagChain() {
        let engine = makeEngine()
        let toc = "<div class='directoryArea'><p><a href='/1'>一</a></p><p><a href='/2'>二</a></p></div>"

        XCTAssertEqual(
            engine.eval(script: "java.getElements('class.directoryArea@tag.p@tag.a').length", result: toc) as? Int,
            2
        )
        XCTAssertEqual(
            engine.eval(script: "java.getElements('class.directoryArea@tag.p@tag.a')[1].text()", result: toc) as? String,
            "二"
        )
        XCTAssertEqual(
            engine.eval(script: "java.getElements('class.directoryArea@tag.p@tag.a')[1].attr('href')", result: toc) as? String,
            "/2"
        )
        XCTAssertNil(engine.lastError)
    }

    func testJavaGetElementsInvalidRuleIsEmpty() {
        let engine = makeEngine()

        XCTAssertEqual(engine.eval(script: "java.getElements(page, 'div[').size()") as? Int, 0)
        XCTAssertEqual(engine.eval(script: "java.getElements('', 'a.item').size()") as? Int, 0)
        XCTAssertNil(engine.lastError)
    }
}
