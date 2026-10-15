import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif
#if canImport(LegadoCore)
import LegadoCore
#endif

public struct SourceManagerView: View {
    @ObservedObject var bookStore = BookStore.shared

    @State private var showImportSheet: Bool = false
    /// 书源导出（存到「文件」）
    @State private var showSourceExporter: Bool = false
    @State private var sourceExportDocument: ExportedFile?
    @State private var sourceExportName: String = "bookSource.json"
    @State private var selectedSourceForLogin: BookSource? = nil
    @State private var selectedSourceForEdit: BookSource? = nil
    @State private var selectedSourceForSearch: BookSource? = nil
    @State private var importText: String = ""
    @State private var importUrl: String = ""
    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false
    @State private var showBatchDeleteAlert: Bool = false

    // 源多的时候靠这几项筛
    @State private var searchText: String = ""
    @State private var selectedGroup: String? = nil
    @State private var onlyEnabled: Bool = false
    @State private var sortMode: SourceSortMode = .manual

    public init() {}

    enum SourceSortMode: String, CaseIterable, Identifiable {
        case manual = "默认顺序"
        case name = "按名称"
        case group = "按分组"
        case enabledFirst = "已启用优先"

        var id: String { rawValue }
    }

    /// 书源里所有出现过的分组名
    private var allGroups: [String] {
        var set = Set<String>()
        for source in bookStore.sources {
            for group in SourceManagerView.splitGroups(source.bookSourceGroup) {
                set.insert(group)
            }
        }
        return set.sorted()
    }

    private static func splitGroups(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw
            .components(separatedBy: CharacterSet(charactersIn: ",，、 "))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var filteredSources: [BookSource] {
        var list = bookStore.sources

        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !keyword.isEmpty {
            list = list.filter { source in
                let haystack = [
                    source.bookSourceName,
                    source.bookSourceUrl,
                    source.bookSourceGroup ?? "",
                    source.bookSourceComment ?? ""
                ].joined(separator: " ").lowercased()
                return haystack.contains(keyword)
            }
        }

        if let selectedGroup {
            list = list.filter { SourceManagerView.splitGroups($0.bookSourceGroup).contains(selectedGroup) }
        }

        if onlyEnabled {
            list = list.filter { $0.enabled ?? true }
        }

        switch sortMode {
        case .manual:
            break
        case .name:
            list.sort { $0.bookSourceName.localizedStandardCompare($1.bookSourceName) == .orderedAscending }
        case .group:
            list.sort {
                SourceManagerView.splitGroups($0.bookSourceGroup).first ?? "~"
                    < SourceManagerView.splitGroups($1.bookSourceGroup).first ?? "~"
            }
        case .enabledFirst:
            list.sort { ($0.enabled ?? true ? 0 : 1) < ($1.enabled ?? true ? 0 : 1) }
        }
        return list
    }

    public var body: some View {
        List {
            Section(header: Text("筛选")) {
                HStack {
                    Text("显示 \(filteredSources.count) / 共 \(bookStore.sources.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("可用 \(bookStore.sources.filter { $0.enabled != false }.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Menu {
                    Button("全部分组") { selectedGroup = nil }
                    ForEach(allGroups, id: \.self) { group in
                        Button(group) { selectedGroup = group }
                    }
                } label: {
                    HStack {
                        Text("分组")
                        Spacer()
                        Text(selectedGroup ?? "全部")
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Menu {
                    ForEach(SourceSortMode.allCases) { mode in
                        Button(mode.rawValue) { sortMode = mode }
                    }
                } label: {
                    HStack {
                        Text("排序")
                        Spacer()
                        Text(sortMode.rawValue)
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle("只看已启用", isOn: $onlyEnabled)

                Menu {
                    Button("启用当前筛选结果") { setEnabled(true, in: filteredSources) }
                    Button("停用当前筛选结果") { setEnabled(false, in: filteredSources) }
                    Divider()
                    Button(role: .destructive) {
                        showBatchDeleteAlert = true
                    } label: {
                        Text("删除当前筛选结果（\(filteredSources.count)）")
                    }
                } label: {
                    HStack {
                        Text("批量操作")
                        Spacer()
                        Text("作用于上面 \(filteredSources.count) 个")
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("已导入书源")) {
                    ForEach(filteredSources) { source in
                        NavigationLink(destination: SourceDetailView(source: source)) {
                            sourceRow(for: source)
                        }
                        .contextMenu {
                            Button {
                                selectedSourceForEdit = source
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }

                            Button {
                                bookStore.pinSource(sourceUrl: source.bookSourceUrl)
                            } label: {
                                Label("置顶", systemImage: "pin")
                            }

                            if source.loginUi != nil || source.loginUrl != nil {
                                Button {
                                    selectedSourceForLogin = source
                                } label: {
                                    Label(source.isLogged ? "重新登录" : "登录", systemImage: "person.badge.key")
                                }
                            }

                            Button {
                                SearchViewModel.shared.selectedSourceUrl = source.bookSourceUrl
                                selectedSourceForSearch = source
                            } label: {
                                Label("搜索", systemImage: "magnifyingglass")
                            }

                            Button {
                                refreshSource(source)
                            } label: {
                                Label("刷新", systemImage: "arrow.clockwise")
                            }

                            Button(role: .destructive) {
                                bookStore.deleteSource(sourceUrl: source.bookSourceUrl)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete(perform: deleteSources)
                }
            }
            .searchable(text: $searchText, prompt: "搜书源名 / 网址 / 分组")
#if os(iOS)
            .listStyle(.insetGrouped)
#else
            .listStyle(.inset)
#endif
            .navigationTitle("书源管理")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showImportSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { exportSources() }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showImportSheet) {
                importSourceSheet
            }
            .sheet(item: $selectedSourceForLogin) { source in
                SourceLoginSheet(source: source)
            }
            .sheet(item: $selectedSourceForEdit) { source in
                EditSourceSheet(source: source)
            }
            .sheet(item: $selectedSourceForSearch) { _ in
                NavigationView {
                    SearchBookView()
                }
            }
            .alert(alertMessage ?? "", isPresented: $showAlert) {
                Button("确定", role: .cancel) {}
            }
            .alert("删除这些书源？", isPresented: $showBatchDeleteAlert) {
                Button("取消", role: .cancel) {}
                Button("删除 \(filteredSources.count) 个", role: .destructive) {
                    // 一次删完：逐条删等于每删一条就把整张表编码写盘一遍，批量删会卡
                    let targets = Set(filteredSources.map { $0.bookSourceUrl })
                    bookStore.deleteSources(sourceUrls: targets)
                    AppLog.write("[书源] 批量删除 \(targets.count) 条")
                    alertMessage = "已删除 \(targets.count) 个书源"
                    showAlert = true
                }
            } message: {
                Text("删的是上面「筛选」的结果，共 \(filteredSources.count) 个。删掉就找不回来了，除非重新导入。")
            }
            .fileExporter(
                isPresented: $showSourceExporter,
                document: sourceExportDocument,
                contentType: .json,
                defaultFilename: sourceExportName
            ) { result in
                switch result {
                case .success:
                    alertMessage = "已导出 \(bookStore.sources.count) 个书源"
                case .failure(let error):
                    alertMessage = "导出失败: \(error.localizedDescription)"
                }
                showAlert = true
            }
    }

    /// 导出全部书源成 JSON（和导入同一套格式，导回来能直接用）
    private func exportSources() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(bookStore.sources) else {
            alertMessage = "导出失败：书源编码出错"
            showAlert = true
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        sourceExportName = "bookSource-\(formatter.string(from: Date())).json"
        sourceExportDocument = ExportedFile(data: data)
        showSourceExporter = true
    }

    /// 选完文件之后的导入流程
    private func handlePickedSourceFiles(_ urls: [URL]) {
        var totalCount = 0
        var errorCount = 0
        for url in urls {
            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                // 中文书源文件常见 GBK/ANSI 存法，只按 UTF-8/UTF-16 读会读不出来，
                // 表现就是「解析失败」。加一层 GB18030 兜底。
                let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
                if let str = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: gb18030)
                    ?? String(data: data, encoding: .unicode) {
                    let count = try bookStore.importSources(json: str)
                    totalCount += count
                } else {
                    errorCount += 1
                }
            } catch {
                errorCount += 1
            }
        }
        AppLog.write("[书源] 文件导入：\(urls.count) 个文件，解析 \(totalCount) 条，失败 \(errorCount) 个")
        showImportSheet = false
        if totalCount > 0 {
            alertMessage = "成功导入 \(totalCount) 个书源！" + (errorCount > 0 ? " (\(errorCount)个文件解析失败)" : "")
        } else {
            alertMessage = errorCount > 0 ? "导入失败：未能成功解析书源文件" : "未在文件中发现有效书源"
        }
        showAlert = true
    }

#if os(iOS)
/// 直接弹系统文档选择器（UIKit），不走 SwiftUI 的 .fileImporter。
///
/// 原因：`.fileImporter` 从 sheet 里触发时，iOS 16 上「选完文件点打开」的回调
/// 不触发（真机 iOS 16.1.1 复现，模拟器 iOS 26 正常）。UIKit 这条路没有这个问题。
/// 用 `asCopy: true`：拿到的是沙盒里能直接读的副本，不受安全作用域限制。
enum SourceDocumentPicker {
    private static var retained: Delegate?

    static func present(contentTypes: [UTType], onPicked: @escaping ([URL]) -> Void) {
        guard let top = topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = true
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
            SourceDocumentPicker.retained = nil
            onPicked(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            SourceDocumentPicker.retained = nil
        }
    }
}
#endif

    private func refreshSource(_ source: BookSource) {
        let cats = BookExploreService.shared.parseExploreCategories(source: source)
        if !cats.isEmpty {
            alertMessage = "书源「\(source.bookSourceName)」已刷新，发现分类获取正常（共 \(cats.count) 个分类）！"
        } else {
            alertMessage = "书源「\(source.bookSourceName)」连接正常！"
        }
        showAlert = true
    }

    @ViewBuilder
    private func sourceRow(for source: BookSource) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(source.bookSourceName)
                        .font(.headline)
                    if source.loginUi != nil || source.loginUrl != nil {
                        loginButton(for: source)
                    }
                }
                Text(source.bookSourceUrl)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let group = source.bookSourceGroup, !group.isEmpty {
                    Text(group)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { source.enabled ?? true },
                set: { _ in bookStore.toggleSource(sourceUrl: source.bookSourceUrl) }
            ))
            .labelsHidden()
        }
    }

    @ViewBuilder
    private func loginButton(for source: BookSource) -> some View {
        Button(action: {
            selectedSourceForLogin = source
        }) {
            HStack(spacing: 3) {
                Image(systemName: source.isLogged ? "checkmark.shield.fill" : "person.badge.key")
                Text(source.isLogged ? "已登录" : "登录")
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(source.isLogged ? Color.green.opacity(0.15) : Color.blue.opacity(0.15))
            .foregroundColor(source.isLogged ? .green : .blue)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func deleteSources(at offsets: IndexSet) {
        let list = filteredSources
        for idx in offsets where idx < list.count {
            bookStore.deleteSource(sourceUrl: list[idx].bookSourceUrl)
        }
    }

    /// 批量启用/停用：只翻转状态不一致的，避免把已经对的又翻回去。
    private func setEnabled(_ enabled: Bool, in sources: [BookSource]) {
        var changed = 0
        for source in sources where (source.enabled ?? true) != enabled {
            bookStore.toggleSource(sourceUrl: source.bookSourceUrl)
            changed += 1
        }
        alertMessage = changed == 0
            ? "这些书源本来就已经是\(enabled ? "启用" : "停用")状态。"
            : "已\(enabled ? "启用" : "停用") \(changed) 个书源。"
        showAlert = true
    }

    private var importSourceSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("本地文件导入")) {
                    Button {
#if os(iOS)
                        // 直接用 UIKit 的文档选择器：SwiftUI 的 .fileImporter 在
                        // 「从 sheet 里触发」这套组合下，iOS 16 上选完文件点「打开」
                        // 回调不触发（真机 iOS 16.1.1 复现，模拟器上正常）。
                        SourceDocumentPicker.present(contentTypes: [.json, .plainText]) { urls in
                            handlePickedSourceFiles(urls)
                        }
#else
                        // 这个包在 macOS 上只用于编译校验（swift test），入口只有 iOS
                        alertMessage = "当前平台不支持文件选择"
                        showAlert = true
#endif
                    } label: {
                        Label("从本地文件导入 (.json)", systemImage: "doc.badge.plus")
                    }
                }

                Section(header: Text("网络导入 (JSON URL)")) {
                    TextField("输入书源网址 (https://...)", text: $importUrl)
                        #if os(iOS)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        #endif
                    Button("从网络获取并导入") {
                        importFromUrl()
                    }
                    .disabled(importUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section(header: Text("剪贴板 / 本地文本导入")) {
                    TextEditor(text: $importText)
                        .frame(height: 120)
                    Button("导入 JSON 文本") {
                        importFromText()
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("导入书源")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showImportSheet = false }
                }
            }
        }
    }

    private func importFromText() {
        do {
            let count = try bookStore.importSources(json: importText)
            AppLog.write("[书源] 文本导入：解析 \(count) 条")
            showImportSheet = false
            importText = ""
            alertMessage = "成功导入 \(count) 个书源！"
            showAlert = true
        } catch {
            alertMessage = "导入失败: JSON 格式错误"
            showAlert = true
        }
    }

    private func importFromUrl() {
        guard let url = URL(string: importUrl.trimmingCharacters(in: .whitespaces)) else {
            alertMessage = "无效的 URL"
            showAlert = true
            return
        }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let jsonStr = String(data: data, encoding: .utf8) else {
                    await MainActor.run {
                        alertMessage = "无法读取网络数据"
                        showAlert = true
                    }
                    return
                }

                await MainActor.run {
                    do {
                        let count = try bookStore.importSources(json: jsonStr)
                        AppLog.write("[书源] 网络导入：host=\(url.host ?? "-") 解析 \(count) 条")
                        showImportSheet = false
                        importUrl = ""
                        alertMessage = "成功从网络导入 \(count) 个书源！"
                        showAlert = true
                    } catch {
                        alertMessage = "书源格式解析失败: \(error.localizedDescription)"
                        showAlert = true
                    }
                }
            } catch {
                await MainActor.run {
                    alertMessage = "网络请求失败: \(error.localizedDescription)"
                    showAlert = true
                }
            }
        }
    }
}

public struct SourceLoginSheet: View {
    let source: BookSource
    @Environment(\.dismiss) private var dismiss
    @State private var loginMode: String
    @State private var fields: [LoginField] = []
    @State private var fieldValues: [String: String] = [:]
    @State private var isLoggingIn: Bool = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil

    struct LoginField: Identifiable {
        var id: String { name }
        let name: String
        let type: String
    }

    private var isWebLoginDefault: Bool {
        guard let loginUrl = source.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !loginUrl.isEmpty else {
            return false
        }
        return (loginUrl.hasPrefix("http://") || loginUrl.hasPrefix("https://")) &&
               !loginUrl.contains("<js>") &&
               !loginUrl.contains("@js:")
    }

    public init(source: BookSource) {
        self.source = source
        let isWeb = (source.loginUrl?.hasPrefix("http://") == true || source.loginUrl?.hasPrefix("https://") == true) &&
                    source.loginUrl?.contains("<js>") == false &&
                    source.loginUrl?.contains("@js:") == false
        self._loginMode = State(initialValue: isWeb ? "web" : "form")
    }

    public var body: some View {
        if isWebLoginDefault || loginMode == "web" {
            SourceWebLoginView(source: source)
        } else {
            formLoginView
        }
    }

    private var formLoginView: some View {
        NavigationView {
            Form {
                Section(header: Text("书源信息")) {
                    Text(source.bookSourceName)
                        .font(.headline)
                    Text(source.bookSourceUrl)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if source.isLogged {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("当前状态：已登录")
                                .foregroundColor(.green)
                                .font(.subheadline)
                        }
                    }
                }

                Section(header: Text("登录模式切换")) {
                    Picker("登录模式", selection: $loginMode) {
                        Text("表单脚本登录").tag("form")
                        Text("网页/Cookie 登录").tag("web")
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("账号登录表单")) {
                    if fields.isEmpty {
                        Text("该书源无需配置字段，直接点击下方按钮执行登录脚本")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(fields) { field in
                            if field.type == "password" {
                                SecureField(field.name, text: Binding(
                                    get: { fieldValues[field.name] ?? "" },
                                    set: { fieldValues[field.name] = $0 }
                                ))
                            } else {
                                TextField(field.name, text: Binding(
                                    get: { fieldValues[field.name] ?? "" },
                                    set: { fieldValues[field.name] = $0 }
                                ))
                                #if os(iOS)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                #endif
                            }
                        }
                    }
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                            .font(.subheadline)
                    }
                }

                if let succ = successMessage {
                    Section {
                        Text(succ)
                            .foregroundColor(.green)
                            .font(.subheadline)
                    }
                }

                Section {
                    Button(action: performLogin) {
                        if isLoggingIn {
                            HStack {
                                Spacer()
                                ProgressView()
                                Text("正在执行登录...").padding(.leading, 8)
                                Spacer()
                            }
                        } else {
                            Text(source.isLogged ? "重新登录" : "立即登录")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isLoggingIn)

                    if source.isLogged {
                        Button(role: .destructive, action: {
                            BookStore.shared.logoutSource(sourceUrl: source.bookSourceUrl)
                            dismiss()
                        }) {
                            Text("退出登录")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle("书源登录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear(perform: parseLoginUi)
        }
    }

    private func parseLoginUi() {
        if let info = source.loginInfo, let data = info.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            fieldValues = dict
        }

        guard let uiJson = source.loginUi, let data = uiJson.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            fields = [LoginField(name: "账号", type: "text"), LoginField(name: "密码", type: "password")]
            return
        }

        var parsed: [LoginField] = []
        for item in arr {
            let name = (item["name"] as? String) ?? ""
            let type = (item["type"] as? String) ?? "text"
            if !name.isEmpty && type != "button" {
                parsed.append(LoginField(name: name, type: type))
            }
        }
        self.fields = parsed
    }

    private func performLogin() {
        isLoggingIn = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                _ = try await BookStore.shared.performLogin(source: source, credentials: fieldValues)
                await MainActor.run {
                    isLoggingIn = false
                    successMessage = "登录成功！"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isLoggingIn = false
                    errorMessage = "登录失败: \(error.localizedDescription)"
                }
            }
        }
    }
}
