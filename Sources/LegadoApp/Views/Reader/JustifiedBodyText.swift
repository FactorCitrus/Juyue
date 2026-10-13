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

    var body: some View {
        #if os(iOS)
        iOSBody
        #else
        macOSBody
        #endif
    }

    private func attributed() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .justified
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

        return NSAttributedString(string: text, attributes: attributes)
    }

    #if os(iOS)
    private var iOSBody: some View {
        JustifiedLabel(attributed: attributed())
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct JustifiedLabel: UIViewRepresentable {
        let attributed: NSAttributedString

        func makeUIView(context: Context) -> UILabel {
            let label = UILabel()
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return label
        }

        func updateUIView(_ label: UILabel, context: Context) {
            label.attributedText = attributed
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
