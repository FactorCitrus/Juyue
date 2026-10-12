import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public struct CategoryExploreView: View {
    @ObservedObject var bookStore = BookStore.shared

    @State private var selectedSourceUrl: String = ""
    @State private var categories: [ExploreCategory] = []
    @State private var selectedCategory: ExploreCategory? = nil

    @State private var books: [SearchBook] = []
    @State private var currentPage: Int = 1
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var hasMore: Bool = true
    @State private var errorMessage: String? = nil

    @State private var showAllCategoriesSheet: Bool = false
    @State private var selectedBookForDetail: SearchBook? = nil

    public init() {}

    /// Sources that are enabled and have exploreUrl configured
    private var availableSources: [BookSource] {
        bookStore.sources.filter { source in
            (source.enabled ?? true) &&
            source.exploreUrl != nil &&
            !(source.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    private var currentSource: BookSource? {
        availableSources.first(where: { $0.bookSourceUrl == selectedSourceUrl }) ?? availableSources.first
    }

    /// Actionable categories (excluding section headers)
    private var actionableCategories: [ExploreCategory] {
        categories.filter { !$0.isHeader && $0.url != nil && !$0.url!.isEmpty }
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if availableSources.isEmpty {
                    emptySourcesView
                } else {
                    // Level 1: Book Source Switcher (Fast Pill Selector)
                    if availableSources.count > 1 {
                        sourceSwitcherBar
                    }

                    // Level 2: Preset Category Quick Bar
                    if !actionableCategories.isEmpty {
                        categoryQuickBar
                    }

                    Divider()

                    // Level 3: Category Book Content Stream
                    mainContentView
                }
            }
            .navigationTitle("分类")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if currentSource != nil && selectedCategory != nil {
                        Button(action: { Task { await refresh() } }) {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .sheet(isPresented: $showAllCategoriesSheet) {
                allCategoriesSheet
            }
            .background(
                NavigationLink(
                    isActive: Binding(
                        get: { selectedBookForDetail != nil },
                        set: { if !$0 { selectedBookForDetail = nil } }
                    ),
                    destination: {
                        if let b = selectedBookForDetail {
                            BookDetailView(searchBook: b, source: currentSource)
                        } else {
                            EmptyView()
                        }
                    },
                    label: { EmptyView() }
                )
                .hidden()
            )
            .onAppear {
                initializeIfNeeded()
            }
        }
    }

    // MARK: - Level 1: Source Switcher Bar
    private var sourceSwitcherBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableSources) { src in
                    let isSelected = src.bookSourceUrl == currentSource?.bookSourceUrl
                    Button {
                        if src.bookSourceUrl != currentSource?.bookSourceUrl {
                            switchSource(to: src)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "globe")
                                .font(.system(size: 11))
                            Text(src.bookSourceName)
                                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                        .foregroundColor(isSelected ? .white : .primary)
                        .cornerRadius(16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(switcherBackgroundColor)
    }

    private var switcherBackgroundColor: Color {
        #if canImport(UIKit)
        return Color(UIColor.secondarySystemBackground).opacity(0.5)
        #elseif canImport(AppKit)
        return Color(NSColor.controlBackgroundColor).opacity(0.5)
        #else
        return Color.secondary.opacity(0.1)
        #endif
    }

    // MARK: - Level 2: Category Quick Bar
    private var categoryQuickBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(actionableCategories) { cat in
                        let isSelected = cat.id == selectedCategory?.id
                        Button {
                            if cat.id != selectedCategory?.id {
                                selectCategory(cat)
                            }
                        } label: {
                            Text(cat.title)
                                .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isSelected ? Color.blue.opacity(0.15) : Color.clear)
                                .foregroundColor(isSelected ? .blue : .secondary)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            // Button to open full category matrix/modal
            Button {
                showAllCategoriesSheet = true
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .background(barBackgroundColor)
    }

    private var barBackgroundColor: Color {
        #if canImport(UIKit)
        return Color(UIColor.systemBackground)
        #elseif canImport(AppKit)
        return Color(NSColor.windowBackgroundColor)
        #else
        return Color.white
        #endif
    }

    // MARK: - Level 3: Main Book Content Stream
    @ViewBuilder
    private var mainContentView: some View {
        if isLoading && books.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在加载「\(selectedCategory?.title ?? "")」内容...")
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
                    if let cat = selectedCategory {
                        loadBooks(for: cat, page: 1)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if books.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.largeTitle)
                    .foregroundColor(.secondary.opacity(0.6))
                Text("该分类暂无书籍")
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

    private var emptySourcesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text("暂无可用分类书源")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("请在「设置 - 书源管理」中导入并启用支持预设分类的书源（如示例书源、示例书源）")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - All Categories Sheet (Grouped by Header)
    private var allCategoriesSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let groups = groupCategories(categories)
                    ForEach(groups, id: \.header) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            if !group.header.isEmpty {
                                Text(group.header)
                                    .font(.subheadline.bold())
                                    .foregroundColor(.secondary)
                            }

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 85), spacing: 8)], spacing: 8) {
                                ForEach(group.items) { item in
                                    let isSelected = item.id == selectedCategory?.id
                                    Button {
                                        showAllCategoriesSheet = false
                                        selectCategory(item)
                                    } label: {
                                        Text(item.title)
                                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .padding(.horizontal, 6)
                                            .background(isSelected ? Color.blue : Color.secondary.opacity(0.12))
                                            .foregroundColor(isSelected ? .white : .primary)
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("全部预设分类")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showAllCategoriesSheet = false }
                }
            }
        }
    }

    // MARK: - Logic & Actions
    private func initializeIfNeeded() {
        if currentSource == nil && !availableSources.isEmpty {
            selectedSourceUrl = availableSources[0].bookSourceUrl
        }
        if let src = currentSource, categories.isEmpty {
            loadCategories(for: src)
        }
    }

    private func switchSource(to source: BookSource) {
        selectedSourceUrl = source.bookSourceUrl
        books = []
        selectedCategory = nil
        loadCategories(for: source)
    }

    private func loadCategories(for source: BookSource) {
        let cats = BookExploreService.shared.parseExploreCategories(source: source)
        self.categories = cats

        // Prefer selecting "全部" as initial category so public books load immediately; presets like 阅读历史 remain available in the top bar
        if let allCategory = cats.first(where: { $0.title == "全部" && $0.url != nil && !$0.url!.isEmpty }) {
            selectCategory(allCategory)
        } else if let firstActionable = cats.first(where: { !$0.isHeader && $0.url != nil && !$0.url!.isEmpty }) {
            selectCategory(firstActionable)
        } else {
            selectedCategory = nil
            books = []
        }
    }

    private func selectCategory(_ category: ExploreCategory) {
        selectedCategory = category
        books = []
        currentPage = 1
        hasMore = true
        loadBooks(for: category, page: 1)
    }

    private func loadBooks(for category: ExploreCategory, page: Int) {
        guard let src = currentSource, let rawUrl = category.url, !rawUrl.isEmpty else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let fetched = try await BookExploreService.shared.fetchExploreBooks(source: src, categoryUrl: rawUrl, page: page)
                await MainActor.run {
                    self.currentPage = page
                    self.books = fetched
                    self.isLoading = false
                    self.hasMore = !fetched.isEmpty
                }
            } catch {
                await MainActor.run {
                    if error.localizedDescription.contains("403") {
                        self.errorMessage = "请先在书源管理中登录该书源账号以同步查看「\(category.title)」"
                    } else {
                        self.errorMessage = error.localizedDescription
                    }
                    self.isLoading = false
                }
            }
        }
    }

    private func loadMore() {
        guard !isLoadingMore, hasMore, let src = currentSource, let cat = selectedCategory, let rawUrl = cat.url, !rawUrl.isEmpty else { return }
        isLoadingMore = true
        let nextPage = currentPage + 1

        Task {
            do {
                let fetched = try await BookExploreService.shared.fetchExploreBooks(source: src, categoryUrl: rawUrl, page: nextPage)
                await MainActor.run {
                    self.currentPage = nextPage
                    if fetched.isEmpty {
                        self.hasMore = false
                    } else {
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
        guard let src = currentSource, let cat = selectedCategory, let rawUrl = cat.url, !rawUrl.isEmpty else { return }
        do {
            let fetched = try await BookExploreService.shared.fetchExploreBooks(source: src, categoryUrl: rawUrl, page: 1)
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

    // MARK: - Category Grouping Helper
    private struct CategoryGroup {
        let header: String
        let items: [ExploreCategory]
    }

    private func groupCategories(_ list: [ExploreCategory]) -> [CategoryGroup] {
        var groups: [CategoryGroup] = []
        var currentHeader: String = ""
        var currentItems: [ExploreCategory] = []

        for cat in list {
            if cat.isHeader {
                if !currentItems.isEmpty {
                    groups.append(CategoryGroup(header: currentHeader, items: currentItems))
                    currentItems = []
                }
                currentHeader = cat.title
            } else {
                currentItems.append(cat)
            }
        }

        if !currentItems.isEmpty {
            groups.append(CategoryGroup(header: currentHeader, items: currentItems))
        }

        return groups
    }
}
