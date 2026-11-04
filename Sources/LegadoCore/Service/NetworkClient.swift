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
    /// 测试可以注入假实现；不传时用 App 启动时安装的无声网页。
    private let headlessLoader: HeadlessWebLoader?

    public init(session: URLSession = .shared, headlessLoader: HeadlessWebLoader? = nil) {
        self.session = session
        self.headlessLoader = headlessLoader
    }

    /// 拆好的请求：网址不再二次解析，方法、头、体都已定。
    public struct ParsedRequest {
        public let url: URL
        public let method: String
        public let headers: [String: String]
        public let body: Data?
        /// 书源的 `,{"webView":true}`：请求要走渲染后的页面。
        public let usesWebView: Bool

        public init(
            url: URL,
            method: String,
            headers: [String: String],
            body: Data?,
            usesWebView: Bool = false
        ) {
            self.url = url
            self.method = method
            self.headers = headers
            self.body = body
            self.usesWebView = usesWebView
        }
    }

    /// 默认 UA：普通请求与脚本里的 `java.getWebViewUA()` 用同一个，免得两边对不上。
    public static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

    /// `data:;base64,<载荷>,<扩展名>` 不是真网址，是聚合源把参数打包塞进来的。
    ///
    /// 宿主不能去请求它：载荷要原样交给规则脚本（详情走 `ruleBookInfo.init`、
    /// 目录走 `chapterList`、正文走 `ruleContent.content`），由脚本自己发请求再返回内容。
    /// 解出来就返回字符串，不是 data: 网址返回 nil。
    public static func dataURLPayload(_ rawUrl: String) -> String? {
        guard rawUrl.hasPrefix("data:") else { return nil }
        let body = rawUrl.dropFirst("data:".count)
        guard let comma = body.firstIndex(of: ",") else { return nil }
        let meta = body[..<comma].lowercased()
        let payload = String(body[body.index(after: comma)...])

        if meta.hasSuffix(";base64") {
            // 聚合源会在载荷后再挂一段 `,<扩展信息>`，只取第一段 base64。
            let encoded = payload.prefix { $0 != "," }
            guard !encoded.isEmpty,
                  let decoded = Data(base64Encoded: String(encoded)) else { return nil }
            return String(data: decoded, encoding: .utf8)
        }

        guard let decoded = payload.removingPercentEncoding, !decoded.isEmpty else {
            return nil
        }
        return decoded
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

    /// 渲染后的地址若带自定义协议（`moyue://...`），返回协议名。
    /// 调用方据此给出「iOS 暂不支持」而不是笼统的 URL 解析失败。
    public static func unsupportedScheme(in rawUrl: String) -> String? {
        let raw = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return BookSourceSchemeClassifier.unsupportedRequestScheme(in: splitTrailingOptions(raw).address)
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
        var usesWebView = false

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
            usesWebView = WebViewOption.isEnabled(options["webView"])
        }

        address = resolveRelativeAddress(address, against: baseUrl)

        // 自定义协议没有 URLSession 处理器，放过去只会得到 -1002「不支持的 URL」。
        if case .custom = BookSourceSchemeClassifier.classify(address) {
            return nil
        }

        // 相对地址在 base 不合法时解不出 scheme，交给 URLSession 只会报 0 号错误；
        // 这里直接当解析失败处理，避免拼出半截地址。
        guard let url = resolveURL(address), url.scheme?.isEmpty == false else { return nil }
        return ParsedRequest(
            url: url,
            method: verb,
            headers: headers,
            body: payload,
            usesWebView: usesWebView
        )
    }

    /// 安卓导出的写法很杂：布尔、字符串 `"true"` / `"false"`，甚至数字。
    /// 只有明确的假值才关掉，其余非空值按开启处理。
    private enum WebViewOption {
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

    /// 绝对地址、`/` 开头和不带 `/` 的相对路径都交给 `URL(string:relativeTo:)`。
    /// 返回前剥掉 fragment：`#...` 不会发给服务器。
    private static func resolveRelativeAddress(_ address: String, against base: String?) -> String {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return address }

        // bookSourceUrl 本身不是合法网址时不能拼，原样返回，后面会因为缺 scheme 被拒。
        guard let rawBase = base?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawBase.isEmpty,
              let baseURL = URL(string: rawBase),
              baseURL.scheme != nil else {
            return strippingFragment(address)
        }

        if let resolved = URL(string: address, relativeTo: baseURL)?.absoluteURL {
            return strippingFragment(resolved.absoluteString)
        }
        if let escaped = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let resolved = URL(string: escaped, relativeTo: baseURL)?.absoluteURL {
            return strippingFragment(resolved.absoluteString)
        }
        return strippingFragment(address)
    }

    private static func resolveURL(_ text: String) -> URL? {
        if let direct = URL(string: text) { return direct }
        guard let escaped = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: escaped)
    }

    private static func strippingFragment(_ text: String) -> String {
        guard let hash = text.firstIndex(of: "#") else { return text }
        return String(text[..<hash])
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
    /// 书源站不少还是 GBK/GB2312：先信响应头，再嗅 HTML 前 2KB 的 meta，最后回退 UTF-8。
    static func package(bytes: Data, response: URLResponse?) -> NetworkResponse {
        let http = response as? HTTPURLResponse
        var fields: [String: String] = [:]
        if let all = http?.allHeaderFields {
            for (name, value) in all { fields["\(name)"] = "\(value)" }
        }
        let text = decode(bytes, declaredCharset: http?.textEncodingName)
        return NetworkResponse(statusCode: http?.statusCode ?? 200,
                               bodyString: text,
                               data: bytes,
                               headers: fields)
    }

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
        if parsed.usesWebView, let response = await headlessResponse(for: parsed, timeout: timeout) {
            return response
        }
        let req = makeURLRequest(from: parsed, timeout: timeout)
        let (bytes, response) = try await session.data(for: req)
        return Self.package(bytes: bytes, response: response)
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

        let req = makeURLRequest(from: parsed, timeout: limit)
        let (bytes, response) = try await session.data(for: req)
        let packed = Self.package(bytes: bytes, response: response)
        return try await loader(HeadlessWebRequest(
            url: response.url ?? parsed.url,
            headers: parsed.headers,
            html: packed.bodyString,
            javaScript: javaScript,
            timeout: limit,
            capturesResourceURLs: capturesResourceURLs
        ))
    }

    /// `webView: true` 走无声网页；没装抓取器或抓取失败时返回 nil，让调用方回退 URLSession。
    private func headlessResponse(for parsed: ParsedRequest, timeout: TimeInterval?) async -> NetworkResponse? {
        let host = parsed.url.host ?? "?"
        guard headlessLoader != nil || HeadlessWebView.shared.loader != nil else {
            LegadoLog.log("[NET] webView 请求没有无声网页实现，回退普通请求 host=\(host)")
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
            LegadoLog.log("[NET] webView \(host) \(cost)ms \(data.count)B")
            return NetworkResponse(
                statusCode: 200,
                bodyString: result.html,
                data: data,
                headers: ["Content-Type": "text/html; charset=utf-8"]
            )
        } catch {
            let cost = Int(Date().timeIntervalSince(began) * 1000)
            LegadoLog.log("[NET] webView 失败 \(host) \(cost)ms，回退普通请求：\(error.localizedDescription)")
            return nil
        }
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
