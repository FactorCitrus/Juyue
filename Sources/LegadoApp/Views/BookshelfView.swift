import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif
import UniformTypeIdentifiers

public struct BookshelfView: View {
    @ObservedObject var bookStore = BookStore.shared
    @State private var selectedBook: Book? = nil
    @State private var navigateToDetailBook: Book? = nil
    @State private var isSearchActive: Bool = false
    @State private var showFileImporter: Bool = false
    @State private var importErrorMessage: String? = nil
    @State private var showImportAlert: Bool = false

    public init() {}

    private var sortedBookshelf: [Book] {
        bookStore.bookshelf.sorted { b1, b2 in
            let t1 = max(b1.durChapterTime, b1.lastCheckTime)
            let t2 = max(b2.durChapterTime, b2.lastCheckTime)
            return t1 > t2
        }
    }

    public var body: some View {
        ZStack {
            NavigationView {
            Group {
                if bookStore.bookshelf.isEmpty {
                    emptyShelfView
                } else {
                    List {
                        ForEach(sortedBookshelf) { book in
                            BookRow(book: book)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedBook = book
                                }
                                .onLongPressGesture {
                                    navigateToDetailBook = book
                                }
                        }
                        .onDelete { indexSet in
                            for idx in indexSet {
                                bookStore.removeBook(bookUrl: sortedBookshelf[idx].bookUrl)
                            }
                        }
                    }
                    .refreshable {
                        await bookStore.refreshAllBooks()
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #else
                    .listStyle(.inset)
                    #endif
                }
            }
            .background(
                Group {
                    // Programmatic push to SearchBookView
                    NavigationLink(
                        isActive: $isSearchActive,
                        destination: { SearchBookView() },
                        label: { EmptyView() }
                    )

                    // Programmatic push to BookDetailView on long press
                    NavigationLink(
                        isActive: Binding(
                            get: { navigateToDetailBook != nil },
                            set: { if !$0 { navigateToDetailBook = nil } }
                        ),
                        destination: {
                            if let b = navigateToDetailBook {
                                let source = bookStore.findSource(for: b)
                                BookDetailView(book: b, source: source)
                            } else {
                                EmptyView()
                            }
                        },
                        label: { EmptyView() }
                    )
                }
                .hidden()
                .frame(width: 0, height: 0)
            )
            .navigationTitle("我的书架")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Search button activating isSearchActive
                    Button(action: { isSearchActive = true }) {
                        Image(systemName: "magnifyingglass")
                    }

                    // Import local file button
                    Button(action: { showFileImporter = true }) {
                        Image(systemName: "doc.badge.plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.epub, .plainText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let canAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if canAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    do {
                        let imported = try bookStore.importFile(from: url)
                        selectedBook = imported
                    } catch {
                        importErrorMessage = "导入失败: \(error.localizedDescription)"
                        showImportAlert = true
                    }
                case .failure(let error):
                    importErrorMessage = "打开文件失败: \(error.localizedDescription)"
                    showImportAlert = true
                }
            }
            .alert(importErrorMessage ?? "", isPresented: $showImportAlert) {
                Button("确定", role: .cancel) {}
            }
            #if os(iOS)
            .fullScreenCover(item: $selectedBook) { book in
                readerCoverView(for: book)
            }
            #endif
        }
        #if !os(iOS)
        if let book = selectedBook {
            readerCoverView(for: book)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .transition(.opacity)
                .zIndex(999)
        }
        #endif
        }
    }

    @ViewBuilder
    private func readerCoverView(for book: Book) -> some View {
        let source = bookStore.findSource(for: book)
        NavigationView {
            ReaderView(book: book, source: source, onDismiss: {
                selectedBook = nil
            })
        }
    }

    private var emptyShelfView: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.6))
            Text("书架空空如也")
                .font(.headline)
            Text("可点击右上角放大镜搜索网络小说，或点击“+”导入本地书籍")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: { isSearchActive = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("前往全网搜索")
                }
                .font(.subheadline.bold())
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(20)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding()
    }
}

// MARK: - BookRow (Legado Android Style)

struct BookRow: View {
    let book: Book

    private var unreadCount: Int {
        guard book.totalChapterNum > 0 else { return 0 }
        let readCount = book.durChapterTitle != nil ? (book.durChapterIndex + 1) : 0
        return max(0, book.totalChapterNum - readCount)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Book cover with Unread Red Badge
            ZStack(alignment: .topTrailing) {
                if let coverUrlStr = book.coverUrl, let url = URL(string: coverUrlStr) {
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
                    .frame(width: 54, height: 74)
                    .cornerRadius(6)
                    .clipped()
                } else {
                    coverPlaceholder
                }

                // Red dot / badge indicating unread chapters count
                if unreadCount > 0 {
                    Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .offset(x: 6, y: -6)
                }
            }

            // Info column: Title, Author, Latest Chapter, Read Progress (No source)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.name)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                if !book.author.isEmpty && book.author != "未知作者" {
                    Text(book.author)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if let latest = book.latestChapterTitle, !latest.isEmpty {
                    Text("最新: \(latest)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                HStack {
                    if let chapter = book.durChapterTitle, !chapter.isEmpty {
                        Text("已读: \(chapter)")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                    } else {
                        Text("未读")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.8))
                    }

                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.12))
            .frame(width: 54, height: 74)
            .overlay(
                Image(systemName: "book.closed.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor.opacity(0.8))
            )
    }
}
