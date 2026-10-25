import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif
#if canImport(LegadoCore)
import LegadoCore
#endif

/// WebDAV 云同步：配置、探活、备份、恢复、本地 zip 导入导出。
///
/// 异步动作共用 `Activity` 状态机；三档确认与普通提示共用单一 `Dialog`，
/// 避免同一节点挂多个 `.alert` —— iOS 只认最后一个。
public struct WebDAVSyncView: View {
    @ObservedObject var bookStore = BookStore.shared
    @Environment(\.appTheme) private var theme

    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var remotePath = "legado"
    @State private var deviceName = ""
    @State private var lastSyncTime: Date?

    @State private var activity: Activity = .idle
    @State private var dialog: Dialog?

    @State private var remoteBackups: [RemoteBackupInfo] = []
    @State private var showBackupPickerSheet = false
    @State private var selectedRestoreBackupName: String?

    /// 备份包存到「文件」，不连 WebDAV 也能备份
    @State private var showBackupExporter = false
    @State private var backupExportDocument: ExportedFile?
    @State private var backupExportName = "backup.zip"

    public init() {}

    // MARK: 状态

    private enum Activity: Equatable {
        case idle
        case testing
        case backingUp
        case restoring
        case fetchingBackups
    }

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// 本地备份包解析结果：只解析、不落盘，等用户选模式。
    private struct ImportPreview: Identifiable {
        let id = UUID()
        let fileName: String
        let books: [Book]?
        let sources: [BookSource]?
        let settingsData: Data?

        var summary: String {
            [
                "文件：\(fileName)",
                "书架 \(books?.count ?? 0) 本",
                "书源 \(sources?.count ?? 0) 个",
                "应用设置：\(settingsData == nil ? "无" : "有")"
            ].joined(separator: "\n")
        }
    }

    private enum Dialog: Identifiable {
        case notice(Notice)
        case restoreConfirm
        case importConfirm(ImportPreview)

        var id: String {
            switch self {
            case .notice(let notice): return "notice-\(notice.id.uuidString)"
            case .restoreConfirm: return "restore-confirm"
            case .importConfirm(let preview): return "import-\(preview.id.uuidString)"
            }
        }

        var title: String {
            switch self {
            case .notice(let notice): return notice.title
            case .restoreConfirm: return "从 WebDAV 恢复"
            case .importConfirm: return "导入备份包"
            }
        }
    }

    private var isBusy: Bool { activity != .idle }

    private var currentConfig: WebDAVConfig {
        WebDAVConfig(
            url: url,
            username: username,
            password: password,
            remotePath: remotePath,
            deviceName: deviceName.isEmpty ? WebDAVConfig.defaultDeviceName : deviceName,
            lastSyncTime: lastSyncTime
        )
    }

    // MARK: 页面

    public var body: some View {
        Form {
            Section {
                TerminalPageHeader(code: "DATA / SYNC", title: "WebDAV 云同步", detail: "备份 / 恢复 / 远端版本")
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }
            .appThemedRows()
            serverSection
            statusSection
            actionsSection
            localBackupSection
        }
        .appThemedList()
        .navigationTitle("WebDAV 云同步")
        .onAppear(perform: loadConfig)
        .alert(
            Text(dialog?.title ?? ""),
            isPresented: Binding(
                get: { dialog != nil },
                set: { presented in if !presented { dialog = nil } }
            ),
            presenting: dialog
        ) { current in
            dialogActions(for: current)
        } message: { current in
            Text(message(for: current))
        }
        .sheet(isPresented: $showBackupPickerSheet) {
            backupPicker
        }
        .fileExporter(
            isPresented: $showBackupExporter,
            document: backupExportDocument,
            contentType: .zip,
            defaultFilename: backupExportName
        ) { result in
            switch result {
            case .success:
                dialog = .notice(Notice(title: "备份包已导出", message: "已存到「文件」：\(backupExportName)"))
            case .failure(let error):
                dialog = .notice(Notice(title: "导出失败", message: error.localizedDescription))
            }
        }
    }

    @ViewBuilder
    private func dialogActions(for current: Dialog) -> some View {
        switch current {
        case .notice:
            Button("确定", role: .cancel) {}

        case .restoreConfirm:
            Button("取消", role: .cancel) {}
            Button("替换恢复（完全采用备份）", role: .destructive) {
                saveConfig()
                restoreFromWebDAV(backupFileName: selectedRestoreBackupName, mode: .replace)
            }
            Button("合并恢复（保留本地进度 / 分组 / 封面）") {
                saveConfig()
                restoreFromWebDAV(backupFileName: selectedRestoreBackupName, mode: .merge)
            }

        case .importConfirm(let preview):
            Button("取消", role: .cancel) {
                AppLog.write("[云备份] 用户取消导入")
            }
            Button("替换导入", role: .destructive) {
                applyImport(preview, mode: .replace)
            }
            Button("合并导入") {
                applyImport(preview, mode: .merge)
            }
        }
    }

    private func message(for current: Dialog) -> String {
        switch current {
        case .notice(let notice):
            return notice.message
        case .restoreConfirm:
            if let name = selectedRestoreBackupName {
                return "从 WebDAV 下载 [\(name)]，和本地数据合并。继续吗？"
            }
            return "从 WebDAV 下载最新的备份，和本地数据合并。继续吗？"
        case .importConfirm(let preview):
            return preview.summary
        }
    }

    // MARK: 服务器设置

    private var serverSection: some View {
        Section {
            field("服务器地址", placeholder: "https://dav.jianguoyun.com/dav/", text: $url)
            field("账号", placeholder: "坚果云账号/邮箱", text: $username)

            HStack {
                Text("密码")
                    .frame(width: 85, alignment: .leading)
                SecureField("应用密码 / 访问凭证", text: $password)
            }

            field("远程目录", placeholder: "legado", text: $remotePath)
            field("设备名称", placeholder: WebDAVConfig.defaultDeviceName, text: $deviceName)

            VStack(alignment: .leading, spacing: 8) {
                Text("快捷填入服务预设")
                    .font(.caption)
                    .foregroundColor(theme.palette.secondaryInk)
                HStack(spacing: 8) {
                    preset("坚果云", server: "https://dav.jianguoyun.com/dav/")
                    preset("InfiniCLOUD", server: "https://teracloud.jp/dav/")
                    preset("Nextcloud", server: "https://example.com/remote.php/dav/files/user/")
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("WebDAV 服务器设置")
        } footer: {
            Text("坚果云这类服务，要先在网页端生成「应用专用密码」再填进来。备份包是 backupYYYY-MM-DD-设备名称.zip，安卓 Legado 也能恢复。")
        }
        .appThemedRows()
    }

    /// 五个配置项长得一样，只有占位文案与是否明文不同。
    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
                .frame(width: 85, alignment: .leading)
            TextField(placeholder, text: text)
                #if os(iOS)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                #endif
        }
    }

    private func preset(_ name: String, server: String) -> some View {
        Button(name) {
            url = server
            if remotePath.isEmpty { remotePath = "legado" }
            saveConfig()
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }

    // MARK: 状态区

    private var statusSection: some View {
        Section(header: Text("同步状态")) {
            HStack {
                Text("上次同步时间")
                Spacer()
                Text(lastSyncTime.map(formatDate) ?? "暂未同步")
                    .foregroundColor(theme.palette.secondaryInk)
            }
            HStack {
                Text("本地书架")
                Spacer()
                Text("\(bookStore.bookshelf.count) 本")
                    .foregroundColor(theme.palette.secondaryInk)
            }
            HStack {
                Text("本地书源")
                Spacer()
                Text("\(bookStore.sources.count) 个")
                    .foregroundColor(theme.palette.secondaryInk)
            }
        }
        .appThemedRows()
    }

    // MARK: 操作区

    private var actionsSection: some View {
        Section(header: Text("同步操作")) {
            actionRow(
                .testing,
                title: "测试连接",
                busyTitle: "正在测试连接...",
                systemImage: "antenna.radiowaves.left.and.right"
            ) {
                saveConfig()
                testConnection()
            }

            actionRow(
                .backingUp,
                title: "立即备份至 WebDAV",
                busyTitle: "正在备份中...",
                systemImage: "arrow.up.doc",
                requiresAccount: true
            ) {
                saveConfig()
                backupToWebDAV()
            }

            actionRow(
                .fetchingBackups,
                title: "选择云端历史备份恢复...",
                busyTitle: "正在获取云端备份...",
                systemImage: "clock.arrow.circlepath",
                requiresAccount: true
            ) {
                saveConfig()
                fetchRemoteBackups()
            }

            actionRow(
                .restoring,
                title: "从 WebDAV 恢复最新数据",
                busyTitle: "正在恢复中...",
                systemImage: "arrow.down.doc",
                role: .destructive,
                requiresAccount: true
            ) {
                selectedRestoreBackupName = nil
                dialog = .restoreConfirm
            }
        }
        .appThemedRows()
    }

    private func actionRow(
        _ kind: Activity,
        title: String,
        busyTitle: String,
        systemImage: String,
        role: ButtonRole? = nil,
        requiresAccount: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let running = activity == kind
        return Button(role: role, action: action) {
            HStack {
                if running {
                    ProgressView()
                        .padding(.trailing, 4)
                } else {
                    Image(systemName: systemImage)
                }
                Text(running ? busyTitle : title)
            }
        }
        .disabled(isBusy || url.isEmpty || (requiresAccount && username.isEmpty))
    }

    // MARK: 本地备份

    private var localBackupSection: some View {
        Section(header: Text("本地备份 (兼容 Android 阅读器)")) {
            Button {
                exportBackupToFiles()
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("导出备份包到「文件」")
                }
            }

            Button {
                presentBackupPicker()
            } label: {
                HStack {
                    Image(systemName: "doc.badge.arrow.up")
                    Text("导入本地 Android 备份包 (.zip)")
                }
            }

            Text("导出：把书架、书源和应用设置打成和安卓一致的 backup*.zip，存到本机「文件」里 —— 不用配 WebDAV 也能备份。导入：支持选取 Android 版阅读器导出的 backup*.zip（可配合 bookProgress 进度目录），自动恢复书籍、书源与阅读进度。")
                .font(.caption2)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .appThemedRows()
    }

    private var backupPicker: some View {
        NavigationView {
            List {
                Section(header: Text("云端备份包 (\(remoteBackups.count) 个)")) {
                    ForEach(remoteBackups) { backup in
                        Button {
                            showBackupPickerSheet = false
                            selectedRestoreBackupName = backup.fileName
                            dialog = .restoreConfirm
                        } label: {
                            backupRow(backup)
                        }
                    }
                }
                .appThemedRows()
            }
            .appThemedList()
            .navigationTitle("选择云端备份")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showBackupPickerSheet = false }
                }
            }
        }
    }

    private func backupRow(_ backup: RemoteBackupInfo) -> some View {
        HStack {
            Image(systemName: "doc.zipper")
                .font(.title2)
                .foregroundColor(theme.palette.accent)
                .padding(.trailing, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(backup.fileName)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(theme.palette.ink)
                HStack(spacing: 12) {
                    if let date = backup.lastModified {
                        Text(formatDate(date))
                            .font(.caption2)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                    if let size = backup.size {
                        Text(formatFileSize(size))
                            .font(.caption2)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .padding(.vertical, 4)
    }

    // MARK: 动作

    /// 统一跑一次异步动作：置忙 → 执行 → 复位 → 弹提示。
    private func perform(_ kind: Activity, _ work: @escaping @MainActor () async -> Notice?) {
        activity = kind
        Task { @MainActor in
            let result = await work()
            activity = .idle
            if let result { dialog = .notice(result) }
        }
    }

    private func loadConfig() {
        let config = WebDAVService.shared.loadConfig()
        url = config.url
        username = config.username
        password = config.password
        remotePath = config.remotePath
        deviceName = config.deviceName
        lastSyncTime = config.lastSyncTime
    }

    private func saveConfig() {
        WebDAVService.shared.saveConfig(currentConfig)
    }

    private func testConnection() {
        AppLog.write("[云备份] 测试连接")
        let config = currentConfig
        perform(.testing) {
            do {
                let message = try await WebDAVService.shared.testConnection(config: config)
                AppLog.write("[云备份] 测试连接成功")
                return Notice(title: "测试连接成功", message: message)
            } catch {
                AppLog.write("[云备份] 测试连接失败 \(error.localizedDescription)")
                return Notice(title: "测试连接失败", message: error.localizedDescription)
            }
        }
    }

    private func fetchRemoteBackups() {
        let config = currentConfig
        let folder = remotePath
        perform(.fetchingBackups) {
            do {
                let backups = try await WebDAVService.shared.listRemoteBackups(config: config)
                remoteBackups = backups
                if !backups.isEmpty { showBackupPickerSheet = true }
                guard backups.isEmpty else { return nil }
                return Notice(
                    title: "未发现备份包",
                    message: "在远程目录 [\(folder)] 下未找到以 backup 开头的 .zip 备份包。"
                )
            } catch {
                return Notice(title: "获取备份失败", message: error.localizedDescription)
            }
        }
    }

    private func backupToWebDAV() {
        AppLog.write("[云备份] 备份到 WebDAV")
        let config = currentConfig
        let folder = remotePath
        let books = bookStore.bookshelf
        let sources = bookStore.sources
        perform(.backingUp) {
            do {
                let result = try await WebDAVService.shared.backup(
                    books: books,
                    sources: sources,
                    config: config,
                    settingsJSON: AppSettingsBackup.makeJSON()
                )
                AppLog.write("[云备份] WebDAV 备份完成 书=\(result.booksCount) 源=\(result.sourcesCount)")
                lastSyncTime = Date()
                return Notice(
                    title: "备份成功",
                    message: "已成功生成 Android 兼容压缩包并上传至 WebDAV 远程目录 [\(folder)]：\n• 备份文件：\(result.backupFileName)\n• 书架藏书：\(result.booksCount) 本\n• 书源配置：\(result.sourcesCount) 个"
                )
            } catch {
                AppLog.write("[云备份] WebDAV 备份失败 \(error.localizedDescription)")
                return Notice(title: "备份失败", message: error.localizedDescription)
            }
        }
    }

    private func restoreFromWebDAV(backupFileName: String? = nil, mode: BookStore.RestoreMode = .merge) {
        AppLog.write("[云备份] 从 WebDAV 恢复")
        let config = currentConfig
        perform(.restoring) {
            do {
                let (books, sources, backupName, settingsJSON) = try await WebDAVService.shared.restore(
                    config: config,
                    backupFileName: backupFileName
                )
                let result = bookStore.restoreFromWebDAV(books: books, sources: sources, mode: mode)
                var settingsSummary: String?
                if let settingsJSON, let payload = AppSettingsBackup.decode(settingsJSON) {
                    settingsSummary = AppSettingsBackup.apply(payload, mode: mode == .replace ? .replace : .merge)
                }
                AppLog.write("[云备份] WebDAV 恢复完成 新增书=\(result.booksAdded) 新增源=\(result.sourcesAdded)")
                lastSyncTime = Date()

                var detail = "已完成从 WebDAV 数据合并：\n"
                if let name = backupName { detail += "• 备份包：\(name)\n" }
                if let books {
                    detail += "• 书架同步：\(books.count) 本 (新增 \(result.booksAdded) 本)\n"
                } else {
                    detail += "• 未找到远程 bookshelf.json\n"
                }
                if let sources {
                    detail += "• 书源同步：\(sources.count) 个 (新增 \(result.sourcesAdded) 个)"
                } else {
                    detail += "• 未找到远程 bookSource.json"
                }
                if let settingsSummary {
                    detail += "\n• 应用设置（\(mode == .replace ? "替换" : "合并")）：\(settingsSummary)"
                }
                return Notice(title: "恢复成功", message: detail)
            } catch {
                AppLog.write("[云备份] WebDAV 恢复失败 \(error.localizedDescription)")
                return Notice(title: "恢复失败", message: error.localizedDescription)
            }
        }
    }

    // MARK: 本地导入

    /// `.fileImporter` 与同节点的 sheet / alert 抢 presentation，iOS 16 上选完文件回调不进来；
    /// 改用 UIKit 文档选择器，照 `SourceDocumentPicker` 的形状。
    private func presentBackupPicker() {
        #if os(iOS)
        BackupDocumentPicker.present(contentTypes: [.zip, .archive]) { urls in
            guard let url = urls.first else { return }
            prepareImport(from: url)
        }
        #else
        AppLog.write("[云备份] 当前平台未接入系统文档选择器")
        dialog = .notice(Notice(title: "暂不支持", message: "当前平台还没有接入文档选择器。"))
        #endif
    }

    /// 只解析、不落盘：拿到摘要等用户确认，解析失败就地报错。
    private func prepareImport(from url: URL) {
        AppLog.write("[云备份] 选中备份包 \(url.lastPathComponent)")
        AppLog.write("[云备份] 导入本地备份包")
        do {
            let (books, sources) = try WebDAVService.shared.restoreFromZip(fileUrl: url)
            // parseArchive 对缺失的 bookshelf.json 只回 nil 不抛错，
            // 直接进确认框会得到一份「0 本 0 源」的空摘要，等于骗用户点合并。
            guard let books else {
                let reason = "压缩包里没有可用的 bookshelf.json（缺失或解析失败），先确认这是安卓版 Legado 导出的备份包。"
                AppLog.write("[云备份] 本地备份导入失败 \(reason)")
                dialog = .notice(Notice(title: "导入失败", message: reason))
                return
            }
            let settingsData = WebDAVService.shared.extractSettingsJSON(fromZipFileUrl: url)
            dialog = .importConfirm(ImportPreview(
                fileName: url.lastPathComponent,
                books: books,
                sources: sources,
                settingsData: settingsData
            ))
        } catch {
            AppLog.write("[云备份] 本地备份导入失败 \(error.localizedDescription)")
            dialog = .notice(Notice(title: "导入失败", message: error.localizedDescription))
        }
    }

    /// 用户确认后才落盘；merge / replace 语义与 WebDAV 恢复一致。
    private func applyImport(_ preview: ImportPreview, mode: BookStore.RestoreMode) {
        AppLog.write("[云备份] 用户确认导入 mode=\(mode == .replace ? "replace" : "merge")")
        let (bookCount, sourceCount) = bookStore.restoreFromWebDAV(
            books: preview.books,
            sources: preview.sources,
            mode: mode
        )

        var settingsNote = ""
        if let data = preview.settingsData, let payload = AppSettingsBackup.decode(data) {
            let summary = AppSettingsBackup.apply(payload, mode: mode == .replace ? .replace : .merge)
            settingsNote = "\n• 应用设置（\(mode == .replace ? "替换" : "合并")）: \(summary)"
        }

        AppLog.write("[云备份] 本地备份导入完成 书架=\(bookCount) 书源=\(sourceCount)")
        let text = "成功识别并合并 Android 备份数据：\n• 书架更新/新增: \(bookCount) 本\n• 书源更新/新增: \(sourceCount) 个\(settingsNote)"
        // 确认框正在退场，此刻直接换下一个 alert 会被吞掉。
        DispatchQueue.main.async {
            self.dialog = .notice(Notice(title: "备份包导入成功", message: text))
        }
    }

    /// 不出网也备份：直接把 zip 存到「文件」。
    private func exportBackupToFiles() {
        AppLog.write("[云备份] 导出备份包到本地")
        do {
            let result = try WebDAVService.shared.createBackupZip(
                books: bookStore.bookshelf,
                sources: bookStore.sources,
                settingsJSON: AppSettingsBackup.makeJSON()
            )
            backupExportName = result.fileName
            backupExportDocument = ExportedFile(data: result.data)
            showBackupExporter = true
            AppLog.write("[云备份] 导出本地备份完成")
        } catch {
            AppLog.write("[云备份] 导出本地备份失败 \(error.localizedDescription)")
            dialog = .notice(Notice(title: "导出失败", message: error.localizedDescription))
        }
    }

    // MARK: 格式化

    private func formatFileSize(_ bytes: Int64) -> String {
        let kilobytes = Double(bytes) / 1024.0
        guard kilobytes >= 1024.0 else {
            return String(format: "%.1f KB", kilobytes)
        }
        return String(format: "%.1f MB", kilobytes / 1024.0)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

#if os(iOS)
/// 备份包专用的系统文档选择器。
///
/// 不用 `.fileImporter`：它与同节点的 `.sheet` / `.alert` / `.fileExporter` 抢 presentation，
/// iOS 16 真机上选完文件点「打开」回调不进来（表现为界面完全没反应）。
/// `asCopy: true` 直接拿到沙盒副本，不需要安全作用域访问。
enum BackupDocumentPicker {
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
            // 选择器还在退场时立刻弹 alert，SwiftUI 会丢掉这次 presentation。
            let callback = onPicked
            BackupDocumentPicker.retained = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                callback(urls)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            BackupDocumentPicker.retained = nil
        }
    }
}
#endif
