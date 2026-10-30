import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 应用设置备份：独立导出 / 导入 `settings.json`，不依赖 WebDAV 整包。
struct AppSettingsBackupView: View {
    @Environment(\.appTheme) private var theme

    @State private var showExporter = false
    @State private var exportDocument: ExportedFile?
    @State private var exportName = "legado-settings.json"
    @State private var pendingPayload: AppSettingsPayload?
    @State private var showImportPreview = false
    @State private var restoreMode: AppSettingsRestoreMode = .merge
    @State private var message: String?
    @State private var showMessage = false
    @State private var showTextImport = false
    @State private var importText = ""
    @State private var includeLoginState = false

    private var current: AppSettingsPayload {
        AppSettingsBackup.makePayload(sanitizeCredentials: !includeLoginState)
    }

    var body: some View {
        List {
            Section {
                TerminalPageHeader(
                    code: "SETTINGS / BACKUP",
                    title: "设置备份",
                    detail: "导出或恢复应用设置"
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
            }
            .appThemedRows()

            Section(header: Text("备份内容")) {
                summaryRow("阅读排版", value: "\(Int(current.readerLayout?.fontSize ?? 0))pt · \(current.readerLayout?.fontName ?? "默认字体")")
                summaryRow("书架外观", value: shelfSummary(current.bookshelf))
                summaryRow("外观主题", value: themeSummary(current))
                summaryRow("替换规则", value: "\(current.replaceRules?.count ?? 0) 条")
                summaryRow("网络书源", value: "\(current.sources?.count ?? 0) 个")
                summaryRow("朗读设置", value: current.tts == nil ? "无" : "语速、切段、音色、多角色")
            }
            .appThemedRows()

            Section {
                Toggle("带上书源登录信息", isOn: $includeLoginState)
                Text(includeLoginState
                     ? "Cookie 和登录信息会写进文件。只在自己的设备之间用。"
                     : "默认不带登录信息，发给别人也不会带上 Cookie。")
                    .font(.caption2)
                    .foregroundColor(includeLoginState ? theme.palette.warning : theme.palette.secondaryInk)

                Button {
                    exportSettings()
                } label: {
                    Label("导出设置 JSON", systemImage: "square.and.arrow.up")
                }

                Button {
                    pickFile()
                } label: {
                    Label("从文件导入", systemImage: "square.and.arrow.down")
                }

                Button {
                    importFromClipboard()
                } label: {
                    Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                }

                Button {
                    importText = ""
                    showTextImport = true
                } label: {
                    Label("粘贴 JSON 导入", systemImage: "text.badge.plus")
                }
            }
            .appThemedRows()

            Section {
                Text("书架正文、阅读进度、语音源地址、WebDAV 密码，这些都不带走。")
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle("设置备份")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportName
        ) { result in
            switch result {
            case .success:
                message = "设置已导出"
            case .failure(let error):
                message = "导出失败：\(error.localizedDescription)"
            }
            showMessage = true
        }
        .sheet(isPresented: $showImportPreview) {
            if let payload = pendingPayload {
                importPreview(payload)
            }
        }
        .sheet(isPresented: $showTextImport) {
            textImportSheet
        }
        .alert(message ?? "", isPresented: $showMessage) {
            Button("好", role: .cancel) {}
        }
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(theme.typography.body)
            Spacer()
            Text(value)
                .font(theme.typography.mono)
                .foregroundColor(theme.palette.secondaryInk)
                .lineLimit(1)
        }
    }

    private func shelfSummary(_ shelf: BookshelfSettingsSnapshot?) -> String {
        guard let shelf else { return "无" }
        let layout = BookshelfLayoutStyle(rawValue: shelf.layout)?.rawValue ?? shelf.layout
        return "\(layout) · \(Int((shelf.cardScale * 100).rounded()))%"
    }

    private func themeSummary(_ payload: AppSettingsPayload) -> String {
        var parts: [String] = []
        if let mode = payload.appearanceMode { parts.append(mode) }
        if let choice = payload.themeChoice,
           let theme = AppThemeChoice(rawValue: choice) {
            parts.append(theme.title)
        }
        return parts.isEmpty ? "无" : parts.joined(separator: " · ")
    }

    private func exportSettings() {
        guard let data = AppSettingsBackup.makeJSON(sanitizeCredentials: !includeLoginState) else {
            message = "导出失败：设置编码出错"
            showMessage = true
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        exportName = "legado-settings-\(formatter.string(from: Date())).json"
        exportDocument = ExportedFile(data: data)
        showExporter = true
    }

    private func pickFile() {
        #if os(iOS)
        SettingsDocumentPicker.present(contentTypes: [.json, .plainText]) { urls in
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                handleImportData(try Data(contentsOf: url))
            } catch {
                message = "文件读取失败：\(error.localizedDescription)"
                showMessage = true
            }
        }
        #else
        message = "当前平台请用剪贴板或文本导入"
        showMessage = true
        #endif
    }

    private func importFromClipboard() {
        var text: String?
        #if canImport(UIKit)
        text = UIPasteboard.general.string
        #elseif canImport(AppKit)
        text = NSPasteboard.general.string(forType: .string)
        #endif
        guard let text, let data = text.data(using: .utf8) else {
            message = "剪贴板没有可导入的 JSON 文本"
            showMessage = true
            return
        }
        handleImportData(data)
    }

    private func handleImportData(_ data: Data) {
        guard let payload = AppSettingsBackup.decode(data) else {
            message = "这不是设置备份文件，或者来自更新版本的橘阅。"
            showMessage = true
            return
        }
        pendingPayload = payload
        restoreMode = .merge
        DispatchQueue.main.async { showImportPreview = true }
    }

    private var textImportSheet: some View {
        NavigationView {
            VStack(spacing: 10) {
                TextEditor(text: $importText)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(6)
                    .background(theme.palette.elevated)
                    .cornerRadius(8)
                Button("预览") {
                    guard let data = importText.data(using: .utf8) else { return }
                    showTextImport = false
                    handleImportData(data)
                }
                .buttonStyle(.borderedProminent)
                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .navigationTitle("粘贴设置 JSON")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showTextImport = false }
                }
            }
        }
    }

    private func importPreview(_ payload: AppSettingsPayload) -> some View {
        NavigationView {
            List {
                Section(header: Text("备份内容")) {
                    if payload.readerLayout != nil { Text("阅读排版") }
                    if payload.bookshelf != nil { Text("书架外观") }
                    if payload.appearanceMode != nil || payload.themeChoice != nil { Text("外观主题") }
                    if let rules = payload.replaceRules { Text("替换规则 \(rules.count) 条") }
                    if let sources = payload.sources { Text("网络书源 \(sources.count) 个") }
                    if payload.tts != nil { Text("朗读设置") }
                }

                Section(header: Text("恢复方式")) {
                    Picker("恢复方式", selection: $restoreMode) {
                        Text("合并").tag(AppSettingsRestoreMode.merge)
                        Text("整体替换").tag(AppSettingsRestoreMode.replace)
                    }
                    .pickerStyle(.segmented)
                    Text(restoreMode == .merge
                         ? "现有设置不动，缺的补上，同名书源和重复规则不会再加一遍。"
                         : "用备份覆盖阅读排版、书架外观、替换规则和书源列表。")
                        .font(.caption2)
                        .foregroundColor(restoreMode == .replace ? .orange : .secondary)
                }
            }
            .navigationTitle("恢复设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        pendingPayload = nil
                        showImportPreview = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("恢复") {
                        let summary = AppSettingsBackup.apply(payload, mode: restoreMode)
                        pendingPayload = nil
                        showImportPreview = false
                        DispatchQueue.main.async {
                            message = "已恢复：\(summary)"
                            showMessage = true
                        }
                    }
                }
            }
        }
    }
}

#if os(iOS)
/// 设置备份用的系统文档选择器。从 sheet 里触发 `fileImporter` 在部分 iOS 版本收不到回调。
private enum SettingsDocumentPicker {
    private static var retained: Delegate?

    static func present(contentTypes: [UTType], onPicked: @escaping ([URL]) -> Void) {
        guard let top = topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        let delegate = Delegate(onPicked: onPicked)
        retained = delegate
        picker.delegate = delegate
        top.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
            ?? scenes.first?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let onPicked: ([URL]) -> Void

        init(onPicked: @escaping ([URL]) -> Void) {
            self.onPicked = onPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // 选择器还在退场时立刻弹预览 sheet，SwiftUI 会把这次 presentation 丢掉，
            // 表现就是「选完文件什么都没发生」。等退场动画结束再回调。
            let callback = onPicked
            SettingsDocumentPicker.retained = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                callback(urls)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            SettingsDocumentPicker.retained = nil
        }
    }
}
#endif
