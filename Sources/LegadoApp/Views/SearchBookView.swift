import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

public struct SearchBookView: View {
    @ObservedObject var viewModel = SearchViewModel.shared
    @State private var selectedDetailBook: SearchBook? = nil

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索书名或作者...", text: $viewModel.searchQuery)
                    .onSubmit {
                        viewModel.startSearch()
                    }
                if !viewModel.searchQuery.isEmpty {
                    Button(action: {
                        viewModel.searchQuery = ""
                        viewModel.cancelAndReset()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
                Button("搜索") {
                    viewModel.startSearch()
                }
                .disabled(viewModel.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isSearching)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(10)
            .padding(.horizontal)
            .padding(.top, 8)

            // Source filter chips
            if !viewModel.availableSources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(
                            title: "全部书源 (\(viewModel.availableSources.count))",
                            isSelected: viewModel.selectedSourceUrl == nil
                        ) {
                            viewModel.selectedSourceUrl = nil
                            if !viewModel.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                                viewModel.startSearch()
                            }
                        }

                        ForEach(viewModel.availableSources) { source in
                            FilterChip(
                                title: source.bookSourceName,
                                isSelected: viewModel.selectedSourceUrl == source.bookSourceUrl
                            ) {
                                viewModel.selectedSourceUrl = source.bookSourceUrl
                                if !viewModel.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                                    viewModel.startSearch()
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }

            Divider()

            // Content area
            if viewModel.isSearching && viewModel.searchResults.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在搜索全网书籍 (第 1 页)...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if viewModel.searchResults.isEmpty && !viewModel.searchQuery.isEmpty && !viewModel.isSearching {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("未找到相关书籍")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("可尝试切换其他书源或更换关键词")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if viewModel.searchResults.isEmpty && viewModel.searchQuery.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("输入关键词开启全网搜索")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(viewModel.searchResults) { item in
                        SearchResultRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedDetailBook = item
                            }
                            .onAppear {
                                if viewModel.shouldAutoLoadMore(for: item) {
                                    viewModel.loadNextPage()
                                }
                            }
                    }

                    // List footer (loading / more / finished)
                    Section {
                        footerView
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("聚合搜索")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(
            // Programmatic navigation link outside List to avoid any row insertion or navigation reset
            NavigationLink(
                isActive: Binding(
                    get: { selectedDetailBook != nil },
                    set: { if !$0 { selectedDetailBook = nil } }
                ),
                destination: {
                    if let item = selectedDetailBook {
                        let source = BookStore.shared.sources.first(where: {
                            $0.bookSourceUrl == item.origin ||
                            $0.bookSourceName == item.originName ||
                            item.origin.contains($0.bookSourceUrl) ||
                            $0.bookSourceUrl.contains(item.origin)
                        })
                        BookDetailView(searchBook: item, source: source)
                    } else {
                        EmptyView()
                    }
                },
                label: { EmptyView() }
            )
            .hidden()
            .frame(width: 0, height: 0)
        )
    }

    // MARK: - Footer View

    @ViewBuilder
    private var footerView: some View {
        if viewModel.isLoadingMore {
            HStack(spacing: 8) {
                Spacer()
                ProgressView()
                Text("正在加载第 \(viewModel.currentPage + 1) 页...")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.vertical, 10)
        } else if viewModel.hasMore && !viewModel.searchResults.isEmpty {
            Button(action: {
                viewModel.loadNextPage()
            }) {
                HStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "arrow.clockwise")
                    Text("加载下一页 (第 \(viewModel.currentPage + 1) 页，已加载 \(viewModel.searchResults.count) 本)")
                    Spacer()
                }
                .font(.footnote)
                .foregroundColor(.accentColor)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        } else if !viewModel.hasMore && !viewModel.searchResults.isEmpty {
            HStack {
                Spacer()
                Text("— 已加载全部 \(viewModel.searchResults.count) 本书籍 —")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected ? .bold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SearchResultRow

public struct SearchResultRow: View {
    public let item: SearchBook

    public init(item: SearchBook) {
        self.item = item
    }

    private var cleanIntro: String? {
        guard let intro = item.intro, !intro.isEmpty else { return nil }
        let cleaned = BookContentService.cleanHtml(intro)
        if cleaned.hasPrefix("源站：") || cleaned.contains("最近同步：") {
            return nil
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Book cover image or fallback placeholder
            if let coverUrlStr = item.coverUrl, let url = URL(string: coverUrlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        coverPlaceholder
                    }
                }
                .frame(width: 52, height: 72)
                .cornerRadius(6)
                .clipped()
            } else {
                coverPlaceholder
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if !item.author.isEmpty && item.author != "未知作者" {
                        Text(item.author)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Text(item.originName)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)
                }

                if let kind = item.kind, !kind.isEmpty {
                    Text(kind.replacingOccurrences(of: ",", with: " · "))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if let intro = cleanIntro, !intro.isEmpty, !intro.hasPrefix("源站：") {
                    Text(intro)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(2)
                }

                if let latest = item.latestChapterTitle, !latest.isEmpty {
                    Text("最新: \(latest)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Chevron indicating navigation into detail page
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.vertical, 4)
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.12))
            .frame(width: 52, height: 72)
            .overlay(
                Image(systemName: "book.closed")
                    .foregroundColor(.accentColor)
            )
    }
}
