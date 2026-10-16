import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 阅读中点「换源」调出来的候选列表：拿书名/作者去所有启用的书源搜一遍。
public struct SourceSwitchSheet: View {
    let book: Book
    let currentSourceUrl: String?
    let onSelect: (BookSource, SearchBook) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bookStore = BookStore.shared

    /// 匹配口径与展示偏好记住，下次换源沿用；关键词、限定源是临时的
    @AppStorage("switch_source_match_title") private var matchTitle: Bool = true
    @AppStorage("switch_source_match_author") private var matchAuthor: Bool = false
    @AppStorage("switch_source_exact") private var exactMatch: Bool = false
    @AppStorage("switch_source_show_detail") private var showDetail: Bool = true

    /// 搜回来的原始候选，按当前口径就地筛，改开关不用重搜
    @State private var rawResults: [(source: BookSource, book: SearchBook)] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var finishedSources = 0
    @State private var totalSources = 0
    @State private var errorMessage: String?
    @State private var keyword: String
    @State private var sourceFilter: String = ""
    /// 搜索条件默认收起，换源时先看候选；收起状态是临时的，每次打开都收着
    @State private var showSearchOptions = false

    public init(
        book: Book,
        currentSourceUrl: String?,
        onSelect: @escaping (BookSource, SearchBook) -> Void
    ) {
        self.book = book
        self.currentSourceUrl = currentSourceUrl
        self.onSelect = onSelect
        // 名字特别短的书（「家」「序」这种）按书名搜全是噪音，默认用作者当关键词
        let shortTitle = book.name.trimmingCharacters(in: .whitespaces).count <= 2
        self._keyword = State(initialValue: (shortTitle && !book.author.isEmpty) ? book.author : book.name)
    }

    private var options: SourceMatchOptions {
        SourceMatchOptions(matchTitle: matchTitle, matchAuthor: matchAuthor, exact: exactMatch)
    }

    private var results: [(source: BookSource, book: SearchBook)] {
        rawResults.filter {
            SourceMatchRules.matches($0.book, title: book.name, author: book.author, options: options)
        }
    }

    /// 给提示用：现在是按什么口径筛的
    private var criteriaText: String {
        var fields: [String] = []
        if matchTitle { fields.append("书名") }
        if matchAuthor { fields.append("作者") }
        let fieldText = fields.isEmpty ? "未选字段" : fields.joined(separator: "+")
        return "\(fieldText)·\(exactMatch ? "精确" : "包含")"
    }

    public var body: some View {
        // A NavigationView here turns the sheet into a sidebar + empty detail pane on
        // macOS, which renders as a black panel with an unusable list. Use one column.
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("换源")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    searchTask?.cancel()
                    dismiss()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.name)
                            .font(.headline)
                        Text("当前书源：\(book.originName.isEmpty ? "未知" : book.originName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if !book.author.isEmpty {
                            Text("作者：\(book.author)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: $showSearchOptions) {
                        // 选中的字段是 AND：书名和作者都开，就两个都要中，同名不同作者的书不会混进来
                        Toggle("匹配书名", isOn: $matchTitle)
                        Toggle("匹配作者", isOn: $matchAuthor)
                        Toggle("精确匹配", isOn: $exactMatch)
                        if !matchTitle && !matchAuthor {
                            Text("至少选一个匹配字段，否则没法判断是不是同一本书。")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }

                        HStack {
                            Text("关键词")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(width: 52, alignment: .leading)
                            PlaceholderField(placeholder: "要搜的内容", text: $keyword)
                            Button("搜索") { startSearch() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty || (!matchTitle && !matchAuthor))
                        }

                        HStack {
                            Text("限定源")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(width: 52, alignment: .leading)
                            PlaceholderField(placeholder: "只搜名称 / 分组里含这几个字的源", text: $sourceFilter)
                        }

                        Toggle("显示书籍详情", isOn: $showDetail)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("搜索条件")
                            // 收起时也得看得出现在是按什么口径搜的
                            Text("\(criteriaText) · 关键词「\(keyword)」")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                if isSearching {
                    Section {
                        HStack {
                            ProgressView()
                            Text("正在搜索其他书源…（\(finishedSources)/\(totalSources)）")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                if !results.isEmpty {
                    Section(header: Text("可用书源 (\(results.count))")) {
                        ForEach(results, id: \.book.id) { item in
                            Button {
                                onSelect(item.source, item.book)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.book.name)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundColor(.primary)
                                            .lineLimit(2)
                                        Spacer()
                                        // 只有「现在这本、在当前源上」才算「当前」，同一个源里的别的书不算
                                        if item.source.bookSourceUrl == currentSourceUrl,
                                           item.book.bookUrl == book.bookUrl {
                                            Text("当前")
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.15))
                                                .cornerRadius(4)
                                        }
                                    }

                                    Text("来源：\(item.source.bookSourceName)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    if showDetail {
                                        if !item.book.author.isEmpty {
                                            Text("作者：\(item.book.author)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        let meta = [item.book.kind, item.book.wordCount]
                                            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                                            .filter { !$0.isEmpty }
                                        if !meta.isEmpty {
                                            Text(meta.joined(separator: " · "))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if let latest = item.book.latestChapterTitle, !latest.isEmpty {
                                            Text("最新：\(latest)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                        if let intro = item.book.intro, !intro.isEmpty {
                                            Text(intro)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if !isSearching {
                    Section {
                        if rawResults.isEmpty {
                            Text("没有在其他书源找到这本书。换个匹配方式或关键词再试。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("搜到 \(rawResults.count) 条，但都不符合当前口径（\(criteriaText)）。放开字段或关掉精确匹配再试。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
        .task {
            startSearch()
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func startSearch() {
        searchTask?.cancel()
        rawResults = []
        errorMessage = nil
        finishedSources = 0

        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmedKeyword.isEmpty else {
            isSearching = false
            errorMessage = "先填关键词。"
            return
        }
        guard matchTitle || matchAuthor else {
            isSearching = false
            errorMessage = "先选一个匹配字段。"
            return
        }

        let filter = sourceFilter.trimmingCharacters(in: .whitespaces).lowercased()
        var sources = bookStore.sources.filter { $0.enabled != false }
        if !filter.isEmpty {
            sources = sources.filter {
                $0.bookSourceName.lowercased().contains(filter)
                    || ($0.bookSourceGroup ?? "").lowercased().contains(filter)
            }
        }
        totalSources = sources.count
        isSearching = !sources.isEmpty
        guard !sources.isEmpty else {
            errorMessage = filter.isEmpty
                ? "没有启用的书源，先去设置里导入。"
                : "没有符合「\(sourceFilter)」的书源。"
            return
        }

        let requestKey = requestKeyword(from: trimmedKeyword)

        searchTask = Task {
            let stream = BookSearchService.shared.searchMultiSources(sources: sources, key: requestKey, page: 1)
            for await (source, books) in stream {
                if Task.isCancelled { return }
                await MainActor.run {
                    finishedSources += 1
                    // 原样收着，展示时按当前口径筛（改开关不用重新搜一遍）
                    for candidate in books {
                        if !rawResults.contains(where: { $0.book.bookUrl == candidate.bookUrl }) {
                            rawResults.append((source: source, book: candidate))
                        }
                    }
                }
            }
            await MainActor.run {
                isSearching = false
            }
        }
    }

    /// 搜索接口一般只认书名，带空格的关键词取最长的那一段去请求
    private func requestKeyword(from raw: String) -> String {
        let parts = raw.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return parts.max(by: { $0.count < $1.count }) ?? raw
    }

}
