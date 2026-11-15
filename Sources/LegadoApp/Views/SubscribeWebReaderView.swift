import SwiftUI
import UIKit
import WebKit
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 订阅正文的网页阅读器，对齐安卓 `ReadRssActivity`：
/// 优先把规则输出当成网页渲染（loadDataWithBaseURL 语义），没有网页时退回网址加载。
struct SubscribeWebReader: View {
    let html: String?
    let url: URL?
    let baseURL: URL?
    let headers: [String: String]
    let enableJS: Bool
    let cacheFirst: Bool
    let allowInsecureTLS: Bool
    let preloadJS: String?
    let darkMode: Bool
    /// 网页里点到的 `legado://` / `juyue://` / `yuedu://` 导入链接。
    let onImportLink: (URL) -> Void
    /// 网页里点到文件直链（书源 JSON、压缩包等），交给内置下载器。
    let onDownloadLink: (URL) -> Void
    /// 其它 App 的 scheme，交给宿主弹确认再跳转。
    let onExternalLink: (URL) -> Void

    @StateObject private var state = WebReaderState()

    var body: some View {
        ZStack {
            SubscribeWebView(
                html: html,
                url: url,
                baseURL: baseURL,
                headers: headers,
                enableJS: enableJS,
                cacheFirst: cacheFirst,
                allowInsecureTLS: allowInsecureTLS,
                preloadJS: preloadJS,
                darkMode: darkMode,
                onImportLink: onImportLink,
                onDownloadLink: onDownloadLink,
                onExternalLink: onExternalLink,
                state: state
            )
            if state.isLoading {
                ProgressView()
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if let message = state.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                    Text(message)
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                    if let url {
                        Link("在浏览器打开", destination: url)
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .padding(24)
            }
        }
    }
}

private final class WebReaderState: ObservableObject {
    @Published var isLoading = true
    @Published var errorMessage: String?
}

private struct SubscribeWebView: UIViewRepresentable {
    let html: String?
    let url: URL?
    let baseURL: URL?
    let headers: [String: String]
    let enableJS: Bool
    let cacheFirst: Bool
    let allowInsecureTLS: Bool
    let preloadJS: String?
    let darkMode: Bool
    let onImportLink: (URL) -> Void
    let onDownloadLink: (URL) -> Void
    let onExternalLink: (URL) -> Void
    let state: WebReaderState

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = enableJS
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(
            source: JavaBridgeShim.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.attach(webView)
        context.coordinator.loadPending()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.loadPending()
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: SubscribeWebView
        private weak var webView: WKWebView?
        private var lastSignature: String?

        init(parent: SubscribeWebView) {
            self.parent = parent
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func loadPending() {
            guard let webView else { return }
            let signature = [
                parent.html ?? "",
                parent.url?.absoluteString ?? "",
                parent.enableJS ? "1" : "0",
                parent.darkMode ? "d" : "l"
            ].joined(separator: "|")
            guard signature != lastSignature else { return }
            lastSignature = signature

            setLoading(true)
            let payload = (parent.html ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !payload.isEmpty {
                let document = WebDocument.wrap(
                    payload,
                    preloadJS: parent.preloadJS,
                    darkMode: parent.darkMode
                )
                // 安卓 `loadWithBaseUrl == false` 时 baseUrl 传 null，等同忽略相对地址。
                webView.loadHTMLString(document, baseURL: parent.baseURL)
                return
            }
            guard let url = parent.url else {
                setLoading(false)
                return
            }
            var request = URLRequest(
                url: url,
                cachePolicy: parent.cacheFirst ? .returnCacheDataElseLoad : .useProtocolCachePolicy
            )
            for (name, value) in parent.headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            webView.load(request)
        }

        private func setLoading(_ loading: Bool) {
            DispatchQueue.main.async {
                self.parent.state.isLoading = loading
                if loading { self.parent.state.errorMessage = nil }
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            setLoading(false)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failure(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            failure(error)
        }

        private func failure(_ error: Error) {
            let ns = error as NSError
            setLoading(false)
            // -999 是用户自己点了链接/停止加载，不算失败。
            guard ns.code != NSURLErrorCancelled else { return }
            DispatchQueue.main.async {
                self.parent.state.errorMessage = "网页加载失败：\(error.localizedDescription)"
            }
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard parent.allowInsecureTLS,
                  challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // 源仓/书源仓库的「一键导入」：legado:// / juyue:// / yuedu://。
            if SourceDeepLinkParser.parse(url) != nil {
                decisionHandler(.cancel)
                DispatchQueue.main.async { self.parent.onImportLink(url) }
                return
            }
            if let target = DownloadLinkClassifier.opappTarget(url) {
                decisionHandler(.cancel)
                DispatchQueue.main.async { self.parent.onDownloadLink(target) }
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" {
                if DownloadLinkClassifier.shouldPerformDownload(
                    navigationActionPrefersDownload: navigationAction.shouldPerformDownload,
                    url: url
                ) {
                    decisionHandler(.cancel)
                    DispatchQueue.main.async { self.parent.onDownloadLink(url) }
                    return
                }
                decisionHandler(.allow)
                return
            }
            let handled: Set<String> = ["about", "data", "blob", "file", "javascript"]
            if handled.contains(scheme) {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            DispatchQueue.main.async { self.parent.onExternalLink(url) }
        }

        /// 地址没扩展名、靠 `Content-Type` 才知道是文件的下载链接，在响应阶段补拦。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            let http = navigationResponse.response as? HTTPURLResponse
            let mime = http?.mimeType ?? navigationResponse.response.mimeType
            let disposition = http?.value(forHTTPHeaderField: "Content-Disposition")
            if navigationResponse.isForMainFrame,
               let url = navigationResponse.response.url,
               DownloadLinkClassifier.shouldPerformDownload(
                   navigationActionPrefersDownload: false,
                   url: url,
                   contentDisposition: disposition,
                   mimeType: mime
               ) {
                decisionHandler(.cancel)
                DispatchQueue.main.async { self.parent.onDownloadLink(url) }
                return
            }
            decisionHandler(.allow)
        }

        // MARK: WKUIDelegate

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            if SourceDeepLinkParser.parse(url) != nil {
                parent.onImportLink(url)
                return nil
            }
            if let target = DownloadLinkClassifier.opappTarget(url) {
                webView.load(URLRequest(url: target))
                return nil
            }
            // 目标页要开新窗口时留在当前阅读器里，避免点了没反应。
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

// MARK: - 文档拼装

private enum WebDocument {
    /// 规则输出可能是完整文档，也可能只是片段；片段补上 head 与默认样式。
    static func wrap(_ payload: String, preloadJS: String?, darkMode: Bool) -> String {
        if looksLikeDocument(payload) {
            return payload
        }
        let background = darkMode ? "#17181a" : "#ffffff"
        let ink = darkMode ? "#e6e6e6" : "#1b1b1b"
        let style = """
        <style>
        :root { color-scheme: \(darkMode ? "dark" : "light"); }
        html, body { margin: 0; padding: 0; background: \(background); color: \(ink); }
        body { padding: 16px; font: 17px/1.7 -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; \
        word-break: break-word; -webkit-text-size-adjust: 100%; }
        img { max-width: 100%; height: auto; }
        video { max-width: 100%; object-fit: fill; background: #000; }
        iframe { max-width: 100%; border: 0; }
        a { color: #3a7bd5; }
        pre, code { white-space: pre-wrap; word-break: break-all; }
        table { width: 100%; border-collapse: collapse; }
        td, th { border: 1px solid rgba(128,128,128,0.35); padding: 4px 6px; }
        </style>
        """
        let preload = preloadJS?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let script = preload.isEmpty ? "" : "<script>\(preload)</script>"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=3, user-scalable=yes">
        \(style)
        \(script)
        </head>
        <body>\(payload)</body>
        </html>
        """
    }

    private static func looksLikeDocument(_ payload: String) -> Bool {
        let head = payload.prefix(512).lowercased()
        return head.contains("<!doctype") || head.contains("<html")
    }
}

/// 网页里常见的 `java.*` 调用来自 Legado 的 WebView 桥；给最小实现，避免整页脚本报错中断。
private enum JavaBridgeShim {
    static let source = """
    (function () {
      if (window.java) { return; }
      var vars = {};
      function syncGet(url) {
        try {
          var xhr = new XMLHttpRequest();
          xhr.open('GET', url, false);
          xhr.send(null);
          return xhr.status >= 200 && xhr.status < 400 ? xhr.responseText : '';
        } catch (e) { return ''; }
      }
      window.java = {
        toast: function () {},
        longToast: function () {},
        log: function () { try { console.log.apply(console, arguments); } catch (e) {} },
        logType: function () {},
        getWebViewUA: function () { return navigator.userAgent; },
        get: function (key) { return vars[key]; },
        put: function (key, value) { vars[key] = value; },
        ajax: function (url) { return syncGet(url); },
        connect: function (url) { return syncGet(url); },
        base64Encode: function (text) {
          try { return btoa(unescape(encodeURIComponent(text))); } catch (e) { return ''; }
        },
        base64Decode: function (text) {
          try { return decodeURIComponent(escape(atob(text))); } catch (e) { return ''; }
        },
        htmlFormat: function (text) { return text; },
        timeFormat: function () { return new Date().toISOString(); },
        timeFormatUTC: function (time, format) {
          try {
            var date = new Date(Number(time));
            var pad = function (n) { return (n < 10 ? '0' : '') + n; };
            return date.getUTCFullYear() + pad(date.getUTCMonth() + 1) + pad(date.getUTCDate())
              + pad(date.getUTCHours()) + pad(date.getUTCMinutes());
          } catch (e) { return ''; }
        }
      };
    })();
    """
}
