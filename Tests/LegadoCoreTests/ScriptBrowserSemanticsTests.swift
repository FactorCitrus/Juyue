import XCTest
import JavaScriptCore
@testable import LegadoCore

final class ScriptBrowserSemanticsTests: XCTestCase {

    private func makeShim() -> (JavaShim, JSContext) {
        let ctx = JSContext()!
        // 上下文由调用方持有，JavaShim 里存的是弱引用
        return (JavaShim(context: ctx), ctx)
    }

    /// `java.startBrowserAwait` 的契约是「等用户关网页，再把最终 HTML / URL 交回脚本」。
    ///
    /// 书源设置中心这么调：`java.startBrowserAwait(openUrl, '书源设置', false)`，接着用
    /// `readSettingsResultFromBody(browserResult.body())` 读设置结果。第三个参数是按安卓
    /// 签名传下来的，宿主不能拿它当「不等」：那样 body 是空的，脚本只会走到
    /// 「未读取到设置结果」。
    func testStartBrowserAwaitAlwaysWaits() throws {
        let (shim, _) = makeShim()
        var seen: [Bool] = []
        ScriptBrowser.shared.present = { _, _, wait in
            seen.append(wait)
            return (body: "<html>设置结果</html>", url: "about:blank#config=%7B%22pstyle%22%3A%221%22%7D")
        }
        defer { ScriptBrowser.shared.present = nil }

        let value = shim.startBrowserAwait("data:text/html;base64,PGh0bWw+", "书源设置", false)

        XCTAssertEqual(seen, [true], "Await 必须让宿主等网页关闭")
        // body 按安卓契约是方法（`.body()`），字符串读 bodyString。
        // 早先这里按属性直接比字符串，函数体 toString 永远不等于正文。
        let bodyFn = value.forProperty("body")
        XCTAssertEqual(bodyFn?.isObject, true, "body 必须是方法")
        XCTAssertEqual(bodyFn?.call(withArguments: [])?.toString(), "<html>设置结果</html>")
        XCTAssertEqual(value.forProperty("bodyString")?.toString(), "<html>设置结果</html>")
        XCTAssertEqual(value.forProperty("url")?.toString(), "about:blank#config=%7B%22pstyle%22%3A%221%22%7D")
        XCTAssertEqual(value.forProperty("code")?.toInt32(), 200)
    }

    /// 两参版同样要等。
    func testStartBrowserAwaitTwoArgsWaits() throws {
        let (shim, _) = makeShim()
        var seen: [Bool] = []
        ScriptBrowser.shared.present = { _, _, wait in
            seen.append(wait)
            return (body: "ok", url: "https://example.invalid/back")
        }
        defer { ScriptBrowser.shared.present = nil }

        _ = shim.startBrowserAwait("https://example.invalid/back", "用户后台")
        XCTAssertEqual(seen, [true])
    }

    /// 只弹不等的接口保持不等，否则脚本线程会白等到用户关页面。
    func testStartBrowserDoesNotWait() throws {
        let (shim, _) = makeShim()
        var seen: [Bool] = []
        ScriptBrowser.shared.present = { _, _, wait in
            seen.append(wait)
            return (body: "", url: "")
        }
        defer { ScriptBrowser.shared.present = nil }

        shim.startBrowser("https://example.invalid/publish", "永久发布页")
        XCTAssertEqual(seen, [false])
    }
}
