import Foundation

public enum HttpTTSError: Error, LocalizedError {
    case invalidURL(String)
    case serverReturnedText(String)
    case unexpectedContentType(actual: String, expected: String)
    case emptyAudio
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let rule):
            return "语音源地址无法解析：\(rule)"
        case .serverReturnedText(let body):
            return "TTS 服务器返回文本而不是音频：\(body)"
        case .unexpectedContentType(let actual, let expected):
            return "TTS 服务器返回类型不匹配：实际 \(actual)，期望 \(expected)"
        case .emptyAudio:
            return "TTS 服务器返回空音频"
        case .httpStatus(let code):
            return "TTS 请求失败，HTTP \(code)"
        }
    }
}

public struct TTSAudio {
    public let data: Data
    public let contentType: String?
    public let statusCode: Int
}

/// 在线朗读引擎：把语音源的 URL 规则渲染成请求，取回音频。
public final class HttpTTSEngine {
    public static let shared = HttpTTSEngine()

    private let client: NetworkClient
    private let renderer: TTSTemplateRenderer

    public init(client: NetworkClient = .shared, renderer: TTSTemplateRenderer = .shared) {
        self.client = client
        self.renderer = renderer
    }

    /// 渲染 URL 规则并解析成可发送的请求。
    public func makeRequest(source: HttpTTS, text: String, speed: Int? = nil) throws -> NetworkClient.ParsedRequest {
        let context = TTSTemplateContext(speakText: text, speakSpeed: speed ?? source.effectiveSpeed)
        let rendered = try renderer.render(source.url, context: context)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = NetworkClient.parseLegadoUrl(rendered, defaultHeader: source.header) else {
            throw HttpTTSError.invalidURL(rendered)
        }
        return parsed
    }

    /// 取一段文字的音频。校验逻辑对齐安卓端 HttpReadAloudService。
    public func fetchAudio(source: HttpTTS, text: String, speed: Int? = nil) async throws -> TTSAudio {
        let parsed = try makeRequest(source: source, text: text, speed: speed)
        let response = try await client.request(parsed: parsed)

        let contentType = HttpTTSEngine.baseContentType(response.headers["Content-Type"])
            ?? HttpTTSEngine.baseContentType(response.headers["content-type"])
        try HttpTTSEngine.validate(contentType: contentType, body: response.bodyString, source: source)

        guard !response.data.isEmpty else {
            throw HttpTTSError.emptyAudio
        }
        return TTSAudio(data: response.data, contentType: contentType, statusCode: response.statusCode)
    }

    /// 返回音频就接受；返回 JSON / 文本一律当作失败，并把正文带出去便于排查。
    public static func validate(contentType: String?, body: String, source: HttpTTS) throws {
        if let contentType = contentType?.lowercased() {
            if contentType == "application/json" || contentType.hasPrefix("text/") {
                throw HttpTTSError.serverReturnedText(String(body.prefix(200)))
            }
            let expected = source.contentType?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let expected, !expected.isEmpty, !matches(actual: contentType, expected: expected) {
                throw HttpTTSError.unexpectedContentType(actual: contentType, expected: expected)
            }
        }
    }

    /// 安卓端用的是 `contentType.matches(ct.toRegex())`，这里按同样的正则语义匹配。
    public static func matches(actual: String, expected: String) -> Bool {
        if actual == expected { return true }
        guard let regex = try? NSRegularExpression(pattern: expected) else {
            return actual == expected
        }
        let range = NSRange(actual.startIndex..<actual.endIndex, in: actual)
        return regex.firstMatch(in: actual, options: [], range: range) != nil
    }

    /// 去掉 `audio/mpeg; charset=utf-8` 后面的参数部分。
    public static func baseContentType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return value.isEmpty ? nil : value
    }
}
