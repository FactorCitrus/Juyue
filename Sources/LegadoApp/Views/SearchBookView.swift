import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

public struct SearchBookView: View {
    @ObservedObject var viewModel = SearchViewModel.shared
    @Environment(\.appTheme) private var theme
    @State private var selectedDetailBook: SearchBook? = nil
    /// 范围与匹配默认收起，先看结果；收起状态是临时的
    @State private var showOptions = false

    public init() {}

    /// 改了范围（分组 / 限定源）要重搜一遍；匹配选项是就地重筛，不用重搜
    private func restartIfNeeded() {
        guard !viewModel.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        viewModel.startSearch()
    }

    /// 卡片底：整页走浅灰底 + 白卡片，控件不再直接贴在灰底上
    private var searchCard: some View {
        RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
            .fill(theme.palette.surface)
            .shadow(color: Color.black.opacity(theme.choice == .standard ? 0.05 : 0), radius: 6, y: 2)
    }

    /// 整页底色：浅灰分组底，白卡片才有对比
    private var pageBackground: Color {
        theme.palette.background
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 搜索栏：一张卡片，输入框在里、搜索是实心按钮
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundColor(theme.palette.secondaryInk)
                    PlaceholderField(placeholder: "搜索书名或作者…", text: $viewModel.searchQuery) {
                        viewModel.startSearch()
                    }
                    if !viewModel.searchQuery.isEmpty {
                        Button {
                            viewModel.searchQuery = ""
                            viewModel.cancelAndReset()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(theme.palette.secondaryInk)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button("搜索") { viewModel.startSearch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isSearching)
            }
            .padding(12)
            .background(searchCard)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if !viewModel.history.isEmpty && viewModel.searchQuery.isEmpty {
                recentSearchChips
            }

            // 范围与匹配：收起时也把当前口径写在标题上
            VStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showOptions.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: showOptions ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(theme.palette.secondaryInk)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("范围与匹配")
                                .font(.subheadline.weight(.medium))
                            // 摘要单独一行，收起时也知道现在按什么口径搜
                            Text(viewModel.optionsSummary)
                                .font(.caption)
                                .foregroundColor(theme.palette.secondaryInk)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showOptions {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("匹配条件")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)

                        Picker("匹配条件", selection: $viewModel.matchField) {
                            Text("书名").tag(SourceMatchRules.SearchField.title)
                            Text("作者").tag(SourceMatchRules.SearchField.author)
                            Text("书名或作者").tag(SourceMatchRules.SearchField.either)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Toggle("精确匹配", isOn: $viewModel.exactMatch)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("搜索范围")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                        HStack {
                            Text("分组")
                                .font(.subheadline)
                                .foregroundColor(theme.palette.secondaryInk)
                                .frame(width: 40, alignment: .leading)
                            Menu(viewModel.groupFilter ?? "全部分组") {
                                Button("全部分组") {
                                    viewModel.groupFilter = nil
                                    restartIfNeeded()
                                }
                                ForEach(viewModel.availableGroups, id: \.self) { group in
                                    Button(group) {
                                        viewModel.groupFilter = group
                                        restartIfNeeded()
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                        }

                        HStack {
                            Text("限定源")
                                .font(.subheadline)
                                .foregroundColor(theme.palette.secondaryInk)
                                .frame(width: 52, alignment: .leading)
                            PlaceholderField(placeholder: "源名 / 分组含这几个字",
                                             text: $viewModel.sourceNameFilter) {
                                restartIfNeeded()
                            }
                            Button("应用") { restartIfNeeded() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(viewModel.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        Text("范围内 \(viewModel.availableSources.count) 个源")
                            .font(.caption2)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                }
            }
            .padding(14)
            .background(searchCard)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Source filter chips
            if !viewModel.availableSources.isEmpty {
                sourceFilterBar
            }

            Divider()

            // Content area
            if viewModel.isSearching && viewModel.searchResults.isEmpty {
                searchingState
            } else if viewModel.searchResults.isEmpty && !viewModel.searchQuery.isEmpty && !viewModel.isSearching {
                noResultState
            } else if viewModel.searchResults.isEmpty && viewModel.searchQuery.isEmpty {
                if viewModel.history.isEmpty {
                    emptyPromptState
                } else {
                    searchHistoryList
                }
            } else {
                if viewModel.hiddenByFilterCount > 0 {
                    Text("按当前条件过滤掉 \(viewModel.hiddenByFilterCount) 条（展开「范围与匹配」可放宽）")
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 6)
                }
                List {
                    ForEach(viewModel.searchResults) { item in
                        resultRow(item)
                    }

                    // List footer (loading / more / finished)
                    Section {
                        footerView
                    }
                    .appThemedRows()
                }
                .appThemedList()
                .listStyle(.plain)
            }
        }
        .navigationTitle("聚合搜索")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(pageBackground)
        .background(
            // Programmatic navigation link outside List to avoid any row insertion or navigation reset
            NavigationLink(
                isActive: Binding(
                    get: { selectedDetailBook != nil },
                    set: { if !$0 { selectedDetailBook = nil } }
                ),
                destination: {
                    if let item = selectedDetailBook {
                        let source = BookStore.shared.source(forSearchBook: item)
                        BookDetailView(searchBook: item, source: source)
                    } else {
                        EmptyView()
                    }
                },
                label: { SwiftUI.EmptyView() }
            )
            .hidden().frame(width: 0, height: 0)
        )
    }

    /// 单条搜索结果：点按进详情，滚到可见时按需续页。
    private func resultRow(_ item: SearchBook) -> some View {
        SearchResultRow(item: item)
            .contentShape(Rectangle())
            .appThemedRows()
            .onTapGesture {
                selectedDetailBook = item
            }
            .onAppear {
                if viewModel.shouldAutoLoadMore(for: item) {
                    viewModel.loadNextPage()
                }
            }
    }

    // MARK: - 状态视图

    /// 书源筛选条：第一个是「全部」，后面每个源一个。
    private var sourceFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "全部书源 (\(viewModel.availableSources.count))",
                           isSelected: viewModel.selectedSourceUrl == nil) {
                    pickSource(nil)
                }
                ForEach(viewModel.availableSources) { source in
                    FilterChip(title: source.bookSourceName,
                               isSelected: viewModel.selectedSourceUrl == source.bookSourceUrl) {
                        pickSource(source.bookSourceUrl)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    /// 切书源。已经有搜索词就顺手重搜，空词只记选择。
    private func pickSource(_ url: String?) {
        viewModel.selectedSourceUrl = url
        guard !viewModel.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        viewModel.startSearch()
    }

    private var searchingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在搜索全网书籍 (第 1 页)...")
                .font(.subheadline)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundColor(theme.palette.secondaryInk.opacity(0.6))
            Text("没找到相关书籍")
                .font(.headline)
                .foregroundColor(theme.palette.secondaryInk)
            Text(viewModel.hiddenByFilterCount > 0
                 ? "搜到 \(viewModel.hiddenByFilterCount) 条，但都不符合当前匹配口径"
                 : "可尝试切换其他书源或更换关键词")
                .font(.caption)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyPromptState: some View {
        VStack(spacing: 8) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40))
                .foregroundColor(theme.palette.secondaryInk.opacity(0.5))
            Text("输入关键词开启全网搜索")
                .font(.subheadline)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer View

    @ViewBuilder
    private var footerView: some View {
        if viewModel.isLoadingMore {
            loadingMoreRow
        } else if viewModel.hasMore && !viewModel.searchResults.isEmpty {
            Button(action: {
                viewModel.loadNextPage()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("加载下一页 (第 \(viewModel.currentPage + 1) 页，已加载 \(viewModel.searchResults.count) 本)")
                }
                .frame(maxWidth: .infinity)
                .font(.footnote)
                .foregroundColor(theme.palette.accent)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        } else if !viewModel.hasMore && !viewModel.searchResults.isEmpty {
            Text("— 已加载全部 \(viewModel.searchResults.count) 本书籍 —")
                .font(.caption2)
                .foregroundColor(theme.palette.secondaryInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    private var loadingMoreRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("正在加载第 \(viewModel.currentPage + 1) 页...")
                .font(.footnote)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    /// 搜索框下方的「最近」快捷词；点一下直接重搜。
    private var recentSearchChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("最近")
                    .font(.caption)
                    .foregroundColor(theme.palette.secondaryInk)
                ForEach(Array(viewModel.history.prefix(10)), id: \.self) { keyword in
                    Button {
                        viewModel.searchQuery = keyword
                        viewModel.startSearch()
                    } label: {
                        Text(keyword)
                            .font(.caption)
                            .foregroundColor(theme.palette.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(theme.palette.elevated))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    viewModel.clearHistory()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
    }

    /// 搜索历史：点一条直接重搜
    private var searchHistoryList: some View {
        List {
            Section(header: HStack {
                Text("最近搜索")
                Spacer()
                Button("清空") {
                    viewModel.clearHistory()
                }
                .font(.caption)
            }.appThemedRows()) {
                ForEach(viewModel.history, id: \.self) { keyword in
                    Button {
                        viewModel.searchQuery = keyword
                        viewModel.startSearch()
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(theme.palette.secondaryInk)
                            Text(keyword)
                                .foregroundColor(theme.palette.ink)
                            Spacer()
                        }
                    }
                    .appThemedRows()
                }
            }
        }
        .appThemedList()
        .listStyle(.plain)
    }
}

// MARK: - Filter Chip

/// 一行输入框：灰底 + 自己画的占位文字。
///
/// 系统的 placeholder 颜色太浅，压在灰底上看着像「这个框没设置内容」，
/// 这里用 secondary 自己画一层，没输入时才显示。
struct PlaceholderField: View {
    @Environment(\.appTheme) private var theme
    let placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.subheadline)
                    .foregroundColor(theme.palette.secondaryInk)
                    .allowsHitTesting(false)
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline)
                #if os(iOS)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                #endif
                .onSubmit { onSubmit?() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous).fill(theme.palette.elevated))
    }
}

struct FilterChip: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
    }

    private var label: some View {
        Text(title)
            .font(.caption.weight(isSelected ? .bold : .regular))
            .padding(EdgeInsets(top: 7, leading: 13, bottom: 7, trailing: 13))
            .background(isSelected ? theme.palette.accent : theme.palette.elevated)
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(17)
    }
}

// MARK: - SearchResultRow

public struct SearchResultRow: View {
    @Environment(\.appTheme) private var theme
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
            cover
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.headline)
                    .lineLimit(2)
                metaLine
                kindLine
                introLine
                latestLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.palette.secondaryInk.opacity(0.5))
        }
        .padding(.vertical, 4)
    }

    /// 封面：有地址就异步加载，失败或没地址都用占位块，尺寸保持一致
    @ViewBuilder
    private var cover: some View {
        if let raw = item.coverUrl, let url = URL(string: raw) {
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
    }

    /// 作者 + 来源标签
    private var metaLine: some View {
        HStack(spacing: 6) {
            if !item.author.isEmpty && item.author != "未知作者" {
                Text(item.author)
                    .font(.subheadline)
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(1)
            }
            Text(item.originName)
                .font(.caption2)
                .padding(EdgeInsets(top: 2, leading: 5, bottom: 2, trailing: 5))
                .background(theme.palette.accent.opacity(0.12))
                .foregroundColor(theme.palette.accent)
                .cornerRadius(4)
        }
    }

    @ViewBuilder
    private var kindLine: some View {
        if let kind = item.kind, !kind.isEmpty {
            Text(kind.replacingOccurrences(of: ",", with: " · "))
                .font(.caption2)
                .foregroundColor(theme.palette.secondaryInk)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var introLine: some View {
        // cleanIntro 已经把空串和「源站：」前缀滤掉了
        if let intro = cleanIntro {
            Text(intro)
                .font(.caption2)
                .foregroundColor(theme.palette.secondaryInk.opacity(0.8))
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var latestLine: some View {
        if let latest = item.latestChapterTitle, !latest.isEmpty {
            Text("最新: \(latest)")
                .font(.caption2)
                .foregroundColor(theme.palette.secondaryInk)
                .lineLimit(1)
        }
    }

    private var coverPlaceholder: some View {
        let tint = Color.accentColor.opacity(0.12)
        return RoundedRectangle(cornerRadius: 6)
            .fill(tint)
            .frame(width: 52, height: 72)
            .overlay(Image(systemName: "book.closed").foregroundColor(theme.palette.accent))
    }
}
