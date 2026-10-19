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
    @Environment(\.appTheme) private var theme
    /// 书源脚本改完设置会调 `java.refreshExplore()`（安卓语义：刷新分类页），这里跟着重拉
    @ObservedObject private var exploreRefresh = ExploreRefreshCenter.shared

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
    @State private var showAllSourcesSheet: Bool = false
    @State private var showLoginSheet: Bool = false
    @State private var exploreFilters: [ExploreFilter] = []
    @State private var filterValues: [String: String] = [:]
    @State private var showFilterSheet: Bool = false
    @State private var sourceFilterText: String = ""
    @State private var selectedBookForDetail: SearchBook? = nil

    /// 这个页签是不是当前选中的。TabView 会把三个页签都建出来，
    /// 分类页一被建出来就联网拉书，会造成启动卡顿，
    /// 所以初始化要等它真的被选中。
    var isActive: Bool = true

    public init(isActive: Bool = true) {
        self.isActive = isActive
    }

    /// 可用书源，只在书源列表变化时刷新一次。
    /// 每次 body 求值都过滤一遍全部书源（含 trim）的开销按帧计算。
    @State private var cachedSources: [BookSource] = []

    private var availableSources: [BookSource] { cachedSources }

    private func refreshCachedSources(_ sources: [BookSource]) {
        cachedSources = sources.filter { source in
            guard source.enabled ?? true, let url = source.exploreUrl else { return false }
            // 用 allSatisfy 判断空白，避免 trim 里再分配一个 String
            return !url.isEmpty && !url.allSatisfy { $0.isWhitespace }
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
                    exploreHeader

                    // Level 1: Book Source Switcher (Fast Pill Selector)
                    if availableSources.count > 1 {
                        barLabel("SOURCE / 书源", trailing: "\(availableSources.count)")
                        sourceSwitcherBar
                    }

                    // Level 2: Preset Category Quick Bar
                    if !actionableCategories.isEmpty {
                        barLabel("CATEGORY / 分类", trailing: "\(actionableCategories.count)")
                        categoryQuickBar
                    }

                    if !exploreFilters.isEmpty {
                        filterBar
                    }

                    Divider()

                    // Level 3: Category Book Content Stream
                    mainContentView
                }
            }
            .background(theme.palette.background)
            .navigationTitle("分类")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if currentSource != nil && selectedCategory != nil {
                        // 分类页里刷新用处不大，换成搜索（直接搜书）
                        NavigationLink {
                            SearchBookView()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
            }
            .sheet(isPresented: $showAllCategoriesSheet) {
                allCategoriesSheet
            }
            .sheet(isPresented: $showAllSourcesSheet) {
                allSourcesSheet
            }
            .sheet(isPresented: $showLoginSheet) {
                if let src = currentSource {
                    SourceLoginSheet(source: src)
                }
            }
            .sheet(isPresented: $showFilterSheet) {
                ExploreFilterSheet(filters: exploreFilters, values: $filterValues) {
                    if let cat = selectedCategory {
                        loadBooks(for: cat, page: 1)
                    }
                }
            }
            .onChange(of: showLoginSheet) { showing in
                // 登录面板关掉就重试一次：登录成功的话这一栏就能看了
                guard !showing, let cat = selectedCategory else { return }
                loadBooks(for: cat, page: 1)
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
                refreshCachedSources(bookStore.sources)
                if isActive { initializeIfNeeded() }
            }
            .onChange(of: isActive) { active in
                if active { initializeIfNeeded() }
            }
            .onChange(of: exploreRefresh.tick) { _ in
                // 源变量变了解析缓存本来就会失效，这里负责让界面重新走一遍
                if let src = currentSource { loadCategories(for: src) }
            }
            .onReceive(bookStore.$sources) { sources in
                refreshCachedSources(sources)
            }
        }
    }

    // MARK: - Level 1: Source Switcher Bar
    private var exploreHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("EXPLORE / SOURCES")
                    .font(theme.typography.label)
                    .foregroundColor(theme.palette.secondaryInk)
                Spacer()
                Text("\(availableSources.count) SOURCES")
                    .font(theme.typography.mono)
                    .foregroundColor(theme.palette.secondaryInk)
            }

            HStack(alignment: .center) {
                Text("分类")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(theme.palette.ink)
                Spacer()
                NavigationLink {
                    SearchBookView()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(theme.palette.accent)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                Rectangle()
                    .fill(theme.palette.accent)
                    .frame(width: 24, height: 2)
                Rectangle()
                    .fill(theme.palette.divider.opacity(0.9))
                    .frame(height: 0.5)
                Rectangle()
                    .fill(theme.palette.ink.opacity(0.75))
                    .frame(width: 4, height: 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func barLabel(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title)
                .font(theme.typography.label)
                .foregroundColor(theme.palette.secondaryInk)
            Spacer()
            Text(trailing)
                .font(theme.typography.mono)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    /// 内联只画当前源 + 前面几个：可用书源有上千个，全塞进 HStack
    /// 一帧里建完按钮，点进分类就会卡一下
    private var inlineSources: [BookSource] {
        let limit = 10
        var list = Array(availableSources.prefix(limit))
        if let cur = currentSource, !list.contains(where: { $0.bookSourceUrl == cur.bookSourceUrl }) {
            list.insert(cur, at: 0)
            if list.count > limit { list.removeLast() }
        }
        return list
    }

    private var filteredSources: [BookSource] {
        let key = sourceFilterText.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return availableSources }
        return availableSources.filter { $0.bookSourceName.localizedCaseInsensitiveContains(key) }
    }

    private var sourceSwitcherBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // 用 HStack：LazyHStack 在横向 ScrollView 里只按提议宽度排版，
            // 后面的书源药丸会被裁掉、整条也会歪
            HStack(spacing: 8) {
                ForEach(inlineSources) { src in
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
                        .background(isSelected ? theme.palette.accent : theme.palette.elevated)
                        .foregroundColor(isSelected ? theme.palette.onAccent : theme.palette.ink)
                        .cornerRadius(theme.metrics.cornerRadius + 6)
                    }
                    .buttonStyle(.plain)
                }

                if availableSources.count > inlineSources.count {
                    Button {
                        showAllSourcesSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 11))
                            Text("全部书源 (\(availableSources.count))")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.palette.elevated)
                        .foregroundColor(theme.palette.ink)
                        .cornerRadius(theme.metrics.cornerRadius + 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(switcherBackgroundColor)
    }

    /// 全部书源：用 List（懒加载）挑，几千个也不卡
    private var allSourcesSheet: some View {
        NavigationView {
            List {
                ForEach(filteredSources) { src in
                    Button {
                        if src.bookSourceUrl != currentSource?.bookSourceUrl {
                            switchSource(to: src)
                        }
                        showAllSourcesSheet = false
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(src.bookSourceName)
                                    .font(.system(size: 15))
                                    .foregroundColor(.primary)
                                Text(src.bookSourceUrl)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if src.bookSourceUrl == currentSource?.bookSourceUrl {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
            .appThemedList()
            .searchable(text: $sourceFilterText, prompt: "搜书源名")
            .navigationTitle("全部书源 (\(availableSources.count))")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showAllSourcesSheet = false }
                }
            }
        }
    }

    private var switcherBackgroundColor: Color {
        theme.palette.surface
    }

    // MARK: - Level 2: Category Quick Bar
    private var categoryQuickBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 分类条目多的书源能有几十个，内联只画前 12 个，其余进「全部」
                    ForEach(Array(actionableCategories.prefix(12))) { cat in
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
                                .background(isSelected ? theme.palette.accent.opacity(0.15) : Color.clear)
                                .foregroundColor(isSelected ? theme.palette.accent : theme.palette.secondaryInk)
                                .cornerRadius(theme.metrics.cornerRadius)
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
        theme.palette.surface
    }

    // MARK: - 发现筛选（exploreScreen）

    /// 选中的筛选项作为查询参数追加到分类 URL。点开面板才修改，应用后重拉第一页。
    private var filterBar: some View {
        HStack(spacing: 8) {
            Button {
                showFilterSheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text("筛选")
                    let active = filterValues.values.filter { !$0.isEmpty }.count
                    if active > 0 {
                        Text("\(active)")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(theme.palette.accent)
                            .foregroundColor(theme.palette.onAccent)
                            .clipShape(Capsule())
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.palette.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.palette.accent.opacity(0.12))
                .cornerRadius(theme.metrics.cornerRadius)
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(exploreFilters) { filter in
                        if let value = filterValues[filter.name], !value.isEmpty {
                            Text("\(filter.name)：\(value)")
                                .font(.system(size: 11))
                                .foregroundColor(theme.palette.secondaryInk)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(theme.palette.elevated)
                                .cornerRadius(theme.metrics.cornerRadius + 2)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(barBackgroundColor)
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
                // 401/403 一般是这个分类要登录，附带一个不用登录也能看的分类
                if isAuthError(error), let publicCategory {
                    Text("这个分类要登录这个书源才能看。登录完再回来这句就不见了。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    if currentSource?.loginUrl?.isEmpty == false || currentSource?.loginUi?.isEmpty == false {
                        Button("登录「\(currentSource?.bookSourceName ?? "")」") {
                            showLoginSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        Button("先看「\(publicCategory.title)」") {
                            selectCategory(publicCategory)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("切到「\(publicCategory.title)」") {
                            selectCategory(publicCategory)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("重试") {
                        if let cat = selectedCategory {
                            loadBooks(for: cat, page: 1)
                        }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("重试") {
                        if let cat = selectedCategory {
                            loadBooks(for: cat, page: 1)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if books.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.largeTitle)
                    .foregroundColor(.secondary.opacity(0.6))
                Text("这个分类还没有书")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                    categoryRow(book, index: index)
                        .listRowSeparator(.hidden)
                        .listRowBackground(theme.palette.surface)
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
            .appThemedList()
            #if os(iOS)
            .listStyle(.plain)
            #endif
            .refreshable {
                await refresh()
            }
        }
    }

    private func categoryRow(_ book: SearchBook, index: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(theme.typography.mono)
                .foregroundColor(theme.palette.secondaryInk)
                .padding(.top, 4)

            Group {
                if book.coverUrl != nil {
                    BookCoverImage(
                        urlString: book.coverUrl,
                        placeholderOverride: AnyView(categoryCoverPlaceholder)
                    )
                } else {
                    categoryCoverPlaceholder
                }
            }
            .frame(width: 46, height: 62)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: max(4, theme.metrics.cornerRadius - 3), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: max(4, theme.metrics.cornerRadius - 3), style: .continuous)
                    .stroke(theme.palette.divider.opacity(0.5), lineWidth: theme.metrics.borderWidth)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(book.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.palette.ink)
                    .lineLimit(2)

                if !book.author.isEmpty {
                    Text(book.author)
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.secondaryInk)
                        .lineLimit(1)
                }

                if let intro = book.intro, !intro.isEmpty {
                    Text(intro)
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.palette.secondaryInk.opacity(0.6))
                .padding(.top, 6)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.divider.opacity(0.45))
                .frame(height: 0.5)
                .padding(.leading, 74)
        }
    }

    private var categoryCoverPlaceholder: some View {
        ZStack {
            theme.palette.elevated
            Image(systemName: "book.closed")
                .font(.system(size: 14))
                .foregroundColor(theme.palette.secondaryInk)
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
            Text("请在「设置 - 书源管理」中导入并启用支持预设分类的书源")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.background)
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
                                            .background(isSelected ? theme.palette.accent : theme.palette.elevated)
                                            .foregroundColor(isSelected ? theme.palette.onAccent : theme.palette.ink)
                                            .cornerRadius(theme.metrics.cornerRadius)
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
    /// 脚本调 `java.refreshExplore()` 的中转：只负责让分类页重拉一遍。
    /// 分类解析本身按「exploreUrl + 源变量」做签名缓存，变量一改下次解析就是新的。
    final class ExploreRefreshCenter: ObservableObject {
        static let shared = ExploreRefreshCenter()
        @Published private(set) var tick = 0

        private init() {
            JSEngine.exploreRefreshSink = { [weak self] in
                DispatchQueue.main.async { self?.tick += 1 }
            }
        }
    }

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
        exploreFilters = []
        filterValues = [:]
        loadCategories(for: source)
    }

    private func loadCategories(for source: BookSource) {
        // 解析要跑书源 JS，手机上几秒，放后台线程；BookExploreService 里有缓存
        Task.detached(priority: .userInitiated) {
            let cats = BookExploreService.shared.parseExploreCategories(source: source)
            let filters = BookExploreService.shared.parseExploreFilters(source: source)
            await MainActor.run {
                self.categories = cats
                self.exploreFilters = filters
                var defaults: [String: String] = [:]
                for filter in filters {
                    if !filter.defaultValue.isEmpty {
                        defaults[filter.name] = filter.defaultValue
                    }
                }
                self.filterValues = defaults

                // Prefer selecting "全部" as initial category so public books load immediately; presets like 阅读历史 remain available in the top bar
                if let allCategory = cats.first(where: { $0.title == "全部" && !($0.url ?? "").isEmpty }) {
                    selectCategory(allCategory)
                } else if let firstActionable = cats.first(where: { !$0.isHeader && !($0.url ?? "").isEmpty && !$0.isAction }) {
                    selectCategory(firstActionable)
                } else {
                    selectedCategory = nil
                    books = []
                }
            }
        }
    }

    private func selectCategory(_ category: ExploreCategory) {
        // 动作类分类没有书可抓，直接执行脚本，不切页面：切了过去先看到「暂无书籍」，
        // 登录页再叠在上面，退出来要退两次。
        if category.isAction {
            runActionCategory(category)
            return
        }
        selectedCategory = category
        books = []
        currentPage = 1
        hasMore = true
        loadBooks(for: category, page: 1)
    }

    private func runActionCategory(_ category: ExploreCategory) {
        guard let src = currentSource, let rawUrl = category.url else { return }
        Task { await BookExploreService.shared.runActionCategory(source: src, categoryUrl: rawUrl) }
    }

    /// 401/403 视为未登录
    private func isAuthError(_ message: String) -> Bool {
        message.contains("401") || message.contains("403")
    }

    /// 不用登录也能看的那一栏（优先「全部」）
    private var publicCategory: ExploreCategory? {
        let usable = categories.filter { !$0.isHeader && $0.url?.isEmpty == false }
        return usable.first(where: { $0.title == "全部" })
            ?? usable.first(where: { !$0.title.contains("历史") && !$0.title.contains("收藏") })
    }

    private func loadBooks(for category: ExploreCategory, page: Int) {
        guard let src = currentSource, let rawUrl = category.url, !rawUrl.isEmpty else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let fetched = try await BookExploreService.shared.fetchExploreBooks(
                    source: src,
                    categoryUrl: rawUrl,
                    page: page,
                    filters: filterValues
                )
                await MainActor.run {
                    self.currentPage = page
                    self.books = fetched
                    self.isLoading = false
                    self.hasMore = !fetched.isEmpty
                }
            } catch {
                await MainActor.run {
                    if error.localizedDescription.contains("403") {
                        self.errorMessage = "「\(category.title)」要登录才能看，先去书源里登录。"
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
                let fetched = try await BookExploreService.shared.fetchExploreBooks(
                    source: src,
                    categoryUrl: rawUrl,
                    page: nextPage,
                    filters: filterValues
                )
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
            let fetched = try await BookExploreService.shared.fetchExploreBooks(
                source: src,
                categoryUrl: rawUrl,
                page: 1,
                filters: filterValues
            )
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
