import SwiftUI
import WebKit
#if canImport(LegadoCore)
import LegadoCore
#endif

public struct SourceWebLoginView: View {
    @ObservedObject var bookStore = BookStore.shared
    @Environment(\.dismiss) private var dismiss

    let source: BookSource
    let onLoginCompleted: ((BookSource) -> Void)?

    @State private var webView: WKWebView
    @State private var currentUrl: URL?
    @State private var pageTitle: String = ""
    @State private var isLoading: Bool = false
    @State private var capturedCookies: [HTTPCookie] = []
    @State private var showManualCookieSheet: Bool = false
    @State private var manualCookieInput: String = ""
    @State private var alertMessage: String = ""
    @State private var showAlert: Bool = false
    /// 地址栏可编辑：聚合源的 loginUrl 是脚本，网址要从脚本里扒或手填
    @State private var urlText: String = ""

    public init(source: BookSource, onLoginCompleted: ((BookSource) -> Void)? = nil) {
        self.source = source
        self.onLoginCompleted = onLoginCompleted

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
        self._webView = State(initialValue: wv)

        // 只认能打开的 http(s) 地址。聚合源的 loginUrl 是一整段 JS，
        // bookSourceUrl 只是个标识（"大灰狼融合VIP5.0"），URL(string:) 解不出来会白屏。
        let candidates = [source.loginUrl ?? "", source.bookSourceUrl]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let firstUsable = candidates.first { Self.isLoadableWebUrl($0) }
        // 都不可用时，用脚本里扒出来的候选主机当默认值
        // （host = ['https://v5.langge.uk', ...]），比空着地址栏强得多。
        let derived = firstUsable ?? Self.candidateHosts(from: source).first ?? ""
        self._currentUrl = State(initialValue: firstUsable.flatMap { URL(string: $0) })
        self._urlText = State(initialValue: derived)
    }

    /// 候选主机的中文名。
    /// 按常见站点给可读名字，认不出来的按序号叫「线路 N」。
    static func hostLabel(_ host: String, index: Int) -> String {
        let lower = host.lowercased()
        if lower.contains("fanqienovel") { return "番茄小说（\(host)）" }
        if lower.contains("langge") { return "大灰狼线路 \(index + 1)（\(host)）" }
        if lower.contains("cloudflare") { return "CDN 线路（\(host)）" }
        return "线路 \(index + 1)（\(host)）"
    }

    /// 从登录脚本 / JS 库里扒出候选主机（去重、保序，最多 6 个）。
    /// 登录页地址是运行时拼的（`getArgument('server') + '/login'`），
    /// 只能扒出脚本里出现过的主机，作为候选给用户挑。
    static func candidateHosts(from source: BookSource) -> [String] {
        let text = [source.loginUrl ?? "", source.jsLib ?? "", source.bookSourceUrl].joined(separator: "\n")
        guard let regex = try? NSRegularExpression(pattern: #"https?://[A-Za-z0-9.\-]+"#) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, out.count < 6 else { return }
            let host = ns.substring(with: match.range)
            if seen.insert(host).inserted { out.append(host) }
        }
        return out
    }

    /// 能否交给 WebView 打开：需要带 host 的 http(s) 地址，
    /// JS 文本和 "大灰狼融合VIP5.0" 这类标识都不算。
    static func isLoadableWebUrl(_ str: String) -> Bool {
        guard let url = URL(string: str),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// 没有可打开的地址时显示的说明。
    private var noWebUrlHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text("这个书源没有可直接打开的网页登录地址")
                .font(.subheadline.weight(.medium))
            Text("它的 loginUrl 是一段脚本、bookSourceUrl 也不是网址。\n上面地址栏里是从脚本里扒出来的主机，填上真实登录页地址点「打开」即可；也可以直接「手动粘贴 Cookie」，或者回上一页走「表单脚本登录」。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Address bar / status hint
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }

                    // 地址可改：扒出来的主机不一定就是登录页
                    TextField("登录页地址（https://…）", text: $urlText)
                        .font(.caption2)
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit { openTypedUrl() }

                    Button("打开") { openTypedUrl() }
                        .font(.caption)
                        .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    let hosts = Self.candidateHosts(from: source)
                    if hosts.count > 1 {
                        Menu {
                            ForEach(Array(hosts.enumerated()), id: \.element) { index, host in
                                Button(Self.hostLabel(host, index: index)) {
                                    urlText = host
                                }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.caption)
                        }
                    }

                    Spacer()

                    if !capturedCookies.isEmpty {
                        Text("\(capturedCookies.count) Cookies")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))

                Divider()

                // Web view area
                #if os(iOS)
                IOSWebViewRepresentable(
                    webView: webView,
                    currentUrl: currentUrl,
                    onLoadingChanged: { loading in
                        self.isLoading = loading
                    },
                    onTitleChanged: { title in
                        self.pageTitle = title
                    },
                    onUrlChanged: { url in
                        self.currentUrl = url
                        self.extractCookies()
                    }
                )
                #else
                MacWebViewRepresentable(
                    webView: webView,
                    currentUrl: currentUrl,
                    onLoadingChanged: { loading in
                        self.isLoading = loading
                    },
                    onTitleChanged: { title in
                        self.pageTitle = title
                    },
                    onUrlChanged: { url in
                        self.currentUrl = url
                        self.extractCookies()
                    }
                )
                #endif

                if currentUrl == nil {
                    noWebUrlHint
                }

                Divider()

                // Bottom toolbar
                bottomControlBar
            }
            .navigationTitle(source.bookSourceName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并完成") {
                        saveCapturedCookiesAndFinish()
                    }
                    .font(.body.bold())
                }
            }
            .sheet(isPresented: $showManualCookieSheet) {
                manualCookieSheet
            }
            .alert(alertMessage, isPresented: $showAlert) {
                Button("确定", role: .cancel) {}
            }
            .onAppear {
                loadInitialUrl()
                extractCookies()
            }
        }
    }

    // MARK: - Bottom Control Bar
    @ViewBuilder
    private var bottomControlBar: some View {
        HStack(spacing: 20) {
            Button(action: { webView.goBack() }) {
                Image(systemName: "chevron.backward")
            }
            .disabled(!webView.canGoBack)

            Button(action: { webView.goForward() }) {
                Image(systemName: "chevron.forward")
            }
            .disabled(!webView.canGoForward)

            Button(action: { webView.reload() }) {
                Image(systemName: "arrow.clockwise")
            }

            Spacer()

            Button("手动粘贴 Cookie") {
                showManualCookieSheet = true
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
    }

    // MARK: - Manual Cookie Input Sheet
    @ViewBuilder
    private var manualCookieSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("粘贴 Cookie 字符串")) {
                    TextEditor(text: $manualCookieInput)
                        .frame(minHeight: 140)
                        .font(.system(.caption, design: .monospaced))
                    Text("提示：若网页已在 Safari/电脑端登录，可直接从浏览器控制台复制 Cookie 填入（如：ews_key=...; ews_token=...; PHPSESSID=...）。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button("保存并应用此 Cookie") {
                        applyManualCookie()
                    }
                    .disabled(manualCookieInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("手动填入 Cookie")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showManualCookieSheet = false }
                }
            }
        }
    }

    // MARK: - Cookie Extraction & Saving
    private func loadInitialUrl() {
        guard let url = currentUrl else { return }
        webView.load(URLRequest(url: url))
    }

    /// 打开地址栏里那条地址
    private func openTypedUrl() {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else { return }
        currentUrl = url
        webView.load(URLRequest(url: url))
    }

    private func loadUrlString(_ str: String) {
        guard let url = URL(string: str) else { return }
        self.currentUrl = url
        webView.load(URLRequest(url: url))
    }

    private func extractCookies() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let filtered = filterRelevantCookies(cookies)
            DispatchQueue.main.async {
                self.capturedCookies = filtered
            }
        }
    }

    private func filterRelevantCookies(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        // 聚合源的 bookSourceUrl 只是个标识（"大灰狼融合VIP5.0"）、loginUrl 是一段脚本，
        // 两者的 host 都取不到，只按它们过滤会一条 cookie 都留不下。当前打开的网页 host
        // 是真实登录域，要一起算进来。
        var hosts: [String] = []
        for candidate in [source.bookSourceUrl, source.loginUrl ?? "", currentUrl?.absoluteString ?? ""] {
            if let host = URL(string: candidate)?.host?.lowercased(), !host.isEmpty, !hosts.contains(host) {
                hosts.append(host)
            }
        }
        guard !hosts.isEmpty else { return [] }

        return cookies.filter { c in
            let domain = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !domain.isEmpty else { return false }
            return hosts.contains { $0.contains(domain) || domain.contains($0) }
        }
    }

    private func saveCapturedCookiesAndFinish() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let filtered = self.filterRelevantCookies(cookies)
            DispatchQueue.main.async {
                guard !filtered.isEmpty else {
                    self.alertMessage = "未检测到该网站的有效 Cookie，请先在网页内输入账号密码完成登录，或点击底部「手动粘贴 Cookie」。"
                    self.showAlert = true
                    return
                }

                let cookieString = filtered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                self.saveCookieString(cookieString, cookiesList: filtered)
            }
        }
    }

    private func applyManualCookie() {
        let clean = manualCookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
        guard !clean.isEmpty else { return }

        showManualCookieSheet = false
        saveCookieString(clean, cookiesList: [])
    }

    private func saveCookieString(_ cookieString: String, cookiesList: [HTTPCookie]) {
        var updatedSource = source

        // 1. Pack into JSON header for NetworkClient
        let headerDict: [String: String] = [
            "Cookie": cookieString,
            "User-Agent": webView.customUserAgent ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: headerDict),
           let jsonStr = String(data: data, encoding: .utf8) {
            updatedSource.loginHeader = jsonStr
        } else {
            updatedSource.loginHeader = "{\"Cookie\":\"\(cookieString)\"}"
        }

        // 2. Pack loginInfo metadata
        let infoDict: [String: Any] = [
            "type": "web_cookie",
            "url": currentUrl?.absoluteString ?? (source.loginUrl ?? source.bookSourceUrl),
            "cookiesCount": cookiesList.count,
            "date": ISO8601DateFormatter().string(from: Date()),
            "preview": String(cookieString.prefix(60)) + "..."
        ]
        if let data = try? JSONSerialization.data(withJSONObject: infoDict),
           let infoStr = String(data: data, encoding: .utf8) {
            updatedSource.loginInfo = infoStr
        }

        // 3. Mirror cookies into shared HTTPCookieStorage
        for c in cookiesList {
            HTTPCookieStorage.shared.setCookie(c)
            // Mirror to bookSourceUrl domain if different
            if let targetHost = URL(string: source.bookSourceUrl)?.host, targetHost != c.domain {
                var props = c.properties ?? [:]
                props[.domain] = targetHost
                if let mirror = HTTPCookie(properties: props) {
                    HTTPCookieStorage.shared.setCookie(mirror)
                }
            }
        }

        // 4. Update in BookStore
        bookStore.updateSource(updatedSource)
        onLoginCompleted?(updatedSource)

        dismiss()
    }
}

// MARK: - Platform WebView Wrappers

#if os(iOS)
struct IOSWebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    let currentUrl: URL?
    let onLoadingChanged: (Bool) -> Void
    let onTitleChanged: (String) -> Void
    let onUrlChanged: (URL?) -> Void

    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: IOSWebViewRepresentable

        init(parent: IOSWebViewRepresentable) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoadingChanged(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoadingChanged(false)
            parent.onTitleChanged(webView.title ?? "")
            parent.onUrlChanged(webView.url)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoadingChanged(false)
        }
    }
}
#endif

#if os(macOS)
struct MacWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    let currentUrl: URL?
    let onLoadingChanged: (Bool) -> Void
    let onTitleChanged: (String) -> Void
    let onUrlChanged: (URL?) -> Void

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: MacWebViewRepresentable

        init(parent: MacWebViewRepresentable) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoadingChanged(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoadingChanged(false)
            parent.onTitleChanged(webView.title ?? "")
            parent.onUrlChanged(webView.url)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoadingChanged(false)
        }
    }
}
#endif
