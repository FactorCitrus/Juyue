import SwiftUI
#if canImport(JuyueCore)
import JuyueCore
#endif
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import PhotosUI
#endif

public struct BookDetailView: View {
    @ObservedObject private var store = BookStore.shared
    @ObservedObject private var downloadManager = ChapterDownloadManager.shared

    @State private var sourceOverride: BookSource?
    @State private var snapshot: Book
    @State private var toc: [BookChapter] = []
    @State private var loadingDetail = false
    @State private var loadError: String?
    @State private var showTOC = false
    @State private var introExpanded = false
    @State private var reading = false
    @State private var readingIndex: Int
    @State private var alertVisible = false
    @State private var editing = false
    @State private var coverPicker = false
    @State private var sourcePicker = false
    @State private var alertText = ""
    @State private var draftName = ""
    @State private var draftAuthor = ""
    @State private var draftCover = ""
    @State private var shareChoiceVisible = false
    @State private var shareJobID: UUID? = nil
    @State private var shareCancelled = false
    @State private var setupRequest: DownloadSetupRequest? = nil

    public init(
        book: Book,
        source: BookSource? = nil
    ) {
        self._sourceOverride = State(initialValue: source)
        self._snapshot = State(initialValue: book)
        self._readingIndex = State(initialValue: book.durChapterIndex)
    }

    public init(
        searchBook: SearchBook,
        source: BookSource? = nil
    ) {
        self.init(
            book: Book(
                bookUrl: searchBook.bookUrl,
                name: searchBook.name,
                author: searchBook.author,
                kind: searchBook.kind,
                coverUrl: searchBook.coverUrl,
                intro: searchBook.intro,
                origin: searchBook.origin,
                originName: searchBook.originName,
                wordCount: searchBook.wordCount,
                latestChapterTitle: searchBook.latestChapterTitle
            ),
            source: source
        )
    }

    private var onShelf: Bool {
        store.bookshelf.contains { $0.bookUrl == snapshot.bookUrl }
    }

    private var shelfSnapshot: Book {
        store.bookshelf.first { $0.bookUrl == snapshot.bookUrl } ?? snapshot
    }

    private var activeSource: BookSource? {
        // override 只在它仍对应当前书籍来源时有效；换源后 origin 已变，回落到 store 查新源。
        if let override = sourceOverride, override.bookSourceUrl == snapshot.origin {
            return override
        }
        return store.findSource(for: snapshot)
    }

    private var mediaKind: BookSource.Kind {
        activeSource?.kind ?? .text
    }

    private var tagList: [String] {
        guard let kind = snapshot.kind, !kind.isEmpty else { return [] }
        var result: [String] = []
        for part in kind.split(whereSeparator: { ",，/| ".contains($0) }) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
        }
        return result
    }

    private var summaryText: String? {
        guard let intro = snapshot.intro, !intro.isEmpty else { return nil }
        let looksLikeMetadata = intro.hasPrefix("源站：") || intro.contains("最近同步：")
        guard !looksLikeMetadata else { return nil }
        let plain = BookContentService.cleanHtml(intro)
        return plain.isEmpty ? nil : plain
    }

    @ViewBuilder
    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                detailContent
            }
            DetailActionBar(
                onShelf: onShelf,
                kind: mediaKind,
                canRead: activeSource != nil || snapshot.origin == "local",
                continued: shelfSnapshot.durChapterIndex > 0,
                onToggleShelf: { toggleShelf() },
                onRead: { startReading() }
            )
        }
        .overlay {
            #if !os(iOS)
            if reading {
                readerLayer
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .background { Color.black }
                    .transition(AnyTransition.opacity)
            }
            #endif
        }
        .appThemePageBackground()
        .navigationTitle("书籍详情")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { topMenu }
        .alert(alertText, isPresented: $alertVisible) {
            Button(role: .cancel) {} label: { Text("确定") }
        }
        .sheet(isPresented: $coverPicker) { coverSheet }
        .sheet(isPresented: $sourcePicker) { sourceSheet }
        .sheet(isPresented: $editing) { editSheet }
        .sheet(item: $setupRequest) { request in
            DownloadSetupSheet(
                bookTitle: snapshot.name,
                bookUrl: snapshot.bookUrl,
                chapterCount: toc.count,
                currentIndex: request.currentIndex,
                preferredScope: request.scope
            ) { scope, indices, options in
                startDownload(scope: scope, indices: indices, options: options)
            }
        }
        .confirmationDialog("分享离线包", isPresented: $shareChoiceVisible, titleVisibility: .visible) {
            Button(shareCachedLabel) { shareOfflinePackage(wholeBook: false) }
            Button(shareWholeLabel) { shareOfflinePackage(wholeBook: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("离线包带上正文、书评和封面，对方导入后断网也能读。")
        }
        .overlay {
            if let job = activeShareJob {
                shareProgressCard(job)
            }
        }
        .background(tocDestination)
        #if os(iOS)
        .fullScreenCover(isPresented: $reading) { readerLayer }
        #endif
        .task { await loadDetailIfNeeded() }
    }

    private var detailContent: some View {
        VStack(spacing: 16) {
            BookDetailHeader(
                book: snapshot,
                shelfBook: shelfSnapshot,
                kind: mediaKind,
                loading: loadingDetail,
                onCover: { coverPicker = true },
                onEdit: { beginEditing() }
            )
            .padding(.horizontal)
            .padding(.top, 12)

            if !tagList.isEmpty {
                TagStrip(tags: tagList)
                    .padding(.horizontal)
            }

            TOCPreviewCard(
                book: snapshot,
                chapters: toc,
                loading: loadingDetail,
                error: loadError,
                onOpen: { showTOC = true }
            )
            .padding(.horizontal)

            IntroPanel(
                text: summaryText,
                loading: loadingDetail,
                expanded: $introExpanded
            )
            .padding(.horizontal)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    @ToolbarContentBuilder
    private var topMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { sourcePicker = true } label: {
                    Label("换源", systemImage: "arrow.triangle.2.circlepath")
                }
                Button { beginEditing() } label: {
                    Label("编辑书名 / 作者 / 封面", systemImage: "pencil")
                }
                Button(role: .destructive) { wipeCache() } label: {
                    Label("清除缓存", systemImage: "trash")
                }
                Button { Task { await refreshDetail() } } label: {
                    Label("刷新目录与详情", systemImage: "arrow.clockwise")
                }
                Button { enqueueAll() } label: {
                    Label("缓存全本", systemImage: "arrow.down.circle")
                }
                Button { enqueueRemaining() } label: {
                    Label("缓存未读章节", systemImage: "arrow.down.to.line")
                }
                Button { shareChoiceVisible = true } label: {
                    Label("导出离线包", systemImage: "square.and.arrow.up")
                }
                Button { beginEditing() } label: {
                    Label("编辑书名 / 作者 / 封面", systemImage: "pencil")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
            }
        }
    }

    private var coverSheet: some View {
        BookCoverPickerSheet(bookName: snapshot.name, currentCover: snapshot.coverUrl) { picked in
            var changed = snapshot
            changed.coverUrl = picked.isEmpty ? nil : picked
            snapshot = changed
            persistIfOnShelf(changed)
        }
    }

    private var sourceSheet: some View {
        SourceSwitchSheet(book: snapshot, currentSourceUrl: activeSource?.bookSourceUrl) { newSource, candidate in
            switchSource(to: newSource, candidate: candidate)
        }
    }

    private var editSheet: some View {
        BookInfoEditSheet(name: draftName, author: draftAuthor, coverUrl: draftCover) { name, author, cover in
            var changed = snapshot
            changed.name = name
            changed.author = author
            changed.coverUrl = cover.isEmpty ? nil : cover
            snapshot = changed
            persistIfOnShelf(changed)
            presentAlert("已保存")
        }
    }

    private var tocDestination: some View {
        NavigationLink(
            isActive: $showTOC,
            destination: {
                ChapterListView(
                    items: toc,
                    highlightedIndex: shelfSnapshot.durChapterIndex,
                    onPick: { index in
                        readingIndex = index
                        reading = true
                    }
                )
            },
            label: { EmptyView() }
        )
        .hidden()
        .frame(width: 0, height: 0)
    }

    private var readerLayer: some View {
        let active = onShelf ? shelfSnapshot : snapshot
        let resolved = activeSource
        let list = toc.isEmpty
            ? [BookChapter(
                bookUrl: active.bookUrl,
                url: active.tocUrl.isEmpty ? active.bookUrl : active.tocUrl,
                title: active.name,
                index: 0
            )]
            : toc

        return NavigationView {
            if resolved == nil || resolved?.kind == .text {
                ReaderView(
                    book: active,
                    source: resolved,
                    initialChapterIndex: readingIndex,
                    onDismiss: { reading = false }
                )
            } else if let resolved {
                MediaBookReaderView(
                    book: active,
                    source: resolved,
                    chapters: list,
                    initialChapterIndex: readingIndex
                ) {
                    reading = false
                }
            }
        }
            .stackNavigationStyle()
    }

    private func beginEditing() {
        draftName = snapshot.name
        draftAuthor = snapshot.author
        draftCover = snapshot.coverUrl ?? ""
        editing = true
    }

    private func persistIfOnShelf(_ book: Book) {
        guard onShelf else { return }
        _ = store.saveOrUpdateBook(book, overwriteCover: true)
    }

    private func presentAlert(_ message: String) {
        alertText = message
        alertVisible = true
    }

    private func wipeCache() {
        let count = BookContentService.shared.getCacheCount(for: snapshot.bookUrl)
        BookContentService.shared.clearCache(for: snapshot.bookUrl)
        presentAlert(count > 0 ? "已清除本书缓存章节 (\(count)章)" : "已清除本书缓存章节")
    }

    private func refreshDetail() async {
        await loadDetailIfNeeded()
        presentAlert("目录与详情已刷新")
    }

    private var offlineCachedCount: Int {
        OfflineBookStore.shared.cachedIndices(for: snapshot.bookUrl).count
    }

    private var shareCachedLabel: String {
        "只分享已缓存（\(offlineCachedCount) 章）"
    }

    private var shareWholeLabel: String {
        guard !toc.isEmpty else { return "补全全书后分享" }
        let missing = max(0, toc.count - offlineCachedCount)
        return missing > 0 ? "补全全书后分享（缺 \(missing) 章）" : "分享全书（已全部缓存）"
    }

    private var activeShareJob: DownloadJob? {
        guard let id = shareJobID else { return nil }
        return downloadManager.jobs.first { $0.id == id }
    }

    private func shareProgressCard(_ job: DownloadJob) -> some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                Text("正在补全《\(job.bookName)》")
                    .font(.system(size: 15, weight: .semibold))
                ProgressView(value: job.progress)
                Text("\(job.finished)/\(job.total) 章" + (job.currentChapter.isEmpty ? "" : " · \(job.currentChapter)"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Button("取消补全") {
                    shareCancelled = true
                    downloadManager.cancel(job.id)
                    shareJobID = nil
                }
                .font(.system(size: 13))
                .foregroundColor(.red)
            }
            .padding(18)
            .frame(maxWidth: 300)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// 把正文、书评与封面打成一个离线包，走系统分享
    private func shareOfflinePackage(wholeBook: Bool) {
        Task {
            if toc.isEmpty { await loadDetailIfNeeded() }
            guard !toc.isEmpty else {
                presentAlert("目录还没加载，先刷新目录再导出")
                return
            }
            if wholeBook {
                let cached = Set(OfflineBookStore.shared.cachedIndices(for: snapshot.bookUrl))
                let missing = toc.indices.filter { !cached.contains($0) }
                if !missing.isEmpty {
                    guard let source = activeSource else {
                        presentAlert("本地导入的书没有书源，只能分享已缓存的内容")
                        return
                    }
                    // 传全书章号：正文已有缓存会直接跳过，书评缺失的章顺带补齐
                    guard let result = downloadManager.start(
                        book: snapshot,
                        chapters: toc,
                        source: source,
                        indices: Array(toc.indices),
                        options: DownloadOptions(reviewLimit: nil, refetchReviews: false, concurrency: 4, background: true)
                    ) else {
                        presentAlert("目录为空，没有可下载的章节")
                        return
                    }
                    shareJobID = result.jobID
                    shareCancelled = false
                    await downloadManager.wait(result.jobID)
                    shareJobID = nil
                    if shareCancelled { return }
                }
            }
            do {
                let url = try OfflineBookShare.export(book: snapshot, chapters: toc)
                presentShareSheet(url: url)
            } catch {
                presentAlert("导出失败：\(error.localizedDescription)")
            }
        }
    }

    private func enqueueAll() {
        guard !toc.isEmpty else {
            presentAlert("目录还没加载，先刷新目录再下载")
            return
        }
        setupRequest = DownloadSetupRequest(scope: .all, currentIndex: 0)
    }

    private func enqueueRemaining() {
        guard !toc.isEmpty else {
            presentAlert("目录还没加载，先刷新目录再下载")
            return
        }
        let current = min(max(0, snapshot.durChapterIndex), toc.count - 1)
        setupRequest = DownloadSetupRequest(scope: .unread, currentIndex: current)
    }

    private func startDownload(scope: DownloadScope, indices: [Int], options: DownloadOptions) {
        guard !indices.isEmpty else { return }
        guard let result = downloadManager.start(
            book: snapshot,
            chapters: toc,
            source: activeSource,
            indices: indices,
            options: options
        ) else {
            presentAlert("加入下载队列失败，请稍后再试")
            return
        }
        if result.merged {
            presentAlert("已并入正在进行的任务（共 \(result.totalChapters) 章）")
        } else {
            presentAlert("已加入下载队列（\(result.addedChapters) 章）")
        }
    }

    private func switchSource(to newSource: BookSource, candidate: SearchBook) {
        var moved = snapshot
        moved.bookUrl = candidate.bookUrl
        moved.origin = newSource.bookSourceUrl
        moved.originName = newSource.bookSourceName
        if !candidate.name.isEmpty { moved.name = candidate.name }
        if let cover = candidate.coverUrl, !cover.isEmpty { moved.coverUrl = cover }

        snapshot = store.changeBookSource(from: snapshot, to: moved)
        sourceOverride = newSource
        toc = []
        Task { await loadDetailIfNeeded() }
    }

    private func toggleShelf() {
        if onShelf {
            store.removeBook(bookUrl: snapshot.bookUrl)
        } else {
            _ = store.saveOrUpdateBook(snapshot)
            // 目录跟着入库，否则从书架进阅读器会找不到章节
            if !toc.isEmpty {
                store.saveChapters(toc, for: snapshot.bookUrl)
            }
        }
    }

    private func startReading() {
        guard activeSource != nil || snapshot.origin == "local" else {
            sourcePicker = true
            return
        }
        readingIndex = shelfSnapshot.durChapterIndex
        reading = true
    }

    private func loadDetailIfNeeded() async {
        guard toc.isEmpty else { return }

        let isLocal = snapshot.origin == "local" || snapshot.bookUrl.hasPrefix("file://")
        if isLocal {
            let localChapters = store.getChapters(for: snapshot.bookUrl)
            if !localChapters.isEmpty {
                await MainActor.run {
                    toc = localChapters
                    snapshot.totalChapterNum = localChapters.count
                    snapshot.latestChapterTitle = localChapters.last?.title
                }
                return
            }
        }

        guard let source = activeSource else {
            await MainActor.run { loadError = "找不到这本书的书源。可能源被删了，换个源试试。" }
            return
        }

        await MainActor.run {
            loadingDetail = true
            loadError = nil
        }

        do {
            let (detailed, chapters) = try await BookContentService.shared.fetchBookDetail(book: snapshot, source: source)
            await MainActor.run {
                snapshot = detailed
                toc = chapters
                loadingDetail = false
                if onShelf {
                    _ = store.saveOrUpdateBook(detailed)
                    if !chapters.isEmpty {
                        store.saveChapters(chapters, for: detailed.bookUrl)
                    }
                }
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                loadingDetail = false
            }
        }
    }
}

// MARK: - 主界面区块

/// 系统分享面板，详情页 / 书架 / 离线书库共用
@MainActor
func presentShareSheet(url: URL) {
    #if canImport(UIKit)
    let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    if let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }),
       let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
        if let pop = controller.popoverPresentationController {
            pop.sourceView = root.view
            pop.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        root.present(controller, animated: true)
    }
    #elseif canImport(AppKit)
    NSWorkspace.shared.open(url)
    #endif
}

private struct BookDetailHeader: View {
    let book: Book
    let shelfBook: Book
    let kind: BookSource.Kind
    let loading: Bool
    let onCover: () -> Void
    let onEdit: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(
            alignment: .top,
            spacing: 16
        ) {
            coverButton

            VStack(
                alignment: .leading,
                spacing: 8
            ) {
                Button(action: onEdit) {
                    Text(book.name)
                        .font(theme.isClassTrial ? .system(size: 22, weight: .black) : .title3.bold())
                        .lineLimit(2)
                        .foregroundColor(theme.isClassTrial ? theme.palette.ink : .primary)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(PlainButtonStyle())

                authorLine
                badgeRow

                if shelfBook.durChapterIndex > 0, let title = shelfBook.durChapterTitle {
                    Text("上次读至：\(title)")
                        .font(Font.caption)
                        .foregroundColor(theme.isClassTrial ? theme.palette.accent : .orange)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.all, 14)
        .appThemePanel()
    }

    private var coverButton: some View {
        Button(action: onCover) {
            Group {
                if book.coverUrl != nil {
                    BookCoverImage(urlString: book.coverUrl)
                } else {
                    CoverPlaceholder()
                }
            }
            .frame(width: 100, height: 138)
            .cornerRadius(theme.isClassTrial ? 0 : 8)
            .overlay {
                if theme.isClassTrial {
                    Rectangle().stroke(theme.palette.ink, lineWidth: 2)
                }
            }
            .shadow(color: theme.isClassTrial ? .clear : Color.black.opacity(0.12),
                    radius: 6, x: 0, y: 3)
            .background {
                if theme.isClassTrial {
                    Rectangle()
                        .fill(theme.palette.accent)
                        .offset(x: 4, y: 4)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var authorLine: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "person")
                .font(Font.caption)
                .foregroundColor(theme.palette.secondaryInk)

            if !book.author.isEmpty && book.author != "未知作者" {
                Button(action: onEdit) {
                    Text(book.author)
                        .font(Font.subheadline)
                        .foregroundColor(theme.palette.secondaryInk)
                        .lineLimit(1)
                }
                .buttonStyle(PlainButtonStyle())
            } else if loading {
                Text("正在获取作者...")
                    .font(Font.subheadline)
                    .foregroundColor(theme.palette.secondaryInk.opacity(0.6))
            } else {
                Text("佚名")
                    .font(Font.subheadline)
                    .foregroundColor(theme.palette.secondaryInk)
            }
        }
    }

    private var badgeRow: some View {
        HStack(alignment: .center, spacing: 8) {
            DetailBadge(
                text: book.originName.isEmpty ? "网络书源" : book.originName,
                tint: theme.palette.accent,
                background: theme.isClassTrial ? theme.palette.surface : theme.palette.accent.opacity(0.15)
            )

            if kind != .text {
                DetailBadge(
                    text: kind.label,
                    icon: kindIcon,
                    tint: theme.isClassTrial ? theme.palette.warning : .orange,
                    background: theme.isClassTrial ? theme.palette.surface : Color.orange.opacity(0.15)
                )
            }

            if let words = book.wordCount, !words.isEmpty {
                DetailBadge(
                    text: words,
                    bold: false,
                    tint: theme.palette.secondaryInk,
                    background: theme.isClassTrial ? theme.palette.surface : theme.palette.elevated
                )
            }
        }
    }

    private var kindIcon: String {
        switch kind {
        case .text: return "book.fill"
        case .audio: return "headphones"
        case .image: return "photo"
        case .file: return "doc"
        case .video: return "play.rectangle"
        }
    }
}

private struct DetailBadge: View {
    let text: String
    var icon: String? = nil
    var bold: Bool = true
    let tint: Color
    let background: Color
    @Environment(\.appTheme) private var theme

    var body: some View {
        Group {
            if let icon {
                Label(text, systemImage: icon)
            } else {
                Text(text)
            }
        }
        .font(bold ? .caption2.bold() : .caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(background)
        .foregroundColor(tint)
        .overlay {
            if theme.isClassTrial {
                Rectangle().stroke(theme.palette.ink, lineWidth: 1.5)
            }
        }
        .cornerRadius(theme.isClassTrial ? 0 : theme.metrics.cornerRadius + 4)
    }
}

private struct CoverPlaceholder: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        Group {
            if theme.isClassTrial {
                ZStack {
                    Rectangle().fill(theme.palette.surface)
                    Image(systemName: "book.closed")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(theme.palette.accent)
                }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.15))
                    .overlay {
                        Image(systemName: "book.closed")
                            .font(.system(size: 36))
                            .foregroundColor(.accentColor)
                    }
            }
        }
    }
}

private struct TagStrip: View {
    let tags: [String]
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView(
            .horizontal,
            showsIndicators: false
        ) {
            HStack(alignment: .center, spacing: 8) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    Text(verbatim: tag)
                        .font(.caption.weight(theme.isClassTrial ? .heavy : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(theme.isClassTrial ? theme.palette.surface : Color.secondary.opacity(0.12))
                        .foregroundColor(theme.isClassTrial ? theme.palette.ink : .secondary)
                        .cornerRadius(theme.isClassTrial ? 0 : 12)
                        .overlay {
                            if theme.isClassTrial {
                                Rectangle().stroke(theme.palette.ink, lineWidth: 1.5)
                            }
                        }
                }
            }
        }
    }
}

private struct TOCPreviewCard: View {
    let book: Book
    let chapters: [BookChapter]
    let loading: Bool
    let error: String?
    let onOpen: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "list.bullet")
                    .font(Font.headline)
                    .foregroundColor(theme.palette.accent)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(verbatim: "目录")
                            .font(Font.subheadline.bold())
                            .foregroundColor(theme.isClassTrial ? theme.palette.ink : .primary)

                        if loading {
                            ProgressView().scaleEffect(0.7)
                        } else if chapters.count > 0 {
                            let total = chapters.count
                            Text("共 \(total) 章")
                                .font(Font.caption2)
                                .foregroundColor(theme.palette.secondaryInk)
                        }
                    }
                    statusLine
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(Font.caption)
                    .foregroundColor(theme.palette.secondaryInk)
            }
            .padding(.all, 14)
            .appThemePanel()
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private var statusLine: some View {
        if let latest = book.latestChapterTitle, !latest.isEmpty {
            Text("最新：\(latest)")
                .font(Font.caption)
                .foregroundColor(theme.palette.secondaryInk)
                .lineLimit(1)
        } else if !chapters.isEmpty {
            Text("最新：\(chapters.last?.title ?? "")")
                .font(Font.caption)
                .foregroundColor(theme.palette.secondaryInk)
                .lineLimit(1)
        } else if loading {
            Text("正在拉取目录...")
                .font(Font.caption)
                .foregroundColor(theme.palette.secondaryInk)
        } else if let error {
            Text("拉取目录失败: \(error)")
                .font(Font.caption)
                .foregroundColor(theme.palette.danger)
        }
    }
}

private struct IntroPanel: View {
    let text: String?
    let loading: Bool
    @Binding var expanded: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(verbatim: "内容简介")
                    .font(theme.isClassTrial ? .system(size: 18, weight: .black) : .headline)
                    .foregroundColor(theme.isClassTrial ? theme.palette.ink : .primary)
                Spacer()
                if let text, text.count > 100 {
                    Button {
                        withAnimation { expanded.toggle() }
                    } label: {
                        Text(expanded ? "收起" : "展开")
                            .font(Font.caption)
                            .foregroundColor(theme.palette.accent)
                    }
                }
            }

            if let text {
                Text(text)
                    .font(Font.subheadline)
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineSpacing(4)
                    .lineLimit(expanded ? nil : 4)
            } else if loading {
                HStack(alignment: .center, spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text(verbatim: "正在加载作品简介与详情...")
                        .font(Font.subheadline)
                        .foregroundColor(theme.palette.secondaryInk.opacity(0.8))
                }
                .padding(.vertical, 4)
            } else {
                Text(verbatim: "暂无简介")
                    .font(Font.subheadline)
                    .foregroundColor(theme.palette.secondaryInk.opacity(0.6))
                    .padding(.vertical, 4)
            }
        }
        .padding(.all, 14)
        .frame(maxWidth: .infinity, alignment: Alignment.leading)
        .appThemePanel()
    }
}

private struct DetailActionBar: View {
    let onShelf: Bool
    let kind: BookSource.Kind
    let canRead: Bool
    let continued: Bool
    let onToggleShelf: () -> Void
    let onRead: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button(action: onToggleShelf) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: onShelf ? "checkmark.circle.fill" : "plus.circle")
                    Text(onShelf ? "移出书架" : "加入书架")
                }
                .font(Font.subheadline.bold())
                .foregroundColor(shelfForeground)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(theme.isClassTrial ? theme.palette.surface : theme.palette.elevated)
                .overlay {
                    if theme.isClassTrial {
                        Rectangle().stroke(theme.palette.ink, lineWidth: 2)
                    }
                }
                .cornerRadius(theme.metrics.cornerRadius)
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: onRead) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: kind == .text ? "book.fill" : kindIcon)
                    Text(readTitle)
                }
                .font(Font.subheadline.bold())
                .foregroundColor(theme.palette.onAccent)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(theme.palette.accent)
                .overlay {
                    if theme.isClassTrial {
                        Rectangle().stroke(theme.palette.ink, lineWidth: 2)
                    }
                }
                .cornerRadius(theme.metrics.cornerRadius)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal).padding(.vertical, 10)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(theme.palette.surface)
        .overlay(alignment: .top) {
            if theme.isClassTrial {
                Rectangle().fill(theme.palette.ink).frame(height: 2)
            }
        }
        .shadow(color: theme.isClassTrial ? .clear : Color.black.opacity(0.06),
                radius: 4, x: 0, y: -2)
    }

    private var shelfForeground: Color {
        if theme.isClassTrial {
            return onShelf ? theme.palette.secondaryInk : theme.palette.ink
        }
        return onShelf ? .secondary : .accentColor
    }

    private var kindIcon: String {
        switch kind {
        case .text: return "book.fill"
        case .audio: return "headphones"
        case .image: return "photo"
        case .file: return "doc"
        case .video: return "play.rectangle"
        }
    }

    private var readTitle: String {
        guard canRead else { return "选择书源" }
        switch kind {
        case .text: return continued ? "继续阅读" : "立即阅读"
        case .audio: return continued ? "继续播放" : "播放音频"
        case .image: return continued ? "继续看图" : "查看图片"
        case .file: return "打开文件"
        case .video: return continued ? "继续播放" : "播放视频"
        }
    }
}

// MARK: - 目录

private struct ChapterListView: View {
    @Environment(\.appTheme) private var theme

    let items: [BookChapter]
    let highlightedIndex: Int
    let onPick: (Int) -> Void

    @State private var query = ""

    private var filtered: [(index: Int, chapter: BookChapter)] {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else {
            return items.indices.map { (index: $0, chapter: items[$0]) }
        }
        return items.indices.compactMap { index in
            guard items[index].title.localizedCaseInsensitiveContains(keyword) else { return nil }
            return (index: index, chapter: items[index])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            chapterList
        }
        .navigationTitle("目录 (\(items.count) 章)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var chapterList: some View {
        List(filtered, id: \.chapter.id) { entry in
            chapterRow(index: entry.index, chapter: entry.chapter)
        }
        .listStyle(PlainListStyle())
        .appThemedList()
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(theme.palette.secondaryInk)
            TextField("搜索章节标题...", text: $query)
                .foregroundColor(theme.palette.ink)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.palette.secondaryInk)
                }
            }
        }
        .padding(8)
        .background(theme.isClassTrial ? theme.palette.surface : theme.palette.elevated)
        .overlay {
            if theme.isClassTrial {
                Rectangle().stroke(theme.palette.ink, lineWidth: 2)
            }
        }
        .cornerRadius(theme.isClassTrial ? 0 : 8)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func chapterRow(index: Int, chapter: BookChapter) -> some View {
        Button { onPick(index) } label: {
            HStack {
                Text(chapter.title)
                    .font(.subheadline.weight(theme.isClassTrial ? .semibold : .regular))
                    .foregroundColor(index == highlightedIndex ? theme.palette.accent : theme.palette.ink)
                    .lineLimit(1)
                Spacer()
                if index == highlightedIndex {
                    Text("上次阅读")
                        .font(.caption2.weight(theme.isClassTrial ? .bold : .regular))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.isClassTrial ? theme.palette.surface : theme.palette.accent.opacity(0.15))
                        .foregroundColor(theme.palette.accent)
                        .overlay {
                            if theme.isClassTrial {
                                Rectangle().stroke(theme.palette.ink, lineWidth: 1.5)
                            }
                        }
                        .cornerRadius(theme.isClassTrial ? 0 : 4)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 封面选择

struct BookCoverPickerSheet: View {
    let bookName: String
    let currentCover: String?
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var candidates: [(source: String, url: String)] = []
    @State private var probing = true
    @State private var typedURL = ""
    #if os(iOS)
    @State private var pickedImage: Any?
    #endif

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    probeStatus
                    candidateGrid
                    manualEntry
                    photoEntry
                    clearEntry
                }
                .padding(16)
            }
            .background(AppThemeBackdrop())
            .navigationTitle("换封面")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await probeCovers() }
        }
            .stackNavigationStyle()
    }

    @ViewBuilder
    private var probeStatus: some View {
        if probing {
            AppThemeSection("书源封面", tag: "PROBE") {
                HStack(alignment: .center, spacing: 8) {
                    ProgressView()
                    Text("正在书源里找这本书的封面…")
                        .font(Font.caption)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .padding(12)
            }
        } else if candidates.isEmpty {
            AppThemeSection("书源封面", tag: "PROBE") {
                Text("书源里没找到封面，手填一个地址，或者从相册挑。")
                    .font(Font.caption)
                    .foregroundColor(theme.palette.secondaryInk)
                    .padding(12)
            }
        }
    }

    @ViewBuilder
    private var candidateGrid: some View {
        if !candidates.isEmpty {
            AppThemeSection("书源找到的封面（\(candidates.count)）", tag: "PICK") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
                    ForEach(candidates, id: \.url) { item in
                        Button {
                            onPick(item.url)
                            dismiss()
                        } label: {
                            VStack(spacing: 4) {
                                BookCoverImage(urlString: item.url)
                                    .frame(width: 76, height: 104)
                                    .cornerRadius(theme.isClassTrial ? 0 : 6)
                                    .overlay {
                                        if theme.isClassTrial {
                                            Rectangle().stroke(theme.palette.ink, lineWidth: 1.5)
                                        }
                                    }
                                Text(item.source)
                                    .font(Font.caption2)
                                    .foregroundColor(theme.palette.secondaryInk)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(12)
            }
        }
    }

    private var manualEntry: some View {
        AppThemeSection("手填地址", tag: "URL") {
            VStack(
                alignment: .leading,
                spacing: 8
            ) {
                TextField("https://…", text: $typedURL)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .font(theme.typography.body)
                    .foregroundColor(theme.palette.ink)
                    .padding(10)
                    .background(theme.palette.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                            .stroke(
                                theme.isClassTrial ? theme.palette.ink : theme.palette.divider,
                                lineWidth: theme.isClassTrial ? 2 : 1
                            )
                    }

                Button("用这个地址") {
                    let trimmed = typedURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onPick(trimmed)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(typedURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var photoEntry: some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            AppThemeSection("本地相册", tag: "PHOTO") {
                PhotosPicker(selection: photoBinding, matching: .images) {
                    Label("从相册选封面", systemImage: "photo.on.rectangle")
                        .font(.system(size: 13, weight: theme.isClassTrial ? .heavy : .medium))
                        .foregroundColor(theme.palette.accent)
                }
                .padding(12)
            }
        }
        #endif
    }

    #if os(iOS)
    @available(iOS 16.0, *)
    private var photoBinding: Binding<PhotosPickerItem?> {
        Binding(
            get: { pickedImage as? PhotosPickerItem },
            set: { item in
                pickedImage = item
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let stored = BookCoverStorage.save(data) else { return }
                    await MainActor.run {
                        onPick(stored)
                        dismiss()
                    }
                }
            }
        )
    }
    #endif

    @ViewBuilder
    private var clearEntry: some View {
        if let currentCover, !currentCover.isEmpty {
            AppThemeSection("当前封面", tag: "CLEAR") {
                Button(role: .destructive) {
                    onPick("")
                    dismiss()
                } label: {
                    Label("清除封面", systemImage: "trash")
                        .font(.system(size: 13, weight: theme.isClassTrial ? .heavy : .medium))
                        .foregroundColor(theme.palette.danger)
                }
                .padding(12)
            }
        }
    }

    private func probeCovers() async {
        let enabled = BookStore.shared.sources.filter { $0.enabled != false }
        candidates = await CoverCandidateFinder.find(bookName: bookName, sources: enabled)
        probing = false
    }
}

// MARK: - 封面加载

struct BookCoverImage: View {
    @Environment(\.appTheme) private var theme
    let urlString: String?
    var contentMode: ContentMode = .fill
    var placeholderOverride: AnyView? = nil
    var onFailure: (() -> Void)? = nil

    @State private var localImage: Image?

    var body: some View {
        Group {
            if let localImage {
                render(localImage)
            } else {
                placeholder
            }
        }
        .task(id: urlString) {
            await loadImage()
        }
    }

    /// 本地路径直接读；远程封面命中磁盘缓存就直接用，否则下载后落盘，下次不再请求
    private func loadImage() async {
        guard let urlString, !urlString.isEmpty else {
            localImage = nil
            return
        }
        if let image = Self.readLocalImage(urlString) {
            localImage = image
            return
        }
        guard let remote = URL(string: urlString),
              let scheme = remote.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            localImage = nil
            return
        }
        if let cached = BookCoverStorage.cachedFileURL(for: urlString),
           let image = Self.readLocalImage(cached.path) {
            localImage = image
            return
        }
        localImage = nil
        do {
            let (data, response) = try await URLSession.shared.data(from: remote)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                onFailure?()
                return
            }
            guard let image = Self.decodedImage(data) else {
                onFailure?()
                return
            }
            BookCoverStorage.saveCached(data, for: urlString)
            localImage = image
        } catch {
            onFailure?()
        }
    }

    @ViewBuilder
    private func render(_ image: Image) -> some View {
        if contentMode == .fill {
            // 整张封面完整显示：同图模糊放大做背景，避免留白难看，也不再裁掉上下或左右
            // 背景层尺寸必须定死：只给 maxWidth 时 scaledToFill 会把 ZStack 撑到图片自身比例，
            // 上层 scaledToFit 跟着铺满整个盒子，再被外层裁掉，封面就成了中心裁切
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    theme.palette.elevated
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .blur(radius: 16)
                        .opacity(0.32)
                        .clipped()
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: size.width, height: size.height)
                }
            }
        } else {
            image
                .resizable()
                .scaledToFit()
        }
    }

    private var placeholder: some View {
        Group {
            if let placeholderOverride {
                placeholderOverride
            } else {
                ZStack {
                    if theme.isClassTrial {
                        Rectangle().fill(theme.palette.surface)
                        Image(systemName: "book.closed")
                            .font(.title3.weight(.bold))
                            .foregroundColor(theme.palette.accent)
                    } else {
                        Color.gray.opacity(0.16)
                        Image(systemName: "book.closed")
                            .font(.title3)
                            .foregroundColor(Color.secondary)
                    }
                }
            }
        }
    }

    private static func readLocalImage(_ urlString: String?) -> Image? {
        guard let urlString else { return nil }
        let path: String
        if urlString.hasPrefix("file://") {
            guard let url = URL(string: urlString) else { return nil }
            path = url.path
        } else if urlString.hasPrefix("/") {
            path = urlString
        } else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        #if os(iOS)
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        return Image(uiImage: image)
        #elseif os(macOS)
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }

    private static func decodedImage(_ data: Data) -> Image? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }
}

// MARK: - 封面存储与候选

enum BookCoverStorage {
    static func directory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return documents.appendingPathComponent("Covers", isDirectory: true)
    }

    static func save(_ data: Data) -> String? {
        let folder = directory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(UUID().uuidString + ".jpg")
        guard (try? data.write(to: target, options: .atomic)) != nil else { return nil }
        return target.absoluteString
    }

    /// 远程封面按 URL 的稳定哈希落盘，重启进程也能命中
    static func cachedFileURL(for remoteURL: String) -> URL? {
        guard !remoteURL.isEmpty else { return nil }
        var hash: UInt64 = 5381
        for byte in remoteURL.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        let name = String(hash, radix: 16) + "-" + String(remoteURL.utf8.count, radix: 16) + ".img"
        return directory().appendingPathComponent(name)
    }

    static func saveCached(_ data: Data, for remoteURL: String) {
        guard let target = cachedFileURL(for: remoteURL) else { return }
        try? FileManager.default.createDirectory(at: directory(), withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
    }
}

enum CoverCandidateFinder {
    static func find(
        bookName: String,
        sources: [BookSource],
        limit: Int = 40
    ) async -> [(source: String, url: String)] {
        guard !bookName.isEmpty, !sources.isEmpty else { return [] }

        var results: [(source: String, url: String)] = []
        var known = Set<String>()

        for await (source, books) in BookSearchService.shared.searchMultiSources(
            sources: sources, key: bookName, page: 1
        ) {
            for candidate in books {
                guard candidate.name.contains(bookName) || bookName.contains(candidate.name) else { continue }
                guard let cover = candidate.coverUrl, !cover.isEmpty else { continue }
                guard known.insert(cover).inserted else { continue }
                results.append((source: source.bookSourceName, url: cover))
                if results.count >= limit { return results }
            }
        }
        return results
    }
}

// MARK: - 编辑书籍信息

struct BookInfoEditSheet: View {
    @Environment(\.dismiss) private var closeEditor
    @State private var name: String
    @State private var author: String
    @State private var cover: String
    @State private var coverError: String?
    @State private var coverOptions: [(source: String, url: String)] = []
    @State private var findingCovers = false
    @State private var finderNote: String?
    #if os(iOS)
    @State private var pickedCover: Any?
    #endif
    private let onSave: (String, String, String) -> Void

    init(name: String, author: String, coverUrl: String, onSave: @escaping (String, String, String) -> Void) {
        _name = State(initialValue: name)
        _author = State(initialValue: author)
        _cover = State(initialValue: coverUrl)
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("书名", text: $name)
                TextField("作者", text: $author)
                TextField("封面图片地址", text: $cover)
                    .autocorrectionDisabled()

                if !cover.isEmpty {
                    HStack(alignment: .center) {
                        Spacer()
                        BookCoverImage(urlString: cover, contentMode: .fit)
                            .frame(height: 120)
                        Spacer()
                    }
                }

                photoRow
                Button("清除封面") { cover = "" }
                    .foregroundColor(.red)
                coverSearchSection
            }
            .navigationTitle("编辑书籍信息")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { closeEditor() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(
                            name.trimmingCharacters(in: .whitespaces),
                            author.trimmingCharacters(in: .whitespaces),
                            cover.trimmingCharacters(in: .whitespaces)
                        )
                        closeEditor()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
            .stackNavigationStyle()
    }

    @ViewBuilder
    private var photoRow: some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            PhotosPicker(
                selection: Binding(
                    get: { pickedCover as? PhotosPickerItem },
                    set: { item in
                        pickedCover = item
                        guard let item else { return }
                        Task {
                            if let data = try? await item.loadTransferable(type: Data.self),
                               let stored = BookCoverStorage.save(data) {
                                await MainActor.run {
                                    cover = stored
                                    coverError = nil
                                }
                            } else {
                                await MainActor.run { coverError = "这张图读不出来，换一张试试。" }
                            }
                        }
                    }
                ),
                matching: .images
            ) {
                Label("从相册选封面", systemImage: "photo.on.rectangle")
            }
            if let coverError {
                Text(coverError)
                    .font(Font.caption)
                    .foregroundColor(.red)
            }
        }
        #endif
    }

    private var coverSearchSection: some View {
        Section(header: Text("从书源找封面")) {
            Button { searchCovers() } label: {
                HStack {
                    Label("用书名去书源搜一圈", systemImage: "square.grid.2x2")
                    Spacer()
                    if findingCovers {
                        ProgressView()
                    }
                }
            }
            .disabled(findingCovers || name.trimmingCharacters(in: .whitespaces).isEmpty)

            if let finderNote {
                Text(finderNote)
                    .font(Font.caption)
                    .foregroundColor(Color.secondary)
            }

            if !coverOptions.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                    ForEach(coverOptions, id: \.url) { item in
                        Button {
                            cover = item.url
                            coverError = nil
                        } label: {
                            BookCoverImage(urlString: item.url)
                                .frame(width: 64, height: 88)
                                .cornerRadius(6)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(cover == item.url ? Color.accentColor : Color.clear, lineWidth: 2)
                                }
                        }
                    }
                }
                .padding([.top, .bottom], 4)
            }
        }
    }

    private func searchCovers() {
        let key = name.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        findingCovers = true
        finderNote = nil
        let enabled = BookStore.shared.sources.filter { $0.enabled != false }
        Task { @MainActor in
            let found = await CoverCandidateFinder.find(bookName: key, sources: enabled)
            coverOptions = found
            findingCovers = false
            finderNote = found.isEmpty ? "没在书源里搜到封面。" : "点一张就换上。"
        }
    }
}

struct DownloadSetupRequest: Identifiable {
    let id = UUID()
    let scope: DownloadScope
    let currentIndex: Int
}

/// 下载前的一次性选项面板：范围、书评、并发、后台。
/// 从阅读器打开时传入阅读主题颜色，在非覆盖主题下跟随正文底色，其余场景跟随 App 主题。
struct DownloadSetupSheet: View {
    let bookTitle: String
    let bookUrl: String
    let chapterCount: Int
    let currentIndex: Int
    let preferredScope: DownloadScope
    let readerBackground: Color?
    let readerInk: Color?
    let readerAccent: Color?
    let readerOnAccent: Color?
    let onStart: (DownloadScope, [Int], DownloadOptions) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var scope: DownloadScope
    @State private var count: Int
    @State private var reviewLimit: Int?
    @State private var refetch: Bool
    @State private var concurrency: Int
    @State private var background: Bool
    @State private var cachedIndices: Set<Int> = []

    private enum Keys {
        static let count = "download_options_count"
        static let review = "download_options_review"
        static let refetch = "download_options_refetch"
        static let concurrency = "download_options_concurrency"
        static let background = "download_options_background"
    }

    init(bookTitle: String, bookUrl: String, chapterCount: Int, currentIndex: Int,
         preferredScope: DownloadScope,
         readerBackground: Color? = nil, readerInk: Color? = nil,
         readerAccent: Color? = nil, readerOnAccent: Color? = nil,
         onStart: @escaping (DownloadScope, [Int], DownloadOptions) -> Void) {
        self.bookTitle = bookTitle
        self.bookUrl = bookUrl
        self.chapterCount = chapterCount
        self.currentIndex = currentIndex
        self.preferredScope = preferredScope
        self.readerBackground = readerBackground
        self.readerInk = readerInk
        self.readerAccent = readerAccent
        self.readerOnAccent = readerOnAccent
        self.onStart = onStart
        let d = UserDefaults.standard
        _scope = State(initialValue: preferredScope)
        _count = State(initialValue: d.object(forKey: Keys.count) as? Int ?? ReaderConfig.shared.cachedChapterCount)
        if let raw = d.object(forKey: Keys.review) as? Int {
            _reviewLimit = State(initialValue: raw < 0 ? nil : raw)
        } else {
            _reviewLimit = State(initialValue: 3)
        }
        _refetch = State(initialValue: d.bool(forKey: Keys.refetch))
        _concurrency = State(initialValue: d.object(forKey: Keys.concurrency) as? Int ?? 4)
        _background = State(initialValue: (d.object(forKey: Keys.background) as? Bool) ?? true)
    }

    private var startIndex: Int {
        max(0, min(currentIndex, max(0, chapterCount - 1)))
    }

    private var indices: [Int] {
        let start = scope == .unread ? startIndex + 1 : startIndex
        return scope.indices(chapterCount: chapterCount, start: start, count: count)
    }

    private var cachedInScope: Int {
        indices.reduce(0) { $0 + (cachedIndices.contains($1) ? 1 : 0) }
    }

    private var nothingToDo: Bool {
        indices.count == cachedInScope && reviewLimit == nil
    }

    // MARK: 主题色

    /// 阅读器传入阅读底色时，未开启主题覆盖就跟随正文，避免白底抽屉砸在黑底阅读页上。
    private var usesReaderColors: Bool {
        !theme.overridesReaderAppearance && readerBackground != nil
    }
    private var pageBackground: Color {
        usesReaderColors ? (readerBackground ?? theme.palette.background) : theme.palette.background
    }
    private var surface: Color {
        usesReaderColors ? (readerInk ?? theme.palette.ink).opacity(0.055) : theme.palette.surface
    }
    private var ink: Color {
        usesReaderColors ? (readerInk ?? theme.palette.ink) : theme.palette.ink
    }
    private var secondaryInk: Color {
        usesReaderColors ? (readerInk ?? theme.palette.ink).opacity(0.6) : theme.palette.secondaryInk
    }
    private var divider: Color {
        usesReaderColors ? (readerInk ?? theme.palette.ink).opacity(0.14) : theme.palette.divider
    }
    private var accent: Color {
        usesReaderColors ? (readerAccent ?? theme.palette.accent) : theme.palette.accent
    }
    private var accentInk: Color {
        usesReaderColors ? (readerOnAccent ?? theme.palette.onAccent) : theme.palette.onAccent
    }
    private var danger: Color { theme.palette.danger }
    private var radius: CGFloat { usesReaderColors ? 18 : max(2, theme.metrics.cornerRadius) }
    private var borderWidth: CGFloat { usesReaderColors ? 1 : theme.metrics.borderWidth }
    private var remaining: Int { max(0, chapterCount - startIndex) }
    private var progress: Double {
        guard chapterCount > 0 else { return 0 }
        return min(1, Double(cachedIndices.count) / Double(chapterCount))
    }

    var body: some View {
        ZStack {
            pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    statusCard
                    sectionLabel("缓存范围")
                    scopeCards
                    if scope == .nextN {
                        presetGrid
                        customCountRow
                    }
                    sectionLabel("下载选项")
                    optionsCard
                    primaryButton
                    footnote
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
        }
        .modifier(DownloadSetupPresentation())
        .onAppear {
            if cachedIndices.isEmpty {
                cachedIndices = Set(OfflineBookStore.shared.cachedIndices(for: bookUrl))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("CACHE / OFFLINE")
                    .font(theme.typography.label)
                    .foregroundColor(accent)
                Text("下载缓存")
                    .font(theme.typography.title)
                    .foregroundColor(ink)
                Text("《\(bookTitle)》共 \(chapterCount) 章")
                    .font(theme.typography.body)
                    .foregroundColor(secondaryInk)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(secondaryInk)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(surface))
                    .overlay(Circle().stroke(divider, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("已缓存")
                    .font(theme.typography.label)
                    .foregroundColor(secondaryInk)
                Text("\(cachedIndices.count)")
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundColor(accent)
                Text("/ \(chapterCount) 章")
                    .font(theme.typography.mono)
                    .foregroundColor(secondaryInk)
                Spacer(minLength: 8)
                if cachedInScope > 0 {
                    Text("本次命中 \(cachedInScope) 章")
                        .font(theme.typography.mono)
                        .foregroundColor(secondaryInk)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(divider.opacity(0.45))
                    Capsule()
                        .fill(accent)
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 5)
            HStack(spacing: 6) {
                Image(systemName: "bookmark")
                Text("当前第 \(startIndex + 1) 章 · 往后还有 \(remaining) 章")
                Spacer(minLength: 0)
            }
            .font(theme.typography.mono)
            .foregroundColor(secondaryInk)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(surface))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(divider.opacity(0.7), lineWidth: borderWidth)
        )
    }

    private var scopeCards: some View {
        VStack(spacing: 8) {
            ForEach(DownloadScope.allCases) { option in
                scopeCard(option)
            }
        }
    }

    private func scopeCard(_ option: DownloadScope) -> some View {
        let selected = scope == option
        return Button {
            scope = option
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(theme.typography.body)
                        .foregroundColor(selected ? accent : ink)
                    Text(detail(for: option))
                        .font(theme.typography.mono)
                        .foregroundColor(secondaryInk)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(theme.typography.symbol)
                    .foregroundColor(selected ? accent : secondaryInk.opacity(0.5))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? accent.opacity(0.12) : surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(selected ? accent : divider.opacity(0.7),
                            lineWidth: selected ? 1.5 : borderWidth)
            )
        }
        .buttonStyle(.plain)
    }

    private var presetGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5),
            spacing: 10
        ) {
            ForEach([10, 20, 30, 50, 100], id: \.self) { n in
                presetButton(n)
            }
        }
    }

    private func presetButton(_ n: Int) -> some View {
        let selected = scope == .nextN && count == n
        return Button {
            scope = .nextN
            count = n
        } label: {
            VStack(spacing: 2) {
                Text("\(n)")
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(selected ? accent : ink)
                Text("章")
                    .font(theme.typography.label)
                    .foregroundColor(secondaryInk)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? accent.opacity(0.12) : surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(selected ? accent : divider.opacity(0.7),
                            lineWidth: selected ? 1.5 : borderWidth)
            )
        }
        .buttonStyle(.plain)
    }

    private var customCountRow: some View {
        Stepper(value: $count, in: 1...2000, step: 10) {
            HStack {
                Text("自定义")
                    .font(theme.typography.body)
                    .foregroundColor(ink)
                Spacer(minLength: 8)
                Text("往下 \(count) 章")
                    .font(theme.typography.mono)
                    .foregroundColor(secondaryInk)
            }
        }
        .tint(accent)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(surface))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(divider.opacity(0.7), lineWidth: borderWidth)
        )
    }

    private var optionsCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("每章书评")
                    .font(theme.typography.body)
                    .foregroundColor(ink)
                Spacer(minLength: 8)
                Picker("每章书评", selection: $reviewLimit) {
                    Text("不抓").tag(Int?.none)
                    Text("3 条").tag(Int?.some(3))
                    Text("10 条").tag(Int?.some(10))
                    Text("30 条").tag(Int?.some(30))
                    Text("全部").tag(Int?.some(0))
                }
                .pickerStyle(.menu)
                .tint(accent)
            }
            .padding(.vertical, 12)
            if reviewLimit != nil {
                cardDivider
                Toggle("重新拉取已有书评", isOn: $refetch)
                    .font(theme.typography.body)
                    .foregroundColor(ink)
                    .tint(accent)
                    .padding(.vertical, 8)
            }
            cardDivider
            VStack(alignment: .leading, spacing: 8) {
                Text("并发")
                    .font(theme.typography.label)
                    .foregroundColor(secondaryInk)
                Picker("并发", selection: $concurrency) {
                    ForEach([1, 4, 8, 16], id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 12)
            cardDivider
            Toggle("切到后台继续下载", isOn: $background)
                .font(theme.typography.body)
                .foregroundColor(ink)
                .tint(accent)
                .padding(.vertical, 8)
        }
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(surface))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(divider.opacity(0.7), lineWidth: borderWidth)
        )
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(divider.opacity(0.6))
            .frame(height: 0.5)
    }

    private var primaryDisabled: Bool {
        indices.isEmpty || nothingToDo
    }

    private var primaryButton: some View {
        Button {
            start()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(accentInk)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: radius * 0.6, style: .continuous)
                            .fill(accentInk.opacity(0.16))
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(nothingToDo ? "已全部缓存" : "下载 \(indices.count) 章")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(accentInk)
                    Text(primarySubtitle)
                        .font(theme.typography.mono)
                        .foregroundColor(accentInk.opacity(0.78))
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(accentInk.opacity(0.7))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(accent))
            .opacity(primaryDisabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(primaryDisabled)
    }

    private var primarySubtitle: String {
        var parts: [String] = [scope.title, "并发 \(concurrency)"]
        if background { parts.append("后台继续") }
        return parts.joined(separator: " · ")
    }

    private var footnote: some View {
        Text("正文已缓存的章节会跳过，缺的书评照常补齐。下载在后台继续，进度可在「设置 → 下载管理」查看。")
            .font(theme.typography.mono)
            .foregroundColor(secondaryInk)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.typography.label)
            .foregroundColor(secondaryInk)
            .padding(.top, 2)
    }

    private func detail(for option: DownloadScope) -> String {
        switch option {
        case .all:
            return "第 1 章到第 \(chapterCount) 章"
        case .unread:
            let from = min(chapterCount, startIndex + 2)
            return "从第 \(max(1, from)) 章到末尾，共 \(max(0, chapterCount - startIndex - 1)) 章"
        case .nextN:
            return "从第 \(startIndex + 1) 章起，往后 \(count) 章"
        }
    }

    private func start() {
        let d = UserDefaults.standard
        d.set(count, forKey: Keys.count)
        d.set(reviewLimit ?? -1, forKey: Keys.review)
        d.set(refetch, forKey: Keys.refetch)
        d.set(concurrency, forKey: Keys.concurrency)
        d.set(background, forKey: Keys.background)
        let options = DownloadOptions(reviewLimit: reviewLimit,
                                      refetchReviews: refetch && reviewLimit != nil,
                                      concurrency: concurrency,
                                      background: background)
        onStart(scope, indices, options)
        dismiss()
    }
}

/// iOS 16 起按整页弹出并显示拖拽条；老系统保持默认。
private struct DownloadSetupPresentation: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
