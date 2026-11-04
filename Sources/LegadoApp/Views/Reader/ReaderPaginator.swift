import Foundation
import CoreText

/// 分页需要的全部排版参数。做成值类型是为了能安全地丢到后台队列：
/// 计算期间用户继续拖滑杆也不会读到半新半旧的配置。
struct ReaderPaginationLayout: Sendable, Equatable {
    var version: Int = 0
    var containerSize: CGSize
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var letterSpacing: CGFloat
    var firstLineIndent: CGFloat
    var paragraphSpacing: CGFloat
    var reviewFontScale: CGFloat
    var reviewInset: CGFloat
    var weightLevel: Int
    var fontPostScriptName: String
    var fontBoldPostScriptName: String
    var punctuationKinsoku: Bool
    var headerEnabled: Bool
    var footerEnabled: Bool
    var headerOffset: CGFloat
    var footerOffset: CGFloat
    var paddingTop: CGFloat
    var paddingBottom: CGFloat
    var paddingLeft: CGFloat
    var paddingRight: CGFloat
    var chapterTitleScale: CGFloat
    var titleHidden: Bool

    var lineHeight: CGFloat { fontSize * 1.25 + lineSpacing }

    var reviewLineHeight: CGFloat {
        fontSize * max(0.5, reviewFontScale) * 1.25 + lineSpacing
    }

    /// 跟 CoreTextUIView.reviewBands 同一个口径：卡片上下各多出这段留白
    var reviewPad: CGFloat { min(14, max(8, paragraphSpacing + 1)) }

    /// 断行的宽度必须和渲染时用的一致，不然一行排得比页宽，右边就被切掉
    var usableWidth: Double {
        Double(max(200, containerSize.width - paddingLeft - paddingRight))
    }
}

/// 把正文切成页。纯函数式：只依赖传入的 `ReaderPaginationLayout`，
/// 可以在后台线程直接跑，不碰任何 UI / 配置对象。
enum ReaderPaginator {
    typealias PageLine = (text: String, isParagraphEnd: Bool, charStart: Int, paragraphId: Int)

    static func paginate(blocks: [ContentBlock], title: String?, layout: ReaderPaginationLayout) -> [[ContentBlock]] {
        let metrics = calculateLayoutMetrics(title: title, layout: layout)
        let normalHeight = metrics.pageHeight
        let firstPageHeight = metrics.firstPageHeight
        let lineHeight = layout.lineHeight
        let reviewScale = max(0.5, layout.reviewFontScale)
        let reviewInset = Double(max(0, layout.reviewInset))
        let reviewLineHeight = layout.reviewLineHeight
        let reviewPad = layout.reviewPad
        let usableWidth = layout.usableWidth

        var pages: [[ContentBlock]] = []
        var currentPageLines: [PageLine] = []
        var currentPageHeight: CGFloat = 0
        var maxHeightForCurrentPage = firstPageHeight
        var blockIdCounter = 10000

        for block in blocks {
            if block.isImage {
                if !currentPageLines.isEmpty {
                    pages.append(buildPageBlocks(from: currentPageLines, startingId: &blockIdCounter))
                    currentPageLines.removeAll(keepingCapacity: true)
                }
                pages.append([block])
                currentPageHeight = 0
                maxHeightForCurrentPage = normalHeight
            } else {
                let isReviewBlock = block.commentCount == -2
                let pLines = splitParagraphIntoLines(
                    text: block.text,
                    width: usableWidth,
                    fontSizeOverride: isReviewBlock ? layout.fontSize * reviewScale : nil,
                    horizontalInset: isReviewBlock ? reviewInset : 0,
                    suppressFirstLineIndent: isReviewBlock,
                    layout: layout
                )
                // 卡片整块留在同一页，不然框会从中间被页面切断
                if isReviewBlock, !currentPageLines.isEmpty {
                    let spacingBefore: CGFloat = currentPageLines.last?.isParagraphEnd == true
                        ? layout.paragraphSpacing : 0
                    let topExtra: CGFloat = currentPageLines.isEmpty
                        ? 0
                        : max(0, reviewPad - spacingBefore)
                    let bottomExtra = max(0, reviewPad - layout.paragraphSpacing)
                    let blockHeight = spacingBefore
                        + CGFloat(pLines.count) * reviewLineHeight
                        + layout.paragraphSpacing
                        + topExtra
                        + bottomExtra
                    if currentPageHeight + blockHeight > maxHeightForCurrentPage,
                       blockHeight <= normalHeight {
                        pages.append(buildPageBlocks(from: currentPageLines, startingId: &blockIdCounter))
                        currentPageLines = []
                        currentPageHeight = 0
                        maxHeightForCurrentPage = normalHeight
                    }
                }
                for lineInfo in pLines {
                    let baseHeight = isReviewBlock ? reviewLineHeight : lineHeight
                    let gap = currentPageLines.last?.isParagraphEnd == true
                        ? layout.paragraphSpacing
                        : 0
                    let advance = baseHeight + gap

                    let overflows = !currentPageLines.isEmpty
                        && currentPageHeight + advance > maxHeightForCurrentPage
                    if overflows {
                        pages.append(buildPageBlocks(from: currentPageLines, startingId: &blockIdCounter))
                        currentPageLines.removeAll(keepingCapacity: true)
                        currentPageHeight = 0
                        maxHeightForCurrentPage = normalHeight
                    }

                    currentPageLines.append((lineInfo.text, lineInfo.isParagraphEnd, lineInfo.charStart, block.id))
                    currentPageHeight += advance
                }
            }
        }

        guard !currentPageLines.isEmpty else {
            return pages.isEmpty ? [[]] : pages
        }
        pages.append(buildPageBlocks(from: currentPageLines, startingId: &blockIdCounter))
        return pages
    }

    /// 首页标题占的高度：按可用宽度估算折行行数，分页和渲染共用同一套算法
    static func estimatedTitleHeight(_ title: String, layout: ReaderPaginationLayout) -> CGFloat {
        guard !layout.titleHidden else { return 0 }
        let titleFontSize = layout.fontSize * layout.chapterTitleScale
        let width = max(120, layout.containerSize.width - layout.paddingLeft - layout.paddingRight)
        let charsPerLine = max(4, Int(width / (titleFontSize + layout.letterSpacing)))
        let lines = max(1, min(4, Int(ceil(Double(title.count) / Double(charsPerLine)))))
        // 略放宽：估小了最后一行会被页脚裁掉
        return titleFontSize * 1.45 * CGFloat(lines) + 12.0
    }

    /// 返回高度而非行数：段间距占位，按行数算会低估，
    /// 超出预算的部分会压到页脚上。
    static func calculateLayoutMetrics(title: String?, layout: ReaderPaginationLayout) -> (pageHeight: CGFloat, firstPageHeight: CGFloat) {
        let height = max(400, layout.containerSize.height)

        let barHeight: CGFloat = 19
        let reserved = (layout.headerEnabled ? barHeight : 0)
            + (layout.footerEnabled ? barHeight : 0)
            + (layout.headerEnabled ? layout.headerOffset : 0)
            + (layout.footerEnabled ? layout.footerOffset : 0)
            + layout.paddingTop
            + layout.paddingBottom
        let usableHeight = max(200, height - reserved - 2)

        // First page has chapter title (+ title padding)
        let titleHeight = title.map { estimatedTitleHeight($0, layout: layout) }
            ?? estimatedTitleHeight("第 1 章", layout: layout)
        let firstPageUsableHeight = max(100, usableHeight - titleHeight)

        return (pageHeight: usableHeight, firstPageHeight: firstPageUsableHeight)
    }

    /// 把一段正文切成行。
    ///
    /// 这里必须跟 `CoreTextPageView` 用同一套字体和字距：换字体或把字距调大后，
    /// 按默认苹方、不带字距切出来的行，画的时候会宽于量出来的宽度，整页就溢出/错位。
    /// 热评段用比正文小一号的字，并且左右各留出卡片内边距，
    /// 所以断行必须按「小字号 + 收窄宽度」来算，跟 draw 那边保持同一口径。
    static func splitParagraphIntoLines(
        text: String,
        width: Double,
        fontSizeOverride: CGFloat? = nil,
        horizontalInset: Double = 0,
        suppressFirstLineIndent: Bool = false,
        layout: ReaderPaginationLayout
    ) -> [(text: String, isParagraphEnd: Bool, charStart: Int)] {
        let fontSize = fontSizeOverride ?? layout.fontSize
        let font = ReaderFontFactory.ctFont(
            postScriptName: layout.fontPostScriptName,
            boldPostScriptName: layout.fontBoldPostScriptName,
            size: fontSize,
            weightLevel: layout.weightLevel
        )
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTKernAttributeName: layout.letterSpacing
        ]
        guard let attrString = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            return [(text, true, 0)]
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attrString)
        var start = 0
        let textLen = CFStringGetLength(text as CFString)
        var result: [(text: String, isParagraphEnd: Bool, charStart: Int)] = []
        let nsStr = text as NSString
        // 段首会补全角缩进，第一行要按缩进后的宽度切，否则首行一定超宽
        let indentWidth = suppressFirstLineIndent
            ? 0
            : Double(layout.firstLineIndent.rounded()) * Double(fontSize)
        let textWidth = max(20, width - horizontalInset * 2)
        var isFirstLine = true

        while start < textLen {
            let available = isFirstLine ? max(20, textWidth - indentWidth) : textWidth
            var count = CTTypesetterSuggestLineBreak(typesetter, start, available)
            if count <= 0 { break }
            if layout.punctuationKinsoku {
                count = applyLineBreakRules(nsStr: nsStr, start: start, count: count, textLen: textLen)
            }
            let sub = nsStr.substring(with: NSRange(location: start, length: count))
            let isEnd = (start + count >= textLen)
            result.append((sub, isEnd, start))
            start += count
            isFirstLine = false
        }
        return result
    }

    // MARK: - 标点禁则

    /// 标点禁则：行首不该出现句读/收尾类标点，行尾不该出现开引号、开括号。
    /// 行首禁则按「标点挤压」处理：把标点拉到上一行，宽度交给两端对齐吸收；
    /// 行尾禁则把该字符挪到下一行。CoreText 不做中文禁则，需要在这里补。
    static let forbiddenLineStart: Set<unichar> = {
        var set = Set<unichar>()
        for scalar in "。，、；：？！…～·）】》」』〉”’.，;:?!)]}%".unicodeScalars where scalar.value <= 0xFFFF {
            set.insert(unichar(scalar.value))
        }
        return set
    }()

    static let forbiddenLineEnd: Set<unichar> = {
        var set = Set<unichar>()
        for scalar in "（【《「『〈“‘([{".unicodeScalars where scalar.value <= 0xFFFF {
            set.insert(unichar(scalar.value))
        }
        return set
    }()

    static func isForbiddenLineStart(_ ch: Character) -> Bool {
        guard let scalar = String(ch).unicodeScalars.first, scalar.value <= 0xFFFF else { return false }
        return forbiddenLineStart.contains(unichar(scalar.value))
    }

    static func isForbiddenLineEnd(_ ch: Character) -> Bool {
        guard let scalar = String(ch).unicodeScalars.first, scalar.value <= 0xFFFF else { return false }
        return forbiddenLineEnd.contains(unichar(scalar.value))
    }

    static func applyLineBreakRules(nsStr: NSString, start: Int, count: Int, textLen: Int) -> Int {
        var adjusted = count
        // 行首禁则：后方紧跟句读类标点时拉到本行，一次最多两个
        var pulled = 0
        var next = start + count
        while pulled < 2, next < textLen, forbiddenLineStart.contains(nsStr.character(at: next)) {
            pulled += 1
            next += 1
        }
        adjusted += pulled
        // 行尾禁则：本行最后一个是开引号/开括号就把它推到下一行
        if adjusted > 1, forbiddenLineEnd.contains(nsStr.character(at: start + adjusted - 1)) {
            adjusted -= 1
        }
        return max(1, adjusted)
    }

    private static func buildPageBlocks(from lines: [PageLine],
                                        startingId: inout Int) -> [ContentBlock] {
        var identifier = startingId
        let blocks = lines.map { line -> ContentBlock in
            defer { identifier += 1 }
            return ContentBlock(
                id: identifier,
                isImage: false,
                text: line.text,
                imageUrl: line.isParagraphEnd ? "p_end" : nil,
                paragraphId: line.paragraphId,
                charStart: line.charStart
            )
        }
        startingId = identifier
        return blocks
    }
}
