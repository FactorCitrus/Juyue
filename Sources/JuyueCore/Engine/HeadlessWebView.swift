import Foundation

/// 无声网页抓取请求。`html` 非空时直接渲染这段 HTML（POST 等已由普通请求取回正文），
/// 否则加载 `url`。`javaScript` 为空时只渲染页面；有值时在 `didFinish` 后执行。
public struct HeadlessWebRequest {
    public let url: URL
    public let headers: [String: String]
    /// 已经拿到的 HTML；用于把 POST 响应交给 WebView 渲染，`url` 只作 baseURL。
    public let html: String?
    public let javaScript: String?
    public let timeout: TimeInterval
    /// `ContentRule.sourceRegex` 需要页面加载过的资源 URL；只在有嗅探需求时采集。
    public let capturesResourceURLs: Bool

    public init(
        url: URL,
        headers: [String: String] = [:],
        html: String? = nil,
        javaScript: String? = nil,
        timeout: TimeInterval = HeadlessWebView.defaultTimeout,
        capturesResourceURLs: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.html = html
        self.javaScript = javaScript
        self.timeout = timeout
        self.capturesResourceURLs = capturesResourceURLs
    }
}

/// 渲染后的页面。`javaScriptResult` 只在请求带脚本且脚本执行成功时才有值。
public struct HeadlessWebResult {
    public let finalURL: URL
    public let html: String
    public let javaScriptResult: String?
    /// 页面加载过程中产生的资源 URL，供 `ContentRule.sourceRegex` 嗅探。
    public let resourceURLs: [String]

    public init(
        finalURL: URL,
        html: String,
        javaScriptResult: String? = nil,
        resourceURLs: [String] = []
    ) {
        self.finalURL = finalURL
        self.html = html
        self.javaScriptResult = javaScriptResult
        self.resourceURLs = resourceURLs
    }
}

public enum HeadlessWebError: LocalizedError {
    case unavailable
    case timedOut
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "无声网页未安装"
        case .timedOut:
            return "无声网页加载超时"
        case .loadFailed(let message):
            return "无声网页加载失败：\(message)"
        }
    }
}

public typealias HeadlessWebLoader = (HeadlessWebRequest) async throws -> HeadlessWebResult

/// Core 层不直接依赖 WebKit：App 启动时把真正的 WKWebView 实现装进 `loader`。
/// 没装（例如跑单元测试、macOS 不提供实现）时，调用方回退普通请求。
public final class HeadlessWebView {
    public static let shared = HeadlessWebView()

    /// 一次网页抓取的默认上限；正文分页还会在这个上限内再按剩余时间收紧。
    public static let defaultTimeout: TimeInterval = 20

    public var loader: HeadlessWebLoader?

    public var isAvailable: Bool { loader != nil }

    private init() {}
}

/// `webJs` 结果选择：非空（trim 后）优先，空结果交回页面 HTML 走原规则。
public enum WebJsContent {
    public static func text(from scriptResult: String?) -> String? {
        guard let text = scriptResult?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }
}
