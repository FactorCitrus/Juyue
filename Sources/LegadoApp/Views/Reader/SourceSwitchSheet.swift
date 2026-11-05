import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
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
    /// 跨源同 URL 是两本不同的书，去重按 SearchBook.id（origin + bookUrl）
    @State private var seenResultIds: Set<String> = []
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
    @State private var failures = SourceSwitchFailureSummary()
    @State private var showFailureDetails = false
    @State private var runKeyword = ""
    @State private var runSelectedSourceUrls: Set<String> = []
    @State private var searchRunId = UUID()
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
        let author = Self.cleanAuthor(book.author)
        self._keyword = State(initialValue: (shortTitle && !author.isEmpty) ? author : book.name)
    }

    private var options: SourceMatchOptions {
        SourceMatchOptions(matchTitle: matchTitle, matchAuthor: matchAuthor, exact: exactMatch)
    }

    private var results: [(source: BookSource, book: SearchBook)] {
        let filtered = rawResults.filter {
            (selectedSourceUrls.isEmpty || selectedSourceUrls.contains($0.source.bookSourceUrl))
                && SourceMatchRules.matches($0.book, title: book.name, author: book.author, options: options)
        }
        return SourceSwitchResultOrdering.sorted(
            filtered,
            title: book.name,
            author: book.author,
            currentSourceUrl: currentSourceUrl
        )
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
        let visibleResults = results

        ZStack {
            NieRBackdrop(palette: palette)

            VStack(spacing: 0) {
                NieRSheetHeader(
                    palette: palette,
                    kicker: "SOURCE TRANSFER",
                    title: "换源",
                    subtitle: "\(isSearching ? "SCANNING" : (isPaused ? "PAUSED" : "READY")) · \(visibleResults.count) NODES"
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

                        if !failures.isEmpty && !isSearching {
                            failurePanel(palette, hasResults: !visibleResults.isEmpty)
                        }

                        if !visibleResults.isEmpty {
                            NieRSectionTitle(
                                palette: palette,
                                index: "02",
                                title: "AVAILABLE NODES",
                                trailing: "\(visibleResults.count)"
                            )
                            .padding(.horizontal, 16)

                            ForEach(Array(visibleResults.enumerated()), id: \.element.book.id) { index, item in
                                resultCard(index: index, item: item, palette: palette)
                            }
                        } else if !isSearching && !isPaused {
                            emptyPanel(palette)
                        }
                    }
                    .padding(.bottom, 28)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
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
                        Text("作者 \(Self.cleanAuthor(book.author))")
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
        Button {
            if isPaused {
                resumeSearch()
            } else if isSearching {
                pauseSearch()
            }
        } label: {
            NieRPanel(palette: palette) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(palette.accent)
                        Text(isPaused ? "PAUSED" : "SCANNING")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundColor(palette.accent)
                        Spacer()
                        HStack(spacing: 6) {
                            Text("\(finishedSources) / \(totalSources)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(palette.muted)
                            if !failures.isEmpty {
                                Text("· 失败 \(failures.count)")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(palette.accent)
                            }
                        }
                    }
                    NieRScanBar(
                        palette: palette,
                        progress: totalSources > 0 ? Double(finishedSources) / Double(totalSources) : 0
                    )
                    Text(scanHintText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPaused ? "已暂停搜索，双击继续" : "正在搜索，双击暂停")
        .accessibilityAddTraits(.isButton)
        .padding(.horizontal, 16)
    }

    private var scanHintText: String {
        let failureSuffix = failures.isEmpty ? "" : " · \(failures.count) 个源失败"
        if isPaused {
            return "点击继续 · 已找到 \(rawResults.count) 本\(failureSuffix)，从未完成的源接着搜"
        }
        return "点击暂停 · 已找到 \(rawResults.count) 本\(failureSuffix)"
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
        // 旧目录地址指向别的站点时，这条「当前源」其实要重换一次才能把目录拉回本源。
        let tocMatches = book.tocUrl.isEmpty || Self.host(of: book.tocUrl) == Self.host(of: item.book.bookUrl)
        let isCurrent = item.source.bookSourceUrl == currentSourceUrl
            && item.book.bookUrl == book.bookUrl
            && tocMatches

        return Button {
            // 当前源没有可换的目标：直接关掉，别清缓存把同一本书重载一遍。
            guard !isCurrent else {
                dismiss()
                return
            }
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
                                Text("AUTHOR · \(Self.cleanAuthor(item.book.author))")
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
        let state = SourceSwitchEmptyState.resolve(
            rawResultCount: rawResults.count,
            failureCount: failures.count,
            sourceCount: totalSources
        )
        return messagePanel(palette, title: state.title, text: state.message)
    }

    /// 失败源列表：默认收起成一句「另有 N 个源失败」，点开看源名和原因。
    private func failurePanel(_ palette: NieRPalette, hasResults: Bool) -> some View {
        NieRPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showFailureDetails.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("FAILED NODES")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundColor(palette.accent)
                        Text("· \(failures.count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(palette.accent)
                        Spacer()
                        Text(showFailureDetails ? "收起" : "查看原因")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(palette.muted)
                        Image(systemName: showFailureDetails ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(palette.accent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(hasResults
                     ? "另有 \(failures.count) 个源失败，不影响下面的候选。"
                     : "\(failures.count) 个源失败。")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.ink.opacity(0.82))

                if showFailureDetails {
                    NieRDivider(palette: palette)
                    ForEach(failures.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.sourceName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(palette.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(entry.reason)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(palette.muted)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(2)
                        }
                    }

                    if !isSearching && !isPaused {
                        Button("重试失败源") { retryFailedSources() }
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(palette.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .overlay(Rectangle().stroke(palette.accent.opacity(0.7), lineWidth: 0.8))
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
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

    private static func host(of address: String) -> String {
        URL(string: address)?.host?.lowercased() ?? ""
    }

    private static func cleanAuthor(_ raw: String) -> String {
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

    private func startSearch(resuming: Bool = false) {
        searchTask?.cancel()
        searchTask = nil
        errorMessage = nil

        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmedKeyword.isEmpty else {
            isSearching = false
            isPaused = false
            errorMessage = "先填关键词。"
            return
        }
        guard matchTitle || matchAuthor else {
            isSearching = false
            isPaused = false
            errorMessage = "先选一个匹配条件。"
            return
        }

        if !resuming {
            let sources = selectedSourceUrls.isEmpty
                ? enabledSources
                : enabledSources.filter { selectedSourceUrls.contains($0.bookSourceUrl) }
            guard !sources.isEmpty else {
                isSearching = false
                isPaused = false
                errorMessage = "没有可搜索的书源，先去设置里导入或重新勾选。"
                return
            }
            rawResults = []
            seenResultIds = []
            failures.removeAll()
            showFailureDetails = false
            finishedSources = 0
            isPaused = false
            runSources = sources
            totalSources = sources.count
            reportedSourceUrls = []
            runKeyword = requestKeyword(from: trimmedKeyword)
            runSelectedSourceUrls = selectedSourceUrls
        }

        let remaining = resuming
            ? runSources.filter { !reportedSourceUrls.contains($0.bookSourceUrl) }
            : runSources
        guard !remaining.isEmpty else {
            isSearching = false
            isPaused = false
            return
        }

        isSearching = true
        isPaused = false
        let runId = UUID()
        searchRunId = runId
        searchTask = Task {
            let stream = BookSearchService.shared.searchMultiSourcesDetailed(
                sources: remaining,
                key: runKeyword,
                page: 1
            )
            for await outcome in stream {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard searchRunId == runId else { return }
                    reportedSourceUrls.insert(outcome.source.bookSourceUrl)
                    finishedSources = min(totalSources, finishedSources + 1)
                    if let failure = outcome.failure {
                        failures.record(source: outcome.source, failure: failure)
                        return
                    }
                    failures.clear(sourceUrl: outcome.source.bookSourceUrl)
                    // 原样收着，展示时按当前口径筛（改开关不用重新搜一遍）
                    for candidate in outcome.books where !seenResultIds.contains(candidate.id) {
                        seenResultIds.insert(candidate.id)
                        rawResults.append((source: outcome.source, book: candidate))
                    }
                }
            }
            await MainActor.run {
                // 取消后再到达的收尾不能把「已暂停」冲掉
                guard searchRunId == runId else { return }
                if !isPaused {
                    isSearching = false
                }
            }
        }
    }

    private func pauseSearch() {
        guard isSearching else { return }
        searchTask?.cancel()
        searchTask = nil
        // 换 runId 后，极端情况下取消前已排队的结果也会被丢弃，不会混进列表
        searchRunId = UUID()
        isSearching = false
        isPaused = true
    }

    private func resumeSearch() {
        guard isPaused else { return }
        // 暂停期间只有关键词和限定源变了才需要重搜；匹配开关只过滤已搜结果
        let criteriaChanged = SourceSwitchCriteria.requiresRestart(
            previous: SourceSwitchCriteria(keyword: runKeyword, sourceUrls: runSelectedSourceUrls),
            current: SourceSwitchCriteria(keyword: requestKeyword(from: keyword), sourceUrls: selectedSourceUrls)
        )
        if criteriaChanged {
            startSearch()
        } else {
            startSearch(resuming: true)
        }
    }

    /// 只重跑这一轮失败的源：把它们从「已上报」里摘出去，再走续跑路径。
    private func retryFailedSources() {
        guard !isSearching, !isPaused, !failures.isEmpty else { return }
        let failedUrls = Set(failures.entries.map(\.sourceUrl))
        failures.removeAll()
        showFailureDetails = false
        reportedSourceUrls.subtract(failedUrls)
        finishedSources = max(0, finishedSources - failedUrls.count)
        startSearch(resuming: true)
    }

    /// 搜索接口一般只认书名，带空格的关键词取最长的那一段去请求
    private func requestKeyword(from raw: String) -> String {
        let parts = raw.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return parts.max(by: { $0.count < $1.count }) ?? raw
    }

}

private struct SourceSwitchSourceGroup: Identifiable {
    let name: String
    let sources: [BookSource]
    var id: String { name }
}

/// 换源页的「限定源」多选面板。不选表示全部启用源；
/// 勾选后既限制这一轮换源要扫的源，也即时过滤已返回的候选。
private struct SourceSwitchSourcePicker: View {    let sources: [BookSource]
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

    private var groupedSources: [SourceSwitchSourceGroup] {
        var order: [String] = []
        var map: [String: [BookSource]] = [:]
        for source in filteredSources {
            let names = groupNames(for: source)
            for name in names.isEmpty ? ["未分组"] : names {
                if map[name] == nil {
                    order.append(name)
                    map[name] = []
                }
                map[name]?.append(source)
            }
        }
        let sorted = order.sorted { lhs, rhs in
            if lhs == "未分组" { return false }
            if rhs == "未分组" { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return sorted.map { SourceSwitchSourceGroup(name: $0, sources: map[$0] ?? []) }
    }

    private func groupNames(for source: BookSource) -> [String] {
        (source.bookSourceGroup ?? "")
            .split(whereSeparator: { ",，、;；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func groupRow(_ name: String, sources: [BookSource]) -> some View {
        let urls = Set(sources.map(\.bookSourceUrl))
        let selectedCount = urls.intersection(selection).count
        let allSelected = !urls.isEmpty && selectedCount == urls.count
        let partiallySelected = selectedCount > 0 && !allSelected
        return Button {
            if allSelected {
                selection.subtract(urls)
            } else {
                selection.formUnion(urls)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: allSelected
                      ? "checkmark.square.fill"
                      : (partiallySelected ? "minus.square.fill" : "square"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(palette.accent)
                Text(name)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundColor(palette.ink)
                Spacer(minLength: 0)
                Text("\(selectedCount)/\(urls.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(palette.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(palette.background.opacity(0.55))
            .overlay(Rectangle().stroke(palette.line.opacity(0.55), lineWidth: 0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        ForEach(groupedSources) { group in
                            groupRow(group.name, sources: group.sources)
                            ForEach(group.sources, id: \.bookSourceUrl) { source in
                                sourceRow(source)
                            }
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
            .stackNavigationStyle()
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
