import XCTest
@testable import LegadoCore

/// 导入书源走的是 JSONDecoder().decode([BookSource].self)。
/// 这里拿一份安卓 Legado 实际导出的书源 JSON 钉住解析，防止模型漂移导致「导入失败」。
final class BookSourceImportTests: XCTestCase {
    private let sampleJSON = """
    [
      {
        "bookSourceComment": "",
        "bookSourceGroup": "测试分组",
        "bookSourceName": "示例书源",
        "bookSourceType": 0,
        "bookSourceUrl": "https://example.com",
        "bookUrlPattern": "",
        "customOrder": 0,
        "enabled": true,
        "enabledExplore": true,
        "exploreUrl": "",
        "header": "",
        "lastUpdateTime": 0,
        "loginUrl": "",
        "respondTime": 180000,
        "searchUrl": "https://example.com/search?q={{key}}",
        "weight": 0,
        "ruleBookInfo": {"name": "class.name@text"},
        "ruleContent": {"content": "id.content@html"},
        "ruleExplore": {},
        "ruleSearch": {"bookList": "class.list@li", "name": "tag.a@text"},
        "ruleToc": {"chapterList": "id.list@li"}
      }
    ]
    """

    func testDecodeLegadoExport() throws {
        let data = try XCTUnwrap(sampleJSON.data(using: .utf8))
        let sources = try JSONDecoder().decode([BookSource].self, from: data)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.bookSourceUrl, "https://example.com")
        XCTAssertEqual(sources.first?.bookSourceName, "示例书源")
    }

    /// 真实书源包里同一个字段类型会飘：lastUpdateTime 有写数字的、有写字符串的，
    /// enabled 有 true / 1 / "true"。严格 decode 撞上一条会把整份文件判成失败。
    func testLenientNumericAndBoolFields() throws {
        let json = #"""
        [{
          "bookSourceUrl": "https://example.org",
          "bookSourceName": "宽松字段",
          "bookSourceType": "0",
          "customOrder": "2",
          "enabled": "true",
          "enabledExplore": 1,
          "lastUpdateTime": "1760000000000",
          "respondTime": 180000,
          "weight": "3"
        }]
        """#
        let data = try XCTUnwrap(json.data(using: .utf8))
        let sources = try JSONDecoder().decode([BookSource].self, from: data)
        let s = try XCTUnwrap(sources.first)
        XCTAssertEqual(s.bookSourceType, 0)
        XCTAssertEqual(s.customOrder, 2)
        XCTAssertEqual(s.enabled, true)
        XCTAssertEqual(s.enabledExplore, true)
        XCTAssertEqual(s.lastUpdateTime, 1_760_000_000_000)
        XCTAssertEqual(s.respondTime, 180_000)
        XCTAssertEqual(s.weight, 3)
    }
    /// 拿真实文件过一遍解析：设了 BS_FILE 环境变量就跑，没设就跳过（CI 不受影响）。
    /// 用法：BS_FILE=/tmp/bs_dahualang.json swift test --filter testDecodeRealFile
    func testDecodeRealFile() throws {
        guard let path = ProcessInfo.processInfo.environment["BS_FILE"] else {
            throw XCTSkip("未设置 BS_FILE，跳过")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let sources = try JSONDecoder().decode([BookSource].self, from: data)
        XCTAssertFalse(sources.isEmpty)
        for s in sources {
            print("解析成功:", s.bookSourceName, "|", s.bookSourceUrl,
                  "| loginUi 长度", s.loginUi?.count ?? 0,
                  "| 有 searchUrl", s.searchUrl != nil)
        }
    }

    /// jsLib / 事件监听 / CookieJar / 并发率这几个字段以前模型里根本没有，导入即丢。
    /// 大灰狼那类聚合源的助手函数（getArguments 等）全写在 jsLib 里。
    func testStructuredFieldsSurviveDecode() throws {
        let json = """
        [{"bookSourceUrl":"a","bookSourceName":"b",
          "jsLib":"function getArguments(v,k){return k}",
          "eventListener":true,"customButton":false,"enabledCookieJar":true,
          "concurrentRate":"1/1000"}]
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let s = try XCTUnwrap(try JSONDecoder().decode([BookSource].self, from: data).first)
        XCTAssertEqual(s.jsLib, "function getArguments(v,k){return k}")
        XCTAssertEqual(s.eventListener, true)
        XCTAssertEqual(s.customButton, false)
        XCTAssertEqual(s.enabledCookieJar, true)
        XCTAssertEqual(s.concurrentRate, "1/1000")
    }

    /// jsLib 必须真的注入 JS 上下文，否则脚本第一行就 ReferenceError。
    func testJsLibIsInjectedIntoContext() throws {
        let lib = "function getArguments(v, k) { return k === 'server' ? 'https://example.com' : ''; }"
        let source = BookSource(bookSourceUrl: "x", bookSourceName: "y", jsLib: lib)
        let engine = JSEngine(bookSource: source, baseUrl: "https://example.com")
        let out = engine.eval(script: "getArguments('', 'server')")
        XCTAssertEqual(out as? String, "https://example.com")
        XCTAssertNil(engine.lastError)
    }

    /// 聚合源的登录脚本探针：把网络桩掉，只跑脚本，看它还缺哪些宿主 API。
    /// 分类（发现）解析探针：聚合源的 exploreUrl 是一段 JS，看它到底解析成什么。
    /// 用法：BS_AGG=/tmp/bs_dahualang2.json swift test --filter testAggregateSourceCategories
    func testAggregateSourceCategories() async throws {
        guard let path = ProcessInfo.processInfo.environment["BS_AGG"] else {
            throw XCTSkip("未设置 BS_AGG，跳过")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let source = try XCTUnwrap(try JSONDecoder().decode([BookSource].self, from: data).first)
        let cats = BookExploreService.shared.parseExploreCategories(source: source)
        print("分类条数:", cats.count)
        for c in cats.prefix(12) {
            print("  -", c.title.prefix(40), "| url:", (c.url ?? "(无)").prefix(60))
        }

        // 那条「点一下执行脚本」的分类（url 里是 java.startBrowser）不该抛错，
        // 应该当动作执行完、返回空列表 —— 以前它会冒出一个「无法解析分类网址」的失败页。
        if let action = cats.first(where: { ($0.url ?? "").contains("startBrowser") }) {
            let books = try await BookExploreService.shared.fetchExploreBooks(
                source: source, categoryUrl: action.url ?? "")
            XCTAssertTrue(books.isEmpty, "动作类分类不该返回书，也不该抛错")
        } else {
            throw XCTSkip("这份源里没有动作类分类，跳过")
        }
    }

    /// 聚合源的登录脚本探针：把网络桩掉，只跑脚本，看它还缺哪些宿主 API。
    /// 用法：BS_AGG=/tmp/bs_dahualang2.json swift test --filter testAggregateSourceLoginSurface
    func testAggregateSourceLoginSurface() throws {
        guard let path = ProcessInfo.processInfo.environment["BS_AGG"] else {
            throw XCTSkip("未设置 BS_AGG，跳过")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let source = try XCTUnwrap(try JSONDecoder().decode([BookSource].self, from: data).first)
        XCTAssertNotNil(source.jsLib, "jsLib 没解出来")

        let engine = JSEngine(bookSource: source, baseUrl: "https://example.invalid")
        // 断网：ajax 直接回「登录成功」，让脚本走完整条成功路径
        // （写 cookie + cache.put + createSymmetricCrypto 缓存登录态都在这一段）
        _ = engine.eval(script: #"java.ajax = function(){ return '{"code":0,"key":"STUBKEY","msg":"ok"}'; };"#)
        _ = engine.eval(script: #"result = { '邮箱': 'stub@example.invalid', '密码': 'stub' };"#)
        // performLogin 的流程：先把 loginUrl 整段跑一遍（里面是各种函数定义），再调 login(true)
        _ = engine.eval(script: JSEngine.unwrapJsScript(source.loginUrl ?? ""))
        _ = engine.eval(script: "login(true)")

        if let e = engine.lastError { print("脚本报错:", e) }
        XCTAssertNil(engine.lastError, engine.lastError ?? "")
    }
}
