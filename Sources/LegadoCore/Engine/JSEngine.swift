import Foundation
import JavaScriptCore
import SwiftSoup
import CommonCrypto

@objc public protocol JavaShimProtocol: JSExport {
    func ajax(_ url: String) -> String
    func connect(_ url: String) -> JSValue
    func connect(_ url: String, _ header: String) -> JSValue
    func post(_ url: String, _ body: String, _ header: JSValue) -> JSValue
    func get(_ key: String) -> String?
    func put(_ key: String, _ value: String) -> String
    func md5Encode(_ str: String) -> String
    func base64Encode(_ str: String) -> String
    func base64Decode(_ str: String) -> String
    func timeFormat(_ timestamp: JSValue) -> String
    func getString(_ path: String) -> String
    func jsonPath(_ json: String, _ path: String) -> JSValue
    func toast(_ message: String)
    func longToast(_ message: String)
    func log(_ message: JSValue)
    func deviceID() -> String
    func androidId() -> String
    func getWebViewUA() -> String
    func getCookie(_ url: String) -> String
    func refreshExplore()
    func hexDecodeToString(_ hex: String) -> String
    // Rhino 的 Java 互操作适配，聚合源依赖这几个：
    func base64EncodeBytes(_ bytes: JSValue) -> String
    func sleepMs(_ ms: JSValue)
    func createSymmetricCrypto(_ transformation: String, _ key: String) -> JSValue
    func createSymmetricCrypto(_ transformation: String, _ key: String, _ iv: String) -> JSValue
    // 需要弹浏览器的方法：注册 / 用户后台 / 教程 / 发布页 / 番茄登录 / 打赏
    func startBrowser(_ url: String, _ title: String)
    func startBrowserAwait(_ url: String, _ title: String) -> JSValue
    func startBrowserAwait(_ url: String, _ title: String, _ wait: Bool) -> JSValue
    func startBrowserDp(_ url: String, _ title: String)
    func showBrowser(_ url: String, _ title: String)
    func showReadingBrowser(_ url: String, _ title: String)
    /// `cache.remove(key)`
    func removeCache(_ key: String)
}

/// 脚本要弹浏览器的请求。
///
/// `java.startBrowserAwait(url, title)` 是同步调用：宿主阻塞脚本线程，等网页关闭后把
/// 最终 HTML 和 URL 交回去。Core 只发请求，弹窗由 App 层注册 handler 实现。
/// 脚本里的 `java.toast` / `java.longToast` 也走这里。
///
/// 宿主不接 handler 时只写日志，界面上没有反馈。
public final class ScriptToast {
    public static let shared = ScriptToast()
    public var handler: ((String) -> Void)?
    private init() {}
}

public final class ScriptBrowser {
    public static let shared = ScriptBrowser()

    /// 返回最终页面 HTML 与 URL，拿不到时返回空串。
    public var present: ((String, String, Bool) -> (body: String, url: String))?

    private init() {}
}

@objc public class JavaShim: NSObject, JavaShimProtocol {
    /// `cache` / `java.put`/`java.get` 的存储。
    ///
    /// 脚本把登录态、段评正文、临时标记放这儿，一个引擎跑一次、下一次点按钮又是新引擎，
    /// 所以必须跨引擎共享（安卓那边是 app 级缓存）。进程内共享，退出即清。
    private static var sharedStore: [String: String] = [:]
    private static let storeLock = NSLock()
    private let lock = NSLock()
    private weak var jsContext: JSContext?
    /// 书源声明的响应时间。聚合源给到 180s，默认 15s 会先超时。
    var respondTimeout: TimeInterval?
    /// 脚本里的同步请求也要吃书源的 concurrentRate，否则规则脚本会绕过限速。
    var rateKey: String?
    var rateLimit: SourceRateLimit?

    public init(context: JSContext?) {
        self.jsContext = context
        super.init()
    }

    /// 书源脚本用 cookie.setCookie 存下来的登录态，请求时自动带上。
    private func jarCookieHeader(for url: String) -> String {
        let cookies = CookieJar.shared.cookieString(for: url)
        return cookies.isEmpty ? "" : "Cookie: \(cookies)"
    }

    public func ajax(_ url: String) -> String {
        guard let parsed = NetworkClient.parseLegadoUrl(url, defaultHeader: jarCookieHeader(for: url)) else { return "" }
        let resp = NetworkClient.shared.requestSync(
            parsed: parsed,
            timeout: respondTimeout ?? 15,
            rateKey: rateKey,
            rateLimit: rateLimit
        )
        return resp?.bodyString ?? ""
    }

    public func connect(_ url: String) -> JSValue {
        return connect(url, jarCookieHeader(for: url))
    }

    public func connect(_ url: String, _ header: String) -> JSValue {
        guard let ctx = jsContext else {
            return JSValue(undefinedIn: JSContext())
        }
        guard let parsed = NetworkClient.parseLegadoUrl(url, defaultHeader: header) else {
            return JSValue(nullIn: ctx)
        }
        let resp = NetworkClient.shared.requestSync(
            parsed: parsed,
            timeout: respondTimeout ?? 15,
            rateKey: rateKey,
            rateLimit: rateLimit
        )
        let body = resp?.bodyString ?? ""
        let code = resp?.statusCode ?? 0

        let resultObj = JSValue(newObjectIn: ctx)
        let bodyBlock: @convention(block) () -> String = { body }
        let codeBlock: @convention(block) () -> Int = { code }
        let urlBlock: @convention(block) () -> String = { url }
        resultObj?.setValue(bodyBlock, forProperty: "body")
        resultObj?.setValue(codeBlock, forProperty: "statusCode")
        resultObj?.setValue(urlBlock, forProperty: "url")
        resultObj?.setValue(body, forProperty: "text")
        return resultObj ?? JSValue(nullIn: ctx)
    }

    public func post(_ url: String, _ body: String, _ header: JSValue) -> JSValue {
        guard let ctx = jsContext else {
            return JSValue(undefinedIn: JSContext())
        }

        var headerDict: [String: String] = [:]
        if header.isObject || header.isString {
            if let dict = header.toDictionary() as? [String: Any] {
                for (k, v) in dict {
                    headerDict[k] = "\(v)"
                }
            } else if let str = header.toString(), let data = str.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in dict {
                    headerDict[k] = "\(v)"
                }
            }
        }

        if headerDict["Content-Type"] == nil {
            headerDict["Content-Type"] = "application/json"
        }
        if headerDict["Cookie"] == nil, headerDict["cookie"] == nil {
            let jar = CookieJar.shared.cookieString(for: url)
            if !jar.isEmpty { headerDict["Cookie"] = jar }
        }

        let bodyData = body.data(using: .utf8)
        guard let cleanUrl = URL(string: url) ?? URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url) else {
            return JSValue(nullIn: ctx)
        }

        let parsed = NetworkClient.ParsedRequest(url: cleanUrl, method: "POST", headers: headerDict, body: bodyData)
        let resp = NetworkClient.shared.requestSync(
            parsed: parsed,
            timeout: respondTimeout ?? 15,
            rateKey: rateKey,
            rateLimit: rateLimit
        )
        let respBody = resp?.bodyString ?? ""
        let respCode = resp?.statusCode ?? 0

        let resultObj = JSValue(newObjectIn: ctx)
        let bodyBlock: @convention(block) () -> String = { respBody }
        let codeBlock: @convention(block) () -> Int = { respCode }
        let urlBlock: @convention(block) () -> String = { url }
        resultObj?.setValue(bodyBlock, forProperty: "body")
        resultObj?.setValue(codeBlock, forProperty: "statusCode")
        resultObj?.setValue(urlBlock, forProperty: "url")
        resultObj?.setValue(respBody, forProperty: "text")
        return resultObj ?? JSValue(nullIn: ctx)
    }

    public func get(_ key: String) -> String? {
        Self.storeLock.lock()
        defer { Self.storeLock.unlock() }
        return Self.sharedStore[key]
    }

    // MARK: - 脚本杂项调用
    //
    // 脚本默认这些接口存在：longToast、deviceID、androidId。缺一个就抛 TypeError。

    public func toast(_ message: String) {
        LegadoLog.log("[toast] \(message)")
        ScriptToast.shared.handler?(message)
    }

    public func longToast(_ message: String) {
        LegadoLog.log("[toast] \(message)")
        ScriptToast.shared.handler?(message)
    }

    public func log(_ message: JSValue) {
        LegadoLog.log("[js] \(message.toString() ?? "")")
    }

    public func deviceID() -> String {
        Self.persistentDeviceID()
    }

    public func androidId() -> String {
        Self.persistentDeviceID()
    }

    /// 脚本自己拼 header 时要一个 WebView 的 UA（聚合源的 69书吧分支用它）。
    public func getWebViewUA() -> String {
        NetworkClient.defaultUserAgent
    }

    /// 有的源把 `java.getCookie` 当 `cookie.getCookie` 的兜底（`|| java.getCookie(url)`）。
    public func getCookie(_ url: String) -> String {
        CookieJar.shared.cookieString(for: url)
    }

    /// 脚本改完设置（换服务器、设置中心结果）会调它，安卓那边是刷新分类页。
    /// 分类缓存本身按「exploreUrl + 源变量」做签名，变量一变下次解析就是新的，
    /// 这里只负责让界面重新拉一遍。
    public func refreshExplore() {
        JSEngine.exploreRefreshSink?()
    }

    /// 正文常以 hex 字符串回传。
    public func hexDecodeToString(_ hex: String) -> String {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2, cleaned.count % 2 == 0 else { return cleaned }

        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return cleaned }
            bytes.append(byte)
            index = next
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Rhino / Java 互操作适配
    //
    // 聚合源用了 JavaImporter、with(javaImport)、Packages.android.util.Base64、
    // java.createSymmetricCrypto 这些 Rhino 能力，这里按语义近似实现。

    /// `Packages.android.util.Base64.encodeToString(bytes, flags)`
    /// flags=2 对应 Android 的 NO_WRAP，即标准 base64，不带换行。
    public func base64EncodeBytes(_ bytes: JSValue) -> String {
        Data(Self.byteArray(from: bytes)).base64EncodedString()
    }

    /// `Packages.java.lang.Thread.sleep(ms)`，脚本用它等待异步、限速。
    public func sleepMs(_ ms: JSValue) {
        let value = ms.isNumber ? ms.toInt32() : (Int32(ms.toString() ?? "0") ?? 0)
        let clamped = max(0, min(value, 10_000))
        if clamped > 0 { Thread.sleep(forTimeInterval: Double(clamped) / 1000.0) }
    }

    public func createSymmetricCrypto(_ transformation: String, _ key: String) -> JSValue {
        makeCrypto(transformation: transformation, key: key, iv: nil)
    }

    public func createSymmetricCrypto(_ transformation: String, _ key: String, _ iv: String) -> JSValue {
        makeCrypto(transformation: transformation, key: key, iv: iv)
    }

    /// 只写算法名（"AES"）时按 BouncyCastle 惯例补成 `<算法>/ECB/PKCS5Padding`；
    /// 密钥和 IV 按 UTF-8 取字节。
    private func makeCrypto(transformation: String, key: String, iv: String?) -> JSValue {
        guard let ctx = jsContext else { return JSValue(undefinedIn: JSContext()) }
        let parts = transformation.uppercased().split(separator: "/").map(String.init)
        let algorithm = parts.first ?? "AES"
        let mode = parts.count > 1 ? parts[1] : "ECB"
        let keyData = Data(key.utf8)
        let ivData = iv.map { Data($0.utf8) }

        let encrypt: @convention(block) (JSValue) -> JSValue = { [weak self] input in
            let plain = Self.byteArray(from: input)
            let out = Self.symmetric(algorithm: algorithm, mode: mode, key: keyData,
                                     iv: ivData, input: plain, encrypt: true) ?? []
            return self?.jsArray(out) ?? JSValue(undefinedIn: ctx)
        }
        let decrypt: @convention(block) (JSValue) -> JSValue = { [weak self] input in
            let cipher = Self.byteArray(from: input)
            let out = Self.symmetric(algorithm: algorithm, mode: mode, key: keyData,
                                     iv: ivData, input: cipher, encrypt: false) ?? []
            return self?.jsArray(out) ?? JSValue(undefinedIn: ctx)
        }
        let encryptBase64: @convention(block) (JSValue) -> JSValue = { [weak ctx] input in
            let plain = Self.byteArray(from: input)
            let out = Self.symmetric(algorithm: algorithm, mode: mode, key: keyData,
                                     iv: ivData, input: plain, encrypt: true) ?? []
            return JSValue(object: Data(out).base64EncodedString(), in: ctx)
        }
        let decryptBase64: @convention(block) (JSValue) -> JSValue = { [weak self, weak ctx] input in
            let raw = input.toString() ?? ""
            let cipher = [UInt8](Data(base64Encoded: raw) ?? Data())
            let out = Self.symmetric(algorithm: algorithm, mode: mode, key: keyData,
                                     iv: ivData, input: cipher, encrypt: false) ?? []
            return self?.jsArray(out) ?? JSValue(undefinedIn: ctx)
        }
        let obj: [String: Any] = [
            "encrypt": encrypt,
            "decrypt": decrypt,
            "encryptBase64": encryptBase64,
            "decryptBase64": decryptBase64
        ]
        return JSValue(object: obj, in: ctx)
    }

    private func jsArray(_ bytes: [UInt8]) -> JSValue {
        let ctx = jsContext ?? JSContext()
        return JSValue(object: bytes.map { Int($0) }, in: ctx)
    }

    /// 入参是 [Int] 数组或字符串，字符串按 UTF-8 取字节。
    static func byteArray(from value: JSValue) -> [UInt8] {
        if let text = value.toString(), !value.isArray { return [UInt8](text.utf8) }
        if let array = value.toArray() {
            return array.compactMap { item in
                if let n = item as? NSNumber { return UInt8(truncatingIfNeeded: n.intValue) }
                if let n = item as? Int { return UInt8(truncatingIfNeeded: n) }
                return nil
            }
        }
        return []
    }

    /// AES/DES 的 ECB 与 CBC，PKCS5 按 PKCS7 处理
    static func symmetric(
        algorithm: String, mode: String, key: Data, iv: Data?, input: [UInt8], encrypt: Bool
    ) -> [UInt8]? {
        guard !input.isEmpty else { return [] }
        let ccAlgorithm: CCAlgorithm
        switch algorithm {
        case "AES": ccAlgorithm = CCAlgorithm(kCCAlgorithmAES)
        case "DES": ccAlgorithm = CCAlgorithm(kCCAlgorithmDES)
        case "DESEDE", "3DES": ccAlgorithm = CCAlgorithm(kCCAlgorithm3DES)
        default: return nil
        }
        let operation = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
        let options = CCOptions(mode == "CBC" ? 0 : kCCOptionECBMode)
        var outLength = 0
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        let status = iv?.withUnsafeBytes { ivBytes -> CCCryptorStatus in
            key.withUnsafeBytes { keyBytes in
                input.withUnsafeBytes { inputBytes in
                    CCCrypt(operation, ccAlgorithm, options,
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress, input.count,
                            &out, out.count, &outLength)
                }
            }
        } ?? key.withUnsafeBytes { keyBytes in
            input.withUnsafeBytes { inputBytes in
                CCCrypt(operation, ccAlgorithm, options,
                        keyBytes.baseAddress, key.count,
                        nil,
                        inputBytes.baseAddress, input.count,
                        &out, out.count, &outLength)
            }
        }
        guard status == kCCSuccess else { return nil }
        return Array(out.prefix(outLength))
    }

    // MARK: - 脚本要弹浏览器

    /// 删缓存键
    public func removeCache(_ key: String) {
        Self.storeLock.lock()
        defer { Self.storeLock.unlock() }
        Self.sharedStore.removeValue(forKey: key)
    }

    /// 不问结果，把网址交给宿主打开。
    public func startBrowser(_ url: String, _ title: String) {
        _ = ScriptBrowser.shared.present?(url, title, false)
    }

    /// 要拿用户操作后的页面内容（注册、书源设置中心、番茄登录）。
    /// 等待靠阻塞脚本线程实现，调用方不能是主线程。
    public func startBrowserAwait(_ url: String, _ title: String) -> JSValue {
        browserResult(url: url, title: title, wait: true)
    }

    /// 第三个参数只为对齐安卓签名保留，语义上当作「等」处理。
    ///
    /// `Await` 的契约就是等用户关网页再把最终 HTML / URL 交回去。书源的设置中心靠返回值
    /// 读结果（`readSettingsResultFromBody(browserResult.body())`），传 false 也照等；
    /// 按参数立刻返回空 body 的话，脚本必然走到「未读取到设置结果」。
    public func startBrowserAwait(_ url: String, _ title: String, _ wait: Bool) -> JSValue {
        browserResult(url: url, title: title, wait: true)
    }

    // 安卓同类接口，语义相同，走同一个宿主入口
    public func startBrowserDp(_ url: String, _ title: String) {
        _ = ScriptBrowser.shared.present?(url, title, false)
    }

    public func showBrowser(_ url: String, _ title: String) {
        _ = ScriptBrowser.shared.present?(url, title, false)
    }

    public func showReadingBrowser(_ url: String, _ title: String) {
        _ = ScriptBrowser.shared.present?(url, title, false)
    }

    private func browserResult(url: String, title: String, wait: Bool) -> JSValue {
        let ctx = jsContext ?? JSContext()
        guard let result = ScriptBrowser.shared.present?(url, title, wait) else {
            let empty = JSValue(newObjectIn: ctx) ?? JSValue(nullIn: ctx)
            let emptyBody: @convention(block) () -> String = { "" }
            empty?.setValue(emptyBody, forProperty: "body")
            empty?.setValue("", forProperty: "bodyString")
            empty?.setValue(url, forProperty: "url")
            empty?.setValue(0, forProperty: "code")
            return empty ?? JSValue(nullIn: ctx)
        }
        // 安卓契约是 `java.startBrowserAwait(...).body()`，body 必须是方法；
        // 同时给一份 bodyString 方便原生侧读取。
        let obj = JSValue(newObjectIn: ctx) ?? JSValue(nullIn: ctx)
        let finalUrl = result.url.isEmpty ? url : result.url
        let bodyBlock: @convention(block) () -> String = { result.body }
        obj?.setValue(bodyBlock, forProperty: "body")
        obj?.setValue(result.body, forProperty: "bodyString")
        obj?.setValue(finalUrl, forProperty: "url")
        obj?.setValue(200, forProperty: "code")
        return obj ?? JSValue(nullIn: ctx)
    }

    private static func persistentDeviceID() -> String {
        let key = "legado.scriptDeviceID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    public func put(_ key: String, _ value: String) -> String {
        Self.storeLock.lock()
        defer { Self.storeLock.unlock() }
        Self.sharedStore[key] = value
        return value
    }

    public func md5Encode(_ str: String) -> String {
        return CryptoUtils.md5(str)
    }

    public func base64Encode(_ str: String) -> String {
        return CryptoUtils.base64Encode(str)
    }

    public func base64Decode(_ str: String) -> String {
        return CryptoUtils.base64Decode(str)
    }

    public func timeFormat(_ timestamp: JSValue) -> String {
        var num = timestamp.toNumber()?.doubleValue ?? 0
        if num == 0, let str = timestamp.toString(), let d = Double(str) {
            num = d
        }
        guard num > 0 else { return "" }
        if num > 10_000_000_000 {
            num /= 1000
        }
        let date = Date(timeIntervalSince1970: num)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    public func getString(_ path: String) -> String {
        guard let ctx = jsContext, let resVal = ctx.objectForKeyedSubscript("result" as NSString) else {
            return ""
        }
        if resVal.isObject {
            let cleanKey = path.replacingOccurrences(of: "$.", with: "").replacingOccurrences(of: "$", with: "")
            if let prop = resVal.forProperty(cleanKey), !prop.isUndefined && !prop.isNull {
                return prop.toString() ?? ""
            }
            if let dict = resVal.toDictionary() {
                if let evaluated = JSONPath.evaluate(path: path, json: dict) {
                    return "\(evaluated)"
                }
            }
        }
        let jsonStr = resVal.toString() ?? ""
        if let data = jsonStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: []),
           let evaluated = JSONPath.evaluate(path: path, json: obj) {
            return "\(evaluated)"
        }
        return ""
    }

    public func jsonPath(_ json: String, _ path: String) -> JSValue {
        let ctx = jsContext ?? JSContext()
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let result = JSONPath.evaluate(path: path, json: object) else {
            return JSValue(nullIn: ctx)
        }
        return JSValue(object: result, in: ctx) ?? JSValue(nullIn: ctx)
    }
}

public class JSEngine {
    public let context: JSContext
    private let javaShim: JavaShim
    /// 当前这本书。脚本读写 `book.getVariable` / `book.setUseReplaceRule` 都落在这份拷贝上，
    /// 改完通过 `bookUpdateSink` 交回 App 层落盘。
    private var book: Book?
    /// 暴露给脚本的 `book.readConfig`，改书写回时也要同步它，否则同一引擎里读到旧值
    private var bookReadConfig: JSValue?
    /// 脚本 `source.setVariable(...)` 写进的状态往哪送。
    ///
    /// 聚合源把「当前服务器」「设置中心结果」「token」全放在书源 variable 里（`setArgument`
    /// 就是读写它）。不写回书源的话，每次点击都从旧值重算：切服务器永远停在同一台，
    /// 设置中心改了下次打开又回到原样。Core 不认识书源仓库，和 LegadoLog 一样由 App 层注入。
    public static var variableSink: ((_ bookSourceUrl: String, _ variable: String) -> Void)?
    /// 脚本改写了「当前这本书」的状态（书级变量、是否替换净化）就往这儿送一份，
    /// 由 App 层落盘。Core 不认识书架，跟 LegadoLog 一样注入。
    public static var bookUpdateSink: ((_ book: Book) -> Void)?
    /// 脚本调 `java.refreshExplore()`（安卓语义：刷新分类页）
    public static var exploreRefreshSink: (() -> Void)?
    public var onLoginHeaderUpdated: ((String) -> Void)?
    /// 脚本用 `source.putLoginInfo` 改写过的登录信息（聚合源把 token 存在这里）。
    public var onLoginInfoUpdated: ((String) -> Void)?
    /// 最近一次脚本异常，供调用方拿到原始错误信息。
    public private(set) var lastError: String?

    public init(bookSource: BookSource? = nil, baseUrl: String? = nil, book: Book? = nil) {
        self.context = JSContext()
        self.javaShim = JavaShim(context: context)
        self.book = book
        self.javaShim.rateKey = bookSource?.bookSourceUrl
        self.javaShim.rateLimit = bookSource?.rateLimit
        if let ms = bookSource?.respondTime, ms > 0 {
            javaShim.respondTimeout = min(180, max(10, TimeInterval(ms) / 1000))
        }

        setupEnvironment(bookSource: bookSource, baseUrl: baseUrl)

        // 注入书源自带的 jsLib（getArguments、加解密等助手）。
        // 正文、搜索、登录脚本直接调这些函数，不注入就 ReferenceError。
        if let lib = bookSource?.jsLib, !lib.isEmpty {
            // 只注一次：jsLib 里有 const 声明，重复注入 JSC 报 duplicate variable。
            if context.objectForKeyedSubscript("__legadoJsLibLoaded")?.toBool() != true {
                _ = eval(script: JSEngine.unwrapJsScript(lib))
                let ok = lastError == nil
                context.setObject(ok, forKeyedSubscript: "__legadoJsLibLoaded" as NSString)
                // jsLib 自身报错另行记录，不算业务脚本错误
                if !ok {
                    LegadoLog.log("[JS] jsLib 注入失败：\(lastError ?? "")")
                    lastError = nil
                }
            }
        }
    }

    private func setupEnvironment(bookSource: BookSource?, baseUrl: String?) {
        // Exception handler
        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "unknown error"
            self?.lastError = message
            // 未捕获异常统一进诊断日志
            LegadoLog.log("[JS] \(message)")
            #if DEBUG
            print("[JSEngine Error] \(message)")
            #endif
        }

        // Expose java shim
        context.setObject(javaShim, forKeyedSubscript: "java" as NSString)

        // Expose source object
        let sourceObj = JSValue(newObjectIn: context)
        var loginHeader: String? = bookSource?.loginHeader ?? bookSource?.header
        var loginInfoStr: String? = bookSource?.loginInfo
        var variableStr: String? = bookSource?.variable

        let getLoginHeaderBlock: @convention(block) () -> String? = { loginHeader }
        let putLoginHeaderBlock: @convention(block) (String) -> Void = { [weak self] newH in
            loginHeader = newH
            self?.onLoginHeaderUpdated?(newH)
        }
        let getLoginInfoBlock: @convention(block) () -> String? = { loginInfoStr }
        let putLoginInfoBlock: @convention(block) (String) -> Void = { [weak self] newInfo in
            loginInfoStr = newInfo
            self?.onLoginInfoUpdated?(newInfo)
        }
        let getVariableBlock: @convention(block) () -> String = { variableStr ?? "" }
        let setVariableBlock: @convention(block) (String) -> Void = { newV in
            variableStr = newV
            JSEngine.variableSink?(bookSource?.bookSourceUrl ?? "", newV)
        }

        let getLoginInfoMapBlock: @convention(block) () -> JSValue = { [weak self] in
            guard let ctx = self?.context else { return JSValue(nullIn: JSContext()) }
            let mapObj = JSValue(newObjectIn: ctx)
            if let info = loginInfoStr, let data = info.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in dict {
                    mapObj?.setValue(v, forProperty: k)
                }
            }
            let getBlock: @convention(block) (String) -> String = { key in
                return mapObj?.forProperty(key)?.toString() ?? ""
            }
            mapObj?.setValue(getBlock, forProperty: "get")
            return mapObj ?? JSValue(newObjectIn: ctx)
        }

        sourceObj?.setValue(getLoginHeaderBlock, forProperty: "getLoginHeader")
        sourceObj?.setValue(putLoginHeaderBlock, forProperty: "putLoginHeader")
        sourceObj?.setValue(getLoginInfoBlock, forProperty: "getLoginInfo")
        sourceObj?.setValue(putLoginInfoBlock, forProperty: "putLoginInfo")
        sourceObj?.setValue(getLoginInfoMapBlock, forProperty: "getLoginInfoMap")
        sourceObj?.setValue(getVariableBlock, forProperty: "getVariable")
        sourceObj?.setValue(setVariableBlock, forProperty: "setVariable")
        let sourcePutBlock: @convention(block) (String, String) -> String = { [weak javaShim] key, value in
            javaShim?.put(key, value) ?? value
        }
        let sourceGetBlock: @convention(block) (String) -> String = { [weak javaShim] key in
            javaShim?.get(key) ?? ""
        }
        let sourceRemoveBlock: @convention(block) (String) -> Void = { [weak javaShim] key in
            javaShim?.removeCache(key)
        }
        sourceObj?.setValue(sourcePutBlock, forProperty: "put")
        sourceObj?.setValue(sourceGetBlock, forProperty: "get")
        sourceObj?.setValue(sourceRemoveBlock, forProperty: "remove")
        sourceObj?.setValue(bookSource?.loginUrl ?? "", forProperty: "loginUrl")
        // 脚本用它做缓存键：cache.put(`userInfo_${source.getKey()}`, ...)
        let getKeyBlock: @convention(block) () -> String = { bookSource?.bookSourceUrl ?? "" }
        sourceObj?.setValue(getKeyBlock, forProperty: "getKey")
        sourceObj?.setValue(bookSource?.bookSourceUrl ?? "", forProperty: "bookSourceUrl")
        sourceObj?.setValue(bookSource?.bookSourceName ?? "", forProperty: "bookSourceName")

        context.setObject(sourceObj, forKeyedSubscript: "source" as NSString)

        // cookie API，脚本用它存登录态，缺了这个全局对象会 ReferenceError。
        let cookieObj = JSValue(newObjectIn: context)
        let getCookieBlock: @convention(block) (String) -> String = { url in
            CookieJar.shared.cookieString(for: url)
        }
        let setCookieBlock: @convention(block) (String, String) -> Void = { url, value in
            CookieJar.shared.setCookies(value, for: url)
        }
        let removeCookieBlock: @convention(block) (String) -> Void = { url in
            CookieJar.shared.remove(for: url)
        }
        let getCookieKeyBlock: @convention(block) (String, String) -> String = { url, name in
            CookieJar.shared.value(for: url, name: name) ?? ""
        }
        cookieObj?.setValue(getCookieBlock, forProperty: "getCookie")
        cookieObj?.setValue(setCookieBlock, forProperty: "setCookie")
        cookieObj?.setValue(removeCookieBlock, forProperty: "removeCookie")
        cookieObj?.setValue(getCookieKeyBlock, forProperty: "getKey")
        context.setObject(cookieObj, forKeyedSubscript: "cookie" as NSString)

        // Expose book object
        let bookObj = JSValue(newObjectIn: context)
        bookObj?.setValue(book?.name ?? "", forProperty: "name")
        bookObj?.setValue(book?.author ?? "", forProperty: "author")
        bookObj?.setValue(book?.bookUrl ?? "", forProperty: "bookUrl")
        bookObj?.setValue(book?.durChapterIndex ?? 0, forProperty: "durChapterIndex")
        bookObj?.setValue(book?.durChapterTitle ?? "", forProperty: "durChapterTitle")
        bookObj?.setValue(book?.totalChapterNum ?? 0, forProperty: "totalChapterNum")
        bookObj?.setValue(bookSource?.bookSourceUrl ?? book?.origin ?? "", forProperty: "origin")

        // book.readConfig：源会读 `book.readConfig.useReplaceRule`，null 表示「还没记过」
        let readConfigObj = JSValue(newObjectIn: context)
        bookReadConfig = readConfigObj
        if let useReplace = book?.useReplaceRule {
            readConfigObj?.setValue(useReplace, forProperty: "useReplaceRule")
        } else {
            readConfigObj?.setValue(JSValue(nullIn: context), forProperty: "useReplaceRule")
        }
        bookObj?.setValue(readConfigObj, forProperty: "readConfig")

        let getBookVarBlock: @convention(block) (String) -> String = { [weak self] key in
            self?.bookVariable(key) ?? ""
        }
        let setBookVarBlock: @convention(block) (String, String) -> Void = { [weak self] key, value in
            self?.setBookVariable(key, value)
        }
        let getUseReplaceRuleBlock: @convention(block) () -> JSValue = { [weak self] in
            guard let ctx = self?.context else { return JSValue(nullIn: JSContext()) }
            guard let flag = self?.book?.useReplaceRule else { return JSValue(nullIn: ctx) }
            return JSValue(object: flag, in: ctx)
        }
        let setUseReplaceRuleBlock: @convention(block) (Bool) -> Void = { [weak self] flag in
            self?.setUseReplaceRule(flag)
        }
        bookObj?.setValue(getBookVarBlock, forProperty: "getVariable")
        bookObj?.setValue(setBookVarBlock, forProperty: "setVariable")
        bookObj?.setValue(getUseReplaceRuleBlock, forProperty: "getUseReplaceRule")
        bookObj?.setValue(setUseReplaceRuleBlock, forProperty: "setUseReplaceRule")
        context.setObject(bookObj, forKeyedSubscript: "book" as NSString)

        if let baseUrl = baseUrl {
            context.setObject(baseUrl, forKeyedSubscript: "baseUrl" as NSString)
        }

        // Compatibility polyfills
        context.evaluateScript("""
        var console = {
            log: function(msg) { },
            error: function(msg) { }
        };
        function format(str) { return Array.isArray(str) ? str.join('\\n\\n') : (str || ''); }
        function regex(str) { return str || ''; }
        function annotate(text, kanji) { return text || ''; }
        function update(url, token) { }
        """)

        // Rhino 的 Java 互操作壳：JavaImporter、with(javaImport)、importClass、
        // Packages.android.util.Base64、Packages.java.lang.Thread.sleep。
        // JSC 没有这些全局，缺了脚本会 ReferenceError。
        context.evaluateScript("""
        var JavaImporter = function(){ return { importClass: function(){}, importPackage: function(){} }; };
        var importClass = function(){};
        var importPackage = function(){};
        var Packages = {
          android: { util: { Base64: { encodeToString: function(bytes, flags){ return java.base64EncodeBytes(bytes); } } } },
          java: { lang: { Thread: { sleep: function(ms){ java.sleepMs(ms); } } } },
          io: { legato: { kazusa: { utils: { TimeoutCancellationException: function(message){ this.message = message; this.name = 'TimeoutCancellationException'; } } } } }
        };
        var com = {
          jayway: {
            jsonpath: {
              JsonPath: {
                read: function(json, path){ return java.jsonPath(String(json), String(path)); },
                parse: function(json){
                  return { read: function(path){ return java.jsonPath(String(json), String(path)); } };
                }
              }
            }
          }
        };
        if (!java.refreshExplore) { java.refreshExplore = function(){}; }

        // 全局 cache，脚本用它存登录态等短期数据（cache.put('userInfo_xxx', ...)），
        // 安卓由宿主提供。
        var cache = {
          put: function(key, value){ java.put(String(key), String(value)); },
          get: function(key){ var v = java.get(String(key)); return (v === undefined || v === null) ? '' : v; },
          remove: function(key){ java.removeCache(String(key)); }
        };
        """)
        context.exception = nil
    }

    // MARK: - 书对象

    /// `book.getVariable(key)`：读书级变量（存在 Book.variable 的 JSON 里）。
    /// 没有这个键就返回空串，源里一般写成 `String(book.getVariable('custom'))`。
    private func bookVariable(_ key: String) -> String {
        guard let dict = Self.bookVariableDict(from: book?.variable),
              let value = dict[key] else { return "" }
        return "\(value)"
    }

    /// `book.setVariable(key, value)`：写书级变量，写完交回宿主落盘。
    private func setBookVariable(_ key: String, _ value: String) {
        guard var current = book else { return }
        var dict = Self.bookVariableDict(from: current.variable) ?? [:]
        dict[key] = value
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        current.variable = text
        book = current
        JSEngine.bookUpdateSink?(current)
    }

    /// `book.setUseReplaceRule(false)`：这本书用不用替换净化。安卓拿它决定正文要不要净化，
    /// 聚合源自己清理过正文，会主动关掉。
    private func setUseReplaceRule(_ flag: Bool) {
        guard var current = book else { return }
        current.useReplaceRule = flag
        book = current
        bookReadConfig?.setValue(flag, forProperty: "useReplaceRule")
        JSEngine.bookUpdateSink?(current)
    }

    private static func bookVariableDict(from raw: String?) -> [String: Any]? {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 跑规则脚本，外面套一层块级作用域。
    ///
    /// 书源的规则脚本会被反复执行（列表里每本书跑一次），脚本里写了顶层 `let` / `const`
    /// 的话，第二次就会抛 `Can't create duplicate variable`，整页解析全废。
    /// 套成 `{ … }` 之后每次是一份新的块作用域，返回值照旧是最后一条语句的值。
    public func evalRule(script: String, result: Any? = nil) -> Any? {
        eval(script: "{ \(script)\n}", result: result)
    }

    /// Evaluates a JavaScript snippet with optional `result` value
    public func eval(script: String, result: Any? = nil) -> Any? {
        if let result = result {
            context.setObject(JSEngine.jsSafeValue(result), forKeyedSubscript: "result" as NSString)
        }
        let val = context.evaluateScript(script)
        if let exception = context.exception {
            lastError = exception.toString()
            context.exception = nil
        }
        if val?.isUndefined == true || val?.isNull == true {
            return nil
        }
        if val?.isString == true {
            return val?.toString()
        }
        if val?.isNumber == true {
            return val?.toNumber()
        }
        if val?.isBoolean == true {
            return val?.toBool()
        }
        if val?.isArray == true {
            return val?.toArray()
        }
        if val?.isObject == true {
            return val?.toDictionary()
        }
        return val?.toObject()
    }

    /// Evaluates template strings containing `{{ ... }}`
    public func renderTemplate(_ text: String, variables: [String: Any] = [:]) -> String {
        for (k, v) in variables {
            context.setObject(JSEngine.jsSafeValue(v), forKeyedSubscript: k as NSString)
        }

        var result = text
        let pattern = "\\{\\{(.*?)\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }

        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

        for match in matches.reversed() {
            let fullRange = match.range
            let innerRange = match.range(at: 1)
            let expression = nsString.substring(with: innerRange).trimmingCharacters(in: .whitespacesAndNewlines)

            let evaluated = eval(script: expression)
            let replacement = evaluated != nil ? "\(evaluated!)" : ""
            result = (result as NSString).replacingCharacters(in: fullRange, with: replacement)
        }

        return result
    }

    /// JavaScriptCore can only bridge Objective-C classes. Handing it a Swift-only
    /// class (e.g. SwiftSoup.Element) aborts the process inside `classInfoForClass:`,
    /// so every value crossing into JS is converted here first.
    /// 剥掉规则里的 `<js>...</js>` 包裹和 `@js:` 前缀，loginUrl 与按钮 action 也带这层壳。
    public static func unwrapJsScript(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = text.range(of: "<js>"),
           let close = text.range(of: "</js>", options: .backwards),
           open.upperBound <= close.lowerBound {
            text = String(text[open.upperBound..<close.lowerBound])
        } else if text.hasPrefix("@js:") {
            text = String(text.dropFirst(4))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func jsSafeValue(_ value: Any) -> Any {
        switch value {
        case let js as JSValue:
            return js
        case let element as Element:
            return (try? element.outerHtml()) ?? ""
        case let elements as Elements:
            return elements.array().map { (try? $0.outerHtml()) ?? "" }
        case let string as String:
            return string
        case let number as NSNumber:
            return number
        case is NSNull:
            return NSNull()
        case let array as [Any]:
            return array.map { jsSafeValue($0) }
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = jsSafeValue(v) }
            return out
        default:
            return String(describing: value)
        }
    }
}
