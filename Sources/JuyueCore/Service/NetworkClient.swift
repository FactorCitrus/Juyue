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
    /// 测试可以注入假实现；不传时用 App 启动时安装的无声网页。
    private let headlessLoader: HeadlessWebLoader?

    public init(session: URLSession = .shared, headlessLoader: HeadlessWebLoader? = nil) {
        self.session = session
        self.headlessLoader = headlessLoader
    }

    /// 已解析好的请求：网址、方法、头、体都不再变化。
    public struct ParsedRequest {
        public let url: URL
        public let method: String
        public let headers: [String: String]
        public let body: Data?
        /// 书源的 `,{"webView":true}`：请求要走渲染后的页面。
        public let usesWebView: Bool
        /// 只在源显式要求时放宽证书校验（ExHentai 这类证书链不完整的站点）。
        public let insecureTLS: Bool

        public init(
            url: URL,
            method: String,
            headers: [String: String],
            body: Data?,
            usesWebView: Bool = false,
            insecureTLS: Bool = false
        ) {
            self.url = url
            self.method = method
            self.headers = headers
            self.body = body
            self.usesWebView = usesWebView
            self.insecureTLS = insecureTLS
        }
    }

    /// `data:;base64,<载荷>,<扩展名>` 是聚合源打包参数的写法，不能真的发请求。
    /// 返回解出的 UTF-8 文本；不是这种网址就返回 nil。
    /// 顺带支持 `data:text/plain,<百分号编码文本>` 这种非 base64 写法。
    public static func dataURLPayload(_ rawUrl: String) -> String? {
        guard rawUrl.hasPrefix("data:") else { return nil }
        let body = rawUrl.dropFirst("data:".count)
        guard let comma = body.firstIndex(of: ",") else { return nil }
        let meta = body[..<comma].lowercased()
        let payload = String(body[body.index(after: comma)...])

        if meta.hasSuffix(";base64") {
            // 聚合源会在载荷后再挂一段 `,<扩展信息>`，只取第一段 base64。
            let token = payload.prefix { $0 != "," }
            guard !token.isEmpty,
                  let bytes = Data(base64Encoded: String(token)) else {
                return nil
            }
            return String(data: bytes, encoding: .utf8)
        }

        guard let decoded = payload.removingPercentEncoding, !decoded.isEmpty else {
            return nil
        }
        return decoded
    }

    /// 渲染后的地址若带自定义协议（`moyue://...`），返回协议名。
    /// 调用方据此给出「iOS 暂不支持」而不是笼统的 URL 解析失败。
    public static func unsupportedScheme(in rawUrl: String) -> String? {
        let raw = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return BookSourceSchemeClassifier.unsupportedRequestScheme(in: RequestTail(raw: raw).address)
    }

    public static func parseJuyueUrl(
        _ rawUrl: String,
        defaultHeader: String? = nil,
        baseUrl: String? = nil,
        insecureTLS: Bool = false
    ) -> ParsedRequest? {
        var headers = ["User-Agent": defaultUserAgent]
        HeaderMerger.merge(defaultHeader, into: &headers)

        let split = RequestTail(raw: rawUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        var address = split.address
        var method = "GET"
        var payload: Data?
        var usesWebView = false
        var allowInsecureTLS = insecureTLS

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
            usesWebView = WebViewOption.isEnabled(options["webView"])
            if let flag = options["allowInsecureTLS"] as? Bool {
                allowInsecureTLS = flag
            }
        }

        address = RelativeAddress.resolve(address, against: baseUrl)

        // 自定义协议没有 URLSession 处理器，放过去只会得到 -1002「不支持的 URL」。
        if case .custom = BookSourceSchemeClassifier.classify(address) {
            return nil
        }

        // 相对地址在 base 不合法时解不出 scheme，交给 URLSession 只会报 0 号错误；
        // 这里直接当解析失败处理，避免拼出半截地址。
        guard let url = URLCandidate.resolve(address), url.scheme?.isEmpty == false else {
            return nil
        }
        return ParsedRequest(
            url: NetworkClient.aliasHost(url),
            method: method,
            headers: headers,
            body: payload,
            usesWebView: usesWebView,
            insecureTLS: allowInsecureTLS
        )
    }

    /// 书源里写死的域名未必存在。`lange.uk` 这一族后缀在公网是 NXDOMAIN，
    /// 大灰狼 5.11.x 把它当默认服务端，改源就得改用户手机上那份；
    /// 在请求层做后缀别名，旧源一个字不改也能连上。只换主机名，路径与查询照旧。
    static let hostAliases: [(suffix: String, replacement: String)] = [
        (".lange.uk", ".langge.uk")
    ]

    public static func aliasHost(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return url }
        for alias in hostAliases {
            // 裸域（`lange.uk` 本身）也要认，否则只有子域被换、根路径照旧打空气。
            if host == String(alias.suffix.dropFirst()) {
                components.host = String(alias.replacement.dropFirst())
                return components.url ?? url
            }
            guard host.hasSuffix(alias.suffix) else { continue }
            let head = String(host.dropLast(alias.suffix.count))
            components.host = head + alias.replacement
            return components.url ?? url
        }
        return url
    }

    /// 只有源显式要求时才用，接受证书链不完整的站点（ExHentai 等）。
    private lazy var insecureSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: InsecureTLSDelegate(), delegateQueue: nil)
    }()

    private func activeSession(for parsed: ParsedRequest) -> URLSession {
        parsed.insecureTLS ? insecureSession : session
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
        if parsed.usesWebView {
            if let response = await headlessResponse(for: parsed, timeout: timeout) {
                return response
            }
        }
        let built = RequestBuilder.make(parsed, timeout: timeout)
        let (bytes, reply) = try await activeSession(for: parsed).data(for: built)
        return ReplyPackager.package(bytes: bytes, reply: reply)
    }

    /// 用无声网页取页面，可选执行脚本。
    ///
    /// GET 直接加载网址；POST 等先走一次普通请求拿到 HTML，再让 WebView 渲染。
    /// WKWebView 不适合直接发 POST，而且书源里的 POST 搜索页往往要靠页面 JS 才出结果。
    public func headlessFetch(
        parsed: ParsedRequest,
        javaScript: String? = nil,
        timeout: TimeInterval? = nil,
        capturesResourceURLs: Bool = false
    ) async throws -> HeadlessWebResult {
        guard let loader = headlessLoader ?? HeadlessWebView.shared.loader else {
            throw HeadlessWebError.unavailable
        }
        let limit = timeout ?? HeadlessWebView.defaultTimeout

        if parsed.method == "GET", parsed.body == nil {
            return try await loader(HeadlessWebRequest(
                url: parsed.url,
                headers: parsed.headers,
                javaScript: javaScript,
                timeout: limit,
                capturesResourceURLs: capturesResourceURLs
            ))
        }

        let built = RequestBuilder.make(parsed, timeout: limit)
        let (bytes, reply) = try await activeSession(for: parsed).data(for: built)
        let packed = ReplyPackager.package(bytes: bytes, reply: reply)
        return try await loader(HeadlessWebRequest(
            url: reply.url ?? parsed.url,
            headers: parsed.headers,
            html: packed.bodyString,
            javaScript: javaScript,
            timeout: limit,
            capturesResourceURLs: capturesResourceURLs
        ))
    }

    /// `webView: true` 走无声网页；没装抓取器或抓取失败时返回 nil，让调用方回退 URLSession。
    private func headlessResponse(
        for parsed: ParsedRequest,
        timeout: TimeInterval?
    ) async -> NetworkResponse? {
        let host = parsed.url.host ?? "?"
        guard headlessLoader != nil || HeadlessWebView.shared.loader != nil else {
            JuyueLog.log("[NET] webView 请求没有无声网页实现，回退普通请求 host=\(host)")
            return nil
        }
        let began = Date()
        do {
            let result = try await headlessFetch(
                parsed: parsed,
                javaScript: nil,
                timeout: timeout
            )
            let data = Data(result.html.utf8)
            let cost = Int(Date().timeIntervalSince(began) * 1000)
            JuyueLog.log("[NET] webView \(host) \(cost)ms \(data.count)B")
            return NetworkResponse(
                statusCode: 200,
                bodyString: result.html,
                data: data,
                headers: ["Content-Type": "text/html; charset=utf-8"]
            )
        } catch {
            let cost = Int(Date().timeIntervalSince(began) * 1000)
            JuyueLog.log("[NET] webView 失败 \(host) \(cost)ms，回退普通请求：\(error.localizedDescription)")
            return nil
        }
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

        activeSession(for: parsed).dataTask(with: built) { bytes, reply, failure in
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

// MARK: - 证书校验

/// 仅供显式开启 `allowInsecureTLS` 的源使用；默认会话不走这里。
private final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
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

private enum WebViewOption {
    /// 安卓导出的写法很杂：布尔、字符串 `"true"` / `"false"`，甚至数字。
    /// 只有明确的假值才关掉，其余非空值按开启处理。
    static func isEnabled(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull:
            return false
        case let flag as Bool:
            return flag
        case let number as NSNumber:
            return number.boolValue
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !trimmed.isEmpty && trimmed != "false"
        default:
            return true
        }
    }
}

private enum RelativeAddress {
    /// 绝对地址、`/` 开头和不带 `/` 的相对路径都交给 `URL(string:relativeTo:)`，
    /// 比手写字符串拼接更贴近 RFC 3986。返回前剥掉 fragment：`#...` 不会发给
    /// 服务器，留着只会让缓存 key 对不上。
    static func resolve(_ address: String, against base: String?) -> String {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return address }

        // bookSourceUrl 本身不是合法网址时不能拼，否则会得到半截错误地址。
        // 原样返回，后面解析时会因为没有 scheme 被拒掉。
        guard let rawBase = base?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawBase.isEmpty,
              let baseURL = URL(string: rawBase),
              baseURL.scheme != nil else {
            return strippingFragment(address)
        }

        if let resolved = resolveURL(address, against: baseURL) {
            return strippingFragment(resolved.absoluteString)
        }
        if let escaped = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let resolved = resolveURL(escaped, against: baseURL) {
            return strippingFragment(resolved.absoluteString)
        }
        return strippingFragment(address)
    }

    private static func resolveURL(_ text: String, against base: URL) -> URL? {
        URL(string: text, relativeTo: base)?.absoluteURL
    }

    private static func strippingFragment(_ text: String) -> String {
        guard let hash = text.firstIndex(of: "#") else { return text }
        return String(text[..<hash])
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

enum ReplyPackager {
    static func package(bytes: Data, reply: URLResponse?) -> NetworkResponse {
        let http = reply as? HTTPURLResponse
        var headers: [String: String] = [:]
        if let all = http?.allHeaderFields {
            for (name, value) in all {
                headers["\(name)"] = "\(value)"
            }
        }
        let text = decode(bytes, declaredCharset: http?.textEncodingName)
        return NetworkResponse(
            statusCode: http?.statusCode ?? 200,
            bodyString: text,
            data: bytes,
            headers: headers
        )
    }

    /// 书源站不少还是 GBK/GB2312：先信响应头，再嗅 HTML 前 2KB 的 meta，
    /// 最后回退 UTF-8。同步和异步请求共用这里。
    static func decode(_ bytes: Data, declaredCharset: String?) -> String {
        if let name = declaredCharset,
           let encoding = encoding(forCharset: name),
           let text = String(data: bytes, encoding: encoding) {
            return text
        }
        if let name = sniffHTMLCharset(bytes),
           let encoding = encoding(forCharset: name),
           let text = String(data: bytes, encoding: encoding) {
            return text
        }
        return String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }

    static func encoding(forCharset name: String) -> String.Encoding? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(trimmed as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String.Encoding(rawValue: nsEncoding)
    }

    static func sniffHTMLCharset(_ bytes: Data) -> String? {
        let prefix = bytes.prefix(2048)
        guard let ascii = String(data: prefix, encoding: .isoLatin1) else { return nil }
        let text = ascii as NSString
        let range = NSRange(location: 0, length: text.length)
        let patterns = [
            #"<meta[^>]+charset\s*=\s*["']?\s*([A-Za-z0-9_\-]+)"#,
            #"content\s*=\s*["'][^"']*charset\s*=\s*([A-Za-z0-9_\-]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: ascii, options: [], range: range),
                  match.numberOfRanges > 1 else {
                continue
            }
            return text.substring(with: match.range(at: 1))
        }
        return nil
    }
}
