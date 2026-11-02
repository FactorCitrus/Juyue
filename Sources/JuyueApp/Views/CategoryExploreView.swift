import SwiftUI
#if canImport(JuyueCore)
import JuyueCore
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public struct CategoryExploreView: View {
    @ObservedObject var catalog = BookStore.shared
    @Environment(\.appTheme) private var theme
    @ObservedObject private var refreshCenter = ExploreRefreshCenter.shared

    @StateObject private var engine = CategoryExploreEngine()

    /// TabView 会预先创建所有页签；未选中时不要发起网络请求。
    private let isActive: Bool

    public init(isActive: Bool = true) {
        self.isActive = isActive
    }

    @ViewBuilder
    public var body: some View {
        NavigationView { screenContent }
    }

    private var screenContent: some View {
        VStack(spacing: 0.0) {
            if engine.sources.isEmpty {
                EmptyExploreSources()
            } else {
                ExploreMasthead(sourceCount: engine.sources.count)

                if engine.sources.count > 1 {
                    SectionCaption(title: "SOURCE / 书源", trailing: "\(engine.sources.count)")
                    SourcePillBar(engine: engine)
                }

                if !engine.actionableCategories.isEmpty {
                    SectionCaption(title: "CATEGORY / 分类", trailing: "\(engine.actionableCategories.count)")
                    CategoryChipBar(engine: engine)
                }

                if !engine.filters.isEmpty {
                    FilterStrip(engine: engine)
                }

                Divider()
                ExploreContent(engine: engine)
            }
        }
        .background {
            if theme.backdropStyle == .plain {
                theme.palette.background
            } else {
                AppThemeBackdrop()
            }
        }
        .navigationTitle(Text("分类"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(true)
        #endif
        .toolbar(content: { primaryToolbar })
        .sheet(isPresented: $engine.showingAllCategories) {
            AllCategoriesSheet(engine: engine)
        }
        .sheet(isPresented: $engine.showingAllSources) {
            AllSourcesSheet(engine: engine)
        }
        .sheet(isPresented: $engine.showingLogin) {
            if let source = engine.currentSource {
                SourceLoginSheet(source: source)
            }
        }
        .sheet(isPresented: $engine.showingFilters) {
            ExploreFilterSheet(filters: engine.filters, values: $engine.filterValues) {
                if let category = engine.activeCategory {
                    engine.fetchFirstPage(category)
                }
            }
        }
        .onChange(of: engine.showingLogin) { presented in
            guard !presented, let category = engine.activeCategory else { return }
            engine.fetchFirstPage(category)
        }
        .background(bookDestination)
        .onAppear(perform: bootstrap)
        .onChange(of: isActive) { active in
            if active { engine.activate() }
        }
        .onChange(of: refreshCenter.tick) { _ in
            engine.reloadCurrentCategories()
        }
        .onReceive(catalog.$sources) { sources in
            engine.updateSources(sources)
        }
    }

    @ToolbarContentBuilder
    private var primaryToolbar: some ToolbarContent {
        ToolbarItem(placement: ToolbarItemPlacement.primaryAction) {
            if engine.currentSource != nil && engine.activeCategory != nil {
                NavigationLink {
                    SearchBookView()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
    }

    private func bootstrap() {
        engine.updateSources(catalog.sources)
        if isActive { engine.activate() }
    }

    private var bookDestination: some View {
        NavigationLink(
            isActive: Binding(
                get: { engine.selectedBook != nil },
                set: { if !$0 { engine.selectedBook = nil } }
            ),
            destination: {
                if let book = engine.selectedBook {
                    BookDetailView(searchBook: book, source: engine.currentSource)
                } else { // 未选中书籍
                    EmptyView()
                }
            },
            label: { EmptyView() }
        )
        .hidden()
    }
}

// MARK: - 页头与切换条

private struct ExploreMasthead: View {
    let sourceCount: Int
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("EXPLORE / SOURCES")
                    .font(theme.typography.label)
                    .foregroundColor(theme.palette.secondaryInk)
                Spacer()
                Text("\(sourceCount) SOURCES")
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
}

private struct SectionCaption: View {
    let title: String
    let trailing: String
    @Environment(\.appTheme) private var theme

    var body: some View {
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
}

private struct SourcePillBar: View {
    @ObservedObject var engine: CategoryExploreEngine
    @Environment(\.appTheme) private var theme

    var body: some View {
        HorizontalScroller {
            HStack(alignment: .center, spacing: 8) {
                ForEach(engine.inlineSources) { source in
                    let selected = source.bookSourceUrl == engine.currentSource?.bookSourceUrl
                    Button(action: {
                        guard !selected else { return }
                        engine.switchSource(source)
                    }) {
                        HStack(alignment: .center, spacing: 5) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "globe")
                                .font(.system(size: 11, weight: .regular))
                            Text(source.bookSourceName)
                                .font(.system(size: 13, weight: selected ? .bold : .medium))
                        }
                        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .background(selected ? theme.palette.accent : theme.palette.elevated)
                        .foregroundStyle(selected ? theme.palette.onAccent : theme.palette.ink)
                        .cornerRadius(theme.metrics.cornerRadius + 6)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if engine.sources.count > engine.inlineSources.count {
                    Button(action: { engine.showingAllSources = true }) {
                        HStack(alignment: .center, spacing: 5) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 11, weight: .regular))
                            Text("全部书源 (\(engine.sources.count))")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .background(theme.palette.elevated)
                        .foregroundStyle(theme.palette.ink)
                        .cornerRadius(theme.metrics.cornerRadius + 6)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        .background(theme.palette.surface)
    }
}

private struct AllSourcesSheet: View {
    @ObservedObject var engine: CategoryExploreEngine

    var body: some View {
        NavigationView {
            List {
                ForEach(engine.filteredSources) { source in
                    Button {
                        if source.bookSourceUrl != engine.currentSource?.bookSourceUrl {
                            engine.switchSource(source)
                        }
                        engine.showingAllSources = false
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.bookSourceName)
                                    .font(.system(size: 15))
                                    .foregroundColor(.primary)
                                Text(source.bookSourceUrl)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if source.bookSourceUrl == engine.currentSource?.bookSourceUrl {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
            .appThemedList()
            .searchable(text: $engine.sourceQuery, prompt: "搜书源名")
            .navigationTitle("全部书源 (\(engine.sources.count))")
            #if os(iOS)
            .navigationBarTitleDisplayMode(NavigationBarItem.TitleDisplayMode.inline)
            #endif
            .toolbar(content: { sourcesToolbar })
        }
    }

    @ToolbarContentBuilder
    private var sourcesToolbar: some ToolbarContent {
        ToolbarItem(placement: ToolbarItemPlacement.cancellationAction) {
            Button("关闭") { engine.showingAllSources = false }
        }
    }
}

private struct CategoryChipBar: View {
    @ObservedObject var engine: CategoryExploreEngine
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HorizontalScroller {
                HStack(alignment: .center, spacing: 8) {
                    ForEach(Array(engine.actionableCategories.prefix(12))) { category in
                        let selected = category.id == engine.activeCategory?.id
                        Button(action: {
                            guard !selected else { return }
                            engine.select(category)
                        }) {
                            Text(category.title)
                                .font(.system(size: 13, weight: selected ? .bold : .regular))
                                .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                                .background(selected ? theme.palette.accent.opacity(0.15) : Color.clear)
                                .foregroundStyle(selected ? theme.palette.accent : theme.palette.secondaryInk)
                                .cornerRadius(theme.metrics.cornerRadius)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }

            Button(action: { engine.showingAllCategories = true }) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .background(theme.palette.surface)
    }
}

private struct FilterStrip: View {
    @ObservedObject var engine: CategoryExploreEngine
    @Environment(\.appTheme) private var theme

    private var activeCount: Int {
        engine.filterValues.values.filter { !$0.isEmpty }.count
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                engine.showingFilters = true
            } label: {
                HStack(alignment: .center, spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text("筛选")
                    if activeCount > 0 {
                        Text("\(activeCount)")
                            .font(.system(size: 10, weight: .bold))
                            .padding(EdgeInsets(top: 1, leading: 5, bottom: 1, trailing: 5))
                            .background(theme.palette.accent)
                            .foregroundStyle(theme.palette.onAccent)
                            .clipShape(Capsule())
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.accent)
                .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                .background(theme.palette.accent.opacity(0.12))
                .cornerRadius(theme.metrics.cornerRadius)
            }
            .buttonStyle(PlainButtonStyle())

            HorizontalScroller {
                HStack(alignment: .center, spacing: 6) {
                    ForEach(engine.filters) { filter in
                        if let value = engine.filterValues[filter.name], !value.isEmpty {
                            Text("\(filter.name)：\(value)")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(theme.palette.secondaryInk)
                                .padding(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                                .background(theme.palette.elevated)
                                .cornerRadius(theme.metrics.cornerRadius + 2)
                        }
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .background(theme.palette.surface)
    }
}

// MARK: - 内容区

private struct ExploreContent: View {
    @ObservedObject var engine: CategoryExploreEngine
    @Environment(\.appTheme) private var theme

    private enum Phase {
        case loading
        case failed(String)
        case empty
        case ready
    }

    private var phase: Phase {
        if engine.loading && engine.items.isEmpty { return .loading }
        if let error = engine.error, engine.items.isEmpty { return .failed(error) }
        if engine.items.isEmpty { return .empty }
        return .ready
    }

    var body: some View {
        switch phase {
        case .loading:
            loadingState
        case .failed(let message):
            failureState(message)
        case .empty:
            emptyState
        case .ready:
            bookList
        }
    }

    private var loadingState: some View {
        VStack(alignment: .center, spacing: 12) {
            ProgressView()
            Text("正在加载「\(engine.activeCategory?.title ?? "")」内容...")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private func failureState(_ message: String) -> some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Color.orange)
            Text("加载失败")
                .font(.system(.headline))
            Text(message)
                .font(.system(.caption))
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(TextAlignment.center)
                .padding(.horizontal, 16)

            if engine.isAuthFailure(message), let fallback = engine.publicCategory {
                Text("该分类需要登录此来源后可见。")
                    .font(.system(.caption))
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(TextAlignment.center)
                    .padding(.horizontal, 16)

                if engine.currentSource?.loginUrl?.isEmpty == false || engine.currentSource?.loginUi?.isEmpty == false {
                    Button("登录「\(engine.currentSource?.bookSourceName ?? "")」") {
                        engine.showingLogin = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button("先看「\(fallback.title)」") {
                        engine.select(fallback)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("切到「\(fallback.title)」") {
                        engine.select(fallback)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("重试") { engine.retrySelectedCategory() }
                    .buttonStyle(.bordered)
            } else {
                Button("重试") { engine.retrySelectedCategory() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "books.vertical")
                .font(.largeTitle)
                .foregroundStyle(Color.secondary.opacity(0.6))
            Text("这个分类还没有书")
                .font(.system(.headline))
                .foregroundStyle(Color.secondary)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var bookList: some View {
        List {
            ForEach(Array(engine.items.enumerated()), id: \.element.id) { offset, book in
                ExploreBookRow(engine: engine, book: book, index: offset)
                    .hideListRowSeparatorCompat()
                    .listRowBackground(theme.palette.surface)
                    .contentShape(Rectangle())
                    .onTapGesture { engine.selectedBook = book }
                    .onAppear {
                        guard book.id == engine.items.last?.id else { return }
                        engine.loadMoreIfNeeded()
                    }
            }

            if engine.canLoadMore {
                HStack(alignment: .center) {
                    Spacer()
                    if engine.loadingMore {
                        ProgressView()
                            .padding(.trailing, 6)
                        Text("正在加载下一页...")
                            .font(.system(.caption))
                            .foregroundStyle(Color.secondary)
                    }
                    if !engine.loadingMore {
                        Button("点击加载更多") { engine.loadMoreIfNeeded() }
                            .font(.system(.caption))
                            .foregroundStyle(Color.blue)
                    }
                    Spacer()
                }
                .padding(.vertical, 8.0)
            }
        }
        .appThemedList()
        #if os(iOS)
        .listStyle(.plain)
        #endif
        .refreshable { await engine.refresh() }
    }
}

private struct ExploreBookRow: View {
    @ObservedObject var engine: CategoryExploreEngine
    let book: SearchBook
    let index: Int
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(theme.typography.mono)
                .foregroundColor(theme.palette.secondaryInk)
                .padding(.top, 4)

            cover
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
        .padding(.vertical, 8.0)
        .padding(.horizontal, 16)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.divider.opacity(0.45))
                .frame(height: 0.5)
                .padding(.leading, 74)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let url = book.coverUrl, !url.isEmpty {
            BookCoverImage(
                urlString: url,
                placeholderOverride: AnyView(CoverPlaceholder()),
                onFailure: { engine.repairCover(for: book) }
            )
        } else {
            CoverPlaceholder()
                .onAppear { engine.repairCover(for: book) }
        }
    }
}

private struct CoverPlaceholder: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            theme.palette.elevated
            Image(systemName: "book.closed")
                .font(.system(size: 14))
                .foregroundColor(theme.palette.secondaryInk)
        }
    }
}

private struct EmptyExploreSources: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            if theme.isClassTrial {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(theme.palette.onInk)
                    .frame(width: 76, height: 76)
                    .background(Rectangle().fill(theme.palette.ink))
                    .overlay(alignment: .bottomTrailing) {
                        Rectangle()
                            .fill(theme.palette.accent)
                            .frame(width: 16, height: 16)
                    }
                    .rotationEffect(.degrees(-3))
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            Text("暂无可用分类书源")
                .font(theme.isClassTrial ? .system(size: 20, weight: .black) : .headline)
                .foregroundStyle(theme.isClassTrial ? theme.palette.ink : .secondary)
            Text("请在「设置 - 书源管理」中导入并启用支持预设分类的书籍来源。")
                .font(theme.isClassTrial ? .system(size: 12, weight: .medium) : .caption)
                .foregroundStyle(theme.isClassTrial ? theme.palette.secondaryInk : .secondary)
                .multilineTextAlignment(TextAlignment.center)
                .padding(EdgeInsets(top: 0, leading: 32, bottom: 0, trailing: 32))
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background {
            if theme.backdropStyle == .plain {
                theme.palette.background
            } else {
                AppThemeBackdrop()
            }
        }
    }
}

// MARK: - 全部分类面板

private struct AllCategoriesSheet: View {
    @ObservedObject var engine: CategoryExploreEngine
    @Environment(\.appTheme) private var theme

    private let categoryColumns = [GridItem(.adaptive(minimum: 85, maximum: .infinity), spacing: 8)]

    var body: some View {
        NavigationView { categoryPanels }
    }

    private var categoryPanels: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16.0) {
                ForEach(CategoryGrouping.groups(from: engine.categories), id: \.caption) { group in
                    VStack(alignment: .leading, spacing: 8.0) {
                        if group.caption.isEmpty == false {
                            Text(verbatim: group.caption)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.secondary)
                        }

                        LazyVGrid(columns: categoryColumns, spacing: 8.0) {
                            ForEach(group.entries) { category in
                                let selected = category.id == engine.activeCategory?.id
                                Button(action: {
                                    engine.showingAllCategories = false
                                    engine.select(category)
                                }) {
                                    Text(category.title)
                                        .font(.system(size: 13, weight: selected ? .bold : .medium))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6))
                                        .background(selected ? theme.palette.accent : theme.palette.elevated)
                                        .foregroundStyle(selected ? theme.palette.onAccent : theme.palette.ink)
                                        .cornerRadius(theme.metrics.cornerRadius)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(Text("全部预设分类"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar(content: { sheetToolbar })
    }

    @ToolbarContentBuilder
    private var sheetToolbar: some ToolbarContent {
        ToolbarItem(placement: ToolbarItemPlacement.cancellationAction) {
            Button("关闭") { engine.showingAllCategories = false }
        }
    }
}

// MARK: - 状态机

final class CategoryExploreEngine: ObservableObject {
    @Published private(set) var sources: [BookSource] = []
    @Published var selectedSourceURL = ""
    @Published private(set) var categories: [ExploreCategory] = []
    @Published var activeCategory: ExploreCategory?
    @Published private(set) var items: [SearchBook] = []
    @Published private(set) var page = 1
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var canLoadMore = true
    @Published private(set) var error: String?
    @Published private(set) var filters: [ExploreFilter] = []
    @Published var filterValues: [String: String] = [:]
    @Published var selectedBook: SearchBook?
    @Published var showingAllCategories = false
    @Published var showingAllSources = false
    @Published var showingLogin = false
    @Published var showingFilters = false
    @Published var sourceQuery = ""

    private var attemptedCoverRepairs: Set<String> = []

    var currentSource: BookSource? {
        sources.first { $0.bookSourceUrl == selectedSourceURL } ?? sources.first
    }

    var actionableCategories: [ExploreCategory] {
        categories.filter { !$0.isHeader && ($0.url ?? "").isEmpty == false }
    }

    var inlineSources: [BookSource] {
        let limit = 10
        var shown = Array(sources.prefix(limit))
        guard let current = currentSource,
              !shown.contains(where: { $0.bookSourceUrl == current.bookSourceUrl }) else {
            return shown
        }
        shown.insert(current, at: 0)
        if shown.count > limit { shown.removeLast() }
        return shown
    }

    var filteredSources: [BookSource] {
        let query = sourceQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sources }
        return sources.filter { $0.bookSourceName.localizedCaseInsensitiveContains(query) }
    }

    var publicCategory: ExploreCategory? {
        let usable = categories.filter { !$0.isHeader && ($0.url ?? "").isEmpty == false }
        return usable.first { $0.title == "全部" }
            ?? usable.first { !$0.title.contains("历史") && !$0.title.contains("收藏") }
    }

    func isAuthFailure(_ message: String) -> Bool {
        message.contains("401") || message.contains("403")
    }

    func updateSources(_ all: [BookSource]) {
        sources = all.filter { source in
            guard source.enabled ?? true, let explore = source.exploreUrl else { return false }
            return !explore.isEmpty && !explore.allSatisfy { $0.isWhitespace }
        }
        if currentSource == nil {
            selectedSourceURL = sources.first?.bookSourceUrl ?? ""
        }
    }

    func activate() {
        if selectedSourceURL.isEmpty {
            selectedSourceURL = sources.first?.bookSourceUrl ?? ""
        }
        guard let source = currentSource, categories.isEmpty else { return }
        reloadCategories(for: source)
    }

    func switchSource(_ source: BookSource) {
        selectedSourceURL = source.bookSourceUrl
        items = []
        activeCategory = nil
        filters = []
        filterValues = [:]
        reloadCategories(for: source)
    }

    func reloadCurrentCategories() {
        guard let source = currentSource else { return }
        reloadCategories(for: source)
    }

    func reloadCategories(for source: BookSource) {
        Task.detached(priority: .userInitiated) {
            let parsedCategories = BookExploreService.shared.parseExploreCategories(source: source)
            let parsedFilters = BookExploreService.shared.parseExploreFilters(source: source)
            await self.applyOnMain {
                guard self.currentSource?.bookSourceUrl == source.bookSourceUrl else { return }
                self.categories = parsedCategories
                self.filters = parsedFilters
                self.filterValues = parsedFilters.reduce(into: [String: String]()) { result, filter in
                    guard !filter.defaultValue.isEmpty else { return }
                    result[filter.name] = filter.defaultValue
                }
                self.chooseInitialCategory(from: parsedCategories)
            }
        }
    }

    private func chooseInitialCategory(from list: [ExploreCategory]) {
        if let all = list.first(where: { $0.title == "全部" && ($0.url ?? "").isEmpty == false }) {
            select(all)
        } else if let first = list.first(where: { !$0.isHeader && ($0.url ?? "").isEmpty == false && !$0.isAction }) {
            select(first)
        } else {
            activeCategory = nil
            items = []
        }
    }

    func select(_ category: ExploreCategory) {
        guard !category.isAction else {
            runAction(category)
            return
        }
        activeCategory = category
        items = []
        page = 1
        canLoadMore = true
        fetchFirstPage(category)
    }

    func retrySelectedCategory() {
        guard let category = activeCategory else { return }
        fetchFirstPage(category)
    }

    private func runAction(_ category: ExploreCategory) {
        guard let source = currentSource, let url = category.url else { return }
        Task(priority: .userInitiated) {
            await BookExploreService.shared.runActionCategory(source: source, categoryUrl: url)
        }
    }

    func fetchFirstPage(_ category: ExploreCategory) {
        guard let source = currentSource, let url = category.url, !url.isEmpty else { return }
        loading = true
        error = nil
        Task(priority: .userInitiated) {
            do /* 首屏请求 */ {
                let result = try await BookExploreService.shared.fetchExploreBooks(
                    source: source,
                    categoryUrl: url,
                    page: 1,
                    filters: filterValues
                )
                await self.applyOnMain {
                    self.page = 1
                    self.items = result
                    self.canLoadMore = !result.isEmpty
                    self.loading = false
                }
            } catch let failure {
                await self.applyOnMain {
                    self.error = failure.localizedDescription.contains("403")
                        ? "「\(category.title)」要登录才能看，先去书源里登录。"
                        : failure.localizedDescription
                    self.loading = false
                }
            }
        }
    }

    func loadMoreIfNeeded() {
        guard !loadingMore, canLoadMore,
              let source = currentSource,
              let category = activeCategory,
              let url = category.url, !url.isEmpty else { return }

        loadingMore = true
        let nextPage = page + 1
        Task(priority: .userInitiated) {
            do /* 下一页请求 */ {
                let result = try await BookExploreService.shared.fetchExploreBooks(
                    source: source,
                    categoryUrl: url,
                    page: nextPage,
                    filters: filterValues
                )
                await self.applyOnMain {
                    self.page = nextPage
                    self.appendUnique(result)
                    self.loadingMore = false
                }
            } catch _ {
                await self.applyOnMain { self.loadingMore = false }
            }
        }
    }

    private func appendUnique(_ incoming: [SearchBook]) {
        guard !incoming.isEmpty else {
            canLoadMore = false
            return
        }
        let existing = Set(items.map(\.bookUrl))
        let fresh = incoming.filter { !existing.contains($0.bookUrl) }
        guard !fresh.isEmpty else {
            canLoadMore = false
            return
        }
        items.append(contentsOf: fresh)
    }

    func refresh() async {
        guard let source = currentSource,
              let category = activeCategory,
              let url = category.url, !url.isEmpty else { return }
        do /* 下拉刷新 */ {
            let result = try await BookExploreService.shared.fetchExploreBooks(
                source: source,
                categoryUrl: url,
                page: 1,
                filters: filterValues
            )
            await self.applyOnMain {
                self.page = 1
                self.items = result
                self.canLoadMore = !result.isEmpty
            }
        } catch let failure {
            await self.applyOnMain { self.error = failure.localizedDescription }
        }
    }

    private func applyOnMain(_ block: @escaping () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                block()
                continuation.resume()
            }
        }
    }

    func repairCover(for searchBook: SearchBook) {
        guard let source = currentSource, !searchBook.bookUrl.isEmpty else { return }
        guard attemptedCoverRepairs.insert(searchBook.id).inserted else { return }

        let model = Book(
            bookUrl: searchBook.bookUrl,
            name: searchBook.name,
            author: searchBook.author,
            kind: searchBook.kind,
            coverUrl: searchBook.coverUrl,
            intro: searchBook.intro,
            origin: searchBook.origin,
            originName: searchBook.originName,
            latestChapterTitle: searchBook.latestChapterTitle
        )
        Task(priority: .userInitiated) {
            guard let cover = await CoverRepairService.shared.cover(for: model, source: source),
                  !cover.isEmpty else { return }
            await self.applyOnMain {
                guard let index = self.items.firstIndex(where: { $0.bookUrl == searchBook.bookUrl }) else { return }
                var updated = self.items
                updated[index].coverUrl = cover
                self.items = updated
            }
        }
    }
}

enum CategoryGrouping {
    struct Bucket {
        let caption: String
        let entries: [ExploreCategory]
    }

    static func groups(from categories: [ExploreCategory]) -> [Bucket] {
        var result: [Bucket] = []
        var header = ""
        var bucket: [ExploreCategory] = []

        for category in categories {
            guard category.isHeader else {
                bucket.append(category)
                continue
            }
            if !bucket.isEmpty {
                result.append(Bucket(caption: header, entries: bucket))
                bucket = []
            }
            header = category.title
        }

        if !bucket.isEmpty {
            result.append(Bucket(caption: header, entries: bucket))
        }
        return result
    }
}

/// 脚本调 `java.refreshExplore()` 的中转：只负责让分类页重拉一遍。
final class ExploreRefreshCenter: ObservableObject {
    static let shared = ExploreRefreshCenter()
    @Published private(set) var tick = 0

    private init() {
        JSEngine.exploreRefreshSink = { [weak self] in
            DispatchQueue.main.async { self?.tick += 1 }
        }
    }
}

/// 分类列表补封面：同一本书可能同时有多行触发，合并成一次详情请求。
final class CoverRepairService {
    static let shared = CoverRepairService()

    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var failed: Set<String> = []
    private var inflight: [String: Task<String?, Never>] = [:]

    func cover(for book: Book, source: BookSource) async -> String? {
        let key = "\(source.bookSourceUrl)|\(book.bookUrl)"

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        if failed.contains(key) {
            lock.unlock()
            return nil
        }
        if let running = inflight[key] {
            lock.unlock()
            return await running.value
        }
        let task = Task { await BookContentService.shared.fetchBookCover(book: book, source: source) }
        inflight[key] = task
        lock.unlock()

        let value = await task.value

        lock.lock()
        inflight[key] = nil
        if let value, !value.isEmpty {
            cache[key] = value
        } else {
            failed.insert(key)
        }
        lock.unlock()
        return value
    }
}

private struct HorizontalScroller<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { content }
    }
}

private extension View {
    @ViewBuilder
    func hideListRowSeparatorCompat() -> some View {
        if #available(iOS 15.0, macOS 13.0, *) {
            self.listRowSeparator(.hidden)
        } else {
            self
        }
    }
}
