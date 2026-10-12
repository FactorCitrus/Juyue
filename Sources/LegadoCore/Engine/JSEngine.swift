import Foundation
import JavaScriptCore

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
}

@objc public class JavaShim: NSObject, JavaShimProtocol {
    private var kvStore: [String: String] = [:]
    private let lock = NSLock()
    private weak var jsContext: JSContext?

    public init(context: JSContext?) {
        self.jsContext = context
        super.init()
    }

    public func ajax(_ url: String) -> String {
        guard let parsed = NetworkClient.parseLegadoUrl(url) else { return "" }
        let resp = NetworkClient.shared.requestSync(parsed: parsed)
        return resp?.bodyString ?? ""
    }

    public func connect(_ url: String) -> JSValue {
        return connect(url, "")
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

    public init(bookSource: BookSource? = nil, baseUrl: String? = nil) {
        self.context = JSContext()
        self.javaShim = JavaShim(context: context)

        setupEnvironment(bookSource: bookSource, baseUrl: baseUrl)
    }

    private func setupEnvironment(bookSource: BookSource?, baseUrl: String?) {
        // Exception handler
        context.exceptionHandler = { _, exception in
            #if DEBUG
            print("[JSEngine Error] \(exception?.toString() ?? "unknown error")")
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
            context.setObject(result, forKeyedSubscript: "result" as NSString)
        }
        let val = context.evaluateScript(script)
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
            context.setObject(v, forKeyedSubscript: k as NSString)
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
}
