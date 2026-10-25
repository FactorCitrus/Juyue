import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

// MARK: - 分页状态机

/// 探索分类的分页状态机。
///
/// 首屏、下拉刷新、触底续拉共用 `fetch(page:mode:)` 一条路径，只在收尾时按 `mode` 决定
/// 是替换列表还是追加。触底遇到整页旧条目就收手——翻页参数没生效的站点会一直回同一页，
/// 不设这个出口会无限请求。
@MainActor
final class ExploreFeedModel: ObservableObject {
    enum Mode {
        case firstPage
        case nextPage
    }

    @Published private(set) var books: [SearchBook] = []
    @Published private(set) var failureText: String?
    @Published private(set) var isFetchingFirstPage = false
    @Published private(set) var isFetchingNextPage = false
    @Published private(set) var reachedEnd = false

    private let source: BookSource
    private let categoryUrl: String?
    private var loadedPage = 0
    private var knownBookUrls = Set<String>()

    init(source: BookSource, category: ExploreCategory) {
        self.source = source
        self.categoryUrl = category.url
    }

    var isEmpty: Bool { books.isEmpty }

    /// 分类条目可能是一段 `{java.startBrowser(...)}`，没有可抓的网址。
    var canFetch: Bool {
        guard let raw = categoryUrl else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func loadFirstPage() async {
        guard canFetch, isFetchingFirstPage == false else { return }
        await fetch(page: 1, mode: .firstPage)
    }

    func refresh() async {
        guard canFetch, isFetchingFirstPage == false else { return }
        await fetch(page: 1, mode: .firstPage)
    }

    func loadNextPage() async {
        guard canFetch, reachedEnd == false, isFetchingNextPage == false, isEmpty == false else { return }
        await fetch(page: loadedPage + 1, mode: .nextPage)
    }

    private func fetch(page: Int, mode: Mode) async {
        guard let raw = categoryUrl, canFetch else { return }
        switch mode {
        case .firstPage: isFetchingFirstPage = true
        case .nextPage: isFetchingNextPage = true
        }
        failureText = nil
        defer {
            isFetchingFirstPage = false
            isFetchingNextPage = false
        }

        do {
            let pageBooks = try await BookExploreService.shared.fetchExploreBooks(
                source: source,
                categoryUrl: raw,
                page: page
            )
            absorb(pageBooks, page: page, mode: mode)
        } catch {
            failureText = error.localizedDescription
        }
    }

    private func absorb(_ incoming: [SearchBook], page: Int, mode: Mode) {
        loadedPage = page

        guard mode == .nextPage else {
            knownBookUrls = Set(incoming.map { $0.bookUrl })
            books = incoming
            reachedEnd = incoming.isEmpty
            return
        }

        guard incoming.isEmpty == false else {
            reachedEnd = true
            return
        }

        let unseen = incoming.filter { knownBookUrls.insert($0.bookUrl).inserted }
        if unseen.isEmpty {
            reachedEnd = true
        } else {
            books.append(contentsOf: unseen)
        }
    }
}

// MARK: - 视图

public struct ExploreBookListView: View {
    private let source: BookSource
    private let category: ExploreCategory

    @StateObject private var feed: ExploreFeedModel
    @State private var pendingBook: SearchBook?
    @State private var didAutoLoad = false

    public init(source: BookSource, category: ExploreCategory) {
        self.source = source
        self.category = category
        _feed = StateObject(wrappedValue: ExploreFeedModel(source: source, category: category))
    }

    public var body: some View {
        Group {
            if feed.isEmpty {
                placeholder
            } else {
                bookList
            }
        }
        .navigationTitle(category.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(detailPushLink)
        .onAppear(perform: autoLoadOnce)
    }

    // 动作类分类取不到书，自动触发只会反复弹登录页。
    private func autoLoadOnce() {
        guard didAutoLoad == false else { return }
        didAutoLoad = true
        guard category.isAction == false else { return }
        Task { await feed.loadFirstPage() }
    }

    @ViewBuilder
    private var placeholder: some View {
        if feed.isFetchingFirstPage {
            statusPanel(spacing: 12) {
                ProgressView()
                Text("正在加载「\(category.title)」书籍...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        } else if let failureText = feed.failureText {
            statusPanel(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text("加载失败")
                    .font(.headline)
                Text(failureText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("重试") {
                    Task { await feed.refresh() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            statusPanel(spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.largeTitle)
                    .foregroundColor(.secondary.opacity(0.6))
                Text("暂无书籍")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var bookList: some View {
        List {
            ForEach(feed.books) { book in
                SearchResultRow(item: book)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        pendingBook = book
                    }
                    .onAppear {
                        guard book.bookUrl == feed.books.last?.bookUrl else { return }
                        Task { await feed.loadNextPage() }
                    }
            }

            if feed.reachedEnd == false {
                footer
            }
        }
        .appThemedList()
        #if os(iOS)
        .listStyle(.plain)
        #endif
        .refreshable {
            await feed.refresh()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if feed.isFetchingNextPage {
                ProgressView()
                    .padding(.trailing, 6)
                Text("正在加载下一页...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Button("点击加载更多") {
                    Task { await feed.loadNextPage() }
                }
                .font(.caption)
                .foregroundColor(.blue)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var detailPushLink: some View {
        NavigationLink(
            isActive: Binding(
                get: { pendingBook != nil },
                set: { if $0 == false { pendingBook = nil } }
            ),
            destination: {
                if let book = pendingBook {
                    BookDetailView(searchBook: book, source: source)
                } else {
                    EmptyView()
                }
            },
            label: { EmptyView() }
        )
        .hidden()
    }

    private func statusPanel<Content: View>(
        spacing: CGFloat,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(spacing: spacing, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
