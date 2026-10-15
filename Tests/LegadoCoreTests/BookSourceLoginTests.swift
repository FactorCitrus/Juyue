import XCTest
@testable import LegadoCore

final class BookSourceLoginTests: XCTestCase {

    /// 「大灰狼聚合」这类书源的登录脚本第一步就摸 `cookie`：
    ///   var c = cookie.getCookie(base_url)
    ///   cookie.setCookie(base_url, "qttoken=...;deviceId=...")
    /// 宿主没暴露 cookie 对象时，脚本在那一行直接抛 ReferenceError，
    /// 后面的逻辑一行都执行不到，界面只显示「登录未返回有效凭据」。
    func testLoginScriptCanUseCookieObject() throws {
        let engine = JSEngine(baseUrl: "https://v5.langge.uk")
        var header: String?
        engine.onLoginHeaderUpdated = { header = $0 }

        _ = engine.eval(script: """
        cookie.setCookie('https://v5.langge.uk', 'qttoken=abc123;deviceId=dev1');
        var token = cookie.getKey('https://v5.langge.uk', 'qttoken');
        source.putLoginHeader('Cookie:qttoken=' + token);
        """)

        XCTAssertNil(engine.lastError, "cookie 对象不可用，脚本会在这里断掉")
        XCTAssertEqual(header, "Cookie:qttoken=abc123")
    }

    /// loginUrl 可能写成 <js>...</js>。宿主直接把它丢给 evaluateScript 会语法错误。
    func testLoginScriptStripsJsWrapper() throws {
        let engine = JSEngine(baseUrl: "https://example.com")
        var header: String?
        engine.onLoginHeaderUpdated = { header = $0 }

        _ = engine.eval(script: JSEngine.unwrapJsScript("<js>\nsource.putLoginHeader('tok');\n</js>"))

        XCTAssertNil(engine.lastError)
        XCTAssertEqual(header, "tok")
    }

    /// 登录函数第一行是 java.longToast(...)，拼 cookie 要用 java.deviceID()。
    /// 缺任何一个都会抛 TypeError，脚本断在那一行，后面的登录逻辑一行都跑不到。
    func testLoginScriptHasCommonJavaApi() throws {
        let engine = JSEngine(baseUrl: "https://v5.langge.uk")
        var header: String?
        engine.onLoginHeaderUpdated = { header = $0 }

        _ = engine.eval(script: """
        java.longToast('正在登录中...');
        java.toast('ok');
        java.log('trace');
        var device = '';
        try { device = java.deviceID(); } catch (e) { device = java.androidId(); }
        source.putLoginHeader('Cookie:deviceId=' + device);
        """)

        XCTAssertNil(engine.lastError)
        XCTAssertEqual(header?.hasPrefix("Cookie:deviceId="), true)
        XCTAssertGreaterThan(header?.count ?? 0, "Cookie:deviceId=".count, "deviceID 不该是空串")
    }

    /// 聚合源把正文以 hex 回传，脚本第一件事就是解它，解不出来正文就是空的。
    func testHexDecodeToString() throws {
        let engine = JSEngine()
        XCTAssertEqual(engine.eval(script: "java.hexDecodeToString('7b2261223a317d')") as? String, "{\"a\":1}")
        XCTAssertEqual(engine.eval(script: "java.hexDecodeToString('nothex')") as? String, "nothex")
    }
}
