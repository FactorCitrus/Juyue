import SwiftUI
import CoreText

#if os(iOS)
import UIKit

/// 滚动模式里「非两端对齐」的段落是 SwiftUI Text 画的，摸不到 TextKit，
/// 也就没有 `ReaderBodyLabel` 那套字符坐标。这里用同一套字体参数再排一遍 CoreText，
/// 只回答两个问题：触点落在第几个字、某个字符区间在窗口里的矩形。
///
/// 参数必须和 `bodyText(_:alignment:)` 那边对齐（系统字体、字号、字距、行距、对齐），
/// 差一项都会让选中的词偏一两个字。
enum ReaderScrollTextMetrics {
    struct Context {
        /// 显示用文本（已做禁则处理，和 Text 实际画的是同一串）
        let text: String
        let fontSize: CGFloat
        let lineSpacing: CGFloat
        let kerning: CGFloat
        let alignment: NSTextAlignment
        /// 文本左上角，窗口坐标
        let origin: CGPoint
        let width: CGFloat
    }

    private struct LineBox {
        let line: CTLine
        /// CT 坐标（左下原点）
        let origin: CGPoint
        let ascent: CGFloat
        let descent: CGFloat
    }

    /// 按触点找字符下标（UTF-16，相对显示文本）
    static func charIndex(atWindowPoint point: CGPoint, in ctx: Context) -> Int? {
        guard let built = build(ctx) else { return nil }
        let localX = point.x - ctx.origin.x
        let localY = point.y - ctx.origin.y
        guard localY >= -3, localY <= built.height + 3 else { return nil }
        // CT 的 y 从底部往上，这里翻过来
        let ctY = built.height - localY
        let hit = built.lines.first { ctY <= $0.origin.y + $0.ascent + 2 && ctY >= $0.origin.y - $0.descent - 2 }
        guard let lineBox = hit else { return nil }
        let xInLine = max(0, localX - lineBox.origin.x)
        let index = CTLineGetStringIndexForPosition(lineBox.line, CGPoint(x: xInLine, y: 0))
        guard index != kCFNotFound else { return nil }
        return max(0, min(index, max(0, (ctx.text as NSString).length - 1)))
    }

    /// 字符区间（UTF-16，相对显示文本）→ 窗口坐标矩形
    static func rect(forRange range: NSRange, in ctx: Context) -> CGRect? {
        guard range.length > 0, let built = build(ctx) else { return nil }
        var union: CGRect?
        for lineBox in built.lines {
            let lineRange = CTLineGetStringRange(lineBox.line)
            let lineStart = lineRange.location
            let lineEnd = lineRange.location + lineRange.length
            let start = max(range.location, lineStart)
            let end = min(range.location + range.length, lineEnd)
            guard end > start else { continue }
            let x1 = CTLineGetOffsetForStringIndex(lineBox.line, start, nil)
            let x2 = CTLineGetOffsetForStringIndex(lineBox.line, end, nil)
            let top = ctx.origin.y + (built.height - (lineBox.origin.y + lineBox.ascent))
            let rect = CGRect(x: ctx.origin.x + lineBox.origin.x + min(x1, x2),
                              y: top,
                              width: max(1, abs(x2 - x1)),
                              height: lineBox.ascent + lineBox.descent)
            union = union.map { $0.union(rect) } ?? rect
        }
        return union
    }

    private static func build(_ ctx: Context) -> (lines: [LineBox], height: CGFloat)? {
        guard ctx.width > 10, !ctx.text.isEmpty else { return nil }
        let font = UIFont.systemFont(ofSize: ctx.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = ctx.alignment
        paragraph.lineSpacing = ctx.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]
        if ctx.kerning != 0 { attributes[.kern] = ctx.kerning }
        let attributed = NSAttributedString(string: ctx.text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: ctx.width, height: .greatestFiniteMagnitude),
            nil
        )
        let height = max(1, ceil(suggested.height))
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: ctx.width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let ctLines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !ctLines.isEmpty else { return nil }
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var boxes: [LineBox] = []
        for (index, line) in ctLines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            boxes.append(LineBox(line: line, origin: origins[index], ascent: ascent, descent: descent))
        }
        return (boxes, height)
    }
}

/// 跨平台别名：macOS 上没有 UILabel 那条路，给个空壳让函数签名照样成立
typealias ReaderScrollMetricsContext = ReaderScrollTextMetrics.Context
#else
struct ReaderScrollMetricsContext {}
#endif
