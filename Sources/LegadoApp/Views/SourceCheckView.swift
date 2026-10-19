import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 书源校验：逐源跑一遍「搜索 → 详情 → 目录 → 正文」，报出每一步的结果与耗时。
///
/// 校验只读：不落库、不改书源，搜到的第一本书只用来当靶子。
struct SourceCheckView: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject private var store = BookStore.shared

    private enum Step: String {
        case waiting = "待校验"
        case searching = "搜索"
        case detail = "详情"
        case toc = "目录"
        case content = "正文"
        case passed = "通过"
        case failed = "失败"
    }

    private struct Row: Identifiable {
        let id: String
        let name: String
        var step: Step = .waiting
        var detail: String = ""
        var seconds: Double = 0
        var diagnostics: [SourceRequestDiagnostic] = []
    }

    private struct CheckAttempt: Codable {
        var time: Date
        var passed: Bool
        var durationMs: Int64
    }

    private struct SourceCheckRecord: Codable {
        var attempts: [CheckAttempt] = []
        var lastDiagnostics: [SourceRequestDiagnostic] = []
    }

    private final class DiagnosticCollector {
        private let lock = NSLock()
        private var items: [SourceRequestDiagnostic] = []

        func append(_ item: SourceRequestDiagnostic) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }

        var all: [SourceRequestDiagnostic] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    private let historyKey = "source_check_history_v1"

    @State private var keyword = "小说"
    @State private var rows: [Row] = []
    @State private var running = false
    @State private var stopRequested = false
    @State private var selectMode = false
    @State private var selected: Set<String> = []
    @State private var showGroupAssignment = false
    @State private var groupText = ""
    @State private var replaceGroups = false
    @State private var groupMessage: String?
    @State private var history: [String: SourceCheckRecord] = [:]
    @State private var diagnosticRow: Row?
    @State private var saveWorkItem: DispatchWorkItem?

    var body: some View {
        List {
            Section {
                HStack {
                    Text("校验关键字")
                    TextField("搜索词", text: $keyword)
                        .multilineTextAlignment(.trailing)
                }
                Button(running ? "停止" : "开始校验") {
                    if running { stopRequested = true } else { start() }
                }
                .foregroundColor(running ? .red : .accentColor)
            } footer: {
                Text("每个源都会跑一遍搜索、详情、目录和正文，不改书源。源多会慢一些，可以随时停。")
            }
            .appThemedRows()

            Section(header: Text("结果（\(passedCount)/\(rows.count) 通过）")) {
                if selectMode {
                    HStack {
                        Button("全选失败") {
                            selected = Set(rows.filter { $0.step == .failed }.map(\.id))
                        }
                        Spacer()
                        Text("已选 \(selected.count)")
                            .font(.footnote)
                            .foregroundColor(theme.palette.secondaryInk)
                        Spacer()
                        Button("重试") {
                            retrySelected()
                        }
                        .disabled(selected.isEmpty || running)
                        Menu {
                            Button("分配到分组…") {
                                groupText = ""
                                replaceGroups = false
                                showGroupAssignment = true
                            }
                            .disabled(selected.isEmpty)
                            Button("按校验结果分组") {
                                groupByResult()
                            }
                            .disabled(!rows.contains { $0.step == .passed || $0.step == .failed })
                        } label: {
                            Text("分组")
                        }
                        Button(role: .destructive) {
                            store.deleteSources(sourceUrls: selected)
                            rows.removeAll { selected.contains($0.id) }
                            selected.removeAll()
                        } label: {
                            Text("删除")
                        }
                        .disabled(selected.isEmpty)
                    }
                }
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        if selectMode {
                            Image(systemName: selected.contains(row.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selected.contains(row.id) ? .accentColor : .secondary)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: icon(for: row.step))
                                    .foregroundColor(color(for: row.step))
                                Text(row.name)
                                    .font(.system(size: 14, weight: .medium))
                                Spacer()
                                TerminalStatusPill(text: row.step.rawValue, color: color(for: row.step))
                                if row.seconds > 0 {
                                    Text(String(format: "%.1fs", row.seconds))
                                        .font(.system(size: 11, design: .rounded))
                                        .foregroundColor(theme.palette.secondaryInk)
                                }
                            }
                            if !row.detail.isEmpty {
                                Text(row.detail)
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.palette.secondaryInk)
                                    .lineLimit(2)
                            }
                            if let summary = historySummary(for: row.id) {
                                Text(summary)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(theme.palette.secondaryInk.opacity(0.8))
                            }
                            if !row.diagnostics.isEmpty {
                                Button("查看诊断（\(row.diagnostics.count)）") {
                                    diagnosticRow = row
                                }
                                .font(.system(size: 11))
                                .buttonStyle(.plain)
                                .foregroundColor(theme.palette.accent)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard selectMode else { return }
                        if selected.contains(row.id) { selected.remove(row.id) } else { selected.insert(row.id) }
                    }
                }
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle("书源校验")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(selectMode ? "完成" : "管理") {
                    selectMode.toggle()
                    if !selectMode { selected.removeAll() }
                }
            }
        }
        .onAppear {
            loadHistory()
            if rows.isEmpty {
                rows = store.sources
                    .filter { $0.enabled ?? true }
                    .map { Row(id: $0.bookSourceUrl, name: $0.bookSourceName) }
            }
        }
        .sheet(item: $diagnosticRow) { row in
            diagnosticSheet(for: row)
        }
        .sheet(isPresented: $showGroupAssignment) {
            groupAssignmentSheet
        }
        .alert("分组", isPresented: Binding(
            get: { groupMessage != nil },
            set: { if !$0 { groupMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(groupMessage ?? "")
        }
    }

    private var passedCount: Int {
        rows.filter { $0.step == .passed }.count
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([String: SourceCheckRecord].self, from: data) else {
            return
        }
        history = decoded
    }

    private func scheduleHistorySave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(history) {
                UserDefaults.standard.set(data, forKey: historyKey)
            }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func finish(
        id: String,
        passed: Bool,
        started: Date,
        diagnostics: [SourceRequestDiagnostic]
    ) {
        let duration = Int64(Date().timeIntervalSince(started) * 1000)
        var record = history[id] ?? SourceCheckRecord()
        record.attempts.append(CheckAttempt(time: Date(), passed: passed, durationMs: duration))
        if record.attempts.count > 10 {
            record.attempts.removeFirst(record.attempts.count - 10)
        }
        record.lastDiagnostics = diagnostics
        history[id] = record
        scheduleHistorySave()
    }

    private func historySummary(for id: String) -> String? {
        guard let record = history[id], let last = record.attempts.last else { return nil }
        let passed = record.attempts.filter(\.passed).count
        let rate = Int(Double(passed) / Double(record.attempts.count) * 100)
        let avg = record.attempts.map(\.durationMs).reduce(0, +) / Int64(max(1, record.attempts.count))
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "上次 \(formatter.string(from: last.time)) · 通过率 \(rate)% · 平均 \(String(format: "%.1f", Double(avg) / 1000))s"
    }

    private func diagnosticSheet(for row: Row) -> some View {
        NavigationView {
            List {
                ForEach(row.diagnostics) { item in
                    Section(header: Text("\(item.step) · \(item.statusCode > 0 ? "HTTP \(item.statusCode)" : "无 HTTP")")) {
                        labeled("请求 URL", item.url)
                        labeled("耗时", "\(item.elapsedMs) ms")
                        labeled("响应大小", "\(item.responseBytes) B")
                        labeled("规则命中", "\(item.ruleHits)")
                        if !item.note.isEmpty {
                            labeled("说明", item.note)
                        }
                        if !item.responsePreview.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("原始响应摘要")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(item.responsePreview)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle("检测诊断")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { diagnosticRow = nil }
                }
            }
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }

    private var allGroups: [String] {
        var groups = Set<String>()
        for source in store.sources {
            for group in Self.splitGroups(source.bookSourceGroup) {
                groups.insert(group)
            }
        }
        return groups.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func splitGroups(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.components(separatedBy: CharacterSet(charactersIn: ",，、;； "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var groupAssignmentSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("已选 \(selected.count) 个书源")) {
                    TextField("分组名，多个用逗号分隔", text: $groupText)
                    Toggle("替换原有分组", isOn: $replaceGroups)
                }
                .appThemedRows()

                if !allGroups.isEmpty {
                    Section(header: Text("已有分组（点一下加入）")) {
                        ForEach(allGroups, id: \.self) { group in
                            Button {
                                toggleGroup(group)
                            } label: {
                                HStack {
                                    Text(group)
                                    Spacer()
                                    if Self.splitGroups(groupText).contains(group) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(theme.palette.accent)
                                    }
                                }
                            }
                        }
                    }
                    .appThemedRows()
                }
            }
            .appThemedList()
            .navigationTitle("分配到分组")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showGroupAssignment = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { applyGroups() }
                        .disabled(selected.isEmpty)
                }
            }
        }
    }

    private func toggleGroup(_ group: String) {
        var groups = Self.splitGroups(groupText)
        if let index = groups.firstIndex(of: group) {
            groups.remove(at: index)
        } else {
            groups.append(group)
        }
        groupText = groups.joined(separator: ",")
    }

    private func applyGroups() {
        let incoming = Self.splitGroups(groupText)
        guard !incoming.isEmpty else {
            groupMessage = "请先填写或选择一个分组。"
            return
        }
        for source in store.sources where selected.contains(source.bookSourceUrl) {
            let existing = replaceGroups ? [] : Self.splitGroups(source.bookSourceGroup)
            let merged = Array(Set(existing).union(incoming))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            store.setSourceGroup(sourceUrl: source.bookSourceUrl, group: merged.joined(separator: ","))
        }
        groupMessage = "已把 \(selected.count) 个书源分到：\(incoming.joined(separator: "、"))。"
        showGroupAssignment = false
    }

    private func groupByResult() {
        let passed = Set(rows.filter { $0.step == .passed }.map(\.id))
        let failed = Set(rows.filter { $0.step == .failed }.map(\.id))
        mergeGroup("校验可用", into: passed)
        mergeGroup("校验失效", into: failed)
        groupMessage = "已并入分组：校验可用 \(passed.count) 个，校验失效 \(failed.count) 个。"
    }

    private func mergeGroup(_ group: String, into ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for source in store.sources where ids.contains(source.bookSourceUrl) {
            let groups = Set(Self.splitGroups(source.bookSourceGroup)).union([group])
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            store.setSourceGroup(sourceUrl: source.bookSourceUrl, group: groups.joined(separator: ","))
        }
    }

    private func icon(for step: Step) -> String {
        switch step {
        case .waiting: return "circle"
        case .searching, .detail, .toc, .content: return "arrow.triangle.2.circlepath"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func color(for step: Step) -> Color {
        switch step {
        case .waiting: return .secondary
        case .passed: return .green
        case .failed: return .red
        default: return .accentColor
        }
    }

    private func start() {
        let sources = store.sources.filter { $0.enabled ?? true }
        rows = sources.map { Row(id: $0.bookSourceUrl, name: $0.bookSourceName) }
        guard !sources.isEmpty else { return }
        running = true
        stopRequested = false
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            for source in sources {
                if stopRequested { break }
                await check(source: source, key: key.isEmpty ? "小说" : key)
            }
            await MainActor.run {
                running = false
                stopRequested = false
            }
        }
    }

    /// 重试选中的源：清掉状态再跑一遍
    private func retrySelected() {
        let targets = store.sources.filter { selected.contains($0.bookSourceUrl) }
        guard !targets.isEmpty, !running else { return }
        running = true
        stopRequested = false
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            for source in targets {
                if stopRequested { break }
                await check(source: source, key: key.isEmpty ? "小说" : key)
            }
            await MainActor.run {
                running = false
                stopRequested = false
            }
        }
    }

    private func update(_ id: String, step: Step, detail: String? = nil, seconds: Double? = nil) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].step = step
        if let detail { rows[index].detail = detail }
        if let seconds { rows[index].seconds = seconds }
    }

    /// 单个书源的四步校验：任何一步失败就停下，把失败环节报出来
    private func check(source: BookSource, key: String) async {
        let started = Date()
        let collector = DiagnosticCollector()
        func elapsed() -> Double { Date().timeIntervalSince(started) }

        await MainActor.run { update(source.bookSourceUrl, step: .searching, detail: "", seconds: 0) }
        let found: [SearchBook]
        do {
            found = try await BookSearchService.shared.search(
                source: source,
                key: key,
                diagnostics: { collector.append($0) }
            )
        } catch {
            await MainActor.run {
                update(source.bookSourceUrl, step: .failed, detail: "搜索失败：\(short(error))", seconds: elapsed())
            }
            await complete(id: source.bookSourceUrl, passed: false, started: started, collector: collector)
            return
        }
        guard let first = found.first else {
            await MainActor.run {
                update(source.bookSourceUrl, step: .failed, detail: "搜索无结果（关键字「\(key)」）", seconds: elapsed())
            }
            await complete(id: source.bookSourceUrl, passed: false, started: started, collector: collector)
            return
        }

        await MainActor.run {
            update(source.bookSourceUrl, step: .detail, detail: "搜到 \(found.count) 条：\(first.name)")
        }
        var book = Book(bookUrl: first.bookUrl, name: first.name, author: first.author, origin: "network")
        book.tocUrl = first.bookUrl
        let chapters: [BookChapter]
        do {
            let detail = try await BookContentService.shared.fetchBookDetail(
                book: book,
                source: source,
                diagnostics: { collector.append($0) }
            )
            book = detail.book
            chapters = detail.chapters
        } catch {
            await MainActor.run {
                update(source.bookSourceUrl, step: .failed, detail: "详情失败：\(short(error))", seconds: elapsed())
            }
            await complete(id: source.bookSourceUrl, passed: false, started: started, collector: collector)
            return
        }
        guard !chapters.isEmpty else {
            await MainActor.run {
                update(source.bookSourceUrl, step: .failed, detail: "目录为空", seconds: elapsed())
            }
            await complete(id: source.bookSourceUrl, passed: false, started: started, collector: collector)
            return
        }

        await MainActor.run { update(source.bookSourceUrl, step: .toc, detail: "目录 \(chapters.count) 章") }
        var firstChapter = chapters[0]
        firstChapter.index = 0
        do {
            let content = try await BookContentService.shared.fetchChapterContent(
                chapter: firstChapter,
                source: source,
                book: book,
                diagnostics: { collector.append($0) }
            )
            let length = content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).count
            let passed = length > 40
            await MainActor.run {
                update(source.bookSourceUrl,
                       step: passed ? .passed : .failed,
                       detail: passed ? "目录 \(chapters.count) 章 · 正文 \(length) 字" : "正文太短（\(length) 字）",
                       seconds: elapsed())
            }
            await complete(id: source.bookSourceUrl, passed: passed, started: started, collector: collector)
        } catch {
            await MainActor.run {
                update(source.bookSourceUrl, step: .failed, detail: "正文失败：\(short(error))", seconds: elapsed())
            }
            await complete(id: source.bookSourceUrl, passed: false, started: started, collector: collector)
        }
    }

    private func complete(
        id: String,
        passed: Bool,
        started: Date,
        collector: DiagnosticCollector
    ) async {
        let diagnostics = collector.all
        await MainActor.run {
            if let index = rows.firstIndex(where: { $0.id == id }) {
                rows[index].diagnostics = diagnostics
            }
            finish(id: id, passed: passed, started: started, diagnostics: diagnostics)
        }
    }

    private func short(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }
}
