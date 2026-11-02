import SwiftUI
import WebKit
import Combine
#if canImport(JuyueCore)
import JuyueCore
#endif

public struct SourceWebLoginView: View {
    @StateObject private var session: SourceLoginSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    public init(source: BookSource, onLoginCompleted: ((BookSource) -> Void)? = nil) {
        _session = StateObject(wrappedValue: SourceLoginSession(source: source, onLoginCompleted: onLoginCompleted))
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                addressBar
                Divider()
                webArea
                if session.currentURL == nil {
                    emptyHint
                }
                Divider()
                navigationBar
            }
            .navigationTitle(session.source.bookSourceName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarItems }
            .sheet(isPresented: $session.showingManualSheet) { manualCookieEditor }
            .alert(session.alertText ?? "", isPresented: alertBinding) {
                Button("确定", role: .cancel) { session.alertText = nil }
            }
            .onAppear {
                session.loadStartPage()
                session.refreshCookies()
            }
            .onReceive(session.$isFinished.filter { $0 }) { _ in dismiss() }
        }
    }

    // MARK: - 地址栏

    private var addressBar: some View {
        HStack(spacing: 8) {
            if session.loading {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Image(systemName: "lock.shield.fill")
                    .font(.caption)
                    .foregroundColor(theme.palette.success)
            }

            TextField("登录页地址（https://…）", text: $session.address)
                .font(.caption2)
                .textFieldStyle(.plain)
                #if os(iOS)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                #endif
                .onSubmit { session.openTypedAddress() }

            Button("打开") { session.openTypedAddress() }
                .font(.caption)
                .disabled(session.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if session.candidates.count > 1 {
                Menu {
                    ForEach(Array(session.candidates.enumerated()), id: \.element) { offset, host in
                        Button(LoginPageResolver.label(for: host, position: offset)) {
                            session.address = host
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.caption)
                }
            }

            Spacer()

            if !session.cookies.isEmpty {
                Text("\(session.cookies.count) Cookies")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.palette.success.opacity(0.15))
                    .foregroundColor(theme.palette.success)
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.palette.elevated)
    }

    // MARK: - 网页与底栏

    private var webArea: some View {
        LoginWebViewHost(
            webView: session.webView,
            onStartLoading: { session.loading = true },
            onFinishLoading: { title, url in
                session.loading = false
                session.pageTitle = title
                session.currentURL = url
                session.refreshCookies()
            },
            onFailLoading: { session.loading = false }
        )
    }

    private var navigationBar: some View {
        HStack(spacing: 20) {
            Button { session.webView.goBack() } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!session.webView.canGoBack)

            Button { session.webView.goForward() } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!session.webView.canGoForward)

            Button { session.webView.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }

            Spacer()

            Button("手动粘贴 Cookie") { session.showingManualSheet = true }
                .font(.caption)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.palette.divider.opacity(0.05))
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 30))
                .foregroundColor(theme.palette.secondaryInk)
            Text("这个书源没有可直接打开的网页登录地址")
                .font(.subheadline.weight(.medium))
            Text("它的 loginUrl 是一段脚本，bookSourceUrl 也不是网址。\n上面地址栏里填的是从脚本里扒出来的主机名。把真正的登录页地址补上，点「打开」；也可以直接「手动粘贴 Cookie」，或者退回去走「表单脚本登录」。")
                .font(.caption)
                .foregroundColor(theme.palette.secondaryInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("保存并完成") { session.finish() }
                .font(.body.bold())
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { session.alertText != nil },
            set: { if !$0 { session.alertText = nil } }
        )
    }

    // MARK: - 手动 Cookie

    private var manualCookieEditor: some View {
        NavigationView {
            Form {
                Section(header: Text("粘贴 Cookie 字符串")) {
                    TextEditor(text: $session.manualCookie)
                        .frame(minHeight: 140)
                        .font(.system(.caption, design: .monospaced))
                    Text("已在他处登录时，可粘贴浏览器 Cookie，形如 ews_key=...; ews_token=...; PHPSESSID=...。")
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .appThemedRows()

                Section {
                    Button("保存并应用此 Cookie") { session.applyManualCookie() }
                        .disabled(session.manualCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .appThemedRows()
            }
            .appThemedList()
            .navigationTitle("手动填入 Cookie")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { session.showingManualSheet = false }
                }
            }
        }
    }
}

// MARK: - 登录会话

final class SourceLoginSession: ObservableObject {
    let source: BookSource
    let webView: WKWebView
    let candidates: [String]

    @Published var address: String
    @Published var currentURL: URL?
    @Published var pageTitle = ""
    @Published var loading = false
    @Published var cookies: [HTTPCookie] = []
    @Published var manualCookie = ""
    @Published var showingManualSheet = false
    @Published var alertText: String?
    @Published var isFinished = false

    private let onLoginCompleted: ((BookSource) -> Void)?

    init(source: BookSource, onLoginCompleted: ((BookSource) -> Void)?) {
        self.source = source
        self.onLoginCompleted = onLoginCompleted

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
        self.webView = browser

        let start = LoginPageResolver.startPage(for: source)
        self.candidates = LoginPageResolver.hosts(in: source)
        self.address = start.address
        self.currentURL = start.url
    }

    func loadStartPage() {
        guard let url = currentURL else { return }
        webView.load(URLRequest(url: url))
    }

    func openTypedAddress() {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return }
        currentURL = url
        webView.load(URLRequest(url: url))
    }

    func refreshCookies() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] all in
            guard let self else { return }
            let relevant = LoginCookieScope.relevant(all, source: self.source, currentURL: self.currentURL)
            DispatchQueue.main.async { self.cookies = relevant }
        }
    }

    func finish() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] all in
            guard let self else { return }
            let relevant = LoginCookieScope.relevant(all, source: self.source, currentURL: self.currentURL)
            DispatchQueue.main.async {
                guard !relevant.isEmpty else {
                    self.alertText = "未检测到该网站的有效 Cookie，请先在网页内输入账号密码完成登录，或点击底部「手动粘贴 Cookie」。"
                    return
                }
                self.cookies = relevant
                self.persist(
                    cookieHeader: relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
                    cookies: relevant
                )
            }
        }
    }

    func applyManualCookie() {
        let cleaned = manualCookie
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
        guard !cleaned.isEmpty else { return }
        showingManualSheet = false
        persist(cookieHeader: cleaned, cookies: [])
    }

    private func persist(cookieHeader: String, cookies: [HTTPCookie]) {
        var updated = source
        updated.loginHeader = LoginPayload.loginHeader(
            cookieHeader: cookieHeader,
            userAgent: webView.customUserAgent
        )
        updated.loginInfo = LoginPayload.loginInfo(
            cookieHeader: cookieHeader,
            pageURL: currentURL?.absoluteString ?? source.loginUrl ?? source.bookSourceUrl,
            cookieCount: cookies.count
        )
        LoginCookieScope.mirror(cookies, for: source.bookSourceUrl)

        BookStore.shared.updateSource(updated)
        onLoginCompleted?(updated)
        isFinished = true
    }
}

// MARK: - 登录地址解析

enum LoginPageResolver {
    struct StartPage {
        let address: String
        let url: URL?
    }

    static func startPage(for source: BookSource) -> StartPage {
        let seeds = [source.loginUrl ?? "", source.bookSourceUrl]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let usable = seeds.first(where: isWebAddress)
        let fallback = usable ?? hosts(in: source).first ?? ""
        return StartPage(address: fallback, url: usable.flatMap { URL(string: $0) })
    }

    static func hosts(in source: BookSource) -> [String] {
        let haystack = [source.loginUrl ?? "", source.jsLib ?? "", source.bookSourceUrl].joined(separator: "\n")
        guard let pattern = try? NSRegularExpression(pattern: #"https?://[A-Za-z0-9.\-]+"#) else { return [] }
        let range = NSRange(location: 0, length: (haystack as NSString).length)
        var ordered: [String] = []
        for match in pattern.matches(in: haystack, options: [], range: range) {
            guard ordered.count < 6,
                  let found = Range(match.range, in: haystack) else { break }
            let host = String(haystack[found])
            if !ordered.contains(host) {
                ordered.append(host)
            }
        }
        return ordered
    }

    static func label(for host: String, position: Int) -> String {
        let lower = host.lowercased()
        if lower.contains("fanqienovel") { return "番茄小说（\(host)）" }
        if lower.contains("langge") { return "大灰狼线路 \(position + 1)（\(host)）" }
        if lower.contains("cloudflare") { return "CDN 线路（\(host)）" }
        return "线路 \(position + 1)（\(host)）"
    }

    static func isWebAddress(_ value: String) -> Bool {
        guard let parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty else { return false }
        return true
    }
}

// MARK: - Cookie 范围与落盘格式

enum LoginCookieScope {
    static func relevant(_ cookies: [HTTPCookie], source: BookSource, currentURL: URL?) -> [HTTPCookie] {
        let raw = [source.bookSourceUrl, source.loginUrl ?? "", currentURL?.absoluteString ?? ""]
        var hosts: [String] = []
        for value in raw {
            guard let host = URL(string: value)?.host?.lowercased(), !host.isEmpty else { continue }
            if !hosts.contains(host) { hosts.append(host) }
        }
        guard !hosts.isEmpty else { return [] }

        return cookies.filter { cookie in
            let domain = cookie.domain
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !domain.isEmpty else { return false }
            return hosts.contains { $0.contains(domain) || domain.contains($0) }
        }
    }

    static func mirror(_ cookies: [HTTPCookie], for sourceURL: String) {
        let storage = HTTPCookieStorage.shared
        let targetHost = URL(string: sourceURL)?.host
        for cookie in cookies {
            storage.setCookie(cookie)
            guard let targetHost, targetHost != cookie.domain else { continue }
            var properties = cookie.properties ?? [:]
            properties[.domain] = targetHost
            if let mirrored = HTTPCookie(properties: properties) {
                storage.setCookie(mirrored)
            }
        }
    }
}

enum LoginPayload {
    private struct HeaderField: Encodable {
        let cookie: String
        let userAgent: String
        enum CodingKeys: String, CodingKey {
            case cookie = "Cookie"
            case userAgent = "User-Agent"
        }
    }

    private struct Metadata: Encodable {
        let type: String
        let url: String
        let cookiesCount: Int
        let date: String
        let preview: String
    }

    static func loginHeader(cookieHeader: String, userAgent: String?) -> String {
        let field = HeaderField(
            cookie: cookieHeader,
            userAgent: userAgent ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)"
        )
        guard let data = try? JSONEncoder().encode(field),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"Cookie\":\"\(cookieHeader)\"}"
        }
        return text
    }

    static func loginInfo(cookieHeader: String, pageURL: String, cookieCount: Int) -> String? {
        let meta = Metadata(
            type: "web_cookie",
            url: pageURL,
            cookiesCount: cookieCount,
            date: ISO8601DateFormatter().string(from: Date()),
            preview: String(cookieHeader.prefix(60)) + "..."
        )
        guard let data = try? JSONEncoder().encode(meta) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - WKWebView 桥接

#if os(iOS)
private struct LoginWebViewHost: UIViewRepresentable {
    let webView: WKWebView
    let onStartLoading: () -> Void
    let onFinishLoading: (String, URL?) -> Void
    let onFailLoading: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: LoginWebViewHost

        init(parent: LoginWebViewHost) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onStartLoading()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onFinishLoading(webView.title ?? "", webView.url)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onFailLoading()
        }
    }
}
#elseif os(macOS)
private struct LoginWebViewHost: NSViewRepresentable {
    let webView: WKWebView
    let onStartLoading: () -> Void
    let onFinishLoading: (String, URL?) -> Void
    let onFailLoading: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: LoginWebViewHost

        init(parent: LoginWebViewHost) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onStartLoading()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onFinishLoading(webView.title ?? "", webView.url)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onFailLoading()
        }
    }
}
#endif
