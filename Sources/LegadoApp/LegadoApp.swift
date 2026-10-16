import SwiftUI
#if canImport(WebKit)
import WebKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(LegadoCore)
import LegadoCore
#endif

@main
public struct LegadoApp: App {
    @StateObject private var bookStore = BookStore.shared
    @StateObject private var scriptBrowser = ScriptBrowserPresenter.shared
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
                ScriptBrowserSheet(request: request) { html, url in
                    scriptBrowser.finish(html: html, url: url)
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

/// 脚本要弹浏览器时的宿主实现。
///
/// 书源的 `java.startBrowserAwait(url, title)` 要「打开网页 → 用户操作 → 关掉 → 脚本拿结果」，
/// 而 JS 是同步的：这里用信号量挡住的是**脚本线程**（登录面板那几个按钮走 Task，不占主线程），
/// 主线程照常弹 WKWebView，关掉时再把最终页面 HTML 交回脚本。
final class ScriptBrowserPresenter: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let url: String
        let title: String
    }

    static let shared = ScriptBrowserPresenter()

    @Published var request: Request?
    private var completion: ((String, String) -> Void)?

    private init() {
        ScriptBrowser.shared.present = { [weak self] url, title, wait in
            guard let self else { return ("", url) }
            #if os(iOS)
            var body = ""
            var finalUrl = url
            let semaphore = wait ? DispatchSemaphore(value: 0) : nil
            DispatchQueue.main.async {
                self.completion = { html, pageUrl in
                    body = html
                    finalUrl = pageUrl.isEmpty ? url : pageUrl
                }
                self.request = Request(url: url, title: title)
                // 不等结果的（教程、永久发布页这类）：弹出来就立刻放行
                semaphore?.signal()
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

    func finish(html: String, url: String) {
        request = nil
        completion?(html, url)
        completion = nil
    }
}

#if os(iOS)
/// 脚本要求弹出的网页（注册书源 / 用户后台 / 使用教程 / 永久发布页 / 番茄登录 / 打赏）。
struct ScriptBrowserSheet: View {
    let request: ScriptBrowserPresenter.Request
    let onFinish: (String, String) -> Void

    @State private var webView = WKWebView()

    var body: some View {
        NavigationView {
            ScriptWebViewBox(webView: webView)
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
            guard let url = URL(string: request.url) else { return }
            webView.load(URLRequest(url: url))
        }
    }

    private func finish() {
        // 把最终页面 HTML 交回脚本 —— 聚合源靠它解析登录/注册结果
        let pageUrl = webView.url?.absoluteString ?? request.url
        webView.evaluateJavaScript("document.documentElement.outerHTML") { value, _ in
            let html = (value as? String) ?? ""
            DispatchQueue.main.async { onFinish(html, pageUrl) }
        }
    }
}

private struct ScriptWebViewBox: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
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
