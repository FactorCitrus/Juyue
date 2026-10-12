import XCTest
@testable import LegadoCore

final class HttpTTSTests: XCTestCase {

    // MARK: - 导入

    func testParseSingleObject() throws {
        let json = """
        {"name":"百度翻译朗读","url":"https://fanyi.baidu.com/gettts?text={{java.encodeURI(speakText)}}","contentType":"audio/mpeg"}
        """
        let sources = try HttpTTS.parse(json: json)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].name, "百度翻译朗读")
        XCTAssertEqual(sources[0].contentType, "audio/mpeg")
    }

    func testParseArrayWithLoginUiObject() throws {
        let json = """
        [
          {"id":-100,"name":"1.百度","url":"http://tts.baidu.com/text2audio","contentType":"audio/wav"},
          {"id":-29,"name":"2.阿里云","url":"https://example.com/tts","loginUi":[{"name":"AppKey","type":"text"}]}
        ]
        """
        let sources = try HttpTTS.parse(json: json)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0].id, -100)
        XCTAssertEqual(sources[1].loginUi, "[{\"type\":\"text\",\"name\":\"AppKey\"}]")
    }

    func testParseRejectsMissingURL() {
        XCTAssertThrowsError(try HttpTTS.parse(json: "[{\"name\":\"坏源\"}]"))
    }

    func testParseRejectsEmpty() {
        XCTAssertThrowsError(try HttpTTS.parse(json: "   "))
    }

    func testEffectiveSpeedDefaultsToFive() throws {
        let sources = try HttpTTS.parse(json: "{\"name\":\"x\",\"url\":\"https://a/b\"}")
        XCTAssertEqual(sources[0].effectiveSpeed, 5)
    }

    // MARK: - 模板求值

    func testEncodeURIMatchesJavaURLEncoder() {
        XCTAssertEqual(JavaURLEncoder.encode("你好 世界"), "%E4%BD%A0%E5%A5%BD+%E4%B8%96%E7%95%8C")
        XCTAssertEqual(JavaURLEncoder.encode("a-b_c.*~"), "a-b_c.*%7E")
    }

    func testRenderEncodeURI() throws {
        let renderer = TTSTemplateRenderer()
        let out = try renderer.render(
            "https://dict.youdao.com/dictvoice?audio={{java.encodeURI(speakText)}}&le=zh",
            context: TTSTemplateContext(speakText: "你好 世界", speakSpeed: 5)
        )
        XCTAssertEqual(
            out,
            "https://dict.youdao.com/dictvoice?audio=%E4%BD%A0%E5%A5%BD+%E4%B8%96%E7%95%8C&le=zh"
        )
    }

    func testRenderNestedRules() throws {
        let renderer = TTSTemplateRenderer()
        let out = try renderer.render(
            "tex={{java.encodeURI(java.encodeURI(speakText))}}",
            context: TTSTemplateContext(speakText: "你好", speakSpeed: 5)
        )
        XCTAssertEqual(out, "tex=%25E4%25BD%25A0%25E5%25A5%25BD")
    }

    func testRenderIntegerSpeedDropsDecimalPoint() throws {
        let renderer = TTSTemplateRenderer()
        let out = try renderer.render(
            "spd={{String(Math.floor(speakSpeed / 8) + 4)}}",
            context: TTSTemplateContext(speakText: "x", speakSpeed: 20)
        )
        XCTAssertEqual(out, "spd=6")
    }

    func testRenderSpeedExpressionFromAndroidDefault() throws {
        let renderer = TTSTemplateRenderer()
        let out = try renderer.render(
            "spd={{(speakSpeed + 5) / 10 + 4}}",
            context: TTSTemplateContext(speakText: "x", speakSpeed: 5)
        )
        XCTAssertEqual(out, "spd=5")
    }

    func testRenderUnbalancedBracesThrows() {
        let renderer = TTSTemplateRenderer()
        XCTAssertThrowsError(try renderer.render("a={{b", context: TTSTemplateContext(speakText: "x", speakSpeed: 5)))
    }

    // MARK: - 请求构造

    func testMakeRequestForAndroidBaiduDefault() throws {
        let json = """
        {
          "name": "1.百度",
          "url": "http://tts.baidu.com/text2audio,{\\n    \\"method\\": \\"POST\\",\\n    \\"body\\": \\"tex={{java.encodeURI(java.encodeURI(speakText))}}&spd={{(speakSpeed + 5) / 10 + 4}}&per=3&_res_tag_=audio\\"\\n}",
          "contentType": "audio/wav"
        }
        """
        let source = try XCTUnwrap(HttpTTS.parse(json: json).first)
        let request = try HttpTTSEngine().makeRequest(source: source, text: "你好", speed: 5)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "http://tts.baidu.com/text2audio")
        let body = try XCTUnwrap(request.body)
        let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(bodyText.contains("tex=%25E4%25BD%25A0%25E5%25A5%25BD"), bodyText)
        XCTAssertTrue(bodyText.contains("spd=5"), bodyText)
        XCTAssertTrue(bodyText.contains("_res_tag_=audio"), bodyText)
    }

    func testMakeRequestForYoudaoGet() throws {
        let source = HttpTTS(
            name: "有道",
            url: "https://dict.youdao.com/dictvoice?le=zh&audio={{java.encodeURI(speakText)}}",
            contentType: "audio/mpeg"
        )
        let request = try HttpTTSEngine().makeRequest(source: source, text: "你好", speed: 5)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(
            request.url.absoluteString,
            "https://dict.youdao.com/dictvoice?le=zh&audio=%E4%BD%A0%E5%A5%BD"
        )
    }

    func testMakeRequestAppliesSourceHeader() throws {
        let source = HttpTTS(
            name: "带请求头",
            url: "https://example.com/tts?t={{java.encodeURI(speakText)}}",
            header: "{\"X-Test\":\"yes\"}"
        )
        let request = try HttpTTSEngine().makeRequest(source: source, text: "a", speed: 5)
        XCTAssertEqual(request.headers["X-Test"], "yes")
    }

    // MARK: - 返回校验

    func testValidateAcceptsAudio() throws {
        let source = HttpTTS(name: "x", url: "https://a/b", contentType: "audio/mpeg")
        XCTAssertNoThrow(try HttpTTSEngine.validate(contentType: "audio/mpeg", body: "", source: source))
    }

    func testValidateRejectsJSONBody() throws {
        let source = HttpTTS(name: "x", url: "https://a/b", contentType: "audio/mpeg")
        XCTAssertThrowsError(
            try HttpTTSEngine.validate(contentType: "application/json", body: "{\"err\":1}", source: source)
        )
    }

    func testValidateRejectsHTMLBody() throws {
        let source = HttpTTS(name: "x", url: "https://a/b")
        XCTAssertThrowsError(
            try HttpTTSEngine.validate(contentType: "text/html", body: "<html>", source: source)
        )
    }

    func testValidateRejectsMismatchedContentType() throws {
        let source = HttpTTS(name: "x", url: "https://a/b", contentType: "audio/wav")
        XCTAssertThrowsError(
            try HttpTTSEngine.validate(contentType: "audio/mpeg", body: "", source: source)
        )
    }

    func testBaseContentTypeStripsParameters() {
        XCTAssertEqual(HttpTTSEngine.baseContentType("audio/mpeg; charset=utf-8"), "audio/mpeg")
        XCTAssertEqual(HttpTTSEngine.baseContentType("AUDIO/MPEG"), "audio/mpeg")
        XCTAssertNil(HttpTTSEngine.baseContentType("  "))
    }

    // MARK: - 分段

    func testChunkerSplitsAndMerges() {
        let text = "第一句。第二句。第三句。"
        let chunks = TTSTextChunker.split(text, maxLength: 8)
        XCTAssertEqual(chunks, ["第一句。第二句。", "第三句。"])
    }

    func testChunkerHardSplitsLongSentence() {
        let text = String(repeating: "长", count: 25)
        let chunks = TTSTextChunker.split(text, maxLength: 10)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.count), [10, 10, 5])
    }

    func testChunkerReturnsEmptyForBlankInput() {
        XCTAssertTrue(TTSTextChunker.split("   \n  ").isEmpty)
    }

    // MARK: - 语音源存档

    private func makeTemporaryStore() -> HttpTTSStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("legado-httptts-tests-\(UUID().uuidString)", isDirectory: true)
        return HttpTTSStore(directory: directory)
    }

    func testStoreImportMergeReplaceAndRemove() throws {
        let store = makeTemporaryStore()
        let first = """
        {"name":"百度翻译朗读","url":"https://fanyi.baidu.com/gettts?text={{java.encodeURI(speakText)}}"}
        """
        let second = """
        [{"id":-100,"name":"1.百度","url":"http://tts.baidu.com/text2audio"},
         {"id":-29,"name":"2.阿里云","url":"https://example.com/tts"}]
        """

        try store.importJSON(first, replace: false)
        XCTAssertEqual(store.sources.count, 1)

        try store.importJSON(second, replace: false)
        XCTAssertEqual(store.sources.count, 3)

        try store.importJSON("{\"id\":-100,\"name\":\"1.百度改\",\"url\":\"http://tts.baidu.com/text2audio\"}")
        XCTAssertEqual(store.sources.count, 3)
        XCTAssertEqual(store.source(id: -100)?.name, "1.百度改")

        try store.remove(id: -29)
        XCTAssertEqual(store.sources.count, 2)

        try store.importJSON(first, replace: true)
        XCTAssertEqual(store.sources.count, 1)
    }

    func testStoreRoundTripsThroughDisk() throws {
        let store = makeTemporaryStore()
        try store.importJSON("""
        [{"id":-100,"name":"1.百度","url":"http://tts.baidu.com/text2audio","contentType":"audio/wav"},
         {"id":7,"name":"Next","url":"http://5.45.99.149:8075/tts?t={{java.encodeURI(speakText)}}","speed":10}]
        """, replace: true)

        let reloaded = HttpTTSStore(directory: URL(fileURLWithPath: store.filePath).deletingLastPathComponent())
        try reloaded.load()
        XCTAssertEqual(reloaded.sources.count, 2)
        XCTAssertEqual(reloaded.source(id: -100)?.contentType, "audio/wav")
        XCTAssertEqual(reloaded.source(id: 7)?.effectiveSpeed, 10)
    }
}
