import Foundation
import JavaScriptCore
import SwiftSoup

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
