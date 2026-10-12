import SwiftUI
import UniformTypeIdentifiers
#if canImport(LegadoCore)
import LegadoCore
#endif

public struct SourceManagerView: View {
    @ObservedObject var bookStore = BookStore.shared

    @State private var showImportSheet: Bool = false
    @State private var showFileImporter: Bool = false
    @State private var selectedSourceForLogin: BookSource? = nil
    @State private var selectedSourceForEdit: BookSource? = nil
    @State private var selectedSourceForSearch: BookSource? = nil
    @State private var importText: String = ""
    @State private var importUrl: String = ""
    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false

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
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.json, .plainText],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    var totalCount = 0
                    var errorCount = 0
                    for url in urls {
                        let canAccess = url.startAccessingSecurityScopedResource()
                        defer {
                            if canAccess { url.stopAccessingSecurityScopedResource() }
                        }
                        do {
                            let data = try Data(contentsOf: url)
                            if let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) {
                                let count = try bookStore.importSources(json: str)
                                totalCount += count
                            } else {
                                errorCount += 1
                            }
                        } catch {
                            errorCount += 1
                        }
                    }
                    showImportSheet = false
                    if totalCount > 0 {
                        alertMessage = "成功导入 \(totalCount) 个书源！" + (errorCount > 0 ? " (\(errorCount)个文件解析失败)" : "")
                    } else {
                        alertMessage = errorCount > 0 ? "导入失败：未能成功解析书源文件" : "未在文件中发现有效书源"
                    }
                    showAlert = true
                case .failure(let error):
                    alertMessage = "打开文件失败: \(error.localizedDescription)"
                    showAlert = true
                }
            }
    }

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
                        showFileImporter = true
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
