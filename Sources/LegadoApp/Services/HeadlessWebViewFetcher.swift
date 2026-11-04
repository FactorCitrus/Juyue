import Foundation
#if canImport(LegadoCore)
import LegadoCore
#endif

#if canImport(WebKit)
import WebKit
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 把 Core 的无声网页闭包接到 WKWebView：页面不上屏、不弹窗，
/// 加载完成后取最终 URL 和 HTML，请求带脚本时再执行一次并返回结果。
enum HeadlessWebViewFetcher {
    static func install() {
        guard HeadlessWebView.shared.loader == nil else { return }
        HeadlessWebView.shared.loader = { request in
            try await load(request)
        }
    }

    @MainActor
    private static func load(_ request: HeadlessWebRequest) async throws -> HeadlessWebResult {
        try await HeadlessPage(request: request).run()
    }
}

@MainActor
private final class HeadlessPage: NSObject, WKNavigationDelegate {
    private let request: HeadlessWebRequest
    private let webView: WKWebView
    private var continuation: CheckedContinuation<HeadlessWebResult, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var scriptResult: String?
    private var finished = false

    init(request: HeadlessWebRequest) {
        self.request = request

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        // 不上屏也要有个尺寸：部分站点靠视口宽度决定是否渲染正文。
        self.webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
            configuration: configuration
        )
        super.init()

        webView.navigationDelegate = self
        webView.customUserAgent = Self.userAgent(from: request.headers)
    }

    func run() async throws -> HeadlessWebResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                start()
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func start() {
        let timeout = max(1, request.timeout)
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(HeadlessWebError.timedOut))
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = timeout
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        load(urlRequest)
    }

    /// WKWebView 的 Cookie 存储是异步的：等全部写进去再导航，
    /// 否则第一批请求可能不带登录 Cookie。
    private func load(_ urlRequest: URLRequest) {
        let cookies = Self.cookies(from: request)
        guard !cookies.isEmpty else {
            startNavigation(urlRequest)
            return
        }
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.startNavigation(urlRequest)
        }
    }

    private func startNavigation(_ urlRequest: URLRequest) {
        if let html = request.html {
            webView.loadHTMLString(html, baseURL: request.url)
        } else {
            webView.load(urlRequest)
        }
    }

    // MARK: - 导航

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        runUserScript()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(HeadlessWebError.loadFailed(error.localizedDescription)))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        // 超时/取消时 WebKit 会报一次 NSURLErrorCancelled，别覆盖已有结果。
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        finish(.failure(HeadlessWebError.loadFailed(error.localizedDescription)))
    }

    // MARK: - 取页面

    private func runUserScript() {
        let script = request.javaScript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !script.isEmpty else {
            capturePage()
            return
        }

        // 与安卓 BackstageWebView 对齐：脚本里可以直接用 result / src / baseUrl。
        let prelude = """
        var result = document.documentElement ? document.documentElement.outerHTML : '';
        var src = result;
        var baseUrl = String(location.href || '');
        """
        webView.evaluateJavaScript(prelude + "\n" + script) { [weak self] value, error in
            guard let self else { return }
            if let error {
                LegadoLog.log("[网页] webJs 执行失败 \(error.localizedDescription)")
            }
            self.scriptResult = error == nil ? Self.string(from: value) : nil
            self.capturePage()
        }
    }

    private func capturePage() {
        let script = """
        JSON.stringify({
          h: document.documentElement ? document.documentElement.outerHTML : '',
          u: String(location.href || '')
        })
        """
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(HeadlessWebError.loadFailed(error.localizedDescription)))
                return
            }
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                self.finish(.failure(HeadlessWebError.loadFailed("无法读取页面 HTML")))
                return
            }

            let finalURL = object["u"]
                .flatMap { $0.isEmpty || $0 == "about:blank" ? nil : URL(string: $0) }
                ?? self.request.url
            self.captureResourceURLs { urls in
                self.finish(.success(HeadlessWebResult(
                    finalURL: finalURL,
                    html: object["h"] ?? "",
                    javaScriptResult: self.scriptResult,
                    resourceURLs: urls
                )))
            }
        }
    }

    /// `ContentRule.sourceRegex` 的资源嗅探：页面加载过的 URL 全在 Performance Resource Timing 里。
    /// 采集失败只影响嗅探，不影响页面本身。
    private func captureResourceURLs(_ completion: @escaping ([String]) -> Void) {
        guard request.capturesResourceURLs else {
            completion([])
            return
        }
        let script = """
        JSON.stringify(performance.getEntriesByType('resource').map(function(e) { return e.name; }))
        """
        webView.evaluateJavaScript(script) { value, error in
            if let error {
                LegadoLog.log("[网页] 资源 URL 采集失败 \(error.localizedDescription)")
                completion([])
                return
            }
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let urls = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                completion([])
                return
            }
            completion(urls)
        }
    }

    private func finish(_ result: Result<HeadlessWebResult, Error>) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let pending = continuation
        continuation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        pending?.resume(with: result)
    }

    // MARK: - 请求头与 Cookie

    private static func userAgent(from headers: [String: String]) -> String {
        for (name, value) in headers where name.lowercased() == "user-agent" {
            if !value.isEmpty { return value }
        }
        return NetworkClient.defaultUserAgent
    }

    private static func cookies(from request: HeadlessWebRequest) -> [HTTPCookie] {
        guard let host = request.url.host,
              let header = request.headers.first(where: { $0.key.lowercased() == "cookie" })?.value,
              !header.isEmpty else {
            return []
        }
        var cookies: [HTTPCookie] = []
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  let cookie = HTTPCookie(properties: [
                    .name: name,
                    .value: value,
                    .domain: host,
                    .path: "/",
                    .secure: request.url.scheme == "https" ? "TRUE" : "FALSE"
                  ]) else {
                continue
            }
            cookies.append(cookie)
        }
        return cookies
    }

    private static func string(from value: Any?) -> String? {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            return array.map { "\($0)" }.joined(separator: ",")
        case let object as [String: Any]:
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }
}
#else
enum HeadlessWebViewFetcher {
    /// 当前平台没有 WebKit：不安装抓取器，`webView` / `webJs` 自动回退普通请求。
    static func install() {}
}
#endif
