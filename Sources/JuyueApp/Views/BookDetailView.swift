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

    private let sourceOverride: BookSource?

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

    public init(
        book: Book,
        source: BookSource? = nil
    ) {
        self.sourceOverride = source
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
        sourceOverride ?? store.findSource(for: snapshot)
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
        SourceSwitchSheet(book: snapshot, currentSourceUrl: sourceOverride?.bookSourceUrl) { newSource, candidate in
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
        let resolved = sourceOverride ?? store.findSource(for: active)
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

    private func enqueueAll() {
        let all = Array(toc.indices)
        ChapterDownloadManager.shared.start(
            book: snapshot,
            chapters: toc,
            source: activeSource,
            indices: all
        )
        presentAlert("已加入下载队列（全本 \(toc.count) 章）")
    }

    private func enqueueRemaining() {
        let start = min(snapshot.durChapterIndex, max(0, toc.count - 1))
        let rest = Array(start..<toc.count)
        ChapterDownloadManager.shared.start(
            book: snapshot,
            chapters: toc,
            source: activeSource,
            indices: rest
        )
        presentAlert("已加入下载队列（未读 \(rest.count) 章）")
    }

    private func switchSource(to newSource: BookSource, candidate: SearchBook) {
        var moved = snapshot
        moved.bookUrl = candidate.bookUrl
        moved.origin = newSource.bookSourceUrl
        moved.originName = newSource.bookSourceName
        if !candidate.name.isEmpty { moved.name = candidate.name }
        if let cover = candidate.coverUrl, !cover.isEmpty { moved.coverUrl = cover }

        snapshot = store.changeBookSource(from: snapshot, to: moved)
        toc = []
        Task { await loadDetailIfNeeded() }
    }

    private func toggleShelf() {
        if onShelf {
            store.removeBook(bookUrl: snapshot.bookUrl)
        } else {
            _ = store.saveOrUpdateBook(snapshot)
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
            } else if let remote = urlString.flatMap(URL.init(string:)) {
                AsyncImage(url: remote) { phase in
                    switch phase {
                    case .success(let image):
                        render(image)
                    case .failure:
                        placeholder.onAppear { onFailure?() }
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .task(id: urlString) {
            localImage = Self.readLocalImage(urlString)
        }
    }

    @ViewBuilder
    private func render(_ image: Image) -> some View {
        if contentMode == .fill {
            Color.clear
                .overlay {
                    image
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
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
