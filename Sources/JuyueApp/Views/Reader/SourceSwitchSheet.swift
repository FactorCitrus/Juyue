import SwiftUI
#if canImport(JuyueCore)
import JuyueCore
#endif

/// 阅读中点「换源」调出来的候选列表：拿书名/作者去所有启用的书源搜一遍。
public struct SourceSwitchSheet: View {
    let book: Book
    let currentSourceUrl: String?
    let onSelect: (BookSource, SearchBook) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var bookStore = BookStore.shared

    /// 匹配口径与展示偏好记住，下次换源沿用；关键词、限定源是临时的
    @AppStorage("switch_source_match_title") private var matchTitle: Bool = true
    @AppStorage("switch_source_match_author") private var matchAuthor: Bool = false
    @AppStorage("switch_source_exact") private var exactMatch: Bool = false
    @AppStorage("switch_source_show_detail") private var showDetail: Bool = true

    /// 搜回来的原始候选，按当前口径就地筛，改开关不用重搜
    @State private var rawResults: [(source: BookSource, book: SearchBook)] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var finishedSources = 0
    @State private var totalSources = 0
    @State private var errorMessage: String?
    @State private var keyword: String
    @State private var selectedSourceUrls: Set<String> = []
    @State private var showSourcePicker = false
    @State private var isPaused = false
    @State private var runSources: [BookSource] = []
    @State private var reportedSourceUrls: Set<String> = []
    @State private var runKeyword = ""
    /// 搜索条件默认收起，换源时先看候选；收起状态是临时的，每次打开都收着
    @State private var showSearchOptions = false

    public init(
        book: Book,
        currentSourceUrl: String?,
        onSelect: @escaping (BookSource, SearchBook) -> Void
    ) {
        self.book = book
        self.currentSourceUrl = currentSourceUrl
        self.onSelect = onSelect
        // 名字特别短的书（「家」「序」这种）按书名搜全是噪音，默认用作者当关键词
        let shortTitle = book.name.trimmingCharacters(in: .whitespaces).count <= 2
        self._keyword = State(initialValue: (shortTitle && !book.author.isEmpty) ? book.author : book.name)
    }

    private var options: SourceMatchOptions {
        SourceMatchOptions(matchTitle: matchTitle, matchAuthor: matchAuthor, exact: exactMatch)
    }

    private var results: [(source: BookSource, book: SearchBook)] {
        rawResults.filter {
            (selectedSourceUrls.isEmpty || selectedSourceUrls.contains($0.source.bookSourceUrl))
                && SourceMatchRules.matches($0.book, title: book.name, author: book.author, options: options)
        }
    }

    private var enabledSources: [BookSource] {
        bookStore.sources.filter { $0.enabled != false && $0.searchUrl != nil }
    }

    /// 给提示用：现在是按什么口径筛的
    private var criteriaText: String {
        var fields: [String] = []
        if matchTitle { fields.append("书名") }
        if matchAuthor { fields.append("作者") }
        let fieldText = fields.isEmpty ? "未选字段" : fields.joined(separator: "+")
        return "\(fieldText)·\(exactMatch ? "精确" : "包含")"
    }

    public var body: some View {
        let palette = NieRPalette(colorScheme)

        ZStack {
            NieRBackdrop(palette: palette)

            VStack(spacing: 0) {
                NieRSheetHeader(
                    palette: palette,
                    kicker: "SOURCE TRANSFER",
                    title: "换源",
                    subtitle: "\(isSearching ? "SCANNING" : (isPaused ? "PAUSED" : "READY")) · \(results.count) NODES"
                ) {
                    searchTask?.cancel()
                    dismiss()
                }

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        targetPanel(palette)
                        searchPanel(palette)

                        if isSearching || isPaused {
                            scanningPanel(palette)
                        }

                        if let errorMessage {
                            messagePanel(palette, title: "ERROR", text: errorMessage)
                        }

                        if !results.isEmpty {
                            NieRSectionTitle(
                                palette: palette,
                                index: "02",
                                title: "AVAILABLE NODES",
                                trailing: "\(results.count)"
                            )
                            .padding(.horizontal, 16)

                            ForEach(Array(results.enumerated()), id: \.element.book.id) { index, item in
                                resultCard(index: index, item: item, palette: palette)
                            }
                        } else if !isSearching {
                            emptyPanel(palette)
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
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
        .sheet(isPresented: $showSourcePicker) {
            SourceSwitchSourcePicker(
                sources: enabledSources,
                selection: $selectedSourceUrls,
                currentSourceUrl: currentSourceUrl,
                palette: palette
            )
        }
    }

    private func targetPanel(_ palette: NieRPalette) -> some View {
        NieRPanel(palette: palette, raised: true) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("TARGET / 目标书籍")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(palette.accent)
                    Spacer()
                    Text("BOOK")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(palette.muted)
                }
                Text(book.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(palette.ink)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Text(book.originName.isEmpty ? "未知来源" : book.originName)
                    if !book.author.isEmpty {
                        Text("作者 \(cleanAuthor(book.author))")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(palette.muted)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
    }

    private func searchPanel(_ palette: NieRPalette) -> some View {
        NieRPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showSearchOptions.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("01")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(palette.accent)
                        Text("PARAM / 搜索条件")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundColor(palette.muted)
                        Spacer()
                        Image(systemName: showSearchOptions ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(palette.accent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("\(criteriaText) · 「\(keyword)」")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.ink)
                    .lineLimit(1)

                if showSearchOptions {
                    NieRDivider(palette: palette)
                    toggleRow("匹配书名", isOn: $matchTitle, palette: palette)
                    toggleRow("匹配作者", isOn: $matchAuthor, palette: palette)
                    toggleRow("精确匹配", isOn: $exactMatch, palette: palette)

                    if !matchTitle && !matchAuthor {
                        Text("至少选一个匹配条件。")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(palette.accent)
                    }

                    NieRDivider(palette: palette)
                    HStack(spacing: 8) {
                        nierField("关键词", text: $keyword, palette: palette)
                        if isSearching {
                            searchActionButton("暂停", filled: false, palette: palette) { pauseSearch() }
                        } else if isPaused {
                            searchActionButton("继续", filled: true, palette: palette) { resumeSearch() }
                        } else {
                            searchActionButton("搜索", filled: true, palette: palette) { startSearch() }
                                .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty || (!matchTitle && !matchAuthor))
                        }
                    }
                    Button {
                        showSourcePicker = true
                    } label: {
                        HStack(spacing: 8) {
                            Text("限定源")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(palette.muted)
                            Spacer(minLength: 0)
                            Text(selectedSourceUrls.isEmpty
                                 ? "全部源"
                                 : "已选 \(selectedSourceUrls.count) / \(enabledSources.count)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(palette.accent)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(palette.accent)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(palette.background.opacity(0.7))
                        .overlay(Rectangle().stroke(palette.line.opacity(0.7), lineWidth: 0.6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    toggleRow("显示书籍详情", isOn: $showDetail, palette: palette)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func scanningPanel(_ palette: NieRPalette) -> some View {
        NieRPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(isPaused ? "PAUSED" : "SCANNING")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(palette.accent)
                    Spacer()
                    Text("\(finishedSources) / \(totalSources)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(palette.muted)
                }
                NieRScanBar(
                    palette: palette,
                    progress: totalSources > 0 ? Double(finishedSources) / Double(totalSources) : 0
                )
                if isPaused {
                    Text("已找到 \(rawResults.count) 本 · 继续会从未完成的源接着搜")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(palette.muted)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func searchActionButton(
        _ title: String,
        filled: Bool,
        palette: NieRPalette,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(filled ? palette.background : palette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(filled ? palette.accent : palette.panel)
            .overlay(Rectangle().stroke(palette.accent.opacity(filled ? 0 : 0.7), lineWidth: 0.8))
    }

    private func resultCard(
        index: Int,
        item: (source: BookSource, book: SearchBook),
        palette: NieRPalette
    ) -> some View {
        let isCurrent = item.source.bookSourceUrl == currentSourceUrl
            && item.book.bookUrl == book.bookUrl

        return Button {
            onSelect(item.source, item.book)
            dismiss()
        } label: {
            NieRPanel(palette: palette, raised: isCurrent) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 4) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.accent)
                        Rectangle()
                            .fill(isCurrent ? palette.accent : palette.line.opacity(0.5))
                            .frame(width: 1, height: 28)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.book.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(palette.ink)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            if isCurrent {
                                NieRBadge(palette: palette, text: "ACTIVE", filled: true)
                            }
                        }

                        Text("NODE · \(item.source.bookSourceName)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(palette.muted)
                            .lineLimit(1)

                        if showDetail {
                            if !item.book.author.isEmpty {
                                Text("AUTHOR · \(cleanAuthor(item.book.author))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(palette.muted)
                                    .lineLimit(1)
                            }
                            let meta = cleanMeta([item.book.kind, item.book.wordCount])
                            if !meta.isEmpty {
                                Text(meta.joined(separator: " · "))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(palette.muted)
                                    .lineLimit(1)
                            }
                            if let latest = item.book.latestChapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !latest.isEmpty {
                                Text("LATEST · \(latest)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(palette.muted)
                                    .lineLimit(1)
                            }
                            if let intro = item.book.intro, !intro.isEmpty {
                                Text(intro)
                                    .font(.system(size: 11))
                                    .foregroundColor(palette.muted)
                                    .lineLimit(2)
                            }
                        }
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(palette.accent.opacity(0.7))
                        .padding(.top, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private func emptyPanel(_ palette: NieRPalette) -> some View {
        messagePanel(
            palette,
            title: "NO SIGNAL",
            text: rawResults.isEmpty
                ? "没有在其他书源找到这本书。换个匹配方式或关键词再试。"
                : "搜到 \(rawResults.count) 条，但都不符合当前条件。放宽条件或关掉精确匹配再试。"
        )
    }

    private func messagePanel(_ palette: NieRPalette, title: String, text: String) -> some View {
        NieRPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(palette.accent)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(palette.ink.opacity(0.82))
            }
        }
        .padding(.horizontal, 16)
    }

    private func nierField(_ placeholder: String, text: Binding<String>, palette: NieRPalette) -> some View {
        ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.muted.opacity(0.7))
                    .padding(.horizontal, 8)
            }
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(palette.ink)
                #if os(iOS)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                #endif
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
        }
        .background(palette.background.opacity(0.7))
        .overlay(
            Rectangle()
                .stroke(palette.line.opacity(0.7), lineWidth: 0.6)
        )
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, palette: NieRPalette) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(palette.ink)
        }
        .tint(palette.accent)
    }

    private func cleanAuthor(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["作 者：", "作 者:", "作者：", "作者:"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanMeta(_ parts: [String?]) -> [String] {
        parts.compactMap { raw in
            guard let raw else { return nil }
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = value.first, ",，、;；:： ".contains(first) {
                value.removeFirst()
            }
            return value.isEmpty ? nil : value
        }
    }

    private func startSearch() {
        searchTask?.cancel()
        rawResults = []
        errorMessage = nil
        finishedSources = 0

        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmedKeyword.isEmpty else {
            isSearching = false
            errorMessage = "先填关键词。"
            return
        }
        guard matchTitle || matchAuthor else {
            isSearching = false
            errorMessage = "先选一个匹配条件。"
            return
        }

        let sources = selectedSourceUrls.isEmpty
            ? enabledSources
            : enabledSources.filter { selectedSourceUrls.contains($0.bookSourceUrl) }
        totalSources = sources.count
        isSearching = !sources.isEmpty
        guard !sources.isEmpty else {
            errorMessage = "没有可搜索的书源，先去设置里导入或重新勾选。"
            return
        }

        let requestKey = requestKeyword(from: trimmedKeyword)

        searchTask = Task {
            let stream = BookSearchService.shared.searchMultiSources(sources: sources, key: requestKey, page: 1)
            for await (source, books) in stream {
                if Task.isCancelled { return }
                await MainActor.run {
                    finishedSources += 1
                    // 原样收着，展示时按当前口径筛（改开关不用重新搜一遍）
                    for candidate in books {
                        if !rawResults.contains(where: { $0.book.bookUrl == candidate.bookUrl }) {
                            rawResults.append((source: source, book: candidate))
                        }
                    }
                }
            }
            await MainActor.run {
                isSearching = false
            }
        }
    }

    /// 搜索接口一般只认书名，带空格的关键词取最长的那一段去请求
    private func requestKeyword(from raw: String) -> String {
        let parts = raw.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return parts.max(by: { $0.count < $1.count }) ?? raw
    }

}

/// 换源页的「限定源」多选面板。不选表示全部启用源；
/// 勾选后既限制这一轮换源要扫的源，也即时过滤已返回的候选。
private struct SourceSwitchSourcePicker: View {
    let sources: [BookSource]
    @Binding var selection: Set<String>
    let currentSourceUrl: String?
    let palette: NieRPalette
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filteredSources: [BookSource] {
        let key = query.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return sources }
        return sources.filter {
            $0.bookSourceName.localizedCaseInsensitiveContains(key)
                || ($0.bookSourceGroup ?? "").localizedCaseInsensitiveContains(key)
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundColor(palette.muted)
                        TextField("搜索书源…", text: $query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(palette.ink)
                            #if os(iOS)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            #endif
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(palette.panel)
                    .overlay(Rectangle().stroke(palette.line.opacity(0.7), lineWidth: 0.6))

                    Text(selection.isEmpty
                         ? "未选择 = 全部启用源 · \(sources.count) 个"
                         : "已选 \(selection.count) / \(sources.count) 个源")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(palette.muted)

                    LazyVStack(spacing: 8) {
                        ForEach(filteredSources, id: \.bookSourceUrl) { source in
                            sourceRow(source)
                        }
                    }
                }
                .padding(16)
            }
            .background(NieRBackdrop(palette: palette))
            .navigationTitle("限定源")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("清空") { selection.removeAll() }
                        .disabled(selection.isEmpty)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("全选") { selection = Set(sources.map(\.bookSourceUrl)) }
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func sourceRow(_ source: BookSource) -> some View {
        let isOn = selection.contains(source.bookSourceUrl)
        return Button {
            if isOn {
                selection.remove(source.bookSourceUrl)
            } else {
                selection.insert(source.bookSourceUrl)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.bookSourceName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(palette.ink)
                        .lineLimit(1)
                    if let group = source.bookSourceGroup,
                       !group.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(group)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(palette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if source.bookSourceUrl == currentSourceUrl {
                    Text("当前")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(palette.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(Rectangle().stroke(palette.accent.opacity(0.6), lineWidth: 0.6))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.panel)
            .overlay(Rectangle().stroke(palette.line.opacity(0.7), lineWidth: 0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
