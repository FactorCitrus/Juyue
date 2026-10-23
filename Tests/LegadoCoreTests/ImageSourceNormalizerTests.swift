import XCTest
@testable import LegadoCore

final class ImageSourceNormalizerTests: XCTestCase {
    func testCollapsesRepeatedDataPrefixAndStripsMetadata() {
        let raw = #"data:data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=,%7B%22js%22%3A%22showCmt(...)%22%7D"#
        XCTAssertEqual(
            ImageSourceNormalizer.normalize(raw),
            "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4="
        )
    }

    func testStripsRemoteCardMetadataAndFixesProtocolRelativeURL() {
        XCTAssertEqual(
            ImageSourceNormalizer.normalize(#"https://cdn.example/a.jpg,{"click":"showCmt(...)"}"#),
            "https://cdn.example/a.jpg"
        )
        XCTAssertEqual(
            ImageSourceNormalizer.normalize("//cdn.example/b.jpg"),
            "https://cdn.example/b.jpg"
        )
    }

    func testDataURIPayloadStopsAtMetadataComma() {
        let raw = "data:image/svg+xml;base64,QUJD,%7B%22js%22%3A%22x%22%7D"
        XCTAssertEqual(ImageSourceNormalizer.dataURIPayload(raw), "QUJD")
    }

    func testDecodedSourceGetsIsValidCompatibilityFix() throws {
        let json = #"""
        [{
          "bookSourceUrl": "https://example.com",
          "bookSourceName": "示例",
          "ruleBookInfo": {
            "intro": "<js>let isValid = (value) => String(value).length > 1; if (isValid(abstract)) abstract.split('\\n');</js>"
          }
        }]
        """#
        let decoded = try JSONDecoder().decode([BookSource].self, from: Data(json.utf8))
        let intro = try XCTUnwrap(decoded.first?.ruleBookInfo?.intro)
        XCTAssertTrue(intro.contains("value !== undefined && value !== null"), intro)
        XCTAssertFalse(intro.contains("let isValid = (value) => String(value).length > 1;"), intro)
    }
}
