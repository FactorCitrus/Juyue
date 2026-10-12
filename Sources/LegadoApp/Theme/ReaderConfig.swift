import SwiftUI

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
        case .eyeCare: return Color(red: 187.0 / 255.0, green: 200.0 / 255.0, blue: 149.0 / 255.0)
        case .dark: return Color(red: 0.12, green: 0.12, blue: 0.12)
        }
    }

    public var textColor: Color {
        switch self {
        case .white: return Color(red: 0.15, green: 0.15, blue: 0.15)
        case .parchment: return Color(red: 0.22, green: 0.18, blue: 0.15)
        case .eyeCare: return Color(red: 57.0 / 255.0, green: 67.0 / 255.0, blue: 33.0 / 255.0)
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

/// 页眉页脚每栏能填什么
public enum ReaderBarContent: String, CaseIterable, Identifiable {
    case none = "无"
    case chapterTitle = "标题"
    case bookName = "书名"
    case progress = "进度(%)"
    case pageInfo = "页码"
    case time = "时间"

    public var id: String { rawValue }
}

/// 每页顶部那行章节标题怎么放
public enum ReaderTitleAlignment: String, CaseIterable, Identifiable {
    case leading = "靠左"
    case center = "居中"
    case hidden = "隐藏"

    public var id: String { rawValue }
}

public class ReaderConfig: ObservableObject {
    public static let shared = ReaderConfig()

    private static let defaults = UserDefaults.standard

    // MARK: - 字号与行距
    @Published public var fontSize: CGFloat = 18.0 { didSet { persist(fontSize, "reader_font_size") } }
    @Published public var lineSpacing: CGFloat = 8.0 { didSet { persist(lineSpacing, "reader_line_spacing") } }

    // MARK: - 排版
    /// 字间距
    @Published public var letterSpacing: CGFloat = 0.5 { didSet { persist(letterSpacing, "reader_letter_spacing") } }
    /// 段间距
    @Published public var paragraphSpacing: CGFloat = 12.0 { didSet { persist(paragraphSpacing, "reader_paragraph_spacing") } }
    /// 左右页边距
    @Published public var horizontalPadding: CGFloat = 24.0 { didSet { persist(horizontalPadding, "reader_horizontal_padding") } }
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

    // MARK: - 页眉页脚
    @Published public var titleAlignment: ReaderTitleAlignment = .leading {
        didSet { Self.defaults.set(titleAlignment.rawValue, forKey: "reader_title_alignment") }
    }
    @Published public var headerEnabled: Bool = false {
        didSet { Self.defaults.set(headerEnabled, forKey: "reader_header_enabled") }
    }
    @Published public var headerLeft: ReaderBarContent = .bookName {
        didSet { Self.defaults.set(headerLeft.rawValue, forKey: "reader_header_left") }
    }
    @Published public var headerCenter: ReaderBarContent = .none {
        didSet { Self.defaults.set(headerCenter.rawValue, forKey: "reader_header_center") }
    }
    @Published public var headerRight: ReaderBarContent = .progress {
        didSet { Self.defaults.set(headerRight.rawValue, forKey: "reader_header_right") }
    }
    @Published public var footerEnabled: Bool = true {
        didSet { Self.defaults.set(footerEnabled, forKey: "reader_footer_enabled") }
    }
    @Published public var footerLeft: ReaderBarContent = .chapterTitle {
        didSet { Self.defaults.set(footerLeft.rawValue, forKey: "reader_footer_left") }
    }
    @Published public var footerCenter: ReaderBarContent = .none {
        didSet { Self.defaults.set(footerCenter.rawValue, forKey: "reader_footer_center") }
    }
    @Published public var footerRight: ReaderBarContent = .pageInfo {
        didSet { Self.defaults.set(footerRight.rawValue, forKey: "reader_footer_right") }
    }
    @Published public var barDivider: Bool = false {
        didSet { Self.defaults.set(barDivider, forKey: "reader_bar_divider") }
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
    }

    public var layoutSnapshot: LayoutSnapshot {
        LayoutSnapshot(
            fontSize: Double(fontSize),
            lineSpacing: Double(lineSpacing),
            letterSpacing: Double(letterSpacing),
            paragraphSpacing: Double(paragraphSpacing),
            horizontalPadding: Double(horizontalPadding),
            verticalPadding: Double(verticalPadding),
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
            barDivider: barDivider
        )
    }

    public func apply(_ snapshot: LayoutSnapshot) {
        fontSize = CGFloat(snapshot.fontSize)
        lineSpacing = CGFloat(snapshot.lineSpacing)
        letterSpacing = CGFloat(snapshot.letterSpacing)
        paragraphSpacing = CGFloat(snapshot.paragraphSpacing)
        horizontalPadding = CGFloat(snapshot.horizontalPadding)
        verticalPadding = CGFloat(snapshot.verticalPadding)
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
        if d.object(forKey: "reader_letter_spacing") != nil { letterSpacing = CGFloat(d.double(forKey: "reader_letter_spacing")) }
        if d.object(forKey: "reader_paragraph_spacing") != nil { paragraphSpacing = CGFloat(d.double(forKey: "reader_paragraph_spacing")) }
        if d.object(forKey: "reader_horizontal_padding") != nil { horizontalPadding = CGFloat(d.double(forKey: "reader_horizontal_padding")) }
        if d.object(forKey: "reader_first_line_indent") != nil { firstLineIndent = CGFloat(d.double(forKey: "reader_first_line_indent")) }
        if d.object(forKey: "reader_bold_text") != nil { boldText = d.bool(forKey: "reader_bold_text") }
        if let name = d.string(forKey: "reader_font_name") { fontName = name }
        if d.object(forKey: "reader_weight_level") != nil { weightLevel = d.integer(forKey: "reader_weight_level") }
        if let v = d.string(forKey: "reader_chinese_conversion"), let c = ChineseConversion(rawValue: v) {
            chineseConversion = c
        }
        if d.object(forKey: "reader_vertical_padding") != nil { verticalPadding = CGFloat(d.double(forKey: "reader_vertical_padding")) }
        if let v = d.string(forKey: "reader_title_alignment"), let t = ReaderTitleAlignment(rawValue: v) { titleAlignment = t }
        if d.object(forKey: "reader_header_enabled") != nil { headerEnabled = d.bool(forKey: "reader_header_enabled") }
        if let v = d.string(forKey: "reader_header_left"), let c = ReaderBarContent(rawValue: v) { headerLeft = c }
        if let v = d.string(forKey: "reader_header_center"), let c = ReaderBarContent(rawValue: v) { headerCenter = c }
        if let v = d.string(forKey: "reader_header_right"), let c = ReaderBarContent(rawValue: v) { headerRight = c }
        if d.object(forKey: "reader_footer_enabled") != nil { footerEnabled = d.bool(forKey: "reader_footer_enabled") }
        if let v = d.string(forKey: "reader_footer_left"), let c = ReaderBarContent(rawValue: v) { footerLeft = c }
        if let v = d.string(forKey: "reader_footer_center"), let c = ReaderBarContent(rawValue: v) { footerCenter = c }
        if let v = d.string(forKey: "reader_footer_right"), let c = ReaderBarContent(rawValue: v) { footerRight = c }
        if d.object(forKey: "reader_bar_divider") != nil { barDivider = d.bool(forKey: "reader_bar_divider") }
        if d.object(forKey: "reader_shared_layout") != nil { sharedLayout = d.bool(forKey: "reader_shared_layout") }
        if d.object(forKey: "reader_custom_colors") != nil { useCustomColors = d.bool(forKey: "reader_custom_colors") }
        if let hex = d.string(forKey: "reader_bg_hex") { customBackgroundHex = hex }
        if let hex = d.string(forKey: "reader_text_hex") { customTextHex = hex }
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
