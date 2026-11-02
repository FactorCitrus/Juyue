import Foundation

/// 一次 HTTP 往返的结果。文本给规则脚本，原始字节给图片和压缩包。
public struct NetworkResponse {
    public let bodyString: String
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(statusCode: Int, bodyString: String, data: Data, headers: [String: String]) {
        self.statusCode = statusCode
        self.bodyString = bodyString
        self.data = data
        self.headers = headers
    }
}

/// 所有出网流量的唯一出口：搜索、目录、正文、封面、脚本 `java.ajax` 都走这里。
public class NetworkClient {
    public static let shared = NetworkClient()

    /// 普通请求与脚本里的 `java.getWebViewUA()` 共用同一个 UA。
    public static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// 已解析好的请求：网址、方法、头、体都不再变化。
    public struct ParsedRequest {
        public let url: URL
        public let method: String
        public let headers: [String: String]
        public let body: Data?
    }

    /// `data:;base64,<载荷>,<扩展名>` 是聚合源打包参数的写法，不能真的发请求。
    /// 返回解出的 UTF-8 文本；不是这种网址就返回 nil。
    public static func dataURLPayload(_ rawUrl: String) -> String? {
        guard rawUrl.hasPrefix("data:"),
              let marker = rawUrl.range(of: "base64,") else {
            return nil
        }
        let remainder = rawUrl[marker.upperBound...]
        let token = remainder.prefix { $0 != "," }
        guard !token.isEmpty,
              let bytes = Data(base64Encoded: String(token)) else {
            return nil
        }
        return String(data: bytes, encoding: .utf8)
    }

    public static func parseJuyueUrl(
        _ rawUrl: String,
        defaultHeader: String? = nil,
        baseUrl: String? = nil
    ) -> ParsedRequest? {
        var headers = ["User-Agent": defaultUserAgent]
        HeaderMerger.merge(defaultHeader, into: &headers)

        let split = RequestTail(raw: rawUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        var address = split.address
        var method = "GET"
        var payload: Data?

        if let options = split.options {
            if let declared = options["method"] as? String {
                method = declared.uppercased()
            }
            if let extras = options["headers"] as? [String: Any] {
                for (name, value) in extras {
                    headers[name] = "\(value)"
                }
            }
            if let body = options["body"] {
                if let text = body as? String {
                    payload = text.data(using: .utf8)
                } else if let encoded = try? JSONSerialization.data(withJSONObject: body) {
                    payload = encoded
                    if headers["Content-Type"] == nil {
                        headers["Content-Type"] = "application/json; charset=utf-8"
                    }
                }
            }
        }

        address = RelativeAddress.resolve(address, against: baseUrl)

        guard let url = URLCandidate.resolve(address) else { return nil }
        return ParsedRequest(url: url, method: method, headers: headers, body: payload)
    }

    public func request(parsed: ParsedRequest) async throws -> NetworkResponse {
        try await request(parsed: parsed, timeout: nil)
    }

    public func request(
        parsed: ParsedRequest,
        timeout: TimeInterval?,
        rateKey: String? = nil,
        rateLimit: SourceRateLimit? = nil
    ) async throws -> NetworkResponse {
        if let rateKey, let rateLimit {
            await SourceRateLimiter.shared.acquire(key: rateKey, limit: rateLimit)
        }
        let built = RequestBuilder.make(parsed, timeout: timeout)
        let (bytes, reply) = try await session.data(for: built)
        return ReplyPackager.package(bytes: bytes, reply: reply)
    }

    /// 同步请求，规则脚本求值用；脚本环境里没有 async。
    /// 日志只记 host、状态码和大小，不把整条 URL 写出去。
    public func requestSync(
        parsed: ParsedRequest,
        timeout: TimeInterval = 15.0,
        rateKey: String? = nil,
        rateLimit: SourceRateLimit? = nil
    ) -> NetworkResponse? {
        if let rateKey, let rateLimit {
            SourceRateLimiter.shared.acquireSync(key: rateKey, limit: rateLimit)
        }

        let built = RequestBuilder.make(parsed, timeout: timeout)
        let host = parsed.url.host ?? "?"
        let began = Date()
        let semaphore = DispatchSemaphore(value: 0)
        var result: NetworkResponse?

        session.dataTask(with: built) { bytes, reply, failure in
            defer { semaphore.signal() }
            let cost = Int(Date().timeIntervalSince(began) * 1000)

            if let failure {
                JuyueLog.log("[NET] \(host) 失败 code=\((failure as NSError).code) \(cost)ms")
                return
            }
            guard let bytes else {
                JuyueLog.log("[NET] \(host) 空响应 \(cost)ms")
                return
            }
            let packed = ReplyPackager.package(bytes: bytes, reply: reply)
            JuyueLog.log("[NET] \(host) \(packed.statusCode) \(bytes.count)B \(cost)ms")
            result = packed
        }.resume()

        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }
}

// MARK: - 请求头

private enum HeaderMerger {
    static func merge(_ raw: String?, into headers: inout [String: String]) {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }

        if let data = text.data(using: .utf8),
           let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (name, value) in fields {
                headers[name] = "\(value)"
            }
            return
        }

        if text.hasPrefix("Cookie:") {
            headers["Cookie"] = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            return
        }

        if text.contains("="), !text.contains("{") {
            headers["Cookie"] = text
            return
        }

        guard text.contains(":") else { return }
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
    }
}

// MARK: - 网址尾部选项

private struct RequestTail {
    let address: String
    let options: [String: Any]?

    init(raw: String) {
        guard let comma = raw.firstIndex(of: ",") else {
            address = raw
            options = nil
            return
        }

        let afterComma = raw[raw.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        guard afterComma.hasPrefix("{") else {
            address = raw
            options = nil
            return
        }

        let head = String(raw[..<comma]).trimmingCharacters(in: .whitespaces)
        guard let data = afterComma.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            address = head
            options = nil
            return
        }
        address = head
        options = parsed
    }
}

private enum RelativeAddress {
    static func resolve(_ address: String, against base: String?) -> String {
        guard address.hasPrefix("/"),
              let base = base?.trimmingCharacters(in: .whitespacesAndNewlines),
              !base.isEmpty else {
            return address
        }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        return root + address
    }
}

private enum URLCandidate {
    static func resolve(_ text: String) -> URL? {
        if let direct = URL(string: text) {
            return direct
        }
        guard let escaped = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: escaped)
    }
}

// MARK: - 请求与响应

private enum RequestBuilder {
    static func make(_ parsed: NetworkClient.ParsedRequest, timeout: TimeInterval?) -> URLRequest {
        var request = URLRequest(url: parsed.url)
        request.httpMethod = parsed.method
        request.httpBody = parsed.body
        if let timeout {
            request.timeoutInterval = timeout
        }
        for (name, value) in parsed.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

private enum ReplyPackager {
    static func package(bytes: Data, reply: URLResponse?) -> NetworkResponse {
        let http = reply as? HTTPURLResponse
        var headers: [String: String] = [:]
        if let all = http?.allHeaderFields {
            for (name, value) in all {
                headers["\(name)"] = "\(value)"
            }
        }
        let text = String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
        return NetworkResponse(
            statusCode: http?.statusCode ?? 200,
            bodyString: text,
            data: bytes,
            headers: headers
        )
    }
}
