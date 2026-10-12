import Foundation

/// 在线朗读引擎，对齐安卓版 `HttpTTS` 实体与 `httpTTS.json` 导入格式。
///
/// 安卓端的导入规则：顶层可以是单个对象，也可以是对象数组；
/// `name` 与 `url` 必填，其余字段缺失时用默认值。
public struct HttpTTS: Equatable, Codable {
    public var id: Int64
    public var name: String
    /// URL 规则，格式为 `地址,{JSON 选项}`，选项支持 method / headers / body / charset。
    public var url: String
    public var contentType: String?
    /// 同源并发间隔（毫秒），安卓端用于限速。
    public var concurrentRate: String?
    public var loginUrl: String?
    public var loginUi: String?
    /// 请求头，JSON 对象或 `Key: Value` 多行文本。
    public var header: String?
    public var jsLib: String?
    public var enabledCookieJar: Bool?
    public var loginCheckJs: String?
    /// 源级语速，0..80，实际倍速为 (speed + 5) / 10；nil 表示按默认 5 处理。
    public var speed: Int?
    public var synthesisThreadCount: Int?

    public init(
        id: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        name: String,
        url: String,
        contentType: String? = nil,
        concurrentRate: String? = nil,
        loginUrl: String? = nil,
        loginUi: String? = nil,
        header: String? = nil,
        jsLib: String? = nil,
        enabledCookieJar: Bool? = nil,
        loginCheckJs: String? = nil,
        speed: Int? = nil,
        synthesisThreadCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.contentType = contentType
        self.concurrentRate = concurrentRate
        self.loginUrl = loginUrl
        self.loginUi = loginUi
        self.header = header
        self.jsLib = jsLib
        self.enabledCookieJar = enabledCookieJar
        self.loginCheckJs = loginCheckJs
        self.speed = speed
        self.synthesisThreadCount = synthesisThreadCount
    }

    /// 传给 URL 模板的语速，缺省时与安卓端一致按 5 处理。
    public var effectiveSpeed: Int {
        speed ?? 5
    }
}

public enum HttpTTSImportError: Error, LocalizedError {
    case emptyInput
    case notJSON
    case entryNotObject(index: Int)
    case missingRequiredField(index: Int)
    case noValidSource

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "语音源内容为空"
        case .notJSON:
            return "语音源不是合法 JSON"
        case .entryNotObject(let index):
            return "第 \(index + 1) 条语音源不是 JSON 对象"
        case .missingRequiredField(let index):
            return "第 \(index + 1) 条语音源缺少 name 或 url"
        case .noValidSource:
            return "没有解析出任何可用的语音源"
        }
    }
}

extension HttpTTS {

    /// 解析 `httpTTS.json`：顶层为单个对象或对象数组都接受。
    public static func parse(json: String) throws -> [HttpTTS] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HttpTTSImportError.emptyInput }
        guard let data = trimmed.data(using: .utf8) else { throw HttpTTSImportError.notJSON }
        return try parse(jsonData: data)
    }

    public static func parse(jsonData: Data) throws -> [HttpTTS] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            throw HttpTTSImportError.notJSON
        }

        if let array = object as? [Any] {
            var sources: [HttpTTS] = []
            for (index, element) in array.enumerated() {
                guard let dict = element as? [String: Any] else {
                    throw HttpTTSImportError.entryNotObject(index: index)
                }
                guard let source = HttpTTS(jsonObject: dict) else {
                    throw HttpTTSImportError.missingRequiredField(index: index)
                }
                sources.append(source)
            }
            guard !sources.isEmpty else { throw HttpTTSImportError.noValidSource }
            return sources
        }

        if let dict = object as? [String: Any] {
            guard let source = HttpTTS(jsonObject: dict) else {
                throw HttpTTSImportError.missingRequiredField(index: 0)
            }
            return [source]
        }

        throw HttpTTSImportError.notJSON
    }

    public init?(jsonObject: [String: Any]) {
        guard let name = HttpTTS.string(jsonObject["name"]), !name.isEmpty,
              let url = HttpTTS.string(jsonObject["url"]), !url.isEmpty else {
            return nil
        }

        self.init(
            id: HttpTTS.int64(jsonObject["id"]) ?? Int64(Date().timeIntervalSince1970 * 1000),
            name: name,
            url: url,
            contentType: HttpTTS.string(jsonObject["contentType"]),
            concurrentRate: HttpTTS.string(jsonObject["concurrentRate"]),
            loginUrl: HttpTTS.string(jsonObject["loginUrl"]),
            loginUi: HttpTTS.rawString(jsonObject["loginUi"]),
            header: HttpTTS.string(jsonObject["header"]),
            jsLib: HttpTTS.string(jsonObject["jsLib"]),
            enabledCookieJar: jsonObject["enabledCookieJar"] as? Bool,
            loginCheckJs: HttpTTS.string(jsonObject["loginCheckJs"]),
            speed: HttpTTS.int(jsonObject["speed"]),
            synthesisThreadCount: HttpTTS.int(jsonObject["synthesisThreadCount"])
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let str = value as? String { return str }
        if value is NSNull { return nil }
        return "\(value)"
    }

    /// `loginUi` 在安卓端既可能是字符串，也可能是 JSON 数组，这里原样保留成字符串。
    private static func rawString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let str = value as? String { return str }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else {
            return "\(value)"
        }
        return json
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        return number.int64Value
    }
}
