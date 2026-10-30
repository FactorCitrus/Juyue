import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
typealias ShelfLogoImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias ShelfLogoImage = NSImage
#endif

/// 拖动预览用的快照图。macOS 构建没有 UIImage，这里给个占位类型，
/// 让 `dragSnapshot` 这类状态在两端都能编译；macOS 上 makeDragSnapshot 始终返回 nil。
#if canImport(UIKit)
typealias ShelfDragImage = UIImage
#else
struct ShelfDragImage {}
#endif

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

/// 书架排列：分栏网格或单列列表。
public enum BookshelfLayoutStyle: String, CaseIterable, Identifiable {
    case grid = "分栏"
    case list = "列表"

    public var id: String { rawValue }
}

private struct ShelfFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 没有封面时的默认封面：纸面底 + 书名首字 + NO COVER 记号。
private struct DefaultBookCover: View {
    let book: Book
    @Environment(\.appTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(
                    colors: [theme.palette.elevated, theme.palette.surface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: side * 0.05) {
                    Text(String(book.name.prefix(1)))
                        .font(.system(size: side * 0.40, weight: .bold, design: .serif))
                        .foregroundColor(theme.palette.ink.opacity(0.28))
                    Text("NO COVER")
                        .font(.system(size: max(7, side * 0.08), weight: .medium, design: .monospaced))
                        .foregroundColor(theme.palette.secondaryInk.opacity(0.85))
                }

                Rectangle()
                    .stroke(theme.palette.divider.opacity(0.55), lineWidth: 0.8)
                    .padding(side * 0.07)

                VStack {
                    Spacer()
                    HStack {
                        Rectangle()
                            .fill(theme.palette.accent)
                            .frame(width: side * 0.18, height: 2)
                        Spacer()
                    }
                }
                .padding(side * 0.09)
            }
        }
    }
}

/// 只在指定模式挂手势：整理模式才启用跟手拖，平时不抢滚动。
private struct ConditionalGesture<G: Gesture>: ViewModifier {
    let enabled: Bool
    let gesture: G

    func body(content: Content) -> some View {
        if enabled {
            content.simultaneousGesture(gesture)
        } else {
            content
        }
    }
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

    @Published public var layout: BookshelfLayoutStyle = .grid {
        didSet { Self.defaults.set(layout.rawValue, forKey: "shelf_layout_style") }
    }
    /// 分栏模式的列数，2 到 4
    @Published public var gridColumns: Int = 2 {
        didSet { Self.defaults.set(gridColumns, forKey: "shelf_grid_columns") }
    }
    /// 封面尺寸倍率：0.8 小图，1.3 大图
    @Published public var cardScale: CGFloat = 1.0 {
        didSet { Self.defaults.set(Double(cardScale), forKey: "shelf_card_scale") }
    }

    /// 书架标题：文字、字号、水平/垂直位置都能单独调
    @Published public var titleText: String = "我的书架" {
        didSet { Self.defaults.set(titleText, forKey: "shelf_title_text") }
    }
    /// 自定义图标本身带字时可以关掉标题文字，避免出现两行「我的书架」
    @Published public var titleVisible: Bool = true {
        didSet { Self.defaults.set(titleVisible, forKey: "shelf_title_visible") }
    }
    @Published public var titleFontSize: CGFloat = 30 {
        didSet { Self.defaults.set(Double(titleFontSize), forKey: "shelf_title_font_size") }
    }
    @Published public var titleOffsetX: CGFloat = 0 {
        didSet { Self.defaults.set(Double(titleOffsetX), forKey: "shelf_title_offset_x") }
    }
    @Published public var titleOffsetY: CGFloat = 0 {
        didSet { Self.defaults.set(Double(titleOffsetY), forKey: "shelf_title_offset_y") }
    }
    /// 书架图标（ShelfMark）可以换成相册里的图，大小与位置单独调
    @Published public var logoHeight: CGFloat = 72 {
        didSet { Self.defaults.set(Double(logoHeight), forKey: "shelf_logo_height") }
    }
    @Published public var logoOffsetX: CGFloat = 0 {
        didSet { Self.defaults.set(Double(logoOffsetX), forKey: "shelf_logo_offset_x") }
    }
    @Published public var logoOffsetY: CGFloat = 0 {
        didSet { Self.defaults.set(Double(logoOffsetY), forKey: "shelf_logo_offset_y") }
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
        if let v = d.string(forKey: "shelf_layout_style"), let l = BookshelfLayoutStyle(rawValue: v) {
            layout = l
        }
        if d.object(forKey: "shelf_grid_columns") != nil {
            gridColumns = min(4, max(2, d.integer(forKey: "shelf_grid_columns")))
        }
        if d.object(forKey: "shelf_card_scale") != nil {
            cardScale = min(1.40, max(0.40, CGFloat(d.double(forKey: "shelf_card_scale"))))
        }
        if let text = d.string(forKey: "shelf_title_text") { titleText = text }
        if d.object(forKey: "shelf_title_visible") != nil { titleVisible = d.bool(forKey: "shelf_title_visible") }
        if d.object(forKey: "shelf_title_font_size") != nil {
            titleFontSize = min(75, max(14, CGFloat(d.double(forKey: "shelf_title_font_size"))))
        }
        if d.object(forKey: "shelf_title_offset_x") != nil {
            titleOffsetX = min(120, max(-120, CGFloat(d.double(forKey: "shelf_title_offset_x"))))
        }
        if d.object(forKey: "shelf_title_offset_y") != nil {
            titleOffsetY = min(60, max(-40, CGFloat(d.double(forKey: "shelf_title_offset_y"))))
        }
        if d.object(forKey: "shelf_logo_height") != nil {
            logoHeight = min(160, max(32, CGFloat(d.double(forKey: "shelf_logo_height"))))
        }
        if d.object(forKey: "shelf_logo_offset_x") != nil {
            logoOffsetX = min(80, max(-80, CGFloat(d.double(forKey: "shelf_logo_offset_x"))))
        }
        if d.object(forKey: "shelf_logo_offset_y") != nil {
            logoOffsetY = min(40, max(-40, CGFloat(d.double(forKey: "shelf_logo_offset_y"))))
        }
        AppLog.write("[书架] 载入 标题字号=\(titleFontSize) 位置=\(titleOffsetX),\(titleOffsetY) 文字长度=\(titleText.count) 列=\(gridColumns) 卡片=\(cardScale)")
        AppLog.write("[书架] 图标 大小=\(logoHeight) 位置=\(logoOffsetX),\(logoOffsetY) 自定义=\(ShelfLogoStorage.hasImage)")
    }
}

/// 自定义书架图标：固定写在 Documents/ShelfLogo/custom-logo.png。
enum ShelfLogoStorage {
    static var folderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShelfLogo", isDirectory: true)
    }
    static var fileURL: URL { folderURL.appendingPathComponent("custom-logo.png") }
    static var hasImage: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
}

/// 图标在书架与设置预览之间共享，换图后两边同时刷新
final class ShelfLogoStore: ObservableObject {
    static let shared = ShelfLogoStore()

    @Published private(set) var image: ShelfLogoImage?

    private init() { reload() }

    func reload() {
        #if canImport(UIKit)
        image = UIImage(contentsOfFile: ShelfLogoStorage.fileURL.path)
        #else
        image = nil
        #endif
    }

    @discardableResult
    func save(_ data: Data) -> Bool {
        #if canImport(UIKit)
        guard let source = UIImage(data: data) else { return false }
        // 相册原图可能几千万像素，先缩到 1024，避免书架每次进都解大图
        let maxSide: CGFloat = 1024
        let longest = max(source.size.width, source.size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let size = CGSize(width: max(1, source.size.width * scale), height: max(1, source.size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
        guard let png = resized.pngData() else { return false }
        try? FileManager.default.createDirectory(at: ShelfLogoStorage.folderURL, withIntermediateDirectories: true)
        guard (try? png.write(to: ShelfLogoStorage.fileURL)) != nil else { return false }
        reload()
        return true
        #else
        return false
        #endif
    }

    func clear() {
        try? FileManager.default.removeItem(at: ShelfLogoStorage.fileURL)
        reload()
    }
}

public struct BookshelfView: View {
    @ObservedObject var bookStore = BookStore.shared
    @ObservedObject private var shelfConfig = BookshelfConfig.shared
    @StateObject private var shelfLogo = ShelfLogoStore.shared
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
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
    @State private var showShelfSizeSheet = false
    @State private var draggingBook: Book? = nil
    @State private var dragLocation: CGPoint = .zero
    @State private var dragCover: Image? = nil
    @State private var dragSnapshot: ShelfDragImage? = nil
    @State private var hoveredBookUrl: String? = nil
    @State private var lastLiveTarget: String? = nil
    @State private var cardFrames: [String: CGRect] = [:]

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
        VStack(alignment: .leading, spacing: 12) {
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

    /// 书架标题：logo 用模板色跟随主题墨色，配合标题字。
    private var shelfTitleLockup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                Group {
                    if let custom = shelfLogo.image {
                        #if canImport(UIKit)
                        Image(uiImage: custom)
                            .resizable()
                            .scaledToFit()
                        #else
                        Image(nsImage: custom)
                            .resizable()
                            .scaledToFit()
                        #endif
                    } else if AppEdition.isAppStoreClean {
                        // 商店包不能带第三方角色美术：换成程序绘制的档案标记
                        ShelfEditionMark(ink: theme.palette.ink, accent: theme.palette.accent)
                    } else if colorScheme == .dark {
                        Image("ShelfMark")
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .colorInvert()
                    } else {
                        Image("ShelfMark")
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(height: shelfConfig.logoHeight)
                .offset(x: shelfConfig.logoOffsetX, y: shelfConfig.logoOffsetY)
                .accessibilityHidden(true)

                if shelfConfig.titleVisible {
                    Text(shelfDisplayTitle)
                        .font(.system(size: shelfConfig.titleFontSize, weight: .bold))
                        .foregroundColor(theme.palette.ink)
                        .lineLimit(1)
                        // 字号要真实生效：别在 29pt 以后又自动缩回去
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: shelfConfig.titleOffsetX, y: shelfConfig.titleOffsetY)
                        .padding(.bottom, 4)
                }

                Spacer(minLength: 0)
            }
            .overlay(alignment: .bottomTrailing) {
                shelfHeaderActions
                    .padding(.bottom, 4)
            }

            // 标题下的装饰线：短红条 + 细线 + 末端小方块，呼应档案终端的分隔记号
            HStack(spacing: 0) {
                Rectangle()
                    .fill(theme.palette.accent)
                    .frame(width: 24, height: 2)
                Rectangle()
                    .fill(theme.palette.divider.opacity(0.9))
                    .frame(height: 0.5)
                Rectangle()
                    .fill(theme.palette.ink.opacity(0.75))
                    .frame(width: 4, height: 4)
            }
            .padding(.leading, 6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(shelfDisplayTitle)
    }

    private var shelfDisplayTitle: String {
        let text = shelfConfig.titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "我的书架" : text
    }

    private var readingBookCount: Int {
        bookStore.bookshelf.filter {
            $0.durChapterIndex > 0 || !($0.durChapterTitle ?? "").isEmpty
        }.count
    }

    private var shelfSizeSheet: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            theme.palette.surface
                .opacity(0.35)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("卡片大小")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(theme.palette.ink)
                    Spacer()
                    Text("\(Int((shelfConfig.cardScale * 100).rounded()))% · \(autoColumnCount) 列")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.palette.secondaryInk)
                }

                Slider(value: $shelfConfig.cardScale, in: 0.40...1.40, step: 0.01)
                    .tint(theme.palette.accent)

                HStack(spacing: 10) {
                    Button {
                        adjustCardScale(-0.01)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 32, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(theme.palette.elevated))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.palette.ink)

                    Text("1% 步进 · 40%–140%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.palette.secondaryInk)
                    Spacer()
                    Button {
                        adjustCardScale(0.01)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 32, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(theme.palette.elevated))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.palette.ink)
                }

                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func adjustCardScale(_ delta: CGFloat) {
        shelfConfig.cardScale = min(1.40, max(0.40, shelfConfig.cardScale + delta))
    }

    private var shelfHeaderActions: some View {
        HStack(spacing: 16) {
            Button {
                isSearchActive = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("搜索书籍")

            Button {
                showFileImporter = true
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .accessibilityLabel("导入本地文件")

            Menu {
                shelfLayoutMenu
            } label: {
                Image(systemName: isOrganizing
                      ? "checkmark.circle.fill"
                      : (shelfConfig.layout == .grid ? "square.grid.2x2" : "list.bullet"))
            }
            .accessibilityLabel(isOrganizing ? "书架排列与整理，整理中" : "书架排列与整理")
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(theme.palette.accent)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var shelfLayoutMenu: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isOrganizing.toggle()
                if !isOrganizing { selectedBookIDs.removeAll() }
            }
            AppLog.write("[书架] \(isOrganizing ? "进入" : "退出")整理模式 已选=\(selectedBookIDs.count)")
        } label: {
            Label(isOrganizing ? "完成整理" : "整理书架",
                  systemImage: isOrganizing ? "checkmark.circle" : "checklist")
        }

        Divider()

        Button {
            shelfConfig.layout = .grid
        } label: {
            HStack {
                Text("分栏 · 自动列数")
                if shelfConfig.layout == .grid {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }

        Button {
            shelfConfig.layout = .list
        } label: {
            HStack {
                Text("列表 · 单列")
                if shelfConfig.layout == .list {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }

        Menu("卡片大小") {
            Button("极小 · 45%（4 列）") { shelfConfig.cardScale = 0.45 }
            Button("小 · 65%（4 列）") { shelfConfig.cardScale = 0.65 }
            Button("中 · 80%（3 列）") { shelfConfig.cardScale = 0.80 }
            Button("标准 · 100%（2 列）") { shelfConfig.cardScale = 1.0 }
            Button("大 · 125%（2 列）") { shelfConfig.cardScale = 1.25 }
            Button("特大 · 140%（2 列）") { shelfConfig.cardScale = 1.40 }
            Divider()
            Button("自定义大小…") { showShelfSizeSheet = true }
        }

        Button("恢复最近阅读排序") {
            withAnimation(.easeInOut(duration: 0.2)) {
                resetShelfOrder()
            }
        }
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
            ZStack(alignment: .topLeading) {
                Group {
                    switch shelfConfig.layout {
                    case .grid:
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(Array(displayedBooks.enumerated()), id: \.element.id) { index, book in
                                bookshelfCard(book, index: index)
                            }
                        }
                    case .list:
                        LazyVStack(spacing: 10) {
                            ForEach(Array(displayedBooks.enumerated()), id: \.element.id) { index, book in
                                bookshelfRow(book, index: index)
                            }
                        }
                    }
                }

                if let draggingBook {
                    draggedCardOverlay(draggingBook)
                        .position(dragLocation)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: displayedBooks.map(\.bookUrl))
            .coordinateSpace(name: "shelfSpace")
            .onPreferenceChange(ShelfFrameKey.self) { cardFrames = $0 }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .refreshable {
            await bookStore.refreshAllBooks()
        }
    }

    @ViewBuilder
    private func draggedCardOverlay(_ book: Book) -> some View {
        let index = displayedBooks.firstIndex(where: { $0.bookUrl == book.bookUrl }) ?? 0
        Group {
            if let dragSnapshotImage {
                dragSnapshotImage
                    .resizable()
                    .scaledToFit()
                    .frame(width: shelfConfig.layout == .grid ? gridCardWidth : shelfContentWidth)
            } else if shelfConfig.layout == .grid {
                gridCardContent(book, index: index, isSelected: false, coverOverride: dragCover)
                    .frame(width: gridCardWidth)
            } else {
                let scale = shelfConfig.cardScale
                rowContent(
                    book,
                    index: index,
                    isSelected: false,
                    coverWidth: (60 * scale).rounded(),
                    coverHeight: (84 * scale).rounded(),
                    coverOverride: dragCover
                )
                .frame(width: shelfContentWidth)
            }
        }
        .scaleEffect(1.05)
        .shadow(color: .black.opacity(0.22), radius: 16, y: 10)
    }

    private var gridColumns: [GridItem] {
        let count = autoColumnCount
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    /// 卡片越小列数越多：大卡 2 列，中卡 3 列，小卡 4 列。
    private var autoColumnCount: Int {
        let scale = shelfConfig.cardScale
        if scale >= 0.95 { return 2 }
        if scale >= 0.75 { return 3 }
        return 4
    }

    /// 列数越多卡片越窄，封面同步压低，避免拉成细长条。
    private var gridCoverHeight: CGFloat {
        let columns = autoColumnCount
        let columnFactor: CGFloat
        switch columns {
        case 2: columnFactor = 1
        case 3: columnFactor = 0.86
        default: columnFactor = 0.74
        }
        return (210 * shelfConfig.cardScale * columnFactor).rounded()
    }

    private var shelfContentWidth: CGFloat {
        #if os(iOS)
        let width = UIScreen.main.bounds.width
        return width > 0 ? width - 32 : 343
        #else
        return 720
        #endif
    }

    private var gridCardWidth: CGFloat {
        let columns = CGFloat(autoColumnCount)
        return ((shelfContentWidth - 12 * (columns - 1)) / columns).rounded()
    }

    private func bookshelfCard(_ book: Book, index: Int) -> some View {
        let isSelected = selectedBookIDs.contains(book.bookUrl)
        let card = Button {
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
            gridCardContent(book, index: index, isSelected: isSelected)
                .frame(height: gridCoverHeight + 126, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ShelfFrameKey.self,
                    value: [book.bookUrl: proxy.frame(in: .named("shelfSpace"))]
                )
            }
        )
        .modifier(ConditionalGesture(enabled: isOrganizing, gesture: shelfDragGesture(book)))
        .opacity(draggingBook?.bookUrl == book.bookUrl ? 0.22 : 1)
        .overlay(
            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                .stroke(theme.palette.accent, lineWidth: 1.5)
                .opacity(hoveredBookUrl == book.bookUrl ? 1 : 0)
        )
        // 整理模式下长按要直接拖书，别再弹详情菜单
        return Group {
            if isOrganizing {
                card
            } else {
                card.contextMenu {
                    bookContextMenu(book)
                }
            }
        }
    }

    private func gridCardContent(
        _ book: Book,
        index: Int,
        isSelected: Bool,
        coverOverride: Image? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let coverOverride {
                        coverOverride
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if book.coverUrl != nil {
                        BookCoverImage(
                            urlString: book.coverUrl,
                            placeholderOverride: AnyView(DefaultBookCover(book: book))
                        )
                    } else {
                        DefaultBookCover(book: book)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: gridCoverHeight)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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

    @ViewBuilder
    private func bookContextMenu(_ book: Book) -> some View {
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
        Divider()
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedBookIDs.removeAll()
                isOrganizing = true
            }
            AppLog.write("[书架] 进入整理模式（书籍菜单）")
        } label: {
            Label("整理书架", systemImage: "checklist")
        }
    }

    /// 列表模式：封面 + 书名/作者/进度一行排开，长列表更好扫。
    private func bookshelfRow(_ book: Book, index: Int) -> some View {
        let isSelected = selectedBookIDs.contains(book.bookUrl)
        let scale = shelfConfig.cardScale
        let coverWidth = (60 * scale).rounded()
        let coverHeight = (84 * scale).rounded()

        let card = Button {
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
            rowContent(book, index: index, isSelected: isSelected, coverWidth: coverWidth, coverHeight: coverHeight)
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ShelfFrameKey.self,
                    value: [book.bookUrl: proxy.frame(in: .named("shelfSpace"))]
                )
            }
        )
        .modifier(ConditionalGesture(enabled: isOrganizing, gesture: shelfDragGesture(book)))
        .opacity(draggingBook?.bookUrl == book.bookUrl ? 0.22 : 1)
        .overlay(
            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                .stroke(theme.palette.accent, lineWidth: 1.5)
                .opacity(hoveredBookUrl == book.bookUrl ? 1 : 0)
        )
        // 整理模式下长按要直接拖书，别再弹详情菜单
        return Group {
            if isOrganizing {
                card
            } else {
                card.contextMenu {
                    bookContextMenu(book)
                }
            }
        }
    }

    private var sortedBookshelf: [Book] {
        let books = bookStore.bookshelf
        let hasManualOrder = books.contains { $0.shelfOrder != nil }
        return books.sorted { b1, b2 in
            if hasManualOrder {
                let o1 = b1.shelfOrder ?? Int.max
                let o2 = b2.shelfOrder ?? Int.max
                if o1 != o2 { return o1 < o2 }
            }
            let t1 = max(b1.durChapterTime, b1.lastCheckTime)
            let t2 = max(b2.durChapterTime, b2.lastCheckTime)
            return t1 > t2
        }
    }

    /// 拖拽换位：先把当前顺序固化成序位，再交换两本的位置并整体写回。
    private func moveBook(_ sourceUrl: String, onto targetUrl: String, persist: Bool = true) {
        guard sourceUrl != targetUrl else { return }
        var ordered = sortedBookshelf
        guard let sourceIndex = ordered.firstIndex(where: { $0.bookUrl == sourceUrl }),
              let targetIndex = ordered.firstIndex(where: { $0.bookUrl == targetUrl }) else {
            return
        }
        // 插入式换位：抽走源书，落到目标位置，其余书顺移
        let moved = ordered.remove(at: sourceIndex)
        let rawInsert = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        let insertIndex = min(max(0, rawInsert), ordered.count)
        ordered.insert(moved, at: insertIndex)

        var orderByUrl: [String: Int] = [:]
        for (index, book) in ordered.enumerated() {
            orderByUrl[book.bookUrl] = index
        }
        for index in bookStore.bookshelf.indices {
            if let order = orderByUrl[bookStore.bookshelf[index].bookUrl] {
                bookStore.bookshelf[index].shelfOrder = order
            }
        }
        if persist {
            bookStore.saveBookshelf()
        }
        AppLog.write("[书架] 拖拽换位 \(sourceUrl) ↔ \(targetUrl)")
    }

    private func rowContent(
        _ book: Book,
        index: Int,
        isSelected: Bool,
        coverWidth: CGFloat,
        coverHeight: CGFloat,
        coverOverride: Image? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let coverOverride {
                    coverOverride
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if book.coverUrl != nil {
                    BookCoverImage(
                        urlString: book.coverUrl,
                        placeholderOverride: AnyView(DefaultBookCover(book: book))
                    )
                } else {
                    DefaultBookCover(book: book)
                }
            }
            .frame(width: coverWidth, height: coverHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: max(4, theme.metrics.cornerRadius - 2), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: max(4, theme.metrics.cornerRadius - 2), style: .continuous)
                    .stroke(theme.palette.divider.opacity(0.5), lineWidth: theme.metrics.borderWidth)
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(String(format: "ARCHIVE %02d", index + 1))
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.secondaryInk)
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

            Spacer(minLength: 4)

            if isOrganizing {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(isSelected ? theme.palette.accent : theme.palette.secondaryInk)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                .fill(theme.palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                .stroke(isSelected ? theme.palette.accent : theme.palette.divider.opacity(0.45),
                        lineWidth: isSelected ? 1.4 : theme.metrics.borderWidth)
        )
        .shadow(color: .black.opacity(0.03), radius: 5, y: 2)
    }

    private func resetShelfOrder() {
        for index in bookStore.bookshelf.indices {
            bookStore.bookshelf[index].shelfOrder = nil
        }
        bookStore.saveBookshelf()
    }

    /// 整理模式的跟手拖：长按后移动，卡片跟着手走。
    private func shelfDragGesture(_ book: Book) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("shelfSpace"))
            .onChanged { drag in
                if draggingBook?.bookUrl != book.bookUrl {
                    draggingBook = book
                    let cover = dragCoverImage(book)
                    dragCover = cover
                    dragSnapshot = makeDragSnapshot(book, cover: cover)
                    lastLiveTarget = nil
                }
                dragLocation = drag.location
                let target = cardFrames.first(where: {
                    $0.key != book.bookUrl && $0.value.contains(drag.location)
                })?.key
                if hoveredBookUrl != target { hoveredBookUrl = target }
                if let target, target != lastLiveTarget, book.bookUrl != target {
                    lastLiveTarget = target
                    moveBook(book.bookUrl, onto: target, persist: false)
                }
            }
            .onEnded { _ in
                if let source = draggingBook?.bookUrl,
                   let target = hoveredBookUrl,
                   source != target {
                    let from = displayedBooks.firstIndex(where: { $0.bookUrl == source }) ?? -1
                    let to = displayedBooks.firstIndex(where: { $0.bookUrl == target }) ?? -1
                    AppLog.write("[书架] 拖动排序 \(from)->\(to)")
                    moveBook(source, onto: target)
                }
                draggingBook = nil
                hoveredBookUrl = nil
                lastLiveTarget = nil
                dragCover = nil
                dragSnapshot = nil
                bookStore.saveBookshelf()
            }
    }

    private var dragSnapshotImage: Image? {
        #if canImport(UIKit)
        guard let dragSnapshot else { return nil }
        return Image(uiImage: dragSnapshot)
        #else
        return nil
        #endif
    }

    private func makeDragSnapshot(_ book: Book, cover: Image?) -> ShelfDragImage? {
        #if os(iOS)
        guard #available(iOS 16.0, *) else { return nil }
        let index = displayedBooks.firstIndex(where: { $0.bookUrl == book.bookUrl }) ?? 0
        let card: AnyView
        if shelfConfig.layout == .grid {
            card = AnyView(
                gridCardContent(book, index: index, isSelected: false, coverOverride: cover)
                    .frame(width: gridCardWidth, height: gridCoverHeight + 126)
                    .environment(\.appTheme, theme)
            )
        } else {
            let scale = shelfConfig.cardScale
            card = AnyView(
                rowContent(
                    book,
                    index: index,
                    isSelected: false,
                    coverWidth: (60 * scale).rounded(),
                    coverHeight: (84 * scale).rounded(),
                    coverOverride: cover
                )
                .frame(width: shelfContentWidth)
                .environment(\.appTheme, theme)
            )
        }
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        return renderer.uiImage
        #else
        return nil
        #endif
    }

    /// 拖拽时同步取封面：本地文件直接读，网络图走 URLCache，避免预览里封面空白。
    private func dragCoverImage(_ book: Book) -> Image? {
        guard let raw = book.coverUrl, !raw.isEmpty else { return nil }
        #if os(iOS)
        let path: String?
        if raw.hasPrefix("/") {
            path = raw
        } else if raw.hasPrefix("file://"), let url = URL(string: raw) {
            path = url.path
        } else {
            path = nil
        }
        if let path, let image = UIImage(contentsOfFile: path) {
            return Image(uiImage: image)
        }
        if let url = URL(string: raw),
           let cached = URLCache.shared.cachedResponse(for: URLRequest(url: url)),
           let image = UIImage(data: cached.data) {
            return Image(uiImage: image)
        }
        return nil
        #else
        return nil
        #endif
    }

    /// 验收用：`JUYUE_OPEN_BOOK=<序号 或 书名片段>` 启动后直接翻开一本书，
    /// 省掉「书架里手点封面」这一步。只活在 Debug / 模拟器里。
    /// 验收用：`JUYUE_IMPORT_TXT=<容器里的绝对路径>` 启动时先导一本本地书，
    /// 省得每次手点「+」。只在 DEBUG / 模拟器里生效。
    private func importDebugBookIfRequested() {
        #if DEBUG || targetEnvironment(simulator)
        guard let path = ProcessInfo.processInfo.environment["JUYUE_IMPORT_TXT"], !path.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            AppLog.write("[调试] 导入文件不存在：\(path)")
            return
        }
        do {
            let book = try bookStore.importFile(from: URL(fileURLWithPath: path))
            AppLog.write("[调试] 本地导入成功《\(book.name)》\(book.totalChapterNum) 章")
        } catch {
            AppLog.write("[调试] 本地导入失败 \(error.localizedDescription)")
        }
        #endif
    }

    private func openDebugBookIfRequested() {
        #if DEBUG || targetEnvironment(simulator)
        guard selectedBook == nil else { return }
        guard let needle = ProcessInfo.processInfo.environment["JUYUE_OPEN_BOOK"],
              !needle.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let pool = bookStore.bookshelf
            guard !pool.isEmpty else {
                AppLog.write("[调试] 书架为空，JUYUE_OPEN_BOOK 没处落")
                return
            }
            if let index = Int(needle), pool.indices.contains(index) {
                AppLog.write("[调试] 直接翻开第 \(index) 本 \(pool[index].name)")
                selectedBook = pool[index]
                return
            }
            if let hit = pool.first(where: { $0.name.contains(needle) || $0.bookUrl.contains(needle) }) {
                AppLog.write("[调试] 直接翻开《\(hit.name)》")
                selectedBook = hit
            } else {
                AppLog.write("[调试] JUYUE_OPEN_BOOK 没匹配到：\(needle)")
            }
        }
        #endif
    }

    public var body: some View {
        ZStack {
            NavigationView {
            VStack(spacing: 0) {
                shelfTitleLockup
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
            .onChange(of: isOrganizing) { on in
                if !on {
                    draggingBook = nil
                    hoveredBookUrl = nil
                    lastLiveTarget = nil
                    dragCover = nil
                    dragSnapshot = nil
                }
            }
            .onAppear {
                importDebugBookIfRequested()
                openDebugBookIfRequested()
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
                Text("会删掉 \(selectedBookIDs.count) 本书，阅读进度和缓存也会一起删。")
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarHidden(true)
            #endif
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
            .sheet(isPresented: $showShelfSizeSheet) {
                if #available(iOS 16.4, macOS 13.3, *) {
                    shelfSizeSheet
                        .presentationDetents([.height(190)])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.clear)
                } else if #available(iOS 16.0, macOS 13.0, *) {
                    shelfSizeSheet
                        .presentationDetents([.height(190)])
                        .presentationDragIndicator(.visible)
                } else {
                    shelfSizeSheet
                }
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
            if source == nil, book.origin != "local",
               !book.bookUrl.hasPrefix("file://"), !book.bookUrl.hasPrefix("epub://"),
               !book.bookUrl.hasPrefix("txt://") {
                MissingBookSourceView(book: book) {
                    selectedBook = nil
                }
            } else if let source, source.kind != .text {
                let cached = bookStore.getChapters(for: book.bookUrl)
                let chapters = cached.isEmpty
                    ? [BookChapter(
                        bookUrl: book.bookUrl,
                        url: book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl,
                        title: book.name,
                        index: 0
                    )]
                    : cached
                MediaBookReaderView(
                    book: book,
                    source: source,
                    chapters: chapters,
                    initialChapterIndex: book.durChapterIndex
                ) {
                    selectedBook = nil
                }
            } else {
                ReaderView(book: book, source: source, onDismiss: {
                    selectedBook = nil
                })
            }
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

/// 商店版的标题标记：角标框 + 一只简笔猫 + 一道强调线，全部 Canvas 绘制，
/// 不含第三方角色美术。侧载版仍走 `ShelfMark` 图，分叉只在 `AppEdition` 上。
struct ShelfEditionMark: View {
    let ink: Color
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let line = max(1, height * 0.035)
            let stroke = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)

            // 角标框：左上与右下两个直角，跟其它页头的视觉语言一致
            var frame = Path()
            frame.move(to: CGPoint(x: 0, y: height * 0.5))
            frame.addLine(to: CGPoint(x: 0, y: 0))
            frame.addLine(to: CGPoint(x: width * 0.34, y: 0))
            frame.move(to: CGPoint(x: width, y: height * 0.5))
            frame.addLine(to: CGPoint(x: width, y: height))
            frame.addLine(to: CGPoint(x: width * 0.66, y: height))
            context.stroke(frame, with: .color(ink.opacity(0.8)), lineWidth: line)

            // 猫头：一条闭合路径把两只耳朵一起勾出来，耳尖压在头顶两侧
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: width * x, y: height * y)
            }
            var head = Path()
            head.move(to: point(0.255, 0.150))
            head.addLine(to: point(0.400, 0.335))
            head.addLine(to: point(0.600, 0.315))
            head.addLine(to: point(0.745, 0.135))
            head.addQuadCurve(to: point(0.755, 0.520), control: point(0.790, 0.320))
            head.addQuadCurve(to: point(0.500, 0.745), control: point(0.750, 0.700))
            head.addQuadCurve(to: point(0.245, 0.520), control: point(0.250, 0.700))
            head.addQuadCurve(to: point(0.255, 0.150), control: point(0.210, 0.320))
            head.closeSubpath()
            context.stroke(head, with: .color(ink.opacity(0.92)), style: stroke)

            // 眼睛两个点，别画表情，留白就够
            let eyesAt: [CGFloat] = [0.395, 0.605]
            for x in eyesAt {
                let r = max(1.2, width * 0.022)
                let eye = Path(ellipseIn: CGRect(
                    x: width * x - r, y: height * 0.500 - r, width: r * 2, height: r * 2
                ))
                context.fill(eye, with: .color(ink.opacity(0.92)))
            }

            // 胡须：左右各两根，短、等长，别伸到角标框外面
            var whiskers = Path()
            whiskers.move(to: point(0.300, 0.590)); whiskers.addLine(to: point(0.155, 0.560))
            whiskers.move(to: point(0.300, 0.635)); whiskers.addLine(to: point(0.150, 0.660))
            whiskers.move(to: point(0.700, 0.590)); whiskers.addLine(to: point(0.845, 0.560))
            whiskers.move(to: point(0.700, 0.635)); whiskers.addLine(to: point(0.850, 0.660))
            context.stroke(whiskers, with: .color(ink.opacity(0.55)), lineWidth: max(1, line * 0.7))

            // 身体只留一道肩线，尾巴绕到右下，收在角标框里
            var body = Path()
            body.move(to: point(0.330, 0.880))
            body.addQuadCurve(to: point(0.670, 0.880), control: point(0.500, 0.780))
            body.move(to: point(0.660, 0.880))
            body.addQuadCurve(to: point(0.845, 0.800), control: point(0.800, 0.885))
            body.addQuadCurve(to: point(0.790, 0.735), control: point(0.865, 0.740))
            context.stroke(body, with: .color(ink.opacity(0.75)), style: stroke)

            // 强调线：跟原来同位置，别动
            context.fill(
                Path(CGRect(x: width * 0.78, y: height * 0.12, width: width * 0.16, height: line)),
                with: .color(accent)
            )
        }
        .aspectRatio(1.24, contentMode: .fit)
    }
}
