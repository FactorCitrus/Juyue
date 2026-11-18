import SwiftUI
import WebKit

/// 设计器导出回来的东西。`htmlTemplate` 是渲染用的 HTML 片段，
/// `projectJSON` 是完整工程（元素/画布/资源），下次打开设计器要回灌。
struct ChapterTitleDesignExport {
    var htmlTemplate: String = ""
    var projectJSON: String = ""
    var canvasHeight: Double = 0
}

/// 章节标题设计器。
///
/// 页面就是 `Resources/ChapterTitleDesigner`（index.html + designer.js），
/// 协议照它原有的走：原生注册 `chapterTitleDesigner` 消息处理器收 `{type, payload}`，
/// 下发用 `window.qireaderTitleDesigner.receive({command, payload})`。
struct ChapterTitleDesignerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var readerConfig = ReaderConfig.shared

    let onSave: (ChapterTitleDesignExport) -> Void

    @State private var exportTicket: Int = 0
    @State private var pending: ChapterTitleDesignExport?
    @State private var status: String = "调好之后点右上角「保存」"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("章节标题设计器")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 14))
                Button("保存") {
                    status = "正在取设计结果…"
                    exportTicket += 1
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ChapterTitleDesignerWebView(
                initialProjectJSON: readerConfig.chapterTitleProjectJSON,
                isDark: readerConfig.isDarkAppearance,
                exportTicket: exportTicket,
                onExport: { export in
                    pending = export
                }
            )
        }
        .onChange(of: exportTicket) { _ in
            // 等设计器把 exportProject 回传上来再落盘
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let export = pending, !export.projectJSON.isEmpty else {
                    status = "没取到设计结果，请重试"
                    exportTicket = 0
                    return
                }
                onSave(export)
                dismiss()
            }
        }
    }
}

/// 承载设计器页面的 WebView。
struct ChapterTitleDesignerWebView: View {
    let initialProjectJSON: String
    let isDark: Bool
    /// 自增一下就向设计器要一次导出结果
    let exportTicket: Int
    let onExport: (ChapterTitleDesignExport) -> Void

    var body: some View {
        #if os(iOS)
        DesignerRepresentable(
            initialProjectJSON: initialProjectJSON,
            isDark: isDark,
            exportTicket: exportTicket,
            onExport: onExport
        )
        #else
        DesignerNSRepresentable(
            initialProjectJSON: initialProjectJSON,
            isDark: isDark,
            exportTicket: exportTicket,
            onExport: onExport
        )
        #endif
    }
}

/// 两条平台的实现只差一个父协议，逻辑全在 Coordinator 里。
final class ChapterTitleDesignerCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var initialProjectJSON: String = ""
    var isDark: Bool = false
    var onExport: ((ChapterTitleDesignExport) -> Void)?
    private var loaded = false

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "chapterTitleDesigner",
              let body = message.body as? [String: Any] else { return }
        let type = (body["type"] as? String) ?? ""
        guard type == "exportProject", let payload = body["payload"] as? [String: Any] else { return }
        var export = ChapterTitleDesignExport()
        export.htmlTemplate = (payload["htmlTemplate"] as? String) ?? ""
        export.projectJSON = (payload["projectJSON"] as? String) ?? ""
        export.canvasHeight = (payload["canvasHeight"] as? NSNumber)?.doubleValue ?? 0
        onExport?(export)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !loaded else { return }
        loaded = true
        send("setTheme", ["name": isDark ? "dark" : "light"], to: webView)
        if !initialProjectJSON.isEmpty {
            // initProject 收的是工程对象，不是字符串，所以在这里 parse
            let js = "try{window.qireaderTitleDesigner.receive({command:'initProject',payload:"
                + "JSON.parse(\(jsStringLiteral(initialProjectJSON)))});}catch(e){console.error(e);}"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func requestExport(in webView: WKWebView) {
        webView.evaluateJavaScript(
            "window.qireaderTitleDesigner && window.qireaderTitleDesigner.requestExport();",
            completionHandler: nil
        )
    }

    private func send(_ command: String, _ payload: [String: Any], to webView: WKWebView) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.qireaderTitleDesigner && window.qireaderTitleDesigner.receive({command:'\(command)',payload:\(text)});",
            completionHandler: nil
        )
    }
}

/// 章节标题的渲染侧。
///
/// 设计器导出的 `htmlTemplate` 里图片是 `qireader-title-asset://<id>` 这种自定义协议，
/// 直接丢给 WebView 是加载不出来的，得先用 projectJSON 里的资源换成 data URI。
enum ChapterTitleRenderer {
    /// `render` 是在 SwiftUI body 里调的，翻页拖动时每帧都会跑一遍。
    /// 里面要 JSON 解析 + 正则替换 + 拼串，不缓存的话每帧都在做这些。
    private final class Cache {
        static let shared = Cache()
        private var html: [String: String] = [:]
        private var canvas: [String: CGSize] = [:]
        private let lock = NSLock()

        func html(for key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return html[key]
        }

        func storeHTML(_ value: String, for key: String) {
            lock.lock()
            if html.count > 96 { html.removeAll() }
            html[key] = value
            lock.unlock()
        }

        func canvas(for key: String) -> CGSize? {
            lock.lock(); defer { lock.unlock() }
            return canvas[key]
        }

        func storeCanvas(_ value: CGSize, for key: String) {
            lock.lock()
            canvas[key] = value
            lock.unlock()
        }
    }

    /// 画布尺寸，拿不到就给个兜底，免得按 0 算高度
    static func canvasSize(projectJSON: String) -> CGSize {
        let key = String(projectJSON.hashValue)
        if let cached = Cache.shared.canvas(for: key) { return cached }
        guard let data = projectJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let canvas = root["canvas"] as? [String: Any] else {
            return CGSize(width: 360, height: 120)
        }
        let width = (canvas["width"] as? NSNumber)?.doubleValue ?? 360
        let height = (canvas["height"] as? NSNumber)?.doubleValue ?? 120
        let size = CGSize(width: max(80, width), height: max(24, height))
        Cache.shared.storeCanvas(size, for: key)
        return size
    }

    /// 资源 id → 可直接塞进 HTML 的地址
    static func assetURLs(projectJSON: String) -> [String: String] {
        guard let data = projectJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else { return [:] }
        var map: [String: String] = [:]
        for asset in assets {
            guard let id = asset["id"] as? String else { continue }
            let raw = (asset["url"] as? String) ?? (asset["src"] as? String) ?? ""
            if raw.isEmpty { continue }
            if raw.hasPrefix("data:") || raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                map[id] = raw
            } else if raw.hasPrefix("file://"), let url = URL(string: raw), let inlined = inlineFile(url.path) {
                map[id] = inlined
            } else if raw.hasPrefix("/"), let inlined = inlineFile(raw) {
                map[id] = inlined
            } else {
                map[id] = raw
            }
        }
        return map
    }

    private static func inlineFile(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        case "svg": mime = "image/svg+xml"
        default: mime = "application/octet-stream"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// 把 `data-qr-type="chapterName"/"chapterNumber"` 节点里的占位文字换成真章节
    private static func fill(_ html: String, type: String, value: String) -> String {
        let pattern = "(<[^>]*data-qr-type=\"\(type)\"[^>]*>)(.*?)(</)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return html
        }
        let range = NSRange(html.startIndex..., in: html)
        // 值里的 $ 会被当成反向引用，先转义
        let safe = value.replacingOccurrences(of: "$", with: "\\$")
        return regex.stringByReplacingMatches(
            in: html,
            options: [],
            range: range,
            withTemplate: "$1\(safe)$3"
        )
    }

    /// 拼成一张自包含的页面：模板 + 透明底 + 禁滚动
    static func render(
        htmlTemplate: String,
        projectJSON: String,
        chapterTitle: String = "",
        chapterNumber: String = ""
    ) -> String {
        let key = "\(htmlTemplate.hashValue)|\(projectJSON.hashValue)|\(chapterTitle)|\(chapterNumber)"
        if let cached = Cache.shared.html(for: key) { return cached }
        var html = htmlTemplate
        for (id, url) in assetURLs(projectJSON: projectJSON) {
            html = html.replacingOccurrences(of: "qireader-title-asset://\(id)", with: url)
        }
        if !chapterTitle.isEmpty { html = fill(html, type: "chapterName", value: chapterTitle) }
        if !chapterNumber.isEmpty { html = fill(html, type: "chapterNumber", value: chapterNumber) }
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>
        html,body{margin:0;padding:0;background:transparent;overflow:hidden;
        -webkit-text-size-adjust:100%;-webkit-user-select:none;user-select:none;}
        </style></head><body>\(html)</body></html>
        """
        Cache.shared.storeHTML(page, for: key)
        return page
    }
}

/// 阅读页里的设计标题。按可用宽度等比缩放画布高度。
struct ChapterTitleHTMLView: View {
    let htmlTemplate: String
    let projectJSON: String
    /// 正文可用宽度，由调用方给，免得这里再套一层 GeometryReader
    let width: CGFloat
    var chapterTitle: String = ""
    var chapterNumber: String = ""

    static func height(forWidth width: CGFloat, projectJSON: String) -> CGFloat {
        let canvas = ChapterTitleRenderer.canvasSize(projectJSON: projectJSON)
        return max(24, canvas.height * (width / max(1, canvas.width)))
    }

    var body: some View {
        let html = ChapterTitleRenderer.render(
            htmlTemplate: htmlTemplate,
            projectJSON: projectJSON,
            chapterTitle: chapterTitle,
            chapterNumber: chapterNumber
        )
        let height = Self.height(forWidth: width, projectJSON: projectJSON)
        #if os(iOS)
        TitleHTMLRepresentable(html: html)
            .frame(width: width, height: height)
        #else
        TitleHTMLNSRepresentable(html: html)
            .frame(width: width, height: height)
        #endif
    }
}

    /// 把字符串编成 JS 字面量：工程 JSON 里有中文和引号，不能直接拼
func jsStringLiteral(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let text = String(data: data, encoding: .utf8) else { return "\"\"" }
    // 去掉外层数组的方括号，留下带转义的字符串字面量
    return String(text.dropFirst().dropLast())
}

private func designerIndexURL() -> URL? {
    Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "ChapterTitleDesigner")
}

#if os(iOS)
struct DesignerRepresentable: UIViewRepresentable {
    let initialProjectJSON: String
    let isDark: Bool
    let exportTicket: Int
    let onExport: (ChapterTitleDesignExport) -> Void

    func makeCoordinator() -> ChapterTitleDesignerCoordinator {
        let coordinator = ChapterTitleDesignerCoordinator()
        coordinator.initialProjectJSON = initialProjectJSON
        coordinator.isDark = isDark
        coordinator.onExport = onExport
        return coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "chapterTitleDesigner")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        if let url = designerIndexURL() {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onExport = onExport
        if exportTicket > 0 { context.coordinator.requestExport(in: view) }
    }
}
#else
struct DesignerNSRepresentable: NSViewRepresentable {
    let initialProjectJSON: String
    let isDark: Bool
    let exportTicket: Int
    let onExport: (ChapterTitleDesignExport) -> Void

    func makeCoordinator() -> ChapterTitleDesignerCoordinator {
        let coordinator = ChapterTitleDesignerCoordinator()
        coordinator.initialProjectJSON = initialProjectJSON
        coordinator.isDark = isDark
        coordinator.onExport = onExport
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "chapterTitleDesigner")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        if let url = designerIndexURL() {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onExport = onExport
        if exportTicket > 0 { context.coordinator.requestExport(in: view) }
    }
}
#endif

// MARK: - 设计标题的渲染载体

/// 只读、透明底、不滚动的 WebView。
/// 设计标题是逐章渲染的，交互和滚动全关掉，免得跟阅读手势打架。
@MainActor
private func makeTitleWebView(html: String) -> WKWebView {
    let config = WKWebViewConfiguration()
    let view = WKWebView(frame: .zero, configuration: config)
    #if os(iOS)
    view.isOpaque = false
    view.backgroundColor = .clear
    view.scrollView.isScrollEnabled = false
    view.scrollView.contentInsetAdjustmentBehavior = .never
    view.isUserInteractionEnabled = false
    #else
    view.setValue(false, forKey: "drawsBackground")
    #endif
    view.loadHTMLString(html, baseURL: nil)
    return view
}

final class TitleHTMLCoordinator {
    var lastHTML: String?
}

#if os(iOS)
struct TitleHTMLRepresentable: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> TitleHTMLCoordinator { TitleHTMLCoordinator() }

    func makeUIView(context: Context) -> WKWebView { makeTitleWebView(html: html) }

    func updateUIView(_ view: WKWebView, context: Context) {
        // 只在内容真的变了才重新加载，否则每次重绘都刷一遍 WebView
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            view.loadHTMLString(html, baseURL: nil)
        }
    }
}
#else
struct TitleHTMLNSRepresentable: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> TitleHTMLCoordinator { TitleHTMLCoordinator() }

    func makeNSView(context: Context) -> WKWebView { makeTitleWebView(html: html) }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            view.loadHTMLString(html, baseURL: nil)
        }
    }
}
#endif
