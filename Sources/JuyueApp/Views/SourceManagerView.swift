import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(JuyueCore)
import JuyueCore
#endif

// MARK: - 复用外壳

private struct SheetNavigation<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        NavigationView { content() }
    }
}

private struct CancelToolbar: ToolbarContent {
    private let title: String
    private let action: () -> Void

    init(_ title: String = "取消", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(title, action: action)
        }
    }
}

private extension View {
    func sheetChrome(_ title: String) -> some View {
        navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    func plainTextInput() -> some View {
        #if os(iOS)
        autocapitalization(.none).disableAutocorrection(true)
        #else
        self
        #endif
    }
}

// MARK: - 排序

enum SourceOrder: String, CaseIterable, Identifiable {
    case manual = "默认顺序"
    case name = "按名称"
    case group = "按分组"
    case enabledFirst = "已启用优先"

    var id: String { rawValue }
}

// MARK: - 列表筛选

enum SourceCatalog {
    static func splitGroups(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw
            .components(separatedBy: CharacterSet(charactersIn: ",，、 "))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func allGroups(in sources: [BookSource]) -> [String] {
        var names = Set<String>()
        for source in sources {
            for group in splitGroups(source.bookSourceGroup) {
                names.insert(group)
            }
        }
        return names.sorted()
    }

    static func visible(
        _ sources: [BookSource],
        query: String,
        group: String?,
        enabledOnly: Bool,
        order: SourceOrder,
        pinned: (BookSource) -> Bool
    ) -> [BookSource] {
        var result = sources

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            result = result.filter { source in
                let haystack = [
                    source.bookSourceName,
                    source.bookSourceUrl,
                    source.bookSourceGroup ?? "",
                    source.bookSourceComment ?? ""
                ].joined(separator: " ").lowercased()
                return haystack.contains(needle)
            }
        }

        if let group {
            result = result.filter { splitGroups($0.bookSourceGroup).contains(group) }
        }

        if enabledOnly {
            result = result.filter { $0.enabled ?? true }
        }

        switch order {
        case .manual:
            break
        case .name:
            result.sort { $0.bookSourceName.localizedStandardCompare($1.bookSourceName) == .orderedAscending }
        case .group:
            result.sort { lhs, rhs in
                let left = splitGroups(lhs.bookSourceGroup).first ?? "~"
                let right = splitGroups(rhs.bookSourceGroup).first ?? "~"
                return left < right
            }
        case .enabledFirst:
            result.sort { lhs, rhs in
                let leftRank = (lhs.enabled ?? true) ? 0 : 1
                let rightRank = (rhs.enabled ?? true) ? 0 : 1
                return leftRank < rightRank
            }
        }

        return result.enumerated()
            .sorted { lhs, rhs in
                let leftPinned = pinned(lhs.element)
                let rightPinned = pinned(rhs.element)
                if leftPinned != rightPinned { return leftPinned }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

// MARK: - 页面状态

final class SourceManagerState: ObservableObject {
    @Published var importSheetVisible = false
    @Published var importConsent = !BookSourceDisclaimer.requiresConsent
    @Published var exporterVisible = false
    @Published var exportDocument: ExportedFile?
    @Published var exportName = "bookSource.json"
    @Published var exportCount = 0
    @Published var pickerVisible = false
    @Published var pickedURLs: Set<String> = []
    @Published var pendingEntries: [BookStore.SourceImportEntry] = []
    @Published var previewVisible = false
    @Published var sharePayload: SourceShareItem?
    @Published var loginTarget: BookSource?
    @Published var editTarget: BookSource?
    @Published var searchTarget: BookSource?
    @Published var textDraft = ""
    @Published var urlDraft = ""
    @Published var notice: String?
    @Published var confirmBulkDelete = false
    @Published var query = ""
    @Published var group: String?
    @Published var enabledOnly = false
    @Published var order: SourceOrder = .manual
    @Published var groupTarget: BookSource?
    @Published var groupDraft = ""
    @Published var groupManagerVisible = false
}

// MARK: - 书源管理

public struct SourceManagerView: View {
    @ObservedObject private var library = BookStore.shared
    @StateObject private var state = SourceManagerState()

    public init() {
        // 页面状态与筛选逻辑都放在 SourceManagerState / SourceCatalog 里。
    }

    private var visible: [BookSource] {
        SourceCatalog.visible(
            library.sources,
            query: state.query,
            group: state.group,
            enabledOnly: state.enabledOnly,
            order: state.order,
            pinned: { library.isPinned($0) }
        )
    }

    private var groups: [String] {
        SourceCatalog.allGroups(in: library.sources)
    }

    public var body: some View { managerBody }

    private var managerBody: some View {
        List {
            Section {
                TerminalPageHeader(
                    code: "SOURCE / LIBRARY",
                    title: "书源管理",
                    detail: AppEdition.allowsSourceExport
                        ? "筛选 / 排序 / 校验 / 导入导出"
                        : "筛选 / 排序 / 校验 / 导入"
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
            }
            .appThemedRows()

            SourceToolsSection()

            SourceFilterSection(
                state: state,
                visible: visible,
                total: library.sources,
                groups: groups,
                onEnableAll: { setEnabled(true, in: visible) },
                onDisableAll: { setEnabled(false, in: visible) }
            )

            Section("已导入书源") {
                ForEach(visible) { source in
                    NavigationLink(destination: SourceDetailView(source: source)) {
                        SourceRow(source: source, library: library) {
                            state.loginTarget = source
                        }
                    }
                    .contextMenu { rowMenu(for: source) }
                }
                .onDelete(perform: removeRows)
            }
            .appThemedRows()
        }
        .searchable(text: $state.query, prompt: "搜书源名 / 网址 / 分组")
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .appThemedList()
        .navigationTitle("书源管理")
        .toolbar { toolbarContent }
        .sheet(isPresented: $state.importSheetVisible, onDismiss: resetConsent) {
            SourceImportSheet(
                state: state,
                onPickFiles: handlePickedFiles,
                onImportURL: importFromURL,
                onImportText: importFromText,
                onClose: { state.importSheetVisible = false }
            )
        }
        .sheet(item: $state.groupTarget) { target in
            SourceGroupEditorSheet(
                target: target,
                groups: groups,
                draft: $state.groupDraft,
                onCancel: { state.groupTarget = nil },
                onSave: {
                    library.setSourceGroup(sourceUrl: target.bookSourceUrl, group: state.groupDraft)
                    state.groupTarget = nil
                },
                onToggle: toggleGroup
            )
        }
        .sheet(item: $state.loginTarget) { SourceLoginSheet(source: $0) }
        .sheet(item: $state.editTarget) { EditSourceSheet(source: $0) }
        .sheet(item: $state.searchTarget) { _ in
            SheetNavigation { SearchBookView() }
        }
        .sheet(isPresented: $state.groupManagerVisible) { SourceGroupManagerView() }
        .sheet(isPresented: $state.previewVisible) {
            SourceImportPreviewView(entries: state.pendingEntries) { overwrite in
                let outcome = library.applyImport(entries: state.pendingEntries, overwriteConflicts: overwrite)
                state.pendingEntries = []
                state.notice = "导入完成：新增 \(outcome.added)，更新 \(outcome.updated)，同名保留 \(outcome.conflictsAdded)"
            }
        }
        .sheet(isPresented: $state.pickerVisible) {
            SourceExportPickerSheet(
                sources: visible,
                selection: $state.pickedURLs,
                onCancel: { state.pickerVisible = false },
                onExport: { chosen in
                    state.pickerVisible = false
                    exportSources(chosen, namePrefix: "selected-bookSource")
                }
            )
        }
        .sheet(item: $state.sharePayload) { payload in
            #if os(iOS)
            SourceShareSheet(items: [payload.url])
            #else
            Text("当前平台请使用文件导出").padding()
            #endif
        }
        .alert(state.notice ?? "", isPresented: noticeBinding) {
            Button("确定", role: .cancel) {}
        }
        .alert("删除这些书源？", isPresented: $state.confirmBulkDelete) {
            Button("取消", role: .cancel) {}
            Button("删除 \(visible.count) 个", role: .destructive) { deleteVisible() }
        } message: {
            Text("删的是上面「筛选」的结果，共 \(visible.count) 个。删掉就找不回来了，除非重新导入。")
        }
        .fileExporter(
            isPresented: $state.exporterVisible,
            document: state.exportDocument,
            contentType: .json,
            defaultFilename: state.exportName
        ) { result in
            switch result {
            case .success:
                state.notice = "已导出 \(state.exportCount) 个书源"
            case .failure(let error):
                state.notice = "导出失败: \(error.localizedDescription)"
            }
        }
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { state.notice != nil },
            set: { if !$0 { state.notice = nil } }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: openImportFlow) {
                Image(systemName: "plus")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if AppEdition.allowsSourceExport {
                Menu {
                    Button("导出全部（\(library.sources.count)）") {
                        exportSources(library.sources)
                    }
                    Button("导出当前筛选（\(visible.count)）") {
                        exportSources(visible)
                    }
                    Button("选择书源导出…") {
                        state.pickedURLs = []
                        state.pickerVisible = true
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(for source: BookSource) -> some View {
        Button { state.editTarget = source } label: {
            Label("编辑", systemImage: "pencil")
        }
        Button {
            library.setPinned(!library.isPinned(source), sourceUrl: source.bookSourceUrl)
        } label: {
            Label(library.isPinned(source) ? "取消置顶" : "置顶",
                  systemImage: library.isPinned(source) ? "pin.slash" : "pin")
        }
        Button {
            state.groupDraft = source.bookSourceGroup ?? ""
            state.groupTarget = source
        } label: {
            Label("编辑分类", systemImage: "folder")
        }
        if source.loginUi != nil || source.loginUrl != nil {
            Button { state.loginTarget = source } label: {
                Label(source.isLogged ? "重新登录" : "登录", systemImage: "person.badge.key")
            }
        }
        Button {
            SearchViewModel.shared.selectedSourceUrls = [source.bookSourceUrl]
            state.searchTarget = source
        } label: {
            Label("搜索", systemImage: "magnifyingglass")
        }
        Button { probeSource(source) } label: {
            Label("刷新", systemImage: "arrow.clockwise")
        }
        if AppEdition.allowsSourceExport {
            Button { copySourceJSON(source) } label: {
                Label("复制 JSON", systemImage: "doc.on.doc")
            }
            Button { shareSource(source) } label: {
                Label("分享书源", systemImage: "square.and.arrow.up")
            }
            Button { exportSources([source], namePrefix: "bookSource-single") } label: {
                Label("导出这个书源", systemImage: "tray.and.arrow.down")
            }
        }
        Button { clearVariable(source) } label: {
            Label("清空变量", systemImage: "eraser")
        }
        if source.loginUi != nil || source.loginUrl != nil {
            Button(role: .destructive) { resetLoginState(source) } label: {
                Label("重置登录态", systemImage: "person.crop.circle.badge.xmark")
            }
        }
        Button(role: .destructive) {
            library.deleteSource(sourceUrl: source.bookSourceUrl)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: 导入

    private func openImportFlow() {
        state.importConsent = !BookSourceDisclaimer.requiresConsent
        state.importSheetVisible = true
    }

    private func resetConsent() {
        if state.importConsent {
            BookSourceDisclaimer.revoke()
        }
        state.importConsent = !BookSourceDisclaimer.requiresConsent
    }

    @discardableResult
    private func prepareImport(_ json: String) -> [BookStore.SourceImportEntry]? {
        do {
            let entries = try library.planImportSources(json: json)
            guard !entries.isEmpty else {
                state.notice = "未发现有效书源"
                return nil
            }
            state.pendingEntries = entries
            state.importSheetVisible = false
            DispatchQueue.main.async { state.previewVisible = true }
            return entries
        } catch {
            state.notice = "导入失败：JSON 格式错误"
            return nil
        }
    }

    private func importFromText() {
        if prepareImport(state.textDraft) != nil {
            state.textDraft = ""
        }
    }

    private func importFromURL() {
        let raw = state.urlDraft.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: raw) else {
            state.notice = "无效的 URL"
            return
        }

        Task { @MainActor in
            do {
                let (payload, _) = try await URLSession.shared.data(from: url)
                guard let json = String(data: payload, encoding: .utf8) else {
                    state.notice = "无法读取网络数据"
                    return
                }
                AppLog.write("[书源] 网络导入预览：host=\(url.host ?? "-")")
                if prepareImport(json) != nil {
                    state.urlDraft = ""
                }
            } catch let failure {
                state.notice = "网络请求失败: \(failure.localizedDescription)"
            }
        }
    }

    private func handlePickedFiles(_ urls: [URL]) {
        var collected: [BookStore.SourceImportEntry] = []
        var fingerprints = Set<String>()
        var failures = 0

        for url in urls {
            let secured = url.startAccessingSecurityScopedResource()
            defer {
                if secured { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
                guard let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: gb18030)
                        ?? String(data: data, encoding: .unicode) else {
                    failures += 1
                    continue
                }
                let plan = try library.planImportSources(json: text)
                for entry in plan where fingerprints.insert(entry.incoming.bookSourceUrl).inserted {
                    collected.append(entry)
                }
            } catch {
                failures += 1
            }
        }

        AppLog.write("[书源] 文件导入预览：\(urls.count) 个文件，解析 \(collected.count) 条，失败 \(failures) 个")
        guard !collected.isEmpty else {
            state.notice = failures > 0 ? "导入失败：未能成功解析书源文件" : "未在文件中发现有效书源"
            return
        }
        state.pendingEntries = collected
        state.importSheetVisible = false
        DispatchQueue.main.async { state.previewVisible = true }
    }

    // MARK: 导出与单条操作

    private func exportSources(_ sources: [BookSource], namePrefix: String = "bookSource") {
        guard !sources.isEmpty else {
            state.notice = "没有可导出的书源"
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(sources) else {
            state.notice = "导出失败：书源编码出错"
            return
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd"
        state.exportCount = sources.count
        state.exportName = "\(namePrefix)-\(stamp.string(from: Date())).json"
        state.exportDocument = ExportedFile(data: data)
        state.exporterVisible = true
    }

    private func copySourceJSON(_ source: BookSource) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode([source]),
              let text = String(data: data, encoding: .utf8) else { return }
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        state.notice = "已复制「\(source.bookSourceName)」的 JSON"
    }

    private func shareSource(_ source: BookSource) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode([source]) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SourceShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = source.bookSourceName.replacingOccurrences(of: "/", with: "_")
        let file = directory.appendingPathComponent("\(safeName)-bookSource.json")
        do {
            try data.write(to: file, options: .atomic)
            state.sharePayload = SourceShareItem(url: file)
        } catch {
            state.notice = "生成分享文件失败：\(error.localizedDescription)"
        }
    }

    private func resetLoginState(_ source: BookSource) {
        library.logoutSource(sourceUrl: source.bookSourceUrl)
        state.notice = "已清除「\(source.bookSourceName)」的登录 Header 与 Cookie"
    }

    private func clearVariable(_ source: BookSource) {
        var changed = source
        changed.variable = nil
        library.updateSource(changed)
        state.notice = "已清空「\(source.bookSourceName)」的书源变量"
    }

    private func probeSource(_ source: BookSource) {
        let categories = BookExploreService.shared.parseExploreCategories(source: source)
        state.notice = categories.isEmpty
            ? "书源「\(source.bookSourceName)」连接正常！"
            : "书源「\(source.bookSourceName)」已刷新，发现分类获取正常（共 \(categories.count) 个分类）！"
    }

    private func setEnabled(_ enabled: Bool, in sources: [BookSource]) {
        var changed = 0
        for source in sources where (source.enabled ?? true) != enabled {
            library.toggleSource(sourceUrl: source.bookSourceUrl)
            changed += 1
        }
        let stateWord = enabled ? "启用" : "停用"
        state.notice = changed == 0
            ? "这些书源本来就已经是\(stateWord)状态。"
            : "已\(stateWord) \(changed) 个书源。"
    }

    private func removeRows(at offsets: IndexSet) {
        let rows = visible
        for offset in offsets where offset < rows.count {
            library.deleteSource(sourceUrl: rows[offset].bookSourceUrl)
        }
    }

    private func deleteVisible() {
        let urls = Set(visible.map(\.bookSourceUrl))
        library.deleteSources(sourceUrls: urls)
        AppLog.write("[书源] 批量删除 \(urls.count) 条")
        state.notice = "已删除 \(urls.count) 个书源"
    }

    private func toggleGroup(_ group: String) {
        var current = SourceCatalog.splitGroups(state.groupDraft)
        if let index = current.firstIndex(of: group) {
            current.remove(at: index)
        } else {
            current.append(group)
        }
        state.groupDraft = current.joined(separator: ",")
    }
}

// MARK: - 子视图

private struct SourceToolsSection: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        Section("工具") {
            NavigationLink(destination: SourceCheckView()) {
                HStack {
                    Label("校验书源", systemImage: "checkmark.shield")
                    Spacer()
                    Text("逐个检测书源可用性")
                        .font(.caption)
                        .foregroundColor(theme.palette.secondaryInk)
                }
            }
        }
        .appThemedRows()
    }
}

private struct SourceFilterSection: View {
    @ObservedObject var state: SourceManagerState
    let visible: [BookSource]
    let total: [BookSource]
    let groups: [String]
    let onEnableAll: () -> Void
    let onDisableAll: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Section("筛选") {
            HStack {
                Text("显示 \(visible.count) / 共 \(total.count)")
                    .font(.caption)
                    .foregroundColor(theme.palette.secondaryInk)
                Spacer()
                Text("可用 \(total.filter { $0.enabled != false }.count)")
                    .font(.caption)
                    .foregroundColor(theme.palette.secondaryInk)
            }

            Menu {
                Button("全部分组") { state.group = nil }
                ForEach(groups, id: \.self) { group in
                    Button(group) { state.group = group }
                }
            } label: {
                menuRow(title: "分组", value: state.group ?? "全部")
            }

            Menu {
                ForEach(SourceOrder.allCases) { order in
                    Button(order.rawValue) { state.order = order }
                }
            } label: {
                menuRow(title: "排序", value: state.order.rawValue)
            }

            Toggle("只看已启用", isOn: $state.enabledOnly)

            Menu {
                Button("启用当前筛选结果", action: onEnableAll)
                Button("停用当前筛选结果", action: onDisableAll)
                Divider()
                Button(role: .destructive) {
                    state.confirmBulkDelete = true
                } label: {
                    Text("删除当前筛选结果（\(visible.count)）")
                }
            } label: {
                menuRow(title: "批量操作", value: "作用于上面 \(visible.count) 个")
            }

            Button {
                state.groupManagerVisible = true
            } label: {
                HStack {
                    Label("分组管理", systemImage: "folder.badge.gearshape")
                    Spacer()
                    Text("\(groups.count) 个分组")
                        .foregroundColor(theme.palette.secondaryInk)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(theme.palette.secondaryInk)
                }
            }
        }
        .appThemedRows()
    }

    private func menuRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(theme.palette.secondaryInk)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(theme.palette.secondaryInk)
        }
    }
}

private struct SourceRow: View {
    let source: BookSource
    @ObservedObject var library: BookStore
    let onLogin: () -> Void
    @Environment(\.appTheme) private var theme

    private var hasLogin: Bool {
        source.loginUi != nil || source.loginUrl != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(source.bookSourceName).font(.headline)
                    if hasLogin {
                        loginBadge
                    }
                }
                Text(source.bookSourceUrl).font(.caption)
                    .foregroundColor(theme.palette.secondaryInk).lineLimit(1)
                if let group = source.bookSourceGroup, !group.isEmpty {
                    Text(group)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.palette.divider.opacity(0.12))
                        .cornerRadius(4)
                }
            }

            Spacer(minLength: 12)

            Toggle("", isOn: enabledBinding).labelsHidden()
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { source.enabled ?? true }, set: { _ in library.toggleSource(sourceUrl: source.bookSourceUrl) })
    }

    private var loginBadge: some View {
        Button(action: onLogin) {
            Label(
                source.isLogged ? "已登录" : "登录",
                systemImage: source.isLogged ? "checkmark.shield.fill" : "person.badge.key"
            )
            .labelStyle(.titleAndIcon).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(source.isLogged ? theme.palette.success.opacity(0.15) : theme.palette.accent.opacity(0.12))
            .foregroundColor(source.isLogged ? theme.palette.success : theme.palette.accent).cornerRadius(6)
        }.buttonStyle(.plain)
    }
}

private struct SourceGroupEditorSheet: View {
    let target: BookSource
    let groups: [String]
    @Binding var draft: String
    let onCancel: () -> Void
    let onSave: () -> Void
    let onToggle: (String) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        SheetNavigation {
            Form {
                Section("分类（分组）") {
                    TextField("多个分类用英文逗号分隔", text: $draft)
                        #if os(iOS)
                        .plainTextInput()
                        #endif
                    Text("留空 = 不分组")
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .appThemedRows()

                if !groups.isEmpty {
                    Section("已有分类（点一下切换）") {
                        ForEach(groups, id: \.self) { group in
                            Button {
                                onToggle(group)
                            } label: {
                                HStack {
                                    Text(group)
                                    Spacer()
                                    if SourceCatalog.splitGroups(draft).contains(group) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    .appThemedRows()
                }
            }
            .appThemedList()
            .sheetChrome("编辑分类")
            .toolbar {
                CancelToolbar(action: onCancel)
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: onSave)
                }
            }
        }
    }
}

private struct SourceImportSheet: View {
    @ObservedObject var state: SourceManagerState
    let onPickFiles: ([URL]) -> Void
    let onImportURL: () -> Void
    let onImportText: () -> Void
    let onClose: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        SheetNavigation {
            Form {
                Section("书源导入须知") {
                    BookSourceDisclaimerContent(agreed: $state.importConsent)
                }
                .appThemedRows()

                Section("本地文件导入") {
                    Button {
                        #if os(iOS)
                        SourceDocumentPicker.present(contentTypes: [.json, .plainText], onPicked: onPickFiles)
                        #else
                        state.notice = "当前平台不支持文件选择"
                        #endif
                    } label: {
                        Label("从本地文件导入 (.json)", systemImage: "doc.badge.plus")
                    }
                    .disabled(!state.importConsent)
                }
                .appThemedRows()

                Section("网络导入 (JSON URL)") {
                    TextField("输入书源网址 (https://...)", text: $state.urlDraft)
                        #if os(iOS)
                        .plainTextInput()
                        #endif
                    Button("从网络获取并导入", action: onImportURL)
                        .disabled(!state.importConsent || state.urlDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .appThemedRows()

                Section("剪贴板 / 本地文本导入") {
                    TextEditor(text: $state.textDraft)
                        .frame(height: 120)
                    Button("导入 JSON 文本", action: onImportText)
                        .disabled(!state.importConsent || state.textDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .appThemedRows()
            }
            .appThemedList()
            .sheetChrome("导入书源")
            .toolbar {
                CancelToolbar(action: onClose)
            }
        }
    }
}

private struct SourceExportPickerSheet: View {
    let sources: [BookSource]
    @Binding var selection: Set<String>
    let onCancel: () -> Void
    let onExport: ([BookSource]) -> Void

    var body: some View {
        SheetNavigation {
            List {
                ForEach(sources) { source in
                    Button {
                        toggle(source.bookSourceUrl)
                    } label: {
                        HStack {
                            Image(systemName: selection.contains(source.bookSourceUrl)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selection.contains(source.bookSourceUrl) ? .accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.bookSourceName)
                                    .foregroundColor(.primary)
                                Text(source.bookSourceUrl)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .sheetChrome("选择书源导出（\(selection.count)）")
            .toolbar {
                CancelToolbar(action: onCancel)
                ToolbarItem(placement: .primaryAction) {
                    HStack {
                        Button("全选") {
                            selection = Set(sources.map(\.bookSourceUrl))
                        }
                        Button("导出") {
                            onExport(sources.filter { selection.contains($0.bookSourceUrl) })
                        }
                        .disabled(selection.isEmpty)
                    }
                }
            }
        }
    }

    private func toggle(_ url: String) {
        selection.formSymmetricDifference([url])
    }
}

// MARK: - 文档选择器

#if os(iOS)
enum SourceDocumentPicker {
    private static var delegateKeeper: Delegate?

    static func present(contentTypes: [UTType], onPicked: @escaping ([URL]) -> Void) {
        guard let host = topController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        let delegate = Delegate(onPicked: onPicked)
        delegateKeeper = delegate
        picker.delegate = delegate
        host.present(picker, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
            ?? scenes.first?.windows.first
        var current = window?.rootViewController
        while let next = current?.presentedViewController {
            current = next
        }
        return current
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        private let onPicked: ([URL]) -> Void

        init(onPicked: @escaping ([URL]) -> Void) {
            self.onPicked = onPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            SourceDocumentPicker.delegateKeeper = nil
            onPicked(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            SourceDocumentPicker.delegateKeeper = nil
        }
    }
}
#endif

// MARK: - 书源登录

public struct SourceLoginSheet: View {
    private let source: BookSource
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var mode: LoginMode
    @State private var blueprint = LoginBlueprint.empty
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var errorText: String?
    @State private var successText: String?
    @State private var runningAction: String?

    enum LoginMode: String, Hashable {
        case form
        case web
    }

    public init(source: BookSource) {
        self.source = source
        _mode = State(initialValue: LoginBlueprint.prefersWeb(for: source) ? .web : .form)
    }

    public var body: some View { panel }

    private var usesWebLogin: Bool {
        LoginBlueprint.prefersWeb(for: source) || mode == .web
    }

    @ViewBuilder
    private var panel: some View {
        switch usesWebLogin {
        case true:
            SourceWebLoginView(source: source)
        case false:
            formBody
        }
    }

    private var isLogged: Bool { source.isLogged }

    private func signOut() {
        BookStore.shared.logoutSource(sourceUrl: source.bookSourceUrl)
        dismiss()
    }

    private var formBody: some View {
        SheetNavigation {
            Form {
                Section("书源信息") {
                    Text(source.bookSourceName).font(.headline)
                    Text(source.bookSourceUrl).font(.caption)
                        .foregroundColor(theme.palette.secondaryInk)
                    if isLogged {
                        Label("已登录", systemImage: "checkmark.circle.fill")
                            .foregroundColor(theme.palette.success)
                            .font(.subheadline)
                    }
                }
                .appThemedRows()

                Section("登录模式切换") {
                    Picker("登录模式", selection: $mode) {
                        Text("表单脚本登录").tag(LoginMode.form)
                        Text("网页/Cookie 登录").tag(LoginMode.web)
                    }
                    .pickerStyle(.segmented)
                }
                .appThemedRows()

                Section("账号登录表单") {
                    if blueprint.fields.isEmpty {
                        Text("该来源需要账号，使用下方按钮登录。")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                    } else {
                        ForEach(blueprint.fields) { field in
                            fieldEditor(field)
                        }
                    }
                }
                .appThemedRows()

                if !blueprint.actions.isEmpty {
                    Section("脚本按钮") {
                        ForEach(Array(blueprint.rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 8) {
                                ForEach(row) { action in
                                    Button { run(action) } label: {
                                        HStack(spacing: 4) {
                                            if runningAction == action.script {
                                                ProgressView().scaleEffect(0.7)
                                            }
                                            Text(action.name)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.7)
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(runningAction != nil)
                                }
                            }
                        }
                    }
                    .appThemedRows()
                }

                if let errorText {
                    Section {
                        Text(errorText).font(.subheadline)
                            .foregroundColor(theme.palette.danger)
                    }
                    .appThemedRows()
                }

                if let successText {
                    Section {
                        Text(successText).font(.subheadline)
                            .foregroundColor(theme.palette.success)
                    }
                    .appThemedRows()
                }

                Section {
                    if !blueprint.hasLoginAction {
                        Button(action: login) {
                            if busy {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                    Text("正在登录…").padding(.leading, 8)
                                    Spacer()
                                }
                            } else {
                                Text(source.isLogged ? "重新登录" : "立即登录")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(busy)
                    }

                    if isLogged {
                        Button(role: .destructive, action: signOut) {
                            Text("退出登录").frame(maxWidth: .infinity)
                        }
                    }
                }
                .appThemedRows()
            }
            .appThemedList()
            .sheetChrome("书源登录")
            .toolbar {
                CancelToolbar { dismiss() }
            }
            .onAppear(perform: loadBlueprint)
        }
    }

    @ViewBuilder
    private func fieldEditor(_ field: LoginBlueprint.Field) -> some View {
        switch field.type {
        case "password":
            SecureField(field.name, text: binding(for: field.name))
        default:
            TextField(field.name, text: binding(for: field.name))
                #if os(iOS)
                .plainTextInput()
                #endif
        }
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
    }

    private func loadBlueprint() {
        let parsed = LoginBlueprint.parse(source: source)
        blueprint = parsed.blueprint
        values = parsed.values
    }

    private func run(_ action: LoginBlueprint.Action) {
        runningAction = action.script
        errorText = nil
        successText = nil
        Task { @MainActor in
            do {
                let header = try await BookStore.shared.runLoginAction(
                    source: source,
                    credentials: values,
                    action: action.script
                )
                runningAction = nil
                successText = header.isEmpty
                    ? "「\(action.name)」已执行"
                    : "「\(action.name)」已执行，并拿到凭据"
            } catch let failure {
                runningAction = nil
                errorText = failure.localizedDescription
            }
        }
    }

    private func login() {
        busy = true
        errorText = nil
        successText = nil
        Task { @MainActor in
            do {
                _ = try await BookStore.shared.performLogin(source: source, credentials: values)
                busy = false
                successText = "登录成功！"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
            } catch let failure {
                busy = false
                errorText = "登录失败: \(failure.localizedDescription)"
            }
        }
    }
}

struct LoginBlueprint {
    struct Field: Identifiable {
        let name: String
        let type: String
        var id: String { name }
    }

    struct Action: Identifiable {
        let index: Int
        let name: String
        let script: String
        let width: Double
        var id: String { "\(index)-\(name)" }
    }

    var fields: [Field] = []
    var actions: [Action] = []

    static let empty = LoginBlueprint()

    static func prefersWeb(for source: BookSource) -> Bool {
        guard let raw = source.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        return (raw.hasPrefix("http://") || raw.hasPrefix("https://"))
            && !raw.contains("<js>")
            && !raw.contains("@js:")
    }

    static func parse(source: BookSource) -> (blueprint: LoginBlueprint, values: [String: String]) {
        var saved: [String: String] = [:]
        if let info = source.loginInfo,
           let data = info.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            saved = dict
        }

        guard let raw = source.loginUi,
              let data = raw.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return (
                LoginBlueprint(
                    fields: [Field(name: "账号", type: "text"), Field(name: "密码", type: "password")],
                    actions: []
                ),
                saved
            )
        }

        var fields: [Field] = []
        var actions: [Action] = []
        for (index, item) in items.enumerated() {
            let name = (item["name"] as? String) ?? ""
            let type = (item["type"] as? String) ?? "text"
            if type == "button" {
                guard !name.isEmpty,
                      let script = item["action"] as? String,
                      !script.isEmpty else { continue }
                actions.append(Action(
                    index: index,
                    name: name,
                    script: script,
                    width: flexWidth(item["style"])
                ))
            } else if !name.isEmpty {
                fields.append(Field(name: name, type: type))
            }
        }
        return (LoginBlueprint(fields: fields, actions: actions), saved)
    }

    static func flexWidth(_ style: Any?) -> Double {
        if let text = style as? String {
            let normalized = text.replacingOccurrences(of: "'", with: "\"")
            guard let data = normalized.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return 1
            }
            return number(object["layout_flexBasisPercent"])
        }
        if let object = style as? [String: Any] {
            return number(object["layout_flexBasisPercent"])
        }
        return 1
    }

    private static func number(_ value: Any?) -> Double {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let text = value as? String, let double = Double(text) { return double }
        return 1
    }

    var rows: [[Action]] {
        var result: [[Action]] = []
        var row: [Action] = []
        var width = 0.0
        for action in actions {
            let clamped = min(1.0, max(0.2, action.width))
            if !row.isEmpty && width + clamped > 1.0001 {
                result.append(row)
                row = []
                width = 0
            }
            row.append(action)
            width += clamped
        }
        if !row.isEmpty { result.append(row) }
        return result
    }

    var hasLoginAction: Bool {
        actions.contains { $0.script.lowercased().contains("login(") }
    }
}

// MARK: - 分组管理

struct SourceGroupManagerView: View {
    @ObservedObject private var library = BookStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var renaming: GroupName?
    @State private var renameDraft = ""
    @State private var deleting: GroupName?
    @State private var notice: String?

    private struct GroupName: Identifiable {
        let value: String
        var id: String { value }
    }

    private var groups: [String] {
        SourceGroupCatalog.all(in: library.sources)
    }

    private var looseCount: Int {
        library.sources.filter { SourceGroupCatalog.split($0.bookSourceGroup).isEmpty }.count
    }

    var body: some View {
        SheetNavigation {
            List {
                Section(header: Text("分组（\(groups.count)）")) {
                    if groups.isEmpty {
                        Text("还没有分组。先在书源里编辑分类，或到校验页按结果分组。")
                            .font(.footnote)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                    ForEach(groups, id: \.self) { group in
                        HStack {
                            Text(group)
                            Spacer()
                            Text("\(count(of: group)) 个")
                                .font(.caption)
                                .foregroundColor(theme.palette.secondaryInk)
                            Menu {
                                Button("重命名") {
                                    renameDraft = group
                                    renaming = GroupName(value: group)
                                }
                                Button(role: .destructive) {
                                    deleting = GroupName(value: group)
                                } label: {
                                    Text("删除分组")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundColor(theme.palette.accent)
                            }
                        }
                    }
                }
                .appThemedRows()

                Section {
                    HStack {
                        Label("未分组", systemImage: "tray")
                        Spacer()
                        Text("\(looseCount) 个")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                }
                .appThemedRows()
            }
            .appThemedList()
            .sheetChrome("分组管理")
            .toolbar {
                CancelToolbar("关闭") { dismiss() }
            }
            .sheet(item: $renaming) { target in
                renameSheet(target)
            }
            .alert("删除分组", isPresented: deleteBinding) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) {
                    if let target = deleting { remove(target) }
                }
            } message: {
                Text("只会从书源上移除这个分组名，不删除书源。")
            }
            .alert("分组", isPresented: noticeBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(notice ?? "")
            }
        }
    }

    private func renameSheet(_ target: GroupName) -> some View {
        SheetNavigation {
            Form {
                Section(header: Text("重命名「\(target.value)」")) {
                    TextField("新的分组名", text: $renameDraft)
                }
                .appThemedRows()
            }
            .appThemedList()
            .sheetChrome("重命名分组")
            .toolbar {
                CancelToolbar { renaming = nil }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { rename(target) }
                        .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )
    }

    private func count(of group: String) -> Int {
        library.sources.filter { SourceGroupCatalog.split($0.bookSourceGroup).contains(group) }.count
    }

    private func rename(_ target: GroupName) {
        let newName = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != target.value else {
            renaming = nil
            return
        }
        for source in library.sources {
            var groups = SourceGroupCatalog.split(source.bookSourceGroup)
            guard let index = groups.firstIndex(of: target.value) else { continue }
            groups[index] = newName
            library.setSourceGroup(sourceUrl: source.bookSourceUrl, group: groups.joined(separator: ","))
        }
        notice = "已把「\(target.value)」重命名为「\(newName)」。"
        renaming = nil
    }

    private func remove(_ target: GroupName) {
        for source in library.sources {
            var groups = SourceGroupCatalog.split(source.bookSourceGroup)
            guard groups.contains(target.value) else { continue }
            groups.removeAll { $0 == target.value }
            library.setSourceGroup(
                sourceUrl: source.bookSourceUrl,
                group: groups.isEmpty ? nil : groups.joined(separator: ",")
            )
        }
        notice = "已删除分组「\(target.value)」。"
        deleting = nil
    }
}

enum SourceGroupCatalog {
    static func split(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw
            .components(separatedBy: CharacterSet(charactersIn: ",，、;； "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func all(in sources: [BookSource]) -> [String] {
        var names = Set<String>()
        for source in sources {
            for group in split(source.bookSourceGroup) {
                names.insert(group)
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
