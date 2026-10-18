import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif
import UniformTypeIdentifiers

/// 书架角标的外观配置。
/// 原来那个红色 99+ 是写死的，颜色、位置、封顶都改不了。
public enum BookshelfBadgeStyle: String, CaseIterable, Identifiable {
    case count = "未读章数"
    case dot = "只显示圆点"
    case hidden = "不显示"

    public var id: String { rawValue }
}

public enum BookshelfBadgeCorner: String, CaseIterable, Identifiable {
    case topTrailing = "右上"
    case topLeading = "左上"

    public var id: String { rawValue }
}

public class BookshelfConfig: ObservableObject {
    public static let shared = BookshelfConfig()
    private static let defaults = UserDefaults.standard

    @Published public var badgeStyle: BookshelfBadgeStyle = .count {
        didSet { Self.defaults.set(badgeStyle.rawValue, forKey: "shelf_badge_style") }
    }
    /// 数字封顶：超过就显示成 "N+"，填 0 表示不封顶
    @Published public var badgeCap: Int = 99 {
        didSet { Self.defaults.set(badgeCap, forKey: "shelf_badge_cap") }
    }
    @Published public var badgeColorHex: String = "#FF3B30" {
        didSet { Self.defaults.set(badgeColorHex, forKey: "shelf_badge_color") }
    }
    @Published public var badgeCorner: BookshelfBadgeCorner = .topTrailing {
        didSet { Self.defaults.set(badgeCorner.rawValue, forKey: "shelf_badge_corner") }
    }
    @Published public var badgeFontSize: CGFloat = 9 {
        didSet { Self.defaults.set(Double(badgeFontSize), forKey: "shelf_badge_font_size") }
    }
    /// 描一圈底色，压在深色封面上才分得出来
    @Published public var badgeOutline: Bool = true {
        didSet { Self.defaults.set(badgeOutline, forKey: "shelf_badge_outline") }
    }
    /// 角标离封面角的距离
    @Published public var badgeOffset: CGFloat = 6 {
        didSet { Self.defaults.set(Double(badgeOffset), forKey: "shelf_badge_offset") }
    }

    public var badgeColor: Color { Color(hex: badgeColorHex) ?? .red }

    public init() {
        let d = Self.defaults
        if let v = d.string(forKey: "shelf_badge_style"), let s = BookshelfBadgeStyle(rawValue: v) {
            badgeStyle = s
        }
        if d.object(forKey: "shelf_badge_cap") != nil { badgeCap = d.integer(forKey: "shelf_badge_cap") }
        if let v = d.string(forKey: "shelf_badge_color") { badgeColorHex = v }
        if let v = d.string(forKey: "shelf_badge_corner"), let c = BookshelfBadgeCorner(rawValue: v) {
            badgeCorner = c
        }
        if d.object(forKey: "shelf_badge_font_size") != nil {
            badgeFontSize = CGFloat(d.double(forKey: "shelf_badge_font_size"))
        }
        if d.object(forKey: "shelf_badge_outline") != nil { badgeOutline = d.bool(forKey: "shelf_badge_outline") }
        if d.object(forKey: "shelf_badge_offset") != nil {
            badgeOffset = CGFloat(d.double(forKey: "shelf_badge_offset"))
        }
    }
}

public struct BookshelfView: View {
    @ObservedObject var bookStore = BookStore.shared
    @State private var selectedBook: Book? = nil
    @State private var navigateToDetailBook: Book? = nil
    @State private var isSearchActive: Bool = false
    @State private var showFileImporter: Bool = false
    @State private var selectedGroupId: UUID? = nil
    @State private var showNewGroupAlert: Bool = false
    @State private var newGroupName: String = ""
    @State private var importErrorMessage: String? = nil
    @State private var showImportAlert: Bool = false

    public init() {}

    /// 分组筛选：nil = 全部
    private var displayedBooks: [Book] {
        guard let selectedGroupId else { return sortedBookshelf }
        return sortedBookshelf.filter { $0.groupId == selectedGroupId }
    }

    private var groupFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                groupChip(title: "全部", isSelected: selectedGroupId == nil) {
                    selectedGroupId = nil
                }
                ForEach(bookStore.groups) { group in
                    groupChip(title: group.name, isSelected: selectedGroupId == group.id) {
                        selectedGroupId = group.id
                    }
                }
                Button {
                    newGroupName = ""
                    showNewGroupAlert = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 11))
                        Text("新建分组").font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(14)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func groupChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.12))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }

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
                    VStack(spacing: 0) {
                    groupFilterBar
                    List {
                        ForEach(displayedBooks) { book in
                            BookRow(book: book)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedBook = book
                                }
                                .onLongPressGesture {
                                    navigateToDetailBook = book
                                }
                                .contextMenu {
                                    // 长按默认弹的是这个菜单，.onLongPressGesture 抢不到，
                                    // 所以详情的入口放这儿
                                    Button {
                                        navigateToDetailBook = book
                                    } label: {
                                        Label("书籍详情", systemImage: "info.circle")
                                    }
                                    Menu("移动到分组") {
                                        Button("未分组") { bookStore.assign(book, toGroup: nil) }
                                        ForEach(bookStore.groups) { group in
                                            Button(group.name) { bookStore.assign(book, toGroup: group.id) }
                                        }
                                        Divider()
                                        Button("新建分组…") {
                                            newGroupName = ""
                                            showNewGroupAlert = true
                                        }
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    Button {
                                        navigateToDetailBook = book
                                    } label: {
                                        Label("详情", systemImage: "info.circle")
                                    }
                                    .tint(.blue)
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
                    if !AppEdition.isAppStoreClean {
                        // Search button activating isSearchActive
                        Button(action: { isSearchActive = true }) {
                            Image(systemName: "magnifyingglass")
                        }
                    }

                    // Import local file button
                    Button(action: { showFileImporter = true }) {
                        Image(systemName: "doc.badge.plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.epub, .plainText, .pdf, .zip, .archive],
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
            .alert("新建分组", isPresented: $showNewGroupAlert) {
                TextField("分组名", text: $newGroupName)
                Button("创建") {
                    let group = bookStore.addGroup(name: newGroupName)
                    selectedGroupId = group.id
                }
                Button("取消", role: .cancel) {}
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
            Text(AppEdition.isAppStoreClean
                 ? "点击右上角“+”导入本地 TXT / EPUB / PDF"
                 : "可点击右上角放大镜搜索网络小说，或点击“+”导入本地书籍")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if AppEdition.isAppStoreClean {
                Button(action: { showFileImporter = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus")
                        Text("导入本地书籍")
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

                Text("本应用不提供书籍内容，请导入你拥有合法使用权的文件。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
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
        }
        .padding()
    }
}

// MARK: - BookRow (Legado Android Style)

struct BookRow: View {
    let book: Book
    @ObservedObject private var shelfConfig = BookshelfConfig.shared

    private var unreadCount: Int {
        guard book.totalChapterNum > 0 else { return 0 }
        let readCount = book.durChapterTitle != nil ? (book.durChapterIndex + 1) : 0
        return max(0, book.totalChapterNum - readCount)
    }

    private var showsBadge: Bool {
        shelfConfig.badgeStyle != .hidden && unreadCount > 0
    }

    /// 只有「未读章数」才出数字；封顶填 0 表示不封顶
    private var badgeText: String? {
        guard shelfConfig.badgeStyle == .count else { return nil }
        let cap = shelfConfig.badgeCap
        if cap > 0 && unreadCount > cap { return "\(cap)+" }
        return "\(unreadCount)"
    }

    private var badgeOffsetX: CGFloat {
        shelfConfig.badgeCorner == .topTrailing ? shelfConfig.badgeOffset : -shelfConfig.badgeOffset
    }

    @ViewBuilder
    private var badgeView: some View {
        let fontSize = max(7, shelfConfig.badgeFontSize)
        if let text = badgeText {
            Text(text)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, max(3, fontSize * 0.5))
                .padding(.vertical, max(1, fontSize * 0.22))
                .background(Capsule().fill(shelfConfig.badgeColor))
                .overlay {
                    if shelfConfig.badgeOutline {
                        Capsule().stroke(Color(white: 1).opacity(0.85), lineWidth: 1.5)
                    }
                }
                .offset(x: badgeOffsetX, y: -shelfConfig.badgeOffset)
        } else {
            Circle()
                .fill(shelfConfig.badgeColor)
                .frame(width: fontSize + 3, height: fontSize + 3)
                .overlay {
                    if shelfConfig.badgeOutline {
                        Circle().stroke(Color(white: 1).opacity(0.85), lineWidth: 1.5)
                    }
                }
                .offset(x: badgeOffsetX, y: -shelfConfig.badgeOffset)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Book cover with Unread Red Badge
            ZStack(alignment: shelfConfig.badgeCorner == .topTrailing ? .topTrailing : .topLeading) {
                if book.coverUrl != nil {
                    // 走统一的封面视图：相册选的本地封面也在这儿显示
                    BookCoverImage(urlString: book.coverUrl)
                    .frame(width: 54, height: 74)
                    .cornerRadius(6)
                    .clipped()
                } else {
                    coverPlaceholder
                }

                if showsBadge {
                    badgeView
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
