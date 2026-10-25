import Foundation

/// 一次 HTTP 往返的结果。字符串给规则脚本用，原始字节留给图片、压缩包这类不能当文本解的东西。
public struct NetworkResponse {
    public let bodyString: String
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(statusCode: Int, bodyString: String, data: Data, headers: [String: String]) {
        self.bodyString = bodyString
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

/// 所有出网流量的唯一出口：规则脚本的 `java.ajax`、目录分页、正文抓取、封面下载都从这里走。
public class NetworkClient {
    public static let shared = NetworkClient()
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// 拆好的请求：网址不再二次解析，方法、头、体都已定。
    public struct ParsedRequest {
        public let url: URL
        public let method: String
        public let headers: [String: String]
        public let body: Data?
    }

    /// 默认 UA：普通请求与脚本里的 `java.getWebViewUA()` 用同一个，免得两边对不上。
    public static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

    /// `data:;base64,<载荷>,<扩展名>` 不是真网址，是聚合源把参数打包塞进来的。
    ///
    /// 宿主不能去请求它：载荷要原样交给规则脚本（详情走 `ruleBookInfo.init`、
    /// 目录走 `chapterList`、正文走 `ruleContent.content`），由脚本自己发请求再返回内容。
    /// 解出来就返回字符串，不是 data: 网址返回 nil。
    public static func dataURLPayload(_ rawUrl: String) -> String? {
        guard rawUrl.hasPrefix("data:"),
              let marker = rawUrl.range(of: "base64,") else { return nil }
        let rest = rawUrl[marker.upperBound...]
        let encoded = rest.prefix { $0 != "," }
        guard !encoded.isEmpty,
              let decoded = Data(base64Encoded: String(encoded)) else { return nil }
        return String(data: decoded, encoding: .utf8)
    }

    /// 把书源 `header` 字段并进请求头。三种写法都认：JSON 对象、`Cookie: xxx`、
    /// 或者 `Key: Value` 一行一个。写错了当没写——书源是用户导入的，容错优先于报错。
    private static func absorbDefaultHeader(_ raw: String?, into headers: inout [String: String]) {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }

        if let blob = text.data(using: .utf8),
           let fields = try? JSONSerialization.jsonObject(with: blob) as? [String: Any] {
            for (name, value) in fields { headers[name] = "\(value)" }
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
            let halves = line.split(separator: ":", maxSplits: 1)
            guard halves.count == 2 else { continue }
            let name = halves[0].trimmingCharacters(in: .whitespaces)
            let value = halves[1].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
    }

    /// 网址后面用逗号挂一段 JSON 选项：`https://host/search,{"method":"POST"}`。
    /// 逗号后面必须紧跟 `{` 才算选项，否则当成网址自带的逗号，原样保留。
    private static func splitTrailingOptions(_ raw: String) -> (address: String, options: [String: Any]?) {
        guard let comma = raw.firstIndex(of: ",") else { return (raw, nil) }
        let tail = raw[raw.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        guard tail.hasPrefix("{") else { return (raw, nil) }
        let head = String(raw[..<comma]).trimmingCharacters(in: .whitespaces)
        guard let blob = tail.data(using: .utf8),
              let options = try? JSONSerialization.jsonObject(with: blob) as? [String: Any] else {
            return (head, nil)
        }
        return (head, options)
    }

    /// 解析书源里那种「网址 + 逗号 + JSON」的写法，产出可直接发出去的请求。
    /// `baseUrl` 只在网址以 `/` 开头时参与拼接，用于相对路径的书源。
    public static func parseLegadoUrl(_ rawUrl: String, defaultHeader: String? = nil, baseUrl: String? = nil) -> ParsedRequest? {
        var headers: [String: String] = ["User-Agent": defaultUserAgent]
        absorbDefaultHeader(defaultHeader, into: &headers)

        let split = splitTrailingOptions(rawUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        var address = split.address
        var verb = "GET"
        var payload: Data?

        if let options = split.options {
            if let declared = options["method"] as? String {
                verb = declared.uppercased()
            }
            if let extra = options["headers"] as? [String: Any] {
                for (name, value) in extra { headers[name] = "\(value)" }
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

        if address.hasPrefix("/"),
           let base = baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !base.isEmpty {
            let stem = base.hasSuffix("/") ? String(base.dropLast()) : base
            address = stem + address
        }

        var resolved = URL(string: address)
        if resolved == nil,
           let escaped = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            resolved = URL(string: escaped)
        }
        guard let url = resolved else { return nil }
        return ParsedRequest(url: url, method: verb, headers: headers, body: payload)
    }

    /// 组 URLRequest。超时只在调用方给了值时才设，保持 URLSession 自己的默认。
    private func makeURLRequest(from parsed: ParsedRequest, timeout: TimeInterval?) -> URLRequest {
        var req = URLRequest(url: parsed.url)
        req.httpMethod = parsed.method
        req.httpBody = parsed.body
        if let timeout { req.timeoutInterval = timeout }
        for (field, value) in parsed.headers {
            req.setValue(value, forHTTPHeaderField: field)
        }
        return req
    }

    /// 把 URLResponse 拆成 NetworkResponse。非 HTTP 响应按 200 处理，跟以前一致。
    private static func package(bytes: Data, response: URLResponse?) -> NetworkResponse {
        let http = response as? HTTPURLResponse
        var fields: [String: String] = [:]
        if let all = http?.allHeaderFields {
            for (name, value) in all { fields["\(name)"] = "\(value)" }
        }
        let text = String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
        return NetworkResponse(statusCode: http?.statusCode ?? 200,
                               bodyString: text,
                               data: bytes,
                               headers: fields)
    }

    public func request(parsed: ParsedRequest) async throws -> NetworkResponse {
        try await request(parsed: parsed, timeout: nil)
    }

    /// 带超时的异步请求，目录分页这类批量抓取用，免得单页卡住整轮。
    /// `rateKey` / `rateLimit` 来自书源的 concurrentRate，发请求前先占限速窗口。
    public func request(
        parsed: ParsedRequest,
        timeout: TimeInterval?,
        rateKey: String? = nil,
        rateLimit: SourceRateLimit? = nil
    ) async throws -> NetworkResponse {
        if let rateKey, let rateLimit {
            await SourceRateLimiter.shared.acquire(key: rateKey, limit: rateLimit)
        }
        let req = makeURLRequest(from: parsed, timeout: timeout)
        let (bytes, response) = try await session.data(for: req)
        return Self.package(bytes: bytes, response: response)
    }

    /// 同步请求，规则脚本求值用（脚本环境里没有 async）。
    /// 日志只记 host 和错误码：系统错误描述里可能带整条 URL，连 path 一起泄出去。
    public func requestSync(
        parsed: ParsedRequest,
        timeout: TimeInterval = 15.0,
        rateKey: String? = nil,
        rateLimit: SourceRateLimit? = nil
    ) -> NetworkResponse? {
        if let rateKey, let rateLimit {
            SourceRateLimiter.shared.acquireSync(key: rateKey, limit: rateLimit)
        }
        let req = makeURLRequest(from: parsed, timeout: timeout)
        let host = parsed.url.host ?? "?"
        let began = Date()
        var outcome: NetworkResponse?
        let gate = DispatchSemaphore(value: 0)

        session.dataTask(with: req) { bytes, response, failure in
            defer { gate.signal() }
            let cost = Int(Date().timeIntervalSince(began) * 1000)
            if let failure {
                LegadoLog.log("[NET] \(host) 失败 code=\((failure as NSError).code) \(cost)ms")
                return
            }
            guard let bytes else {
                LegadoLog.log("[NET] \(host) 空响应 \(cost)ms")
                return
            }
            let packed = Self.package(bytes: bytes, response: response)
            LegadoLog.log("[NET] \(host) \(packed.statusCode) \(bytes.count)B \(cost)ms")
            outcome = packed
        }.resume()

        _ = gate.wait(timeout: .now() + timeout)
        return outcome
    }
}
