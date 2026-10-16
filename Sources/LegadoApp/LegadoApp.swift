import SwiftUI
#if canImport(WebKit)
import WebKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(LegadoCore)
import LegadoCore
#endif

@main
public struct LegadoApp: App {
    @StateObject private var bookStore = BookStore.shared
    @StateObject private var scriptBrowser = ScriptBrowserPresenter.shared
    @StateObject private var toastPresenter = ToastPresenter.shared
    @AppStorage("legado_app_theme") private var appTheme: String = "system"

    private var selectedColorScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    public init() {
        AppLog.install()
        preloadDefaultSources()
        // 导入过的自定义字体要在用之前注册进进程，否则 CoreText 认不出来
        CustomFontService.shared.loadAll()
    }

    public var body: some Scene {
        WindowGroup {
            rootContent
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        #if os(iOS)
        MainTabView()
            .environmentObject(bookStore)
            .preferredColorScheme(selectedColorScheme)
            .sheet(item: $scriptBrowser.request) { request in
                ScriptBrowserSheet(request: request) { webView, pageUrl in
                    scriptBrowser.close(webView: webView, pageUrl: pageUrl)
                }
            }
        #else
        MainTabView()
            .environmentObject(bookStore)
            .preferredColorScheme(selectedColorScheme)
        #endif
    }

    private func preloadDefaultSources() {
        if bookStore.sources.isEmpty {
            // Load bundled default sources if available
            if let bundleUrl = Bundle.main.url(forResource: "bookSources", withExtension: "json"),
               let data = try? Data(contentsOf: bundleUrl),
               let json = String(data: data, encoding: .utf8) {
                _ = try? bookStore.importSources(json: json)
            }
        }
    }
}

/// 脚本 toast 的上屏入口。
final class ToastPresenter: ObservableObject {
    static let shared = ToastPresenter()

    private init() {
        ScriptToast.shared.handler = { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            ScriptToastWindow.shared.show(trimmed)
        }
    }
}

#if os(iOS)
/// 承载 toast 的独立窗口，2.6 秒后隐藏。
///
/// 挂在视图上的 overlay 会被 sheet 盖住（登录面板就是 sheet），所以单开一层窗口。
/// 窗口不吃触摸，点击照旧落到下面的界面。
final class ScriptToastWindow {
    static let shared = ScriptToastWindow()

    private var window: UIWindow?
    private var host: UIHostingController<ScriptToastBanner>?
    private var hideTask: DispatchWorkItem?

    private init() {}

    func show(_ text: String) {
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
            else { return }

            if self.window == nil {
                let win = ScriptToastHostWindow(windowScene: scene)
                win.windowLevel = .alert + 1
                win.backgroundColor = .clear
                // 不吃触摸，点击落到下面的界面
                win.isUserInteractionEnabled = false
                let host = UIHostingController(rootView: ScriptToastBanner(message: text))
                host.view.backgroundColor = .clear
                win.rootViewController = host
                self.window = win
                self.host = host
            }

            self.host?.rootView = ScriptToastBanner(message: text)
            self.window?.frame = scene.coordinateSpace.bounds
            self.window?.isHidden = false
            self.window?.alpha = 1

            self.hideTask?.cancel()
            let task = DispatchWorkItem { [weak self] in
                self?.window?.isHidden = true
            }
            self.hideTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: task)
        }
    }
}

/// 只负责显示 toast，不参与键盘焦点，否则弹提示会把输入框的键盘收掉。
final class ScriptToastHostWindow: UIWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeFocused: Bool { false }
}

struct ScriptToastBanner: View {
    let message: String

    var body: some View {
        VStack {
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.82)))
                .padding(.top, 64)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
#else
/// 桌面端 toast 只进日志。
final class ScriptToastWindow {
    static let shared = ScriptToastWindow()
    private init() {}
    func show(_ text: String) {}
}
#endif

/// 脚本要弹浏览器时的宿主实现。
///
/// 等待网页关闭靠信号量阻塞脚本线程，主线程弹 WKWebView，关掉时把页面 HTML 交回去。
final class ScriptBrowserPresenter: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let url: String
        let title: String
    }

    static let shared = ScriptBrowserPresenter()

    @Published var request: Request?
    private var completion: ((String, String) -> Void)?
    /// 取 HTML 期间持有 WKWebView
    private var retainedWebView: WKWebView?

    private init() {
        ScriptBrowser.shared.present = { [weak self] url, title, wait in
            guard let self else { return ("", url) }
            #if os(iOS)
            var body = ""
            var finalUrl = url
            // 主线程上不能等：弹窗要排在主线程，等它就互锁
            let canWait = wait && !Thread.isMainThread
            let semaphore = canWait ? DispatchSemaphore(value: 0) : nil
            DispatchQueue.main.async {
                // 上一个等结果的调用先放行，避免一直阻塞
                let previous = self.completion
                self.completion = { html, pageUrl in
                    body = html
                    finalUrl = pageUrl.isEmpty ? url : pageUrl
                    // 等结果的调用要等网页关闭才放行
                    semaphore?.signal()
                }
                previous?("", url)
                // 同一地址重复弹时复用现有 sheet，不叠层
                if self.request?.url != url {
                    self.request = Request(url: url, title: title)
                }
            }
            if let semaphore { _ = semaphore.wait(timeout: .now() + 600) }
            return (body, finalUrl)
            #else
            // 桌面端没有内嵌网页这一套：交给系统浏览器，脚本那边直接放行
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            return ("", url)
            #endif
        }
    }

    /// 用户点「关闭 / 完成」：先收 sheet，再取最终 HTML。
    /// 页面卡住时 evaluateJavaScript 长时间不回调，不能等它。
    func close(webView: WKWebView, pageUrl: String) {
        request = nil
        let pending = completion
        completion = nil
        guard let pending else {
            retainedWebView = nil
            return
        }
        retainedWebView = webView
        var delivered = false
        let deliver: (String) -> Void = { [weak self] html in
            guard !delivered else { return }
            delivered = true
            pending(html, pageUrl)
            self?.retainedWebView = nil
        }
        // 抓不到就按空 HTML 放行，不阻塞脚本线程
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { deliver("") }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { value, _ in
            deliver((value as? String) ?? "")
        }
    }
}

#if os(iOS)
/// 脚本要求弹出的网页（注册书源 / 用户后台 / 使用教程 / 永久发布页 / 番茄登录 / 打赏）。
struct ScriptBrowserSheet: View {
    let request: ScriptBrowserPresenter.Request
    let onFinish: (WKWebView, String) -> Void

    @State private var webView = WKWebView()
    @StateObject private var loader = ScriptPageLoadState()

    var body: some View {
        NavigationView {
            ZStack {
                ScriptWebViewBox(webView: webView)
                if loader.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在加载网页…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemBackground).opacity(0.92)))
                }
                if let failure = loader.failure {
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.title2)
                            .foregroundColor(.orange)
                        Text(failure)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") { load(request.url) }
                            .buttonStyle(.bordered)
                    }
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemBackground).opacity(0.92)))
                }
            }
                .navigationTitle(request.title.isEmpty ? "网页" : request.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { finish() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { finish() }
                    }
                }
        }
        .onAppear {
            webView.navigationDelegate = loader
            load(request.url)
        }
    }

    private func load(_ raw: String) {
        // 书源设置中心用 `data:text/html;base64,...` 传页面，WKWebView 不允许顶层导航到
        // data: 地址（load 完是白屏），这里解出 HTML 直接交给 loadHTMLString。
        if raw.hasPrefix("data:text/html"), let comma = raw.firstIndex(of: ",") {
            let meta = raw[raw.startIndex..<comma]
            let payload = String(raw[raw.index(after: comma)...])
            let html = meta.contains("base64")
                ? Data(base64Encoded: payload).flatMap { String(data: $0, encoding: .utf8) }
                : payload.removingPercentEncoding
            if let html {
                webView.loadHTMLString(html, baseURL: nil)
                return
            }
        }
        guard let url = URL(string: raw) else { return }
        webView.load(URLRequest(url: url))
    }

    private func finish() {
        // 不等 evaluateJavaScript 回调，先收 sheet，HTML 由 presenter 收尾时再取
        let pageUrl = webView.url?.absoluteString ?? ""
        onFinish(webView, pageUrl.isEmpty || pageUrl == "about:blank" ? request.url : pageUrl)
    }
}

private struct ScriptWebViewBox: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// 网页加载状态：给脚本弹出的网页加加载中提示，并把耗时写进诊断日志。
/// 这些页在小服务器或境外站点上白屏十几秒很常见，日志里能分清是加载慢还是脚本没跑。
final class ScriptPageLoadState: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var isLoading = false
    @Published var failure: String?

    private var startedAt: Date?
    private var currentUrl: String?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        failure = nil
        startedAt = Date()
        currentUrl = webView.url?.absoluteString
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        logElapsed(status: "完成")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        failure = error.localizedDescription
        logElapsed(status: "失败")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        let nsError = error as NSError
        // 用户自己点关闭时的取消不算加载失败
        guard nsError.code != NSURLErrorCancelled else { return }
        failure = error.localizedDescription
        logElapsed(status: "失败")
    }

    private func logElapsed(status: String) {
        let ms = startedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        // 地址可能是几十 KB 的 data: 页面，日志里只留前 120 字符
        AppLog.write("[网页] \(status) \(ms)ms \(String((currentUrl ?? "").prefix(120)))")
        startedAt = nil
    }
}
#endif

public struct MainTabView: View {
    /// 三个页签始终建出来，否则未选中的 tabItem 会消失（试过用条件包 Group，tab 栏就只剩书架了）。
    /// 启动卡顿改成由各页自己按 isActive 决定要不要干活。
    @State private var selection: Int = 0

    public init() {}

    public var body: some View {
        TabView(selection: $selection) {
            BookshelfView()
                .tabItem {
                    Label("书架", systemImage: "books.vertical.fill")
                }
                .tag(0)

            CategoryExploreView(isActive: selection == 1)
                .tabItem {
                    Label("分类", systemImage: "square.grid.2x2.fill")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
                .tag(2)
        }
    }
}
