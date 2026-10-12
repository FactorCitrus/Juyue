import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif
#if canImport(UIKit)
import UIKit
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

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 16) {
            // Book Cover Image
            if let coverUrlStr = currentBook.coverUrl, let url = URL(string: coverUrlStr) {
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

            VStack(alignment: .leading, spacing: 8) {
                Text(currentBook.name)
                    .font(.title3.bold())
                    .lineLimit(2)
                    .foregroundColor(.primary)

                HStack(spacing: 6) {
                    Image(systemName: "person")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if !currentBook.author.isEmpty && currentBook.author != "未知作者" {
                        Text(currentBook.author)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
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
                if !isInBookshelf {
                    _ = bookStore.saveOrUpdateBook(currentBook)
                }
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
