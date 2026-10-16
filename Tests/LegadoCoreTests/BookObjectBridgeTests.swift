import XCTest
@testable import LegadoCore

final class BookObjectBridgeTests: XCTestCase {

    private func makeBook(variable: String? = nil, useReplaceRule: Bool? = nil) -> Book {
        var book = Book(bookUrl: "https://example.invalid/b1", name: "示例书", author: "示例作者")
        book.variable = variable
        book.useReplaceRule = useReplaceRule
        return book
    }

    /// `book.getVariable` / `book.setVariable`：读写书级变量，写完回传宿主落盘。
    func testBookVariableRoundTrip() {
        var updated: Book?
        JSEngine.bookUpdateSink = { updated = $0 }
        defer { JSEngine.bookUpdateSink = nil }

        let engine = JSEngine(bookSource: nil, baseUrl: nil, book: makeBook(variable: #"{"custom":"old"}"#))
        XCTAssertEqual(engine.eval(script: "book.getVariable('custom')") as? String, "old")

        _ = engine.eval(script: "book.setVariable('custom','new')")
        XCTAssertEqual(updated?.variable, #"{"custom":"new"}"#)
        // 同一个引擎里再读要读到新值
        XCTAssertEqual(engine.eval(script: "book.getVariable('custom')") as? String, "new")
    }

    /// 没记过的书，`book.readConfig.useReplaceRule` 要是 null —— 源就是靠这个判断要不要主动关掉。
    func testReadConfigIsNullWhenUnset() {
        let engine = JSEngine(bookSource: nil, baseUrl: nil, book: makeBook())
        XCTAssertEqual(engine.eval(script: "String(book.readConfig.useReplaceRule)") as? String, "null")
    }

    /// 记过的书要如实反映，源不会再去覆盖用户/上次的设置。
    func testReadConfigReflectsBook() {
        let engine = JSEngine(bookSource: nil, baseUrl: nil, book: makeBook(useReplaceRule: true))
        XCTAssertEqual(engine.eval(script: "String(book.readConfig.useReplaceRule)") as? String, "true")
    }

    /// `book.setUseReplaceRule(false)`：写进书里并回传。
    func testSetUseReplaceRuleReportsToSink() {
        var updated: Book?
        JSEngine.bookUpdateSink = { updated = $0 }
        defer { JSEngine.bookUpdateSink = nil }

        let engine = JSEngine(bookSource: nil, baseUrl: nil, book: makeBook())
        _ = engine.eval(script: "book.setUseReplaceRule(false)")
        XCTAssertEqual(updated?.useReplaceRule, false)
        XCTAssertEqual(engine.eval(script: "String(book.readConfig.useReplaceRule)") as? String, "false")
    }

    /// `java.refreshExplore()` 要把宿主回调叫起来（安卓语义：刷新分类页）。
    func testRefreshExploreCallsSink() {
        var hits = 0
        JSEngine.exploreRefreshSink = { hits += 1 }
        defer { JSEngine.exploreRefreshSink = nil }

        let engine = JSEngine(bookSource: nil, baseUrl: nil)
        _ = engine.eval(script: "java.refreshExplore()")
        XCTAssertEqual(hits, 1)
    }

    /// 书的基本字段要能看到，源会拿来判断（例：`book.durChapterIndex === chapter.index`）。
    func testBookFieldsVisible() {
        var book = makeBook()
        book.durChapterIndex = 7
        book.durChapterTitle = "第8章 示例"
        let engine = JSEngine(bookSource: nil, baseUrl: nil, book: book)
        XCTAssertEqual(engine.eval(script: "book.durChapterIndex") as? Int, 7)
        XCTAssertEqual(engine.eval(script: "book.durChapterTitle") as? String, "第8章 示例")
    }
}
