import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 两端对齐的正文段落。
///
/// SwiftUI 的 `Text` 没有两端对齐，滚动模式下要真做 justify 只能落到平台文本控件；
/// 顺带把行距、字距、下划线一起交给 `NSMutableParagraphStyle`，
/// 口径和正文段落的排版一致（text-align / line-height / letter-spacing）。
struct JustifiedBodyText: View {
    let text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let letterSpacing: CGFloat
    let textColor: Color
    /// PostScript 名，为空就用系统字体
    let fontName: String?
    let underlineEnabled: Bool
    let underlineColor: Color?
    let underlineStyle: Int
    /// 这一段的身份：滚动模式的长按要按它换算字位
    var chapterIndex: Int = -1
    var blockId: Int = -1
    /// 这一段里的逐字标注（start / length 相对本段）
    var charAnnotations: [ReaderCharAnnotation] = []
    /// 当前字选（-1 表示没选）
    var selectionStart: Int = -1
    var selectionLength: Int = 0
    /// 正在朗读的区间：只给有字的地方铺底色，行尾留白照旧露纸色
    var readingStart: Int = -1
    var readingLength: Int = 0
    var readingTint: Color? = nil
    /// 段落对齐：两端对齐之外的三档也走这套控件，滚动模式的字选才有字符坐标
    var alignment: NSTextAlignment = .justified

    var body: some View {
        #if os(iOS)
        iOSBody
        #else
        macOSBody
        #endif
    }

    private func attributed() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping

        var attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: paragraph,
            .kern: letterSpacing,
        ]

        #if os(iOS)
        attributes[.font] = fontName.flatMap { UIFont(name: $0, size: fontSize) }
            ?? UIFont.systemFont(ofSize: fontSize)
        attributes[.foregroundColor] = UIColor(textColor)
        #else
        attributes[.font] = fontName.flatMap { NSFont(name: $0, size: fontSize) }
            ?? NSFont.systemFont(ofSize: fontSize)
        attributes[.foregroundColor] = NSColor(textColor)
        #endif

        if underlineEnabled {
            #if os(iOS)
            attributes[.underlineStyle] = underlineStyle
            attributes[.underlineColor] = UIColor(underlineColor ?? textColor)
            #else
            attributes[.underlineStyle] = underlineStyle
            attributes[.underlineColor] = NSColor(underlineColor ?? textColor)
            #endif
        }

        let result = NSMutableAttributedString(string: text, attributes: attributes)

        // 逐字标注：底色 / 下划线按区间叠上去，滚动模式也能只标选中那几个字
        #if os(iOS)
        if readingLength > 0, let tint = readingTint {
            let range = NSRange(location: readingStart, length: readingLength)
            if range.location >= 0, range.location + range.length <= result.length {
                result.addAttribute(.backgroundColor, value: UIColor(tint), range: range)
            }
        }
        for item in charAnnotations {
            let range = NSRange(location: item.start, length: item.length)
            guard range.location >= 0, range.length > 0,
                  range.location + range.length <= result.length else { continue }
            if let hex = item.style.highlightHex, let color = UIColor(readerHex: hex) {
                result.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.55), range: range)
            }
            if item.style.underline,
               let color = UIColor(readerHex: item.style.underlineHex ?? "#2F7BF6") {
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                result.addAttribute(.underlineColor, value: color, range: range)
            }
        }
        if selectionLength > 0 {
            let range = NSRange(location: selectionStart, length: selectionLength)
            if range.location >= 0, range.location + range.length <= result.length {
                result.addAttribute(.backgroundColor,
                                    value: UIColor.systemBlue.withAlphaComponent(0.22),
                                    range: range)
            }
        }
        #endif

        return result
    }

    #if os(iOS)
    private var iOSBody: some View {
        JustifiedLabel(attributed: attributed(),
                       chapterIndex: chapterIndex,
                       blockId: blockId)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct JustifiedLabel: UIViewRepresentable {
        let attributed: NSAttributedString
        let chapterIndex: Int
        let blockId: Int

        func makeUIView(context: Context) -> ReaderBodyLabel {
            let label = ReaderBodyLabel()
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.isUserInteractionEnabled = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return label
        }

        func updateUIView(_ label: ReaderBodyLabel, context: Context) {
            label.chapterIndex = chapterIndex
            label.blockId = blockId
            label.attributedText = attributed
            label.registerInRegistry()
        }
    }
    #else
    private var macOSBody: some View {
        JustifiedField(attributed: attributed())
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct JustifiedField: NSViewRepresentable {
        let attributed: NSAttributedString

        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField(labelWithAttributedString: attributed)
            field.isEditable = false
            field.isSelectable = false
            field.isBordered = false
            field.drawsBackground = false
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 0
            return field
        }

        func updateNSView(_ field: NSTextField, context: Context) {
            field.attributedStringValue = attributed
        }
    }
    #endif
}

#if os(iOS)
/// 滚动模式正文用的 UILabel。
///
/// UILabel 不对外暴露 TextKit，可滚动模式的长按要回答「这个点落在第几个字」，
/// 只能自己搭一套参数相同的 layout manager：字号、行距、字距、段样式全沿用正文那一份，
/// 排版结果和 label 实际画出来的基本重合（左右零内边距、行高一致）。
final class ReaderBodyLabel: UILabel {
    /// 这一段属于第几章、哪个 block：长按命中后靠它回查原文
    var chapterIndex: Int = -1
    var blockId: Int = -1

    private final class WeakRef {
        weak var value: ReaderBodyLabel?
        init(_ value: ReaderBodyLabel) { self.value = value }
    }
    private static var registry: [WeakRef] = []

    /// 按章节 + block 找到那一段的 label（长按只给了屏幕坐标，没法直接 query）
    /// 已注册的 label 数量（验收日志用：0 说明这一屏根本没走 UIKit 文本）
    static var registeredCount: Int {
        registry.removeAll { $0.value == nil }
        return registry.count
    }

    static func label(chapterIndex: Int, blockId: Int) -> ReaderBodyLabel? {
        registry.removeAll { $0.value == nil }
        return registry.compactMap(\.value)
            .first { $0.chapterIndex == chapterIndex && $0.blockId == blockId }
    }

    func registerInRegistry() {
        Self.registry.removeAll { $0.value == nil || $0.value === self }
        Self.registry.append(WeakRef(self))
    }

    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)
    private let textStorage = NSTextStorage()
    private var needsLayoutSync = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureTextKit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTextKit()
    }

    private func configureTextKit() {
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
    }

    override var attributedText: NSAttributedString? {
        didSet { needsLayoutSync = true }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != textContainer.size {
            needsLayoutSync = true
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { registerInRegistry() }
    }

    private func syncLayout() {
        guard bounds.width > 0 else { return }
        textContainer.size = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        if needsLayoutSync {
            let current = attributedText ?? NSAttributedString(string: text ?? "")
            textStorage.setAttributedString(current)
            needsLayoutSync = false
        }
        layoutManager.ensureLayout(for: textContainer)
    }

    /// 窗口坐标 → 段内 UTF-16 偏移。整段为空或点落在正文外就返回 nil。
    func charIndex(atWindowPoint point: CGPoint) -> Int? {
        syncLayout()
        let length = textStorage.length
        guard length > 0 else { return nil }
        let localPoint = convert(point, from: nil)
        guard localPoint.y >= -4, localPoint.y <= bounds.height + 4 else { return nil }
        let used = layoutManager.usedRect(for: textContainer)
        // label 比正文高时 UILabel 自己会垂直居中，这里跟着让位
        let insetY = max(0, (bounds.height - used.height) / 2)
        let probe = CGPoint(x: min(max(0, localPoint.x), max(0, bounds.width - 1)),
                            y: min(max(0, localPoint.y - insetY), max(0, used.height - 1)))
        let glyph = layoutManager.glyphIndex(for: probe, in: textContainer)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return min(max(0, index), length - 1)
    }

    /// 段内字符区间 → 窗口坐标里的选框，气泡靠它定位
    func windowRect(forCharRange range: NSRange) -> CGRect? {
        syncLayout()
        guard range.location >= 0, range.length > 0,
              range.location + range.length <= textStorage.length else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        rect.origin.y += max(0, (bounds.height - used.height) / 2)
        return convert(rect, to: nil)
    }
}
#endif

extension ReaderUnderlinePattern {
    /// 转成 NSUnderlineStyle 的位掩码
    var nsUnderlineStyle: Int {
        switch self {
        case .solid: return NSUnderlineStyle.single.rawValue
        case .dot: return NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
        case .dash: return NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue
        case .dashDot: return NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDashDot.rawValue
        }
    }
}
