import SwiftUI
#if canImport(JuyueCore)
import JuyueCore
#endif

public struct SearchBookView: View {
    @ObservedObject private var viewModel = SearchViewModel.shared
    @Environment(\.appTheme) private var theme

    @State private var detailTarget: SearchBook?
    @State private var scopeExpanded = false
    @State private var sourceSheetVisible = false

    public init() {}

    private func rerunIfNeeded() {
        guard !viewModel.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        viewModel.startSearch()
    }

    private func toggleSource(_ url: String) {
        if viewModel.selectedSourceUrls.contains(url) {
            viewModel.selectedSourceUrls.remove(url)
        } else {
            viewModel.selectedSourceUrls.insert(url)
        }
        rerunIfNeeded()
    }

    public var body: some View {
        VStack(spacing: 0) {
            SearchInputCard(
                viewModel: viewModel,
                onSubmit: { viewModel.startSearch() },
                onClear: {
                    viewModel.searchQuery = ""
                    viewModel.cancelAndReset()
                },
                onPause: { viewModel.pauseSearch() },
                onResume: { viewModel.resumeSearch() }
            )
            .padding(12)
            .appThemePanel()
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if viewModel.searchQuery.isEmpty && !viewModel.history.isEmpty {
                RecentQueries(viewModel: viewModel)
            }

            SearchScopeCard(
                viewModel: viewModel,
                expanded: $scopeExpanded,
                onRerun: rerunIfNeeded,
                onChooseSources: { sourceSheetVisible = true }
            )
            .padding(14)
            .appThemePanel()
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if !viewModel.searchableSources.isEmpty {
                SourceFilterStrip(
                    viewModel: viewModel,
                    onToggle: toggleSource,
                    onSelectAll: {
                        viewModel.selectedSourceUrls.removeAll()
                        rerunIfNeeded()
                    }
                )
            }

            Divider()

            SearchOutput(
                viewModel: viewModel,
                onSelect: { detailTarget = $0 }
            )
        }
        .navigationTitle("聚合搜索")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .appThemePageBackground()
        .sheet(isPresented: $sourceSheetVisible, onDismiss: rerunIfNeeded) {
            SearchSourcePickerSheet(viewModel: viewModel)
        }
        .background(detailDestination)
    }

    private var detailDestination: some View {
        NavigationLink(
            isActive: Binding(
                get: { detailTarget != nil },
                set: { if !$0 { detailTarget = nil } }
            ),
            destination: {
                if let item = detailTarget {
                    BookDetailView(
                        searchBook: item,
                        source: BookStore.shared.source(forSearchBook: item)
                    )
                } else {
                    EmptyView()
                }
            },
            label: { SwiftUI.EmptyView() }
        )
        .hidden()
        .frame(width: 0, height: 0)
    }
}

// MARK: - 搜索栏

private struct SearchInputCard: View {
    @ObservedObject var viewModel: SearchViewModel
    let onSubmit: () -> Void
    let onClear: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundColor(theme.palette.secondaryInk)

                PlaceholderField(placeholder: "搜索书名或作者…", text: $viewModel.searchQuery, onSubmit: onSubmit)

                if !viewModel.searchQuery.isEmpty {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                    .buttonStyle(.plain)
                }
            }

            actionButton
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if viewModel.isSearching || viewModel.isLoadingMore {
            Button("暂停", action: onPause)
                .buttonStyle(.bordered)
        } else if viewModel.isPaused {
            Button("继续", action: onResume)
                .buttonStyle(.borderedProminent)
        } else {
            Button("搜索", action: onSubmit)
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

// MARK: - 最近搜索

private struct RecentQueries: View {
    @ObservedObject var viewModel: SearchViewModel
    @Environment(\.appTheme) private var theme

    var body: some View {
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

                Button { viewModel.clearHistory() } label: {
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
}

// MARK: - 范围与匹配

private struct SearchScopeCard: View {
    @ObservedObject var viewModel: SearchViewModel
    @Binding var expanded: Bool
    let onRerun: () -> Void
    let onChooseSources: () -> Void
    @Environment(\.appTheme) private var theme

    private let fields: [(SourceMatchRules.SearchField, String)] = [
        (.title, "书名"), (.author, "作者"), (.either, "书名或作者")
    ]

    var body: some View {
        VStack(spacing: 8) {
            header
            if expanded {
                Divider()
                matchSection
                Divider()
                rangeSection
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(theme.palette.secondaryInk)

                VStack(alignment: .leading, spacing: 3) {
                    Text("范围与匹配")
                        .font(.subheadline.weight(.medium))
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
    }

    private var matchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("匹配条件")
                .font(.caption)
                .foregroundColor(theme.palette.secondaryInk)

            if theme.isClassTrial {
                HStack(spacing: 6) {
                    ForEach(fields, id: \.1) { field, label in
                        matchChoice(field: field, label: label)
                    }
                }
            } else {
                Picker("匹配条件", selection: $viewModel.matchField) {
                    Text("书名").tag(SourceMatchRules.SearchField.title)
                    Text("作者").tag(SourceMatchRules.SearchField.author)
                    Text("书名或作者").tag(SourceMatchRules.SearchField.either)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("精确匹配", isOn: $viewModel.exactMatch)
        }
    }

    private func matchChoice(field: SourceMatchRules.SearchField, label: String) -> some View {
        let selected = viewModel.matchField == field
        return Button {
            viewModel.matchField = field
        } label: {
            Text(label)
                .font(.system(size: 12, weight: selected ? .black : .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? theme.palette.accent : theme.palette.surface)
                .foregroundColor(selected ? theme.palette.onAccent : theme.palette.ink)
                .overlay(
                    RoundedRectangle(cornerRadius: 0)
                        .stroke(selected ? theme.palette.accent : theme.palette.ink, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }

    private var rangeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("搜索范围")
                .font(.caption)
                .foregroundColor(theme.palette.secondaryInk)

            HStack {
                Text("分组")
                    .font(.subheadline)
                    .foregroundColor(theme.palette.secondaryInk)
                    .frame(width: 40, alignment: .leading)
                groupMenu
                Spacer()
            }

            HStack {
                Text("限定源")
                    .font(.subheadline)
                    .foregroundColor(theme.palette.secondaryInk)
                    .frame(width: 52, alignment: .leading)
                sourceButton
                Spacer()
            }

            Text("范围内 \(viewModel.availableSources.count) 个源")
                .font(.caption2)
                .foregroundColor(theme.palette.secondaryInk)
        }
    }

    @ViewBuilder
    private var groupMenu: some View {
        let menu = Menu {
            Button("全部分组") {
                viewModel.groupFilter = nil
                onRerun()
            }
            ForEach(viewModel.availableGroups, id: \.self) { group in
                Button(group) {
                    viewModel.groupFilter = group
                    onRerun()
                }
            }
        } label: {
            if theme.isClassTrial {
                HStack(spacing: 4) {
                    Text(viewModel.groupFilter ?? "全部分组")
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.palette.surface)
                .overlay(Rectangle().stroke(theme.palette.ink, lineWidth: 2))
            } else {
                Text(viewModel.groupFilter ?? "全部分组")
            }
        }

        if theme.isClassTrial {
            menu.buttonStyle(.plain)
        } else {
            menu.buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var sourceButton: some View {
        Button(action: onChooseSources) {
            HStack(spacing: 6) {
                Text(viewModel.selectedSourceUrls.isEmpty
                     ? "全部书源"
                     : "已选 \(viewModel.selectedSourceUrls.count) 个源")
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.palette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                    .stroke(
                        theme.isClassTrial ? theme.palette.ink : theme.palette.divider,
                        lineWidth: theme.isClassTrial ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 书源筛选条

private struct SourceFilterStrip: View {
    @ObservedObject var viewModel: SearchViewModel
    let onToggle: (String) -> Void
    let onSelectAll: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    title: "全部书源 (\(viewModel.searchableSources.count))",
                    isSelected: viewModel.selectedSourceUrls.isEmpty,
                    action: onSelectAll
                )

                ForEach(viewModel.searchableSources) { source in
                    FilterChip(
                        title: source.bookSourceName,
                        isSelected: viewModel.selectedSourceUrls.contains(source.bookSourceUrl),
                        action: { onToggle(source.bookSourceUrl) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - 结果区

private struct SearchOutput: View {
    @ObservedObject var viewModel: SearchViewModel
    let onSelect: (SearchBook) -> Void

    @ViewBuilder
    var body: some View {
        Group {
            if viewModel.isPaused && viewModel.searchResults.isEmpty {
                PausedOutput(onResume: { viewModel.resumeSearch() })
            } else if viewModel.isSearching && viewModel.searchResults.isEmpty {
                SearchingOutput()
            } else if viewModel.searchResults.isEmpty && !viewModel.searchQuery.isEmpty && !viewModel.isSearching {
                NoResultOutput(hiddenCount: viewModel.hiddenByFilterCount)
            } else if viewModel.searchResults.isEmpty && viewModel.searchQuery.isEmpty {
                if viewModel.history.isEmpty {
                    EmptyPromptOutput()
                } else {
                    HistoryOutput(viewModel: viewModel)
                }
            } else {
                ResultListOutput(viewModel: viewModel, onSelect: onSelect)
            }
        }
    }
}

private struct ResultListOutput: View {
    @ObservedObject var viewModel: SearchViewModel
    let onSelect: (SearchBook) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isPaused {
                pausedBanner
            }
            if viewModel.hiddenByFilterCount > 0 {
                filteredNote
            }
            resultList
        }
    }

    private var pausedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.fill")
                .font(.system(size: 11, weight: .bold))
            Text("已暂停 · 已找到 \(viewModel.searchResults.count) 本")
                .font(.caption)
            Spacer()
            Button("继续") { viewModel.resumeSearch() }
                .font(.caption.weight(.semibold))
                .foregroundColor(theme.palette.accent)
        }
        .foregroundColor(theme.palette.secondaryInk)
        .padding(.horizontal)
        .padding(.top, 6)
    }

    private var filteredNote: some View {
        Text("按当前条件过滤掉 \(viewModel.hiddenByFilterCount) 条（展开「范围与匹配」可放宽）")
            .font(.caption2)
            .foregroundColor(theme.palette.secondaryInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 6)
    }

    private var resultList: some View {
        List {
            ForEach(viewModel.searchResults) { item in
                SearchResultRow(item: item)
                    .contentShape(Rectangle())
                    .appThemedRows()
                    .onTapGesture { onSelect(item) }
                    .onAppear {
                        if viewModel.shouldAutoLoadMore(for: item) {
                            viewModel.loadNextPage()
                        }
                    }
            }

            Section {
                SearchListFooter(viewModel: viewModel)
            }
            .appThemedRows()
        }
        .appThemedList()
        .listStyle(.plain)
    }
}

private struct SearchListFooter: View {
    @ObservedObject var viewModel: SearchViewModel
    @Environment(\.appTheme) private var theme

    @ViewBuilder
    var body: some View {
        if viewModel.isPaused {
            Button { viewModel.resumeSearch() } label: {
                footerLabel("play.fill", "已暂停 · 继续搜索剩余书源")
            }
            .buttonStyle(.plain)
        } else if viewModel.isLoadingMore {
            loadingRow
        } else if viewModel.hasMore && !viewModel.searchResults.isEmpty {
            Button { viewModel.loadNextPage() } label: {
                footerLabel(
                    "arrow.clockwise",
                    "加载下一页 (第 \(viewModel.currentPage + 1) 页，已加载 \(viewModel.searchResults.count) 本)"
                )
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

    private func footerLabel(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .frame(maxWidth: .infinity)
        .font(.footnote)
        .foregroundColor(theme.palette.accent)
        .padding(.vertical, 8)
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("正在加载第 \(viewModel.currentPage + 1) 页...")
                .font(.footnote)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

// MARK: - 空态

private struct PausedOutput: View {
    let onResume: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "pause.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(theme.palette.accent)
            Text("搜索已暂停")
                .font(.headline)
                .foregroundColor(theme.palette.ink)
            Text("已经找到的结果会保留，继续会从未完成的源接着搜。")
                .font(.caption)
                .foregroundColor(theme.palette.secondaryInk)
                .multilineTextAlignment(.center)
            Button("继续搜索", action: onResume)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SearchingOutput: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在搜索全网书籍 (第 1 页)...")
                .font(.subheadline)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NoResultOutput: View {
    let hiddenCount: Int
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            TrialIcon(systemName: "magnifyingglass", regularFont: .largeTitle)
            Text("没找到相关书籍")
                .font(.headline)
                .foregroundColor(theme.palette.secondaryInk)
            Text(hiddenCount > 0
                 ? "搜到 \(hiddenCount) 条，但都不符合当前匹配口径"
                 : "可尝试切换其他书源或更换关键词")
                .font(.caption)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyPromptOutput: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            TrialIcon(systemName: "books.vertical", regularFont: .system(size: 40))
            Text("输入关键词，全网搜。")
                .font(.subheadline)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 学级审判主题下的大图标块；标准主题退回普通 SF Symbol。
private struct TrialIcon: View {
    let systemName: String
    let regularFont: Font
    @Environment(\.appTheme) private var theme

    @ViewBuilder
    var body: some View {
        if theme.isClassTrial {
            Image(systemName: systemName)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(theme.palette.onInk)
                .frame(width: 72, height: 72)
                .background(Rectangle().fill(theme.palette.ink))
                .overlay(alignment: .bottomTrailing) {
                    Rectangle()
                        .fill(theme.palette.accent)
                        .frame(width: 15, height: 15)
                }
                .rotationEffect(.degrees(-3))
                .padding(.bottom, 6)
        } else {
            Image(systemName: systemName)
                .font(regularFont)
                .foregroundColor(theme.palette.secondaryInk.opacity(systemName == "books.vertical" ? 0.5 : 0.6))
        }
    }
}

// MARK: - 历史列表

private struct HistoryOutput: View {
    @ObservedObject var viewModel: SearchViewModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        List {
            Section(header: header.appThemedRows()) {
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

    private var header: some View {
        HStack {
            Text("最近搜索")
            Spacer()
            Button("清空") { viewModel.clearHistory() }
                .font(.caption)
        }
    }
}

// MARK: - 输入框与筛选 chip

/// 灰底输入框，系统 placeholder 太浅，这里自己画一层。
struct PlaceholderField: View {
    @Environment(\.appTheme) private var theme
    let placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.subheadline)
            #if os(iOS)
            .autocapitalization(.none)
            .disableAutocorrection(true)
            #endif
            .onSubmit { onSubmit?() }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(fieldBackground)
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.subheadline)
                        .foregroundColor(theme.palette.secondaryInk)
                        .padding(.horizontal, 12)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if theme.isClassTrial {
                    RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                        .stroke(theme.palette.ink, lineWidth: 2)
                }
            }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
            .fill(theme.isClassTrial ? theme.palette.surface : theme.palette.elevated)
    }
}

struct FilterChip: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected || theme.isClassTrial ? .bold : .regular))
                .padding(EdgeInsets(top: 7, leading: 13, bottom: 7, trailing: 13))
                .background(background)
                .foregroundColor(foreground)
                .cornerRadius(theme.isClassTrial ? 0 : 17)
                .overlay {
                    if theme.isClassTrial {
                        RoundedRectangle(cornerRadius: 0)
                            .stroke(isSelected ? theme.palette.accent : theme.palette.ink, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        if isSelected { return theme.palette.accent }
        return theme.isClassTrial ? theme.palette.surface : theme.palette.elevated
    }

    private var foreground: Color {
        if isSelected { return theme.palette.onAccent }
        return theme.isClassTrial ? theme.palette.ink : .primary
    }
}

// MARK: - 结果行

public struct SearchResultRow: View {
    @Environment(\.appTheme) private var theme
    public let item: SearchBook

    public init(item: SearchBook) {
        self.item = item
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ResultCover(item: item)
            ResultDetails(item: item)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.palette.secondaryInk.opacity(0.5))
        }
        .padding(.vertical, 4)
    }
}

private struct ResultCover: View {
    let item: SearchBook
    @Environment(\.appTheme) private var theme

    var body: some View {
        Group {
            if let raw = item.coverUrl, let url = URL(string: raw) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
                .frame(width: 52, height: 72)
                .cornerRadius(6)
                .clipped()
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.12))
            .frame(width: 52, height: 72)
            .overlay(Image(systemName: "book.closed").foregroundColor(theme.palette.accent))
    }
}

private struct ResultDetails: View {
    let item: SearchBook
    @Environment(\.appTheme) private var theme

    private var intro: String? {
        guard let raw = item.intro, !raw.isEmpty else { return nil }
        let cleaned = BookContentService.cleanHtml(raw)
        guard !cleaned.hasPrefix("源站："), !cleaned.contains("最近同步："), !cleaned.isEmpty else {
            return nil
        }
        return cleaned
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name)
                .font(.headline)
                .lineLimit(2)

            meta

            if let kind = item.kind, !kind.isEmpty {
                Text(kind.replacingOccurrences(of: ",", with: " · "))
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(1)
            }

            if let intro {
                Text(intro)
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk.opacity(0.8))
                    .lineLimit(2)
            }

            if let latest = item.latestChapterTitle, !latest.isEmpty {
                Text("最新: \(latest)")
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meta: some View {
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
}

// MARK: - 限定书源面板

struct SearchSourcePickerSheet: View {
    @ObservedObject var viewModel: SearchViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var query = ""

    private var filteredSources: [BookSource] {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return viewModel.searchableSources }
        return viewModel.searchableSources.filter { source in
            let nameHit = source.bookSourceName.localizedCaseInsensitiveContains(keyword)
            let groupHit = (source.bookSourceGroup ?? "").localizedCaseInsensitiveContains(keyword)
            return nameHit || groupHit
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredSources, id: \.bookSourceUrl) { source in
                        SourcePickRow(
                            source: source,
                            selected: viewModel.selectedSourceUrls.contains(source.bookSourceUrl),
                            action: { toggle(source.bookSourceUrl) }
                        )
                    }
                }
                .padding(16)
            }
            .background(AppThemeBackdrop())
            .searchable(text: $query, prompt: "搜书源名或分组")
            .navigationTitle("限定书源")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("全选") {
                        viewModel.selectedSourceUrls = Set(viewModel.searchableSources.map(\.bookSourceUrl))
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
    }

    private var bottomBar: some View {
        HStack {
            Text("已选 \(viewModel.selectedSourceUrls.count) / \(viewModel.searchableSources.count)")
                .font(theme.typography.mono)
                .foregroundColor(theme.palette.secondaryInk)
            Spacer()
            Button("清空") {
                viewModel.selectedSourceUrls.removeAll()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(theme.palette.accent)
        }
        .padding(16)
        .background(theme.palette.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.palette.divider)
                .frame(height: theme.isClassTrial ? 2 : 0.5)
        }
    }

    private func toggle(_ url: String) {
        if viewModel.selectedSourceUrls.contains(url) {
            viewModel.selectedSourceUrls.remove(url)
        } else {
            viewModel.selectedSourceUrls.insert(url)
        }
    }
}

private struct SourcePickRow: View {
    let source: BookSource
    let selected: Bool
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.palette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.bookSourceName)
                        .font(theme.typography.body)
                        .foregroundColor(theme.palette.ink)
                    if let group = source.bookSourceGroup,
                       !group.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(group)
                            .font(.caption2)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appThemePanel()
        }
        .buttonStyle(.plain)
    }
}
