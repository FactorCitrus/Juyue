#if os(iOS)
import SwiftUI
import UIKit

/// 系统卷页会给卷起的那张纸加一层提亮高光，无法关闭。
/// 浅色主题（羊皮纸那种本来就接近白的）提亮看不出来；饱和色主题（护眼绿）
/// 一提就显成折痕边上的白边。
///
/// 处理方式相反：把背面那页的底色预先压暗一档，被高光提亮之后
/// 正好落回主题色。只动背面的填充，正文、正面、卷页几何都不碰。
private func curlBackColor(_ color: Color) -> Color {
    let ui = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return color }
    let k: CGFloat = 0.90
    return Color(red: Double(r * k), green: Double(g * k), blue: Double(b * k)).opacity(Double(a))
}

/// 仿真翻页：用 UIPageViewController 的 .pageCurl，就是系统书城那种卷页效果。
///
/// 只负责当前章的页面；翻过头或翻回来时通知外层换章。
public struct PageCurlPager: UIViewControllerRepresentable {
    public let pages: [[ContentBlock]]
    /// pages 对应的章节序号：换章时正文要晚一步才到，卷页动画得等它到位再做
    public let loadedChapterIndex: Int
    public let chapterTitle: String?
    public let fontSize: CGFloat
    public let lineSpacing: CGFloat
    public let letterSpacing: CGFloat
    public let paragraphSpacing: CGFloat
    public let firstLineIndent: CGFloat
    public let weightLevel: Int
    public let chineseConversion: ChineseConversion
    public let fontPostScriptName: String
    public let boldPostScriptName: String?
    public let textAlignment: ReaderTextAlignment
    public let underlineEnabled: Bool
    public let underlineColor: Color?
    public let paragraphSeparatorLines: Int
    public let paragraphSeparatorColor: Color
    public let textColor: Color
    public let backgroundColor: Color
    /// 阅读背景图，跟着每一页和卷起来的背面一起铺
    public let backgroundImage: Image?
    /// 章节标题字号系数，跟滚动模式同一口径
    public let chapterTitleScale: CGFloat
    public let shortTitleLength: Int
    /// 长按选中段落：把这一页的块和页内行号交回阅读页
    public var onSelectParagraph: (([ContentBlock], Int, Int) -> Void)? = nil
    /// 选中的段落（起始块 id + 覆盖块数）
    public var selectedRange: (start: Int, count: Int)? = nil
    /// 段内逐字选择
    public var charSelection: ReaderCharSelection? = nil
    /// 段内逐字标注
    public var charAnnotations: [ReaderCharAnnotation] = []
    /// 已加标注的段落：下划线 / 底色
    public var annotationRanges: [(start: Int, count: Int, style: ReaderBlockStyle)] = []
    public let customDatePattern: String
    public let customBarText: String
    public let titleHTMLTemplate: String
    public let titleProjectJSON: String
    public let paddingTop: CGFloat
    public let paddingBottom: CGFloat
    public let paddingLeft: CGFloat
    public let paddingRight: CGFloat
    public let headerOffset: CGFloat
    public let footerOffset: CGFloat
    public let titleAlignment: ReaderTitleAlignment
    /// 页眉页脚：仿真模式下要画在每一页里，跟着卷页一起动
    public let showHeader: Bool
    public let showFooter: Bool
    public let barDivider: Bool
    public let headerSlots: [[ReaderBarContent]]
    public let footerSlots: [[ReaderBarContent]]
    /// 整页是贴到屏幕物理边缘的，页眉页脚得自己把安全区让出来再顶出去
    public let topInset: CGFloat
    public let bottomInset: CGFloat
    public let bookName: String
    public let chapterTitleText: String
    public let chapterIndex: Int
    public let chapterCount: Int
    public let startIndex: Int
    public let onIndexChange: (Int) -> Void
    public let onReachEnd: () -> Void
    public let onReachStart: () -> Void
    public let onTapCenter: () -> Void
    public var commentMap: [Int: (count: Int, url: String)] = [:]
    public var onCommentTap: ((String) -> Void)? = nil

    public init(
        pages: [[ContentBlock]],
        loadedChapterIndex: Int,
        chapterTitle: String?,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        letterSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        firstLineIndent: CGFloat,
        weightLevel: Int,
        chineseConversion: ChineseConversion,
        fontPostScriptName: String,
        boldPostScriptName: String?,
        textAlignment: ReaderTextAlignment,
        underlineEnabled: Bool,
        underlineColor: Color?,
        paragraphSeparatorLines: Int,
        paragraphSeparatorColor: Color,
        textColor: Color,
        backgroundColor: Color,
        backgroundImage: Image?,
        chapterTitleScale: CGFloat,
        shortTitleLength: Int,
        onSelectParagraph: (([ContentBlock], Int, Int) -> Void)? = nil,
        selectedRange: (start: Int, count: Int)? = nil,
        charSelection: ReaderCharSelection? = nil,
        charAnnotations: [ReaderCharAnnotation] = [],
        annotationRanges: [(start: Int, count: Int, style: ReaderBlockStyle)] = [],
        customDatePattern: String,
        customBarText: String,
        titleHTMLTemplate: String,
        titleProjectJSON: String,
        paddingTop: CGFloat,
        paddingBottom: CGFloat,
        paddingLeft: CGFloat,
        paddingRight: CGFloat,
        headerOffset: CGFloat,
        footerOffset: CGFloat,
        titleAlignment: ReaderTitleAlignment,
        showHeader: Bool,
        showFooter: Bool,
        barDivider: Bool,
        headerSlots: [[ReaderBarContent]],
        footerSlots: [[ReaderBarContent]],
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        bookName: String,
        chapterTitleText: String,
        chapterIndex: Int,
        chapterCount: Int,
        startIndex: Int,
        onIndexChange: @escaping (Int) -> Void,
        onReachEnd: @escaping () -> Void,
        onReachStart: @escaping () -> Void,
        onTapCenter: @escaping () -> Void,
        commentMap: [Int: (count: Int, url: String)] = [:],
        onCommentTap: ((String) -> Void)? = nil
    ) {
        self.pages = pages
        self.loadedChapterIndex = loadedChapterIndex
        self.chapterTitle = chapterTitle
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.letterSpacing = letterSpacing
        self.paragraphSpacing = paragraphSpacing
        self.firstLineIndent = firstLineIndent
        self.weightLevel = weightLevel
        self.chineseConversion = chineseConversion
        self.fontPostScriptName = fontPostScriptName
        self.boldPostScriptName = boldPostScriptName
        self.textAlignment = textAlignment
        self.underlineEnabled = underlineEnabled
        self.underlineColor = underlineColor
        self.paragraphSeparatorLines = paragraphSeparatorLines
        self.paragraphSeparatorColor = paragraphSeparatorColor
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.backgroundImage = backgroundImage
        self.chapterTitleScale = chapterTitleScale
        self.shortTitleLength = shortTitleLength
        self.onSelectParagraph = onSelectParagraph
        self.selectedRange = selectedRange
        self.charSelection = charSelection
        self.charAnnotations = charAnnotations
        self.annotationRanges = annotationRanges
        self.customDatePattern = customDatePattern
        self.customBarText = customBarText
        self.titleHTMLTemplate = titleHTMLTemplate
        self.titleProjectJSON = titleProjectJSON
        self.paddingTop = paddingTop
        self.paddingBottom = paddingBottom
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
        self.headerOffset = headerOffset
        self.footerOffset = footerOffset
        self.titleAlignment = titleAlignment
        self.showHeader = showHeader
        self.showFooter = showFooter
        self.barDivider = barDivider
        self.headerSlots = headerSlots
        self.footerSlots = footerSlots
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.bookName = bookName
        self.chapterTitleText = chapterTitleText
        self.chapterIndex = chapterIndex
        self.chapterCount = chapterCount
        self.startIndex = startIndex
        self.onIndexChange = onIndexChange
        self.onReachEnd = onReachEnd
        self.onReachStart = onReachStart
        self.onTapCenter = onTapCenter
        self.commentMap = commentMap
        self.onCommentTap = onCommentTap
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: nil
        )
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        // 双面翻页：背面由 dataSource 提供，才不会出现系统那张白纸
        controller.isDoubleSided = true
        controller.view.backgroundColor = UIColor(backgroundColor)
        context.coordinator.installSwipeHooks(on: controller)
        // 正面 + 背面；实际投递几张由 apply 按当前书脊裁
        apply(
            context.coordinator.pagePair(at: clampedIndex),
            to: controller,
            direction: .forward,
            animated: false
        )
        return controller
    }

    /// 一次投几张，按 UIKit 的校验规则来（模拟器 iOS 26.3 实测，和 `isDoubleSided`、
    /// 有没有上屏都无关）：
    ///
    /// - 不带画：严格按书脊切分，`.min` 1 张，`.mid` 2 张；
    /// - 带动画：固定按 2 张校验，只给 1 张同样抛
    ///   "The number of view controllers provided (1) doesn't match the number required (2) for the requested transition"。
    ///
    /// 给多给少都是一条 NSInvalidArgumentException，凑不齐两张就退化成不带画投递。
    /// `isDoubleSided` 每次重新声明，保证卷起时露出的背面由 dataSource 提供。
    private func apply(
        _ target: [UIViewController],
        to controller: UIPageViewController,
        direction: UIPageViewController.NavigationDirection,
        animated: Bool
    ) {
        guard !target.isEmpty else { return }
        var wanted = target
        var animate = animated
        if animated {
            if target.count >= 2 {
                wanted = Array(target.prefix(2))
            } else {
                animate = false
            }
        } else if controller.spineLocation != .mid {
            wanted = Array(target.prefix(1))
        }
        controller.isDoubleSided = true
        controller.setViewControllers(wanted, direction: direction, animated: animate)
    }

    public func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.installSwipeHooks(on: controller)
        controller.view.backgroundColor = UIColor(backgroundColor)
        guard !pages.isEmpty else { return }

        // 配色、字体、排版这些变了要重建当前页，否则托管的页面还是旧样式
        let signature = renderSignature
        // 换章：在 pager 里按方向卷过去，别硬切、也别重建 pager。
        // （旧写法是给 pager 加 .id 让 SwiftUI 重建，换章就没有卷页动画了）
        if let previousChapter = context.coordinator.lastLoadedChapterIndex, previousChapter != loadedChapterIndex {
            let forward = loadedChapterIndex > previousChapter
            context.coordinator.lastLoadedChapterIndex = loadedChapterIndex
            context.coordinator.lastSignature = signature
            context.coordinator.index = clampedIndex
            apply(
                context.coordinator.pagePair(at: clampedIndex),
                to: controller,
                direction: forward ? .forward : .reverse,
                animated: true
            )
            return
        }
        context.coordinator.lastLoadedChapterIndex = loadedChapterIndex

        if context.coordinator.lastSignature != signature {
            context.coordinator.lastSignature = signature
            apply(
                context.coordinator.pagePair(at: context.coordinator.index),
                to: controller,
                direction: .forward,
                animated: false
            )
            return
        }

        let current = context.coordinator.index
        guard current != clampedIndex else { return }
        let direction: UIPageViewController.NavigationDirection = clampedIndex > current ? .forward : .reverse
        apply(
            context.coordinator.pagePair(at: clampedIndex),
            to: controller,
            direction: direction,
            animated: true
        )
        context.coordinator.index = clampedIndex
    }

    private var clampedIndex: Int {
        guard !pages.isEmpty else { return 0 }
        return min(max(0, startIndex), pages.count - 1)
    }

    /// 影响渲染的配置指纹，变了就重建页面
    private var renderSignature: String {
        var parts: [String] = []
        parts.append(String(describing: backgroundColor))
        parts.append(String(describing: textColor))
        parts.append("\(fontSize)")
        parts.append("\(lineSpacing)")
        parts.append("\(letterSpacing)")
        parts.append("\(paragraphSpacing)")
        parts.append("\(firstLineIndent)")
        parts.append("\(weightLevel)")
        parts.append(fontPostScriptName)
        parts.append(boldPostScriptName ?? "")
        parts.append(chineseConversion.rawValue)
        parts.append(titleAlignment.rawValue)
        // 正文对齐 / 下划线也必须进指纹：它们是托管页面的绘制参数，
        // 不进指纹的话「对齐」改了签名不变，缓存里的旧页面会一直留在屏幕上
        parts.append(textAlignment.rawValue)
        parts.append("\(underlineEnabled)/\(underlineColor.map { String(describing: $0) } ?? "")")
        parts.append("\(showHeader)\(showFooter)\(barDivider)")
        parts.append("\(paddingTop)/\(paddingBottom)/\(paddingLeft)/\(paddingRight)")
        parts.append("\(paragraphSeparatorLines)/\(String(describing: paragraphSeparatorColor))")
        parts.append("\(headerOffset)/\(footerOffset)")
        parts.append(headerSlots.map { $0.map(\.rawValue).joined(separator: "+") }.joined(separator: ","))
        parts.append(footerSlots.map { $0.map(\.rawValue).joined(separator: "+") }.joined(separator: ","))
        parts.append("\(topInset)/\(bottomInset)")
        parts.append("\(chapterTitleScale)")
        // 分页结果变了（页数变了）也要重建当前页：只看配置的话，
        // 「距顶/章标题间距」这类改了签名没变，托管页面会拿着旧分页不撒手
        parts.append("\(pages.count)")
        parts.append(chapterTitleText)
        parts.append(bookName)
        parts.append("\(chapterIndex)/\(chapterCount)")
        // 选中与标注也要进指纹：每页是托管缓存着的，不进指纹的话长按选中只改了状态，
        // 屏幕上那一页还是旧画面，看着就像「长按没选中」；下划线/底色同理，要翻页才出现
        parts.append(selectedRange.map { "sel\($0.start)+\($0.count)" } ?? "sel-")
        parts.append(charSelection.map { "char\($0.paragraphId):\($0.start)+\($0.length)" } ?? "char-")
        parts.append(charAnnotations.map {
            "\($0.paragraphId):\($0.start)+\($0.length):\($0.style.underline ? "u\($0.style.underlineHex ?? "")" : "")\($0.style.highlightHex ?? "")"
        }.joined(separator: ","))
        parts.append(annotationRanges.map {
            "\($0.start)+\($0.count):\($0.style.underline ? "u\($0.style.underlineHex ?? "")" : "")\($0.style.highlightHex ?? "")"
        }.joined(separator: ","))
        return parts.joined(separator: "|")
    }

    public final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlPager
        var index: Int
        var lastSignature: String = ""

        init(_ parent: PageCurlPager) {
            self.parent = parent
            self.index = min(max(0, parent.startIndex), max(0, parent.pages.count - 1))
            self.lastSignature = parent.renderSignature
        }

        // MARK: - 页面缓存
        private struct CachedPage {
            let controller: UIViewController
            let key: String
        }
        private var frontCache: [Int: CachedPage] = [:]
        private var backCache: [Int: CachedPage] = [:]
        private var cacheSignature: String = ""

        /// 缓存键 = 配置指纹 + 这一页的实际内容。
        /// 只看下标不行：翻到下一章时下标会重复，会拿到上一章的旧页面。
        private func pageKey(_ index: Int) -> String {
            let blocks = parent.pages[index]
            return parent.renderSignature
                + "|\(parent.pages.count)|\(index)|"
                + blocks.map { $0.text }.joined(separator: "\u{2}")
                + "|"
                + blocks.map { $0.imageUrl ?? "" }.joined(separator: "\u{2}")
        }

        private func resetCacheIfNeeded() {
            if cacheSignature != parent.renderSignature {
                cacheSignature = parent.renderSignature
                frontCache.removeAll()
                backCache.removeAll()
            }
        }

        /// 缓存不能无限涨，只留当前页附近的几页
        private func trim(_ cache: inout [Int: CachedPage]) {
            let limit = 6
            guard cache.count > limit else { return }
            let evict = cache.keys.sorted { abs($0 - index) > abs($1 - index) }
            for key in evict.prefix(cache.count - limit) { cache.removeValue(forKey: key) }
        }

        /// UIPageViewController 翻页时会反复要页面。每次重建 hosting controller
        /// 每次翻页都会重建 SwiftUI 视图树并重排正文，动画会卡。
        func controller(at index: Int) -> UIViewController? {
            guard index >= 0, index < parent.pages.count else { return nil }
            resetCacheIfNeeded()
            let key = pageKey(index)
            if let cached = frontCache[index], cached.key == key { return cached.controller }
            let made = makeController(at: index)
            frontCache[index] = CachedPage(controller: made, key: key)
            trim(&frontCache)
            return made
        }

        private func makeController(at index: Int) -> UIViewController {
            let page = parent.pages[index]
            let host = UIHostingController(rootView: PageCurlContent(
                blocks: page,
                onLongPressLine: { [parent] line, charOffset in
                    parent.onSelectParagraph?(page, line, charOffset)
                },
                selectedRange: parent.selectedRange,
                charSelection: parent.charSelection,
                charAnnotations: parent.charAnnotations,
                annotationRanges: parent.annotationRanges,
                commentMap: parent.commentMap,
                onCommentTap: parent.onCommentTap,
                chapterTitle: index == 0 ? parent.chapterTitle : nil,
                fontSize: parent.fontSize,
                lineSpacing: parent.lineSpacing,
                letterSpacing: parent.letterSpacing,
                paragraphSpacing: parent.paragraphSpacing,
                firstLineIndent: parent.firstLineIndent,
                weightLevel: parent.weightLevel,
                chineseConversion: parent.chineseConversion,
                fontPostScriptName: parent.fontPostScriptName,
                boldPostScriptName: parent.boldPostScriptName,
                textAlignment: parent.textAlignment,
                underlineEnabled: parent.underlineEnabled,
                underlineColor: parent.underlineColor,
                paragraphSeparatorLines: parent.paragraphSeparatorLines,
                paragraphSeparatorColor: parent.paragraphSeparatorColor,
                textColor: parent.textColor,
                backgroundColor: parent.backgroundColor,
                backgroundImage: parent.backgroundImage,
                chapterTitleScale: parent.chapterTitleScale,
                shortTitleLength: parent.shortTitleLength,
                customDatePattern: parent.customDatePattern,
                customBarText: parent.customBarText,
                titleHTMLTemplate: parent.titleHTMLTemplate,
                titleProjectJSON: parent.titleProjectJSON,
                paddingTop: parent.paddingTop,
                paddingBottom: parent.paddingBottom,
                paddingLeft: parent.paddingLeft,
                paddingRight: parent.paddingRight,
                headerOffset: parent.headerOffset,
                footerOffset: parent.footerOffset,
                titleAlignment: parent.titleAlignment,
                showHeader: parent.showHeader,
                showFooter: parent.showFooter,
                barDivider: parent.barDivider,
                headerSlots: parent.headerSlots,
                footerSlots: parent.footerSlots,
                topInset: parent.topInset,
                bottomInset: parent.bottomInset,
                bookName: parent.bookName,
                chapterTitleText: parent.chapterTitleText,
                chapterIndex: parent.chapterIndex,
                chapterCount: parent.chapterCount
                ,
                pageIndex: index,
                pageCount: parent.pages.count
            ))
            host.view.backgroundColor = UIColor(parent.backgroundColor)
            host.view.tag = index
            installTapZones(on: host.view)
            return host
        }

        /// 正面在前、背面在后；书脊是 .min 时 apply 只会用到正面那张
        func pagePair(at index: Int) -> [UIViewController] {
            guard let front = controller(at: index) else { return [] }
            if let back = backController(at: index) {
                return [front, back]
            }
            return [front]
        }

        /// 卷起来时露出的那一面：用主题底色 + 靠书脊的浅阴影，不再是一张白纸
        func backController(at index: Int) -> UIViewController? {
            guard index >= 0, index < parent.pages.count else { return nil }
            resetCacheIfNeeded()
            let key = pageKey(index)
            if let cached = backCache[index], cached.key == key { return cached.controller }
            let made = makeBackController(at: index)
            backCache[index] = CachedPage(controller: made, key: key)
            trim(&backCache)
            return made
        }

        private func makeBackController(at index: Int) -> UIViewController {
            let back = UIHostingController(rootView: PageCurlBackPage(
                backgroundColor: curlBackColor(parent.backgroundColor),
                backgroundImage: parent.backgroundImage,
                spineOnRight: false,
                faintLines: parent.pages[index].map { $0.text },
                faintParagraphEnd: parent.pages[index].map { $0.imageUrl == "p_end" },
                fontSize: parent.fontSize,
                lineSpacing: parent.lineSpacing,
                letterSpacing: parent.letterSpacing,
                firstLineIndent: parent.firstLineIndent,
                weightLevel: parent.weightLevel,
                chineseConversion: parent.chineseConversion,
                fontPostScriptName: parent.fontPostScriptName,
                boldPostScriptName: parent.boldPostScriptName,
                textColor: parent.textColor,
                paddingTop: parent.paddingTop,
                paddingBottom: parent.paddingBottom,
                paddingLeft: parent.paddingLeft,
                paddingRight: parent.paddingRight
            ))
            back.view.backgroundColor = UIColor(curlBackColor(parent.backgroundColor))
            back.view.tag = index
            return back
        }

        /// 左 30% 上一页、右 30% 下一页、中间切换控制栏
        private func installTapZones(on view: UIView) {
            for zone in 0..<3 {
                let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                let strip = UIView(frame: .zero)
                strip.backgroundColor = .clear
                strip.tag = zone
                strip.addGestureRecognizer(tap)
                strip.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(strip)
                NSLayoutConstraint.activate([
                    strip.topAnchor.constraint(equalTo: view.topAnchor),
                    strip.bottomAnchor.constraint(equalTo: view.bottomAnchor)
                ])
                if zone == 0 {
                    strip.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
                    strip.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.3).isActive = true
                } else if zone == 1 {
                    strip.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0).isActive = true
                    strip.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
                    view.sendSubviewToBack(strip)
                } else {
                    strip.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
                    strip.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.3).isActive = true
                }
            }
        }

        private var swipeHooked = false
        /// 一次滑动里只在位移阈值处通知一次
        private var boundaryForward = false
        private var boundaryBackward = false
        static var panEnds = 0
        static var panHits = 0
        static var swipeHits = 0
        static var tapHits = 0
        /// 换章检测：指纹变了＝换章，用来决定要不要走卷页动画
        var lastChapterSignature: String? = nil
        /// pages 已经渲染成哪一章了；换章动画靠它判断新章正文到没到
        var lastLoadedChapterIndex: Int? = nil

        /// 盯住 UIPageViewController 自己的滑动手势：本章最后一页还往前划，
        /// 或者第一页还往后划，就通知外层换章（原来只有点边缘才会换）
        func installSwipeHooks(on pager: UIPageViewController) {
            guard !swipeHooked else { return }
            let pans = Coordinator.collectPans(in: pager.view)
            let direct = pager.gestureRecognizers.compactMap { $0 as? UIPanGestureRecognizer }
            for pan in Set(pans + direct) {
                pan.addTarget(self, action: #selector(handlePanEnd(_:)))
            }
            // 边界那一下（本章最后一页再往前、第一页再往后）UIKit 没有下一页可给，
            // pan 手势可能不被识别，另挂两个 swipe 识别器兜底
            for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
                swipe.direction = direction
                swipe.cancelsTouchesInView = false
                pager.view.addGestureRecognizer(swipe)
            }
            swipeHooked = true
        }

        @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
            NSLog("[PageCurl] swipe dir=\(gesture.direction.rawValue) index=\(index) pages=\(parent.pages.count)")
            Coordinator.swipeHits += 1
            switch gesture.direction {
            case .left:
                if index >= parent.pages.count - 1 {
                    Coordinator.panHits += 1
                    parent.onReachEnd()
                }
            case .right:
                if index <= 0 {
                    Coordinator.panHits += 1
                    parent.onReachStart()
                }
            default:
                break
            }
        }

        /// pageCurl 的翻页手势挂在内部分页视图上，得整个视图树捞一遍
        static func collectPans(in view: UIView) -> [UIPanGestureRecognizer] {
            var found: [UIPanGestureRecognizer] = []
            for gr in view.gestureRecognizers ?? [] {
                if let pan = gr as? UIPanGestureRecognizer { found.append(pan) }
            }
            for sub in view.subviews {
                found.append(contentsOf: collectPans(in: sub))
            }
            return found
        }

        @objc private func handlePanEnd(_ pan: UIPanGestureRecognizer) {
            let view = pan.view ?? pan.view?.window
            NSLog("[PageCurl] pan state=\(pan.state.rawValue) tx=\(pan.translation(in: view).x) index=\(index) pages=\(parent.pages.count)")
            let translation = pan.translation(in: view)
            let velocity = pan.velocity(in: view)
            let forward = translation.x < -20 || velocity.x < -250
            let backward = translation.x > 20 || velocity.x > 250
            switch pan.state {
            case .changed:
                // 边界那一下 UIKit 没有下一页可给，手势结束时位移可能被清成 0，
                // 所以滑动过程中先记下「到头了」，真正换章等手指离开再做，
                // 免得卷页动画中途被打断
                if forward, index >= parent.pages.count - 1, translation.x < -50 {
                    boundaryForward = true
                } else if backward, index <= 0, translation.x > 50 {
                    boundaryBackward = true
                }
            case .ended, .cancelled, .failed:
                Coordinator.panEnds += 1
                if boundaryForward, forward || translation.x < -20 {
                    boundaryForward = false
                    Coordinator.panHits += 1
                    parent.onReachEnd()
                } else if boundaryBackward, backward || translation.x > 20 {
                    boundaryBackward = false
                    Coordinator.panHits += 1
                    parent.onReachStart()
                } else {
                    boundaryForward = false
                    boundaryBackward = false
                    if forward, index >= parent.pages.count - 1 {
                        Coordinator.panHits += 1
                        parent.onReachEnd()
                    } else if backward, index <= 0 {
                        Coordinator.panHits += 1
                        parent.onReachStart()
                    }
                }
            default:
                break
            }
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            // 选字状态：点任何位置先退出选字，不翻页
            if parent.charSelection != nil {
                parent.onTapCenter()
                return
            }
            // 热评页直接开段评；页面手势层会抢掉 SwiftUI 按钮的点击
            if index >= 0, index < parent.pages.count,
               let block = parent.pages[index].first,
               block.commentCount == -2 {
                if let url = block.commentURL {
                    parent.onCommentTap?(url)
                }
                return
            }
            // 气泡贴着左右翻页区也要先命中评论；否则贴边会直接翻页
            if let view = gesture.view {
                let point = view.convert(gesture.location(in: view), to: nil)
                if CoreTextUIView.triggerCommentTap(atWindowPoint: point) { return }
            }
            switch gesture.view?.tag {
            case 0:
                step(forward: false)
            case 2:
                step(forward: true)
            default:
                parent.onTapCenter()
            }
        }

        private func step(forward: Bool) {
            if forward {
                if index + 1 < parent.pages.count {
                    parent.onIndexChange(index + 1)
                } else {
                    Coordinator.tapHits += 1
                    parent.onReachEnd()
                }
            } else {
                if index > 0 {
                    parent.onIndexChange(index - 1)
                } else {
                    Coordinator.tapHits += 1
                    parent.onReachStart()
                }
            }
        }

        public func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            // 背面往左就是同一页的正面
            if viewController is UIHostingController<PageCurlBackPage> {
                return controller(at: viewController.view.tag)
            }
            let target = viewController.view.tag - 1
            return target >= 0 ? backController(at: target) : nil
        }

        public func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            if viewController is UIHostingController<PageCurlBackPage> {
                let next = viewController.view.tag + 1
                return next < parent.pages.count ? controller(at: next) : nil
            }
            // 最后一页往前划：不返回「本页背面」了，否则会卷出一张背面然后卡死在那儿，
            // 返回 nil 让手势直接落到 handlePanEnd，由它通知外层换章
            if viewController.view.tag >= parent.pages.count - 1 {
                return nil
            }
            return backController(at: viewController.view.tag)
        }

        public func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed, let controllers = pageViewController.viewControllers, !controllers.isEmpty else { return }
            // 双面模式下 viewControllers 可能同时含正面和背面，取正面那页的页码
            let front = controllers.first { $0 is UIHostingController<PageCurlContent> } ?? controllers[0]
            index = front.view.tag
            parent.onIndexChange(index)
        }
    }
}

/// 单页内容，交给 CoreTextPageView 画，跟左右翻页共用一套排版。
struct PageCurlContent: View {
    let blocks: [ContentBlock]
    /// 长按某一行（页内行号）—— 段落级选择的入口
    var onLongPressLine: ((Int, Int) -> Void)? = nil
    /// 选中与标注的绘制参数
    var selectedRange: (start: Int, count: Int)? = nil
    var charSelection: ReaderCharSelection? = nil
    var charAnnotations: [ReaderCharAnnotation] = []
    var annotationRanges: [(start: Int, count: Int, style: ReaderBlockStyle)] = []
    var commentMap: [Int: (count: Int, url: String)] = [:]
    var onCommentTap: ((String) -> Void)? = nil
    let chapterTitle: String?
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let letterSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let firstLineIndent: CGFloat
    let weightLevel: Int
    let chineseConversion: ChineseConversion
    let fontPostScriptName: String
    let boldPostScriptName: String?
    let textAlignment: ReaderTextAlignment
    let underlineEnabled: Bool
    let underlineColor: Color?
    let paragraphSeparatorLines: Int
    let paragraphSeparatorColor: Color
    let textColor: Color
    let backgroundColor: Color
    let backgroundImage: Image?
    let chapterTitleScale: CGFloat
    let shortTitleLength: Int
    let customDatePattern: String
    let customBarText: String
    let titleHTMLTemplate: String
    let titleProjectJSON: String
    let paddingTop: CGFloat
    let paddingBottom: CGFloat
    let paddingLeft: CGFloat
    let paddingRight: CGFloat
    let headerOffset: CGFloat
    let footerOffset: CGFloat
    let titleAlignment: ReaderTitleAlignment
    let showHeader: Bool
    let showFooter: Bool
    let barDivider: Bool
    let headerSlots: [[ReaderBarContent]]
    let footerSlots: [[ReaderBarContent]]
    let topInset: CGFloat
    let bottomInset: CGFloat
    let bookName: String
    let chapterTitleText: String
    let chapterIndex: Int
    let chapterCount: Int
    let pageIndex: Int
    let pageCount: Int

    /// 页眉页脚每栏要显示的文字，走和滚动阅读同一套格式化
    private func barText(_ content: ReaderBarContent, pageIndex: Int, pageCount: Int) -> String {
        var ctx = ReaderBarContext()
        ctx.bookName = bookName
        ctx.chapterTitle = chapterTitleText
        ctx.chapterIndex = chapterIndex
        ctx.chapterCount = chapterCount
        ctx.pageIndex = pageIndex
        ctx.pageCount = pageCount
        ctx.isPaged = true
        ctx.bookProgress = chapterCount > 0
            ? Double(chapterIndex) / Double(chapterCount)
                + (pageCount > 0 ? Double(pageIndex) / Double(pageCount) / Double(chapterCount) : 0)
            : 0
        ctx.shortTitleLength = shortTitleLength
        ctx.customDatePattern = customDatePattern
        ctx.customBarText = customBarText
        return readerBarText(content, ctx)
    }

    @ViewBuilder
    private func barSlot(_ slot: ReaderBarContent, alignment: Alignment) -> some View {
        switch slot {
        case .bookPercentBar, .batteryBar:
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(textColor.opacity(0.18))
                    Capsule()
                        .fill(textColor.opacity(0.65))
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, slot == .bookPercentBar
                            ? bookProgressFraction
                            : (ReaderBarBattery.level() ?? 0)))))
                }
            }
            .frame(height: 3)
            .frame(maxWidth: .infinity, alignment: alignment)
        case .batteryIcon, .batteryGlyphWithPercent:
            HStack(spacing: 3) {
                Image(systemName: batterySymbolName)
                if slot == .batteryGlyphWithPercent, let level = ReaderBarBattery.level() {
                    Text("\(Int((level * 100).rounded()))%")
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        default:
            Text(barText(slot, pageIndex: pageIndex, pageCount: pageCount))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    private var bookProgressFraction: Double {
        guard chapterCount > 0 else { return 0 }
        let chapterPart = Double(chapterIndex) / Double(chapterCount)
        let inChapter = pageCount > 0 ? Double(pageIndex) / Double(pageCount) / Double(chapterCount) : 0
        return min(1, chapterPart + inChapter)
    }

    private var batterySymbolName: String {
        guard let level = ReaderBarBattery.level() else { return "battery.0" }
        switch level {
        case ..<0.13: return "battery.0"
        case ..<0.38: return "battery.25"
        case ..<0.63: return "battery.50"
        case ..<0.88: return "battery.75"
        default: return "battery.100"
        }
    }

    @ViewBuilder
    private func pageBar(
        _ slots: [[ReaderBarContent]],
        pageIndex: Int,
        pageCount: Int,
        extendEdge: Edge.Set? = nil,
        topSpacer: CGFloat = 0,
        bottomSpacer: CGFloat = 0
    ) -> some View {
        VStack(spacing: 0) {
            // 给灵动岛/Home 指示条留的空白，让这条栏的底色顶到屏幕物理边缘
            if topSpacer > 0 {
                Color.clear.frame(height: topSpacer)
            }
            if barDivider {
                Rectangle()
                    .fill(textColor.opacity(0.12))
                    .frame(height: 0.5)
            }
            HStack(spacing: 8) {
                ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                    barSlotGroup(slot, alignment: index == 0 ? .leading : (index == 1 ? .center : .trailing))
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.8))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 18)
            if bottomSpacer > 0 {
                Color.clear.frame(height: bottomSpacer)
            }
        }
        .frame(height: 19 + topSpacer + bottomSpacer)
        .background(
            Group {
                if let edge = extendEdge {
                    backgroundColor.ignoresSafeArea(edges: edge)
                } else {
                    backgroundColor
                }
            }
        )
    }

    /// 一栏里可能塞了好几个组件，横着排开
    @ViewBuilder
    private func barSlotGroup(_ contents: [ReaderBarContent], alignment: Alignment) -> some View {
        let items = contents.filter { $0 != .none }
        if items.count == 1, let only = items.first {
            barSlot(only, alignment: alignment)
        } else {
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    barSlot(item, alignment: alignment)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let usableWidth = max(200, geo.size.width - paddingLeft - paddingRight)
            // 跟左右翻页同一套：「距顶/距底」是离屏幕物理边缘的绝对距离，0 = 贴边
            let headerGap = showHeader ? max(0, headerOffset) : 0
            let footerGap = showFooter ? max(0, footerOffset) : 0
            let barsHeight = (headerGap + 19) + (footerGap + 19)
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: headerGap + 19)
                contentBody(usableWidth: usableWidth, bodyHeight: geo.size.height)
                    .frame(height: max(80, geo.size.height - barsHeight), alignment: .top)
                    .clipped()
                Color.clear.frame(height: footerGap + 19)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .top) {
                if showHeader, headerSlots.count == 3 {
                    pageBar(headerSlots, pageIndex: pageIndex, pageCount: pageCount, extendEdge: .top)
                        .padding(.top, headerGap)
                }
            }
            .overlay(alignment: .bottom) {
                if showFooter, footerSlots.count == 3 {
                    pageBar(footerSlots, pageIndex: pageIndex, pageCount: pageCount, extendEdge: .bottom)
                        .padding(.bottom, footerGap)
                }
            }
        }
        // UIPageViewController 里的 SwiftUI 会按窗口安全区给自己留边，不忽略的话
        // 这一页的 0 点在灵动岛下方，「距顶 0」到不了屏幕上沿
        .ignoresSafeArea(edges: .all)
        .background(pageBackground)
    }

    /// 每页的底色 + 可选背景图，铺满整页
    @ViewBuilder
    private var pageBackground: some View {
        ZStack {
            backgroundColor
            if let backgroundImage {
                backgroundImage
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
    }

    @ViewBuilder
    private func contentBody(usableWidth: CGFloat, bodyHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
                if let chapterTitle, titleAlignment != .hidden {
                    if !titleHTMLTemplate.isEmpty {
                        // 存过设计稿就按设计稿渲染这一章的标题
                        ChapterTitleHTMLView(
                            htmlTemplate: titleHTMLTemplate,
                            projectJSON: titleProjectJSON,
                            width: max(120, usableWidth),
                            chapterTitle: chapterTitle,
                            chapterNumber: "第 \(chapterIndex + 1) 章"
                        )
                        .frame(maxWidth: .infinity, alignment: titleAlignment == .center ? .center : .leading)
                    } else {
                        Text(chapterTitle)
                            .font(.system(size: fontSize * chapterTitleScale, weight: .semibold))
                            .foregroundColor(textColor)
                            .padding(.bottom, 8)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: titleAlignment == .center ? .center : .leading)
                            .multilineTextAlignment(titleAlignment == .center ? .center : .leading)
                    }
                }

                if let block = blocks.first, block.commentCount == -2 {
                    GodReviewCardView(
                        text: block.text,
                        imageURL: block.imageUrl,
                        referer: nil
                    ) {
                        if let url = block.commentURL {
                            onCommentTap?(url)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if blocks.first?.isImage == true, let urlStr = blocks.first?.imageUrl {
                    ChapterImageView(urlString: urlStr, referer: nil)
                } else {
                    let lines = blocks.map { $0.text }
                    let isParagraphEnd = blocks.map { $0.imageUrl == "p_end" }
                    let trailingSpacing = isParagraphEnd.last == true ? 1 : 0
                    let paragraphCount = CGFloat(isParagraphEnd.filter { $0 }.count - trailingSpacing)
                    let effectiveLineHeight = fontSize * 1.25 + lineSpacing
                    let filledBase = CGFloat(lines.count) * effectiveLineHeight
                    // 一页排不满时把剩下的高度匀进段间距，正文才会贴到页脚（跟左右翻页同一套算法）
                    let titleReserved = pageIndex == 0 ? estimatedTitleHeight(usableWidth: usableWidth) : 0
                    let barsReserved = (showHeader ? 19 + max(0, headerOffset) : 0) + (showFooter ? 19 + max(0, footerOffset) : 0)
                    let available = max(80, bodyHeight - barsReserved - paddingTop - paddingBottom - titleReserved - 10)
                    // 余量要把段间距本身先扣掉再匀，否则整页会超出可用高度
                    let slack = max(0, available - filledBase - paragraphCount * paragraphSpacing)
                    let extraPerParagraph = paragraphCount > 0
                        ? min(slack / paragraphCount, effectiveLineHeight)
                        : 0
                    // 关掉「页末匀空白」就不匀
                    let appliedExtra = ReaderConfig.shared.justifyLastPage ? extraPerParagraph : 0
                    let contentHeight = filledBase
                        + paragraphCount * (paragraphSpacing + appliedExtra)

                    CoreTextPageView(
                        lines: lines,
                        isParagraphEnd: isParagraphEnd,
                        fontSize: fontSize,
                        lineSpacing: lineSpacing,
                        textColor: textColor,
                        width: usableWidth,
                        height: contentHeight,
                        letterSpacing: letterSpacing,
                        paragraphSpacing: paragraphSpacing + appliedExtra,
                        firstLineIndent: firstLineIndent,
                        weightLevel: weightLevel,
                        chineseConversion: chineseConversion,
                        fontPostScriptName: fontPostScriptName,
                        boldPostScriptName: boldPostScriptName,
                        textAlignment: textAlignment,
                        underlineEnabled: underlineEnabled,
                        underlineColor: underlineColor,
                        paragraphSeparatorLines: paragraphSeparatorLines,
                        paragraphSeparatorColor: paragraphSeparatorColor,
                        lineBlockIds: blocks.map(\.id),
                        lineParagraphIds: blocks.map(\.paragraphId),
                        lineCharStarts: blocks.map(\.charStart),
                        selectedRange: selectedRange,
                        charSelection: charSelection,
                        charAnnotations: charAnnotations,
                        annotationRanges: annotationRanges,
                        onLongPressLine: onLongPressLine,
                        commentMap: commentMap,
                        pageBackgroundColor: backgroundColor,
                        onCommentTap: onCommentTap
                    )
                    .frame(width: usableWidth, height: contentHeight, alignment: .topLeading)
                }

            }
            .padding(.leading, paddingLeft)
            .padding(.trailing, paddingRight)
            .padding(.top, paddingTop)
            .padding(.bottom, paddingBottom)
    }

    /// 首页标题占的高度：跟左右翻页用同一套估算
    private func estimatedTitleHeight(usableWidth: CGFloat) -> CGFloat {
        guard titleAlignment != .hidden, let title = chapterTitle else { return 0 }
        let titleFontSize = fontSize * chapterTitleScale
        let charsPerLine = max(4, Int(usableWidth / (titleFontSize + letterSpacing)))
        let lines = max(1, min(4, Int(ceil(Double(title.count) / Double(charsPerLine)))))
        return titleFontSize * 1.45 * CGFloat(lines) + 12.0
    }
}

/// 仿真翻页翻开后露出的背面：跟主题同色，靠书脊一侧压一道浅影
struct PageCurlBackPage: View {
    let backgroundColor: Color
    let backgroundImage: Image?
    let spineOnRight: Bool
    /// 翻起来的那张纸背面透出来的字（镜像 + 很淡，像墨透到背面）
    var faintLines: [String] = []
    var faintParagraphEnd: [Bool] = []
    var fontSize: CGFloat = 18
    var lineSpacing: CGFloat = 6
    var letterSpacing: CGFloat = 0
    var firstLineIndent: CGFloat = 0
    var weightLevel: Int = 1
    var chineseConversion: ChineseConversion = .none
    var fontPostScriptName: String = "PingFangSC-Regular"
    var boldPostScriptName: String? = "PingFangSC-Semibold"
    var textColor: Color = .black
    var paddingTop: CGFloat = 24
    var paddingBottom: CGFloat = 24
    var paddingLeft: CGFloat = 24
    var paddingRight: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backgroundColor
                if let backgroundImage {
                    backgroundImage
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }

                if !faintLines.isEmpty {
                    let bodyHeight = max(80, geo.size.height - paddingTop - paddingBottom)
                    let usableWidth = max(120, geo.size.width - paddingLeft - paddingRight)
                    CoreTextPageView(
                        lines: faintLines,
                        isParagraphEnd: faintParagraphEnd,
                        fontSize: fontSize,
                        lineSpacing: lineSpacing,
                        textColor: textColor,
                        width: usableWidth,
                        height: bodyHeight,
                        letterSpacing: letterSpacing,
                        paragraphSpacing: lineSpacing,
                        firstLineIndent: firstLineIndent,
                        weightLevel: weightLevel,
                        chineseConversion: chineseConversion,
                        fontPostScriptName: fontPostScriptName,
                        boldPostScriptName: boldPostScriptName,
                        textAlignment: .justify,
                        underlineEnabled: false,
                        underlineColor: nil
                    )
                    .frame(width: usableWidth, height: bodyHeight, alignment: .topLeading)
                    .padding(.leading, paddingLeft)
                    .padding(.trailing, paddingRight)
                    .padding(.top, paddingTop)
                    .scaleEffect(x: -1, y: 1)
                    .opacity(0.10)
                }

                LinearGradient(
                    colors: [Color.black.opacity(0.10), Color.black.opacity(0.0)],
                    startPoint: spineOnRight ? .trailing : .leading,
                    endPoint: spineOnRight ? .leading : .trailing
                )
                .frame(width: 26)
                .frame(maxWidth: .infinity, alignment: spineOnRight ? .trailing : .leading)
            }
        }
        .ignoresSafeArea()
    }
}
#endif
