import Foundation
import CoreText
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

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
    /// 插图显示设置：分页和渲染必须用同一套尺寸算法，否则会留白或裁图
    var imageDisplayMode: Int = 0
    var imageMaxWidthPercent: CGFloat = 100
    /// 书源规则里的图片样式：FULL/SINGLE 铺满，TEXT 小图，其它不超过原尺寸
    var imageStyleFullWidth: Bool = false
    var imageStyleSmall: Bool = false

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

    /// 一页里可以混排文字行和插图：插图不再强制独占一页
    private enum PageItem {
        case line(PageLine)
        case image(ContentBlock)
    }

    /// ChapterImageView 给插图上下各留 6pt
    static let imageVerticalPadding: CGFloat = 12

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
        var currentPageItems: [PageItem] = []
        var currentItemHeights: [CGFloat] = []
        var currentPageHeight: CGFloat = 0
        var maxHeightForCurrentPage = firstPageHeight
        var blockIdCounter = 10000

        func lastLineIsParagraphEnd() -> Bool {
            if case .line(let line)? = currentPageItems.last { return line.isParagraphEnd }
            return false
        }

        func appendCurrentPage() {
            pages.append(buildPageBlocks(from: currentPageItems, startingId: &blockIdCounter))
            currentPageItems.removeAll(keepingCapacity: true)
            currentItemHeights.removeAll(keepingCapacity: true)
            currentPageHeight = 0
            maxHeightForCurrentPage = normalHeight
        }

        for (index, block) in blocks.enumerated() {
            if block.isImage {
                let size = imageDisplaySize(
                    for: block,
                    usableWidth: CGFloat(usableWidth),
                    maxImageHeight: normalHeight,
                    displayMode: layout.imageDisplayMode,
                    maxWidthPercent: layout.imageMaxWidthPercent,
                    styleFullWidth: layout.imageStyleFullWidth,
                    styleSmall: layout.imageStyleSmall
                )
                // 图注跟着图走：紧随其后的 caption 块也一起算进本页预算
                var captionAdvance: CGFloat = 0
                var cursor = index + 1
                while cursor < blocks.count, blocks[cursor].isCaption, !blocks[cursor].isImage {
                    captionAdvance += lineHeight
                    cursor += 1
                }
                let needed = size.height + imageVerticalPadding + captionAdvance
                if !currentPageItems.isEmpty, currentPageHeight + needed > maxHeightForCurrentPage {
                    appendCurrentPage()
                }
                currentPageItems.append(.image(block))
                currentItemHeights.append(size.height + imageVerticalPadding)
                currentPageHeight += size.height + imageVerticalPadding
                continue
            }

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
            if isReviewBlock, !currentPageItems.isEmpty {
                let spacingBefore: CGFloat = lastLineIsParagraphEnd()
                    ? layout.paragraphSpacing : 0
                let topExtra: CGFloat = max(0, reviewPad - spacingBefore)
                let bottomExtra = max(0, reviewPad - layout.paragraphSpacing)
                let blockHeight = spacingBefore
                    + CGFloat(pLines.count) * reviewLineHeight
                    + layout.paragraphSpacing
                    + topExtra
                    + bottomExtra
                if currentPageHeight + blockHeight > maxHeightForCurrentPage,
                   blockHeight <= normalHeight {
                    appendCurrentPage()
                }
            }
            for (lineIdx, lineInfo) in pLines.enumerated() {
                let baseHeight = isReviewBlock ? reviewLineHeight : lineHeight
                let gap = lastLineIsParagraphEnd()
                    ? layout.paragraphSpacing
                    : 0
                let advance = baseHeight + gap

                // 孤行控制：段首行不能单独留在页底，放不下「本行 + 下一行」就整段下移
                if !isReviewBlock, lineIdx == 0, pLines.count > 1,
                   !currentPageItems.isEmpty,
                   currentPageHeight + advance + baseHeight > maxHeightForCurrentPage {
                    appendCurrentPage()
                }

                let overflows = !currentPageItems.isEmpty
                    && currentPageHeight + advance > maxHeightForCurrentPage
                if overflows {
                    // 寡行控制：段末行不单独起页，把本段上一行一起带下去
                    var carried: PageLine?
                    if !isReviewBlock,
                       lineIdx == pLines.count - 1, lineIdx > 0,
                       currentPageItems.count >= 2,
                       case .line(let prev)? = currentPageItems.last,
                       prev.paragraphId == block.id {
                        carried = prev
                        currentPageHeight -= currentItemHeights.removeLast()
                        currentPageItems.removeLast()
                    }
                    appendCurrentPage()
                    if let carried {
                        currentPageItems.append(.line(carried))
                        currentItemHeights.append(baseHeight)
                        currentPageHeight += baseHeight
                    }
                }

                currentPageItems.append(.line((lineInfo.text, lineInfo.isParagraphEnd, lineInfo.charStart, block.id)))
                currentItemHeights.append(advance)
                currentPageHeight += advance
            }
        }

        if !currentPageItems.isEmpty {
            appendCurrentPage()
        }
        return pages.isEmpty ? [[]] : pages
    }

    /// 插图在正文里的显示尺寸。分页和渲染共用；宽高比未知时按 4:3 估。
    static func imageDisplaySize(
        for block: ContentBlock,
        usableWidth: CGFloat,
        maxImageHeight: CGFloat,
        displayMode: Int,
        maxWidthPercent: CGFloat,
        styleFullWidth: Bool,
        styleSmall: Bool
    ) -> CGSize {
        let ratio = max(0.05, block.imageAspectRatio ?? (4.0 / 3.0))
        let naturalWidth = block.imageNaturalWidth
        var width = usableWidth
        switch displayMode {
        case 1:
            // 原始尺寸：不超过正文宽度
            if naturalWidth > 0 { width = min(usableWidth, naturalWidth) }
        case 2:
            width = usableWidth
        default:
            if styleSmall {
                width = min(max(naturalWidth > 0 ? naturalWidth : 80, 24), 80)
            } else if !styleFullWidth, naturalWidth > 0 {
                width = min(usableWidth, naturalWidth)
            }
        }
        let percent = max(0.3, min(1, maxWidthPercent / 100))
        width = max(24, min(width, usableWidth * percent))
        let height = min(width / ratio, max(0.1, maxImageHeight) * 0.85)
        return CGSize(width: width, height: height)
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
        for scalar in "。，、；：？！…～·）】》」』〉”’.，;:?!)]}%—".unicodeScalars where scalar.value <= 0xFFFF {
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
        // 行首禁则：后方紧跟句读类标点时拉到本行，一次最多三个
        var pulled = 0
        var next = start + count
        while pulled < 3, next < textLen, forbiddenLineStart.contains(nsStr.character(at: next)) {
            pulled += 1
            next += 1
        }
        adjusted += pulled
        // 行尾禁则：开引号/开括号连续出现时一并推到下一行，避免行尾挂半个引号
        var trailingOpen = 0
        while trailingOpen < 2,
              adjusted - trailingOpen > 1,
              forbiddenLineEnd.contains(nsStr.character(at: start + adjusted - trailingOpen - 1)) {
            trailingOpen += 1
        }
        adjusted -= trailingOpen
        return max(1, adjusted)
    }

    private static func buildPageBlocks(from items: [PageItem],
                                        startingId: inout Int) -> [ContentBlock] {
        var identifier = startingId
        var blocks: [ContentBlock] = []
        for item in items {
            switch item {
            case .line(let line):
                blocks.append(ContentBlock(
                    id: identifier,
                    isImage: false,
                    text: line.text,
                    imageUrl: line.isParagraphEnd ? "p_end" : nil,
                    paragraphId: line.paragraphId,
                    charStart: line.charStart
                ))
                identifier += 1
            case .image(let block):
                // 保留原 block id：正文里的评论/统计还按它索引
                blocks.append(block)
            }
        }
        startingId = identifier
        return blocks
    }}

/// 分页后的一页按内容拆段：文字段 / 插图 / 热评卡片。
/// 左右翻页和仿真翻页共用，插图才能和文字排在同一页。
struct ReaderPageSegment: Identifiable {
    enum Kind: Equatable {
        case text
        case image
        case review
    }

    let id: Int
    let kind: Kind
    let blocks: [ContentBlock]

    static func split(_ blocks: [ContentBlock]) -> [ReaderPageSegment] {
        var result: [ReaderPageSegment] = []
        var textRun: [ContentBlock] = []
        func flushText() {
            guard !textRun.isEmpty else { return }
            result.append(ReaderPageSegment(id: textRun[0].id, kind: .text, blocks: textRun))
            textRun.removeAll(keepingCapacity: true)
        }
        for block in blocks {
            if block.isImage {
                flushText()
                result.append(ReaderPageSegment(id: block.id, kind: .image, blocks: [block]))
            } else if block.commentCount == -2 {
                flushText()
                result.append(ReaderPageSegment(id: block.id, kind: .review, blocks: [block]))
            } else {
                textRun.append(block)
            }
        }
        flushText()
        return result
    }

    /// 跟分页器同一口径：段尾标记后的段间距不计入本段高度（下一页/插图会吃掉它）
    static func textHeight(_ blocks: [ContentBlock], lineHeight: CGFloat, paragraphSpacing: CGFloat) -> CGFloat {
        let ends = blocks.map { $0.imageUrl == "p_end" }
        let trailing = ends.last == true ? 1 : 0
        let paragraphCount = ends.filter { $0 }.count - trailing
        return CGFloat(blocks.count) * lineHeight + CGFloat(max(0, paragraphCount)) * paragraphSpacing
    }
}

/// 插图尺寸测量：只读图片头，不整张解码。
/// 本地 EPUB 图直接读文件头；远程图由 ChapterImageView 加载成功后回填缓存。
enum ReaderImageMetrics {
    private static let cache = NSCache<NSString, NSValue>()

    static func measure(urlString: String, cachedData: Data? = nil) -> CGSize? {
        let key = urlString as NSString
        if let value = cache.object(forKey: key) {
            return cgSize(from: value)
        }
        var size: CGSize?
        if let cachedData, !cachedData.isEmpty {
            size = pixelSize(of: cachedData)
        } else if let url = URL(string: urlString), url.isFileURL {
            size = pixelSize(ofFile: url)
        }
        if let size, size.width > 0, size.height > 0 {
            cache.setObject(sizeValue(size), forKey: key)
            return size
        }
        return nil
    }

    /// 图片真正加载出来后回填，之后重新解析这一章就能按真实比例分页
    static func remember(urlString: String, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        cache.setObject(sizeValue(size), forKey: urlString as NSString)
    }

    private static func sizeValue(_ size: CGSize) -> NSValue {
        #if os(macOS)
        return NSValue(size: size)
        #else
        return NSValue(cgSize: size)
        #endif
    }

    private static func cgSize(from value: NSValue) -> CGSize {
        #if os(macOS)
        return value.sizeValue
        #else
        return value.cgSizeValue
        #endif
    }

    static func aspectRatio(_ pixelSize: CGSize?) -> CGFloat? {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        return pixelSize.width / pixelSize.height
    }

    /// 跟 ChapterImageView.naturalWidthInPoints 同一口径：像素宽按屏幕倍率折成 pt
    static func pointsWidth(_ pixelSize: CGSize?) -> CGFloat {
        guard let pixelSize, pixelSize.width > 0 else { return 0 }
        #if canImport(UIKit)
        let scale = UIScreen.main.scale
        return scale > 0 ? pixelSize.width / scale : pixelSize.width
        #else
        return pixelSize.width
        #endif
    }

    private static func pixelSize(ofFile url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixelSize(from: source)
    }

    private static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(from: source)
    }

    private static func pixelSize(from source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}

