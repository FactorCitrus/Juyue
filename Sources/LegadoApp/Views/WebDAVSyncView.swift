import SwiftUI
import UniformTypeIdentifiers
#if canImport(LegadoCore)
import LegadoCore
#endif

public struct WebDAVSyncView: View {
    @ObservedObject var bookStore = BookStore.shared
    @Environment(\.appTheme) private var theme

    @State private var url: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var remotePath: String = "legado"
    @State private var deviceName: String = ""
    @State private var lastSyncTime: Date? = nil

    @State private var isTesting: Bool = false
    @State private var isBackingUp: Bool = false
    @State private var isRestoring: Bool = false
    @State private var isFetchingBackups: Bool = false
    @State private var remoteBackups: [RemoteBackupInfo] = []
    @State private var showBackupPickerSheet: Bool = false
    @State private var showFileImporter: Bool = false
    /// 备份包存到「文件」（不用连 WebDAV 也能备份）
    @State private var showBackupExporter: Bool = false
    @State private var backupExportDocument: ExportedFile?
    @State private var backupExportName: String = "backup.zip"

    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    @State private var showAlert: Bool = false
    @State private var showRestoreConfirm: Bool = false
    @State private var selectedRestoreBackupName: String? = nil

    public init() {}

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

    public var body: some View {
        Form {
            Section {
                TerminalPageHeader(code: "DATA / SYNC", title: "WebDAV 云同步", detail: "备份 / 恢复 / 远端版本")
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }
            .appThemedRows()
            serverConfigSection
            statusSection
            actionsSection
            localBackupSection
        }
        .appThemedList()
        .navigationTitle("WebDAV 云同步")
        .onAppear {
            loadConfig()
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .alert("从 WebDAV 恢复", isPresented: $showRestoreConfirm) {
            Button("取消", role: .cancel) {}
            Button("替换恢复（完全采用备份）", role: .destructive) {
                saveConfig()
                restoreFromWebDAV(backupFileName: selectedRestoreBackupName, mode: .replace)
            }
            Button("合并恢复（保留本地进度 / 分组 / 封面）") {
                saveConfig()
                restoreFromWebDAV(backupFileName: selectedRestoreBackupName, mode: .merge)
            }
        } message: {
            if let name = selectedRestoreBackupName {
                Text("从 WebDAV 下载 [\(name)]，和本地数据合并。继续吗？")
            } else {
                Text("从 WebDAV 下载最新的备份，和本地数据合并。继续吗？")
            }
        }
        .sheet(isPresented: $showBackupPickerSheet) {
            backupPickerView
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.zip, .archive],
            allowsMultipleSelection: false
        ) { result in
            handleLocalZipImport(result: result)
        }
        .fileExporter(
            isPresented: $showBackupExporter,
            document: backupExportDocument,
            contentType: .zip,
            defaultFilename: backupExportName
        ) { result in
            switch result {
            case .success:
                alertTitle = "备份包已导出"
                alertMessage = "已存到「文件」：\(backupExportName)"
            case .failure(let error):
                alertTitle = "导出失败"
                alertMessage = error.localizedDescription
            }
            showAlert = true
        }
    }

    @ViewBuilder
    private var serverConfigSection: some View {
        Section {
            HStack {
                Text("服务器地址")
                    .frame(width: 85, alignment: .leading)
                TextField("https://dav.jianguoyun.com/dav/", text: $url)
                    #if os(iOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
            }

            HStack {
                Text("账号")
                    .frame(width: 85, alignment: .leading)
                TextField("坚果云账号/邮箱", text: $username)
                    #if os(iOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
            }

            HStack {
                Text("密码")
                    .frame(width: 85, alignment: .leading)
                SecureField("应用密码 / 访问凭证", text: $password)
            }

            HStack {
                Text("远程目录")
                    .frame(width: 85, alignment: .leading)
                TextField("legado", text: $remotePath)
                    #if os(iOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
            }

            HStack {
                Text("设备名称")
                    .frame(width: 85, alignment: .leading)
                TextField(WebDAVConfig.defaultDeviceName, text: $deviceName)
                    #if os(iOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
            }

            // Quick presets
            VStack(alignment: .leading, spacing: 8) {
                Text("快捷填入服务预设")
                    .font(.caption)
                    .foregroundColor(theme.palette.secondaryInk)
                HStack(spacing: 8) {
                    Button("坚果云") {
                        url = "https://dav.jianguoyun.com/dav/"
                        if remotePath.isEmpty { remotePath = "legado" }
                        saveConfig()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)

                    Button("InfiniCLOUD") {
                        url = "https://teracloud.jp/dav/"
                        if remotePath.isEmpty { remotePath = "legado" }
                        saveConfig()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)

                    Button("Nextcloud") {
                        url = "https://example.com/remote.php/dav/files/user/"
                        if remotePath.isEmpty { remotePath = "legado" }
                        saveConfig()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
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

    @ViewBuilder
    private var statusSection: some View {
        Section(header: Text("同步状态")) {
            HStack {
                Text("上次同步时间")
                Spacer()
                if let date = lastSyncTime {
                    Text(formatDate(date))
                        .foregroundColor(theme.palette.secondaryInk)
                } else {
                    Text("暂未同步")
                        .foregroundColor(theme.palette.secondaryInk)
                }
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

    @ViewBuilder
    private var actionsSection: some View {
        Section(header: Text("同步操作")) {
            Button {
                saveConfig()
                testConnection()
            } label: {
                HStack {
                    if isTesting {
                        ProgressView()
                            .padding(.trailing, 4)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    Text(isTesting ? "正在测试连接..." : "测试连接")
                }
            }
            .disabled(isTesting || isBackingUp || isRestoring || isFetchingBackups || url.isEmpty)

            Button {
                saveConfig()
                backupToWebDAV()
            } label: {
                HStack {
                    if isBackingUp {
                        ProgressView()
                            .padding(.trailing, 4)
                    } else {
                        Image(systemName: "arrow.up.doc")
                    }
                    Text(isBackingUp ? "正在备份中..." : "立即备份至 WebDAV")
                }
            }
            .disabled(isTesting || isBackingUp || isRestoring || isFetchingBackups || url.isEmpty || username.isEmpty)

            Button {
                saveConfig()
                fetchRemoteBackups()
            } label: {
                HStack {
                    if isFetchingBackups {
                        ProgressView()
                            .padding(.trailing, 4)
                    } else {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    Text(isFetchingBackups ? "正在获取云端备份..." : "选择云端历史备份恢复...")
                }
            }
            .disabled(isTesting || isBackingUp || isRestoring || isFetchingBackups || url.isEmpty || username.isEmpty)

            Button(role: .destructive) {
                selectedRestoreBackupName = nil
                showRestoreConfirm = true
            } label: {
                HStack {
                    if isRestoring {
                        ProgressView()
                            .padding(.trailing, 4)
                    } else {
                        Image(systemName: "arrow.down.doc")
                    }
                    Text(isRestoring ? "正在恢复中..." : "从 WebDAV 恢复最新数据")
                }
            }
            .disabled(isTesting || isBackingUp || isRestoring || isFetchingBackups || url.isEmpty || username.isEmpty)
        }
        .appThemedRows()
    }

    @ViewBuilder
    private var localBackupSection: some View {
        Section(header: Text("本地备份 (兼容 Android Legado)")) {
            Button {
                exportBackupToFiles()
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("导出备份包到「文件」")
                }
            }

            Button {
                showFileImporter = true
            } label: {
                HStack {
                    Image(systemName: "doc.badge.arrow.up")
                    Text("导入本地 Android 备份包 (.zip)")
                }
            }

            Text("导出：把书架、书源和应用设置打成和安卓一致的 backup*.zip，存到本机「文件」里 —— 不用配 WebDAV 也能备份。导入：支持选取 Android 版 Legado 导出的 backup*.zip（可配合 bookProgress 进度目录），自动恢复书籍、书源与阅读进度。")
                .font(.caption2)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .appThemedRows()
    }

    /// 不出网也备份：直接把 zip 存到「文件」
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
            alertTitle = "导出失败"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    @ViewBuilder
    private var backupPickerView: some View {
        NavigationView {
            List {
                Section(header: Text("云端备份包 (\(remoteBackups.count) 个)")) {
                    ForEach(remoteBackups) { backup in
                        Button {
                            showBackupPickerSheet = false
                            selectedRestoreBackupName = backup.fileName
                            showRestoreConfirm = true
                        } label: {
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
                    Button("取消") {
                        showBackupPickerSheet = false
                    }
                }
            }
        }
    }

    private func handleLocalZipImport(result: Result<[URL], Error>) {
        AppLog.write("[云备份] 导入本地备份包")
        do {
            guard let selectedUrl = try result.get().first else { return }
            let canAccess = selectedUrl.startAccessingSecurityScopedResource()
            defer {
                if canAccess { selectedUrl.stopAccessingSecurityScopedResource() }
            }

            let (books, sources) = try WebDAVService.shared.restoreFromZip(fileUrl: selectedUrl)
            let (bCount, sCount) = bookStore.restoreFromWebDAV(books: books, sources: sources)

            var settingsNote = ""
            if let settingsData = WebDAVService.shared.extractSettingsJSON(fromZipFileUrl: selectedUrl),
               let payload = AppSettingsBackup.decode(settingsData) {
                let summary = AppSettingsBackup.apply(payload, mode: .merge)
                settingsNote = "\n• 应用设置（合并）: \(summary)"
            }

            alertTitle = "备份包导入成功"
            alertMessage = "成功识别并合并 Android 备份数据：\n• 书架更新/新增: \(bCount) 本\n• 书源更新/新增: \(sCount) 个\(settingsNote)"
            showAlert = true
            AppLog.write("[云备份] 本地备份导入完成 书架=\(bCount) 书源=\(sCount)")
        } catch {
            AppLog.write("[云备份] 本地备份导入失败 \(error.localizedDescription)")
            alertTitle = "导入失败"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func loadConfig() {
        let config = WebDAVService.shared.loadConfig()
        self.url = config.url
        self.username = config.username
        self.password = config.password
        self.remotePath = config.remotePath
        self.deviceName = config.deviceName
        self.lastSyncTime = config.lastSyncTime
    }

    private func saveConfig() {
        WebDAVService.shared.saveConfig(currentConfig)
    }

    private func testConnection() {
        AppLog.write("[云备份] 测试连接")
        isTesting = true
        Task {
            do {
                let msg = try await WebDAVService.shared.testConnection(config: currentConfig)
                await MainActor.run {
                    isTesting = false
                    AppLog.write("[云备份] 测试连接成功")
                    alertTitle = "测试连接成功"
                    alertMessage = msg
                    showAlert = true
                }
            } catch {
                AppLog.write("[云备份] 测试连接失败 \(error.localizedDescription)")
                await MainActor.run {
                    isTesting = false
                    alertTitle = "测试连接失败"
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func fetchRemoteBackups() {
        isFetchingBackups = true
        Task {
            do {
                let backups = try await WebDAVService.shared.listRemoteBackups(config: currentConfig)
                await MainActor.run {
                    isFetchingBackups = false
                    self.remoteBackups = backups
                    if backups.isEmpty {
                        alertTitle = "未发现备份包"
                        alertMessage = "在远程目录 [\(remotePath)] 下未找到以 backup 开头的 .zip 备份包。"
                        showAlert = true
                    } else {
                        showBackupPickerSheet = true
                    }
                }
            } catch {
                await MainActor.run {
                    isFetchingBackups = false
                    alertTitle = "获取备份失败"
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func backupToWebDAV() {
        AppLog.write("[云备份] 备份到 WebDAV")
        isBackingUp = true
        Task {
            do {
                let result = try await WebDAVService.shared.backup(
                    books: bookStore.bookshelf,
                    sources: bookStore.sources,
                    config: currentConfig,
                    settingsJSON: AppSettingsBackup.makeJSON()
                )
                await MainActor.run {
                    isBackingUp = false
                    lastSyncTime = Date()
                    AppLog.write("[云备份] WebDAV 备份完成 书=\(result.booksCount) 源=\(result.sourcesCount)")
                    alertTitle = "备份成功"
                    alertMessage = "已成功生成 Android 兼容压缩包并上传至 WebDAV 远程目录 [\(remotePath)]：\n• 备份文件：\(result.backupFileName)\n• 书架藏书：\(result.booksCount) 本\n• 书源配置：\(result.sourcesCount) 个"
                    showAlert = true
                }
            } catch {
                AppLog.write("[云备份] WebDAV 备份失败 \(error.localizedDescription)")
                await MainActor.run {
                    isBackingUp = false
                    alertTitle = "备份失败"
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func restoreFromWebDAV(backupFileName: String? = nil, mode: BookStore.RestoreMode = .merge) {
        AppLog.write("[云备份] 从 WebDAV 恢复")
        isRestoring = true
        Task {
            do {
                let (books, sources, backupName, settingsJSON) = try await WebDAVService.shared.restore(
                    config: currentConfig,
                    backupFileName: backupFileName
                )
                let result = bookStore.restoreFromWebDAV(books: books, sources: sources, mode: mode)
                var settingsSummary: String?
                if let settingsJSON, let payload = AppSettingsBackup.decode(settingsJSON) {
                    settingsSummary = AppSettingsBackup.apply(payload, mode: mode == .replace ? .replace : .merge)
                }
                await MainActor.run {
                    isRestoring = false
                    lastSyncTime = Date()
                    AppLog.write("[云备份] WebDAV 恢复完成 新增书=\(result.booksAdded) 新增源=\(result.sourcesAdded)")
                    alertTitle = "恢复成功"
                    var detail = "已完成从 WebDAV 数据合并：\n"
                    if let name = backupName {
                        detail += "• 备份包：\(name)\n"
                    }
                    if let b = books {
                        detail += "• 书架同步：\(b.count) 本 (新增 \(result.booksAdded) 本)\n"
                    } else {
                        detail += "• 未找到远程 bookshelf.json\n"
                    }
                    if let s = sources {
                        detail += "• 书源同步：\(s.count) 个 (新增 \(result.sourcesAdded) 个)"
                    } else {
                        detail += "• 未找到远程 bookSource.json"
                    }
                    if let settingsSummary {
                        detail += "\n• 应用设置（\(mode == .replace ? "替换" : "合并")）：\(settingsSummary)"
                    }
                    alertMessage = detail
                    showAlert = true
                }
            } catch {
                AppLog.write("[云备份] WebDAV 恢复失败 \(error.localizedDescription)")
                await MainActor.run {
                    isRestoring = false
                    alertTitle = "恢复失败"
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024.0
        if kb < 1024.0 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024.0
        return String(format: "%.1f MB", mb)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
