import XCTest
@testable import LegadoCore

final class BookSourceRoundTripTests: XCTestCase {

    /// 书源导入后 encode 进本地存储，下次启动 decode 出来。
    /// 这一进一出丢了 jsLib，规则脚本会在 `host` / `getArguments` 上抛错。
    func testJsLibSurvivesEncodeDecodeRoundTrip() throws {
        let original = BookSource(
            bookSourceUrl: "示例标识",
            bookSourceName: "示例书源",
            exploreUrl: "<js>host[0]</js>",
            jsLib: "var host = ['https://v5.langge.uk'];"
        )

        let encoded = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([BookSource].self, from: encoded)

        XCTAssertEqual(decoded.first?.jsLib, "var host = ['https://v5.langge.uk'];",
                       "encode/decode 把 jsLib 弄丢了，脚本必然 ReferenceError")
        XCTAssertEqual(decoded.first?.exploreUrl, "<js>host[0]</js>")
    }
}

// MARK: - 规则字段

final class RuleFieldsRoundTripTests: XCTestCase {

    /// 书评规则、副文规则、回调 JS 这些字段要能进模型，否则编辑器里改了也存不下。
    /// 详情规则的预处理在安卓导出的键是 `init`，不映射就整条丢。
    func testReviewAndContentFieldsRoundTrip() throws {
        let json = """
        [{
          "bookSourceName": "示例",
          "bookSourceUrl": "https://example.invalid",
          "ruleBookInfo": {"init": ".book@h1@text", "name": "h1@text", "canReName": "\\\\d+"},
          "ruleContent": {"content": "#content@textNodes", "subContent": "#lyric@text", "callBackJs": "java.toast('ok')"},
          "ruleReview": {
            "reviewUrl": "https://example.invalid/review",
            "avatarRule": "img@src",
            "contentRule": "p@text",
            "postTimeRule": "span@text",
            "inlineHotReview": {"urlRule": "/hot", "listRule": ".hot", "contentRule": "p@text"},
            "voteUpUrl": "/up"
          }
        }]
        """
        let sources = try JSONDecoder().decode([BookSource].self, from: Data(json.utf8))
        let source = try XCTUnwrap(sources.first)

        XCTAssertEqual(source.ruleBookInfo?.initRule, ".book@h1@text")
        XCTAssertEqual(source.ruleBookInfo?.canReName, "\\d+")
        XCTAssertEqual(source.ruleContent?.subContent, "#lyric@text")
        XCTAssertEqual(source.ruleContent?.callBackJs, "java.toast('ok')")
        XCTAssertEqual(source.ruleReview?.reviewUrl, "https://example.invalid/review")
        XCTAssertEqual(source.ruleReview?.postTimeRule, "span@text")
        XCTAssertEqual(source.ruleReview?.inlineHotReview?.contentRule, "p@text")
        XCTAssertEqual(source.ruleReview?.voteUpUrl, "/up")

        // 存回本地再读一遍，导出时不能丢
        let encoded = try JSONEncoder().encode([source])
        let decoded = try JSONDecoder().decode([BookSource].self, from: encoded)
        XCTAssertEqual(decoded.first?.ruleReview?.inlineHotReview?.urlRule, "/hot")
        XCTAssertEqual(decoded.first?.ruleBookInfo?.initRule, ".book@h1@text")
        XCTAssertEqual(decoded.first?.ruleContent?.subContent, "#lyric@text")
    }
}
