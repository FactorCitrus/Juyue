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
    func toast(_ message: String)
    func longToast(_ message: String)
    func log(_ message: JSValue)
    func deviceID() -> String
    func androidId() -> String
    func hexDecodeToString(_ hex: String) -> String
    // 下面这几个是给 Rhino 那套 Java 互操作做适配用的（聚合源大量依赖）：
    func base64EncodeBytes(_ bytes: JSValue) -> String
    func sleepMs(_ ms: JSValue)
    func createSymmetricCrypto(_ transformation: String, _ key: String) -> JSValue
    func createSymmetricCrypto(_ transformation: String, _ key: String, _ iv: String) -> JSValue
    // 需要弹浏览器的那些按钮：注册 / 用户后台 / 使用教程 / 永久发布页 / 番茄登录 / 打赏
    func startBrowser(_ url: String, _ title: String)
    func startBrowserAwait(_ url: String, _ title: String) -> JSValue
    func startBrowserAwait(_ url: String, _ title: String, _ wait: Bool) -> JSValue
    func startBrowserDp(_ url: String, _ title: String)
    func showBrowser(_ url: String, _ title: String)
    func showReadingBrowser(_ url: String, _ title: String)
    /// `cache.remove(key)`：脚本缓存登录态用的全局 cache 对象靠它删键
    func removeCache(_ key: String)
}

/// 脚本要弹浏览器的请求。
///
/// 书源的 `java.startBrowserAwait(url, title)` 要「打开网页 → 用户操作 → 关掉 → 脚本拿结果」，
/// 而 JS 是同步的：宿主必须能阻塞调用线程直到网页关闭。Core 层只负责发请求，
/// 真正弹窗由 App 层注册 handler 实现 —— Core 不依赖 UIKit，桌面端也能各自接。
public final class ScriptBrowser {
    public static let shared = ScriptBrowser()

    /// 参数：url、标题、是否等网页关闭。返回：最终页面 HTML 与 URL（拿不到就给空串）。
    public var present: ((String, String, Bool) -> (body: String, url: String))?

    private init() {}
}

@objc public class JavaShim: NSObject, JavaShimProtocol {
    private var kvStore: [String: String] = [:]
    private let lock = NSLock()
    private weak var jsContext: JSContext?

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
        let resp = NetworkClient.shared.requestSync(parsed: parsed)
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
        let resp = NetworkClient.shared.requestSync(parsed: parsed)
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
        let resp = NetworkClient.shared.requestSync(parsed: parsed)
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
        lock.lock()
        defer { lock.unlock() }
        return kvStore[key]
    }

    // MARK: - 脚本会顺手调用的杂项
    //
    // 这些看着不重要，但书源脚本把它们当默认存在的东西用：
    //   java.longToast("正在登录中...")   ← 登录函数第一行
    //   java.deviceID() / java.androidId()  ← 拼 cookie 用的设备指纹
    // 缺任何一个，脚本当场抛 TypeError，后面的登录逻辑一行都跑不到。

    public func toast(_ message: String) {
        LegadoLog.log("[toast] \(message)")
    }

    public func longToast(_ message: String) {
        LegadoLog.log("[toast] \(message)")
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

    /// 聚合源常把正文以 hex 字符串回传，脚本第一件事就是解它。
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
    // 安卓的 JS 引擎是 Rhino，聚合源的脚本大量用 Java 互操作：
    // `new JavaImporter()` + `with(javaImport){...}` / `Packages.android.util.Base64` /
    // `java.createSymmetricCrypto("AES", key).encrypt(bytes)`。JSC 里这些一个都没有，
    // 脚本第一行就 ReferenceError。这里把用到的那些按语义近似实现。

    /// `Packages.android.util.Base64.encodeToString(bytes, flags)`
    /// flags 里的 2 是 Android 的 NO_WRAP，正好等于标准 base64 不带换行。
    public func base64EncodeBytes(_ bytes: JSValue) -> String {
        Data(Self.byteArray(from: bytes)).base64EncodedString()
    }

    /// `Packages.java.lang.Thread.sleep(ms)` —— 脚本用它来等异步、限速。
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

    /// 只按安卓 BouncyCastle 的默认惯例来：只写算法名（"AES"）当作
    /// `<算法>/ECB/PKCS5Padding`；密钥和 IV 都按 UTF-8 取字节。
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

    /// 脚本传进来的可能是 [Int] 数组、也可能是字符串（按 UTF-8 取字节）。
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

    /// AES/DES 的 ECB / CBC(PKCS5=PKCS7) —— 就是 BouncyCastle 那几种默认写法
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

    /// 删缓存键（脚本的全局 cache 对象用）
    public func removeCache(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        kvStore.removeValue(forKey: key)
    }

    /// 不等结果：把网页交给宿主打开就行（教程、永久发布页这类）。
    public func startBrowser(_ url: String, _ title: String) {
        _ = ScriptBrowser.shared.present?(url, title, false)
    }

    /// 等结果：脚本要拿到用户操作后的页面内容（注册、书源设置中心、番茄登录这类）。
    /// “等”是同步阻塞当前脚本线程实现的 —— 所以调用它的脚本不能跑在主线程上，
    /// 登录面板那几个按钮走的是 Task，正好不占主线程。
    public func startBrowserAwait(_ url: String, _ title: String) -> JSValue {
        browserResult(url: url, title: title, wait: true)
    }

    public func startBrowserAwait(_ url: String, _ title: String, _ wait: Bool) -> JSValue {
        browserResult(url: url, title: title, wait: wait)
    }

    // 安卓侧的几个近亲，脚本里也在用；语义一样，都走同一个宿主入口
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
            return JSValue(object: ["url": url, "body": "", "code": 0], in: ctx)
        }
        return JSValue(object: [
            "url": result.url.isEmpty ? url : result.url,
            "body": result.body,
            "code": 200
        ], in: ctx)
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
        lock.lock()
        defer { lock.unlock() }
        kvStore[key] = value
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
}

public class JSEngine {
    public let context: JSContext
    private let javaShim: JavaShim
    public var onLoginHeaderUpdated: ((String) -> Void)?
    /// 最近一次脚本异常。登录这类同步流程出错时，把原文带出去，别让调用方只看到一句笼统失败。
    public private(set) var lastError: String?

    public init(bookSource: BookSource? = nil, baseUrl: String? = nil) {
        self.context = JSContext()
        self.javaShim = JavaShim(context: context)

        setupEnvironment(bookSource: bookSource, baseUrl: baseUrl)

        // 把书源自带的 jsLib 注入上下文。
        // 聚合源（大灰狼那一类）把 getArguments / setArgument / 各种加解密助手全写在 jsLib 里，
        // 正文、搜索、登录脚本直接调；不注入的话脚本第一行就
        // `ReferenceError: Can't find variable: getArguments`，整份源等于废掉。
        if let lib = bookSource?.jsLib, !lib.isEmpty {
            _ = eval(script: JSEngine.unwrapJsScript(lib))
        }
    }

    private func setupEnvironment(bookSource: BookSource?, baseUrl: String?) {
        // Exception handler
        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "unknown error"
            self?.lastError = message
            // 书源脚本的未捕获异常统一进诊断日志，搜索/目录/正文出问题时能自己查到原因
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
        let putLoginInfoBlock: @convention(block) (String) -> Void = { newInfo in loginInfoStr = newInfo }
        let getVariableBlock: @convention(block) () -> String = { variableStr ?? "" }
        let setVariableBlock: @convention(block) (String) -> Void = { newV in variableStr = newV }

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
        sourceObj?.setValue(bookSource?.loginUrl ?? "", forProperty: "loginUrl")
        // 聚合源拿它当「这本书源的缓存键」用：cache.put(`userInfo_${source.getKey()}`, ...)
        let getKeyBlock: @convention(block) () -> String = { bookSource?.bookSourceUrl ?? "" }
        sourceObj?.setValue(getKeyBlock, forProperty: "getKey")
        sourceObj?.setValue(bookSource?.bookSourceUrl ?? "", forProperty: "bookSourceUrl")
        sourceObj?.setValue(bookSource?.bookSourceName ?? "", forProperty: "bookSourceName")

        context.setObject(sourceObj, forKeyedSubscript: "source" as NSString)

        // Legado 书源脚本的 cookie API。脚本靠它存登录态，缺了这个全局对象，
        // 像「大灰狼聚合」那种登录脚本第一行就抛 ReferenceError。
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
        let getBookVarBlock: @convention(block) (String) -> String = { _ in "" }
        let setBookVarBlock: @convention(block) (String, String) -> Void = { _, _ in }
        bookObj?.setValue(getBookVarBlock, forProperty: "getVariable")
        bookObj?.setValue(setBookVarBlock, forProperty: "setVariable")
        bookObj?.setValue(bookSource?.bookSourceUrl ?? "", forProperty: "origin")
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

        // Rhino 的 Java 互操作壳。
        //
        // 安卓那边脚本跑在 Rhino 上，聚合源大量用 `new JavaImporter()` + `with(javaImport){...}`、
        // `importClass(...)`、`Packages.android.util.Base64.encodeToString(...)`、
        // `Packages.java.lang.Thread.sleep(...)`。JSC 里这些全局一个都没有，
        // 脚本第一行就 ReferenceError（实测大灰狼 5.9.30 就是卡在 JavaImporter）。
        // 这里按语义把用到的那些补上，缺的部分脚本自己大多包在 try/catch 里会降级。
        context.evaluateScript("""
        var JavaImporter = function(){ return { importClass: function(){}, importPackage: function(){} }; };
        var importClass = function(){};
        var importPackage = function(){};
        var Packages = {
          android: { util: { Base64: { encodeToString: function(bytes, flags){ return java.base64EncodeBytes(bytes); } } } },
          java: { lang: { Thread: { sleep: function(ms){ java.sleepMs(ms); } } } },
          io: { legato: { kazusa: { utils: { TimeoutCancellationException: function(message){ this.message = message; this.name = 'TimeoutCancellationException'; } } } } }
        };
        if (!java.refreshExplore) { java.refreshExplore = function(){}; }

        // 全局 cache：脚本用它存登录态之类的短期数据（cache.put('userInfo_xxx', ...)）。
        // 安卓那边是宿主提供的，缺了就 ReferenceError，聚合源登录的最后一步正好用它。
        var cache = {
          put: function(key, value){ java.put(String(key), String(value)); },
          get: function(key){ var v = java.get(String(key)); return (v === undefined || v === null) ? '' : v; },
          remove: function(key){ java.removeCache(String(key)); }
        };
        """)
        context.exception = nil
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
    /// 剥掉书源规则常见的 `<js>...</js>` 包裹与 `@js:` 前缀。
    /// loginUrl 和 loginUi 的 action 也可能带这层壳，直接丢给 evaluateScript 会语法错误。
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
