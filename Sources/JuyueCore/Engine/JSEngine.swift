import Foundation
import JavaScriptCore
import SwiftSoup
import CommonCrypto

@objc public protocol JavaShimProtocol: JSExport {
    func ajax(_ url: String) -> String
    func ajaxAll(_ urls: JSValue) -> JSValue
    func connect(_ url: String) -> JSValue
    func connect(_ url: String, _ header: String) -> JSValue
    func post(_ url: String, _ body: String, _ header: JSValue) -> JSValue
    func get(_ key: String) -> String?
    func put(_ key: String, _ value: String) -> String
    func md5Encode(_ str: String) -> String
    func base64Encode(_ str: String) -> String
    func base64Decode(_ str: String) -> String
    func base64DecodeToByteArray(_ str: String) -> JSValue
    func encodeURI(_ str: String) -> String
    func t2s(_ str: String) -> String
    func timeFormat(_ timestamp: JSValue) -> String
    func timeFormatUTC(_ timestamp: JSValue, _ format: String, _ timeZoneOffset: JSValue) -> String
    func messageDigest(_ algorithm: String, _ parts: JSValue) -> JSValue
    func stringToBytes(_ str: String) -> JSValue
    func getString(_ path: String) -> String
    func jsonPath(_ json: String, _ path: String) -> JSValue
    func getElements(_ html: JSValue, _ rule: JSValue) -> JSValue
    func getElement(_ rule: String) -> JSValue
    func toast(_ message: String)
    func longToast(_ message: String)
    func log(_ message: JSValue)
    func deviceID() -> String
    func androidId() -> String
    func getWebViewUA() -> String
    func getCookie(_ url: String) -> String
    func refreshExplore()
    func hexDecodeToString(_ hex: String) -> String
    func htmlFormat(_ html: String) -> String
    func base64EncodeBytes(_ bytes: JSValue) -> String
    func sleepMs(_ ms: JSValue)
    func createSymmetricCrypto(_ transformation: String, _ key: String) -> JSValue
    func createSymmetricCrypto(_ transformation: String, _ key: String, _ iv: String) -> JSValue
    func startBrowser(_ url: String, _ title: String)
    func startBrowserAwait(_ url: String, _ title: String) -> JSValue
    func startBrowserAwait(_ url: String, _ title: String, _ wait: Bool) -> JSValue
    func startBrowserDp(_ url: String, _ title: String)
    func showBrowser(_ url: String, _ title: String)
    func showReadingBrowser(_ url: String, _ title: String)
    func removeCache(_ key: String)
}

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
    private weak var jsContext: JSContext?
    /// 书源声明的响应时间。聚合源给到 180s，默认 15s 会先超时。
    var respondTimeout: TimeInterval?
    /// 脚本里的同步请求也要吃书源的 concurrentRate。
    var rateKey: String?
    var rateLimit: SourceRateLimit?
    /// `java.getElements(html, rule)` 要按当前书源规则解析。
    var bookSource: BookSource?
    var baseUrl: String?

    public init(context: JSContext?) {
        self.jsContext = context
        super.init()
    }

    // MARK: - 请求

    private func cookieHeader(for url: String) -> String {
        let cookies = CookieJar.shared.cookieString(for: url)
        return cookies.isEmpty ? "" : "Cookie: \(cookies)"
    }

    private func perform(_ request: NetworkClient.ParsedRequest) -> NetworkResponse? {
        NetworkClient.shared.requestSync(
            parsed: request,
            timeout: respondTimeout ?? 15,
            rateKey: rateKey,
            rateLimit: rateLimit
        )
    }

    public func ajax(_ url: String) -> String {
        guard let request = NetworkClient.parseJuyueUrl(url, defaultHeader: cookieHeader(for: url)) else {
            return ""
        }
        return perform(request)?.bodyString ?? ""
    }

    /// `java.ajaxAll(urls)`：按顺序同步请求，回响应对象数组。
    /// 脚本里常见的用法是拿一批章节接口的 JSON，数量上限 20，避免一条规则把脚本卡死。
    public func ajaxAll(_ urls: JSValue) -> JSValue {
        guard let ctx = jsContext else {
            return JSValue(undefinedIn: JSContext())
        }
        let array = JSValue(newArrayIn: ctx) ?? JSValue(nullIn: ctx)
        guard let raw = urls.toArray() else { return array ?? JSValue(nullIn: ctx) }

        var index = 0
        for item in raw {
            guard index < 20 else { break }
            guard let url = item as? String, !url.isEmpty else { continue }
            array?.setValue(connect(url), at: index)
            index += 1
        }
        return array ?? JSValue(nullIn: ctx)
    }

    public func connect(_ url: String) -> JSValue {
        connect(url, cookieHeader(for: url))
    }

    public func connect(_ url: String, _ header: String) -> JSValue {
        guard let ctx = jsContext else {
            return JSValue(undefinedIn: JSContext())
        }
        guard let request = NetworkClient.parseJuyueUrl(url, defaultHeader: header) else {
            return JSValue(nullIn: ctx)
        }
        let response = perform(request)
        return ScriptObjectFactory.response(
            body: response?.bodyString ?? "",
            code: response?.statusCode ?? 0,
            url: url,
            in: ctx
        )
    }

    public func post(_ url: String, _ body: String, _ header: JSValue) -> JSValue {
        guard let ctx = jsContext else {
            return JSValue(undefinedIn: JSContext())
        }

        var fields = headerFields(from: header)
        if fields["Content-Type"] == nil {
            fields["Content-Type"] = "application/json"
        }
        if fields["Cookie"] == nil, fields["cookie"] == nil {
            let jar = CookieJar.shared.cookieString(for: url)
            if !jar.isEmpty { fields["Cookie"] = jar }
        }

        guard let cleanURL = URL(string: url)
            ?? URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url) else {
            return JSValue(nullIn: ctx)
        }

        let request = NetworkClient.ParsedRequest(
            url: cleanURL,
            method: "POST",
            headers: fields,
            body: body.data(using: .utf8)
        )
        let response = perform(request)
        return ScriptObjectFactory.response(
            body: response?.bodyString ?? "",
            code: response?.statusCode ?? 0,
            url: url,
            in: ctx
        )
    }

    /// `post` 的第三个参数可以是对象，也可以是 JSON 字符串。
    private func headerFields(from value: JSValue) -> [String: String] {
        guard value.isObject || value.isString else { return [:] }

        if let dict = value.toDictionary() as? [String: Any] {
            return dict.mapValues { "\($0)" }
        }
        guard let text = value.toString(),
              let data = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict.mapValues { "\($0)" }
    }

    /// `Jsoup.connect(...).get()` 的取数：沿用书源请求头、Cookie 与限速。
    func fetchHTML(
        url: String,
        headers: [String: String],
        method: String,
        body: String?
    ) -> (String, Int) {
        var fields = headers
        if fields.keys.first(where: { $0.caseInsensitiveCompare("Cookie") == .orderedSame }) == nil {
            let cookies = CookieJar.shared.cookieString(for: url)
            if !cookies.isEmpty { fields["Cookie"] = cookies }
        }
        guard let parsed = NetworkClient.parseJuyueUrl(url) else {
            return ("", 0)
        }

        // defaultHeader 遇到含 "=" 的值会整段当成 Cookie，书源头必须直接并入。
        var merged = parsed.headers
        for (name, value) in fields {
            merged[name] = value
        }

        let upper = method.uppercased()
        let request = NetworkClient.ParsedRequest(
            url: parsed.url,
            method: upper,
            headers: merged,
            body: upper == "POST" ? (body ?? "").data(using: .utf8) : nil,
            usesWebView: parsed.usesWebView
        )
        let response = perform(request)
        return (response?.bodyString ?? "", response?.statusCode ?? 0)
    }

    // MARK: - 脚本缓存

    public func get(_ key: String) -> String? {
        ScriptMemory.read(key)
    }

    public func put(_ key: String, _ value: String) -> String {
        ScriptMemory.write(value, for: key)
        return value
    }

    public func removeCache(_ key: String) {
        ScriptMemory.remove(key)
    }

    // MARK: - 杂项

    public func toast(_ message: String) {
        JuyueLog.log("[toast] \(message)")
        ScriptToast.shared.handler?(message)
    }

    public func longToast(_ message: String) {
        JuyueLog.log("[toast] \(message)")
        ScriptToast.shared.handler?(message)
    }

    public func log(_ message: JSValue) {
        JuyueLog.log("[js] \(message.toString() ?? "")")
    }

    public func deviceID() -> String {
        Self.persistentDeviceID()
    }

    public func androidId() -> String {
        Self.persistentDeviceID()
    }

    public func getWebViewUA() -> String {
        NetworkClient.defaultUserAgent
    }

    public func getCookie(_ url: String) -> String {
        CookieJar.shared.cookieString(for: url)
    }

    public func refreshExplore() {
        JSEngine.exploreRefreshSink?()
    }

    public func hexDecodeToString(_ hex: String) -> String {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2, cleaned.count.isMultiple(of: 2) else {
            return cleaned
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var cursor = cleaned.startIndex
        while cursor < cleaned.endIndex {
            let end = cleaned.index(cursor, offsetBy: 2)
            guard let byte = UInt8(cleaned[cursor..<end], radix: 16) else {
                return cleaned
            }
            bytes.append(byte)
            cursor = end
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 安卓 `java.htmlFormat`：去注释、脚本、样式与标签，压成单行纯文本。
    public func htmlFormat(_ html: String) -> String {
        var text = html
        for pattern in [
            "(?is)<!--[\\s\\S]*?-->",
            "(?is)<(script|style)[^>]*>[\\s\\S]*?</\\1>",
            "(?is)<[^>]*>"
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: ""
            )
        }
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        guard let whitespace = try? NSRegularExpression(pattern: "\\s+") else { return text }
        return whitespace.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: " "
        ).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Rhino / Java 互操作

    public func base64EncodeBytes(_ bytes: JSValue) -> String {
        Data(ScriptCrypto.bytes(from: bytes)).base64EncodedString()
    }

    public func sleepMs(_ ms: JSValue) {
        let raw = ms.isNumber ? ms.toInt32() : (Int32(ms.toString() ?? "0") ?? 0)
        let duration = max(0, min(raw, 10_000))
        if duration > 0 {
            Thread.sleep(forTimeInterval: Double(duration) / 1000.0)
        }
    }

    public func createSymmetricCrypto(_ transformation: String, _ key: String) -> JSValue {
        makeCrypto(transformation: transformation, key: key, iv: nil)
    }

    public func createSymmetricCrypto(_ transformation: String, _ key: String, _ iv: String) -> JSValue {
        makeCrypto(transformation: transformation, key: key, iv: iv)
    }

    private func makeCrypto(transformation: String, key: String, iv: String?) -> JSValue {
        guard let ctx = jsContext else {
            return JSValue(undefinedIn: JSContext())
        }

        let parts = transformation.uppercased().split(separator: "/").map(String.init)
        let algorithm = parts.first ?? "AES"
        let mode = parts.count > 1 ? parts[1] : "ECB"
        let keyData = Data(key.utf8)
        let ivData = iv.map { Data($0.utf8) }

        func transform(_ input: [UInt8], encrypt: Bool) -> [UInt8] {
            ScriptCrypto.symmetric(
                algorithm: algorithm,
                mode: mode,
                key: keyData,
                iv: ivData,
                input: input,
                encrypt: encrypt
            ) ?? []
        }

        let encrypt: @convention(block) (JSValue) -> JSValue = { value in
            ScriptObjectFactory.byteArray(transform(ScriptCrypto.bytes(from: value), encrypt: true), in: ctx)
        }
        let decrypt: @convention(block) (JSValue) -> JSValue = { value in
            ScriptObjectFactory.byteArray(transform(ScriptCrypto.bytes(from: value), encrypt: false), in: ctx)
        }
        let encryptBase64: @convention(block) (JSValue) -> JSValue = { value in
            let output = transform(ScriptCrypto.bytes(from: value), encrypt: true)
            return JSValue(object: Data(output).base64EncodedString(), in: ctx)
        }
        let decryptBase64: @convention(block) (JSValue) -> JSValue = { value in
            let raw = value.toString() ?? ""
            let input = [UInt8](Data(base64Encoded: raw) ?? Data())
            return ScriptObjectFactory.byteArray(transform(input, encrypt: false), in: ctx)
        }

        let object: [String: Any] = [
            "encrypt": encrypt,
            "decrypt": decrypt,
            "encryptBase64": encryptBase64,
            "decryptBase64": decryptBase64
        ]
        return JSValue(object: object, in: ctx)
    }

    static func byteArray(from value: JSValue) -> [UInt8] {
        ScriptCrypto.bytes(from: value)
    }

    static func symmetric(
        algorithm: String, mode: String, key: Data, iv: Data?, input: [UInt8], encrypt: Bool
    ) -> [UInt8]? {
        ScriptCrypto.symmetric(
            algorithm: algorithm,
            mode: mode,
            key: key,
            iv: iv,
            input: input,
            encrypt: encrypt
        )
    }

    // MARK: - 浏览器

    public func startBrowser(_ url: String, _ title: String) {
        _ = ScriptBrowser.shared.present?(url, title, false)
    }

    public func startBrowserAwait(_ url: String, _ title: String) -> JSValue {
        browserResult(url: url, title: title)
    }

    public func startBrowserAwait(_ url: String, _ title: String, _ wait: Bool) -> JSValue {
        browserResult(url: url, title: title)
    }

    public func startBrowserDp(_ url: String, _ title: String) {
        _ = ScriptBrowser.shared.present?(url, title, false)
    }

    public func showBrowser(_ url: String, _ title: String) {
        _ = ScriptBrowser.shared.present?(url, title, false)
    }

    public func showReadingBrowser(_ url: String, _ title: String) {
        _ = ScriptBrowser.shared.present?(url, title, false)
    }

    private func browserResult(url: String, title: String) -> JSValue {
        guard let ctx = jsContext ?? JSContext() else {
            return JSValue(undefinedIn: nil)
        }
        guard let result = ScriptBrowser.shared.present?(url, title, true) else {
            return ScriptObjectFactory.emptyBrowser(url: url, in: ctx)
        }
        return ScriptObjectFactory.browser(
            body: result.body,
            url: result.url.isEmpty ? url : result.url,
            in: ctx
        )
    }

    private static func persistentDeviceID() -> String {
        JuyueStorageMigration.runIfNeeded()
        let key = "juyue.scriptDeviceID"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    // MARK: - 其他协议方法

    public func md5Encode(_ str: String) -> String {
        CryptoUtils.md5(str)
    }

    public func base64Encode(_ str: String) -> String {
        CryptoUtils.base64Encode(str)
    }

    public func base64Decode(_ str: String) -> String {
        CryptoUtils.base64Decode(str)
    }

    /// `java.base64DecodeToByteArray(str)`：解出来直接给字节数组，脚本可以再喂给解密。
    public func base64DecodeToByteArray(_ str: String) -> JSValue {
        let ctx: JSContext = jsContext ?? JSContext()
        let cleaned = str.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]) ?? Data()
        return ScriptObjectFactory.byteArray([UInt8](data), in: ctx)
    }

    /// JavaScript `encodeURI` 语义：保留 URL 保留字符，其余按 UTF-8 百分号编码，空格为 `%20`。
    public func encodeURI(_ str: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'();/?:@&=+$,#"
        )
        return str.addingPercentEncoding(withAllowedCharacters: allowed) ?? str
    }

    /// `java.t2s(str)`：繁体转简体。书源在分类名、书名上用它统一字形。
    public func t2s(_ str: String) -> String {
        let mutable = NSMutableString(string: str)
        CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false)
        return mutable as String
    }

    /// `java.timeFormatUTC(t, format, offset)`：按指定时区格式化，offset 是小时数，缺省 UTC。
    /// 与 Legado 一致，入参按毫秒时间戳解释；format 缺省时沿用 `timeFormat` 的默认格式。
    public func timeFormatUTC(_ timestamp: JSValue, _ format: String, _ timeZoneOffset: JSValue) -> String {
        var milliseconds = timestamp.toNumber()?.doubleValue ?? 0
        if milliseconds == 0, let text = timestamp.toString(), let parsed = Double(text) {
            milliseconds = parsed
        }
        guard milliseconds >= 0 else { return "" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // 番茄系源会传 8 表示东八区；没有第三参时保持 UTC。
        let hours = timeZoneOffset.toNumber()?.intValue ?? 0
        formatter.timeZone = TimeZone(secondsFromGMT: hours * 3600) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format.isEmpty ? "yyyy-MM-dd HH:mm" : format
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    /// `Packages.java.security.MessageDigest` 的原生摘要实现。
    /// `parts` 是脚本 `update()` 攒下的字节数组列表，按顺序拼起来再算。
    public func messageDigest(_ algorithm: String, _ parts: JSValue) -> JSValue {
        let ctx: JSContext = jsContext ?? JSContext()
        var input: [UInt8] = []
        if let array = parts.toArray() {
            for item in array {
                input.append(contentsOf: ScriptDigest.bytes(from: item))
            }
        } else {
            input.append(contentsOf: ScriptCrypto.bytes(from: parts))
        }

        guard let digest = ScriptDigest.value(algorithm: algorithm, input: input) else {
            return ScriptObjectFactory.byteArray([], in: ctx)
        }
        return ScriptObjectFactory.byteArray(digest, in: ctx)
    }

    public func stringToBytes(_ str: String) -> JSValue {
        let ctx: JSContext = jsContext ?? JSContext()
        return ScriptObjectFactory.byteArray([UInt8](str.utf8), in: ctx)
    }

    public func timeFormat(_ timestamp: JSValue) -> String {
        var seconds = timestamp.toNumber()?.doubleValue ?? 0
        if seconds == 0, let text = timestamp.toString(), let parsed = Double(text) {
            seconds = parsed
        }
        guard seconds > 0 else { return "" }
        if seconds > 10_000_000_000 {
            seconds /= 1000
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    public func getString(_ path: String) -> String {
        guard let ctx = jsContext,
              let result = ctx.objectForKeyedSubscript("result" as NSString) else {
            return ""
        }

        if result.isObject {
            let directKey = String(path.drop { $0 == "$" || $0 == "." })
            if let direct = result.forProperty(directKey), !direct.isUndefined, !direct.isNull {
                return direct.toString() ?? ""
            }
            if let dict = result.toDictionary(),
               let hit = JSONPath.evaluate(path: path, json: dict) {
                return "\(hit)"
            }
        }

        guard let text = result.toString(),
              let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let hit = JSONPath.evaluate(path: path, json: parsed) else {
            return ""
        }
        return "\(hit)"
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

    /// `java.getElements(html, rule)`：按当前书源的规则语法解析 HTML，
    /// 返回与 `org.jsoup` wrapper 同一套方法的集合对象。
    ///
    /// 书源里更常见的是单参数写法 `java.getElements(rule)`：Rhino 把 `java`
    /// 绑到当前 AnalyzeRule，规则作用在正在解析的 `result` 上。这里两种都支持。
    public func getElements(_ html: JSValue, _ rule: JSValue) -> JSValue {
        let ctx: JSContext = jsContext ?? JSContext()
        let hasRule = !(rule.isUndefined || rule.isNull)
        let htmlText: String
        let ruleText: String
        if hasRule {
            htmlText = Self.jsoupText(html)
            ruleText = Self.jsoupText(rule)
        } else {
            htmlText = currentResultText()
            ruleText = Self.jsoupText(html)
        }
        let trimmed = Self.normalizeJsoupIndexRule(
            ruleText.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        if trimmed.isEmpty {
            return JsoupShim.document(html: htmlText, baseUri: baseUrl ?? "", in: ctx)
        }

        let analyzer = RuleAnalyzer(content: htmlText, baseUrl: baseUrl, bookSource: bookSource)
        let elements = Elements()
        for item in analyzer.getElements(trimmed) {
            if let element = item as? Element { elements.add(element) }
        }
        return JsoupShim.wrapper(elements, in: ctx)
    }

    /// 单参数 `java.getElement(rule)`：规则作用在当前脚本的 `result` 上。
    /// 洛娅橙这类订阅源用它把 JSON 结果转成条目集合，没有这个方法脚本直接报错。
    public func getElement(_ rule: String) -> JSValue {
        let ctx: JSContext = jsContext ?? JSContext()
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = currentResultText()

        if trimmed.hasPrefix("$") {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let hit = JSONPath.evaluate(path: trimmed, json: object) else {
                return JSValue(newArrayIn: ctx)
            }
            return JSValue(object: hit, in: ctx) ?? JSValue(newArrayIn: ctx)
        }

        let analyzer = RuleAnalyzer(content: text, baseUrl: baseUrl, bookSource: bookSource)
        let elements = Elements()
        for item in analyzer.getElements(trimmed) {
            if let element = item as? Element { elements.add(element) }
        }
        return JsoupShim.wrapper(elements, in: ctx)
    }

    /// 单参数 `java.getElements(rule)` 的输入：当前脚本里的 `result`。
    private func currentResultText() -> String {
        guard let ctx = jsContext,
              let value = ctx.objectForKeyedSubscript("result"),
              !value.isUndefined, !value.isNull else {
            return ""
        }
        if value.isArray, let array = value.toArray(),
           let data = try? JSONSerialization.data(withJSONObject: array),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if value.isObject, !value.isArray, let dict = value.toDictionary(),
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return value.toString() ?? ""
    }

    private static func jsoupText(_ value: JSValue) -> String {
        value.isUndefined || value.isNull ? "" : (value.toString() ?? "")
    }

    /// Legado 的索引写法 `dd!-1` 等价于 `dd.-1`，RuleAnalyzer 只认后者。
    private static func normalizeJsoupIndexRule(_ rule: String) -> String {
        let attributes: Set<String> = ["text", "textnodes", "html", "href", "src", "title", "content"]
        return rule.components(separatedBy: "@").map { part in
            let token = part.trimmingCharacters(in: .whitespaces)
            guard let marker = token.range(of: "!", options: .backwards) else { return part }
            let base = String(token[..<marker.lowerBound])
            let index = String(token[marker.upperBound...])
            guard !base.isEmpty,
                  Int(index) != nil,
                  !attributes.contains(base.lowercased()),
                  !base.hasPrefix("attr(") else {
                return part
            }
            return "\(base).\(index)"
        }.joined(separator: "@")
    }
}

// MARK: - 共享缓存

private enum ScriptMemory {
    private static var values: [String: String] = [:]
    private static let lock = NSLock()

    static func read(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    static func write(_ value: String, for key: String) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }

    static func remove(_ key: String) {
        lock.lock()
        values.removeValue(forKey: key)
        lock.unlock()
    }
}

// MARK: - 脚本对象

private enum ScriptObjectFactory {
    static func response(body: String, code: Int, url: String, in ctx: JSContext) -> JSValue {
        let object = JSValue(newObjectIn: ctx)
        object?.setValue({ body } as @convention(block) () -> String, forProperty: "body")
        object?.setValue({ code } as @convention(block) () -> Int, forProperty: "statusCode")
        object?.setValue({ url } as @convention(block) () -> String, forProperty: "url")
        object?.setValue(body, forProperty: "text")
        return object ?? JSValue(nullIn: ctx)
    }

    static func browser(body: String, url: String, in ctx: JSContext) -> JSValue {
        let object = JSValue(newObjectIn: ctx)
        object?.setValue({ body } as @convention(block) () -> String, forProperty: "body")
        object?.setValue(body, forProperty: "bodyString")
        object?.setValue(url, forProperty: "url")
        object?.setValue(200, forProperty: "code")
        return object ?? JSValue(nullIn: ctx)
    }

    static func emptyBrowser(url: String, in ctx: JSContext) -> JSValue {
        let object = JSValue(newObjectIn: ctx)
        object?.setValue({ "" } as @convention(block) () -> String, forProperty: "body")
        object?.setValue("", forProperty: "bodyString")
        object?.setValue(url, forProperty: "url")
        object?.setValue(0, forProperty: "code")
        return object ?? JSValue(nullIn: ctx)
    }

    static func byteArray(_ bytes: [UInt8], in ctx: JSContext) -> JSValue {
        JSValue(object: bytes.map { Int($0) }, in: ctx)
    }
}

// MARK: - 加解密

private enum ScriptCrypto {
    static func bytes(from value: JSValue) -> [UInt8] {
        if let text = value.toString(), !value.isArray {
            return [UInt8](text.utf8)
        }
        guard let array = value.toArray() else { return [] }
        return array.compactMap { item in
            if let number = item as? NSNumber {
                return UInt8(truncatingIfNeeded: number.intValue)
            }
            if let number = item as? Int {
                return UInt8(truncatingIfNeeded: number)
            }
            return nil
        }
    }

    static func symmetric(
        algorithm: String,
        mode: String,
        key: Data,
        iv: Data?,
        input: [UInt8],
        encrypt: Bool
    ) -> [UInt8]? {
        guard !input.isEmpty else { return [] }

        let cipher: CCAlgorithm
        switch algorithm {
        case "AES": cipher = CCAlgorithm(kCCAlgorithmAES)
        case "DES": cipher = CCAlgorithm(kCCAlgorithmDES)
        case "DESEDE", "3DES": cipher = CCAlgorithm(kCCAlgorithm3DES)
        default: return nil
        }

        let operation = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
        let options = CCOptions(mode == "CBC" ? 0 : kCCOptionECBMode)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var outputLength = 0

        func run(_ ivBytes: UnsafeRawBufferPointer?) -> CCCryptorStatus {
            key.withUnsafeBytes { keyBytes in
                input.withUnsafeBytes { inputBytes in
                    CCCrypt(
                        operation,
                        cipher,
                        options,
                        keyBytes.baseAddress,
                        key.count,
                        ivBytes?.baseAddress,
                        inputBytes.baseAddress,
                        input.count,
                        &output,
                        output.count,
                        &outputLength
                    )
                }
            }
        }

        let status = iv?.withUnsafeBytes { run($0) } ?? run(nil)
        guard status == kCCSuccess else { return nil }
        return Array(output.prefix(outputLength))
    }
}

// MARK: - 摘要

private enum ScriptDigest {
    static func value(algorithm: String, input: [UInt8]) -> [UInt8]? {
        switch algorithm.uppercased().replacingOccurrences(of: "_", with: "-") {
        case "MD5":
            var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            CC_MD5(input, CC_LONG(input.count), &digest)
            return digest
        case "SHA1", "SHA-1":
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            CC_SHA1(input, CC_LONG(input.count), &digest)
            return digest
        case "SHA256", "SHA-256":
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(input, CC_LONG(input.count), &digest)
            return digest
        default:
            return nil
        }
    }

    static func bytes(from value: Any) -> [UInt8] {
        if let js = value as? JSValue { return ScriptCrypto.bytes(from: js) }
        if let text = value as? String { return [UInt8](text.utf8) }
        if let number = value as? NSNumber { return [UInt8(truncatingIfNeeded: number.intValue)] }
        if let array = value as? [Any] { return array.flatMap { bytes(from: $0) } }
        return []
    }
}

public class JSEngine {
    public let context: JSContext
    private let javaShim: JavaShim
    private var book: Book?
    private var bookReadConfig: JSValue?

    public static var variableSink: ((_ bookSourceUrl: String, _ variable: String) -> Void)?
    public static var bookUpdateSink: ((_ book: Book) -> Void)?
    public static var exploreRefreshSink: (() -> Void)?
    public var onLoginHeaderUpdated: ((String) -> Void)?
    public var onLoginInfoUpdated: ((String) -> Void)?
    public private(set) var lastError: String?

    public init(bookSource: BookSource? = nil, baseUrl: String? = nil, book: Book? = nil) {
        self.context = JSContext()
        self.javaShim = JavaShim(context: context)
        self.book = book

        javaShim.rateKey = bookSource?.bookSourceUrl
        javaShim.rateLimit = bookSource?.rateLimit
        javaShim.bookSource = bookSource
        javaShim.baseUrl = baseUrl
        if let milliseconds = bookSource?.respondTime, milliseconds > 0 {
            javaShim.respondTimeout = min(180, max(10, TimeInterval(milliseconds) / 1000))
        }

        installExceptionHandler()
        installJavaShim()
        installSourceObject(bookSource: bookSource)
        installCookieObject()
        installBookObject(bookSource: bookSource)
        if let baseUrl {
            context.setObject(baseUrl, forKeyedSubscript: "baseUrl" as NSString)
        }
        installRuntimePolyfills()
        installScriptLibrary(bookSource: bookSource)
    }

    // MARK: - 环境

    /// 规则 JS 里的 `src` 是被分析的页面源码（Legado 的 AnalyzeRule.evalJS 同样绑定），
    /// 目录地址规则常写 `src.match(/data-mid="(\\d+)"/)`。
    public func setSourceText(_ text: String) {
        context.setObject(text, forKeyedSubscript: "src" as NSString)
    }

    private func installExceptionHandler() {
        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "unknown error"
            self?.lastError = message
            JuyueLog.log("[JS] \(message)")
            #if DEBUG
            print("[JSEngine Error] \(message)")
            #endif
        }
    }

    /// 订阅源规则脚本要读 `source.sortUrl`（洛娅橙的 jsLib 会拿它取版本号），
    /// BookSource 模型里没有这个字段，由调用方在创建引擎后补进去。
    func setSourceValue(_ key: String, _ value: String) {
        guard let source = context.objectForKeyedSubscript("source" as NSString) else { return }
        source.setObject(value, forKeyedSubscript: key as NSString)
    }

    /// 订阅源的 ruleContent 脚本要读 `rssArticle.title` / `rssArticle.sort`
    /// （洛娅橙拿它判断当前打开的是哪一篇），Legado 的环境里有这个全局。
    public func setRssArticle(_ fields: [String: String]) {
        guard let article = JSValue(newObjectIn: context) else { return }
        for (key, value) in fields {
            article.setObject(value, forKeyedSubscript: key as NSString)
        }
        context.setObject(article, forKeyedSubscript: "rssArticle" as NSString)
    }

    private func installJavaShim() {
        context.setObject(javaShim, forKeyedSubscript: "java" as NSString)
    }

    private func installSourceObject(bookSource: BookSource?) {
        let object = JSValue(newObjectIn: context)
        var loginHeader = bookSource?.loginHeader ?? bookSource?.header
        var loginInfo = bookSource?.loginInfo
        var variable = bookSource?.variable

        let getHeader: @convention(block) () -> String? = { loginHeader }
        let putHeader: @convention(block) (String) -> Void = { [weak self] value in
            loginHeader = value
            self?.onLoginHeaderUpdated?(value)
        }
        let getInfo: @convention(block) () -> String? = { loginInfo }
        let putInfo: @convention(block) (String) -> Void = { [weak self] value in
            loginInfo = value
            self?.onLoginInfoUpdated?(value)
        }
        let getVariable: @convention(block) () -> String = { variable ?? "" }
        let setVariable: @convention(block) (String) -> Void = { value in
            variable = value
            JSEngine.variableSink?(bookSource?.bookSourceUrl ?? "", value)
        }
        let getInfoMap: @convention(block) () -> JSValue = { [weak self] in
            let ctx = self?.context ?? JSContext()
            let map = JSValue(newObjectIn: ctx)
            if let raw = loginInfo,
               let data = raw.data(using: .utf8),
               let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (name, value) in fields {
                    map?.setValue(value, forProperty: name)
                }
            }
            let lookup: @convention(block) (String) -> String = { key in
                map?.forProperty(key)?.toString() ?? ""
            }
            map?.setValue(lookup, forProperty: "get")
            return map ?? JSValue(newObjectIn: ctx)
        }
        let putCache: @convention(block) (String, String) -> String = { [weak javaShim] key, value in
            javaShim?.put(key, value) ?? value
        }
        let getCache: @convention(block) (String) -> String = { [weak javaShim] key in
            javaShim?.get(key) ?? ""
        }
        let removeCache: @convention(block) (String) -> Void = { [weak javaShim] key in
            javaShim?.removeCache(key)
        }
        let getKey: @convention(block) () -> String = { bookSource?.bookSourceUrl ?? "" }

        object?.setValue(getVariable, forProperty: "getVariable")
        object?.setValue(setVariable, forProperty: "setVariable")
        object?.setValue(getHeader, forProperty: "getLoginHeader")
        object?.setValue(putHeader, forProperty: "putLoginHeader")
        object?.setValue(getInfoMap, forProperty: "getLoginInfoMap")
        object?.setValue(putInfo, forProperty: "putLoginInfo")
        object?.setValue(getInfo, forProperty: "getLoginInfo")
        object?.setValue(putCache, forProperty: "put")
        object?.setValue(getCache, forProperty: "get")
        object?.setValue(removeCache, forProperty: "remove")
        object?.setValue(bookSource?.loginUrl ?? "", forProperty: "loginUrl")
        object?.setValue(getKey, forProperty: "getKey")
        object?.setValue(bookSource?.bookSourceUrl ?? "", forProperty: "bookSourceUrl")
        object?.setValue(bookSource?.bookSourceName ?? "", forProperty: "bookSourceName")

        context.setObject(object, forKeyedSubscript: "source" as NSString)
    }

    private func installCookieObject() {
        let object = JSValue(newObjectIn: context)
        let getCookie: @convention(block) (String) -> String = { url in
            CookieJar.shared.cookieString(for: url)
        }
        let setCookie: @convention(block) (String, String) -> Void = { url, value in
            CookieJar.shared.setCookies(value, for: url)
        }
        let removeCookie: @convention(block) (String) -> Void = { url in
            CookieJar.shared.remove(for: url)
        }
        let getKey: @convention(block) (String, String) -> String = { url, name in
            CookieJar.shared.value(for: url, name: name) ?? ""
        }

        object?.setValue(getCookie, forProperty: "getCookie")
        object?.setValue(setCookie, forProperty: "setCookie")
        object?.setValue(removeCookie, forProperty: "removeCookie")
        object?.setValue(getKey, forProperty: "getKey")
        context.setObject(object, forKeyedSubscript: "cookie" as NSString)
    }

    private func installBookObject(bookSource: BookSource?) {
        let object = JSValue(newObjectIn: context)
        object?.setValue(book?.name ?? "", forProperty: "name")
        object?.setValue(book?.author ?? "", forProperty: "author")
        object?.setValue(book?.bookUrl ?? "", forProperty: "bookUrl")
        object?.setValue(book?.durChapterIndex ?? 0, forProperty: "durChapterIndex")
        object?.setValue(book?.durChapterTitle ?? "", forProperty: "durChapterTitle")
        object?.setValue(book?.totalChapterNum ?? 0, forProperty: "totalChapterNum")
        object?.setValue(bookSource?.bookSourceUrl ?? book?.origin ?? "", forProperty: "origin")

        let config = JSValue(newObjectIn: context)
        bookReadConfig = config
        if let flag = book?.useReplaceRule {
            config?.setValue(flag, forProperty: "useReplaceRule")
        } else {
            config?.setValue(JSValue(nullIn: context), forProperty: "useReplaceRule")
        }
        object?.setValue(config, forProperty: "readConfig")

        let getVariable: @convention(block) (String) -> String = { [weak self] key in
            self?.bookVariable(key) ?? ""
        }
        let setVariable: @convention(block) (String, String) -> Void = { [weak self] key, value in
            self?.setBookVariable(key, value)
        }
        let getReplace: @convention(block) () -> JSValue = { [weak self] in
            guard let ctx = self?.context else { return JSValue(nullIn: JSContext()) }
            guard let flag = self?.book?.useReplaceRule else { return JSValue(nullIn: ctx) }
            return JSValue(object: flag, in: ctx)
        }
        let setReplace: @convention(block) (Bool) -> Void = { [weak self] flag in
            self?.setUseReplaceRule(flag)
        }

        object?.setValue(getVariable, forProperty: "getVariable")
        object?.setValue(setVariable, forProperty: "setVariable")
        object?.setValue(getReplace, forProperty: "getUseReplaceRule")
        object?.setValue(setReplace, forProperty: "setUseReplaceRule")
        context.setObject(object, forKeyedSubscript: "book" as NSString)
    }

    private func installRuntimePolyfills() {
        context.evaluateScript(Self.compatibilityRuntime)
        context.evaluateScript(Self.javaRuntime)
        installJsoupShim()
        context.exception = nil
    }

    /// 全局 `org.jsoup`：Android 书源里最常见的 HTML 解析写法。
    private func installJsoupShim() {
        let fetch: JsoupShim.Fetcher = { [weak javaShim] url, headers, method, body in
            javaShim?.fetchHTML(url: url, headers: headers, method: method, body: body) ?? ("", 0)
        }
        JsoupShim.install(context: context, fetch: fetch)
        // Rhino 的包对象写法 `Packages.org.jsoup.Jsoup` 也要能落到同一个实现。
        context.evaluateScript("if (typeof Packages === 'object' && Packages) { Packages.org = org; }")
        context.exception = nil
    }

    private func installScriptLibrary(bookSource: BookSource?) {
        guard let library = bookSource?.jsLib, !library.isEmpty else { return }
        if context.objectForKeyedSubscript("__juyueJsLibLoaded")?.toBool() == true {
            return
        }
        _ = eval(script: Self.unwrapJsScript(library))
        let loaded = lastError == nil
        context.setObject(loaded, forKeyedSubscript: "__juyueJsLibLoaded" as NSString)
        if !loaded {
            JuyueLog.log("[JS] jsLib 注入失败：\(lastError ?? "")")
            lastError = nil
        }
    }

    private static let compatibilityRuntime = """
    var console = {
        log: function () { },
        error: function () { }
    };
    function format(value) { return Array.isArray(value) ? value.join('\\n\\n') : (value || ''); }
    function regex(value) { return value || ''; }
    function annotate(content) { return content || ''; }
    function update(address) { }
    """

    private static let javaRuntime = """
    var JavaImporter = function(){
      var merged = { importClass: function(){}, importPackage: function(){} };
      for (var i = 0; i < arguments.length; i++) {
        var pkg = arguments[i];
        if (!pkg || typeof pkg !== 'object') continue;
        for (var key in pkg) { merged[key] = pkg[key]; }
      }
      return merged;
    };
    var importClass = function(){};
    var importPackage = function(){};
    // 订阅源 ruleContent 会直接把 `${toastjs}` 插进生成的 HTML，Legado 内置了这个提示函数。
    var toastjs = "function showToast(message){ java.toast(String(message)); }";
    var Packages = {
      android: { util: { Base64: { encodeToString: function(bytes, flags){ return java.base64EncodeBytes(bytes); } } } },
      java: {
        lang: {
          Thread: { sleep: function(ms){ java.sleepMs(ms); } },
          String: function(value){
            return { getBytes: function(){ return java.stringToBytes(String(value)); } };
          }
        },
        security: {
          MessageDigest: {
            getInstance: function(algorithm){
              var parts = [];
              var add = function(bytes){
                if (bytes !== undefined && bytes !== null) parts.push(bytes);
              };
              return {
                update: function(bytes){ add(bytes); },
                digest: function(bytes){
                  add(bytes);
                  return java.messageDigest(String(algorithm), parts);
                }
              };
            }
          }
        }
      },
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
    // Rhino 里 `java.lang` / `java.security` 是包对象；书源两种写法都用，
    // 这里把同一套实现挂到 java 对象上，避免 `java.security.MessageDigest` 报 undefined。
    java.lang = Packages.java.lang;
    java.security = Packages.java.security;
    if (!java.refreshExplore) { java.refreshExplore = function(){}; }
    var cache = {
      put: function(key, value){ java.put(String(key), String(value)); },
      get: function(key){ var v = java.get(String(key)); return (v === undefined || v === null) ? '' : v; },
      remove: function(key){ java.removeCache(String(key)); },
      putMemory: function(key, value){ java.put('__mem__' + String(key), String(value)); },
      getFromMemory: function(key){
        var v = java.get('__mem__' + String(key));
        if (v === undefined || v === null || v === '') return 0;
        var n = Number(v);
        return isNaN(n) ? 0 : n;
      }
    };
    // Legado 的 source.get / java.ajax 回的是 java.lang.String，脚本会对结果调 `.length()`
    // （洛娅橙 ruleContent 拿它判断缓存长度）。原生 JS 字符串的 length 是数字，
    // 直接调用抛 TypeError，这里按 Java String 的形态包一层。
    var __javaString = function(v){
      var raw = (v === undefined || v === null) ? '' : String(v);
      var o = Object.create(String.prototype);
      o.toString = function(){ return raw; };
      o.valueOf = function(){ return raw; };
      Object.defineProperty(o, 'length', { get: function(){ return function(){ return raw.length; }; } });
      return o;
    };
    if (typeof source !== 'undefined' && source && typeof source.get === 'function') {
      var __sourceGet = source.get;
      source.get = function(key){ return __javaString(__sourceGet.call(source, String(key))); };
    }
    if (typeof java !== 'undefined' && typeof java.ajax === 'function') {
      var __javaAjax = java.ajax;
      // 安卓的 java.ajax(url, header) 带请求头；原生垫片只有单参版，这里转发给 connect。
      java.ajax = function(url, header){
        if (arguments.length > 1 && header !== undefined && header !== null) {
          try {
            var text = (typeof header === 'string') ? header : JSON.stringify(header);
            var reply = java.connect(String(url), text);
            var body = (reply && typeof reply.body === 'function') ? reply.body() : '';
            return __javaString(body);
          } catch (e) {}
        }
        return __javaString(__javaAjax.call(java, String(url)));
      };
    }
    if (typeof java !== 'undefined' && typeof java.get === 'function') {
      var __javaGet = java.get;
      // 安卓的 java.get(key, defaultValue) 有默认值重载。
      java.get = function(key, defaultValue){
        var value = __javaGet.call(java, String(key));
        if (value === undefined || value === null || value === '') {
          return defaultValue === undefined ? '' : defaultValue;
        }
        return value;
      };
    }
    """

    // MARK: - 书对象状态

    private func bookVariable(_ key: String) -> String {
        guard let dict = Self.bookVariableDict(from: book?.variable),
              let value = dict[key] else {
            return ""
        }
        return "\(value)"
    }

    private func setBookVariable(_ key: String, _ value: String) {
        guard var updated = book else { return }
        var dict = Self.bookVariableDict(from: updated.variable) ?? [:]
        dict[key] = value
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        updated.variable = text
        book = updated
        JSEngine.bookUpdateSink?(updated)
    }

    private func setUseReplaceRule(_ flag: Bool) {
        guard var updated = book else { return }
        updated.useReplaceRule = flag
        book = updated
        bookReadConfig?.setValue(flag, forProperty: "useReplaceRule")
        JSEngine.bookUpdateSink?(updated)
    }

    private static func bookVariableDict(from raw: String?) -> [String: Any]? {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - 求值

    public func evalRule(script: String, result: Any? = nil, rawText: String? = nil) -> Any? {
        eval(script: "{ \(script)\n}", result: result, rawText: rawText)
    }

    public func eval(script: String, result: Any? = nil, rawText: String? = nil) -> Any? {
        if let result {
            context.setObject(Self.jsSafeValue(result), forKeyedSubscript: "result" as NSString)
        }
        if let rawText {
            Self.attachRawText(rawText, to: "result", context: context)
        }

        let value = context.evaluateScript(script)
        if let exception = context.exception {
            lastError = exception.toString()
            context.exception = nil
        }

        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isString { return value.toString() }
        if value.isNumber { return value.toNumber() }
        if value.isBoolean { return value.toBool() }
        // `java.getElements(...)` 的返回值是包装对象，先还原成节点数组。
        if let elements = JsoupShim.elements(from: value) { return elements }
        if value.isArray { return value.toArray() }
        if value.isObject {
            // `java.ajax` / `java.post` 回的是模拟 java.lang.String 的对象，
            // 脚本把它的返回值一路传下来时（`result` 就是这个对象），
            // toDictionary 只会得到 {toString: fn, valueOf: fn}，拼进 URL 就是 [object Object]。
            if let text = Self.javaStringPayload(value, context: context) { return text }
            return value.toDictionary()
        }
        return value.toObject()
    }

    /// 让对象在转字符串时还原原始响应文本。
    ///
    /// 规则引擎把 JSON 响应解析成对象绑定给 `result`（脚本要 `result.title` 这类字段），
    /// 但聚合源正文会对 `result` 做 `String()` / `hexDecodeToString()` / `JSON.parse()`，
    /// 对象默认会被转成 `[object Object]`。这里给对象挂一个不可枚举的 `toString`，
    /// 两种用法都能拿到原文，`for…in` 也不会多出一个键。
    private static func attachRawText(_ raw: String, to variable: String, context: JSContext) {
        let block: @convention(block) () -> String = { raw }
        guard let function = JSValue(object: block, in: context) else { return }
        context.setObject(function, forKeyedSubscript: "__juyueRawToString" as NSString)
        context.evaluateScript("""
        if (typeof \(variable) === 'object' && \(variable) !== null) {
            Object.defineProperty(\(variable), 'toString', {
                value: __juyueRawToString,
                enumerable: false,
                configurable: true,
                writable: true
            });
        }
        delete __juyueRawToString;
        """)
        context.exception = nil
    }

    /// 只有 toString / valueOf、没有可枚举字段的对象，按「Java 字符串」还原。
    /// 判据两条一起用：JSON.stringify 出 `{}`，且 toString 不是 `[object Object]`。
    /// 空对象 `{}` 也会 stringify 成 `{}`，靠第二条排除。
    private static func javaStringPayload(_ value: JSValue, context: JSContext) -> String? {
        guard value.isObject else { return nil }
        let text = value.toString() ?? ""
        guard !text.isEmpty, text != "[object Object]" else { return nil }
        guard let json = context.objectForKeyedSubscript("JSON"),
              let stringified = json.invokeMethod("stringify", withArguments: [value]),
              stringified.toString() == "{}" else { return nil }
        return text
    }

    public func renderTemplate(_ text: String, variables: [String: Any] = [:]) -> String {
        for (name, value) in variables {
            context.setObject(Self.jsSafeValue(value), forKeyedSubscript: name as NSString)
        }

        guard !text.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: #"\{\{(.*?)\}\}"#,
                options: [.dotMatchesLineSeparators]
              ) else {
            return text
        }

        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        var output = text
        for match in matches.reversed() {
            let expression = source.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rendered = RuleAnalyzer.scalarText(eval(script: expression))
            output = (output as NSString).replacingCharacters(in: match.range, with: rendered)
        }
        return output
    }

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
        if let js = value as? JSValue {
            return js
        }
        if let element = value as? Element {
            return (try? element.outerHtml()) ?? ""
        }
        if let elements = value as? Elements {
            return elements.array().map { (try? $0.outerHtml()) ?? "" }
        }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number
        }
        if value is NSNull {
            return NSNull()
        }
        if let array = value as? [Any] {
            return array.map { jsSafeValue($0) }
        }
        if let dict = value as? [String: Any] {
            return dict.mapValues { jsSafeValue($0) }
        }
        return String(describing: value)
    }
}
