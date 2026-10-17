import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import PhotosUI
#endif

public struct BookDetailView: View {
    @ObservedObject var bookStore = BookStore.shared
    @Environment(\.dismiss) private var dismiss

    let initialBook: Book
    let source: BookSource?

    @State private var currentBook: Book
    @State private var chapters: [BookChapter] = []
    @State private var isLoadingDetails: Bool = false
    @State private var errorMessage: String? = nil

    @State private var navigateToTOC: Bool = false
    @State private var isIntroExpanded: Bool = false
    @State private var isReading: Bool = false
    @State private var selectedChapterIndex: Int = 0
    @State private var showActionAlert: Bool = false
    @State private var showEditSheet: Bool = false
    @State private var showCoverPicker: Bool = false
    @State private var showSourceSwitch: Bool = false
    @State private var editName: String = ""
    @State private var editAuthor: String = ""
    @State private var editCover: String = ""
    @State private var actionAlertMessage: String = ""

    public init(book: Book, source: BookSource? = nil) {
        self.initialBook = book
        self.source = source
        self._currentBook = State(initialValue: book)
        self._selectedChapterIndex = State(initialValue: book.durChapterIndex)
    }

    public init(searchBook: SearchBook, source: BookSource? = nil) {
        let b = Book(
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
        )
        self.init(book: b, source: source)
    }

    private var isInBookshelf: Bool {
        bookStore.bookshelf.contains(where: { $0.bookUrl == currentBook.bookUrl })
    }

    private var currentBookshelfBook: Book {
        bookStore.bookshelf.first(where: { $0.bookUrl == currentBook.bookUrl }) ?? currentBook
    }

    private var tags: [String] {
        guard let kind = currentBook.kind, !kind.isEmpty else { return [] }
        return kind
            .components(separatedBy: CharacterSet(charactersIn: ",，/| "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var displayIntro: String? {
        guard let intro = currentBook.intro, !intro.isEmpty else { return nil }
        // Filter out debug/search metadata that is not real story synopsis
        if intro.hasPrefix("源站：") || intro.contains("最近同步：") {
            return nil
        }
        let cleaned = BookContentService.cleanHtml(intro)
        return cleaned.isEmpty ? nil : cleaned
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        // Header: Cover + Title + Author + Badges
                        headerCard
                            .padding(.horizontal)
                            .padding(.top, 12)

                        // Tags flow
                        if !tags.isEmpty {
                            tagsSection
                                .padding(.horizontal)
                        }

                        // Directory / TOC preview card
                        tocPreviewCard
                            .padding(.horizontal)

                        // Intro section (Real story synopsis)
                        introSection
                            .padding(.horizontal)

                        Spacer(minLength: 24)
                    }
                }

                // Fixed Bottom Action Bar (Add to shelf + Read Now)
                bottomActionBar
            }
            .navigationTitle("书籍详情")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if !AppEdition.isAppStoreClean {
                            Button {
                                showSourceSwitch = true
                            } label: {
                                Label("换源", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }

                        Button {
                            beginEditing()
                        } label: {
                            Label("编辑书名 / 作者 / 封面", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            let count = BookContentService.shared.getCacheCount(for: currentBook.bookUrl)
                            BookContentService.shared.clearCache(for: currentBook.bookUrl)
                            actionAlertMessage = "已清除本书缓存章节" + (count > 0 ? " (\(count)章)" : "")
                            showActionAlert = true
                        } label: {
                            Label("清除缓存", systemImage: "trash")
                        }

                        Button {
                            Task {
                                await loadBookDetails()
                                actionAlertMessage = "目录与详情已刷新"
                                showActionAlert = true
                            }
                        } label: {
                            Label("刷新目录与详情", systemImage: "arrow.clockwise")
                        }

                        if !AppEdition.isAppStoreClean {
                            Button {
                                let all = chapters.indices.map { $0 }
                                ChapterDownloadManager.shared.start(book: currentBook, chapters: chapters, source: source ?? bookStore.findSource(for: currentBook), indices: all)
                                actionAlertMessage = "已加入下载队列（全本 \(chapters.count) 章）"
                                showActionAlert = true
                            } label: {
                                Label("缓存全本", systemImage: "arrow.down.circle")
                            }

                            Button {
                                let start = min(currentBook.durChapterIndex, max(0, chapters.count - 1))
                                let rest = (start..<chapters.count).map { $0 }
                                ChapterDownloadManager.shared.start(book: currentBook, chapters: chapters, source: source ?? bookStore.findSource(for: currentBook), indices: rest)
                                actionAlertMessage = "已加入下载队列（未读 \(rest.count) 章）"
                                showActionAlert = true
                            } label: {
                                Label("缓存未读章节", systemImage: "arrow.down.to.line")
                            }
                        }

                        Button {
                            editName = currentBook.name
                            editAuthor = currentBook.author
                            editCover = currentBook.coverUrl ?? ""
                            showEditSheet = true
                        } label: {
                            Label("编辑书名 / 作者 / 封面", systemImage: "pencil")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                }
            }
            .alert(actionAlertMessage, isPresented: $showActionAlert) {
                Button("确定", role: .cancel) {}
            }
            .sheet(isPresented: $showCoverPicker) {
                BookCoverPickerSheet(
                    bookName: currentBook.name,
                    currentCover: currentBook.coverUrl
                ) { picked in
                    var updated = currentBook
                    updated.coverUrl = picked.isEmpty ? nil : picked
                    currentBook = updated
                    if bookStore.bookshelf.contains(where: { $0.bookUrl == updated.bookUrl }) {
                        _ = bookStore.saveOrUpdateBook(updated, overwriteCover: true)
                    }
                }
            }
            .sheet(isPresented: $showSourceSwitch) {
                SourceSwitchSheet(
                    book: currentBook,
                    currentSourceUrl: source?.bookSourceUrl
                ) { newSource, candidate in
                    switchSource(to: newSource, candidate: candidate)
                }
            }
            .sheet(isPresented: $showEditSheet) {
                BookInfoEditSheet(
                    name: editName,
                    author: editAuthor,
                    coverUrl: editCover,
                    onSave: { name, author, cover in
                        var updated = currentBook
                        updated.name = name
                        updated.author = author
                        updated.coverUrl = cover.isEmpty ? nil : cover
                        currentBook = updated
                        if bookStore.bookshelf.contains(where: { $0.bookUrl == updated.bookUrl }) {
                            _ = bookStore.saveOrUpdateBook(updated, overwriteCover: true)
                        }
                        actionAlertMessage = "已保存"
                        showActionAlert = true
                    }
                )
            }
            .background(
                NavigationLink(
                    isActive: $navigateToTOC,
                    destination: {
                        ChapterListView(
                            chapters: chapters,
                            currentChapterIndex: currentBookshelfBook.durChapterIndex,
                            onSelectChapter: { index in
                                selectedChapterIndex = index
                                isReading = true
                            }
                        )
                    },
                    label: { EmptyView() }
                )
                .hidden()
                .frame(width: 0, height: 0)
            )

            #if !os(iOS)
            if isReading {
                readerCoverView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .transition(.opacity)
                    .zIndex(999)
            }
            #endif
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isReading) {
            readerCoverView
        }
        #endif
        .task {
            await loadBookDetails()
        }
    }

    @ViewBuilder
    private var readerCoverView: some View {
        let activeBook = isInBookshelf ? currentBookshelfBook : currentBook
        let resolvedSource = source ?? bookStore.findSource(for: activeBook)
        NavigationView {
            ReaderView(book: activeBook, source: resolvedSource, initialChapterIndex: selectedChapterIndex, onDismiss: {
                isReading = false
            })
        }
    }

    // MARK: - Header Card

    /// 点书名 / 作者 / 菜单里的「编辑」都走这儿，先把三个字段灌进 sheet
    private func beginEditing() {
        editName = currentBook.name
        editAuthor = currentBook.author
        editCover = currentBook.coverUrl ?? ""
        showEditSheet = true
    }

    /// 换源：搬到新源的同一本书，保留阅读进度
    private func switchSource(to newSource: BookSource, candidate: SearchBook) {
        var updated = currentBook
        updated.bookUrl = candidate.bookUrl
        updated.origin = newSource.bookSourceUrl
        updated.originName = newSource.bookSourceName
        if !candidate.name.isEmpty { updated.name = candidate.name }
        if let cover = candidate.coverUrl, !cover.isEmpty { updated.coverUrl = cover }
        currentBook = bookStore.changeBookSource(from: currentBook, to: updated)
        chapters = []
        Task { await loadBookDetails() }
    }

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 16) {
            // Book Cover Image
            // 点一下就能换：候选来自书源搜索 + 相册 + 手填
            Button {
                showCoverPicker = true
            } label: {
                if currentBook.coverUrl != nil {
                    BookCoverImage(urlString: currentBook.coverUrl)
                        .frame(width: 100, height: 138)
                        .cornerRadius(8)
                        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
                        .clipped()
                } else {
                    coverPlaceholder
                        .frame(width: 100, height: 138)
                        .cornerRadius(8)
                        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    beginEditing()
                } label: {
                    Text(currentBook.name)
                        .font(.title3.bold())
                        .lineLimit(2)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    Image(systemName: "person")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if !currentBook.author.isEmpty && currentBook.author != "未知作者" {
                        Button {
                            beginEditing()
                        } label: {
                            Text(currentBook.author)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else if isLoadingDetails {
                        Text("正在获取作者...")
                            .font(.subheadline)
                            .foregroundColor(.secondary.opacity(0.6))
                    } else {
                        Text("佚名")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    // Source Name Badge
                    Text(currentBook.originName.isEmpty ? "网络书源" : currentBook.originName)
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .cornerRadius(6)

                    if let wordCount = currentBook.wordCount, !wordCount.isEmpty {
                        Text(wordCount)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundColor(.secondary)
                            .cornerRadius(6)
                    }
                }

                if currentBookshelfBook.durChapterIndex > 0,
                   let durTitle = currentBookshelfBook.durChapterTitle {
                    Text("上次读至：\(durTitle)")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(0.15))
            .overlay(
                Image(systemName: "book.closed")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
            )
    }

    // MARK: - Tags Section

    private var tagsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundColor(.secondary)
                        .cornerRadius(12)
                }
            }
        }
    }

    // MARK: - TOC Preview Card

    private var tocPreviewCard: some View {
        Button(action: {
            navigateToTOC = true
        }) {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet")
                    .font(.headline)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("目录")
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)

                        if isLoadingDetails {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else if !chapters.isEmpty {
                            Text("共 \(chapters.count) 章")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let latest = currentBook.latestChapterTitle, !latest.isEmpty {
                        Text("最新：\(latest)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else if !chapters.isEmpty {
                        Text("最新：\(chapters.last?.title ?? "")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else if isLoadingDetails {
                        Text("正在拉取目录...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if let error = errorMessage {
                        Text("拉取目录失败: \(error)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Intro Section

    private var introSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("内容简介")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                if let intro = displayIntro, intro.count > 100 {
                    Button(action: {
                        withAnimation {
                            isIntroExpanded.toggle()
                        }
                    }) {
                        Text(isIntroExpanded ? "收起" : "展开")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
            }

            if let intro = displayIntro {
                Text(intro)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineSpacing(4)
                    .lineLimit(isIntroExpanded ? nil : 4)
            } else if isLoadingDetails {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("正在加载作品简介与详情...")
                        .font(.subheadline)
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .padding(.vertical, 4)
            } else {
                Text("暂无简介")
                    .font(.subheadline)
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.vertical, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        HStack(spacing: 14) {
            // Add to Shelf Button
            Button(action: {
                toggleShelf()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isInBookshelf ? "checkmark.circle.fill" : "plus.circle")
                    Text(isInBookshelf ? "移出书架" : "加入书架")
                }
                .font(.subheadline.bold())
                .foregroundColor(isInBookshelf ? .secondary : .accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)

            // Read Now Button
            Button(action: {
                selectedChapterIndex = currentBookshelfBook.durChapterIndex
                isReading = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "book.fill")
                    Text(currentBookshelfBook.durChapterIndex > 0 ? "继续阅读" : "立即阅读")
                }
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(
            Group {
                #if os(iOS)
                Color(UIColor.systemBackground)
                #else
                Color.primary.colorInvert()
                #endif
            }
            .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: -2)
        )
    }

    // MARK: - Helper Actions

    private func toggleShelf() {
        if isInBookshelf {
            bookStore.removeBook(bookUrl: currentBook.bookUrl)
        } else {
            _ = bookStore.saveOrUpdateBook(currentBook)
        }
    }

    private func loadBookDetails() async {
        guard chapters.isEmpty else { return }

        // If local book, load local chapters from BookStore
        if currentBook.origin == "local" || currentBook.bookUrl.hasPrefix("file://") {
            let localChapters = bookStore.getChapters(for: currentBook.bookUrl)
            if !localChapters.isEmpty {
                await MainActor.run {
                    self.chapters = localChapters
                    self.currentBook.totalChapterNum = localChapters.count
                    if let last = localChapters.last {
                        self.currentBook.latestChapterTitle = last.title
                    }
                }
                return
            }
        }

        let resolvedSource = source ?? bookStore.findSource(for: currentBook)

        guard let src = resolvedSource else { return }

        isLoadingDetails = true
        errorMessage = nil

        do {
            let (detailedBook, fetchedChapters) = try await BookContentService.shared.fetchBookDetail(book: currentBook, source: src)
            await MainActor.run {
                self.currentBook = detailedBook
                self.chapters = fetchedChapters
                self.isLoadingDetails = false

                // If this book is already on the shelf, persist its fetched author, intro and chapters count
                if self.isInBookshelf {
                    _ = self.bookStore.saveOrUpdateBook(detailedBook)
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoadingDetails = false
            }
        }
    }
}

// MARK: - ChapterListView

struct ChapterListView: View {
    @Environment(\.dismiss) private var dismiss
    let chapters: [BookChapter]
    let currentChapterIndex: Int
    let onSelectChapter: (Int) -> Void

    @State private var searchKeyword: String = ""

    private var filteredChapters: [(index: Int, chapter: BookChapter)] {
        let enumerated = chapters.enumerated().map { (index: $0.offset, chapter: $0.element) }
        if searchKeyword.trimmingCharacters(in: .whitespaces).isEmpty {
            return enumerated
        }
        return enumerated.filter { $0.chapter.title.localizedCaseInsensitiveContains(searchKeyword) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search filter
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索章节标题...", text: $searchKeyword)
                if !searchKeyword.isEmpty {
                    Button(action: { searchKeyword = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.top, 8)

            List(filteredChapters, id: \.chapter.id) { item in
                Button(action: {
                    onSelectChapter(item.index)
                }) {
                    HStack {
                        Text(item.chapter.title)
                            .font(.subheadline)
                            .foregroundColor(item.index == currentChapterIndex ? .accentColor : .primary)
                            .lineLimit(1)

                        Spacer()

                        if item.index == currentChapterIndex {
                            Text("上次阅读")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundColor(.accentColor)
                                .cornerRadius(4)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .navigationTitle("目录 (\(chapters.count) 章)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// 详情页点封面弹出来的换封面面板：书源搜到的候选 + 手填地址 + 相册
struct BookCoverPickerSheet: View {
    let bookName: String
    let currentCover: String?
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [(source: String, url: String)] = []
    @State private var isLoading = true
    @State private var manual = ""
    #if os(iOS)
    @State private var pickedImage: Any?
    #endif

    var body: some View {
        NavigationView {
            List {
                if isLoading {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在书源里找这本书的封面…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else if candidates.isEmpty {
                    Section {
                        Text("书源里没搜到封面，用手填地址或相册吧。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if !candidates.isEmpty {
                    Section(header: Text("书源找到的封面（\(candidates.count)）")) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
                            ForEach(candidates, id: \.url) { item in
                                Button {
                                    onPick(item.url)
                                    dismiss()
                                } label: {
                                    VStack(spacing: 4) {
                                        BookCoverImage(urlString: item.url)
                                            .frame(width: 76, height: 104)
                                            .cornerRadius(6)
                                        Text(item.source)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section(header: Text("手填地址")) {
                    TextField("https://…", text: $manual)
                        .autocorrectionDisabled()
                    Button("用这个地址") {
                        let trimmed = manual.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onPick(trimmed)
                        dismiss()
                    }
                    .disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                #if os(iOS)
                if #available(iOS 16.0, *) {
                    Section {
                        PhotosPicker(
                            selection: Binding(
                                get: { pickedImage as? PhotosPickerItem },
                                set: { newValue in
                                    pickedImage = newValue
                                    guard let item = newValue else { return }
                                    Task {
                                        if let data = try? await item.loadTransferable(type: Data.self),
                                           let stored = BookCoverStorage.save(data) {
                                            await MainActor.run {
                                                onPick(stored)
                                                dismiss()
                                            }
                                        }
                                    }
                                }
                            ),
                            matching: .images
                        ) {
                            Label("从相册选封面", systemImage: "photo.on.rectangle")
                        }
                    }
                }
                #endif

                if let currentCover, !currentCover.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            onPick("")
                            dismiss()
                        } label: {
                            Label("清除封面", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("换封面")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        let sources = BookStore.shared.sources.filter { $0.enabled != false }
        candidates = await CoverCandidateFinder.find(bookName: bookName, sources: sources)
        isLoading = false
    }
}

/// 封面：网络地址走 AsyncImage，本地文件（相册选的）直接读盘，省一次请求
struct BookCoverImage: View {
    let urlString: String?
    var contentMode: ContentMode = .fill

    @State private var localImage: Image?

    var body: some View {
        Group {
            if let localImage {
                localImage
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                    case .failure:
                        placeholder
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .task(id: urlString) {
            localImage = Self.loadLocalImage(urlString)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.16)
            Image(systemName: "book.closed")
                .font(.title3)
                .foregroundColor(.secondary)
        }
    }

    /// 只认本地文件，网络地址交给 AsyncImage
    private static func loadLocalImage(_ urlString: String?) -> Image? {
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

/// 相册选的封面存到沙盒里，书里只留文件地址
enum BookCoverStorage {
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Covers", isDirectory: true)
    }

    static func save(_ data: Data) -> String? {
        let dir = directory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".jpg")
        do {
            try data.write(to: url, options: .atomic)
            return url.absoluteString
        } catch {
            return nil
        }
    }
}

/// 去书源里找同一本书，把各家搜到的封面收回来当候选
enum CoverCandidateFinder {
    static func find(bookName: String, sources: [BookSource], limit: Int = 40) async -> [(source: String, url: String)] {
        guard !bookName.isEmpty, !sources.isEmpty else { return [] }
        var found: [(source: String, url: String)] = []
        var seen = Set<String>()

        let stream = BookSearchService.shared.searchMultiSources(sources: sources, key: bookName, page: 1)
        for await (source, books) in stream {
            for candidate in books where candidate.name.contains(bookName) || bookName.contains(candidate.name) {
                guard let cover = candidate.coverUrl, !cover.isEmpty else { continue }
                guard !seen.contains(cover) else { continue }
                seen.insert(cover)
                found.append((source: source.bookSourceName, url: cover))
                if found.count >= limit { return found }
            }
        }
        return found
    }
}

/// 改书名 / 作者 / 封面链接
struct BookInfoEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var author: String
    @State private var cover: String
    @State private var coverError: String?
    @State private var coverCandidates: [(source: String, url: String)] = []
    @State private var isFindingCovers = false
    @State private var coverFinderNote: String?
    #if os(iOS)
    /// 用 Any 存是为了 iOS 15 也能编译（PhotosPickerItem 要 iOS 16+）
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
                    HStack {
                        Spacer()
                        BookCoverImage(urlString: cover, contentMode: .fit)
                            .frame(height: 120)
                        Spacer()
                    }
                }
                #if os(iOS)
                if #available(iOS 16.0, *) {
                    PhotosPicker(
                        selection: Binding(
                            get: { pickedCover as? PhotosPickerItem },
                            set: { newValue in
                                pickedCover = newValue
                                guard let item = newValue else { return }
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
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                #endif
                Button("清除封面") { cover = "" }
                    .foregroundColor(.red)

                Section(header: Text("从书源找封面")) {
                    Button {
                        findCovers()
                    } label: {
                        HStack {
                            Label("用书名去书源搜一圈", systemImage: "square.grid.2x2")
                            Spacer()
                            if isFindingCovers {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isFindingCovers || name.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let coverFinderNote {
                        Text(coverFinderNote)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !coverCandidates.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                            ForEach(coverCandidates, id: \.url) { item in
                                Button {
                                    cover = item.url
                                    coverError = nil
                                } label: {
                                    BookCoverImage(urlString: item.url)
                                        .frame(width: 64, height: 88)
                                        .cornerRadius(6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(cover == item.url ? Color.accentColor : Color.clear, lineWidth: 2)
                                        )
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("编辑书籍信息")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(name.trimmingCharacters(in: .whitespaces), author.trimmingCharacters(in: .whitespaces), cover.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    /// 拿书名去所有启用的书源搜，收各家给出的封面当候选
    private func findCovers() {
        let key = name.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        isFindingCovers = true
        coverFinderNote = nil
        let sources = BookStore.shared.sources.filter { $0.enabled != false }
        Task {
            let found = await CoverCandidateFinder.find(bookName: key, sources: sources)
            await MainActor.run {
                coverCandidates = found
                isFindingCovers = false
                coverFinderNote = found.isEmpty ? "没在书源里搜到封面。" : "点一张就换上。"
            }
        }
    }
}
