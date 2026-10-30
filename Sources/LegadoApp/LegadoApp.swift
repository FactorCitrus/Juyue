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
    @StateObject private var themeManager = AppThemeManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("legado_app_theme") private var appTheme: String = "system"

    private var selectedColorScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var effectiveColorScheme: ColorScheme? {
        renderTheme.forcedColorScheme ?? selectedColorScheme
    }

    /// 验收用：`JUYUE_THEME=lunarTerminal` 只换这一轮渲染的调色板与列表样式，
    /// 不写持久化里的主题选择。Release 里没有这段。
    private var renderTheme: AppThemeTokens {
        #if DEBUG || targetEnvironment(simulator)
        switch ProcessInfo.processInfo.environment["JUYUE_THEME"] {
        case "lunarTerminal": return .lunarTerminal
        case "standard": return .standard
        default: break
        }
        #endif
        return themeManager.theme
    }

    /// 机型标识（iPhone18,1 这种）比 UIDevice.model 的「iPhone」有用。
    private static var deviceModel: String {
        #if targetEnvironment(simulator)
        // 模拟器里 uname 只回 arm64，机型得从环境变量拿（iPhone18,1 这种）
        return "sim-" + (ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown")
        #else
        var info = utsname()
        uname(&info)
        // 先拷一份再取地址：直接 &info.machine 会在同一个表达式里读写同一块内存
        var machine = info.machine
        let capacity = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        #endif
    }

    /// 磁盘剩多少，听书缓存和模型撑爆沙盒时这条能对上号。
    private static var freeDiskGB: String {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let bytes = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }

    public init() {
        AppLog.install()
        // 启动这一条带齐环境：出问题先把这份头几行发过来，机型、系统、剩余空间、
        // 当前挂在哪个引擎和语音源，四样都在里面，不用再问一轮。
        AppLog.write("[启动] \(Self.deviceModel) · iOS \(ProcessInfo.processInfo.operatingSystemVersionString) · 可用 \(Self.freeDiskGB)GB · 引擎=\(TTSEngineChoice.current.rawValue) 源=\(TTSEngineChoice.current == .http ? (TTSourceSelection.activeId.map(String.init) ?? "-") : "不使用") · uptime=\(Int(ProcessInfo.processInfo.systemUptime / 60))m")
        preloadDefaultSources()
        // 导入过的自定义字体要在用之前注册进进程，否则 CoreText 认不出来
        CustomFontService.shared.loadAll()
        // 模拟器验收用：灌一份真机备份，省得每次手点文件选择器
        #if DEBUG || targetEnvironment(simulator)
        importDebugBackupIfPresent()
        runTTSSelfTestIfPresent()
        #endif
    }

    #if DEBUG || targetEnvironment(simulator)
    /// `JUYUE_TTS_SELFTEST=<文本>` 启动 1.5 秒后直接让内置引擎念一句，不经过听书面板，
    /// 验收时省掉点屏；`JUYUE_TTS_MODEL=melo` 一并把音色定死，不看上次留下的选择。
    private func runTTSSelfTestIfPresent() {
        runCastSelfTestIfPresent()
        runHTTPFailureSelfTestIfPresent()
        guard let text = ProcessInfo.processInfo.environment["JUYUE_TTS_SELFTEST"], !text.isEmpty else { return }
        let store = LocalTTSModelStore.shared
        // `JUYUE_TTS_SEQ=melo,huayan,melo`：同一进程里连着换音色念同一句，
        // 专门验「采样率差 >1Hz 就重建音频图」这条修复，比每次冷启动更能说明问题。
        if let seq = ProcessInfo.processInfo.environment["JUYUE_TTS_SEQ"], !seq.isEmpty {
            switchTest(names: seq.split(separator: ",").map(String.init), text: text)
            return
        }
        if let want = ProcessInfo.processInfo.environment["JUYUE_TTS_MODEL"], !want.isEmpty {
            if let model = store.models.first(where: { $0.id.contains(want) || $0.name.contains(want) }) {
                store.select(model)
                AppLog.write("[调试] 自测选定 · \(model.id) · \(model.name)")
            } else {
                AppLog.write("[调试] 自测没匹配到 · \(want) · 现有 \(store.models.map(\.id).joined(separator: ","))")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            AppLog.write("[调试] 自测朗读开始")
            LocalTTSEngine.shared.speak(text: text, speed: 1.0) {
                AppLog.write("[调试] 自测朗读结束")
            } onFailure: { message in
                AppLog.write("[调试] 自测朗读失败 · \(message)")
            }
        }
    }

    /// `JUYUE_TTS_HTTP_SELFTEST=<文本>`：把引擎按死在一条在线源上，整段走「取音失败 → 改系统语音」。
    /// 文本超过块长会切好几块，专门验「某一块失败，剩下的块不被悄悄跳过去」。
    /// `JUYUE_TTS_HTTP_SOURCE=<id>` 指定源，不写就用 900001（测试用的死源）。
    private func runHTTPFailureSelfTestIfPresent() {
        guard let text = ProcessInfo.processInfo.environment["JUYUE_TTS_HTTP_SELFTEST"],
              !text.isEmpty else { return }
        let rawId = ProcessInfo.processInfo.environment["JUYUE_TTS_HTTP_SOURCE"] ?? "900001"
        guard let id = Int64(rawId) else {
            AppLog.write("[调试] 在线源失败自测 id 读不出来 · \(rawId)")
            return
        }
        TTSEngineChoice.current = .http
        TTSourceSelection.activeId = id
        let resolved = TTSourceSelection.activeSource
        AppLog.write("[调试] 在线源失败自测开始 · 源 \(id) · 解析到 \(resolved?.name ?? "nil") · \(text.count) 字 · 块长 \(AudioBookService.shared.chunkLength)")
        guard resolved != nil else {
            // 源没解析出来，走的根本不是在线的失败分支，别拿这份日志当验收
            AppLog.write("[调试] 在线源失败自测中止 · 源 \(id) 没在 httpTTS.json 里")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            AudioBookService.shared.speak(text: text)
        }
    }

    /// `JUYUE_TTS_CAST_SELFTEST=<文本>`：直接灌一份多角色配置就开念，
    /// 验的是「同一章里按段换引擎」。
    ///
    /// `JUYUE_TTS_CAST_ENGINES=builtin:meló,system:Tingting` 按「旁白 → 对话 →
    /// 关键词」的顺序套，冒号后面是该引擎的音色：内置填模型 id 或名字片段、
    /// 系统填语音名片段、在线填源 id。`JUYUE_TTS_CAST_KEYWORD` 给第三条角色的关键词。
    private func runCastSelfTestIfPresent() {
        guard let text = ProcessInfo.processInfo.environment["JUYUE_TTS_CAST_SELFTEST"],
              !text.isEmpty else { return }
        let spec = ProcessInfo.processInfo.environment["JUYUE_TTS_CAST_ENGINES"] ?? "builtin,system"
        let keyword = ProcessInfo.processInfo.environment["JUYUE_TTS_CAST_KEYWORD"] ?? ""

        var roles: [TTSCastRole] = []
        for (index, piece) in spec.split(separator: ",").enumerated() {
            let parts = piece.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let engineName = String(parts.first ?? "system")
            let voice = parts.count > 1 ? String(parts[1]) : ""
            let engine: TTSCastRole.Engine
            switch engineName {
            case "builtin": engine = .builtin
            case "http": engine = .http
            default: engine = .system
            }

            var role: TTSCastRole
            switch index {
            case 0: role = TTSCastRole(name: "旁白", match: .narration, engine: engine)
            case 1: role = TTSCastRole(name: "对话", match: .dialogue, engine: engine)
            default: role = TTSCastRole(name: "关键词", match: .keyword, keyword: keyword, engine: engine)
            }

            switch engine {
            case .builtin:
                if !voice.isEmpty {
                    let store = LocalTTSModelStore.shared
                    if let model = store.models.first(where: {
                        $0.id.localizedCaseInsensitiveContains(voice) || $0.name.contains(voice)
                    }) {
                        role.voiceId = model.id
                    } else {
                        AppLog.write("[调试] 自测没匹配到模型 · \(voice) · 现有 \(store.models.map(\.id).joined(separator: ","))")
                    }
                }
            case .system:
                if !voice.isEmpty {
                    let hit = SystemVoiceSelection.chineseVoices.first {
                        $0.name.localizedCaseInsensitiveContains(voice) || $0.identifier.contains(voice)
                    }
                    role.voiceId = hit?.identifier ?? ""
                    if hit == nil {
                        AppLog.write("[调试] 自测没匹配到系统音色 · \(voice)")
                    }
                }
            case .http:
                role.sourceId = Int64(voice)
            }
            roles.append(role)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            TTSCastStore.shared.roles = roles
            TTSCastStore.shared.enabled = true
            AppLog.write("[调试] 多角色自测开始 · " + roles.map {
                "\($0.name)=\($0.engine.rawValue)\($0.voiceId.isEmpty ? "" : "(\($0.voiceId))")"
            }.joined(separator: " / "))
            AudioBookService.shared.speakWithCast(text)
        }
    }

    private func switchTest(names: [String], text: String) {
        let store = LocalTTSModelStore.shared
        var index = 0
        func step() {
            guard index < names.count else {
                AppLog.write("[调试] 换色序列结束")
                return
            }
            let name = names[index]
            index += 1
            guard let model = store.models.first(where: { $0.id.contains(name) || $0.name.contains(name) }) else {
                AppLog.write("[调试] 换色序列没匹配到 · \(name)")
                step()
                return
            }
            store.select(model)
            AppLog.write("[调试] 换色序列第 \(index) 段 · \(model.id) · \(model.name)")
            LocalTTSEngine.shared.speak(text: text, speed: 1.0) {
                AppLog.write("[调试] 换色序列第 \(index) 段结束 · \(model.name)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step() }
            } onFailure: { message in
                AppLog.write("[调试] 换色序列失败 · \(model.name) · \(message)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { step() }
    }

    /// `JUYUE_IMPORT_BACKUP=<zip 路径>` 启动时整包替换书架与书源。
    /// 只活在 Debug 里：Release 包连这段符号都不生成，不会被误触。
    private func importDebugBackupIfPresent() {
        guard let path = ProcessInfo.processInfo.environment["JUYUE_IMPORT_BACKUP"], !path.isEmpty else {
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLog.write("[调试] 备份包不存在 \(path)")
            return
        }
        do {
            let result = try WebDAVService.shared.restoreFromZip(fileUrl: url)
            guard let books = result.books else {
                AppLog.write("[调试] 备份包里没有可用的 bookshelf.json")
                return
            }
            let (bookCount, sourceCount) = BookStore.shared.restoreFromWebDAV(
                books: books,
                sources: result.sources,
                mode: .replace
            )
            AppLog.write("[调试] 导入备份 \(books.count) 本 / \(result.sources?.count ?? 0) 源，落盘 \(bookCount) / \(sourceCount)")
        } catch {
            AppLog.write("[调试] 导入备份失败 \(error.localizedDescription)")
        }
    }
    #endif

    public var body: some Scene {
        WindowGroup {
            rootContent
                .onChange(of: scenePhase) { phase in
                    AppLog.write("[生命周期] \(phase)")
                }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        #if os(iOS)
        // scriptBrowser 不参与布局了：网页现在由 ScriptBrowserWindow 单独开窗显示。
        // 保留这一行是因为脚本浏览器的 present 回调挂在它自己的 init 里，取一次 shared
        // 才能保证脚本还没弹过网页时宿主就已经接好。
        MainTabView()
            // 钩子挂在环境注入的内层：sheet 只会继承挂载点上方的环境，
            // 放到 .environment(\.appTheme,) 外面就拿不到主题了。
            .modifier(DebugTTSLauncher())
            .task {
                #if !NO_BAIDU_TTS
                BaiduOfflineTTS.probeIfNeeded()
                #endif
            }
            .environmentObject(bookStore)
            .environmentObject(themeManager)
            .environment(\.appTheme, renderTheme)
            .tint(renderTheme.palette.accent)
            .preferredColorScheme(effectiveColorScheme)
        #else
        MainTabView()
            // 钩子挂在环境注入的内层：sheet 只会继承挂载点上方的环境，
            // 放到 .environment(\.appTheme,) 外面就拿不到主题了。
            .modifier(DebugTTSLauncher())
            .environmentObject(bookStore)
            .environmentObject(themeManager)
            .environment(\.appTheme, renderTheme)
            .tint(renderTheme.palette.accent)
            .preferredColorScheme(effectiveColorScheme)
        #endif
    }

    private func preloadDefaultSources() {
        if bookStore.sources.isEmpty {
            // Load bundled default sources if available
            if let bundleUrl = Bundle.main.url(forResource: "bookSources", withExtension: "json"),
               let data = try? Data(contentsOf: bundleUrl),
               let json = String(data: data, encoding: .utf8) {
                let count = try? bookStore.importSources(json: json)
                AppLog.write("[启动] 预装书源导入 \(count ?? 0) 条")
            }
        }
    }
}

/// `JUYUE_OPEN_TTS=1` 启动即弹出听书设置，验收 UI 时省掉「设置 → 听书」两级手点。
/// 只活在 Debug / 模拟器里；Release 包里这个修饰器是空壳，不生成 sheet。
private struct DebugTTSLauncher: ViewModifier {
    #if DEBUG || targetEnvironment(simulator)
    @State private var openTarget = ProcessInfo.processInfo.environment["JUYUE_OPEN_TTS"]
    @State private var isPresented = {
        let v = ProcessInfo.processInfo.environment["JUYUE_OPEN_TTS"] ?? "0"
        return v != "0"
    }()
    #endif

    func body(content: Content) -> some View {
        #if DEBUG || targetEnvironment(simulator)
        content.sheet(isPresented: $isPresented) {
            switch openTarget {
            case "sources": NavigationView { TTSourceManagerView() }
            default: TTSSettingsSheet()
            }
        }
        #else
        content
        #endif
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
    /// 等用户关网页的上限。超时只写日志，脚本那边按空 HTML 继续。
    private static let waitTimeout: TimeInterval = 600

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
                self.showPage(Request(url: url, title: title))
            }
            if let semaphore, semaphore.wait(timeout: .now() + Self.waitTimeout) == .timedOut {
                LegadoLog.log("[网页] 等网页关闭超时 \(Int(Self.waitTimeout))s")
            }
            return (body, finalUrl)
            #else
            // 桌面端没有内嵌网页这一套：交给系统浏览器，脚本那边直接放行
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            return ("", url)
            #endif
        }
    }

    /// 把网页交给独立窗口显示。
    ///
    /// 以前挂在根视图的 `.sheet` 上：登录面板、书源编辑这些自己就是 sheet，系统看到
    /// 「已经有一个 sheet 在展示」会把新的推迟到旧的关掉之后，表现就是点了按钮没反应、
    /// 设置中心一直转圈。独立窗口不参与这套队列，从哪一层点都能立刻显示。
    private func showPage(_ request: Request) {
        self.request = request
        #if os(iOS)
        ScriptBrowserWindow.shared.show(request: request) { [weak self] webView, pageUrl in
            self?.close(webView: webView, pageUrl: pageUrl)
        }
        #endif
    }

    /// 用户点「关闭 / 完成」：先收网页，再取最终 HTML。
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
        var finalPageUrl = pageUrl
        let deliver: (String) -> Void = { [weak self] html in
            guard !delivered else { return }
            delivered = true
            pending(html, finalPageUrl)
            self?.retainedWebView = nil
        }
        // 抓不到就按空 HTML 放行，不阻塞脚本线程
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { deliver("") }
        // 顺手把页面自己的 location.href 带回去：书源设置中心把结果写进地址
        // （`#config=` / `?source_settings_result=`），而 WKWebView 里这一步是
        // loadHTMLString，webView.url 只会是 about:blank，拿不到页面改过的地址。
        webView.evaluateJavaScript("JSON.stringify({ h: document.documentElement.outerHTML, u: String(location.href) })") { value, _ in
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else {
                deliver("")
                return
            }
            if let href = obj["u"], !href.isEmpty, href != "about:blank" {
                finalPageUrl = href
            }
            deliver(obj["h"] ?? "")
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
    private var watchdog: DispatchWorkItem?
    /// didStart 之后既不来 didFinish 也不来 didFail 的上限。
    /// 以前只有转圈没有出口，用户只能自己关掉重来。
    private static let loadTimeout: TimeInterval = 15

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        failure = nil
        startedAt = Date()
        currentUrl = webView.url?.absoluteString
        startWatchdog()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        stopWatchdog()
        isLoading = false
        logElapsed(status: "完成")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        stopWatchdog()
        isLoading = false
        failure = error.localizedDescription
        logElapsed(status: "失败")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        stopWatchdog()
        isLoading = false
        let nsError = error as NSError
        // 用户自己点关闭时的取消不算加载失败
        guard nsError.code != NSURLErrorCancelled else { return }
        failure = error.localizedDescription
        logElapsed(status: "失败")
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isLoading else { return }
            self.isLoading = false
            self.failure = "网页加载超时，检查网络后重试"
            self.logElapsed(status: "超时")
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout, execute: item)
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func logElapsed(status: String) {
        let ms = startedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        // 地址可能是几十 KB 的 data: 页面，日志里只留前 120 字符
        AppLog.write("[网页] \(status) \(ms)ms \(String((currentUrl ?? "").prefix(120)))")
        startedAt = nil
    }
}

/// 脚本网页的独立窗口。
///
/// 单独开窗而不是挂 `.sheet`：登录面板、书源编辑自己就是 sheet，往 sheet 上再叠 sheet
/// 会被系统推迟甚至丢掉，表现就是点了按钮没反应。窗口层级压在主窗口和它的 sheet 之上，
/// 「关闭 / 完成」交回去之后再把 key 还给原来的窗口。
final class ScriptBrowserWindow {
    static let shared = ScriptBrowserWindow()

    private var window: UIWindow?
    private var host: UIHostingController<ScriptBrowserSheet>?
    private weak var previousKeyWindow: UIWindow?

    private init() {}

    func show(request: ScriptBrowserPresenter.Request, onFinish: @escaping (WKWebView, String) -> Void) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        // 上一页还开着就又点了一次：整个换掉，不在旧窗口里复用旧页面
        hide()

        let page = ScriptBrowserSheet(request: request) { [weak self] webView, pageUrl in
            onFinish(webView, pageUrl)
            self?.hide()
        }

        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let hosting = UIHostingController(rootView: page)
        let win = UIWindow(windowScene: scene)
        win.rootViewController = hosting
        // 压在主窗口之上，主窗口里的 sheet 就盖不住这一页
        win.windowLevel = .normal + 1
        win.backgroundColor = .systemBackground
        win.makeKeyAndVisible()
        host = hosting
        window = win
        AppLog.write("[网页] 独立窗口打开 \(request.title)")
    }

    func hide() {
        window?.isHidden = true
        window = nil
        host = nil
        // 不还回去的话输入焦点留在空窗口上，主界面点不动
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
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
