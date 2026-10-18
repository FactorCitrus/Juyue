import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 书源校验：逐源跑一遍「搜索 → 详情 → 目录 → 正文」，报出每一步的结果与耗时。
///
/// 校验只读：不落库、不改书源，搜到的第一本书只用来当靶子。
struct SourceCheckView: View {
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
    }

    @State private var keyword = "小说"
    @State private var rows: [Row] = []
    @State private var running = false
    @State private var stopRequested = false
    @State private var selectMode = false
    @State private var selected: Set<String> = []

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
                Text("逐个检测书源可用性：搜索、详情、目录、正文各跑一遍，只读不改书源。源多时慢一点，可以中途停止。")
            }

            Section(header: Text("结果（\(passedCount)/\(rows.count) 通过）")) {
                if selectMode {
                    HStack {
                        Button("全选失败") {
                            selected = Set(rows.filter { $0.step == .failed }.map(\.id))
                        }
                        Spacer()
                        Text("已选 \(selected.count)")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("重试") {
                            retrySelected()
                        }
                        .disabled(selected.isEmpty || running)
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
                                Text(row.step.rawValue)
                                    .font(.system(size: 11))
                                    .foregroundColor(color(for: row.step))
                                if row.seconds > 0 {
                                    Text(String(format: "%.1fs", row.seconds))
                                        .font(.system(size: 11, design: .rounded))
                                        .foregroundColor(.secondary)
                                }
                            }
                            if !row.detail.isEmpty {
                                Text(row.detail)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
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
            if rows.isEmpty {
                rows = store.sources
                    .filter { $0.enabled ?? true }
                    .map { Row(id: $0.bookSourceUrl, name: $0.bookSourceName) }
            }
        }
    }

    private var passedCount: Int {
        rows.filter { $0.step == .passed }.count
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
        func elapsed() -> Double { Date().timeIntervalSince(started) }

        await MainActor.run { update(source.bookSourceUrl, step: .searching, detail: "", seconds: 0) }
        let found: [SearchBook]
        do {
            found = try await BookSearchService.shared.search(source: source, key: key)
        } catch {
            await MainActor.run {
                update(source.bookSourceUrl, step: .failed, detail: "搜索失败：\(short(error))", seconds: elapsed())
            }
            return
        }
        guard let first = found.first else {
            await MainActor.run {
                update(source.bookSourceUrl, step: .failed, detail: "搜索无结果（关键字「\(key)」）", seconds: elapsed())
            }
            return
        }

        await MainActor.run {
            update(source.bookSourceUrl, step: .detail, detail: "搜到 \(found.count) 条：\(first.name)")
        }
        var book = Book(bookUrl: first.bookUrl, name: first.name, author: first.author, origin: "network")
        book.tocUrl = first.bookUrl
        let chapters: [BookChapter]
        do {
            let detail = try await BookContentService.shared.fetchBookDetail(book: book, source: source)
            book = detail.book
            chapters = detail.chapters
        } catch {
            await MainActor.run {
                update(source.bookSourceUrl, step: .failed, detail: "详情失败：\(short(error))", seconds: elapsed())
            }
            return
        }
        guard !chapters.isEmpty else {
            await MainActor.run {
                update(source.bookSourceUrl, step: .failed, detail: "目录为空", seconds: elapsed())
            }
            return
        }

        await MainActor.run { update(source.bookSourceUrl, step: .toc, detail: "目录 \(chapters.count) 章") }
        var firstChapter = chapters[0]
        firstChapter.index = 0
        do {
            let content = try await BookContentService.shared.fetchChapterContent(
                chapter: firstChapter, source: source, book: book
            )
            let length = content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).count
            await MainActor.run {
                update(source.bookSourceUrl,
                       step: length > 40 ? .passed : .failed,
                       detail: length > 40 ? "目录 \(chapters.count) 章 · 正文 \(length) 字" : "正文太短（\(length) 字）",
                       seconds: elapsed())
            }
        } catch {
            await MainActor.run {
                update(source.bookSourceUrl, step: .failed, detail: "正文失败：\(short(error))", seconds: elapsed())
            }
        }
    }

    private func short(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }
}
