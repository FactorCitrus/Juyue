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
    @Environment(\.appTheme) private var theme
    @State private var selectedBook: Book? = nil
    @State private var navigateToDetailBook: Book? = nil
    @State private var isSearchActive: Bool = false
    @State private var showFileImporter: Bool = false
    @State private var selectedGroupId: UUID? = nil
    @State private var showNewGroupAlert: Bool = false
    @State private var newGroupName: String = ""
    @State private var importErrorMessage: String? = nil
    @State private var showImportAlert: Bool = false
    @State private var isOrganizing = false
    @State private var selectedBookIDs: Set<String> = []
    @State private var showDeleteSelectedAlert = false

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
                .background(isSelected ? theme.palette.accent : theme.palette.surface.opacity(0.88))
                .foregroundColor(isSelected ? theme.palette.onAccent : theme.palette.ink)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                        .stroke(isSelected ? theme.palette.accent : theme.palette.divider,
                                lineWidth: theme.metrics.borderWidth)
                )
                .cornerRadius(theme.metrics.cornerRadius)
        }
        .buttonStyle(.plain)
    }

    private var bookshelfHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ARCHIVE / LIBRARY")
                    .font(theme.typography.label)
                Spacer()
                Text("SYS.READY")
                    .font(theme.typography.mono)
            }
            .foregroundColor(theme.palette.secondaryInk)

            HStack(alignment: .firstTextBaseline) {
                Text("档案库")
                    .font(theme.typography.title)
                    .foregroundColor(theme.palette.ink)
                Spacer()
                Text("\(bookStore.bookshelf.count) BOOKS")
                    .font(theme.typography.mono)
                    .foregroundColor(theme.palette.secondaryInk)
            }

            Text("\(bookStore.groups.count) GROUPS · \(readingBookCount) IN PROGRESS")
                .font(theme.typography.mono)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [theme.palette.elevated.opacity(0.9), theme.palette.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.palette.accent)
                .frame(width: 3)
        }
        .overlay(alignment: .trailing) {
            Text(String(format: "%03d", bookStore.bookshelf.count))
                .font(.system(size: 58, weight: .bold, design: .monospaced))
                .foregroundColor(theme.palette.ink.opacity(0.035))
                .padding(.trailing, 10)
        }
        .overlay(
            Rectangle()
                .stroke(theme.palette.divider.opacity(0.85), lineWidth: theme.metrics.borderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 5)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var readingBookCount: Int {
        bookStore.bookshelf.filter {
            $0.durChapterIndex > 0 || !($0.durChapterTitle ?? "").isEmpty
        }.count
    }

    private var organizerBar: some View {
        HStack(spacing: 10) {
            Button(allVisibleSelected ? "取消全选" : "全选") {
                if allVisibleSelected {
                    selectedBookIDs.removeAll()
                } else {
                    selectedBookIDs = Set(displayedBooks.map(\.bookUrl))
                }
            }

            Menu {
                Button("未分组") {
                    for url in selectedBookIDs {
                        if let book = bookStore.bookshelf.first(where: { $0.bookUrl == url }) {
                            bookStore.assign(book, toGroup: nil)
                        }
                    }
                }
                ForEach(bookStore.groups) { group in
                    Button(group.name) {
                        for url in selectedBookIDs {
                            if let book = bookStore.bookshelf.first(where: { $0.bookUrl == url }) {
                                bookStore.assign(book, toGroup: group.id)
                            }
                        }
                    }
                }
            } label: {
                Label("分组", systemImage: "folder")
            }
            .disabled(selectedBookIDs.isEmpty)

            Button(role: .destructive) {
                showDeleteSelectedAlert = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(selectedBookIDs.isEmpty)

            Spacer()

            Text("\(selectedBookIDs.count) 本")
                .font(theme.typography.mono)
                .foregroundColor(theme.palette.secondaryInk)

            Button("完成") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isOrganizing = false
                    selectedBookIDs.removeAll()
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.palette.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.palette.divider)
                .frame(height: 1)
        }
    }

    private var allVisibleSelected: Bool {
        !displayedBooks.isEmpty && displayedBooks.allSatisfy { selectedBookIDs.contains($0.bookUrl) }
    }

    private var bookshelfGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 12
            ) {
                ForEach(Array(displayedBooks.enumerated()), id: \.element.id) { index, book in
                    bookshelfCard(book, index: index)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .refreshable {
            await bookStore.refreshAllBooks()
        }
    }

    private func bookshelfCard(_ book: Book, index: Int) -> some View {
        let isSelected = selectedBookIDs.contains(book.bookUrl)
        return Button {
            if isOrganizing {
                if isSelected {
                    selectedBookIDs.remove(book.bookUrl)
                } else {
                    selectedBookIDs.insert(book.bookUrl)
                }
            } else {
                selectedBook = book
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    Group {
                        if book.coverUrl != nil {
                            BookCoverImage(urlString: book.coverUrl)
                        } else {
                            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius)
                                .fill(
                                    LinearGradient(
                                        colors: [theme.palette.elevated, theme.palette.surface],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay(
                                    Image(systemName: "book.closed.fill")
                                        .font(.title2)
                                        .foregroundColor(theme.palette.accent.opacity(0.65))
                                )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipped()
                    .overlay(
                        LinearGradient(
                            colors: [
                                theme.palette.background.opacity(0.08),
                                .clear,
                                theme.palette.background.opacity(0.10)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [.clear, theme.palette.surface.opacity(0.88)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 42)
                    }

                    if isOrganizing {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(isSelected ? theme.palette.accent : theme.palette.secondaryInk)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                HStack(spacing: 6) {
                    Text(String(format: "ARCHIVE %02d", index + 1))
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.secondaryInk)
                    Spacer()
                    if let group = bookStore.groups.first(where: { $0.id == book.groupId }) {
                        Text(group.name)
                            .font(theme.typography.mono)
                            .foregroundColor(theme.palette.accent)
                            .lineLimit(1)
                    }
                }

                Text(book.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.palette.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !book.author.isEmpty && book.author != "未知作者" {
                    Text(book.author)
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.secondaryInk)
                        .lineLimit(1)
                }

                if book.totalChapterNum > 0 {
                    let read = min(book.durChapterIndex + 1, book.totalChapterNum)
                    ProgressView(value: Double(read), total: Double(book.totalChapterNum))
                        .tint(theme.palette.accent)
                    Text("\(read)/\(book.totalChapterNum) CHAPTERS")
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.secondaryInk)
                } else if let chapter = book.durChapterTitle, !chapter.isEmpty {
                    Text(chapter)
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.secondaryInk)
                        .lineLimit(1)
                }

            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: [theme.palette.surface.opacity(0.94), theme.palette.surface],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                    .stroke(isSelected ? theme.palette.accent : theme.palette.divider.opacity(0.45),
                            lineWidth: isSelected ? 1.4 : theme.metrics.borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.035), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .onLongPressGesture {
            navigateToDetailBook = book
        }
        .contextMenu {
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
            Button(role: .destructive) {
                bookStore.removeBook(bookUrl: book.bookUrl)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
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
            VStack(spacing: 0) {
                bookshelfHeader
                if bookStore.bookshelf.isEmpty {
                    emptyShelfView
                } else {
                    groupFilterBar
                    bookshelfGrid
                }
            }
            .background(AppThemeBackdrop())
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
            .safeAreaInset(edge: .bottom) {
                if isOrganizing {
                    organizerBar
                }
            }
            .alert("删除选中的书籍", isPresented: $showDeleteSelectedAlert) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    for url in selectedBookIDs {
                        bookStore.removeBook(bookUrl: url)
                    }
                    selectedBookIDs.removeAll()
                }
            } message: {
                Text("将删除 \(selectedBookIDs.count) 本书，阅读进度与缓存也会一起移除。")
            }
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

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isOrganizing.toggle()
                            if !isOrganizing { selectedBookIDs.removeAll() }
                        }
                    } label: {
                        Image(systemName: isOrganizing ? "checkmark.circle.fill" : "square.grid.2x2")
                    }
                    .accessibilityLabel(isOrganizing ? "完成整理" : "整理书架")
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
                    let ext = url.pathExtension.lowercased()
                    let canAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if canAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    do {
                        let imported = try bookStore.importFile(from: url)
                        AppLog.write("[导入] 本地文件成功 type=\(ext.isEmpty ? "?" : ext)")
                        selectedBook = imported
                    } catch {
                        AppLog.write("[导入] 本地文件失败 type=\(ext.isEmpty ? "?" : ext) error=\(error.localizedDescription)")
                        importErrorMessage = "导入失败: \(error.localizedDescription)"
                        showImportAlert = true
                    }
                case .failure(let error):
                    AppLog.write("[导入] 文件选择失败 error=\(error.localizedDescription)")
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
                    AppLog.write("[书架] 新建分组")
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
        .background(AppThemeBackdrop())
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
                .background(theme.palette.accent)
                .foregroundColor(theme.palette.onAccent)
                .cornerRadius(theme.metrics.cornerRadius)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.background)
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
