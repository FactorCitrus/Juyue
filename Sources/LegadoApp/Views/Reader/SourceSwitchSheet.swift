import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 阅读中点「换源」调出来的候选列表：拿书名去所有启用的书源搜一遍。
public struct SourceSwitchSheet: View {
    let book: Book
    let currentSourceUrl: String?
    let onSelect: (BookSource, SearchBook) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bookStore = BookStore.shared

    @State private var results: [(source: BookSource, book: SearchBook)] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var finishedSources = 0
    @State private var totalSources = 0
    @State private var errorMessage: String?

    public init(
        book: Book,
        currentSourceUrl: String?,
        onSelect: @escaping (BookSource, SearchBook) -> Void
    ) {
        self.book = book
        self.currentSourceUrl = currentSourceUrl
        self.onSelect = onSelect
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
                        Text("没有在其他书源找到这本书。")
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
        let sources = bookStore.sources.filter { $0.enabled != false }
        totalSources = sources.count
        finishedSources = 0
        isSearching = !sources.isEmpty
        guard !sources.isEmpty else {
            errorMessage = "没有启用的书源，先去设置里导入。"
            return
        }

        searchTask = Task {
            let stream = BookSearchService.shared.searchMultiSources(sources: sources, key: book.name, page: 1)
            for await (source, books) in stream {
                if Task.isCancelled { return }
                await MainActor.run {
                    finishedSources += 1
                    // 只收书名对得上的，避免把同名不同书塞进来
                    let matched = books.filter { $0.name.contains(book.name) || book.name.contains($0.name) }
                    for candidate in matched {
                        if !results.contains(where: { $0.book.bookUrl == candidate.bookUrl }) {
                            results.append((source: source, book: candidate))
                        }
                    }
                }
            }
            await MainActor.run {
                isSearching = false
            }
        }
    }
}
