import SwiftUI

enum AppThemeChoice: String, CaseIterable, Identifiable {
    case standard
    case lunarTerminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "标准"
        case .lunarTerminal: return "月面终端"
        }
    }

    var subtitle: String {
        switch self {
        case .standard: return "跟随系统外观"
        case .lunarTerminal: return "暖纸、墨色与氧化红"
        }
    }
}

struct AppThemePalette {
    var background: Color
    var surface: Color
    var elevated: Color
    var ink: Color
    var secondaryInk: Color
    var divider: Color
    var accent: Color
    var danger: Color
    var success: Color
    var warning: Color
    var onAccent: Color
}

struct AppThemeTypography {
    var title: Font
    var body: Font
    var label: Font
    var mono: Font
    var symbol: Font
    var readerBody: Font
}

struct AppThemeMetrics {
    var cornerRadius: CGFloat
    var borderWidth: CGFloat
    var gridSpacing: CGFloat
    var tileHeight: CGFloat
}

struct AppThemeTokens {
    var choice: AppThemeChoice
    var palette: AppThemePalette
    var typography: AppThemeTypography
    var metrics: AppThemeMetrics
    var showsGrid: Bool
    var gridOpacity: Double
    var forcedColorScheme: ColorScheme?

    static let standard = AppThemeTokens(
        choice: .standard,
        palette: AppThemePalette(
            background: systemGroupedBackground,
            surface: secondarySystemGroupedBackground,
            elevated: Color.primary.opacity(0.04),
            ink: .primary,
            secondaryInk: .secondary,
            divider: Color.primary.opacity(0.12),
            accent: .accentColor,
            danger: .red,
            success: .green,
            warning: .orange,
            onAccent: .white
        ),
        typography: AppThemeTypography(
            title: .system(size: 26, weight: .bold),
            body: .system(size: 15),
            label: .system(size: 11, weight: .semibold),
            mono: .system(size: 12, design: .monospaced),
            symbol: .system(size: 16, weight: .medium),
            readerBody: .system(size: 17)
        ),
        metrics: AppThemeMetrics(cornerRadius: 14, borderWidth: 1, gridSpacing: 28, tileHeight: 146),
        showsGrid: false,
        gridOpacity: 0,
        forcedColorScheme: nil
    )

    static let lunarTerminal = AppThemeTokens(
        choice: .lunarTerminal,
        palette: AppThemePalette(
            background: Color(red: 0.851, green: 0.831, blue: 0.765),
            surface: Color(red: 0.906, green: 0.882, blue: 0.820),
            elevated: Color(red: 0.945, green: 0.925, blue: 0.871),
            ink: Color(red: 0.090, green: 0.090, blue: 0.082),
            secondaryInk: Color(red: 0.435, green: 0.416, blue: 0.369),
            divider: Color(red: 0.604, green: 0.580, blue: 0.522),
            accent: Color(red: 0.702, green: 0.227, blue: 0.169),
            danger: Color(red: 0.702, green: 0.227, blue: 0.169),
            success: Color(red: 0.247, green: 0.408, blue: 0.267),
            warning: Color(red: 0.553, green: 0.373, blue: 0.153),
            onAccent: Color(red: 0.965, green: 0.945, blue: 0.894)
        ),
        typography: AppThemeTypography(
            title: .system(size: 25, weight: .bold),
            body: .system(size: 15),
            label: .system(size: 11, weight: .semibold, design: .monospaced),
            mono: .system(size: 12, design: .monospaced),
            symbol: .system(size: 16, weight: .regular),
            readerBody: .custom("Songti SC", size: 18)
        ),
        metrics: AppThemeMetrics(cornerRadius: 2, borderWidth: 1, gridSpacing: 28, tileHeight: 146),
        showsGrid: true,
        gridOpacity: 0.09,
        forcedColorScheme: .light
    )

    private static var systemGroupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private static var secondarySystemGroupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

final class AppThemeManager: ObservableObject {
    static let shared = AppThemeManager()

    @Published var choice: AppThemeChoice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: Self.key) }
    }

    private static let key = "app_theme_choice_v1"

    var theme: AppThemeTokens {
        switch choice {
        case .standard: return .standard
        case .lunarTerminal: return .lunarTerminal
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.key)
        choice = AppThemeChoice(rawValue: stored ?? "") ?? .standard
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppThemeTokens.standard
}

extension EnvironmentValues {
    var appTheme: AppThemeTokens {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

private struct AppThemedListModifier: ViewModifier {
    @Environment(\.appTheme) private var theme

    @ViewBuilder
    private func styledContent(_ content: Content) -> some View {
        if theme.showsGrid {
            content.listStyle(.plain)
        } else {
            content
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            styledContent(content)
                .scrollContentBackground(.hidden)
                .listRowBackground(theme.palette.surface)
                .background(AppThemeBackdrop())
                .appThemedPage()
        } else {
            styledContent(content)
                .listRowBackground(theme.palette.surface)
                .background(AppThemeBackdrop())
                .appThemedPage()
        }
    }
}

extension View {
    func appThemedList() -> some View {
        modifier(AppThemedListModifier())
    }

    func appThemedRows() -> some View {
        modifier(AppThemedRowsModifier())
    }

    func appThemedPage() -> some View {
        modifier(AppThemedPageModifier())
    }
}

private struct AppThemedRowsModifier: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content.listRowBackground(theme.palette.surface)
    }
}

private struct AppThemedPageModifier: ViewModifier {
    @Environment(\.appTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            #if os(iOS)
            content
                .tint(theme.palette.accent)
                .toolbarBackground(theme.palette.surface, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
            #else
            content
                .tint(theme.palette.accent)
            #endif
        } else {
            content
                .tint(theme.palette.accent)
        }
    }
}

struct AppThemeBackdrop: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                theme.palette.background
                LinearGradient(
                    colors: [
                        theme.palette.elevated.opacity(0.55),
                        theme.palette.background,
                        theme.palette.background.opacity(0.94)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [theme.palette.elevated.opacity(0.55), .clear],
                    center: .topTrailing,
                    startRadius: 10,
                    endRadius: 320
                )
                RadialGradient(
                    colors: [theme.palette.ink.opacity(0.035), .clear],
                    center: .bottomLeading,
                    startRadius: 20,
                    endRadius: 420
                )

                if theme.showsGrid {
                    Canvas { context, size in
                        var grid = Path()
                        for x in stride(from: 0.0, through: size.width, by: theme.metrics.gridSpacing) {
                            grid.move(to: CGPoint(x: x, y: 0))
                            grid.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        for y in stride(from: 0.0, through: size.height, by: theme.metrics.gridSpacing) {
                            grid.move(to: CGPoint(x: 0, y: y))
                            grid.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        context.stroke(grid, with: .color(theme.palette.ink.opacity(theme.gridOpacity)), lineWidth: 0.5)

                        var scanlines = Path()
                        for y in stride(from: 0.0, through: size.height, by: 4.0) {
                            scanlines.move(to: CGPoint(x: 0, y: y))
                            scanlines.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        context.stroke(scanlines, with: .color(theme.palette.ink.opacity(0.018)), lineWidth: 0.5)

                        var corners = Path()
                        let inset: CGFloat = 14
                        let arm: CGFloat = 26
                        corners.move(to: CGPoint(x: inset, y: inset + arm))
                        corners.addLine(to: CGPoint(x: inset, y: inset))
                        corners.addLine(to: CGPoint(x: inset + arm, y: inset))
                        corners.move(to: CGPoint(x: size.width - inset - arm, y: inset))
                        corners.addLine(to: CGPoint(x: size.width - inset, y: inset))
                        corners.addLine(to: CGPoint(x: size.width - inset, y: inset + arm))
                        corners.move(to: CGPoint(x: inset, y: size.height - inset - arm))
                        corners.addLine(to: CGPoint(x: inset, y: size.height - inset))
                        corners.addLine(to: CGPoint(x: inset + arm, y: size.height - inset))
                        corners.move(to: CGPoint(x: size.width - inset - arm, y: size.height - inset))
                        corners.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset))
                        corners.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset - arm))
                        context.stroke(corners, with: .color(theme.palette.ink.opacity(0.16)), lineWidth: 0.8)

                        var ticks = Path()
                        let tickY = size.height - 34
                        for index in 0..<14 {
                            let height = CGFloat((index % 5) + 1) * 2.2
                            let x = size.width - 34 - CGFloat(index) * 4
                            ticks.addRect(CGRect(x: x, y: tickY - height, width: 2, height: height))
                        }
                        context.fill(ticks, with: .color(theme.palette.ink.opacity(0.08)))
                    }

                    Text("TERMINAL / READER")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(3)
                        .foregroundColor(theme.palette.ink.opacity(0.055))
                        .rotationEffect(.degrees(-90))
                        .position(x: geo.size.width - 9, y: geo.size.height * 0.52)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

struct TerminalPageHeader: View {
    @Environment(\.appTheme) private var theme

    let code: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(code)
                    .font(theme.typography.label)
                Spacer()
                Text("MODULE")
                    .font(theme.typography.mono)
            }
            .foregroundColor(theme.palette.secondaryInk)

            Text(title)
                .font(theme.typography.title)
                .foregroundColor(theme.palette.ink)

            Text(detail)
                .font(theme.typography.mono)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.palette.accent)
                .frame(width: 3)
        }
        .overlay {
            Rectangle()
                .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
        }
    }
}

struct TerminalInfoRow: View {
    @Environment(\.appTheme) private var theme

    let symbol: String
    let title: String
    var detail: String? = nil
    var value: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(theme.typography.symbol)
                .foregroundColor(theme.palette.accent)
                .frame(width: 28, height: 28)
                .background(theme.palette.accent.opacity(0.10))
                .overlay(
                    Rectangle()
                        .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.typography.body)
                    .foregroundColor(theme.palette.ink)
                if let detail {
                    Text(detail)
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.secondaryInk)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .font(theme.typography.mono)
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

struct TerminalStatusPill: View {
    @Environment(\.appTheme) private var theme

    let text: String
    var color: Color? = nil

    var body: some View {
        Text(text)
            .font(theme.typography.mono)
            .foregroundColor(color ?? theme.palette.secondaryInk)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((color ?? theme.palette.secondaryInk).opacity(0.10))
            .overlay(
                Rectangle()
                    .stroke((color ?? theme.palette.divider).opacity(0.7),
                            lineWidth: theme.metrics.borderWidth)
            )
    }
}

struct TerminalMetricCard: View {
    @Environment(\.appTheme) private var theme

    let label: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(theme.typography.label)
                    .foregroundColor(theme.palette.secondaryInk)
                Spacer()
                Image(systemName: symbol)
                    .font(theme.typography.symbol)
                    .foregroundColor(theme.palette.accent)
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(theme.palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous))
    }
}

struct TerminalActionTile: View {
    @Environment(\.appTheme) private var theme

    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: symbol)
                    .font(theme.typography.symbol)
                    .foregroundColor(theme.palette.accent)
                Text(title)
                    .font(theme.typography.body.weight(.semibold))
                    .foregroundColor(theme.palette.ink)
                Text(detail)
                    .font(theme.typography.mono)
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(theme.palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                    .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

public enum ReaderTheme: String, CaseIterable, Identifiable {
    case white = "默认白"
    case parchment = "复古羊皮纸"
    case eyeCare = "护眼绿"
    case dark = "夜间暗黑"

    public var id: String { rawValue }

    public var backgroundColor: Color {
        switch self {
        case .white: return Color(red: 0.98, green: 0.98, blue: 0.98)
        case .parchment: return Color(red: 0.95, green: 0.90, blue: 0.82)
        // 取自安卓阅读器护眼绿的实测值
        case .eyeCare: return Color(red: 188.0 / 255.0, green: 200.0 / 255.0, blue: 150.0 / 255.0)
        case .dark: return Color(red: 0.12, green: 0.12, blue: 0.12)
        }
    }

    public var textColor: Color {
        switch self {
        case .white: return Color(red: 0.15, green: 0.15, blue: 0.15)
        case .parchment: return Color(red: 0.22, green: 0.18, blue: 0.15)
        // 两张安卓截图取样一致：背景 rgb(188,200,150)、正文 rgb(68,77,43)
        case .eyeCare: return Color(red: 68.0 / 255.0, green: 77.0 / 255.0, blue: 43.0 / 255.0)
        case .dark: return Color(red: 0.80, green: 0.80, blue: 0.80)
        }
    }
}

public enum PageMode: String, CaseIterable, Identifiable {
    case scroll = "连续滚动"
    case pageByPage = "左右翻页"
    case cover = "覆盖翻页"
    case slide = "滑动翻页"
    case simulation = "仿真翻页"
    case none = "无动画"

    public var id: String { rawValue }

    /// 按页翻的模式（左右、仿真）共用分页逻辑。
    public var isPaged: Bool { self != .scroll }
}

/// 正文字重档位
public enum ReaderWeight: String, CaseIterable, Identifiable {
    case light = "细"
    case regular = "中"
    case bold = "粗"

    public var id: String { rawValue }

    public var level: Int {
        switch self {
        case .light: return 0
        case .regular: return 1
        case .bold: return 2
        }
    }

    public static func from(level: Int) -> ReaderWeight {
        switch level {
        case 0: return .light
        case 2: return .bold
        default: return .regular
        }
    }
}

/// 简繁转换
public enum ChineseConversion: String, CaseIterable, Identifiable {
    case none = "原文"
    case simplified = "转简体"
    case traditional = "转繁体"

    public var id: String { rawValue }

    var transform: StringTransform? {
        switch self {
        case .none: return nil
        case .simplified: return StringTransform("Traditional-Simplified")
        case .traditional: return StringTransform("Simplified-Traditional")
        }
    }

    public func apply(_ text: String) -> String {
        guard let transform else { return text }
        return text.applyingTransform(transform, reverse: false) ?? text
    }
}

/// 阅读器设置卡片的三个面板
/// （quick / spacing / tts）。原来所有设置堆成一长条，滑半天找不到东西。
public enum ReaderQuickPanel: String, CaseIterable, Identifiable {
    case quick = "快捷"
    case spacing = "排版"
    case tts = "朗读"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .quick: return "slider.horizontal.3"
        case .spacing: return "text.alignleft"
        case .tts: return "speaker.wave.2"
        }
    }
}

public extension ReaderTheme {
    /// 每套主题一个强调色，设置面板的滑块、选中态都用它，
    /// 免得所有控件都是同一个灰。
    var accentColor: Color {
        switch self {
        case .white: return Color(red: 0.18, green: 0.44, blue: 0.84)
        case .parchment: return Color(red: 0.72, green: 0.47, blue: 0.20)
        case .eyeCare: return Color(red: 0.30, green: 0.50, blue: 0.24)
        case .dark: return Color(red: 0.56, green: 0.73, blue: 0.96)
        }
    }
}

/// 页眉页脚每栏能填什么。
///
/// 页眉页脚每栏可填的条目；前 6 个的 rawValue 是已存配置的键，不要改，
/// 免得老用户的已存配置解不出来。
public enum ReaderBarContent: String, CaseIterable, Identifiable {
    case none = "无"
    case bookName = "书名"
    case chapterTitle = "标题"
    case shortChapterTitle = "短标题"
    case progress = "进度(%)"
    case pageInfo = "页码"
    case pagePercent = "页进度"
    case pageNumberLabel = "第 N 页"
    case bookPercent = "总进度"
    case bookPercentBar = "总进度条"
    case time = "时间"
    case clockWithSeconds = "时间(秒)"
    case date = "日期"
    case weekday = "星期"
    case userDate = "自定义日期"
    case batteryLevel = "电量(%)"
    case batteryIcon = "电量图标"
    case batteryGlyphWithPercent = "图标+电量"
    case batteryBar = "电量条"
    case chapterCount = "共 N 章"
    case chaptersShort = "N 章"
    case elapsedReadingTime = "阅读时长"
    case remainingReadingTime = "剩余时间"
    case userText = "自定义"

    public var id: String { rawValue }

    /// 电量与进度条这类要画图形，不能只当文本塞进 HStack
    public var isGraphical: Bool {
        switch self {
        case .batteryIcon, .batteryGlyphWithPercent, .batteryBar, .bookPercentBar:
            return true
        default:
            return false
        }
    }
}

/// 每页顶部那行章节标题怎么放
public enum ReaderTitleAlignment: String, CaseIterable, Identifiable {
    case leading = "靠左"
    case center = "居中"
    case hidden = "隐藏"

    public var id: String { rawValue }
}

/// 正文对齐方式，默认两端对齐。
public enum ReaderTextAlignment: String, CaseIterable, Identifiable {
    case justify = "两端"
    case leading = "靠左"
    case center = "居中"
    case trailing = "靠右"

    public var id: String { rawValue }

    /// 只有两端对齐要额外做二次分配，其余交给 Text 自己排。
    public var isJustify: Bool { self == .justify }
}

/// 下划线线型。
public enum ReaderUnderlinePattern: String, CaseIterable, Identifiable {
    case solid = "实线"
    case dot = "点线"
    case dash = "虚线"
    case dashDot = "点划线"

    public var id: String { rawValue }

    /// `Text.LineStyle` 要 iOS 16 / macOS 13 才有，低版本走不带线型的分支
    @available(iOS 16.0, macOS 13.0, *)
    public var lineStyle: Text.LineStyle.Pattern {
        switch self {
        case .solid: return .solid
        case .dot: return .dot
        case .dash: return .dash
        case .dashDot: return .dashDot
        }
    }
}

public class ReaderConfig: ObservableObject {
    public static let shared = ReaderConfig()

    private static let defaults = UserDefaults.standard

    // MARK: - 字号与行距
    @Published public var fontSize: CGFloat = 18.0 { didSet { persist(fontSize, "reader_font_size") } }
    @Published public var lineSpacing: CGFloat = 8.0 { didSet { persist(lineSpacing, "reader_line_spacing") } }
    /// 阅读页「下载缓存」一次往后缓存多少章
    @Published public var cachedChapterCount: Int = 20 {
        didSet { Self.defaults.set(cachedChapterCount, forKey: "reader_cached_chapters") }
    }

    // MARK: - 排版
    /// 字间距
    @Published public var letterSpacing: CGFloat = 0.5 { didSet { persist(letterSpacing, "reader_letter_spacing") } }
    /// 段间距
    @Published public var paragraphSpacing: CGFloat = 12.0 { didSet { persist(paragraphSpacing, "reader_paragraph_spacing") } }
    /// 左右页边距
    @Published public var horizontalPadding: CGFloat = 24.0 { didSet { persist(horizontalPadding, "reader_horizontal_padding") } }
    /// 上下左右分开调（旧的两个键只用来做一次性迁移）
    @Published public var paddingTop: CGFloat = 24.0 { didSet { persist(paddingTop, "reader_padding_top") } }
    @Published public var paddingBottom: CGFloat = 24.0 { didSet { persist(paddingBottom, "reader_padding_bottom") } }
    @Published public var paddingLeft: CGFloat = 24.0 { didSet { persist(paddingLeft, "reader_padding_left") } }
    @Published public var paddingRight: CGFloat = 24.0 { didSet { persist(paddingRight, "reader_padding_right") } }
    /// 页眉/页脚离屏幕边缘的距离
    @Published public var headerOffset: CGFloat = 0.0 { didSet { persist(headerOffset, "reader_header_offset") } }
    @Published public var footerOffset: CGFloat = 0.0 { didSet { persist(footerOffset, "reader_footer_offset") } }

    /// 页眉那一行离屏幕上沿的实际距离，0 = 贴屏幕上沿（顶到灵动岛那条上面）
    public var headerGap: CGFloat { max(0, headerOffset) }
    /// 页脚那一行离屏幕下沿的实际距离，0 = 贴屏幕下沿
    public var footerGap: CGFloat { max(0, footerOffset) }

    /// 页末匀空白：一页排不满时，把剩下的高度匀进段间距，正文看起来铺满整页。
    /// 关掉之后页末留白全堆在底部，段间距就是你设的那个值。
    @Published public var justifyLastPage: Bool = true {
        didSet { Self.defaults.set(justifyLastPage, forKey: "reader_justify_last_page") }
    }

    /// 阅读设置面板的不透明度：调布局时把它调低，能看见被面板挡住的正文变化。
    @Published public var panelOpacity: Double = 0.92 {
        didSet { Self.defaults.set(panelOpacity, forKey: "reader_panel_opacity") }
    }

    /// 面板是两层底色叠出来的，想得到总不透明度 v，每层得用 1-√(1-v)。
    public var panelLayerOpacity: Double {
        let v = max(0.0, min(1.0, panelOpacity))
        return 1 - (1 - v).squareRoot()
    }
    /// 阅读页亮度：1 = 原始，越小越暗（盖一层黑，不去动系统亮度）
    @Published public var brightness: Double = 1.0 { didSet { Self.defaults.set(brightness, forKey: "reader_brightness") } }
    /// 自动夜间：22:00–07:00 用暗黑主题，白天回到原来的主题
    @Published public var autoNight: Bool = false { didSet { Self.defaults.set(autoNight, forKey: "reader_auto_night") } }
    /// 上下边距
    @Published public var verticalPadding: CGFloat = 24.0 { didSet { persist(verticalPadding, "reader_vertical_padding") } }
    /// 首行缩进，按字数算
    @Published public var firstLineIndent: CGFloat = 0 { didSet { persist(firstLineIndent, "reader_first_line_indent") } }
    /// 正文加粗
    @Published public var boldText: Bool = false { didSet { Self.defaults.set(boldText, forKey: "reader_bold_text") } }
    /// 正文字体（PostScript 名）
    @Published public var fontName: String = ReaderFont.default.postScriptName {
        didSet { Self.defaults.set(fontName, forKey: "reader_font_name") }
    }
    /// 字重档位：细 / 中 / 粗
    @Published public var weightLevel: Int = 1 {
        didSet { Self.defaults.set(weightLevel, forKey: "reader_weight_level") }
    }
    /// 简繁转换
    @Published public var chineseConversion: ChineseConversion = .none {
        didSet { Self.defaults.set(chineseConversion.rawValue, forKey: "reader_chinese_conversion") }
    }

    public var weight: ReaderWeight {
        get { ReaderWeight.from(level: weightLevel) }
        set { weightLevel = newValue.level }
    }

    // MARK: - 正文对齐与段落
    /// 正文对齐，默认两端对齐
    @Published public var textAlignment: ReaderTextAlignment = .justify {
        didSet { Self.defaults.set(textAlignment.rawValue, forKey: "reader_text_alignment") }
    }
    /// 段落之间的分隔线数量，0 表示不加
    @Published public var paragraphSeparatorLines: Int = 0 {
        didSet { Self.defaults.set(paragraphSeparatorLines, forKey: "reader_paragraph_separator_lines") }
    }
    /// 段落分隔线的颜色，空字符串表示跟随正文色
    @Published public var paragraphSeparatorColorHex: String = "" {
        didSet { Self.defaults.set(paragraphSeparatorColorHex, forKey: "reader_paragraph_separator_hex") }
    }

    // MARK: - 正文下划线
    @Published public var underlineEnabled: Bool = false {
        didSet { Self.defaults.set(underlineEnabled, forKey: "reader_underline_enabled") }
    }
    @Published public var underlinePattern: ReaderUnderlinePattern = .solid {
        didSet { Self.defaults.set(underlinePattern.rawValue, forKey: "reader_underline_pattern") }
    }
    /// 空字符串表示跟随正文色
    @Published public var underlineColorHex: String = "" {
        didSet { Self.defaults.set(underlineColorHex, forKey: "reader_underline_hex") }
    }

    public var underlineColor: Color? {
        underlineColorHex.isEmpty ? nil : Color(hex: underlineColorHex)
    }

    public var paragraphSeparatorColor: Color {
        Color(hex: paragraphSeparatorColorHex) ?? textColor.opacity(0.18)
    }

    // MARK: - 章节标题
    /// 标题字号 = 正文字号 × 该系数，默认 1.18
    @Published public var chapterTitleScale: CGFloat = 1.18 {
        didSet { persist(chapterTitleScale, "reader_chapter_title_scale") }
    }
    /// 标题到正文的距离
    @Published public var chapterTitleSpacing: CGFloat = 28.0 {
        didSet { persist(chapterTitleSpacing, "reader_chapter_title_spacing") }
    }
    /// 上一章尾部到下一章标题的距离
    @Published public var chapterTopSpacing: CGFloat = 18.0 {
        didSet { persist(chapterTopSpacing, "reader_chapter_top_spacing") }
    }
    /// 章节正文底部留白
    @Published public var chapterBottomSpacing: CGFloat = 36.0 {
        didSet { persist(chapterBottomSpacing, "reader_chapter_bottom_spacing") }
    }

    // MARK: - 章节标题设计器产物（设计器导出的 JSON）
    /// 设计器工程 JSON，下次打开设计器回灌用
    @Published public var chapterTitleProjectJSON: String = "" {
        didSet { Self.defaults.set(chapterTitleProjectJSON, forKey: "reader_title_designer_project") }
    }
    /// 渲染用 HTML 片段（`<style>…</style>` + HTML）
    @Published public var chapterTitleHTMLTemplate: String = "" {
        didSet { Self.defaults.set(chapterTitleHTMLTemplate, forKey: "reader_title_designer_html") }
    }
    /// 设计画布高度，渲染时按这个比例缩放
    @Published public var chapterTitleCanvasHeight: Double = 0 {
        didSet { Self.defaults.set(chapterTitleCanvasHeight, forKey: "reader_title_designer_height") }
    }
    /// 有没有已经设计好的标题
    public var hasDesignedChapterTitle: Bool { !chapterTitleHTMLTemplate.isEmpty }

    /// 设计器要按当前配色切明暗主题
    public var isDarkAppearance: Bool {
        theme == .dark
    }

    // MARK: - 阅读背景图
    @Published public var backgroundImageEnabled: Bool = false {
        didSet { Self.defaults.set(backgroundImageEnabled, forKey: "reader_bg_image_enabled") }
    }
    /// 背景图绝对路径。用路径而不是资源名，才能用相册或文件里选的图
    @Published public var backgroundImagePath: String = "" {
        didSet { Self.defaults.set(backgroundImagePath, forKey: "reader_bg_image_path") }
    }

    // MARK: - 页眉页脚内容参数
    /// 「短标题」留几个字
    @Published public var shortTitleLength: Int = 6 {
        didSet { Self.defaults.set(shortTitleLength, forKey: "reader_short_title_length") }
    }
    /// 「自定义日期」的格式串
    @Published public var customDatePattern: String = "M月d日" {
        didSet { Self.defaults.set(customDatePattern, forKey: "reader_custom_date_pattern") }
    }
    /// 「自定义」栏文字
    @Published public var customBarText: String = "" {
        didSet { Self.defaults.set(customBarText, forKey: "reader_custom_bar_text") }
    }

    // MARK: - 页眉页脚
    @Published public var titleAlignment: ReaderTitleAlignment = .leading {
        didSet { Self.defaults.set(titleAlignment.rawValue, forKey: "reader_title_alignment") }
    }
    @Published public var headerEnabled: Bool = false {
        didSet { Self.defaults.set(headerEnabled, forKey: "reader_header_enabled") }
    }
    /// 一栏能塞几个组件就塞几个，顺序就是显示顺序；空数组等于这一栏不画。
    @Published public var headerLeft: [ReaderBarContent] = [.bookName] {
        didSet { Self.persistBar(headerLeft, key: "reader_header_left") }
    }
    @Published public var headerCenter: [ReaderBarContent] = [] {
        didSet { Self.persistBar(headerCenter, key: "reader_header_center") }
    }
    @Published public var headerRight: [ReaderBarContent] = [.progress] {
        didSet { Self.persistBar(headerRight, key: "reader_header_right") }
    }
    @Published public var footerEnabled: Bool = true {
        didSet { Self.defaults.set(footerEnabled, forKey: "reader_footer_enabled") }
    }
    @Published public var footerLeft: [ReaderBarContent] = [.chapterTitle] {
        didSet { Self.persistBar(footerLeft, key: "reader_footer_left") }
    }
    @Published public var footerCenter: [ReaderBarContent] = [] {
        didSet { Self.persistBar(footerCenter, key: "reader_footer_center") }
    }
    @Published public var footerRight: [ReaderBarContent] = [.pageInfo] {
        didSet { Self.persistBar(footerRight, key: "reader_footer_right") }
    }

    /// 一栏多个组件用逗号拼着存；老的「单个值」也在这条路径上解出来。
    private static func persistBar(_ items: [ReaderBarContent], key: String) {
        defaults.set(items.map { $0.rawValue }.joined(separator: ","), forKey: key)
    }

    private static func loadBar(_ key: String, fallback: [ReaderBarContent]) -> [ReaderBarContent] {
        guard let raw = defaults.string(forKey: key) else { return fallback }
        let parts = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let parsed = parts.compactMap { ReaderBarContent(rawValue: $0) }.filter { $0 != .none }
        return parsed
    }
    /// 页眉页脚和正文之间的分隔线：按用户要求默认关掉（同色背景下那条线显得多余），
    /// 想要的人可以在排版设置里打开「显示分隔线」
    @Published public var barDivider: Bool = false {
        didSet { Self.defaults.set(barDivider, forKey: "reader_bar_divider") }
    }

    /// 智能分段：有些书源把整章塞成一行，没有空行就分不出段落，
    /// 开着重排时按句末标点把它切成正常段落。已经分好段的正文不受影响
    @Published public var smartParagraphs: Bool = true {
        didSet { Self.defaults.set(smartParagraphs, forKey: "reader_smart_paragraphs") }
    }

    /// 标点禁则：行首不出现句读/收尾类标点，行尾不出现开引号、开括号。
    /// 按页翻走 CoreText 断行，连续模式走 TextKit 的 word joiner，两套都听这个开关
    @Published public var punctuationKinsoku: Bool = true {
        didSet { Self.defaults.set(punctuationKinsoku, forKey: "reader_punctuation_kinsoku") }
    }

    /// 共享布局：开着就是所有书共用一套排版；关掉后每本书各存一份。
    @Published public var sharedLayout: Bool = true {
        didSet { Self.defaults.set(sharedLayout, forKey: "reader_shared_layout") }
    }

    /// 与书无关的排版快照，用于按书存取
    public struct LayoutSnapshot: Codable, Equatable {
        public var fontSize: Double
        public var lineSpacing: Double
        public var letterSpacing: Double
        public var paragraphSpacing: Double
        public var horizontalPadding: Double
        public var verticalPadding: Double
        public var paddingTop: Double?
        public var paddingBottom: Double?
        public var paddingLeft: Double?
        public var paddingRight: Double?
        public var firstLineIndent: Double
        public var weightLevel: Int
        public var fontName: String
        public var chineseConversion: String
        public var theme: String
        public var useCustomColors: Bool
        public var customBackgroundHex: String
        public var customTextHex: String
        public var titleAlignment: String
        public var headerEnabled: Bool
        public var footerEnabled: Bool
        public var barDivider: Bool
        // 后加的键一律可选，老备份解出来是 nil 就用默认值
        public var textAlignment: String?
        public var paragraphSeparatorLines: Int?
        public var underlineEnabled: Bool?
        public var underlinePattern: String?
        public var underlineColorHex: String?
        public var chapterTitleScale: Double?
        public var chapterTitleSpacing: Double?
        public var chapterTopSpacing: Double?
        public var chapterBottomSpacing: Double?
        public var backgroundImageEnabled: Bool?
        public var backgroundImagePath: String?
    }

    public var layoutSnapshot: LayoutSnapshot {
        LayoutSnapshot(
            fontSize: Double(fontSize),
            lineSpacing: Double(lineSpacing),
            letterSpacing: Double(letterSpacing),
            paragraphSpacing: Double(paragraphSpacing),
            horizontalPadding: Double(horizontalPadding),
            verticalPadding: Double(verticalPadding),
            paddingTop: Double(paddingTop),
            paddingBottom: Double(paddingBottom),
            paddingLeft: Double(paddingLeft),
            paddingRight: Double(paddingRight),
            firstLineIndent: Double(firstLineIndent),
            weightLevel: weightLevel,
            fontName: fontName,
            chineseConversion: chineseConversion.rawValue,
            theme: theme.rawValue,
            useCustomColors: useCustomColors,
            customBackgroundHex: customBackgroundHex,
            customTextHex: customTextHex,
            titleAlignment: titleAlignment.rawValue,
            headerEnabled: headerEnabled,
            footerEnabled: footerEnabled,
            barDivider: barDivider,
            textAlignment: textAlignment.rawValue,
            paragraphSeparatorLines: paragraphSeparatorLines,
            underlineEnabled: underlineEnabled,
            underlinePattern: underlinePattern.rawValue,
            underlineColorHex: underlineColorHex,
            chapterTitleScale: Double(chapterTitleScale),
            chapterTitleSpacing: Double(chapterTitleSpacing),
            chapterTopSpacing: Double(chapterTopSpacing),
            chapterBottomSpacing: Double(chapterBottomSpacing),
            backgroundImageEnabled: backgroundImageEnabled,
            backgroundImagePath: backgroundImagePath
        )
    }

    public func apply(_ snapshot: LayoutSnapshot) {
        fontSize = CGFloat(snapshot.fontSize)
        lineSpacing = CGFloat(snapshot.lineSpacing)
        letterSpacing = CGFloat(snapshot.letterSpacing)
        paragraphSpacing = CGFloat(snapshot.paragraphSpacing)
        horizontalPadding = CGFloat(snapshot.horizontalPadding)
        verticalPadding = CGFloat(snapshot.verticalPadding)
        paddingTop = CGFloat(snapshot.paddingTop ?? snapshot.verticalPadding)
        paddingBottom = CGFloat(snapshot.paddingBottom ?? snapshot.verticalPadding)
        paddingLeft = CGFloat(snapshot.paddingLeft ?? snapshot.horizontalPadding)
        paddingRight = CGFloat(snapshot.paddingRight ?? snapshot.horizontalPadding)
        firstLineIndent = CGFloat(snapshot.firstLineIndent)
        weightLevel = snapshot.weightLevel
        fontName = snapshot.fontName
        chineseConversion = ChineseConversion(rawValue: snapshot.chineseConversion) ?? .none
        theme = ReaderTheme(rawValue: snapshot.theme) ?? .parchment
        useCustomColors = snapshot.useCustomColors
        customBackgroundHex = snapshot.customBackgroundHex
        customTextHex = snapshot.customTextHex
        titleAlignment = ReaderTitleAlignment(rawValue: snapshot.titleAlignment) ?? .leading
        headerEnabled = snapshot.headerEnabled
        footerEnabled = snapshot.footerEnabled
        barDivider = snapshot.barDivider
        textAlignment = ReaderTextAlignment(rawValue: snapshot.textAlignment ?? "") ?? .justify
        paragraphSeparatorLines = snapshot.paragraphSeparatorLines ?? 0
        underlineEnabled = snapshot.underlineEnabled ?? false
        underlinePattern = ReaderUnderlinePattern(rawValue: snapshot.underlinePattern ?? "") ?? .solid
        underlineColorHex = snapshot.underlineColorHex ?? ""
        chapterTitleScale = CGFloat(snapshot.chapterTitleScale ?? 1.18)
        chapterTitleSpacing = CGFloat(snapshot.chapterTitleSpacing ?? 28)
        chapterTopSpacing = CGFloat(snapshot.chapterTopSpacing ?? 18)
        chapterBottomSpacing = CGFloat(snapshot.chapterBottomSpacing ?? 36)
        backgroundImageEnabled = snapshot.backgroundImageEnabled ?? false
        backgroundImagePath = snapshot.backgroundImagePath ?? ""
    }

    /// 按书存排版，key 用书的 URL 的哈希
    public func saveLayout(for bookUrl: String) {
        guard !sharedLayout, !bookUrl.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(layoutSnapshot) else { return }
        Self.defaults.set(data, forKey: "reader_layout_\(abs(bookUrl.hashValue))")
    }

    public func loadLayout(for bookUrl: String) {
        guard !sharedLayout, !bookUrl.isEmpty else { return }
        guard let data = Self.defaults.data(forKey: "reader_layout_\(abs(bookUrl.hashValue))"),
              let snapshot = try? JSONDecoder().decode(LayoutSnapshot.self, from: data) else { return }
        apply(snapshot)
    }

    /// 当前字体，找不到就退回默认
    public var font: ReaderFont {
        let candidate = ReaderFont.font(named: fontName)
        return candidate.isAvailable ? candidate : ReaderFont.default
    }

    // MARK: - 配色
    @Published public var theme: ReaderTheme = .parchment { didSet { Self.defaults.set(theme.rawValue, forKey: "reader_theme") } }
    @Published public var useCustomColors: Bool = false { didSet { Self.defaults.set(useCustomColors, forKey: "reader_custom_colors") } }
    @Published public var customBackgroundHex: String = "#F2ECE0" { didSet { Self.defaults.set(customBackgroundHex, forKey: "reader_bg_hex") } }
    @Published public var customTextHex: String = "#2E2721" { didSet { Self.defaults.set(customTextHex, forKey: "reader_text_hex") } }

    // MARK: - 翻页
    @Published public var pageMode: PageMode = .scroll { didSet { Self.defaults.set(pageMode.rawValue, forKey: "reader_page_mode") } }

    /// 真正用到的背景色：开了自定义就用自定义，否则用主题色。
    public var backgroundColor: Color {
        guard useCustomColors, let custom = Color(hex: customBackgroundHex) else {
            return theme.backgroundColor
        }
        return custom
    }

    public var textColor: Color {
        guard useCustomColors, let custom = Color(hex: customTextHex) else {
            return theme.textColor
        }
        return custom
    }

    public init() {
        let d = Self.defaults
        if let savedMode = d.string(forKey: "reader_page_mode"), let mode = PageMode(rawValue: savedMode) {
            pageMode = mode
        }
        if let savedTheme = d.string(forKey: "reader_theme"), let t = ReaderTheme(rawValue: savedTheme) {
            theme = t
        }
        if d.object(forKey: "reader_font_size") != nil { fontSize = CGFloat(d.double(forKey: "reader_font_size")) }
        if d.object(forKey: "reader_line_spacing") != nil { lineSpacing = CGFloat(d.double(forKey: "reader_line_spacing")) }
        if d.object(forKey: "reader_cached_chapters") != nil { cachedChapterCount = d.integer(forKey: "reader_cached_chapters") }
        if d.object(forKey: "reader_letter_spacing") != nil { letterSpacing = CGFloat(d.double(forKey: "reader_letter_spacing")) }
        if d.object(forKey: "reader_paragraph_spacing") != nil { paragraphSpacing = CGFloat(d.double(forKey: "reader_paragraph_spacing")) }
        if d.object(forKey: "reader_justify_last_page") != nil { justifyLastPage = d.bool(forKey: "reader_justify_last_page") }
        if d.object(forKey: "reader_panel_opacity") != nil { panelOpacity = d.double(forKey: "reader_panel_opacity") }
        if d.object(forKey: "reader_horizontal_padding") != nil { horizontalPadding = CGFloat(d.double(forKey: "reader_horizontal_padding")) }
        if d.object(forKey: "reader_first_line_indent") != nil { firstLineIndent = CGFloat(d.double(forKey: "reader_first_line_indent")) }
        if d.object(forKey: "reader_bold_text") != nil { boldText = d.bool(forKey: "reader_bold_text") }
        if let name = d.string(forKey: "reader_font_name") { fontName = name }
        if d.object(forKey: "reader_weight_level") != nil { weightLevel = d.integer(forKey: "reader_weight_level") }
        if let v = d.string(forKey: "reader_chinese_conversion"), let c = ChineseConversion(rawValue: v) {
            chineseConversion = c
        }
        if d.object(forKey: "reader_vertical_padding") != nil { verticalPadding = CGFloat(d.double(forKey: "reader_vertical_padding")) }
        // 老版本只有上下/左右两个边距：没有新键就沿用旧值，之后互不影响
        let legacyVertical = CGFloat(d.object(forKey: "reader_vertical_padding") != nil ? d.double(forKey: "reader_vertical_padding") : Double(verticalPadding))
        let legacyHorizontal = CGFloat(d.object(forKey: "reader_horizontal_padding") != nil ? d.double(forKey: "reader_horizontal_padding") : Double(horizontalPadding))
        paddingTop = d.object(forKey: "reader_padding_top") != nil ? CGFloat(d.double(forKey: "reader_padding_top")) : legacyVertical
        paddingBottom = d.object(forKey: "reader_padding_bottom") != nil ? CGFloat(d.double(forKey: "reader_padding_bottom")) : legacyVertical
        paddingLeft = d.object(forKey: "reader_padding_left") != nil ? CGFloat(d.double(forKey: "reader_padding_left")) : legacyHorizontal
        paddingRight = d.object(forKey: "reader_padding_right") != nil ? CGFloat(d.double(forKey: "reader_padding_right")) : legacyHorizontal
        if d.object(forKey: "reader_header_offset") != nil { headerOffset = CGFloat(d.double(forKey: "reader_header_offset")) }
        // 老配置里可能存着超出滑块范围的数（滑块 range 一变就出这种脏值），
        // SwiftUI 的 Slider 拿到范围外的值会 trap，统一夹一次
        headerOffset = min(max(0, headerOffset), 160)
        footerOffset = min(max(0, footerOffset), 160)
        shortTitleLength = min(max(1, shortTitleLength), 20)
        paddingTop = min(max(0, paddingTop), 200)
        paddingBottom = min(max(0, paddingBottom), 200)
        paddingLeft = min(max(0, paddingLeft), 200)
        paddingRight = min(max(0, paddingRight), 200)
        paragraphSpacing = min(max(0, paragraphSpacing), 30)
        lineSpacing = min(max(0, lineSpacing), 40)
        letterSpacing = min(max(0, letterSpacing), 4)
        firstLineIndent = min(max(0, firstLineIndent), 4)
        fontSize = min(max(12, fontSize), 32)
        if d.object(forKey: "reader_footer_offset") != nil { footerOffset = CGFloat(d.double(forKey: "reader_footer_offset")) }
        if d.object(forKey: "reader_brightness") != nil { brightness = d.double(forKey: "reader_brightness") }
        if d.object(forKey: "reader_auto_night") != nil { autoNight = d.bool(forKey: "reader_auto_night") }
        if let v = d.string(forKey: "reader_title_alignment"), let t = ReaderTitleAlignment(rawValue: v) { titleAlignment = t }
        if d.object(forKey: "reader_header_enabled") != nil { headerEnabled = d.bool(forKey: "reader_header_enabled") }
        headerLeft = Self.loadBar("reader_header_left", fallback: headerLeft)
        headerCenter = Self.loadBar("reader_header_center", fallback: headerCenter)
        headerRight = Self.loadBar("reader_header_right", fallback: headerRight)
        if d.object(forKey: "reader_footer_enabled") != nil { footerEnabled = d.bool(forKey: "reader_footer_enabled") }
        footerLeft = Self.loadBar("reader_footer_left", fallback: footerLeft)
        footerCenter = Self.loadBar("reader_footer_center", fallback: footerCenter)
        footerRight = Self.loadBar("reader_footer_right", fallback: footerRight)
        if d.object(forKey: "reader_bar_divider") != nil { barDivider = d.bool(forKey: "reader_bar_divider") }
        if d.object(forKey: "reader_smart_paragraphs") != nil { smartParagraphs = d.bool(forKey: "reader_smart_paragraphs") }
        if d.object(forKey: "reader_punctuation_kinsoku") != nil { punctuationKinsoku = d.bool(forKey: "reader_punctuation_kinsoku") }
        if d.object(forKey: "reader_shared_layout") != nil { sharedLayout = d.bool(forKey: "reader_shared_layout") }
        if d.object(forKey: "reader_custom_colors") != nil { useCustomColors = d.bool(forKey: "reader_custom_colors") }
        if let hex = d.string(forKey: "reader_bg_hex") { customBackgroundHex = hex }
        if let hex = d.string(forKey: "reader_text_hex") { customTextHex = hex }
        if let v = d.string(forKey: "reader_text_alignment"), let a = ReaderTextAlignment(rawValue: v) {
            textAlignment = a
        }
        if d.object(forKey: "reader_paragraph_separator_lines") != nil {
            paragraphSeparatorLines = d.integer(forKey: "reader_paragraph_separator_lines")
        }
        if let hex = d.string(forKey: "reader_paragraph_separator_hex") { paragraphSeparatorColorHex = hex }
        if d.object(forKey: "reader_underline_enabled") != nil { underlineEnabled = d.bool(forKey: "reader_underline_enabled") }
        if let v = d.string(forKey: "reader_underline_pattern"), let p = ReaderUnderlinePattern(rawValue: v) {
            underlinePattern = p
        }
        if let hex = d.string(forKey: "reader_underline_hex") { underlineColorHex = hex }
        if d.object(forKey: "reader_chapter_title_scale") != nil {
            chapterTitleScale = CGFloat(d.double(forKey: "reader_chapter_title_scale"))
        }
        if d.object(forKey: "reader_chapter_title_spacing") != nil {
            chapterTitleSpacing = CGFloat(d.double(forKey: "reader_chapter_title_spacing"))
        }
        if d.object(forKey: "reader_chapter_top_spacing") != nil {
            chapterTopSpacing = CGFloat(d.double(forKey: "reader_chapter_top_spacing"))
        }
        if d.object(forKey: "reader_chapter_bottom_spacing") != nil {
            chapterBottomSpacing = CGFloat(d.double(forKey: "reader_chapter_bottom_spacing"))
        }
        if d.object(forKey: "reader_bg_image_enabled") != nil { backgroundImageEnabled = d.bool(forKey: "reader_bg_image_enabled") }
        if let p = d.string(forKey: "reader_bg_image_path") { backgroundImagePath = p }
        if d.object(forKey: "reader_short_title_length") != nil {
            shortTitleLength = d.integer(forKey: "reader_short_title_length")
        }
        if let p = d.string(forKey: "reader_custom_date_pattern") { customDatePattern = p }
        if let t = d.string(forKey: "reader_custom_bar_text") { customBarText = t }
        if let p = d.string(forKey: "reader_title_designer_project") { chapterTitleProjectJSON = p }
        if let h = d.string(forKey: "reader_title_designer_html") { chapterTitleHTMLTemplate = h }
        if d.object(forKey: "reader_title_designer_height") != nil {
            chapterTitleCanvasHeight = d.double(forKey: "reader_title_designer_height")
        }

        AppLog.write("[阅读配置] 载入 字号=\(fontSize) 行距=\(lineSpacing) 亮度=\(brightness) 面板=\(panelOpacity) 标题=\(chapterTitleScale) 距顶=\(headerOffset) 距底=\(footerOffset) 主题=\(theme.rawValue) 模式=\(pageMode.rawValue)")
        // 所有滑块值统一夹回界面实际范围。旧版本存过越界值时，
        // SwiftUI Slider 一渲染就会 trap，点「界面」即闪退。
        headerOffset = min(max(0, headerOffset), 160)
        footerOffset = min(max(0, footerOffset), 120)
        brightness = min(max(0.2, brightness), 1.0)
        panelOpacity = min(max(0.25, panelOpacity), 1.0)
        chapterTitleScale = min(max(1.0, chapterTitleScale), 1.8)
        chapterTitleSpacing = min(max(0, chapterTitleSpacing), 48)
        chapterTopSpacing = min(max(0, chapterTopSpacing), 48)
        chapterBottomSpacing = min(max(0, chapterBottomSpacing), 72)
        shortTitleLength = min(max(2, shortTitleLength), 12)
    }

    private func persist(_ value: CGFloat, _ key: String) {
        Self.defaults.set(Double(value), forKey: key)
    }
}

/// 预设配色对（背景 + 文字），对应安卓那排色块
public enum ReaderPresetColor: String, CaseIterable, Identifiable {
    case paper = "米黄"
    case warm = "暖棕"
    case olive = "豆绿"
    case lilac = "浅紫"
    case night = "暗夜"
    case plain = "素白"

    public var id: String { rawValue }

    public var backgroundHex: String {
        switch self {
        case .paper: return "#F2E6CE"
        case .warm: return "#E8D6B8"
        case .olive: return "#BBC895"
        case .lilac: return "#E8D8F0"
        case .night: return "#12202E"
        case .plain: return "#F7F6F3"
        }
    }

    public var textHex: String {
        switch self {
        case .paper: return "#4A3F2F"
        case .warm: return "#5A4326"
        case .olive: return "#394321"
        case .lilac: return "#4A3560"
        case .night: return "#D6DEE6"
        case .plain: return "#23282D"
        }
    }
}

// MARK: - 页眉页脚取值

/// 页眉页脚格式化需要的全部输入。
/// 滚动阅读和仿真翻页两条路径共用同一套取值，免得同一栏在两处显示不一样。
public struct ReaderBarContext {
    public var bookName: String = ""
    public var chapterTitle: String = ""
    public var chapterIndex: Int = 0
    public var chapterCount: Int = 0
    public var pageIndex: Int = 0
    public var pageCount: Int = 0
    public var isPaged: Bool = false
    /// 全书进度 0...1
    public var bookProgress: Double = 0
    /// 本次阅读会话起点，没有就不显示时长
    public var sessionStart: Date?
    public var shortTitleLength: Int = 6
    public var customDatePattern: String = "M月d日"
    public var customBarText: String = ""

    public init() {}
}

public enum ReaderBarBattery {
    /// 设备电量 0...1，拿不到返回 nil
    public static func level() -> Double? {
        #if canImport(UIKit)
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        return level < 0 ? nil : Double(level)
        #else
        return nil
        #endif
    }
}

/// `DateFormatter` 建一次要几百微秒，而页眉页脚每帧都会问一次时间。
/// 按格式串缓存住，不然翻页时每帧都在建格式化器。
private final class ReaderBarClock {
    static let shared = ReaderBarClock()
    private var cache: [String: DateFormatter] = [:]
    private let lock = NSLock()

    func string(for pattern: String) -> String {
        lock.lock()
        let formatter: DateFormatter
        if let cached = cache[pattern] {
            formatter = cached
        } else {
            let made = DateFormatter()
            made.locale = Locale(identifier: "zh_CN")
            made.dateFormat = pattern
            cache[pattern] = made
            formatter = made
        }
        lock.unlock()
        return formatter.string(from: Date())
    }
}

private func readerBarClock(_ pattern: String) -> String {
    ReaderBarClock.shared.string(for: pattern)
}

/// 把一栏显示项格式化成文字。图形项（电量图标、进度条）返回空串，由视图层单独画。
public func readerBarText(_ content: ReaderBarContent, _ ctx: ReaderBarContext) -> String {
    switch content {
    case .none, .bookPercentBar, .batteryIcon, .batteryBar:
        return ""
    case .bookName:
        return ctx.bookName
    case .chapterTitle:
        return ctx.chapterTitle
    case .shortChapterTitle:
        guard !ctx.chapterTitle.isEmpty else { return "" }
        let limit = max(2, ctx.shortTitleLength)
        return ctx.chapterTitle.count <= limit ? ctx.chapterTitle : String(ctx.chapterTitle.prefix(limit)) + "…"
    case .progress:
        guard ctx.chapterCount > 0 else { return "" }
        return String(format: "%.1f%%", Double(ctx.chapterIndex + 1) / Double(ctx.chapterCount) * 100)
    case .pageInfo, .pagePercent:
        if ctx.isPaged, ctx.pageCount > 0 { return "\(ctx.pageIndex + 1)/\(ctx.pageCount)" }
        guard ctx.chapterCount > 0 else { return "" }
        return "\(ctx.chapterIndex + 1)/\(ctx.chapterCount)"
    case .pageNumberLabel:
        guard ctx.isPaged, ctx.pageCount > 0 else { return "" }
        return "第 \(ctx.pageIndex + 1) 页"
    case .bookPercent:
        return ctx.bookProgress <= 0 ? "" : String(format: "%.1f%%", ctx.bookProgress * 100)
    case .time:
        return readerBarClock("HH:mm")
    case .clockWithSeconds:
        return readerBarClock("HH:mm:ss")
    case .date:
        return readerBarClock("yyyy-MM-dd")
    case .weekday:
        return readerBarClock("EEEE")
    case .userDate:
        return readerBarClock(ctx.customDatePattern)
    case .batteryLevel, .batteryGlyphWithPercent:
        guard let level = ReaderBarBattery.level() else { return "" }
        return "\(Int((level * 100).rounded()))%"
    case .chapterCount:
        return ctx.chapterCount > 0 ? "共 \(ctx.chapterCount) 章" : ""
    case .chaptersShort:
        return ctx.chapterCount > 0 ? "\(ctx.chapterCount)章" : ""
    case .elapsedReadingTime:
        guard let start = ctx.sessionStart else { return "" }
        return barDurationText(Date().timeIntervalSince(start))
    case .remainingReadingTime:
        guard let start = ctx.sessionStart else { return "" }
        let elapsed = Date().timeIntervalSince(start)
        // 样本太少不外推，免得刚打开就报一个离谱的数字
        guard ctx.bookProgress > 0.02, elapsed > 60 else { return "" }
        let remaining = elapsed / ctx.bookProgress - elapsed
        guard remaining > 0, remaining < 24 * 3600 else { return "" }
        return "约剩 " + barDurationText(remaining)
    case .userText:
        return ctx.customBarText
    }
}

private func barDurationText(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes <= 0 { return "刚刚" }
    if minutes < 60 { return "\(minutes) 分" }
    return "\(minutes / 60) 时 \(minutes % 60) 分"
}

public extension Color {
    /// 支持 #RRGGBB / RRGGBB / #RGB
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((number & 0xFF0000) >> 16) / 255.0,
            green: Double((number & 0x00FF00) >> 8) / 255.0,
            blue: Double(number & 0x0000FF) / 255.0
        )
    }

    /// 转回 #RRGGBB，用于把取色器的结果存进 UserDefaults
    var hexString: String? {
        #if os(iOS)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #else
        guard let ns = NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
        let r = ns.redComponent, g = ns.greenComponent, b = ns.blueComponent
        #endif
        return String(
            format: "#%02X%02X%02X",
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded())
        )
    }
}

/// 替换净化规则：正文入库前按顺序跑一遍，全局规则 + 本书规则都会生效
public struct ReplaceRule: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var pattern: String
    public var replacement: String
    /// 关掉就按纯文本替换，不把 pattern 当正则
    public var isRegex: Bool
    public var enabled: Bool
    /// nil = 全局；填 bookUrl = 只对那本书
    public var bookUrl: String?

    public init(
        id: UUID = UUID(),
        name: String = "",
        pattern: String = "",
        replacement: String = "",
        isRegex: Bool = true,
        enabled: Bool = true,
        bookUrl: String? = nil
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.isRegex = isRegex
        self.enabled = enabled
        self.bookUrl = bookUrl
    }

    public var isGlobal: Bool { bookUrl == nil }

    /// 只跑这一条：编辑页试跑和批量净化都走它
    public func apply(to text: String) -> String {
        guard enabled, !pattern.isEmpty else { return text }
        if isRegex {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
            let range = NSRange(location: 0, length: (text as NSString).length)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
        }
        return text.replacingOccurrences(of: pattern, with: replacement)
    }
}

public final class ReplaceRuleStore: ObservableObject {
    public static let shared = ReplaceRuleStore()

    @Published public var rules: [ReplaceRule] {
        didSet { save() }
    }

    private let key = "reader_replace_rules_v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([ReplaceRule].self, from: data) {
            rules = list
        } else {
            rules = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public func globalRules() -> [ReplaceRule] {
        rules.filter { $0.isGlobal }
    }

    public func rules(for bookUrl: String?) -> [ReplaceRule] {
        rules.filter { $0.isGlobal || ($0.bookUrl != nil && $0.bookUrl == bookUrl) }
    }

    /// 对正文跑一遍净化，正则出错时跳过本条规则。
    public func apply(to text: String, bookUrl: String?) -> String {
        rules(for: bookUrl).reduce(text) { $1.apply(to: $0) }
    }
}

extension ReaderConfig {
    /// 一键把「排版」相关的值恢复默认（字体、主题、亮度不动，那些是个人偏好）
    public func resetLayoutToDefaults() {
        fontSize = 18
        lineSpacing = 8
        letterSpacing = 0
        paragraphSpacing = 12
        firstLineIndent = 2
        paddingTop = 24
        paddingBottom = 24
        paddingLeft = 16
        paddingRight = 16
        headerOffset = 0
        footerOffset = 0
        shortTitleLength = 6
        justifyLastPage = true
        barDivider = false
        smartParagraphs = true
        punctuationKinsoku = true
        titleAlignment = .center
        headerLeft = [.bookName]
        headerCenter = []
        headerRight = [.progress]
        footerLeft = [.chapterTitle]
        footerCenter = []
        footerRight = [.pageInfo]
    }
}
