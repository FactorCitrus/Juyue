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

    public init(source: BookSource, onLoginCompleted: ((BookSource) -> Void)? = nil) {
        self.source = source
        self.onLoginCompleted = onLoginCompleted

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
        self._webView = State(initialValue: wv)

        let initialStr = source.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? source.bookSourceUrl
        self._currentUrl = State(initialValue: URL(string: initialStr))
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

                    Text(currentUrl?.absoluteString ?? source.bookSourceUrl)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

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
        let sourceHost = URL(string: source.bookSourceUrl)?.host?.lowercased() ?? ""
        let loginHost = URL(string: source.loginUrl ?? "")?.host?.lowercased() ?? ""

        return cookies.filter { c in
            let domain = c.domain.lowercased()
            if !sourceHost.isEmpty && (domain.contains(sourceHost) || sourceHost.contains(domain)) {
                return true
            }
            if !loginHost.isEmpty && (domain.contains(loginHost) || loginHost.contains(domain)) {
                return true
            }
            return false
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
