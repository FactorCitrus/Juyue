import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(LegadoCore)
import LegadoCore
#endif

public struct SourceManagerView: View {
    @ObservedObject var bookStore = BookStore.shared
    @Environment(\.appTheme) private var theme

    @State private var showImportSheet: Bool = false
    /// 书源导出（存到「文件」）
    @State private var showSourceExporter: Bool = false
    @State private var sourceExportDocument: ExportedFile?
    @State private var sourceExportName: String = "bookSource.json"
    @State private var exportingCount: Int = 0
    @State private var showExportPicker = false
    @State private var exportSelectedURLs: Set<String> = []
    @State private var importEntries: [BookStore.SourceImportEntry] = []
    @State private var showImportPreview = false
    @State private var shareItem: SourceShareItem? = nil
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
    /// 正在改分组的书源
    @State private var groupEditTarget: BookSource?
    @State private var groupEditText: String = ""
    @State private var showGroupManager = false

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
        // 置顶项排在最前，各排序模式下都生效
        return list.enumerated()
            .sorted { lhs, rhs in
                let lp = bookStore.isPinned(lhs.element), rp = bookStore.isPinned(rhs.element)
                if lp != rp { return lp }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    public var body: some View {
        List {
            Section {
                TerminalPageHeader(code: "SOURCE / LIBRARY", title: "书源管理", detail: "筛选 / 排序 / 校验 / 导入导出")
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }
            .appThemedRows()

            Section(header: Text("工具")) {
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

            Section(header: Text("筛选")) {
                HStack {
                    Text("显示 \(filteredSources.count) / 共 \(bookStore.sources.count)")
                        .font(.caption)
                        .foregroundColor(theme.palette.secondaryInk)
                    Spacer()
                    Text("可用 \(bookStore.sources.filter { $0.enabled != false }.count)")
                        .font(.caption)
                        .foregroundColor(theme.palette.secondaryInk)
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
                            .foregroundColor(theme.palette.secondaryInk)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
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
                            .foregroundColor(theme.palette.secondaryInk)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
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
                            .foregroundColor(theme.palette.secondaryInk)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                }

                Button {
                    showGroupManager = true
                } label: {
                    HStack {
                        Label("分组管理", systemImage: "folder.badge.gearshape")
                        Spacer()
                        Text("\(allGroups.count) 个分组")
                            .foregroundColor(theme.palette.secondaryInk)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                }
            }
            .appThemedRows()

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
                                bookStore.setPinned(!bookStore.isPinned(source), sourceUrl: source.bookSourceUrl)
                            } label: {
                                Label(bookStore.isPinned(source) ? "取消置顶" : "置顶",
                                      systemImage: bookStore.isPinned(source) ? "pin.slash" : "pin")
                            }

                            Button {
                                groupEditText = source.bookSourceGroup ?? ""
                                groupEditTarget = source
                            } label: {
                                Label("编辑分类", systemImage: "folder")
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

                            Button {
                                copySourceJSON(source)
                            } label: {
                                Label("复制 JSON", systemImage: "doc.on.doc")
                            }

                            Button {
                                shareSource(source)
                            } label: {
                                Label("分享书源", systemImage: "square.and.arrow.up")
                            }

                            Button {
                                exportSources([source], namePrefix: "bookSource-single")
                            } label: {
                                Label("导出这个书源", systemImage: "tray.and.arrow.down")
                            }

                            Button {
                                clearVariable(source)
                            } label: {
                                Label("清空变量", systemImage: "eraser")
                            }

                            if source.loginUi != nil || source.loginUrl != nil {
                                Button(role: .destructive) {
                                    resetLoginState(source)
                                } label: {
                                    Label("重置登录态", systemImage: "person.crop.circle.badge.xmark")
                                }
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
            .appThemedRows()
            }
            .searchable(text: $searchText, prompt: "搜书源名 / 网址 / 分组")
#if os(iOS)
            .listStyle(.insetGrouped)
#else
            .listStyle(.inset)
#endif
            .appThemedList()
            .navigationTitle("书源管理")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showImportSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("导出全部（\(bookStore.sources.count)）") {
                            exportSources(bookStore.sources)
                        }
                        Button("导出当前筛选（\(filteredSources.count)）") {
                            exportSources(filteredSources)
                        }
                        Button("选择书源导出…") {
                            exportSelectedURLs = []
                            showExportPicker = true
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showImportSheet) {
                importSourceSheet
            }
            .sheet(item: $groupEditTarget) { target in
                groupEditor(for: target)
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
            .sheet(isPresented: $showGroupManager) {
                SourceGroupManagerView()
            }
            .sheet(isPresented: $showImportPreview) {
                SourceImportPreviewView(entries: importEntries) { overwrite in
                    let result = bookStore.applyImport(entries: importEntries, overwriteConflicts: overwrite)
                    importEntries = []
                    alertMessage = "导入完成：新增 \(result.added)，更新 \(result.updated)，同名保留 \(result.conflictsAdded)"
                    showAlert = true
                }
            }
            .sheet(isPresented: $showExportPicker) {
                exportPickerSheet
            }
            .sheet(item: $shareItem) { item in
                #if os(iOS)
                SourceShareSheet(items: [item.url])
                #else
                Text("当前平台请使用文件导出")
                    .padding()
                #endif
            }
            .alert(alertMessage ?? "", isPresented: $showAlert) {
                Button("确定", role: .cancel) {}
            }
            .alert("删除这些书源？", isPresented: $showBatchDeleteAlert) {
                Button("取消", role: .cancel) {}
                Button("删除 \(filteredSources.count) 个", role: .destructive) {
                    // 一次删完，逐条删会每删一条就编码写盘一次
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
                    alertMessage = "已导出 \(exportingCount) 个书源"
                case .failure(let error):
                    alertMessage = "导出失败: \(error.localizedDescription)"
                }
                showAlert = true
            }
    }

    /// 导出全部书源成 JSON（和导入同一套格式，导回来能直接用）
    private func exportSources(_ list: [BookSource], namePrefix: String = "bookSource") {
        guard !list.isEmpty else {
            alertMessage = "没有可导出的书源"
            showAlert = true
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(list) else {
            alertMessage = "导出失败：书源编码出错"
            showAlert = true
            return
        }
        exportingCount = list.count
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        sourceExportName = "\(namePrefix)-\(formatter.string(from: Date())).json"
        sourceExportDocument = ExportedFile(data: data)
        showSourceExporter = true
    }

    private var exportPickerSheet: some View {
        NavigationView {
            List {
                ForEach(filteredSources) { source in
                    Button {
                        if exportSelectedURLs.contains(source.bookSourceUrl) {
                            exportSelectedURLs.remove(source.bookSourceUrl)
                        } else {
                            exportSelectedURLs.insert(source.bookSourceUrl)
                        }
                    } label: {
                        HStack {
                            Image(systemName: exportSelectedURLs.contains(source.bookSourceUrl)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(exportSelectedURLs.contains(source.bookSourceUrl) ? .accentColor : .secondary)
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
            .navigationTitle("选择书源导出（\(exportSelectedURLs.count)）")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showExportPicker = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack {
                        Button("全选") {
                            exportSelectedURLs = Set(filteredSources.map(\.bookSourceUrl))
                        }
                        Button("导出") {
                            let selected = filteredSources.filter { exportSelectedURLs.contains($0.bookSourceUrl) }
                            showExportPicker = false
                            exportSources(selected, namePrefix: "selected-bookSource")
                        }
                        .disabled(exportSelectedURLs.isEmpty)
                    }
                }
            }
        }
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
        alertMessage = "已复制「\(source.bookSourceName)」的 JSON"
        showAlert = true
    }

    private func shareSource(_ source: BookSource) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode([source]) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SourceShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = source.bookSourceName.replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent("\(safeName)-bookSource.json")
        do {
            try data.write(to: url, options: .atomic)
            shareItem = SourceShareItem(url: url)
        } catch {
            alertMessage = "生成分享文件失败：\(error.localizedDescription)"
            showAlert = true
        }
    }

    private func resetLoginState(_ source: BookSource) {
        bookStore.logoutSource(sourceUrl: source.bookSourceUrl)
        alertMessage = "已清除「\(source.bookSourceName)」的登录 Header 与 Cookie"
        showAlert = true
    }

    private func clearVariable(_ source: BookSource) {
        var updated = source
        updated.variable = nil
        bookStore.updateSource(updated)
        alertMessage = "已清空「\(source.bookSourceName)」的书源变量"
        showAlert = true
    }

    /// 预览导入计划；返回是否成功解析。
    @discardableResult
    private func prepareImport(_ json: String) -> [BookStore.SourceImportEntry]? {
        do {
            let entries = try bookStore.planImportSources(json: json)
            guard !entries.isEmpty else {
                alertMessage = "未发现有效书源"
                showAlert = true
                return nil
            }
            importEntries = entries
            showImportSheet = false
            DispatchQueue.main.async { showImportPreview = true }
            return entries
        } catch {
            alertMessage = "导入失败：JSON 格式错误"
            showAlert = true
            return nil
        }
    }

    /// 选完文件之后的导入流程
    private func handlePickedSourceFiles(_ urls: [URL]) {
        var entries: [BookStore.SourceImportEntry] = []
        var seen = Set<String>()
        var errorCount = 0
        for url in urls {
            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                // 中文书源文件常见 GBK/ANSI 编码，UTF-8/UTF-16 读不出来，加 GB18030 兜底
                let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
                if let str = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: gb18030)
                    ?? String(data: data, encoding: .unicode) {
                    let plan = try bookStore.planImportSources(json: str)
                    for entry in plan where seen.insert(entry.incoming.bookSourceUrl).inserted {
                        entries.append(entry)
                    }
                } else {
                    errorCount += 1
                }
            } catch {
                errorCount += 1
            }
        }
        AppLog.write("[书源] 文件导入预览：\(urls.count) 个文件，解析 \(entries.count) 条，失败 \(errorCount) 个")
        if !entries.isEmpty {
            importEntries = entries
            showImportSheet = false
            DispatchQueue.main.async { showImportPreview = true }
        } else {
            alertMessage = errorCount > 0 ? "导入失败：未能成功解析书源文件" : "未在文件中发现有效书源"
            showAlert = true
        }
    }

#if os(iOS)
/// 系统文档选择器（UIKit）。
/// `.fileImporter` 从 sheet 里触发时，iOS 16 上选完文件点「打开」的回调不触发
/// （真机 iOS 16.1.1 复现，模拟器 iOS 26 正常）。
/// `asCopy: true`，拿到沙盒里可直接读的副本。
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
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(1)
                if let group = source.bookSourceGroup, !group.isEmpty {
                    Text(group)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.palette.divider.opacity(0.12))
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
            .background(source.isLogged ? theme.palette.success.opacity(0.15) : theme.palette.accent.opacity(0.12))
            .foregroundColor(source.isLogged ? theme.palette.success : theme.palette.accent)
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

    /// 批量启用/停用，只翻转状态不一致的。
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

    /// 编辑书源分组，可手打或点已有分组。
    @ViewBuilder
    private func groupEditor(for target: BookSource) -> some View {
        NavigationView {
            Form {
                Section(header: Text("分类（分组）")) {
                    TextField("多个分类用英文逗号分隔", text: $groupEditText)
                        #if os(iOS)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        #endif
                    Text("留空 = 不分组")
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .appThemedRows()

                if !allGroups.isEmpty {
                    Section(header: Text("已有分类（点一下切换）")) {
                        ForEach(allGroups, id: \.self) { group in
                            Button {
                                toggleGroup(group)
                            } label: {
                                HStack {
                                    Text(group)
                                    Spacer()
                                    if SourceManagerView.splitGroups(groupEditText).contains(group) {
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
            .navigationTitle("编辑分类")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { groupEditTarget = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        bookStore.setSourceGroup(sourceUrl: target.bookSourceUrl, group: groupEditText)
                        groupEditTarget = nil
                    }
                }
            }
        }
    }

    private func toggleGroup(_ group: String) {
        var groups = SourceManagerView.splitGroups(groupEditText)
        if let idx = groups.firstIndex(of: group) {
            groups.remove(at: idx)
        } else {
            groups.append(group)
        }
        groupEditText = groups.joined(separator: ",")
    }

    private var importSourceSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("本地文件导入")) {
                    Button {
#if os(iOS)
                        // 用 UIKit 文档选择器：SwiftUI 的 .fileImporter 从 sheet 里触发时，
                        // iOS 16 上选完文件点「打开」的回调不触发（真机 16.1.1 复现）。
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
                .appThemedRows()

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
                .appThemedRows()

                Section(header: Text("剪贴板 / 本地文本导入")) {
                    TextEditor(text: $importText)
                        .frame(height: 120)
                    Button("导入 JSON 文本") {
                        importFromText()
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .appThemedRows()
            }
            .appThemedList()
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
        if prepareImport(importText) != nil {
            importText = ""
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
                    AppLog.write("[书源] 网络导入预览：host=\(url.host ?? "-")")
                    if prepareImport(jsonStr) != nil {
                        importUrl = ""
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
    @Environment(\.appTheme) private var theme
    @State private var loginMode: String
    @State private var fields: [LoginField] = []
    @State private var fieldValues: [String: String] = [:]
    @State private var isLoggingIn: Bool = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil
    @State private var loginButtons: [LoginButton] = []
    @State private var runningAction: String? = nil

    struct LoginField: Identifiable {
        var id: String { name }
        let name: String
        let type: String
    }

    /// `loginUi` 里的按钮项。每个按钮带一段 action 脚本，
    /// 宽度由 style 的 `layout_flexBasisPercent` 定（0.4 = 一行两个，1 = 独占一行）。
    struct LoginButton: Identifiable {
        var id: String { "\(index)-\(name)" }
        let index: Int
        let name: String
        let action: String
        let width: Double
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
                        .foregroundColor(theme.palette.secondaryInk)
                    if source.isLogged {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(theme.palette.success)
                            Text("已登录")
                                .foregroundColor(theme.palette.success)
                                .font(.subheadline)
                        }
                    }
                }
                .appThemedRows()

                Section(header: Text("登录模式切换")) {
                    Picker("登录模式", selection: $loginMode) {
                        Text("表单脚本登录").tag("form")
                        Text("网页/Cookie 登录").tag("web")
                    }
                    .pickerStyle(.segmented)
                }
                .appThemedRows()

                Section(header: Text("账号登录表单")) {
                    if fields.isEmpty {
                        Text("这个源不用填账号，点下面的按钮登录。")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
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
                .appThemedRows()

                if !loginButtons.isEmpty {
                    Section(header: Text("脚本按钮")) {
                        ForEach(Array(buttonRows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 8) {
                                ForEach(row) { button in
                                    Button {
                                        runLoginAction(button)
                                    } label: {
                                        HStack(spacing: 4) {
                                            if runningAction == button.action {
                                                ProgressView().scaleEffect(0.7)
                                            }
                                            Text(button.name)
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

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundColor(theme.palette.danger)
                            .font(.subheadline)
                    }
                    .appThemedRows()
                }

                if let succ = successMessage {
                    Section {
                        Text(succ)
                            .foregroundColor(theme.palette.success)
                            .font(.subheadline)
                    }
                    .appThemedRows()
                }

                Section {
                    // loginUi 自带登录按钮时不追加宿主的「立即登录」
                    if !hasLoginButton {
                    Button(action: performLogin) {
                        if isLoggingIn {
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
                    .disabled(isLoggingIn)
                    }

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
                .appThemedRows()
            }
            .appThemedList()
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
            loginButtons = []
            return
        }

        var parsed: [LoginField] = []
        var buttons: [LoginButton] = []
        for (index, item) in arr.enumerated() {
            let name = (item["name"] as? String) ?? ""
            let type = (item["type"] as? String) ?? "text"
            if type == "button" {
                guard !name.isEmpty, let action = item["action"] as? String, !action.isEmpty else { continue }
                buttons.append(LoginButton(index: index,
                                           name: name,
                                           action: action,
                                           width: Self.parseFlexWidth(item["style"])))
            } else if !name.isEmpty {
                parsed.append(LoginField(name: name, type: type))
            }
        }
        self.fields = parsed
        self.loginButtons = buttons
    }

    /// 取 style 里的 layout_flexBasisPercent。
    /// 安卓导出的是单引号伪 JSON：`{'layout_flexGrow': 1, 'layout_flexBasisPercent': 0.4}`，
    /// 需先换成双引号再交给 JSONSerialization。
    static func parseFlexWidth(_ style: Any?) -> Double {
        var text: String?
        if let s = style as? String { text = s }
        else if let dict = style as? [String: Any], let v = dict["layout_flexBasisPercent"] {
            return (v as? Double) ?? Double("\(v)") ?? 1
        }
        guard let raw = text else { return 1 }
        let normalized = raw.replacingOccurrences(of: "'", with: "\"")
        guard let data = normalized.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 1 }
        if let v = dict["layout_flexBasisPercent"] as? Double { return v }
        if let v = dict["layout_flexBasisPercent"], let d = Double("\(v)") { return d }
        return 1
    }

    /// 按宽度把按钮折行，一行内宽度和不超过 1.0；总宽不足 1 时按比例撑满。
    private var buttonRows: [[LoginButton]] {
        var rows: [[LoginButton]] = []
        var current: [LoginButton] = []
        var sum = 0.0
        for button in loginButtons {
            let w = min(1.0, max(0.2, button.width))
            if !current.isEmpty && sum + w > 1.0001 {
                rows.append(current)
                current = []
                sum = 0
            }
            current.append(button)
            sum += w
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    /// loginUi 是否自带「登录」按钮
    private var hasLoginButton: Bool {
        loginButtons.contains { $0.action.lowercased().contains("login(") }
    }

    /// 跑某个按钮的 action（注册 / 番茄登录 / 切换服务器等）。
    private func runLoginAction(_ button: LoginButton) {
        runningAction = button.action
        errorMessage = nil
        successMessage = nil
        Task {
            do {
                let header = try await BookStore.shared.runLoginAction(source: source,
                                                                      credentials: fieldValues,
                                                                      action: button.action)
                runningAction = nil
                successMessage = header.isEmpty
                    ? "「\(button.name)」已执行"
                    : "「\(button.name)」已执行，并拿到凭据"
            } catch {
                runningAction = nil
                errorMessage = error.localizedDescription
            }
        }
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

/// 分组不是独立实体，而是书源里的逗号串。这里统一做重命名和删除。
struct SourceGroupManagerView: View {
    @ObservedObject private var store = BookStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var renameTarget: GroupName?
    @State private var renameText = ""
    @State private var deleteTarget: GroupName?
    @State private var message: String?

    private struct GroupName: Identifiable {
        let value: String
        var id: String { value }
    }

    private var groups: [String] {
        var set = Set<String>()
        for source in store.sources {
            for group in Self.splitGroups(source.bookSourceGroup) {
                set.insert(group)
            }
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var ungroupedCount: Int {
        store.sources.filter { Self.splitGroups($0.bookSourceGroup).isEmpty }.count
    }

    var body: some View {
        NavigationView {
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
                            Text("\(count(for: group)) 个")
                                .font(.caption)
                                .foregroundColor(theme.palette.secondaryInk)
                            Menu {
                                Button("重命名") {
                                    renameText = group
                                    renameTarget = GroupName(value: group)
                                }
                                Button(role: .destructive) {
                                    deleteTarget = GroupName(value: group)
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
                        Text("\(ungroupedCount) 个")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                }
                .appThemedRows()
            }
            .appThemedList()
            .navigationTitle("分组管理")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(item: $renameTarget) { target in
                NavigationView {
                    Form {
                        Section(header: Text("重命名「\(target.value)」")) {
                            TextField("新的分组名", text: $renameText)
                        }
                        .appThemedRows()
                    }
                    .appThemedList()
                    .navigationTitle("重命名分组")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { renameTarget = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") { rename(target) }
                                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            .alert("删除分组", isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )) {
                Button("取消", role: .cancel) { deleteTarget = nil }
                Button("删除", role: .destructive) {
                    if let target = deleteTarget { delete(target) }
                }
            } message: {
                Text("只会从书源上移除这个分组名，不删除书源。")
            }
            .alert("分组", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func count(for group: String) -> Int {
        store.sources.filter { Self.splitGroups($0.bookSourceGroup).contains(group) }.count
    }

    private func rename(_ target: GroupName) {
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != target.value else {
            renameTarget = nil
            return
        }
        for source in store.sources {
            var groups = Self.splitGroups(source.bookSourceGroup)
            guard let index = groups.firstIndex(of: target.value) else { continue }
            groups[index] = newName
            store.setSourceGroup(sourceUrl: source.bookSourceUrl, group: groups.joined(separator: ","))
        }
        message = "已把「\(target.value)」重命名为「\(newName)」。"
        renameTarget = nil
    }

    private func delete(_ target: GroupName) {
        for source in store.sources {
            var groups = Self.splitGroups(source.bookSourceGroup)
            guard groups.contains(target.value) else { continue }
            groups.removeAll { $0 == target.value }
            store.setSourceGroup(
                sourceUrl: source.bookSourceUrl,
                group: groups.isEmpty ? nil : groups.joined(separator: ",")
            )
        }
        message = "已删除分组「\(target.value)」。"
        deleteTarget = nil
    }

    private static func splitGroups(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.components(separatedBy: CharacterSet(charactersIn: ",，、;； "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
