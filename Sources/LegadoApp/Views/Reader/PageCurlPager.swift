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
    public let horizontalPadding: CGFloat
    public let verticalPadding: CGFloat
    public let titleAlignment: ReaderTitleAlignment
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
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat,
        titleAlignment: ReaderTitleAlignment,
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
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.titleAlignment = titleAlignment
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
        controller.isDoubleSided = false
        if let first = context.coordinator.controller(at: clampedIndex) {
            controller.setViewControllers([first], direction: .forward, animated: false)
        }
        return controller
    }

    public func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard !pages.isEmpty else { return }
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

    public final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlPager
        var index: Int

        init(_ parent: PageCurlPager) {
            self.parent = parent
            self.index = min(max(0, parent.startIndex), max(0, parent.pages.count - 1))
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
                horizontalPadding: parent.horizontalPadding,
                verticalPadding: parent.verticalPadding,
                titleAlignment: parent.titleAlignment
            ))
            host.view.backgroundColor = UIColor(parent.backgroundColor)
            host.view.tag = index
            installTapZones(on: host.view)
            return host
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
            let target = viewController.view.tag - 1
            return controller(at: target)
        }

        public func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            let target = viewController.view.tag + 1
            return controller(at: target)
        }

        public func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed, let current = pageViewController.viewControllers?.first else { return }
            index = current.view.tag
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
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let titleAlignment: ReaderTitleAlignment

    var body: some View {
        GeometryReader { geo in
            let usableWidth = max(200, geo.size.width - horizontalPadding * 2)
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

                Spacer(minLength: 0)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, verticalPadding)
            .padding(.bottom, verticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(backgroundColor)
    }
}
#endif
