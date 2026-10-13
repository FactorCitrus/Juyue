import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 阅读中点「换源」调出来的候选列表：拿书名/作者去所有启用的书源搜一遍。
public struct SourceSwitchSheet: View {
    let book: Book
    let currentSourceUrl: String?
    let onSelect: (BookSource, SearchBook) -> Void

    /// 拿什么去搜：书名、作者，或者两个都要
    enum MatchMode: String, CaseIterable, Identifiable {
        case title = "书名"
        case author = "作者"
        case both = "书名+作者"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bookStore = BookStore.shared

    @State private var results: [(source: BookSource, book: SearchBook)] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var finishedSources = 0
    @State private var totalSources = 0
    @State private var errorMessage: String?
    @State private var hitNote: String?
    @State private var matchMode: MatchMode
    @State private var keyword: String
    @State private var sourceFilter: String = ""

    public init(
        book: Book,
        currentSourceUrl: String?,
        onSelect: @escaping (BookSource, SearchBook) -> Void
    ) {
        self.book = book
        self.currentSourceUrl = currentSourceUrl
        self.onSelect = onSelect
        // 名字特别短的书（「家」「序」这种）按书名搜全是噪音，默认改成按作者搜
        let shortTitle = book.name.trimmingCharacters(in: .whitespaces).count <= 2
        let initialMode: MatchMode = (shortTitle && !book.author.isEmpty) ? .author : .title
        self._matchMode = State(initialValue: initialMode)
        self._keyword = State(initialValue: initialMode == .author ? book.author : book.name)
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

                Section(header: Text("搜索条件")) {
                    Picker("匹配", selection: $matchMode) {
                        ForEach(MatchMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: matchMode) { newValue in
                        switch newValue {
                        case .title:
                            keyword = book.name
                        case .author:
                            keyword = book.author.isEmpty ? book.name : book.author
                        case .both:
                            keyword = book.author.isEmpty ? book.name : "\(book.name) \(book.author)"
                        }
                        startSearch()
                    }

                    HStack {
                        Text("关键词")
                            .frame(width: 52, alignment: .leading)
                        TextField("要搜的内容", text: $keyword)
                            #if os(iOS)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            #endif
                        Button("搜索") { startSearch() }
                            .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    HStack {
                        Text("限定源")
                            .frame(width: 52, alignment: .leading)
                        TextField("只搜名称 / 分组里含这几个字的源", text: $sourceFilter)
                            #if os(iOS)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            #endif
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

                if let hitNote {
                    Section {
                        Text(hitNote)
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                                        Text(item.source.bookSourceName)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundColor(.primary)
                                        Spacer()
                                        if item.source.bookSourceUrl == currentSourceUrl {
                                            Text("当前")
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.15))
                                                .cornerRadius(4)
                                        }
                                    }
                                    if !item.book.author.isEmpty {
                                        Text("作者：\(item.book.author)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if let latest = item.book.latestChapterTitle, !latest.isEmpty {
                                        Text("最新：\(latest)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                } else if !isSearching {
                    Section {
                        Text("没有在其他书源找到这本书。换个匹配方式或关键词再试。")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
        results = []
        errorMessage = nil
        hitNote = nil
        finishedSources = 0

        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmedKeyword.isEmpty else {
            isSearching = false
            errorMessage = "先填关键词。"
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
        let mode = matchMode
        let bookName = book.name
        let bookAuthor = book.author

        searchTask = Task {
            let stream = BookSearchService.shared.searchMultiSources(sources: sources, key: requestKey, page: 1)
            var mismatched = 0
            for await (source, books) in stream {
                if Task.isCancelled { return }
                await MainActor.run {
                    finishedSources += 1
                    // 按选中的口径过滤，避免同名不同书混进来
                    let matched = books.filter {
                        Self.matches($0, mode: mode, bookName: bookName, author: bookAuthor)
                    }
                    mismatched += books.count - matched.count
                    for candidate in matched {
                        if !results.contains(where: { $0.book.bookUrl == candidate.bookUrl }) {
                            results.append((source: source, book: candidate))
                        }
                    }
                }
            }
            await MainActor.run {
                isSearching = false
                if results.isEmpty, mismatched > 0 {
                    hitNote = "搜到 \(mismatched) 条，但都不符合「\(mode.rawValue)」的匹配口径。"
                }
            }
        }
    }

    /// 搜索接口一般只认书名，带空格的关键词取最长的那一段去请求
    private func requestKeyword(from raw: String) -> String {
        let parts = raw.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return parts.max(by: { $0.count < $1.count }) ?? raw
    }

    /// 按选中的口径判断这条结果算不算同一本书
    private static func matches(_ candidate: SearchBook, mode: MatchMode, bookName: String, author: String) -> Bool {
        let nameHit = !bookName.isEmpty
            && (candidate.name.contains(bookName) || bookName.contains(candidate.name))
        let authorHit = !author.isEmpty && !candidate.author.isEmpty
            && (candidate.author.contains(author) || author.contains(candidate.author))
        switch mode {
        case .title:
            return nameHit
        case .author:
            return authorHit
        case .both:
            return nameHit || authorHit
        }
    }
}
