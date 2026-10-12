#if os(iOS)
import SwiftUI
import UIKit

/// 仿真翻页：用 UIPageViewController 的 .pageCurl，就是系统书城那种卷页效果。
///
/// 只负责当前章的页面；翻过头或翻回来时通知外层换章。
public struct PageCurlPager: UIViewControllerRepresentable {
    public let pages: [[ContentBlock]]
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
    public let textColor: Color
    public let backgroundColor: Color
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
    public let headerSlots: [ReaderBarContent]
    public let footerSlots: [ReaderBarContent]
    public let bookName: String
    public let chapterTitleText: String
    public let chapterIndex: Int
    public let chapterCount: Int
    public let startIndex: Int
    public let onIndexChange: (Int) -> Void
    public let onReachEnd: () -> Void
    public let onReachStart: () -> Void
    public let onTapCenter: () -> Void

    public init(
        pages: [[ContentBlock]],
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
        textColor: Color,
        backgroundColor: Color,
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
        headerSlots: [ReaderBarContent],
        footerSlots: [ReaderBarContent],
        bookName: String,
        chapterTitleText: String,
        chapterIndex: Int,
        chapterCount: Int,
        startIndex: Int,
        onIndexChange: @escaping (Int) -> Void,
        onReachEnd: @escaping () -> Void,
        onReachStart: @escaping () -> Void,
        onTapCenter: @escaping () -> Void
    ) {
        self.pages = pages
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
        self.textColor = textColor
        self.backgroundColor = backgroundColor
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
        self.bookName = bookName
        self.chapterTitleText = chapterTitleText
        self.chapterIndex = chapterIndex
        self.chapterCount = chapterCount
        self.startIndex = startIndex
        self.onIndexChange = onIndexChange
        self.onReachEnd = onReachEnd
        self.onReachStart = onReachStart
        self.onTapCenter = onTapCenter
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
        if let first = context.coordinator.controller(at: clampedIndex) {
            controller.setViewControllers([first], direction: .forward, animated: false)
        }
        return controller
    }

    public func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        controller.view.backgroundColor = UIColor(backgroundColor)
        guard !pages.isEmpty else { return }

        // 配色、字体、排版这些变了要重建当前页，否则托管的页面还是旧样式
        let signature = renderSignature
        if context.coordinator.lastSignature != signature {
            context.coordinator.lastSignature = signature
            let current = context.coordinator.index
            if let rebuilt = context.coordinator.controller(at: current) {
                controller.setViewControllers([rebuilt], direction: .forward, animated: false)
            }
            return
        }

        let current = context.coordinator.index
        guard current != clampedIndex else { return }
        let direction: UIPageViewController.NavigationDirection = clampedIndex > current ? .forward : .reverse
        if let target = context.coordinator.controller(at: clampedIndex) {
            controller.setViewControllers([target], direction: direction, animated: true)
            context.coordinator.index = clampedIndex
        }
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
        parts.append("\(showHeader)\(showFooter)\(barDivider)")
        parts.append("\(paddingTop)/\(paddingBottom)/\(paddingLeft)/\(paddingRight)")
        parts.append("\(headerOffset)/\(footerOffset)")
        parts.append(headerSlots.map { $0.rawValue }.joined(separator: ","))
        parts.append(footerSlots.map { $0.rawValue }.joined(separator: ","))
        parts.append(chapterTitleText)
        parts.append(bookName)
        parts.append("\(chapterIndex)/\(chapterCount)")
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

        func controller(at index: Int) -> UIViewController? {
            guard index >= 0, index < parent.pages.count else { return nil }
            let page = parent.pages[index]
            let host = UIHostingController(rootView: PageCurlContent(
                blocks: page,
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
                textColor: parent.textColor,
                backgroundColor: parent.backgroundColor,
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

        /// 卷起来时露出的那一面：用主题底色 + 靠书脊的浅阴影，不再是一张白纸
        func backController(at index: Int) -> UIViewController? {
            guard index >= 0, index < parent.pages.count else { return nil }
            let back = UIHostingController(rootView: PageCurlBackPage(
                backgroundColor: parent.backgroundColor,
                spineOnRight: false
            ))
            back.view.backgroundColor = UIColor(parent.backgroundColor)
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

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
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
                    parent.onReachEnd()
                }
            } else {
                if index > 0 {
                    parent.onIndexChange(index - 1)
                } else {
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
    let textColor: Color
    let backgroundColor: Color
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
    let headerSlots: [ReaderBarContent]
    let footerSlots: [ReaderBarContent]
    let bookName: String
    let chapterTitleText: String
    let chapterIndex: Int
    let chapterCount: Int
    let pageIndex: Int
    let pageCount: Int

    /// 页眉页脚每栏要显示的文字
    private func barText(_ content: ReaderBarContent, pageIndex: Int, pageCount: Int) -> String {
        switch content {
        case .none:
            return ""
        case .chapterTitle:
            return chapterTitleText
        case .bookName:
            return bookName
        case .progress:
            guard chapterCount > 0 else { return "" }
            let percent = Double(chapterIndex + 1) / Double(chapterCount) * 100
            return String(format: "%.1f%%", percent)
        case .pageInfo:
            if pageCount > 0 {
                return "\(pageIndex + 1)/\(pageCount)"
            }
            return chapterCount > 0 ? "\(chapterIndex + 1)/\(chapterCount)" : ""
        case .time:
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: Date())
        }
    }

    @ViewBuilder
    private func pageBar(
        _ slots: [ReaderBarContent],
        pageIndex: Int,
        pageCount: Int,
        extendEdge: Edge.Set? = nil
    ) -> some View {
        VStack(spacing: 0) {
            if barDivider {
                Rectangle()
                    .fill(textColor.opacity(0.12))
                    .frame(height: 0.5)
            }
            HStack(spacing: 8) {
                ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                    Text(barText(slot, pageIndex: pageIndex, pageCount: pageCount))
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity,
                               alignment: index == 0 ? .leading : (index == 1 ? .center : .trailing))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 18)
        }
        .frame(height: 19)
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

    var body: some View {
        GeometryReader { geo in
            let usableWidth = max(200, geo.size.width - paddingLeft - paddingRight)
            VStack(alignment: .leading, spacing: 0) {
                if showHeader, headerSlots.count == 3 {
                    pageBar(headerSlots, pageIndex: pageIndex, pageCount: pageCount, extendEdge: .top)
                        .padding(.top, headerOffset)
                }
                contentBody(usableWidth: usableWidth)
                Spacer(minLength: 0)
                if showFooter, footerSlots.count == 3 {
                    pageBar(footerSlots, pageIndex: pageIndex, pageCount: pageCount, extendEdge: .bottom)
                        .padding(.bottom, footerOffset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(backgroundColor)
    }

    @ViewBuilder
    private func contentBody(usableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
                if let chapterTitle, titleAlignment != .hidden {
                    Text(chapterTitle)
                        .font(.system(size: fontSize + 3, weight: .bold))
                        .foregroundColor(textColor)
                        .padding(.bottom, 8)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: titleAlignment == .center ? .center : .leading)
                        .multilineTextAlignment(titleAlignment == .center ? .center : .leading)
                }

                if blocks.first?.isImage == true, let urlStr = blocks.first?.imageUrl {
                    ChapterImageView(urlString: urlStr, referer: nil)
                } else {
                    let lines = blocks.map { $0.text }
                    let isParagraphEnd = blocks.map { $0.imageUrl == "p_end" }
                    let paragraphCount = CGFloat(isParagraphEnd.filter { $0 }.count)
                    let contentHeight = CGFloat(lines.count) * (fontSize * 1.25 + lineSpacing)
                        + paragraphCount * paragraphSpacing

                    CoreTextPageView(
                        lines: lines,
                        isParagraphEnd: isParagraphEnd,
                        fontSize: fontSize,
                        lineSpacing: lineSpacing,
                        textColor: textColor,
                        width: usableWidth,
                        height: contentHeight,
                        letterSpacing: letterSpacing,
                        paragraphSpacing: paragraphSpacing,
                        firstLineIndent: firstLineIndent,
                        weightLevel: weightLevel,
                        chineseConversion: chineseConversion,
                        fontPostScriptName: fontPostScriptName,
                        boldPostScriptName: boldPostScriptName
                    )
                    .frame(width: usableWidth, height: contentHeight, alignment: .topLeading)
                }

            }
            .padding(.leading, paddingLeft)
            .padding(.trailing, paddingRight)
            .padding(.top, paddingTop)
            .padding(.bottom, paddingBottom)
    }
}

/// 仿真翻页翻开后露出的背面：跟主题同色，靠书脊一侧压一道浅影
struct PageCurlBackPage: View {
    let backgroundColor: Color
    let spineOnRight: Bool

    var body: some View {
        ZStack {
            backgroundColor
            LinearGradient(
                colors: [Color.black.opacity(0.10), Color.black.opacity(0.0)],
                startPoint: spineOnRight ? .trailing : .leading,
                endPoint: spineOnRight ? .leading : .trailing
            )
            .frame(width: 26)
            .frame(maxWidth: .infinity, alignment: spineOnRight ? .trailing : .leading)
        }
        .ignoresSafeArea()
    }
}
#endif
