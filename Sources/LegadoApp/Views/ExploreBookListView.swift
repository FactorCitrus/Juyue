import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

public struct ExploreBookListView: View {
    let source: BookSource
    let category: ExploreCategory

    @State private var books: [SearchBook] = []
    @State private var currentPage: Int = 1
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var hasMore: Bool = true
    @State private var errorMessage: String? = nil
    @State private var selectedBookForDetail: SearchBook? = nil

    public init(source: BookSource, category: ExploreCategory) {
        self.source = source
        self.category = category
    }

    public var body: some View {
        Group {
            if isLoading && books.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载「\(category.title)」书籍...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, books.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("加载失败")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("重试") {
                        loadBooks(page: 1)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if books.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "books.vertical")
                        .font(.largeTitle)
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("暂无书籍")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(books) { book in
                        SearchResultRow(item: book)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedBookForDetail = book
                            }
                            .onAppear {
                                if book.id == books.last?.id && hasMore && !isLoadingMore {
                                    loadMore()
                                }
                            }
                    }

                    if hasMore {
                        HStack {
                            Spacer()
                            if isLoadingMore {
                                ProgressView()
                                    .padding(.trailing, 6)
                                Text("正在加载下一页...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Button("点击加载更多") {
                                    loadMore()
                                }
                                .font(.caption)
                                .foregroundColor(.blue)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
                #if os(iOS)
                .listStyle(.plain)
                #endif
                .refreshable {
                    await refresh()
                }
            }
        }
        .navigationTitle(category.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(
            NavigationLink(
                isActive: Binding(
                    get: { selectedBookForDetail != nil },
                    set: { if !$0 { selectedBookForDetail = nil } }
                ),
                destination: {
                    if let b = selectedBookForDetail {
                        BookDetailView(searchBook: b, source: source)
                    } else {
                        EmptyView()
                    }
                },
                label: { EmptyView() }
            )
            .hidden()
        )
        .onAppear {
            if books.isEmpty {
                loadBooks(page: 1)
            }
        }
    }

    private func loadBooks(page: Int) {
        guard let rawUrl = category.url, !rawUrl.isEmpty else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let fetched = try await BookExploreService.shared.fetchExploreBooks(source: source, categoryUrl: rawUrl, page: page)
                await MainActor.run {
                    self.currentPage = page
                    self.books = fetched
                    self.isLoading = false
                    self.hasMore = !fetched.isEmpty
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func loadMore() {
        guard !isLoadingMore, hasMore, let rawUrl = category.url, !rawUrl.isEmpty else { return }
        isLoadingMore = true
        let nextPage = currentPage + 1

        Task {
            do {
                let fetched = try await BookExploreService.shared.fetchExploreBooks(source: source, categoryUrl: rawUrl, page: nextPage)
                await MainActor.run {
                    self.currentPage = nextPage
                    if fetched.isEmpty {
                        self.hasMore = false
                    } else {
                        // Avoid duplicates
                        let existingUrls = Set(self.books.map { $0.bookUrl })
                        let newItems = fetched.filter { !existingUrls.contains($0.bookUrl) }
                        if newItems.isEmpty {
                            self.hasMore = false
                        } else {
                            self.books.append(contentsOf: newItems)
                        }
                    }
                    self.isLoadingMore = false
                }
            } catch {
                await MainActor.run {
                    self.isLoadingMore = false
                }
            }
        }
    }

    private func refresh() async {
        guard let rawUrl = category.url, !rawUrl.isEmpty else { return }
        do {
            let fetched = try await BookExploreService.shared.fetchExploreBooks(source: source, categoryUrl: rawUrl, page: 1)
            await MainActor.run {
                self.currentPage = 1
                self.books = fetched
                self.hasMore = !fetched.isEmpty
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
