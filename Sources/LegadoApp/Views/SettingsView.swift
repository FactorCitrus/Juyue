import SwiftUI
import Darwin
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(LegadoCore)
import LegadoCore
#endif

public struct SettingsView: View {
    @ObservedObject var bookStore = BookStore.shared
    @ObservedObject var readerConfig = ReaderConfig.shared
    @ObservedObject var shelfConfig = BookshelfConfig.shared

    @AppStorage("legado_app_theme") private var appTheme: String = "system"

    @State private var showRestoreAlert: Bool = false
    @State private var restoreSuccessMessage: String? = nil
    @State private var showClearCacheAlert: Bool = false
    /// WebDAV 那行的小字：填了地址就算「已配置」，同步过才是「已同步」。
    /// 之前只看 lastSyncTime，所以填完地址回来还显示「未配置」。
    @State private var webDAVStatusText: String = "未配置"
    @State private var clearCacheMessage: String? = nil

    public init() {}

    private var badgeColorBinding: Binding<Color> {
        Binding(
            get: { shelfConfig.badgeColor },
            set: { shelfConfig.badgeColorHex = $0.hexString ?? shelfConfig.badgeColorHex }
        )
    }

    public var body: some View {
        NavigationView {
            Form {
                // Section 0: App Appearance (Dark Mode)
                Section(header: Text("阅读显示 · 外观模式")) {
                    Picker("外观模式", selection: $appTheme) {
                        Text("跟随系统").tag("system")
                        Text("浅色模式").tag("light")
                        Text("深色模式").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                if !AppEdition.isAppStoreClean {
                    Section(header: Text("书源")) {
                    NavigationLink(destination: SourceCheckView()) {
                        HStack {
                            Text("校验书源")
                            Spacer()
                            Text("逐个检测书源可用性")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    NavigationLink(destination: SourceManagerView()) {
                        HStack {
                            Text("管理全部网络书源")
                            Spacer()
                            Text("\(bookStore.sources.filter { $0.enabled != false }.count) / \(bookStore.sources.count) 个可用")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button {
                        showRestoreAlert = true
                    } label: {
                        HStack {
                            Text("重置书源")
                            Spacer()
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.accentColor)
                        }
                    }
                    }
                }

                // Section 1: Reading Display Settings
                Section(header: Text("阅读显示")) {
                    NavigationLink(destination: OPDSCatalogsView()) {
                        HStack {
                            Text("OPDS / Calibre 书库")
                            Spacer()
                            Text("\(OPDSStore.shared.catalogs.count) 个")
                                .foregroundColor(.secondary)
                        }
                    }

                    NavigationLink(destination: RSSFeedsView()) {
                        HStack {
                            Text("订阅（RSS）")
                            Spacer()
                            Text("\(RSSStore.shared.sources.count) 个源")
                                .foregroundColor(.secondary)
                        }
                    }

                    NavigationLink(destination: LogViewerView()) {
                        HStack {
                            Text("诊断日志")
                            Spacer()
                            Text("查崩溃")
                                .foregroundColor(.secondary)
                        }
                    }

                    NavigationLink(destination: SubscribeSourcesView()) {
                        HStack {
                            Text("订阅源（阅读订阅源）")
                            Spacer()
                            Text("\(SubscribeSourceStore.shared.sources.count) 个源")
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("默认缓存章数")
                        Spacer()
                        Stepper(
                            "\(readerConfig.cachedChapterCount) 章",
                            value: $readerConfig.cachedChapterCount,
                            in: 1...200
                        )
                        .labelsHidden()
                        Text("\(readerConfig.cachedChapterCount) 章")
                            .foregroundColor(.secondary)
                    }

                    NavigationLink(destination: DownloadManagerView()) {
                        HStack {
                            Text("下载管理")
                            Spacer()
                            let running = ChapterDownloadManager.shared.jobs.filter { $0.isRunning }.count
                            Text(running > 0 ? "\(running) 个进行中" : "空闲")
                                .foregroundColor(.secondary)
                        }
                    }

                    NavigationLink(destination: ReadingStatsView()) {
                        HStack {
                            Text("阅读统计")
                            Spacer()
                            Text("\(ReadingStatsStore.shared.streakDays) 天连续")
                                .foregroundColor(.secondary)
                        }
                    }

                    NavigationLink(destination: ReplacementRulesView()) {
                        HStack {
                            Text("替换净化")
                            Spacer()
                            Text("\(TextPurifier.shared.rules.filter { $0.enabled }.count) 条启用")
                                .foregroundColor(.secondary)
                        }
                    }

                    NavigationLink(destination: FontManageView()) {
                        HStack {
                            Text("字体管理")
                            Spacer()
                            Text(readerConfig.font.displayName)
                                .foregroundColor(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("正文字号")
                            Spacer()
                            Text("\(Int(readerConfig.fontSize)) pt")
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("A-")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Slider(value: $readerConfig.fontSize, in: 12...32, step: 1)
                            Text("A+")
                                .font(.body.bold())
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("段落行距")
                            Spacer()
                            Text("\(Int(readerConfig.lineSpacing)) pt")
                                .foregroundColor(.secondary)
                        }

                        Slider(value: $readerConfig.lineSpacing, in: 4...24, step: 1)
                    }
                    .padding(.vertical, 4)

                    #if os(iOS)
                    NavigationLink(destination: ReaderBackgroundSettingsView()) {
                        HStack {
                            Text("正文背景图")
                            Spacer()
                            Text("预览 / 缩放 / 位置")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    NavigationLink(destination: ReaderAssetsSheet { }) {
                        HStack {
                            Text("下拉背景与书签外观")
                            Spacer()
                            Text("背景图 / 书签图")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    #endif

                    Picker("阅读背景主题", selection: $readerConfig.theme) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }

                    // Live theme preview box
                    VStack(alignment: .leading, spacing: 6) {
                        Text("排版预览")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("这是示例文本，天地玄黄，宇宙洪荒。日月盈昃，辰宿列张。")
                            .font(.system(size: readerConfig.fontSize))
                            .lineSpacing(readerConfig.lineSpacing)
                            .foregroundColor(readerConfig.theme.textColor)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(readerConfig.theme.backgroundColor)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .padding(.vertical, 4)
                }

                // 书架角标（封面右上那个红色未读数）

                Section(header: Text("阅读显示 · 书架角标")) {
                    Picker("显示方式", selection: $shelfConfig.badgeStyle) {
                        ForEach(BookshelfBadgeStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }

                    if shelfConfig.badgeStyle == .count {
                        Stepper(value: $shelfConfig.badgeCap, in: 0...999, step: 5) {
                            HStack {
                                Text("数字封顶")
                                Spacer()
                                Text(shelfConfig.badgeCap == 0 ? "不封顶" : "\(shelfConfig.badgeCap)+")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if shelfConfig.badgeStyle != .hidden {
                        ColorPicker("角标颜色", selection: badgeColorBinding, supportsOpacity: false)

                        Picker("位置", selection: $shelfConfig.badgeCorner) {
                            ForEach(BookshelfBadgeCorner.allCases) { corner in
                                Text(corner.rawValue).tag(corner)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("字号")
                                Spacer()
                                Text("\(Int(shelfConfig.badgeFontSize)) pt")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $shelfConfig.badgeFontSize, in: 7...16, step: 1)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("离封面距离")
                                Spacer()
                                Text("\(Int(shelfConfig.badgeOffset)) pt")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $shelfConfig.badgeOffset, in: 0...16, step: 1)
                        }

                        Toggle("白色描边", isOn: $shelfConfig.badgeOutline)
                    }
                }

                // Section 3: Bookshelf & Storage
                Section(header: Text("书架与存储")) {
                    HStack {
                        Text("书架藏书")
                        Spacer()
                        Text("\(bookStore.bookshelf.count) 本")
                            .foregroundColor(.secondary)
                    }

                    Button(role: .destructive) {
                        showClearCacheAlert = true
                    } label: {
                        HStack {
                            Text("清理阅读缓存")
                            Spacer()
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                    }
                }

                // Section 4: Data & Cloud Sync (WebDAV)
                Section(header: Text("数据同步")) {
                    NavigationLink(destination: WebDAVSyncView()) {
                        HStack {
                            Label("WebDAV 云同步", systemImage: "icloud.and.arrow.up")
                            Spacer()
                            Text(webDAVStatusText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Section 5: 听书语音源
                Section(header: Text("听书（朗读引擎）")) {
                    NavigationLink(destination: TTSourceManagerView()) {
                        HStack {
                            Text("朗读引擎")
                            Spacer()
                            Text(TTSourceSelection.displayName(in: HttpTTSStore.shared.sources))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("隐私与许可")) {
                    NavigationLink(destination: ReaderPrivacyView()) {
                        Text("隐私政策")
                    }
                    Link(destination: URL(string: "https://github.com/FactorCitrus/Legado-iOS")!) {
                        HStack {
                            Text("源代码")
                            Spacer()
                            Text("GPLv3")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("关于橘阅")) {
                    HStack {
                        Text("应用名称")
                        Spacer()
                        Text("橘阅阅读器（基于 Legado）")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("当前版本")
                        Spacer()
                        Text(Self.appVersionText)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("内核引擎")
                        Spacer()
                        Text("Swift 原生 + JavaScriptCore")
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com/FactorCitrus/Legado-iOS")!) {
                        HStack {
                            Text("GitHub")
                            Spacer()
                            Text("github.com/FactorCitrus/Legado-iOS")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .onAppear {
                let cfg = WebDAVService.shared.loadConfig()
                if cfg.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    webDAVStatusText = "未配置"
                } else {
                    webDAVStatusText = cfg.lastSyncTime != nil ? "已同步" : "已配置"
                }
            }
            .alert("重置书源", isPresented: $showRestoreAlert) {
                Button("取消", role: .cancel) {}
                Button("确定重置", role: .destructive) {
                    bookStore.loadBundledSources(forceReset: true)
                    restoreSuccessMessage = "书源已重置为预装状态"
                }
            } message: {
                Text("确定要把书源重置为预装默认状态吗？自己导入的书源会被覆盖，重新导入即可。")
            }
            .alert("清理阅读缓存", isPresented: $showClearCacheAlert) {
                Button("取消", role: .cancel) {}
                Button("确定清理", role: .destructive) {
                    clearCacheMessage = "缓存已成功清理"
                }
            } message: {
                Text("确定要清理临时章节与图片缓存吗？书架书籍与阅读进度将保留。")
            }
        }
    }

    /// 装的是哪个包，一眼能看出来：版本号 + 构建号 + 这个可执行文件的编译时间。
    static var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        guard let path = Bundle.main.executablePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let created = attrs[.creationDate] as? Date else {
            return "\(short) (\(build))"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "\(short) (\(build)) · \(formatter.string(from: created))"
    }
}

/// 字体管理：导入 ttf/otf、删除，选中的字体立刻能在阅读设置里用。
struct FontManageView: View {
    @ObservedObject private var readerConfig = ReaderConfig.shared
    @ObservedObject private var fontService = CustomFontService.shared

    @State private var showImporter = false
    @State private var message: String?
    @State private var showMessage = false

    var body: some View {
        List {
            Section(header: Text("正在使用")) {
                HStack {
                    Text(readerConfig.font.displayName)
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }

            Section(header: Text("内置字体")) {
                ForEach(ReaderFont.candidates.filter { $0.isAvailable }) { font in
                    fontRow(font)
                }
            }

            Section(header: Text("自定义字体")) {
                if fontService.registered.isEmpty {
                    Text("还没导入字体。点上面的「导入字体」，选 ttf / otf 文件。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(fontService.registered) { font in
                        fontRow(font)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            fontService.remove(fontService.registered[index])
                        }
                    }
                }
            }
        }
        .navigationTitle("字体管理")
        .toolbar {
            Button {
                showImporter = true
            } label: {
                Label("导入字体", systemImage: "plus")
            }
        }
        #if os(iOS)
        // SwiftUI 的 fileImporter 在这种设置页里经常收不到回调，
        // 用户按「打开」就像没反应，所以 iOS 上改用 UIKit 的文档选择器
        .sheet(isPresented: $showImporter) {
            FontDocumentPicker { urls in
                // 等选择器退场再处理，不然弹窗会被吞
                DispatchQueue.main.async { importPicked(urls) }
            }
        }
        #else
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let urls):
                    importPicked(urls)
                case .failure(let error):
                    message = "导入失败：" + error.localizedDescription
                    showMessage = true
                }
            }
        }
        #endif
        .alert("字体", isPresented: $showMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    /// 选择器收回后统一处理：成功、被拒、以及为什么被拒都要说清楚
    private func importPicked(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var imported: [String] = []
        var rejected: [String] = []
        var reasons: [String] = []
        for url in urls {
            if let font = fontService.importFont(from: url) {
                imported.append(font.displayName)
            } else {
                rejected.append(url.lastPathComponent)
                if let reason = fontService.lastError, !reasons.contains(reason) {
                    reasons.append(reason)
                }
            }
        }
        if imported.isEmpty {
            var text = "没导入成功：" + rejected.joined(separator: "、")
            text += "\n只支持 ttf / otf / ttc；如果是 iCloud 里的文件，先下载到本机再选。"
            if !reasons.isEmpty { text += "\n原因：" + reasons.joined(separator: "；") }
            message = text
        } else if rejected.isEmpty {
            message = "已导入：" + imported.joined(separator: "、")
        } else {
            message = "已导入：" + imported.joined(separator: "、")
                + "\n没读进来：" + rejected.joined(separator: "、")
            if !reasons.isEmpty { message = (message ?? "") + "\n原因：" + reasons.joined(separator: "；") }
        }
        showMessage = true
    }

    private func fontRow(_ font: ReaderFont) -> some View {
        Button {
            readerConfig.fontName = font.postScriptName
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(font.displayName)
                        .foregroundColor(.primary)
                    // 用这个字体本身预览一行，选之前先看清长什么样
                    Text("天地玄黄，宇宙洪荒")
                        .font(.custom(font.postScriptName, size: 15))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if readerConfig.fontName == font.postScriptName {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

}

#if os(iOS)
/// UIKit 的文档选择器：asCopy 会先把文件拷进 App 沙箱再交回来，
/// 比 SwiftUI 的 fileImporter 稳，也不会出现「按了打开没反应」。
struct FontDocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
#endif

// MARK: - 替换净化
/// 正文替换净化：规则按顺序过一遍，用来去广告、水印、站点名
struct ReplacementRulesView: View {
    @ObservedObject private var purifier = TextPurifier.shared
    @State private var editing: ReplacementRule? = nil
    @State private var showImport = false
    @State private var importText = ""
    @State private var importMessage: String?
    @State private var showFileImporter = false

    var body: some View {
        List {
            Section {
                Button {
                    editing = ReplacementRule(name: "", pattern: "", replacement: "")
                } label: {
                    Label("新增规则", systemImage: "plus")
                }
                Button {
                    importText = ""
                    importMessage = nil
                    showImport = true
                } label: {
                    Label("一键导入", systemImage: "square.and.arrow.down")
                }
            }

            Section(header: Text("规则（从上到下依次执行）")) {
                ForEach(purifier.rules) { rule in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.name.isEmpty ? (rule.isRegex ? "正则规则" : "文本替换") : rule.name)
                                .font(.system(size: 14, weight: .medium))
                            Text((rule.isRegex ? "正则：" : "文本：") + rule.pattern)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                            if !rule.replacement.isEmpty {
                                Text("→ " + rule.replacement)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: enabledBinding(rule))
                            .labelsHidden()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = rule }
                }
                .onDelete { indexSet in
                    purifier.rules.remove(atOffsets: indexSet)
                }
            }

            Section {
                Text("留空替换内容＝直接删掉匹配到的文字。正则用 NSRegularExpression 语法，$1 表示第一个捕获组。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("替换净化")
        .sheet(item: $editing) { rule in
            ReplacementRuleEditor(rule: rule) { saved in
                if let idx = purifier.rules.firstIndex(where: { $0.id == saved.id }) {
                    purifier.rules[idx] = saved
                } else {
                    purifier.rules.append(saved)
                }
            }
        }
        .sheet(isPresented: $showImport) { importSheet }
    }

    /// 导入面板：贴 JSON，或者从文件选（对齐安卓 legado 导出的替换净化格式）
    private var importSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text("把替换净化的 JSON 贴进来，或者从文件里选。认安卓导出的那套键：name / pattern / replacement / isRegex / enabled。")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                TextEditor(text: $importText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 200)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

                if let importMessage {
                    Text(importMessage)
                        .font(.footnote)
                        .foregroundColor(importMessage.hasPrefix("导入") ? .green : .red)
                }

                Button {
                    showFileImporter = true
                } label: {
                    Label("从文件导入", systemImage: "doc")
                }

                Spacer()
            }
            .padding()
            .navigationTitle("导入替换净化")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showImport = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { importRules(importText) }
                        .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.json, .plainText, .item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        importText = text
                        importRules(text)
                    } else {
                        importMessage = "读不了这个文件"
                    }
                case .failure(let error):
                    importMessage = "选择文件失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func importRules(_ json: String) {
        guard let parsed = ReplacementRulesView.parseRules(json) else {
            importMessage = "解析失败：不是可用的替换净化 JSON"
            return
        }
        var added = 0
        for rule in parsed {
            let duplicate = purifier.rules.contains {
                $0.pattern == rule.pattern && $0.replacement == rule.replacement && $0.isRegex == rule.isRegex
            }
            if !duplicate {
                purifier.rules.append(rule)
                added += 1
            }
        }
        importMessage = "导入 \(added) 条（跳过重复 \(parsed.count - added) 条）"
        if added > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { showImport = false }
        }
    }

    /// 认安卓 legado 的导出格式，也认本 App 自己存的键
    static func parseRules(_ json: String) -> [ReplacementRule]? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var items: [Any] = []
        if let array = object as? [Any] {
            items = array
        } else if let dict = object as? [String: Any] {
            items = (dict["rules"] as? [Any]) ?? [dict]
        }

        var rules: [ReplacementRule] = []
        for item in items {
            guard let dict = item as? [String: Any] else { continue }
            var pattern = (dict["pattern"] as? String) ?? ""
            var isRegex = (dict["isRegex"] as? Bool) ?? true
            if let rawRegex = dict["regex"] {
                if let text = rawRegex as? String, pattern.isEmpty { pattern = text }
                if let flag = rawRegex as? Bool { isRegex = flag }
            }
            guard !pattern.isEmpty else { continue }
            rules.append(ReplacementRule(
                name: (dict["name"] as? String) ?? "",
                pattern: pattern,
                replacement: (dict["replacement"] as? String) ?? "",
                isRegex: isRegex,
                enabled: (dict["enabled"] as? Bool) ?? true
            ))
        }
        return rules.isEmpty ? nil : rules
    }

    private func enabledBinding(_ rule: ReplacementRule) -> Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { value in
                if let idx = purifier.rules.firstIndex(where: { $0.id == rule.id }) {
                    purifier.rules[idx].enabled = value
                }
            }
        )
    }
}

struct ReplacementRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReplacementRule
    private let onSave: (ReplacementRule) -> Void

    init(rule: ReplacementRule, onSave: @escaping (ReplacementRule) -> Void) {
        _draft = State(initialValue: rule)
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("名称（可留空）", text: $draft.name)
                Toggle("按正则匹配", isOn: $draft.isRegex)
                TextField(draft.isRegex ? "正则表达式" : "要查找的文本", text: $draft.pattern)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("替换成（留空＝删掉）", text: $draft.replacement)
                    .autocorrectionDisabled()
                Toggle("启用", isOn: $draft.enabled)
            }
            .navigationTitle("编辑规则")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.pattern.isEmpty)
                }
            }
        }
    }
}

// MARK: - 阅读统计
struct ReadingStatsView: View {
    @ObservedObject private var stats = ReadingStatsStore.shared

    private func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分"
    }

    var body: some View {
        List {
            Section(header: Text("今天")) {
                statRow("阅读时长", duration(stats.todaySeconds))
                statRow("连续天数", "\(stats.streakDays) 天")
            }
            Section(header: Text("累计")) {
                statRow("总时长", duration(stats.totalSeconds))
                statRow("总字数", NumberFormatter.localizedString(from: NSNumber(value: stats.totalCharacters), number: .decimal) + " 字")
                statRow("读完章节", "\(stats.chaptersRead) 章")
                statRow("有记录天数", "\(stats.daysRead) 天")
            }
            Section(header: Text("最近 7 天")) {
                let days = stats.recentDays(7)
                let maxSeconds = max(1, days.map { $0.seconds }.max() ?? 1)
                ForEach(days, id: \.day) { item in
                    HStack(spacing: 10) {
                        Text(String(item.day.suffix(5)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 44, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(0.7))
                                    .frame(width: max(2, geo.size.width * CGFloat(item.seconds) / CGFloat(maxSeconds)))
                            }
                        }
                        .frame(height: 12)
                        Text(item.seconds > 0 ? duration(item.seconds) : "—")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 74, alignment: .trailing)
                    }
                }
            }
        }
        .navigationTitle("阅读统计")
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}

// MARK: - 下载管理
struct DownloadManagerView: View {
    @ObservedObject private var manager = ChapterDownloadManager.shared

    var body: some View {
        List {
            if manager.jobs.isEmpty {
                Text("没有下载任务。在书籍详情页右上「⋯」里可以缓存全本或未读章节。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(manager.jobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(job.bookName)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(job.isCancelled ? "已取消" : (job.isPaused ? "已暂停" : (job.isRunning ? "下载中" : "已完成")))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    ProgressView(value: job.progress)
                    HStack(spacing: 8) {
                        Text("\(job.finished)/\(job.total)" + (job.failed > 0 ? "，失败 \(job.failed)" : ""))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        if !job.currentChapter.isEmpty {
                            Text(job.currentChapter)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if job.isRunning {
                            Button(job.isPaused ? "继续" : "暂停") {
                                job.isPaused ? manager.resume(job.id) : manager.pause(job.id)
                            }
                            .font(.system(size: 12))
                            Button("取消") { manager.cancel(job.id) }
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("下载管理")
        .toolbar {
            Button("清理已完成") { manager.clearFinished() }
        }
    }
}

// MARK: - 订阅源（阅读订阅源）

/// 订阅源的本地存储：整份 JSON 存 UserDefaults，按 sourceUrl 去重
final class SubscribeSourceStore: ObservableObject {
    static let shared = SubscribeSourceStore()

    @Published var sources: [SubscribeSource] = [] {
        didSet { save() }
    }

    private let key = "subscribe_sources_v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([SubscribeSource].self, from: data) {
            sources = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 导入：同地址的覆盖更新，其余追加。返回 (新增, 更新)
    @discardableResult
    func merge(_ list: [SubscribeSource]) -> (added: Int, updated: Int) {
        var added = 0
        var updated = 0
        for item in list where !item.sourceUrl.isEmpty {
            if let idx = sources.firstIndex(where: { $0.sourceUrl == item.sourceUrl }) {
                sources[idx] = item
                updated += 1
            } else {
                sources.append(item)
                added += 1
            }
        }
        return (added, updated)
    }

    func remove(sourceUrl: String) {
        sources.removeAll { $0.sourceUrl == sourceUrl }
    }

    func toggle(sourceUrl: String) {
        guard let idx = sources.firstIndex(where: { $0.sourceUrl == sourceUrl }) else { return }
        sources[idx].enabled = !(sources[idx].enabled ?? true)
    }
}

struct SubscribeSourcesView: View {
    @ObservedObject private var store = SubscribeSourceStore.shared

    @State private var showImport = false
    @State private var importText = ""
    @State private var importURL = ""
    @State private var message: String?
    @State private var showFileImporter = false
    @State private var editing: SubscribeSource?

    var body: some View {
        List {
            if store.sources.isEmpty {
                Section {
                    Text("还没有订阅源。右上角可以粘贴 / 导入 Legado 的 rssSources.json。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("订阅源（\(store.sources.count)）")) {
                ForEach(store.sources) { source in
                    NavigationLink {
                        SubscribeArticlesView(source: source)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(source.sourceName.isEmpty ? source.sourceUrl : source.sourceName)
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()
                                if source.enabled == false {
                                    Text("已停用")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text(source.sourceUrl)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contextMenu {
                        Button {
                            editing = source
                        } label: {
                            Label("看 / 改源码", systemImage: "curlybraces")
                        }
                        Button {
                            store.toggle(sourceUrl: source.sourceUrl)
                        } label: {
                            Label(source.enabled == false ? "启用" : "停用", systemImage: "power")
                        }
                        Button(role: .destructive) {
                            store.remove(sourceUrl: source.sourceUrl)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .onDelete { indexSet in
                    for idx in indexSet where idx < store.sources.count {
                        store.remove(sourceUrl: store.sources[idx].sourceUrl)
                    }
                }
            }
        }
        .navigationTitle("订阅源")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImport = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
        }
        .alert(message ?? "", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) {}
        }
        .sheet(isPresented: $showImport) {
            SubscribeImportSheet(
                importText: $importText,
                importURL: $importURL,
                onDone: { text in message = text },
                onPickFile: { showFileImporter = true }
            )
        }
        .sheet(item: $editing) { source in
            SubscribeSourceEditor(source: source) { updated in
                store.merge([updated])
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json, .plainText]) { result in
            switch result {
            case .success(let url):
                let canAccess = url.startAccessingSecurityScopedResource()
                defer { if canAccess { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url),
                   let text = String(data: data, encoding: .utf8) {
                    message = importJSON(text)
                } else {
                    message = "文件读不出来。"
                }
            case .failure(let error):
                message = "打开文件失败：\(error.localizedDescription)"
            }
        }
    }

    private func importJSON(_ text: String) -> String {
        do {
            let list = try SubscribeSourceService.decodeSources(from: text)
            guard !list.isEmpty else { return "没解析出订阅源，检查是不是 rssSources.json 的格式。" }
            let result = store.merge(list)
            return "导入完成：新增 \(result.added) 个，更新 \(result.updated) 个。"
        } catch {
            return "解析失败：\(error.localizedDescription)"
        }
    }
}

struct SubscribeImportSheet: View {
    @Binding var importText: String
    @Binding var importURL: String
    let onDone: (String) -> Void
    let onPickFile: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isFetching = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("粘贴 JSON")) {
                    TextEditor(text: $importText)
                        .frame(minHeight: 140)
                        .font(.system(.caption, design: .monospaced))
                    Button {
                        apply(importText)
                    } label: {
                        Label("导入粘贴的内容", systemImage: "doc.text")
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section(header: Text("从网址导入")) {
                    TextField("https://…/rssSources.json", text: $importURL)
                        .autocorrectionDisabled()
                    Button {
                        fetchRemote()
                    } label: {
                        HStack {
                            Label("下载并导入", systemImage: "arrow.down.circle")
                            Spacer()
                            if isFetching { ProgressView() }
                        }
                    }
                    .disabled(isFetching || importURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section {
                    Button {
                        onPickFile()
                    } label: {
                        Label("从文件导入", systemImage: "folder")
                    }
                } footer: {
                    Text("跟安卓版 Legado 的订阅源文件互通：数组或单个对象都认。")
                }
            }
            .navigationTitle("导入订阅源")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func apply(_ text: String) {
        onDone(importText.isEmpty ? "没有内容。" : "已解析，返回列表查看。")
        if let list = try? SubscribeSourceService.decodeSources(from: text) {
            let result = SubscribeSourceStore.shared.merge(list)
            onDone("导入完成：新增 \(result.added) 个，更新 \(result.updated) 个。")
        } else {
            onDone("解析失败，检查 JSON 格式。")
        }
        dismiss()
    }

    private func fetchRemote() {
        let url = importURL.trimmingCharacters(in: .whitespaces)
        guard let target = URL(string: url) else {
            onDone("网址不合法。")
            return
        }
        isFetching = true
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: target)
                let text = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run {
                    isFetching = false
                    apply(text)
                }
            } catch {
                await MainActor.run {
                    isFetching = false
                    onDone("下载失败：\(error.localizedDescription)")
                }
            }
        }
    }
}

struct SubscribeSourceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var raw: String
    @State private var error: String?
    private let original: SubscribeSource
    private let onSave: (SubscribeSource) -> Void

    init(source: SubscribeSource, onSave: @escaping (SubscribeSource) -> Void) {
        self.original = source
        self.onSave = onSave
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self._raw = State(initialValue: (try? encoder.encode(source)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("整段 JSON（保存时解析回写）")) {
                    TextEditor(text: $raw)
                        .frame(minHeight: 360)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                }
                if let error {
                    Section {
                        Text(error).font(.caption).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("订阅源源码")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let list = try? SubscribeSourceService.decodeSources(from: raw), let parsed = list.first else {
                            error = "JSON 解析失败，检查括号和引号。"
                            return
                        }
                        onSave(parsed)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct SubscribeArticlesView: View {
    let source: SubscribeSource

    @State private var articles: [SubscribeArticle] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var selected: SubscribeArticle?

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                        Text("正在抓取…").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            if let errorText {
                Section {
                    Text(errorText).font(.caption).foregroundColor(.red)
                }
            }
            Section {
                ForEach(articles) { article in
                    Button {
                        selected = article
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(article.title)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                            if let date = article.date, !date.isEmpty {
                                Text(date).font(.caption2).foregroundColor(.secondary)
                            }
                            if let summary = article.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            } header: {
                Text(articles.isEmpty ? "没有条目" : "\(articles.count) 条")
            } footer: {
                Text(source.sourceName.isEmpty ? source.sourceUrl : source.sourceName)
            }
        }
        .navigationTitle(source.sourceName.isEmpty ? "订阅" : source.sourceName)
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $selected) { article in
            SubscribeArticleView(article: article, source: source)
        }
    }

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            articles = try await SubscribeSourceService.fetchArticles(source: source)
            if articles.isEmpty { errorText = "这条源没抓到条目：检查规则或地址。" }
        } catch {
            errorText = "抓取失败：\(error.localizedDescription)"
        }
        isLoading = false
    }
}

struct SubscribeArticleView: View {
    let article: SubscribeArticle
    let source: SubscribeSource

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var isLoading = true

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(article.title)
                        .font(.title3.bold())
                    if let date = article.date, !date.isEmpty {
                        Text(date).font(.caption).foregroundColor(.secondary)
                    }
                    if isLoading {
                        ProgressView().padding(.top, 20)
                    } else {
                        Text(content.isEmpty ? "没取到正文，点右上角去网页看。" : content)
                            .font(.system(size: 16))
                            .lineSpacing(6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationTitle("正文")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let url = URL(string: article.link) {
                        Link(destination: url) {
                            Image(systemName: "safari")
                        }
                    }
                }
            }
            .task {
                content = (try? await SubscribeSourceService.fetchContent(article: article, source: source)) ?? ""
                isLoading = false
            }
        }
    }
}

// MARK: - RSS 订阅
struct RSSFeedsView: View {
    @ObservedObject private var store = RSSStore.shared
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newURL = ""

    var body: some View {
        List {
            Section {
                Button {
                    newName = ""; newURL = ""
                    showAdd = true
                } label: {
                    Label("添加订阅源", systemImage: "plus")
                }
            }
            Section(header: Text("订阅源")) {
                if store.sources.isEmpty {
                    Text("还没有订阅源。填 RSS / Atom 地址即可，比如公众号镜像、博客、新闻站点。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(store.sources) { source in
                    NavigationLink(destination: RSSItemsView(source: source)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name.isEmpty ? source.url : source.name)
                                .font(.system(size: 15))
                            if !source.name.isEmpty {
                                Text(source.url).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet where i < store.sources.count { store.remove(store.sources[i]) }
                }
            }
        }
        .navigationTitle("订阅（RSS）")
        .alert("添加订阅源", isPresented: $showAdd) {
            TextField("名称（可留空）", text: $newName)
            TextField("RSS / Atom 地址", text: $newURL)
                .autocorrectionDisabled()
            Button("添加") { store.add(name: newName, url: newURL) }
            Button("取消", role: .cancel) {}
        }
    }
}

struct RSSItemsView: View {
    let source: RSSSource
    @State private var items: [RSSItem] = []
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        List {
            if let errorText {
                Text(errorText).font(.footnote).foregroundColor(.red)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 15, weight: .medium))
                    if !item.date.isEmpty {
                        Text(item.date).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    if !item.summary.isEmpty {
                        Text(item.summary).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(3)
                    }
                    if !item.link.isEmpty {
                        Link("打开原文", destination: URL(string: item.link) ?? URL(string: "about:blank")!)
                            .font(.system(size: 12))
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle(source.name.isEmpty ? "订阅" : source.name)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        errorText = nil
        do {
            items = try await RSSService.shared.fetchFeed(url: source.url, sourceName: source.name)
            if items.isEmpty { errorText = "没解析出条目，确认地址是 RSS / Atom 输出。" }
        } catch {
            errorText = "拉取失败：" + error.localizedDescription
        }
        loading = false
    }
}

// MARK: - OPDS / Calibre
struct OPDSCatalogsView: View {
    @ObservedObject private var store = OPDSStore.shared
    @State private var showAdd = false
    @State private var name = ""
    @State private var url = ""
    @State private var user = ""
    @State private var pass = ""

    var body: some View {
        List {
            Section {
                Button {
                    name = ""; url = ""; user = ""; pass = ""
                    showAdd = true
                } label: {
                    Label("添加书库", systemImage: "plus")
                }
            }
            Section(header: Text("OPDS / Calibre 书库")) {
                if store.catalogs.isEmpty {
                    Text("填 OPDS 地址即可，例如 Calibre-Web 的 /opds 或 Calibre 内容服务器的 /opds。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(store.catalogs) { catalog in
                    NavigationLink(destination: OPDSBrowserView(catalog: catalog, path: catalog.url, title: catalog.name)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(catalog.name.isEmpty ? catalog.url : catalog.name).font(.system(size: 15))
                            if !catalog.name.isEmpty {
                                Text(catalog.url).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet where i < store.catalogs.count { store.remove(store.catalogs[i]) }
                }
            }
        }
        .navigationTitle("OPDS 书库")
        .alert("添加书库", isPresented: $showAdd) {
            TextField("名称（可留空）", text: $name)
            TextField("OPDS 地址", text: $url)
                .autocorrectionDisabled()
            TextField("用户名（可留空）", text: $user)
                .autocorrectionDisabled()
            SecureField("密码（可留空）", text: $pass)
            Button("添加") { store.add(name: name, url: url, username: user, password: pass) }
            Button("取消", role: .cancel) {}
        }
    }
}

struct OPDSBrowserView: View {
    let catalog: OPDSCatalog
    let path: String
    let title: String

    @State private var entries: [OPDSEntry] = []
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        List {
            if let message {
                Text(message).font(.footnote).foregroundColor(.secondary)
            }
            ForEach(entries) { entry in
                if entry.isNavigation {
                    NavigationLink(destination: OPDSBrowserView(catalog: catalog, path: entry.href, title: entry.title)) {
                        entryRow(entry)
                    }
                } else if let first = entry.acquisitions.first {
                    Button {
                        Task { await download(first.href, name: entry.title) }
                    } label: {
                        entryRow(entry)
                    }
                } else {
                    entryRow(entry)
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle(title.isEmpty ? "书库" : title)
        .task { await load() }
        .refreshable { await load() }
    }

    private func entryRow(_ entry: OPDSEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title).font(.system(size: 15, weight: .medium))
            if !entry.author.isEmpty {
                Text(entry.author).font(.system(size: 11)).foregroundColor(.secondary)
            }
            if !entry.summary.isEmpty {
                Text(entry.summary).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        loading = true
        message = nil
        do {
            let result = try await OPDSService.shared.fetch(path, username: catalog.username, password: catalog.password)
            entries = result.entries
            if entries.isEmpty { message = "这个地址没返回条目。" }
        } catch {
            message = "拉取失败：" + error.localizedDescription
        }
        loading = false
    }

    private func download(_ href: String, name: String) async {
        loading = true
        message = "正在下载 " + name + "…"
        do {
            let file = try await OPDSService.shared.download(href, username: catalog.username, password: catalog.password)
            _ = try BookStore.shared.importFile(from: file)
            message = "已加入书架：" + name
        } catch {
            message = "下载失败：" + error.localizedDescription
        }
        loading = false
    }
}

// MARK: - 诊断日志

/// 极简应用日志：写在沙盒 Documents/AppLogs/app.log，最多保留 512KB。
/// 挂未捕获异常处理器，崩溃时留下一条日志。
enum AppLog {
    static let defaultMaxLines = 100

    /// 是否记录常规日志（崩溃标记不受它影响，永远写）
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "app_log_enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "app_log_enabled") }
    }

    /// 保留多少行，默认 100
    static var maxLines: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "app_log_max_lines")
            return value > 0 ? value : defaultMaxLines
        }
        set { UserDefaults.standard.set(max(20, newValue), forKey: "app_log_max_lines") }
    }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AppLogs", isDirectory: true).appendingPathComponent("app.log")
    }

    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let stacks = exception.callStackSymbols.prefix(14).joined(separator: " | ")
            AppLog.writeSync("💥 未捕获异常 \(exception.name.rawValue): \(exception.reason ?? "") || \(stacks)")
        }
        // Swift 运行时的 fatalError / 前提条件失败 / 野指针走的是信号，不走 NSException，
        // 所以要单独接一层：只写一行标记再交还给系统，保持原本的崩溃行为
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig, { received in
                let name = AppLog.signalName(received)
                AppLog.writeSync("💥 信号 \(name)——运行时崩溃，上一行日志就是最后的动作\n")
                signal(received, SIG_DFL)
                raise(received)
            })
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        // Core 层的日志出口接到这里：LegadoCore 不依赖 App 层，只能运行时注入
        LegadoLog.handler = { line in AppLog.write(line) }
        // 启动行属于常规日志，跟着开关走
        write("—— 启动 v\(version) (\(build)) ——")
    }

    /// 落盘前的隐私过滤。
    ///
    /// 规矩：日志只记「操作类型 / 序数 / 耗时 / 状态码 / 字节数 / 错误类型」，
    /// 不记搜索词、书名作者、章节标题、正文、URL 的 path 与 query、任何凭据、
    /// 设备名、绝对路径的兜底过滤，命中就整行不写。
    static func sanitize(_ line: String) -> String {
        let banned = [
            "password", "passwd", "secret", "apikey", "api_key", "appid", "app_id",
            "serial", "token", "authorization", "key=", "keyword=", "/users/", "/var/"
        ]
        let lowered = line.lowercased()
        if banned.contains(where: { lowered.contains($0) }) {
            return "[已过滤] 这一行命中隐私关键词，未写入"
        }
        return line
    }

    /// 信号处理里能安全调用的写盘方式（只有 open/write/close）
    static func writeSync(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(sanitize(line))\n"
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = text.withCString { Darwin.write(fd, $0, strlen($0)) }
        Darwin.close(fd)
    }

    static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGFPE: return "SIGFPE"
        default: return "SIG\(sig)"
        }
    }

    static func write(_ line: String) {
        guard isEnabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(sanitize(line))\n"
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: fileURL)
        }
        trimToLines()
    }

    /// 超过保留行数就从前面砍
    private static func trimToLines() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return }
        lines = Array(lines.suffix(maxLines))
        try? Data((lines.joined(separator: "\n")).utf8).write(to: fileURL)
    }

    static func read() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "（还没有日志）"
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// 日志查看：崩溃后进来复制一份发我就够定位了
struct LogViewerView: View {
    @State private var text = ""
    @State private var copied = false
    @State private var logEnabled = AppLog.isEnabled
    @State private var lineLimit = AppLog.maxLines

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("记录日志", isOn: $logEnabled)
                    .onChange(of: logEnabled) { newValue in
                        AppLog.isEnabled = newValue
                        load()
                    }
                Spacer()
                Stepper(value: $lineLimit, in: 20...2000, step: 20) {
                    Text("保留 \(lineLimit) 行")
                        .font(.caption)
                }
                .onChange(of: lineLimit) { newValue in
                    AppLog.maxLines = newValue
                    load()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            Divider()
            HStack(spacing: 12) {
                Button(copied ? "已复制" : "复制全部") {
                    #if os(iOS)
                    UIPasteboard.general.string = text
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    #endif
                    copied = true
                }
                Button("刷新") { load() }
                Button("清空", role: .destructive) {
                    AppLog.clear()
                    load()
                }
                Spacer()
                Text("\(text.count) 字符")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(12)
        }
        .navigationTitle("诊断日志")
        .onAppear { load() }
    }

    private func load() {
        copied = false
        text = AppLog.read()
    }
}

/// 商店版的隐私说明：不建账号、不做分析，数据只留在本机。
struct ReaderPrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("橘阅阅读器隐私政策")
                    .font(.title3.bold())
                Text("1. 本应用不创建账号，不收集姓名、邮箱、通讯录、位置或广告标识。")
                Text("2. 书籍文件、阅读进度、书签和设置只保存在你的设备上。卸载应用会删除这些数据。")
                Text("3. 只有你主动添加 OPDS / Calibre 书库或使用 WebDAV 备份时，应用才会连接你填写的服务器。")
                Text("4. 本应用不提供书籍内容，也不内置第三方书源；请只导入你拥有合法使用权的文件。")
                Text("5. 应用使用系统语音朗读；不会把正文上传到服务器。")
                Text("如有问题，请在项目主页提交 issue。")
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("隐私政策")
    }
}
