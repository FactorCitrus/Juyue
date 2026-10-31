import SwiftUI
import AVFoundation
import CoreText
import UniformTypeIdentifiers
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 阅读背景图读一次盘就缓存住：正文每次重绘都去读文件会卡。
/// 页眉页脚选内容的芯片网格。
/// 23 个选项塞进 Menu 太长，铺成自适应网格更好点。
/// 可折叠设置块：默认收起只留标题，点开才渲染里面的控件
/// （设置卡片一屏堆满控件在真机上很吃渲染，能折的都折起来）
struct CollapsibleSettingBlock: View {
    let title: String
    let tint: Color
    let initiallyExpanded: Bool
    let summary: String?
    /// 展开/收起回调：热评卡片块展开时把设置面板变透明，方便直接看字卡
    let onExpandedChange: ((Bool) -> Void)?
    /// 内容闭包返回 AnyView：面板的泛型类型不再把整棵内容树嵌进类型名。
    /// iOS 27 的 Swift 运行时解码超深泛型名会栈溢出，点「界面」时直接闪退。
    private let content: () -> AnyView

    @State private var expanded: Bool

    /// initiallyExpanded = true 的块等于不折：进来就把内容铺出来
    init(
        title: String,
        tint: Color,
        initiallyExpanded: Bool = false,
        summary: String? = nil,
        onExpandedChange: ((Bool) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> some View
    ) {
        self._expanded = State(initialValue: initiallyExpanded)
        self.title = title
        self.tint = tint
        self.initiallyExpanded = initiallyExpanded
        self.summary = summary
        self.onExpandedChange = onExpandedChange
        self.content = { AnyView(content()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                onExpandedChange?(expanded)
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(tint.opacity(0.75))
                        .frame(width: 2.5, height: 12)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(tint.opacity(0.85))
                    Spacer()
                    if !expanded, let summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(tint.opacity(0.55))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Text(expanded ? "收起" : "展开")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(tint.opacity(0.5))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(tint.opacity(0.5))
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                content()
            }
        }
    }
}

/// 阅读设置卡片的整套外观压成一个 modifier。
/// 原来 10 层 .background/.overlay/.clipShape 串在卡片类型上，iOS 27 解码类型名会栈溢出。
private struct ReaderSettingsCardChrome: ViewModifier {
    let radius: CGFloat
    let fill: Color
    let showsMaterial: Bool
    let ink: Color
    let backdrop: Color
    let layerOpacity: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            styled(
                content,
                shape: UnevenRoundedRectangle(
                    topLeadingRadius: radius,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: radius,
                    style: .continuous
                )
            )
        } else {
            styled(content, shape: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    private func styled<S: Shape>(_ content: Content, shape: S) -> some View {
        content
            .background(
                shape
                    .fill(fill)
                    .overlay(
                        Group {
                            if showsMaterial {
                                shape.fill(.ultraThinMaterial)
                            }
                        }
                    )
            )
            .overlay(shape.stroke(ink.opacity(0.08), lineWidth: 0.5))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.16), radius: 18, y: -6)
            .background(
                backdrop
                    .opacity(layerOpacity)
                    .shadow(color: Color.black.opacity(0.2), radius: 16, x: 0, y: -6)
                    .ignoresSafeArea(edges: .bottom)
            )
            .clipShape(shape)
            .overlay(shape.stroke(ink.opacity(0.10), lineWidth: 0.5))
    }
}

/// 收起态的「页眉/页脚内容」行：摘要 + 展开按钮，展开后才渲染芯片网格
struct ReaderBarPickerRow: View {
    let title: String
    @Binding var selection: [ReaderBarContent]
    let tint: Color

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(tint.opacity(0.7))
                Spacer()
                Text(selection.isEmpty ? "空" : selection.map { $0.rawValue }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundColor(tint.opacity(0.5))
                    .lineLimit(1)
                Button(expanded ? "收起" : "选择") {
                    expanded.toggle()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint.opacity(0.8))
            }
            if expanded {
                ReaderBarItemGrid(selection: $selection, items: ReaderBarContent.allCases, tint: tint)
            }
        }
    }
}

public struct ReaderBarItemGrid: View {
    @Binding var selection: [ReaderBarContent]
    let items: [ReaderBarContent]
    let tint: Color

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 76), spacing: 6)]
    }

    public init(selection: Binding<[ReaderBarContent]>, items: [ReaderBarContent], tint: Color) {
        self._selection = selection
        self.items = items
        self.tint = tint
    }

    public var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                let isOn = item == .none ? selection.isEmpty : selection.contains(item)
                Button {
                    toggle(item)
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(tint.opacity(isOn ? 0.22 : 0.07))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(tint.opacity(isOn ? 0.45 : 0), lineWidth: 1)
                        )
                        .foregroundColor(isOn ? tint : tint.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 点一下加进去，再点一下拿出来；「无」等于清空这一栏。
    private func toggle(_ item: ReaderBarContent) {
        if item == .none {
            selection = []
            return
        }
        if let index = selection.firstIndex(of: item) {
            selection.remove(at: index)
        } else {
            selection.append(item)
        }
    }
}

final class ReaderBackgroundImageCache {
    static let shared = ReaderBackgroundImageCache()
    private var images: [String: Image] = [:]

    func image(for path: String) -> Image? { images[path] }
    func store(_ image: Image, for path: String) { images[path] = image }
    func removeAll() { images.removeAll() }
}

/// 按配置挑正文字体：优先用对应字重，找不到就派生加粗，再不行退回系统默认。
public enum ReaderFontFactory {
    public static func ctFont(
        postScriptName: String,
        boldPostScriptName: String?,
        size: CGFloat,
        weightLevel: Int
    ) -> CTFont {
        let baseName = postScriptName.isEmpty ? "PingFangSC-Regular" : postScriptName
        let font = CTFontCreateWithName(baseName as CFString, size, nil)

        if weightLevel <= 0 {
            // kCTFontWeightTrait 的刻度：-0.4 细、0 常规、0.4 粗
            return applyWeight(-0.4, to: font, size: size)
        }

        guard weightLevel >= 2 else { return font }

        if let boldName = boldPostScriptName, !boldName.isEmpty {
            let candidate = CTFontCreateWithName(boldName as CFString, size, nil)
            let resolved = CTFontCopyPostScriptName(candidate) as String
            if resolved.caseInsensitiveCompare(boldName) == .orderedSame {
                return candidate
            }
        }
        return applyWeight(0.4, to: font, size: size)
    }

    private static func applyWeight(_ weight: CGFloat, to font: CTFont, size: CGFloat) -> CTFont {
        let traits: [CFString: Any] = [kCTFontWeightTrait: weight]
        let attributes: [CFString: Any] = [kCTFontTraitsAttribute: traits]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, size, nil, descriptor)
    }
}

#if os(iOS)
/// 下拉背景的几何只算一次：以整屏为画布，图片按短边填满画布后再乘缩放，
/// 对齐只决定这张图往画布的顶 / 中 / 底靠。阅读页与外观预览共用，避免两边各算一套。
struct PullBackgroundCanvas: View {
    let image: UIImage
    let zoom: Double
    let offsetX: Double
    let offsetY: Double
    let alignment: Int

    var body: some View {
        GeometryReader { geo in
            let canvas = geo.size
            let imageSize = image.size
            let fill = max(canvas.width / max(1, imageSize.width),
                           canvas.height / max(1, imageSize.height))
            let factor = fill * CGFloat(max(0.05, zoom))
            let width = max(1, imageSize.width * factor)
            let height = max(1, imageSize.height * factor)
            let x = (canvas.width - width) / 2 + CGFloat(offsetX)
            let y: CGFloat = {
                switch alignment {
                case 2: return canvas.height - height + CGFloat(offsetY)
                case 1: return (canvas.height - height) / 2 + CGFloat(offsetY)
                default: return CGFloat(offsetY)
                }
            }()

            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: width, height: height)
                .position(x: x + width / 2, y: y + height / 2)
        }
        .clipped()
    }
}

/// 下拉加书签的手势识别器（挂在宿主视图上，四种翻页模式都能用）。
///
/// 为什么不用 SwiftUI 手势：分页那几套模式各自装了 UIPanGestureRecognizer，SwiftUI 层的
/// 竖直拖拽会被它们吃掉；而挂在最外层又会把画布「零位移拖拽 = 点击」抢走（点中间呼不出菜单）。
/// UIKit 层的识别器设成「不取消触摸 + 允许同时识别」，只认竖直向下，就能跟翻页、点击共存。
struct ReaderPullDownCatcher: UIViewRepresentable {
    var isEnabled: () -> Bool
    var isAtTop: () -> Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, Bool) -> Void
    /// 窗口坐标系里的长按（滚动模式用；分页模式走正文视图自己的识别器）
    var onLongPress: (CGPoint) -> Void = { _ in }
    /// 字选手柄：按下时命中哪个手柄（返回 true 表示这次拖拽归手柄）
    var onCharHandleHit: ((CGPoint) -> Bool)? = nil
    /// 字选手柄拖动中的窗口坐标
    var onCharHandleDrag: ((CGPoint) -> Void)? = nil
    /// 单击（窗口坐标）。只旁听，不取消触摸；听书状态在回调里自己判
    var onTap: ((CGPoint) -> Void)? = nil

    /// `.background` 里这层只是个占位，进窗口后由它把识别器挪到 UIWindow 上。
    final class CatcherHostView: UIView {
        var onWindow: ((UIWindow) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: () -> Bool = { true }
        var isAtTop: () -> Bool = { true }
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: (CGFloat, Bool) -> Void = { _, _ in }
        var onLongPress: (CGPoint) -> Void = { _ in }
        var onCharHandleHit: ((CGPoint) -> Bool)?
        var onCharHandleDrag: ((CGPoint) -> Void)?
        var onTap: ((CGPoint) -> Void)?
        private var charDragging = false
        weak var recognizer: UIPanGestureRecognizer?
        weak var longPress: UILongPressGestureRecognizer?
        weak var tap: UITapGestureRecognizer?
        /// 这一次拖拽已经判定成「下拉」：判定一次就认到底，避免慢速下拉时逐帧反复翻转
        private var startedAsPull = false

        func attach(to host: UIView) {
            guard recognizer == nil else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            pan.delegate = self
            // 关键：不取消触摸，翻页/点击照常收到；识别器只旁听
            pan.cancelsTouchesInView = false
            pan.maximumNumberOfTouches = 1
            host.addGestureRecognizer(pan)
            recognizer = pan

            let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
            press.delegate = self
            press.minimumPressDuration = 0.35
            // 长按期间手指多少会滑一点，放宽到 22pt 才判失败
            press.allowableMovement = 22
            press.cancelsTouchesInView = false
            host.addGestureRecognizer(press)
            longPress = press

            // 单击不再挂在这一层：分页器的零位移收尾、滚动视图自己的点按都已经在管，
            // window 层再挂一个会和它们对拼，一次点按 toggle 两回、菜单一闪就没。
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            AppLog.write("[下拉] tap 收到 · coord=\(ObjectIdentifier(self))")
            onTap?(gesture.location(in: gesture.view))
        }

        @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            let point = gesture.location(in: gesture.view)
            AppLog.write("[下拉] 长按收到（真触摸）· \(Int(point.x)),\(Int(point.y))")
            onLongPress(point)
        }

        @objc private func handle(_ gesture: UIPanGestureRecognizer) {
            if charDragging {
                let point = gesture.location(in: gesture.view)
                switch gesture.state {
                case .changed, .ended:
                    onCharHandleDrag?(point)
                case .cancelled, .failed:
                    break
                default:
                    break
                }
                if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                    charDragging = false
                }
                return
            }
            let t = gesture.translation(in: gesture.view)
            let dy = t.y
            switch gesture.state {
            case .began:
                startedAsPull = true
            case .changed:
                onChanged(startedAsPull ? max(0, dy) : 0)
            case .ended, .cancelled, .failed:
                let passed = startedAsPull && dy >= 40
                startedAsPull = false
                onEnded(dy, passed)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer else {
                // 长按：只受「是否允许」控制（下拉那套起手方向判定不适用）
                return isEnabled()
            }
            guard let view = pan.view else { return false }
            if let onCharHandleHit, onCharHandleHit(pan.location(in: view)) {
                charDragging = true
                return true
            }
            guard isEnabled(), isAtTop() else { return false }
            let t = pan.translation(in: view)
            // 起手只看「向下」：鼠标/手指起手常带横向抖动。慢速下拉时 translation 还很小，
            // 门槛压到 4pt；方向是否竖直只看这一次的起手方向，之后不再逐帧重判。
            return t.y > 4 && t.y >= abs(t.x)
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = CatcherHostView()
        // 只旁听，不吃触摸。真正接触摸的是挂在 window 上的识别器。
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        coordinator.isEnabled = isEnabled
        coordinator.isAtTop = isAtTop
        coordinator.onChanged = onChanged
        coordinator.onEnded = onEnded
        coordinator.onLongPress = onLongPress
        coordinator.onCharHandleHit = onCharHandleHit
        coordinator.onCharHandleDrag = onCharHandleDrag
        coordinator.onTap = onTap
        // 这是整个问题的根：.background 里的这个 view 是正文的**兄弟**，不是祖先。
        // UIKit 只把触摸送给命中视图的祖先链，兄弟永远收不到——挂在它（或它的 superview）上
        // 等于没挂，真手指长按一辈子进不来。所以改成等它进窗口后挂到 UIWindow 上。
        view.onWindow = { [weak coordinator] window in
            guard let coordinator else { return }
            coordinator.attach(to: window)
            AppLog.write("[下拉] 识别器挂到 window · coord=\(ObjectIdentifier(coordinator))")
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.isAtTop = isAtTop
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onCharHandleHit = onCharHandleHit
        context.coordinator.onCharHandleDrag = onCharHandleDrag
        context.coordinator.onTap = onTap
        // makeUIView 那一刻背景层还没进视图层级，window 和 superview 都可能还是 nil，
        // 识别器就没挂上；之后屏幕上的点击会落到上一次那个已经销毁的实例的识别器上，
        // 日志照写、改的却是死状态，界面一动不动。这里补挂一次。
        if context.coordinator.recognizer == nil, let window = uiView.window {
            context.coordinator.attach(to: window)
            AppLog.write("[下拉] 补挂识别器到 window · coord=\(ObjectIdentifier(context.coordinator))")
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let recognizer = coordinator.recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        if let press = coordinator.longPress {
            press.view?.removeGestureRecognizer(press)
        }
        if let tap = coordinator.tap {
            tap.view?.removeGestureRecognizer(tap)
        }
    }
}
#endif

/// 书签绶带：矩形 + 底部三角缺口，落在页顶当书签用
/// 段评气泡：左侧尖角 + 圆角矩形，跟正文纸色融合。
struct ReaderCommentBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let tailWidth: CGFloat = 6
        let tailHeight: CGFloat = 11
        let radius: CGFloat = 5
        let body = CGRect(x: tailWidth, y: 0,
                          width: max(1, rect.width - tailWidth),
                          height: rect.height)
        var path = Path(roundedRect: body, cornerRadius: radius)
        let midY = rect.midY
        path.move(to: CGPoint(x: tailWidth, y: midY - tailHeight / 2))
        path.addLine(to: CGPoint(x: 0, y: midY))
        path.addLine(to: CGPoint(x: tailWidth, y: midY + tailHeight / 2))
        path.closeSubpath()
        return path
    }
}

struct BookmarkRibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.30))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 段落级阅读标注：下划线 / 底色。跨平台放顶层，iOS 与 macOS 的正文视图都用它。
public struct ReaderBlockStyle: Equatable {
    public var underline: Bool
    public var underlineHex: String?
    public var highlightHex: String?

    public init(underline: Bool = false, underlineHex: String? = nil, highlightHex: String? = nil) {
        self.underline = underline
        self.underlineHex = underlineHex
        self.highlightHex = highlightHex
    }
}

/// 段内逐字选择：段落 id + 段内字符起点 + 字符数（UTF-16 偏移，跟 BookBookmark 一致）
public struct ReaderCharSelection: Equatable {
    public var paragraphId: Int
    public var start: Int
    public var length: Int

    public init(paragraphId: Int, start: Int, length: Int) {
        self.paragraphId = paragraphId
        self.start = start
        self.length = length
    }
}

/// 段内逐字标注：只画选中的那几个字，不再铺满整行
public struct ReaderCharAnnotation: Equatable {
    public var paragraphId: Int
    public var start: Int
    public var length: Int
    public var style: ReaderBlockStyle

    public init(paragraphId: Int, start: Int, length: Int, style: ReaderBlockStyle) {
        self.paragraphId = paragraphId
        self.start = start
        self.length = length
        self.style = style
    }
}

public struct ContentBlock: Identifiable {
    public let id: Int
    public let isImage: Bool
    public let text: String
    public let imageUrl: String?
    /// 这一行属于哪个原始段落（章节 blocks 里的 id）
    public var paragraphId: Int = 0
    /// 这一行在所属段落里的字符起点（UTF-16）
    public var charStart: Int = 0
    /// 段评数量；-1 表示这一条是「本章说」入口
    public var commentCount: Int = 0
    /// 段评 / 本章说的源站地址
    public var commentURL: String? = nil
}

public struct LoadedChapter: Identifiable {
    public var id: Int { chapter.index }
    public let chapter: BookChapter
    public var content: String
    public var blocks: [ContentBlock]
    public var pages: [[ContentBlock]] = []
}

/// 热评卡片：滚动、分页、仿真共用。文字和可选插图都在这里画。
/// 热评卡片的可调外观。设置面板改这里，分页/绘制两条路径读同一份。
public struct ReviewCardStyle: Equatable {
    public var fontScale: CGFloat
    public var inset: CGFloat
    public var opacity: CGFloat
    /// 0 纸面卡 / 1 左线卡 / 2 无框
    public var style: Int
    /// 0 左对齐 / 1 居中
    public var alignment: Int
    /// 0 尼尔墨色 / 1 氧化红 / 2 跟随正文
    public var textColorMode: Int
    /// 热评文字在卡片里的垂直偏移，正数往下
    public var textDrop: CGFloat

    public init(fontScale: CGFloat = 0.82,
                inset: CGFloat = 12,
                opacity: CGFloat = 1,
                style: Int = 0,
                alignment: Int = 0,
                textColorMode: Int = 0,
                textDrop: CGFloat = 2.5) {
        self.fontScale = fontScale
        self.inset = inset
        self.opacity = opacity
        self.style = style
        self.alignment = alignment
        self.textColorMode = textColorMode
        self.textDrop = textDrop
    }
}

/// 热评样式的实时预览：跟正文里那条卡片同一套参数，改哪一项当场能看到。
struct ReviewStylePreview: View {
    let style: ReviewCardStyle
    let palette: NieRPalette
    let accent: Color
    let pageColor: Color
    /// 正文的正文色 / 字号 / 行距 / 段距：预览必须跟阅读页同一套，不然调完对不上
    let readerTextColor: Color
    let baseFontSize: CGFloat
    let readerLineSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let readerFontName: String
    var sample: String = "热评 · 这个重重的关上门真的全是细节，她作为曾经的地级，身上藏着的东西比谁都多……"

    private var paper: Color {
        palette.isDark ? Color(hex: "#23241F") ?? .black : Color(hex: "#F2ECDE") ?? .white
    }

    private var cardPad: CGFloat {
        min(14, max(8, paragraphSpacing + 1))
    }

    private var textColor: Color {
        switch style.textColorMode {
        case 1: return accent
        case 2: return readerTextColor
        default: return palette.ink
        }
    }

    var body: some View {
        content
            .padding(.horizontal, max(0, style.inset))
            .padding(.vertical, cardPad)
            .background(cardBackground)
            .overlay(cardFrame)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(pageColor)
    }

    private var content: some View {
        Text(sample)
            .font(.custom(readerFontName, size: baseFontSize * style.fontScale))
            .foregroundColor(textColor)
            .lineSpacing(readerLineSpacing)
            .multilineTextAlignment(style.alignment == 1 ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: style.alignment == 1 ? .center : .leading)
            .offset(y: style.textDrop)
    }

    @ViewBuilder
    private var cardBackground: some View {
        switch style.style {
        case 1:
            Rectangle().fill(paper.opacity(0.55 * style.opacity))
        case 2:
            Rectangle().fill(accent.opacity(0.09 * style.opacity))
        default:
            ZStack {
                Rectangle().fill(paper)
                Rectangle().fill(pageColor.opacity((palette.isDark ? 0.12 : 0.18) * style.opacity))
                Rectangle().fill(accent.opacity((palette.isDark ? 0.06 : 0.04) * style.opacity))
            }
        }
    }

    @ViewBuilder
    private var cardFrame: some View {
        switch style.style {
        case 1:
            HStack(spacing: 0) {
                Rectangle().fill(accent.opacity(style.opacity)).frame(width: 3)
                Spacer(minLength: 0)
            }
        case 2:
            EmptyView()
        default:
            ZStack {
                Rectangle().stroke(palette.line.opacity(style.opacity), lineWidth: 0.8)
                Rectangle()
                    .stroke(accent.opacity(0.26 * style.opacity), lineWidth: 0.5)
                    .padding(3.5)
                    .mask(
                        VStack(spacing: 0) {
                            Rectangle().frame(height: 1)
                            Spacer()
                            Rectangle().frame(height: 1)
                        }
                    )
                HStack {
                    Rectangle().fill(accent.opacity(style.opacity)).frame(width: 2).padding(.vertical, 9).padding(.leading, 4.5)
                    Spacer(minLength: 0)
                }
                cornerMarks
            }
        }
    }

    private var cornerMarks: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { corner in
                let top = corner < 2
                let leading = corner % 2 == 0
                ZStack(alignment: Alignment(horizontal: leading ? .leading : .trailing,
                                            vertical: top ? .top : .bottom)) {
                    Rectangle().fill(accent).frame(width: 11, height: 1.6)
                    Rectangle().fill(accent).frame(width: 1.6, height: 11)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: Alignment(horizontal: leading ? .leading : .trailing,
                                            vertical: top ? .top : .bottom))
            }
        }
    }
}

/// 热评样式面板：上面预览，下面调参数，跟书架那套「先看效果再调」一致。
struct ReviewStyleSheet: View {
    @ObservedObject var config: ReaderConfig
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let palette = NieRPalette(colorScheme)
        ZStack {
            NieRBackdrop(palette: palette)
            VStack(spacing: 0) {
                NieRSheetHeader(
                    palette: palette,
                    kicker: "HOT REVIEW // STYLE",
                    title: "热评样式",
                    subtitle: "PREVIEW · LIVE"
                ) {
                    dismiss()
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        ReviewStylePreview(
                            style: currentStyle,
                            palette: palette,
                            accent: palette.accent,
                            pageColor: config.backgroundColor,
                            readerTextColor: config.textColor,
                            baseFontSize: config.fontSize,
                            readerLineSpacing: config.lineSpacing,
                            paragraphSpacing: config.paragraphSpacing,
                            readerFontName: config.font.postScriptName
                        )
                        .overlay(Rectangle().stroke(palette.line.opacity(0.5), lineWidth: 0.5))
                        .padding(.horizontal, 16)

                        VStack(alignment: .leading, spacing: 14) {
                            sliderRow("字号", value: Binding(
                                get: { config.reviewFontScale },
                                set: { config.reviewFontScale = $0 }
                            ), range: 0.65...1.15, suffix: "×", palette: palette)
                            sliderRow("内边距", value: Binding(
                                get: { config.reviewInset },
                                set: { config.reviewInset = $0 }
                            ), range: 6...28, suffix: "pt", palette: palette)
                            sliderRow("透明度", value: Binding(
                                get: { config.reviewCardOpacity },
                                set: { config.reviewCardOpacity = $0 }
                            ), range: 0.2...1, suffix: "", palette: palette)
                            sliderRow("文字位置", value: Binding(
                                get: { config.reviewTextDrop },
                                set: { config.reviewTextDrop = $0 }
                            ), range: -2...6, suffix: "pt", palette: palette)

                            chipRow(palette: palette, title: "样式", options: ["纸面卡", "左线卡", "无框"],
                                    selected: config.reviewCardStyle) { config.reviewCardStyle = $0 }
                            chipRow(palette: palette, title: "文字色", options: ["尼尔墨", "氧化红", "跟正文"],
                                    selected: config.reviewTextColorMode) { config.reviewTextColorMode = $0 }
                            chipRow(palette: palette, title: "对齐", options: ["左对齐", "居中"],
                                    selected: config.reviewAlignment) { config.reviewAlignment = $0 }

                            Button {
                                config.reviewFontScale = 0.82
                                config.reviewInset = 12
                                config.reviewCardOpacity = 1
                                config.reviewCardStyle = 0
                                config.reviewAlignment = 0
                                config.reviewTextColorMode = 0
                                config.reviewTextDrop = 2.5
                            } label: {
                                Text("恢复默认")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(palette.accent)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .overlay(Rectangle().stroke(palette.accent.opacity(0.5), lineWidth: 0.8))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var currentStyle: ReviewCardStyle {
        ReviewCardStyle(
            fontScale: config.reviewFontScale,
            inset: config.reviewInset,
            opacity: config.reviewCardOpacity,
            style: config.reviewCardStyle,
            alignment: config.reviewAlignment,
            textColorMode: config.reviewTextColorMode,
            textDrop: config.reviewTextDrop
        )
    }

    private func sliderRow(_ title: String, value: Binding<CGFloat>,
                           range: ClosedRange<CGFloat>, suffix: String, palette: NieRPalette) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(palette.ink.opacity(0.7))
                .frame(width: 52, alignment: .leading)
            Slider(value: Binding(
                get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
                set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
            ), in: range)
                .tint(palette.accent)
            Text(suffix == "×"
                 ? String(format: "%.2f×", Double(value.wrappedValue))
                 : suffix.isEmpty
                    ? "\(Int((value.wrappedValue * 100).rounded()))%"
                    : "\(Int(value.wrappedValue.rounded()))\(suffix)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(palette.accent)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func chipRow(palette: NieRPalette, title: String, options: [String],
                         selected: Int, action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(palette.ink.opacity(0.7))
                .frame(width: 52, alignment: .leading)
            ForEach(options.indices, id: \.self) { index in
                Button {
                    action(index)
                } label: {
                    Text(options[index])
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(selected == index ? palette.accent : palette.ink.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Rectangle().fill(palette.accent.opacity(selected == index ? 0.16 : 0.05)))
                        .overlay(Rectangle().stroke(palette.accent.opacity(selected == index ? 0.6 : 0.16), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

struct GodReviewCardView: View {
    let text: String
    let imageURL: String?
    let referer: String?
    /// 跟随阅读主题的强调色，卡片底色、边框、标签都吃这一套。
    let accent: Color
    let textColor: Color
    let onAccentColor: Color
    /// 0 左对齐 / 1 居中；跟热评样式面板里的「对齐」是同一个值
    var alignment: Int = 0
    let onTap: () -> Void

    private var displayText: String {
        text
            .replacingOccurrences(of: "热评 · ", with: "")
            .replacingOccurrences(of: "神评 · ", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 7) {
                Text("热评")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(onAccentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(accent)
                    .overlay(Rectangle().stroke(accent.opacity(0.9), lineWidth: 0.6))
                Text("HOT REVIEW //")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundColor(textColor.opacity(0.48))
                Spacer(minLength: 0)
            }
            if !displayText.isEmpty, displayText != "热评" {
                Text(displayText)
                    .font(.system(size: 13))
                    .foregroundColor(textColor)
                    .multilineTextAlignment(alignment == 1 ? .center : .leading)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: alignment == 1 ? .center : .leading)
                }
            if let imageURL, !imageURL.isEmpty {
                ChapterImageView(urlString: imageURL, referer: referer)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipped()
                    .overlay(Rectangle().stroke(accent.opacity(0.28), lineWidth: 0.6))
            }
        }
        .padding(12)
        .background(onAccentColor)
        .overlay(Rectangle().stroke(accent.opacity(0.55), lineWidth: 0.8))
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(accent).frame(width: 12, height: 1.5)
                Rectangle().fill(accent).frame(width: 1.5, height: 12)
            }
        }
        // 卡片整体点击开评论详情；插图里的「点击重试」按钮要能单独收到点击，
        // 所以用 contentShape + onTapGesture 而不是把整张卡包进 Button。
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

public struct ReaderCommentItem: Identifiable {
    public let id: Int
    public let excerpt: String
    public let count: Int
    public let url: String
}

struct ReaderCommentsSheet: View {
    let chapterTitle: String
    let items: [ReaderCommentItem]
    let chapterURL: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var target: ReviewTarget?

    var body: some View {
        let palette = NieRPalette(colorScheme)

        ZStack {
            NieRBackdrop(palette: palette)
            VStack(spacing: 0) {
                NieRSheetHeader(
                    palette: palette,
                    kicker: "CHAPTER NOTES",
                    title: "段评",
                    subtitle: chapterTitle.isEmpty ? "\(items.count) PARAGRAPHS" : chapterTitle
                ) {
                    dismiss()
                }

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let chapterURL {
                            Button {
                                target = ReviewTarget(url: chapterURL, title: "本章说")
                            } label: {
                                NieRPanel(palette: palette, raised: true) {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("CHAPTER")
                                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                                .tracking(0.8)
                                                .foregroundColor(palette.accent)
                                            Text("本章说 · 全部评论")
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundColor(palette.ink)
                                        }
                                        Spacer()
                                        Image(systemName: "text.bubble")
                                            .font(.system(size: 14))
                                            .foregroundColor(palette.accent)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(palette.muted)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                        }

                        NieRSectionTitle(
                            palette: palette,
                            index: "02",
                            title: "PARAGRAPH NODES",
                            trailing: "\(items.count)"
                        )
                        .padding(.horizontal, 16)

                        if items.isEmpty {
                            NieRPanel(palette: palette) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("NO SIGNAL")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .tracking(0.8)
                                        .foregroundColor(palette.accent)
                                    Text("本章还没有段评。")
                                        .font(.system(size: 12))
                                        .foregroundColor(palette.ink.opacity(0.82))
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                target = ReviewTarget(url: item.url, title: "段评")
                            } label: {
                                NieRPanel(palette: palette) {
                                    HStack(alignment: .top, spacing: 10) {
                                        Text(String(format: "%02d", index + 1))
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                            .foregroundColor(palette.accent)
                                            .frame(width: 24, alignment: .leading)
                                        Text(item.excerpt)
                                            .font(.system(size: 13))
                                            .foregroundColor(palette.ink)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        NieRBadge(
                                            palette: palette,
                                            text: item.count >= 99 ? "99+" : "\(item.count)",
                                            filled: item.count >= 99
                                        )
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
        }
        .sheet(item: $target) { target in
            NativeCommentListSheet(target: target)
        }
    }
}

private struct ReviewTarget: Identifiable {
    let id = UUID()
    let url: String
    let title: String
}

private struct GodReviewMarker {
    let text: String
    let imageURL: String?
    let url: String
}

private struct NativeCommentListSheet: View {
    let target: ReviewTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var comments: [ReviewComment] = []
    @State private var total = 0
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorText: String?
    @State private var cursor = ""
    @State private var hasMore = false
    @State private var sortHot = true
    @State private var expandedComments: Set<String> = []
    @State private var replies: [String: [ReviewReply]] = [:]
    @State private var replyCursor: [String: String] = [:]
    @State private var replyHasMore: Set<String> = []

    var body: some View {
        let palette = NieRPalette(colorScheme)

        ZStack {
            NieRBackdrop(palette: palette)
            VStack(spacing: 0) {
                NieRSheetHeader(
                    palette: palette,
                    kicker: "REVIEW LOG",
                    title: target.title,
                    subtitle: total > 0 ? "\(total) RECORDS · \(sortHot ? "HOT" : "LATEST")" : "NO RECORDS"
                ) {
                    dismiss()
                }

                HStack {
                    Text(sortHot ? "SORT / HOT" : "SORT / LATEST")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(palette.muted)
                    Spacer()
                    Button {
                        sortHot.toggle()
                        Task { await load(reset: true) }
                    } label: {
                        Text(sortHot ? "最热" : "最新")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(palette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .overlay(
                                Rectangle()
                                    .stroke(palette.accent.opacity(0.5), lineWidth: 0.6)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if isLoading {
                            loadingPanel(palette)
                        } else if let errorText {
                            messagePanel(palette, title: "SIGNAL LOST", text: errorText, retry: true)
                        } else if comments.isEmpty {
                            messagePanel(palette, title: "NO SIGNAL", text: "还没有评论。")
                        }

                        ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                            commentCard(index: index, comment: comment, palette: palette)
                        }

                        if hasMore {
                            Button {
                                Task { await load(reset: false) }
                            } label: {
                                HStack(spacing: 8) {
                                    Spacer()
                                    if isLoadingMore {
                                        ProgressView().tint(palette.accent)
                                    } else {
                                        Text("加载更多")
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    }
                                    Spacer()
                                }
                                .foregroundColor(palette.accent)
                                .padding(.vertical, 8)
                                .overlay(
                                    Rectangle()
                                        .stroke(palette.line.opacity(0.7), lineWidth: 0.6)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoadingMore)
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
        }
        .task { await load(reset: true) }
    }

    private func loadingPanel(_ palette: NieRPalette) -> some View {
        NieRPanel(palette: palette) {
            HStack(spacing: 10) {
                ProgressView().tint(palette.accent)
                Text("正在读取评论…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.muted)
            }
        }
        .padding(.horizontal, 16)
    }

    private func messagePanel(
        _ palette: NieRPalette,
        title: String,
        text: String,
        retry: Bool = false
    ) -> some View {
        NieRPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(palette.accent)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(palette.ink.opacity(0.82))
                if retry {
                    Button("重试") { Task { await load(reset: true) } }
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(palette.accent)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func commentCard(
        index: Int,
        comment: ReviewComment,
        palette: NieRPalette
    ) -> some View {
        NieRPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(String(format: "%02d", index + 1))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.accent)
                    avatarView(comment.user, size: 18)
                    Text(comment.user?.user_name ?? "匿名")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(palette.ink)
                    Spacer()
                    if let likes = comment.like_count, likes > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "heart")
                            Text("\(likes)")
                        }
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(palette.muted)
                    }
                }

                Text(commentText(comment.content))
                    .font(.system(size: 13))
                    .foregroundColor(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if let image = comment.image_url, let url = resolvedImageURL(image) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else if phase.error == nil {
                            ProgressView().frame(height: 60)
                        }
                    }
                    .frame(maxHeight: 180)
                }

                NieRDivider(palette: palette)

                HStack(spacing: 10) {
                    if let time = comment.create_time {
                        Text(time)
                    }
                    if let replies = comment.reply_count, replies > 0 {
                        Button(expandedComments.contains(comment.id)
                               ? "收起回复"
                               : "\(replies) 回复") {
                            toggleReplies(comment)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(palette.accent)
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(palette.muted)

                if expandedComments.contains(comment.id) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(replies[comment.id] ?? []) { reply in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(reply.user?.user_name ?? "匿名")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundColor(palette.muted)
                                Text(commentText(reply.content))
                                    .font(.system(size: 12))
                                    .foregroundColor(palette.ink.opacity(0.9))
                                if let image = reply.image_url, let url = resolvedImageURL(image) {
                                    AsyncImage(url: url) { phase in
                                        if let image = phase.image {
                                            image.resizable().scaledToFit()
                                        }
                                    }
                                    .frame(maxHeight: 120)
                                }
                            }
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(palette.line.opacity(0.6))
                                    .frame(width: 1)
                            }
                        }
                        if replyHasMore.contains(comment.id) {
                            Button("加载更多回复") {
                                Task { await loadReplies(commentID: comment.id, reset: false) }
                            }
                            .font(.system(size: 9, design: .monospaced))
                            .buttonStyle(.plain)
                            .foregroundColor(palette.accent)
                            .padding(.leading, 10)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func avatarView(_ user: ReviewUser?, size: CGFloat = 24) -> some View {
        if let raw = user?.user_avatar, let url = resolvedImageURL(raw) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: size))
                .foregroundColor(.secondary.opacity(0.55))
                .frame(width: size, height: size)
        }
    }

    private func resolvedImageURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("//") {
            return URL(string: "https:" + raw)
        }
        if let url = URL(string: raw), url.scheme != nil {
            return url
        }
        return URL(string: raw, relativeTo: URL(string: target.url))?.absoluteURL
    }

    private func load(reset: Bool) async {
        if reset {
            isLoading = true
            cursor = ""
            comments = []
        } else {
            isLoadingMore = true
        }
        errorText = nil
        guard let api = reviewAPIURL(from: target.url, cursor: cursor) else {
            AppLog.write("[评论] 地址无法解析 title=\(target.title)")
            errorText = "评论地址无法解析"
            isLoading = false
            isLoadingMore = false
            return
        }
        do {
            // 缓存优先：书源没登录或断网时，之前抓过的评论还能看
            if reset, let cachedData = ReviewCache.load(for: api),
               let cachedEnvelope = try? JSONDecoder().decode(ReviewEnvelope.self, from: cachedData) {
                comments = cachedEnvelope.data?.comments ?? []
                total = cachedEnvelope.data?.total ?? comments.count
                cursor = cachedEnvelope.data?.next_cursor ?? ""
                hasMore = cachedEnvelope.data?.has_more == true && cursor != ""
                AppLog.write("[评论] 先给缓存 title=\(target.title) \(comments.count) 条")
            }
            let (data, _) = try await URLSession.shared.data(from: api)
            let envelope = try JSONDecoder().decode(ReviewEnvelope.self, from: data)
            let page = envelope.data?.comments ?? []
            let existing = Set(comments.map(\.id))
            comments += page.filter { !existing.contains($0.id) }
            total = envelope.data?.total ?? comments.count
            cursor = envelope.data?.next_cursor ?? ""
            hasMore = envelope.data?.has_more == true && cursor != ""
            ReviewCache.store(data, for: api)
            AppLog.write("[评论] 加载完成 title=\(target.title) 当前 \(comments.count) 条 / 总数 \(total)")
        } catch {
            // 有缓存就留在缓存上，别拿一条报错把内容顶掉
            if comments.isEmpty {
                AppLog.write("[评论] 加载失败 title=\(target.title) error=\(error.localizedDescription)")
                errorText = "加载失败：\(error.localizedDescription)"
            } else {
                AppLog.write("[评论] 网络失败，继续用缓存 title=\(target.title) \(comments.count) 条 error=\(error.localizedDescription)")
            }
        }
        isLoading = false
        isLoadingMore = false
    }

    private func reviewAPIURL(from raw: String, cursor: String) -> URL? {
        guard var components = URLComponents(string: raw) else { return nil }
        let query = components.queryItems ?? []
        let originalMode = query.first(where: { $0.name == "mode" })?.value
        let para = query.first(where: { $0.name == "para" || $0.name == "paragraph_id" })?.value ?? "0"
        components.path = "/para_review"
        var items = [
            URLQueryItem(name: "book_id", value: query.first(where: { $0.name == "book_id" })?.value ?? ""),
            URLQueryItem(name: "item_id", value: query.first(where: { $0.name == "item_id" })?.value ?? ""),
            URLQueryItem(name: "item_version", value: query.first(where: { $0.name == "item_version" })?.value ?? ""),
            URLQueryItem(name: "para", value: para),
            URLQueryItem(name: "source", value: query.first(where: { $0.name == "source" })?.value ?? "番茄"),
            URLQueryItem(name: "mode", value: (originalMode == "paragraph" || target.title == "段评") ? "paragraph" : "chapter"),
            URLQueryItem(name: "hot", value: sortHot ? "1" : "0")
        ]
        if !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = items
        return components.url
    }

    private func toggleReplies(_ comment: ReviewComment) {
        if expandedComments.contains(comment.id) {
            expandedComments.remove(comment.id)
        } else {
            expandedComments.insert(comment.id)
            if replies[comment.id] == nil {
                Task { await loadReplies(commentID: comment.id, reset: true) }
            }
        }
    }

    private func loadReplies(commentID: String, reset: Bool) async {
        guard let api = replyAPIURL(commentID: commentID, cursor: reset ? "" : (replyCursor[commentID] ?? "")) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: api)
            let envelope = try JSONDecoder().decode(ReviewEnvelope.self, from: data)
            let page = envelope.data?.replies ?? []
            if reset {
                replies[commentID] = page
            } else {
                replies[commentID, default: []] += page
            }
            replyCursor[commentID] = envelope.data?.next_cursor ?? ""
            if envelope.data?.has_more == true, envelope.data?.next_cursor != nil {
                replyHasMore.insert(commentID)
            } else {
                replyHasMore.remove(commentID)
            }
        } catch {
            // 回复失败保留原列表，不打断主评论
        }
    }

    private func replyAPIURL(commentID: String, cursor: String) -> URL? {
        guard let base = reviewAPIURL(from: target.url, cursor: ""),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "comment_id", value: commentID))
        if !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = items
        return components.url
    }

    private static let commentEmoji: [String: String] = [
        "[微笑]": "😊", "[偷笑]": "😏", "[笑]": "😁", "[什么]": "🤔", "[害羞]": "😳",
        "[爱慕]": "😍", "[飞吻]": "😘", "[奸笑]": "😏", "[尬笑]": "😅", "[思考]": "🤔",
        "[撇嘴]": "😒", "[做鬼脸]": "😜", "[酷]": "😎", "[翻白眼]": "🙄", "[惊呆]": "😲",
        "[震惊]": "😱", "[送心]": "❤️", "[委屈]": "🥺", "[快哭了]": "😭", "[笑哭]": "😂",
        "[哭]": "😢", "[大笑]": "😆", "[舔屏]": "😋", "[怒]": "😡", "[捂脸]": "🤦",
        "[吐]": "🤮", "[恐惧]": "😨", "[抓狂]": "😫", "[敬礼]": "🫡", "[石化]": "🗿",
        "[OK]": "👌", "[赞]": "👍", "[爱心]": "💖", "[伤心]": "💔", "[吃瓜]": "🍉",
        "[盯]": "👀", "[狗头]": "🐶", "[神评]": "🌟", "[小七_神评]": "🌟"
    ]

    private func commentText(_ raw: String?) -> String {
        guard let raw else { return "" }
        var text = raw
        for (token, emoji) in Self.commentEmoji {
            text = text.replacingOccurrences(of: token, with: emoji)
        }
        return text
    }
}

private struct ReviewEnvelope: Decodable {
    let code: Int
    let data: ReviewData?
}

private struct ReviewData: Decodable {
    let comments: [ReviewComment]?
    let replies: [ReviewReply]?
    let total: Int?
    let has_more: Bool?
    let next_cursor: String?
}

private struct ReviewReply: Decodable, Identifiable {
    let reply_id: String
    let content: String?
    let image_url: String?
    let like_count: Int?
    let create_time: String?
    let user: ReviewUser?
    var id: String { reply_id }
}

private struct ReviewComment: Decodable, Identifiable {
    let comment_id: String
    let content: String?
    let image_url: String?
    let like_count: Int?
    let reply_count: Int?
    let create_time: String?
    let user: ReviewUser?
    var id: String { comment_id }
}

private struct ReviewUser: Decodable {
    let user_name: String?
    let user_avatar: String?
}

public struct BlockFrameInfo: Equatable {
    public let chapterIndex: Int
    public let blockId: Int
    public let minY: CGFloat
    public let maxY: CGFloat
    /// 同一段在窗口坐标系里的矩形（长按命中用）
    public let rect: CGRect
}

public struct ReaderScrollPreferenceKey: PreferenceKey {
    public static var defaultValue: [BlockFrameInfo] = []
    public static func reduce(value: inout [BlockFrameInfo], nextValue: () -> [BlockFrameInfo]) {
        value.append(contentsOf: nextValue())
    }
}

/// 滚动模式的长按命中表。
///
/// 正文在滚动模式里是 `UILabel`（`isUserInteractionEnabled = false`），SwiftUI 的
/// `onLongPressGesture` 挂在这种视图上命不中，所以长按统一交给窗口层的识别器，
/// 再由这张表把触点换算成段落。表只存不发布，避免每次布局都触发整页刷新。
final class ReaderScrollHitRegistry {
    struct Entry {
        let chapterIndex: Int
        let blockId: Int
        let rect: CGRect
    }

    private(set) var entries: [Entry] = []

    func replace(with frames: [BlockFrameInfo]) {
        entries = frames.map { Entry(chapterIndex: $0.chapterIndex, blockId: $0.blockId, rect: $0.rect) }
    }

    /// 点落在哪个段落；重叠时取面积最小的那个
    func hitTest(_ point: CGPoint) -> Entry? {
        entries
            .filter { $0.rect.insetBy(dx: -6, dy: -4).contains(point) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }

    /// 某一段在窗口里的矩形（气泡定位用）
    func rect(forBlockId blockId: Int, chapterIndex: Int) -> CGRect? {
        entries.first { $0.blockId == blockId && $0.chapterIndex == chapterIndex }?.rect
    }
}

/// 长按选中段落之后的一小段时间里，松手不再当点击处理。
///
/// 用引用类型：分页那套手势是「手指按下时」捕获闭包的，值类型状态那一刻的副本
/// 读不到长按后面才写进去的抑制时间，松手仍会把工具栏又 toggle 一遍。
final class ReaderTapSuppressor {
    private var until: Date = .distantPast

    var isActive: Bool { Date() < until }

    func suppress(seconds: TimeInterval = 0.8) {
        until = Date().addingTimeInterval(seconds)
    }
}

/// 书签面板的排序方式
enum BookmarkSortOrder: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst
    case chapterAscending
    case chapterDescending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newestFirst: return "按时间（新→旧）"
        case .oldestFirst: return "按时间（旧→新）"
        case .chapterAscending: return "按章节（前→后）"
        case .chapterDescending: return "按章节（后→前）"
        }
    }
}

/// 书签面板的类型筛选
enum BookmarkKindFilter: String, CaseIterable, Identifiable {
    case all
    case bookmark
    case underline
    case highlight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部类型"
        case .bookmark: return "只看书签"
        case .underline: return "只看下划线"
        case .highlight: return "只看底色"
        }
    }
}

public struct ScrollOffsetPreferenceKey: PreferenceKey {
    public static var defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

public struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var readerConfig = ReaderConfig.shared
    @StateObject private var audioService = AudioBookService.shared

    let book: Book
    let source: BookSource?

    /// 换源后原地替换，不退出阅读界面。
    @State private var switchedBook: Book?
    @State private var switchedSource: BookSource?
    /// 换源失败要能退回原来的书源，不然会卡在错误页出不来。
    @State private var previousBook: Book?
    @State private var previousSource: BookSource?

    private var activeBook: Book { switchedBook ?? book }

    /// 热评卡片固定走尼尔配色，不跟随阅读主题色。
    private var nierPalette: NieRPalette { NieRPalette(colorScheme) }

    /// 热评卡片外观：设置项 → 绘制参数
    private var reviewCardStyle: ReviewCardStyle {
        ReviewCardStyle(
            fontScale: readerConfig.reviewFontScale,
            inset: readerConfig.reviewInset,
            opacity: readerConfig.reviewCardOpacity,
            style: readerConfig.reviewCardStyle,
            alignment: readerConfig.reviewAlignment,
            textColorMode: readerConfig.reviewTextColorMode,
            textDrop: readerConfig.reviewTextDrop
        )
    }

    /// 热评块 id → 评论地址；源里没给单条地址就退回本章说
    private var reviewURLMap: [Int: String] {
        let blocks = currentLoadedChapter?.blocks ?? []
        let chapterURL = blocks.first(where: { $0.commentCount == -1 })?.commentURL
        var map: [Int: String] = [:]
        for block in blocks where block.commentCount == -2 {
            if let url = block.commentURL, !url.isEmpty {
                map[block.id] = url
            } else if let chapterURL {
                map[block.id] = chapterURL
            }
        }
        return map
    }

    private var chromeBackground: Color {
        theme.choice == .lunarTerminal ? theme.palette.background : readerConfig.backgroundColor
    }

    private var chromeInk: Color {
        theme.choice == .lunarTerminal ? theme.palette.ink : readerConfig.textColor
    }

    private var chromeRadius: CGFloat {
        theme.choice == .lunarTerminal ? theme.metrics.cornerRadius : 24
    }

    private var effectiveSource: BookSource? {
        switchedSource ?? source ?? BookStore.shared.findSource(for: activeBook)
    }

    @State private var chapters: [BookChapter] = []
    @State private var currentChapterIndex: Int = 0
    @State private var loadedChapters: [LoadedChapter] = []
    @State private var currentPageIndex: Int = 0
    @State private var pageTurnForward: Bool = true
    /// 手指拖动时整页（含页眉页脚）跟着走的位移，松手后归零
    @State private var dragOffset: CGFloat = 0
    @State private var currentReadingBlockId: Int = 0
    /// 滚动模式的长按命中表（引用类型：更新不触发视图刷新）
    @State private var scrollHitRegistry = ReaderScrollHitRegistry()
    /// 按段朗读是从哪一章起的：读到下一章时 currentChapterIndex 会跟着滚走，起点得单独留
    @State private var readingChapterIndex: Int = -1
    /// 上一次「点段起读」的时间：同一根手指会被两套识别器各报一次
    @State private var lastReadingTapAt: Date = .distantPast
    /// 听书球按下时刻：轻点 / 长按按按住时长区分
    @State private var listeningBallPressBegan: Date? = nil
    /// 长按选中段落之后这段时间里，松手不再当点击处理
    @State private var tapSuppressor = ReaderTapSuppressor()
    @State private var chapterCache: [Int: LoadedChapter] = [:]
    @State private var readerContainerSize: CGSize = CGSize(width: 390, height: 700)
    /// 设备安全区实际数值：按页翻的时候整页是贴到屏幕物理边缘的，页眉页脚得自己把这段让出来
    @State private var safeInsets: EdgeInsets = EdgeInsets()

    @State private var isLoadingInitial: Bool = true
    @State private var isLoadingNextChapter: Bool = false
    @State private var loadingNote: String = "正在加载章节内容..."
    @State private var scrollSessionId: UUID = UUID()
    @State private var scrollToChapterId: String? = nil
    @State private var errorMessage: String? = nil

    @ObservedObject private var bookmarkStore = BookStore.shared
    @State private var showTOC: Bool = false
    @State private var tocSearchText: String = ""
    @State private var tocReversed: Bool = false
    @State private var showBookmarks: Bool = false
    @State private var showComments: Bool = false
    @State private var directCommentTarget: ReviewTarget?
    @State private var readingTickStart: Date? = nil
    @State private var newBookmarkNote: String = ""
    /// 书签列表的面板状态：搜索、排序、类型筛选、多选
    @State private var bookmarkSearchText: String = ""
    @State private var bookmarkSort: BookmarkSortOrder = .newestFirst
    @State private var bookmarkKindFilter: BookmarkKindFilter = .all
    @State private var bookmarkMultiSelect: Bool = false
    @State private var selectedBookmarkIDs: Set<UUID> = []
    @State private var showSettings: Bool = false
    @State private var showSearch: Bool = false
    @State private var showTTSSettings: Bool = false
    @State private var showBookInfo: Bool = false
    @State private var showSourceSwitch: Bool = false
    @State private var showControls: Bool = false
    /// 滚动模式的当前偏移（顶部继续下拉才加书签，靠它判断「在顶部」）
    @State private var scrollOffsetY: CGFloat = 0
    /// 下拉加书签：拖动进度、整页下拉位移、绶带是否落定、绶带显示窗口、提示文案
    @State private var bookmarkPullProgress: CGFloat = 0
    @State private var pagePullOffset: CGFloat = 0
    /// 下拉期间为 true：冻结滚动探针，别让位移被当成滚动去换章/重排
    @State private var isPullActive = false
    @State private var bookmarkRibbonSettled = false
    @State private var bookmarkRibbonVisible = false
    @State private var bookmarkHintText: String?
    #if os(iOS)
    /// 自定义图片：下拉露出的背景、书签图（相册里选，见 ReaderAssetsSheet）
    @State private var pullBackgroundImage: UIImage?
    @State private var bookmarkImage: UIImage?
    #endif
    /// 书签位置与尺寸（在「书签 / 笔记」面板里调；跨平台放外面，macOS 版也要能编）
    @AppStorage("reader_bookmark_width") private var bookmarkWidth: Double = 34
    @AppStorage("reader_bookmark_x") private var bookmarkX: Double = 1
    /// 书签的高宽比；0 = 自动（自定义图按图片自身比例，默认绶带 1.73）
    @AppStorage("reader_bookmark_aspect") private var bookmarkAspect: Double = 0
    /// 书签挂下来多少（0 = 贴着屏幕最上沿），跟外观面板共用
    @AppStorage("reader_bookmark_y") private var bookmarkY: Double = 0
    /// 正文背景图：缩放与位置（跟下拉背景一样可以调）
    @AppStorage("reader_bg_image_scale") private var backgroundImageScale: Double = 1
    @AppStorage("reader_bg_image_offset_x") private var backgroundImageOffsetX: Double = 0
    @AppStorage("reader_bg_image_offset_y") private var backgroundImageOffsetY: Double = 0
    /// 下拉背景图的位置微调（pt），跟外观面板共用
    @AppStorage("reader_pull_background_offset_x") private var pullBackgroundOffsetX: Double = 0
    @AppStorage("reader_pull_background_offset_y") private var pullBackgroundOffsetY: Double = 0
    /// 下拉背景图的缩放与对齐（0 顶 / 1 中 / 2 底）
    @AppStorage("reader_pull_background_scale") private var pullBackgroundScale: Double = 1
    @AppStorage("reader_pull_background_align") private var pullBackgroundAlign: Int = 0
    /// 段落级长按：选中区间 + 文字、替换输入、聚合搜索面板
    @State private var selectedBlockRange: (start: Int, count: Int)? = nil
    @State private var selectedParagraphText = ""
    /// 选段落对应的原始段落 id / 段内起点 / 原文（逐字选择用，保留段首缩进）
    @State private var selectedParagraphId = 0
    @State private var selectedParagraphCharStart = 0
    @State private var selectedParagraphRawText = ""
    /// 段内逐字选择；非 nil 就是字选模式
    @State private var charSelection: ReaderCharSelection?
    /// 这次拖拽抓的是起点手柄还是终点手柄
    @State private var isDraggingCharStart = false
    /// 正在选颜色的标注类型（下划线 / 底色）
    @State private var colorPickerKind: BookBookmark.Kind?
    /// 上次用过的颜色，点「下划线 / 底色」时先记住，调色板里高亮
    @AppStorage("reader_underline_hex") private var underlineHex = "#2F7BF6"
    @AppStorage("reader_highlight_hex") private var highlightHex = "#FFF59D"
    /// 选中段落在窗口里的位置（操作气泡贴在这儿）
    @State private var selectionRect: CGRect?
    /// 选中那一刻这一章的标注快照：按「取消」就还原成它
    @State private var annotationSnapshot: [BookBookmark]?
    @State private var showReplaceInput = false
    /// 键盘占掉的高度（窗口坐标）：气泡和调色板的下边界要躲开它
    @State private var keyboardInset: CGFloat = 0
    /// 朗读条收成圆点 / 跟翻页读 / 朗读底色来源：都存盘，换书、重开都不丢
    @AppStorage("tts_bar_collapsed") private var ttsBarCollapsed = false
    /// 整个朗读条藏起来（连那颗圆点也不要）：面板里有开关能叫回来
    @AppStorage("tts_bar_hidden") private var ttsBarHidden = false
    @AppStorage("tts_follow_page") private var ttsFollowPage = false
    /// 进度格跳转时把页码改到自己手里，别让「翻页跟读」把它当成用户翻页又拽回去
    @State private var suppressFollowOnPageChange = false
    /// 用户自己翻过页：朗读还在后面念，就别把页码拽回来。
    /// 念到用户眼前这一页（页码 ≥ 当前页）时自动解除，重新接管。
    @State private var autoFollowPausedByUser = false
    /// 起读请求挂起：章节正文还没到就先记下，等 loadInitialChapter 落地再念。
    /// 以前这里直接读 currentLoadedChapter，它查不到会退回 loadedChapters.first，
    /// 快翻时就把上一章的正文当成这一章念出去，高亮还停在目标章——全错位。
    private struct PendingReadingStart {
        var chapter: Int
        var blockId: Int?
        var revealBar: Bool
    }
    @State private var pendingReadingStart: PendingReadingStart?
    /// accent（主题强调色）/ highlight（底色标注色）/ underline（划线色）
    @AppStorage("tts_tint_source") private var ttsTintSource = "accent"
    /// 听书优先读本地缓存：源站没登录时正文可能是占位文，缓存里才是真内容
    @AppStorage("tts_read_cache") private var ttsReadFromCache = false
    /// 朗读面板：起读位置、跟页、底色都收在这张卡里
    @State private var showReadingPanel = false
    @State private var replaceInput = ""
    @State private var showAggregateSearch = false
    @State private var showBackgroundImagePicker: Bool = false
    #if os(iOS)
    /// 正文背景图：iOS 16 起从相册选（用 Any 存，避开 PhotosPickerItem 的可用性限制）
    @State private var backgroundPhotoItem: Any?
    #endif
    /// 本次阅读会话起点，「阅读时长」「剩余时间」用它算
    @State private var readerSessionStart: Date = Date()
    @State private var settingsPanel: ReaderQuickPanel = .quick
    /// 设置面板收起状态：调布局时把它折起来，整页都露出来
    @State private var panelCollapsed = false
    @State private var layoutPreviewActive = false
    @State private var layoutPreviewToken = 0
    @State private var showReviewStyleSheet = false
    /// 换章进行中：期间拦掉重复的翻页触发，免得拿旧章的页数推进
    @State private var isSwitchingChapter = false
    @State private var paginationTask: Task<Void, Never>?
    @State private var showTitleDesigner = false
    @State private var showReplaceRules = false
    /// 下载缓存这类「做完了」的提示，别用 errorMessage（那是错误页的开关）
    @State private var downloadHint: String? = nil

    public var onDismiss: (() -> Void)? = nil

    public init(book: Book, source: BookSource?, initialChapterIndex: Int? = nil, onDismiss: (() -> Void)? = nil) {
        self.book = book
        self.source = source
        self._currentChapterIndex = State(initialValue: initialChapterIndex ?? book.durChapterIndex)
        self.onDismiss = onDismiss
    }

    private var currentLoadedChapter: LoadedChapter? {
        loadedChapters.first(where: { $0.chapter.index == currentChapterIndex }) ?? loadedChapters.first
    }

    /// 只要这一章，查不到就是 nil。朗读路径全走它——
    /// currentLoadedChapter 那条 `?? loadedChapters.first` 是好心给屏上兜底的，
    /// 拿来朗读会把上一章的正文念出去。
    private func loadedChapter(exactly index: Int) -> LoadedChapter? {
        loadedChapters.first(where: { $0.chapter.index == index })
    }

    private var currentChapterContent: String {
        currentLoadedChapter?.content ?? ""
    }

    // MARK: - 按段朗读

    /// 本章能读的段：图片、分隔、热评卡片都跳过，段落 id 留着对高亮
    private var readingItemsForCurrentChapter: [AudioBookService.ReadingItem] {
        if ttsReadFromCache, let cachedItems = cachedReadingItemsForCurrentChapter() {
            return cachedItems
        }
        guard let loaded = loadedChapter(exactly: currentChapterIndex) else { return [] }
        return loaded.blocks.compactMap { block in
            // 段评段落（commentCount > 0）正文照读，只有章评哨兵（-1）和热评卡片（-2）要跳过。
            // 之前按 == 0 过滤，源站给每段挂了段评数，整章九十段只剩七段进队列。
            guard !block.isImage, block.commentCount >= 0 else { return nil }
            let text = applyingBookReplaceRules(block.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return AudioBookService.ReadingItem(id: block.id, text: text)
        }
    }

    /// 同一章从落盘缓存里重排一份可读段。
    /// 开关打开时缓存就是正文口径：源站这会儿给的是不是占位文，跟听书无关。
    private func cachedReadingItemsForCurrentChapter() -> [AudioBookService.ReadingItem]? {
        guard let loaded = loadedChapter(exactly: currentChapterIndex) else { return nil }
        let chapterIndex = loaded.chapter.index
        guard let cached = BookContentService.shared.getCachedChapterContent(bookUrl: activeBook.bookUrl,
                                                                            chapterIndex: chapterIndex),
              !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let text = applyingBookReplaceRules(cached)
        // 缓存和屏上正文一模一样的时候，别再拿缓存重排一遍：
        // 两次解析在短句处切法不同，段与段会对歪，听的是上一段、亮的是下一段。
        // 只有屏上正文确实不对（未登录拿到占位文、内容过期）才走缓存。
        if text == loaded.content {
            AppLog.write("[听书] 缓存与屏上一致 · 直接用屏上分段（不做缓存重排）")
            return nil
        }
        let cachedBlocks = parseContentBlocks(from: text).filter { block in
            guard !block.isImage, block.commentCount >= 0 else { return false }
            return !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // 屏上那套 block 和缓存重排是两次解析，id 不一定同号（章标题也算一段时整条错开一格）。
        // 高亮认的是屏上 id，所以朗读队列的 id 必须换成屏上那套，不能直接用缓存解析出来的。
        let screenBlocks = loaded.blocks.filter { block in
            guard !block.isImage, block.commentCount >= 0 else { return false }
            return !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // 先按文字对位（缓存和屏上正文会在短句处切得不一样，按序数对会从那一处起整条错开），
        // 对不上的再退回同序取 id。
        var byIndex = 0, byText = 0, unmatched = 0
        let sameCount = screenBlocks.count == cachedBlocks.count
        var cursor = 0
        let items: [AudioBookService.ReadingItem] = cachedBlocks.compactMap { block in
            let spoken = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var id = block.id
            if let hit = screenBlocks[cursor...].firstIndex(where: {
                paragraphsLookAlike($0.text, spoken)
            }) {
                id = screenBlocks[hit].id
                cursor = hit + 1
                byText += 1
            } else if sameCount, byIndex < screenBlocks.count {
                id = screenBlocks[byIndex].id
                byIndex += 1
            } else {
                unmatched += 1
            }
            return AudioBookService.ReadingItem(id: id, text: spoken)
        }
        guard !items.isEmpty else { return nil }
        AppLog.write("[听书] 读本地缓存 · 第 \(chapterIndex + 1) 章 · \(items.count) 段 · 缓存 \(cached.count) 字"
                     + (text == loaded.content ? " · 与屏上正文一致" : " · 与屏上正文不同")
                     + " · 对位 按文\(byText)/按序\(byIndex)/未对上\(unmatched)")
        return items
    }

    /// 两段是不是同一段：先比开头的字，缓存和屏上正文只在标点、空白上有差别
    private func paragraphsLookAlike(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if a == b { return true }
        let n = min(12, min(a.count, b.count))
        guard n >= 6 else { return false }
        return a.prefix(n) == b.prefix(n)
    }

    /// 朗读条上的进度格：跳回正在读的那一段，只挪位置，不重起读、不改进度。
    private func jumpToReadingBlock() {
        guard let blockId = audioService.readingBlockId else {
            showBookmarkHint("这一章还没读到正文")
            return
        }
        // 点进度格就是要回到朗读这一页：把「用户翻页」的挡板撤掉
        autoFollowPausedByUser = false
        // 起读的章节是单独记的：读到章尾时 currentChapterIndex 会被翻页带走
        let chapter = readingChapterIndex >= 0 ? readingChapterIndex : currentChapterIndex
        if readerConfig.pageMode == .scroll {
            withAnimation(.easeInOut(duration: 0.3)) {
                scrollToChapterId = "block_\(chapter)_\(blockId)"
            }
        } else if let cur = currentLoadedChapter, cur.chapter.index == chapter,
                  let page = pageIndex(containing: blockId, in: cur) {
            if page != currentPageIndex {
                suppressFollowOnPageChange = true
                withAnimation(.easeInOut(duration: 0.2)) { currentPageIndex = page }
                updateReadingBlockIdFromCurrentPage()
            }
        } else if chapter != currentChapterIndex {
            suppressFollowOnPageChange = true
            jumpToChapter(chapter)
        }
        AppLog.write("[听书] 进度格跳转 · 第 \(chapter + 1) 章 block \(blockId)")
    }

    /// 从某一段开始读（不给就从本章开头）。
    /// chapterIndex 给了就先切到那一章 —— 点的是下一章第一段时，currentChapterIndex 可能还停在前一章。
    private func startReadingChapter(fromBlockId: Int? = nil, chapterIndex: Int? = nil,
                                     revealBar: Bool = true) {
        if let chapterIndex, chapterIndex != currentChapterIndex {
            if loadedChapters.contains(where: { $0.chapter.index == chapterIndex }) {
                currentChapterIndex = chapterIndex
            } else {
                // 目标章还没铺出来：挂起，别拿当前章的正文顶上去
                pendingReadingStart = PendingReadingStart(chapter: chapterIndex,
                                                          blockId: fromBlockId,
                                                          revealBar: revealBar)
                AppLog.write("[听书] 起读挂起 · 第 \(chapterIndex + 1) 章 正文未到 · 已载 \(loadedChapters.map { $0.chapter.index + 1 })")
                return
            }
        }
        // 目标章正文还没铺出来（刚换章、预取没回来）：挂起这一请求，等 loadInitialChapter 落地再念。
        // 别在这里退回别的章去念——用户听到的会是上一章，而且还以为在听这一章。
        if loadedChapter(exactly: currentChapterIndex) == nil {
            pendingReadingStart = PendingReadingStart(chapter: currentChapterIndex,
                                                      blockId: fromBlockId,
                                                      revealBar: revealBar)
            AppLog.write("[听书] 起读挂起 · 第 \(currentChapterIndex + 1) 章 正文未到 · 已载 \(loadedChapters.map { $0.chapter.index + 1 })")
            return
        }
        let items = readingItemsForCurrentChapter
        AppLog.write("[听书] 起读请求 · 第 \(currentChapterIndex + 1) 章 · 可读 \(items.count) 段 · 已载 \(loadedChapters.map { $0.chapter.index + 1 })")
        guard !items.isEmpty else {
            AppLog.write("[听书] 起读放弃：本章没有可朗读的正文（blocks=\(currentLoadedChapter?.blocks.count ?? -1)）")
            showBookmarkHint("本章没有可朗读的正文")
            return
        }
        let start = fromBlockId.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        if fromBlockId != nil, !items.contains(where: { $0.id == fromBlockId }) {
            // 点到图片、分隔线或还没铺出来的段：什么都不做，别把进度拽回章首
            showBookmarkHint("这一段没有可读的正文")
            return
        }
        // 出口不对就别起：起了也没声，用户只看到条子在动
        if let audioIssue = audioService.audioIssueBeforeReading() {
            AppLog.write("[听书] 起读被拦 · \(audioIssue)")
            showBookmarkHint(audioIssue, seconds: 4)
            return
        }
        readingChapterIndex = currentChapterIndex
        // 重新起读就是一次新会话：跟页读接管权收回，别让上一轮的「用户翻页」标记一直挂着
        autoFollowPausedByUser = false
        // 手动起读才放出条子；跟页读这种自动行为不许掀开用户关掉的东西
        if revealBar, ttsBarHidden {
            withAnimation(.easeOut(duration: 0.18)) { ttsBarHidden = false }
            AppLog.write("[听书] 起读叫回朗读条")
        }
        AppLog.write("[听书] 起读第 \(currentChapterIndex + 1) 章 · 第 \(start + 1)/\(items.count) 段")
        // 本章读完的那一声：跟页读开着就接下一章
        // ReaderView 是 struct，这里只能按值捕获；@State 背后是同一份存储，改得动
        audioService.onReadingQueueFinished = { self.continueReadingAfterChapterEnd() }
        if TTSCastStore.shared.enabled {
            // 多角色还是整章切角色，起点只能到段首
            let text = items[start...].map(\.text).joined(separator: "\n")
            // 带上段号：多角色切碎了对白，高亮和翻页跟随还得认回原来那一段
            audioService.speakWithCast(text, blocks: items[start...].map { (id: $0.id, text: $0.text) })
        } else {
            audioService.speakReadings(items, startAt: start)
        }
        showBookmarkHint("从第 \(start + 1) 段开始朗读")
    }

    /// 气泡里的「本段读」：从选中这一段起读。选中可能跨行，朗读队列按段走，取所属段 id。
    private func readFromSelection() {
        // 段落 id 从 0 起，不能再拿 > 0 当「有没有选」的判据
        let blockId = charSelection?.paragraphId
            ?? (selectedBlockRange != nil ? selectedParagraphId : nil)
        guard let blockId else {
            showBookmarkHint("没选中段落")
            return
        }
        AppLog.write("[听书] 气泡本段读 block \(blockId)")
        cancelParagraphSelection()
        startReadingChapter(fromBlockId: blockId)
    }

    /// 菜单开关统一入口：哪条手势在拨它，日志里一眼看得出来。
    /// 之前分页器和听书回调各有一套 toggle，菜单被反复开关时查不出是谁。
    private func toggleControls(_ driver: String) {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        AppLog.write("[菜单] toggle ← \(driver) → controls=\(showControls)")
    }

    /// 听书状态下的单击：点到哪一段就从那一段起读。
    /// 没在听书时什么都不做，翻页、呼出工具栏照旧（识别器只旁听，不取消触摸）。
    private func handleTapWhileListening(at point: CGPoint) {
        #if os(iOS)
        guard !tapSuppressor.isActive else { return }
        // 点正文不再直接起读：翻页、点空白时手指很容易落在字上，进度被悄悄拽走。
        // 起读统一走长按气泡里的「本段读」。
        // 但朗读中这一下要负责把菜单叫出来：球和展开的朗读条都挂在菜单那一层，
        // 菜单唤不出来就没有暂停的入口。
        // 同一根手指可能被窗口识别器和脚本各报一次，300ms 内只认第一次
        let now = Date()
        if now.timeIntervalSince(lastReadingTapAt) < 0.3 { return }
        guard audioService.hasReadingSession else { return }
        lastReadingTapAt = now
        // 选段中点别处：先退选段，这一下不算呼菜单
        if selectedBlockRange != nil || charSelection != nil { return }
        toggleControls("listen-tap")
        AppLog.write("[听书] 点正文唤起菜单 controls=\(showControls)（不起读）· \(Int(point.x)),\(Int(point.y))")
        #endif
    }

    private var chapterCommentItems: [ReaderCommentItem] {
        guard let loaded = currentLoadedChapter else { return [] }
        return loaded.blocks.compactMap { block in
            guard block.commentCount > 0, let url = block.commentURL else { return nil }
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt = String(text.prefix(64))
            return ReaderCommentItem(id: block.id, excerpt: excerpt, count: block.commentCount, url: url)
        }
    }

    private var chapterCommentURL: String? {
        currentLoadedChapter?.blocks.first(where: { $0.commentCount == -1 })?.commentURL
    }

    /// 分页模式的章末入口：最后一页右下角浮一个「本章说」。
    @ViewBuilder
    private var chapterCommentPill: some View {
        let pages = currentLoadedChapter?.pages.count ?? 0
        if readerConfig.pageMode != .scroll,
           chapterCommentURL != nil,
           pages > 0,
           currentPageIndex >= pages - 1,
           !showControls,
           !showSettings {
            Button {
                // 按钮贴着右侧翻页区，先压住这一拍的整页点击，避免同时翻页
                tapSuppressor.suppress(seconds: 0.35)
                showComments = true
            } label: {
                Label("本章说", systemImage: "text.bubble")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
            .padding(.bottom, 24)
        }
    }

    public var body: some View {
        GeometryReader { outerGeo in
            ZStack {
                ZStack {
                    readerBackground
                        .ignoresSafeArea()

                    // 1. Reading Canvas with Permanent Fixed Bottom Info Bar
                    VStack(spacing: 0) {
                    // 按页翻的模式（左右/覆盖/滑动/仿真）页眉页脚画在每页里，跟着一起翻
                    // 整页下拉（加书签手势）时这一层整体位移，松手弹回
                    if readerConfig.headerEnabled, readerConfig.pageMode == .scroll, !showSettings {
                        statusBar(left: readerConfig.headerLeft, center: readerConfig.headerCenter, right: readerConfig.headerRight, extendEdge: .top)
                            .offset(y: readerConfig.headerGap - screenTopInset)
                    }

                    Group {
                        if isLoadingInitial {
                            VStack(spacing: 16) {
                                Spacer()
                                ProgressView()
                                Text(loadingNote)
                                    .font(.subheadline)
                                    .foregroundColor(readerConfig.textColor.opacity(0.7))
                                Button("返回书架") {
                                    dismiss()
                                }
                                .buttonStyle(.bordered)
                                .padding(.top, 4)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleControls("loading-tap")
                            }
                        } else if let error = errorMessage {
                            VStack(spacing: 12) {
                                Spacer()
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.largeTitle)
                                    .foregroundColor(.orange)
                                Text("加载失败")
                                    .font(.headline)
                                Text(error)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                                HStack(spacing: 12) {
                                    Button("重试") {
                                        Task { await loadTOCAndStart() }
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("返回书架") {
                                        dismiss()
                                    }
                                    .buttonStyle(.bordered)
                                }
                                if previousBook != nil {
                                    Button("换回原书源") {
                                        revertSourceSwitch()
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(.accentColor)
                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleControls("error-tap")
                            }
                        } else {
                            ZStack {
                                if readerConfig.pageMode == .scroll {
                                    infiniteScrollView
                                } else if readerConfig.pageMode == .simulation {
                                    simulationPageView.id("sim_\(themeRenderKey)")
                                } else {
                                    pageByPageView.id("paged_\(themeRenderKey)")
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // 按页翻时整页要铺到屏幕边缘：否则状态栏那一条是外层静止的背景，
                            // 翻页时顶部内容不跟着移动
                            .ignoresSafeArea(edges: readerConfig.pageMode == .scroll ? [] : .all)
                        }
                    }

                    // Fixed Bottom Information Bar (Apple Books Style)
                    if readerConfig.footerEnabled, readerConfig.pageMode == .scroll, !showSettings {
                        statusBar(left: readerConfig.footerLeft, center: readerConfig.footerCenter, right: readerConfig.footerRight, extendEdge: .bottom)
                            .offset(y: screenBottomInset - readerConfig.footerGap)
                    }
                }

                // 2. Dismiss Backdrop (when controls are open, tapping anywhere outside bars dismisses them)
                if showControls && !showSettings {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // 诊断用：球点下去没反应时，靠这行判断是不是被背景层吃了触摸。
                            AppLog.write("[菜单] backdrop 吃掉一下 → controls=false")
                            withAnimation(.easeInOut(duration: 0.22)) {
                                showControls = false
                            }
                        }
                        .ignoresSafeArea()
                }

                // 3. Top Navigation Bar Overlay (Sliding down from top)
                if showControls && !showSettings {
                    VStack(spacing: 0) {
                        topNavigationBar
                        Spacer()
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                }

                // 4. Bottom Control Panel Overlay (Sliding up from bottom)
                if showControls && !showSettings {
                    VStack(spacing: 0) {
                        Spacer()
                        bottomControlPanel
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
                }

                // 5. Reading Settings Card Overlay (Bottom 1/3 of the screen)
                if showSettings {
                    // 面板调淡的时候，底下这层压暗也得跟着淡，不然还是看不清正文
                    Color.black.opacity(0.28 * effectivePanelOpacity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                showSettings = false
                                showControls = false
                            }
                        }
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        Spacer()
                        readingSettingsCard
                    }
                    // 底部贴住屏幕物理边缘，别再露出正文页脚那一条
                    .ignoresSafeArea(edges: .bottom)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
                    }
                }
                // 整页下拉（加书签手势）时整个阅读层跟着下来，松手弹回
                .offset(y: pagePullOffset)
                // 下拉识别器也挂在 background：它只旁听手势，不吃触摸
                .background(pullDownCatcherLayer)
                // 长按选中段落后的操作栏
                .overlay { paragraphActionBar }
                // 字选的两个圆形手柄
                .overlay { charSelectionHandles }
                .overlay(alignment: .top) {
                    if let downloadHint {
                        Text(downloadHint)
                            .font(.system(size: 13))
                            .foregroundColor(readerConfig.textColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 56)
                            .transition(.opacity)
                    }
                }
                .onAppear {
                    // 验收脚本：环境变量给了就往后台排一段长按/标注的重放
                    Task { await runReaderDebugScriptIfNeeded() }
                    // 按页翻的时候整页是贴到屏幕物理边缘的，页眉页脚得自己把安全区让出来
                    let fromWindow = ReaderView.windowSafeInsets()
                    safeInsets = fromWindow.top > 0 || fromWindow.bottom > 0 ? fromWindow : outerGeo.safeAreaInsets
                    updateContainerSizeIfNeeded(paginationContainerSize(for: outerGeo.size))
                }
                .onChange(of: outerGeo.size) { newSize in
                    updateContainerSizeIfNeeded(paginationContainerSize(for: newSize))
                }
                .onChange(of: outerGeo.safeAreaInsets) { newValue in
                    // 下拉时页面位移会让安全区读数抖动，跟着改会触发重新分页，文字当场变形。
                    guard !isPullActive, pagePullOffset == 0 else { return }
                    safeInsets = newValue
                }
            }
        }
        // 下拉背景挂在布局外：正文往下走时它不动，也不会改变正文的尺寸与安全区口径。
        .background(pullBackgroundLayer)
        .overlay(alignment: .topTrailing) { bookmarkRibbonOverlay }
        .overlay(alignment: .top) { bookmarkHintOverlay }
        .overlay(alignment: .bottom) { listeningBallLayer }
        .overlay { readingPanelOverlay }
        .overlay(alignment: .bottomTrailing) { chapterCommentPill }
        #if os(iOS)
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
        #endif
        // 右上角统一菜单：底部工具条只留常用按钮，零碎功能收这里
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        refreshCurrentChapter()
                    } label: {
                        Label("刷新本章正文", systemImage: "arrow.clockwise")
                    }
                    Button {
                        Task { await refreshChapterList() }
                    } label: {
                        Label("刷新目录", systemImage: "list.bullet.rectangle")
                    }
                    Button(role: .destructive) {
                        clearCurrentBookCache()
                    } label: {
                        Label("清除本书缓存", systemImage: "trash")
                    }
                    Button {
                        downloadCachedChapters()
                    } label: {
                        Label("下载缓存（\(readerConfig.cachedChapterCount) 章）", systemImage: "arrow.down.circle")
                    }
                    Button {
                        showReplaceRules = true
                    } label: {
                        Label("替换净化规则", systemImage: "wand.and.stars")
                    }
                    Button {
                        showBookmarks = true
                    } label: {
                        Label("书签", systemImage: "bookmark")
                    }
                    if !chapterCommentItems.isEmpty {
                        Button {
                            showComments = true
                        } label: {
                            Label("段评（\(chapterCommentItems.count)）", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                    if chapterCommentURL != nil {
                        Button {
                            showComments = true
                        } label: {
                            Label("本章说", systemImage: "text.bubble")
                        }
                    }
                    Button {
                        showTTSSettings = true
                    } label: {
                        Label("听书设置", systemImage: "headphones")
                    }
                    // 本章原文网址：聚合源这类把请求包在 data: 里的没有可打开的网页，直接不显示
                    if let chapterUrl = currentLoadedChapter?.chapter.url,
                       let url = URL(string: chapterUrl),
                       let scheme = url.scheme?.lowercased(),
                       scheme == "http" || scheme == "https" {
                        Button {
                            #if os(iOS)
                            UIApplication.shared.open(url)
                            #endif
                        } label: {
                            Label("在浏览器打开本章", systemImage: "safari")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showTOC) {
            tocSheet
        }
        .sheet(isPresented: $showSearch) {
            searchSheet
        }
        .sheet(isPresented: $showTTSSettings) {
            TTSSettingsSheet()
        }
        .sheet(isPresented: $showBookInfo) {
            BookInfoSheet(
                book: activeBook,
                chapterCount: chapters.count,
                currentChapterIndex: currentChapterIndex,
                currentChapterTitle: (!chapters.isEmpty && currentChapterIndex < chapters.count) ? chapters[currentChapterIndex].title : "",
                sourceName: effectiveSource?.bookSourceName ?? activeBook.originName
            )
        }
        .sheet(isPresented: $showBookmarks) {
            bookmarksSheet
        }
        .sheet(isPresented: $showComments) {
            ReaderCommentsSheet(
                chapterTitle: currentLoadedChapter?.chapter.title ?? "",
                items: chapterCommentItems,
                chapterURL: chapterCommentURL
            )
        }
        .sheet(item: $directCommentTarget) { target in
            NativeCommentListSheet(target: target)
        }
        .sheet(isPresented: $showSourceSwitch) {
            SourceSwitchSheet(
                book: activeBook,
                currentSourceUrl: effectiveSource?.bookSourceUrl,
                onSelect: { newSource, candidate in
                    switchToSource(newSource, candidate)
                }
            )
        }
        .sheet(isPresented: $showTitleDesigner) {
            ChapterTitleDesignerView { export in
                readerConfig.chapterTitleHTMLTemplate = export.htmlTemplate
                readerConfig.chapterTitleProjectJSON = export.projectJSON
                readerConfig.chapterTitleCanvasHeight = export.canvasHeight
            }
        }
        .sheet(isPresented: $showReplaceRules) {
            ReplaceRulesView(bookUrl: activeBook.bookUrl, bookName: activeBook.name)
        }
        .sheet(isPresented: $showAggregateSearch) {
            NavigationView {
                SearchBookView()
            }
        }
        .alert("替换这一段", isPresented: $showReplaceInput) {
            TextField("替换成（留空 = 删除）", text: $replaceInput)
            Button("替换") { applyParagraphReplace() }
            Button("取消", role: .cancel) { }
        } message: {
            Text(String(selectedParagraphText.prefix(40)))
        }
        .task {
            readerConfig.loadLayout(for: activeBook.bookUrl)
            await loadTOCAndStart()
        }
        .onAppear { readingTickStart = Date() }
        .onAppear { loadReaderAssets() }
        .onDisappear { flushReadingTime() }
        .onDisappear {
            saveCurrentProgress()
            readerConfig.saveLayout(for: activeBook.bookUrl)
            audioService.stop()
        }
        .onChange(of: readerConfig.pageMode) { newMode in
            handlePageModeChange(to: newMode)
        }
        // 字号/行距/段间距/边距/页眉页脚一改，一页能装多少行就变了，必须重排，
        // 旧分页的行数未更新时，页面下半部分会空着
        .onChange(of: layoutSignature) { _ in
            // 拉滑杆会连着触发很多次，稍微等一下再重排，别每帧都排一遍
            paginationTask?.cancel()
            paginationTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                recomputePagination()
            }
        }
        // 亮度：盖一层黑，不动系统亮度
        .overlay {
            if readerConfig.brightness < 0.999 {
                Color.black
                    .opacity(1 - readerConfig.brightness)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            applyAutoNightIfNeeded()
        }
    }

    /// 把这一段的阅读时长记进统计
    private func flushReadingTime() {
        guard let start = readingTickStart else { return }
        let seconds = Int(Date().timeIntervalSince(start))
        readingTickStart = Date()
        guard seconds > 0 else { return }
        ReadingStatsStore.shared.addReading(seconds: seconds)
    }

    /// 自动夜间：22:00–07:00 切暗黑，白天回到原来那套主题
    private func applyAutoNightIfNeeded() {
        guard readerConfig.autoNight else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        let isNight = hour >= 22 || hour < 7
        let dayThemeKey = "reader_day_theme"
        if isNight {
            if readerConfig.theme != .dark {
                UserDefaults.standard.set(readerConfig.theme.rawValue, forKey: dayThemeKey)
                readerConfig.theme = .dark
            }
        } else if readerConfig.theme == .dark,
                  let saved = UserDefaults.standard.string(forKey: dayThemeKey),
                  let theme = ReaderTheme(rawValue: saved) {
            readerConfig.theme = theme
        }
    }


    // MARK: - 阅读页背景
    /// 底色 + 可选背景图，缩放到铺满（background-size: cover / position: center）。
    @ViewBuilder
    private var readerBackground: some View {
        ZStack {
            readerConfig.backgroundColor
            if readerConfig.backgroundImageEnabled,
               !readerConfig.backgroundImagePath.isEmpty,
               let image = platformImage(atPath: readerConfig.backgroundImagePath) {
                // 必须钉死在容器尺寸上再裁：不限制的话大图会把自己的原始尺寸撑进布局，
                // 整个阅读页跟着变大（横图甚至会触发转屏），上下还会露出主题色
                GeometryReader { geo in
                    image
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(CGFloat(backgroundImageScale))
                        .offset(x: CGFloat(backgroundImageOffsetX), y: CGFloat(backgroundImageOffsetY))
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
        }
    }

    private func platformImage(atPath path: String) -> Image? {
        // 沙盒绝对路径在 App 升级后会失效（容器 UUID 变了），读之前先解析一次
        let path = ReaderBackgroundStorage.resolve(path)
        if let cached = ReaderBackgroundImageCache.shared.image(for: path) { return cached }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let image = Self.decodeImage(data) else { return nil }
        ReaderBackgroundImageCache.shared.store(image, for: path)
        return image
    }

    private static func decodeImage(_ data: Data) -> Image? {
        #if canImport(UIKit)
        if let ui = UIImage(data: data) { return Image(uiImage: ui) }
        #elseif canImport(AppKit)
        if let ns = NSImage(data: data) { return Image(nsImage: ns) }
        #endif
        return nil
    }

    /// 选择器给的 URL 出沙箱就失效，必须拷进 App 自己的目录再记路径。
    private func importBackgroundImage(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            readerConfig.backgroundImagePath = url.path
            return
        }
        let folder = dir.appendingPathComponent("ReaderBackground", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let dest = folder.appendingPathComponent("background." + ext)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            ReaderBackgroundImageCache.shared.removeAll()
            readerConfig.backgroundImagePath = dest.path
        } catch {
            readerConfig.backgroundImagePath = url.path
        }
    }

    // MARK: - 正文段落（对齐 / 字距 / 下划线）
    /// 每章的标题：设计器里存过设计稿就渲染设计稿，否则用纯文字。
    /// 两条路径的间距口径一致，切换设计不应该跳版。
    @ViewBuilder
    private func chapterTitleView(chapterIndex: Int, title: String) -> some View {
        let width = max(120, readerContainerSize.width - readerConfig.paddingLeft - readerConfig.paddingRight)
        if readerConfig.hasDesignedChapterTitle {
            ChapterTitleHTMLView(
                htmlTemplate: readerConfig.chapterTitleHTMLTemplate,
                projectJSON: readerConfig.chapterTitleProjectJSON,
                width: width,
                chapterTitle: title,
                chapterNumber: "第 \(chapterIndex + 1) 章"
            )
            .padding(.leading, readerConfig.paddingLeft)
            .padding(.trailing, readerConfig.paddingRight)
            .padding(.top, readerConfig.chapterTopSpacing)
            .padding(.bottom, readerConfig.chapterTitleSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(title)
                .font(.system(size: readerConfig.fontSize * readerConfig.chapterTitleScale, weight: .semibold))
                .foregroundColor(chromeInk)
                .padding(.leading, readerConfig.paddingLeft)
                .padding(.trailing, readerConfig.paddingRight)
                .padding(.top, readerConfig.chapterTopSpacing)
                .padding(.bottom, readerConfig.chapterTitleSpacing)
        }
    }

    /// 两端对齐交给自定义排版控件，其余三档用原生 Text。
    @ViewBuilder
    private func bodyTextView(_ text: String,
                              chapterIndex: Int = -1,
                              blockId: Int = -1,
                              charAnnotations: [ReaderCharAnnotation] = [],
                              selectionStart: Int = -1,
                              selectionLength: Int = 0,
                              readingStart: Int = -1,
                              readingLength: Int = 0,
                              readingTint: Color? = nil,
                              useTextKit: Bool = false) -> some View {
        // 滚动模式一律走 UIKit 文本控件：字选要字符坐标，逐字标注也要能画在区间上，
        // SwiftUI Text 两样都给不了。对齐方式由 alignment 带过去。
        if readerConfig.textAlignment.isJustify || useTextKit {
            JustifiedBodyText(
                text: text,
                fontSize: readerConfig.fontSize,
                lineSpacing: readerConfig.lineSpacing,
                letterSpacing: readerConfig.letterSpacing,
                textColor: readerConfig.textColor,
                fontName: readerConfig.font.postScriptName,
                underlineEnabled: readerConfig.underlineEnabled,
                underlineColor: readerConfig.underlineColor,
                underlineStyle: readerConfig.underlinePattern.nsUnderlineStyle,
                chapterIndex: chapterIndex,
                blockId: blockId,
                charAnnotations: charAnnotations,
                selectionStart: selectionStart,
                selectionLength: selectionLength,
                readingStart: readingStart,
                readingLength: readingLength,
                readingTint: readingTint,
                alignment: readerConfig.textAlignment.isJustify ? .justified : coreTextAlignment
            )
        } else {
            bodyText(text, alignment: nativeTextAlignment)
        }
    }

    /// 滚动模式的一段：禁则处理会插零宽连接符，字符下标跟着变，
    /// 标注区间和字选都得先换算到显示文本上，不然会偏几个字。
    private func scrollBody(block: ContentBlock, chapterIndex: Int) -> some View {
        let rendered = applyingKinsoku(block.text)
        let renderedNS = rendered as NSString
        let marks: [ReaderCharAnnotation] = chapterIndex == currentChapterIndex
            ? charAnnotationRangesForCurrentChapter
                .filter { $0.paragraphId == block.id }
                .compactMap { item in
                    let start = renderedIndex(fromOriginal: item.start, in: renderedNS)
                    let end = renderedIndex(fromOriginal: item.start + item.length, in: renderedNS)
                    guard end > start else { return nil }
                    return ReaderCharAnnotation(paragraphId: item.paragraphId,
                                                start: start,
                                                length: end - start,
                                                style: item.style)
                }
            : []
        var selStart = -1
        var selLength = 0
        if let sel = charSelection, sel.paragraphId == block.id, chapterIndex == currentChapterIndex {
            let start = renderedIndex(fromOriginal: sel.start, in: renderedNS)
            let end = renderedIndex(fromOriginal: sel.start + sel.length, in: renderedNS)
            selStart = start
            selLength = max(0, end - start)
        }
        // 朗读段整段都是底色范围；真正铺在哪几个字上由文本控件自己按字形算
        var readingStart = -1
        var readingLength = 0
        if chapterIndex == currentChapterIndex, isReadingBlock(block.id) {
            readingStart = 0
            readingLength = renderedNS.length
        }
        return bodyTextView(rendered,
                            chapterIndex: chapterIndex,
                            blockId: block.id,
                            charAnnotations: marks,
                            selectionStart: selStart,
                            selectionLength: selLength,
                            readingStart: readingStart,
                            readingLength: readingLength,
                            readingTint: readingLength > 0 ? readingTint : nil,
                            useTextKit: true)
    }

    /// 原文下标 → 显示文本下标（数一数前面插了几个零宽连接符）
    private func renderedIndex(fromOriginal index: Int, in ns: NSString) -> Int {
        guard ns.length > 0 else { return 0 }
        var seen = 0
        var cursor = 0
        while cursor < ns.length {
            if ns.character(at: cursor) != 0x2060 {
                if seen == index { return cursor }
                seen += 1
            }
            cursor += 1
        }
        return ns.length
    }

    /// 显示文本下标 → 原文下标（长按落点换算用）
    private func originalIndex(fromRendered index: Int, in ns: NSString) -> Int {
        var seen = 0
        var cursor = 0
        while cursor < ns.length && cursor < index {
            if ns.character(at: cursor) != 0x2060 { seen += 1 }
            cursor += 1
        }
        return seen
    }

    private var nativeTextAlignment: TextAlignment {
        switch readerConfig.textAlignment {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    @ViewBuilder
    private func bodyText(_ text: String, alignment: TextAlignment) -> some View {
        let base = Text(text)
            .font(.system(size: readerConfig.fontSize))
            .foregroundColor(readerConfig.textColor)

        // 下划线与字距都是 Text 专属修饰符，必须趁还是 Text 的时候应用
        let decorated: Text = {
            guard readerConfig.underlineEnabled else { return base }
            if #available(iOS 16.0, macOS 13.0, *) {
                return base.underline(
                    true,
                    pattern: readerConfig.underlinePattern.lineStyle,
                    color: readerConfig.underlineColor ?? readerConfig.textColor
                )
            } else {
                return base.underline(true, color: readerConfig.underlineColor ?? readerConfig.textColor)
            }
        }()

        if #available(iOS 16.0, macOS 13.0, *) {
            decorated
                .kerning(readerConfig.letterSpacing)
                .lineSpacing(readerConfig.lineSpacing)
                .multilineTextAlignment(alignment)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            decorated
                .lineSpacing(readerConfig.lineSpacing)
                .multilineTextAlignment(alignment)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 段间分隔线，条数由设置决定
    @ViewBuilder
    private func paragraphSeparator() -> some View {
        if readerConfig.paragraphSeparatorLines > 0 {
            VStack(spacing: 3) {
                ForEach(0..<readerConfig.paragraphSeparatorLines, id: \.self) { _ in
                    Rectangle()
                        .fill(readerConfig.paragraphSeparatorColor)
                        .frame(height: 0.5)
                }
            }
            .padding(.leading, readerConfig.paddingLeft)
            .padding(.trailing, readerConfig.paddingRight)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Mode 1: Infinite Scroll Down (连续滚动)
    private var infiniteScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    GeometryReader { probeGeo in
                        Color.clear.preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: probeGeo.frame(in: .named("readerScrollCoordinate")).minY
                        )
                    }
                    .frame(height: 0)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(loadedChapters) { loadedCh in
                            // 段间距由每段自己的下间距给，块之间不再叠一层行距，
                            // 这样「段间距」滑块和段落自身的 margin-bottom 才是一个口径
                            VStack(alignment: .leading, spacing: 0) {
                                // Chapter Title
                                chapterTitleView(chapterIndex: loadedCh.chapter.index, title: loadedCh.chapter.title)
                                    .id("chapter_\(loadedCh.chapter.index)")
                                    .onAppear {
                                        if currentChapterIndex != loadedCh.chapter.index {
                                            currentChapterIndex = loadedCh.chapter.index
                                            BookStore.shared.updateProgress(bookUrl: activeBook.bookUrl, chapterIndex: currentChapterIndex, chapterTitle: loadedCh.chapter.title, chapterPos: currentChapterCharOffset())
                                            preCacheNeighbors(around: currentChapterIndex)
                                        }
                                    }

                                // Chapter Paragraphs and Images
                                ForEach(loadedCh.blocks) { block in
                                    if block.isImage, let urlStr = block.imageUrl {
                                        ChapterImageView(urlString: urlStr, referer: effectiveSource?.bookSourceUrl)
                                            .padding(.leading, readerConfig.paddingLeft)
                                            .padding(.trailing, readerConfig.paddingRight)
                                            .padding(.bottom, readerConfig.paragraphSpacing)
                                            .id("block_\(loadedCh.chapter.index)_\(block.id)")
                                            .background(
                                                GeometryReader { geo in
                                                    Color.clear
                                                        .preference(
                                                            key: ReaderScrollPreferenceKey.self,
                                                            value: [BlockFrameInfo(
                                                                chapterIndex: loadedCh.chapter.index,
                                                                blockId: block.id,
                                                                minY: geo.frame(in: .named("readerScrollCoordinate")).minY,
                                                                maxY: geo.frame(in: .named("readerScrollCoordinate")).maxY,
                                                                rect: geo.frame(in: .global)
                                                            )]
                                                        )
                                                }
                                            )
                                    } else if block.commentCount == -2 {
                                        godReviewCard(block)
                                            .padding(.leading, readerConfig.paddingLeft)
                                            .padding(.trailing, readerConfig.paddingRight)
                                            .padding(.bottom, readerConfig.paragraphSpacing)
                                            .id("block_\(loadedCh.chapter.index)_\(block.id)")
                                            .background(
                                                GeometryReader { geo in
                                                    Color.clear.preference(
                                                        key: ReaderScrollPreferenceKey.self,
                                                        value: [BlockFrameInfo(
                                                            chapterIndex: loadedCh.chapter.index,
                                                            blockId: block.id,
                                                            minY: geo.frame(in: .named("readerScrollCoordinate")).minY,
                                                            maxY: geo.frame(in: .named("readerScrollCoordinate")).maxY,
                                                            rect: geo.frame(in: .global)
                                                        )]
                                                    )
                                                }
                                            )
                                    } else {
                                        scrollBody(block: block, chapterIndex: loadedCh.chapter.index)
                                            .padding(.leading, readerConfig.paddingLeft)
                                            .padding(.trailing, readerConfig.paddingRight)
                                            .padding(.bottom, readerConfig.paragraphSpacing)
                                            // 段落级长按：连续滚动里一个 block 就是一段
                                            .onLongPressGesture {
                                                selectScrollParagraph(block, chapterIndex: loadedCh.chapter.index)
                                            }
                                            .onTapGesture {
                                                if block.commentCount == -1 {
                                                    showComments = true
                                                } else if block.commentCount == -2, let url = block.commentURL {
                                                    directCommentTarget = ReviewTarget(url: url, title: "段评")
                                                }
                                            }
                                            .overlay(alignment: .bottomTrailing) {
                                                if block.commentCount > 0, let url = block.commentURL {
                                                    paragraphCommentBadge(block, url: url)
                                                        .offset(x: -2, y: 7)
                                                }
                                            }
                                            .background(scrollAnnotationBackground(for: block, chapterIndex: loadedCh.chapter.index))
                                            .overlay(alignment: .leading) {
                                                // 朗读位置：段左一条竖线，比只铺底色更好找
                                                if isReadingBlock(block.id) {
                                                    Rectangle()
                                                        .fill(nierPalette.accent.opacity(0.85))
                                                        .frame(width: 3)
                                                        .padding(.vertical, 1)
                                                }
                                            }
                                            .overlay(alignment: .bottom) {
                                                scrollAnnotationUnderline(for: block, chapterIndex: loadedCh.chapter.index)
                                            }
                                            .id("block_\(loadedCh.chapter.index)_\(block.id)")
                                            .background(
                                                GeometryReader { geo in
                                                    Color.clear
                                                        .preference(
                                                            key: ReaderScrollPreferenceKey.self,
                                                            value: [BlockFrameInfo(
                                                                chapterIndex: loadedCh.chapter.index,
                                                                blockId: block.id,
                                                                minY: geo.frame(in: .named("readerScrollCoordinate")).minY,
                                                                maxY: geo.frame(in: .named("readerScrollCoordinate")).maxY,
                                                                rect: geo.frame(in: .global)
                                                            )]
                                                        )
                                                }
                                            )
                                    }

                                    // 段间分隔线：最后一段不加，免得贴着下一章
                                    if block.id != loadedCh.blocks.last?.id {
                                        paragraphSeparator()
                                    }
                                }

                                // Empty space between chapters (pure blank space, no lines or text prompts)
                                Color.clear
                                    .frame(height: readerConfig.chapterBottomSpacing + readerConfig.chapterTopSpacing)
                                    .id("chapter_end_\(loadedCh.chapter.index)")
                                    .onAppear {
                                        if loadedCh.chapter.index < chapters.count - 1 {
                                            loadNextChapterForInfiniteScroll(after: loadedCh.chapter.index)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .coordinateSpace(name: "readerScrollCoordinate")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { minY in
                let scrollY = -minY
                handleScrollOffsetChanged(scrollY: scrollY)
            }
            .onPreferenceChange(ReaderScrollPreferenceKey.self) { frames in
                handleBlockFramesChanged(frames)
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification)) { notification in
                guard readerConfig.pageMode == .scroll else { return }
                if let clipView = notification.object as? NSClipView {
                    let scrollY = clipView.documentVisibleRect.origin.y
                    handleScrollOffsetChanged(scrollY: scrollY)
                }
            }
            #endif
            .id(scrollSessionId)
            .refreshable {
                if let first = loadedChapters.first, first.chapter.index > 0 {
                    let prevIndex = first.chapter.index - 1
                    if let prevLoaded = await getOrFetchChapter(at: prevIndex) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            loadedChapters.insert(prevLoaded, at: 0)
                            currentChapterIndex = prevIndex
                            scrollToChapterId = "chapter_end_\(prevIndex)"
                        }
                        BookStore.shared.updateProgress(bookUrl: activeBook.bookUrl, chapterIndex: prevIndex, chapterTitle: prevLoaded.chapter.title)
                        preCacheNeighbors(around: prevIndex)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // 听书中这一下已经被「点段起读」用掉了，别再顺手把工具栏呼出来
                if Date().timeIntervalSince(lastReadingTapAt) < 0.5 { return }
                // 选段中点别处：退出选段、保留这次的更改
                if selectedBlockRange != nil || charSelection != nil {
                    clearParagraphSelection()
                    return
                }
                toggleControls("scroll-tap")
            }
            .onAppear {
                if let target = scrollToChapterId {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        let anchor: UnitPoint = target.hasPrefix("chapter_end") ? .center : .top
                        proxy.scrollTo(target, anchor: anchor)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            proxy.scrollTo(target, anchor: anchor)
                            scrollToChapterId = nil
                        }
                    }
                }
            }
            .onChange(of: scrollToChapterId) { target in
                if let target = target {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        let anchor: UnitPoint = target.hasPrefix("chapter_end") ? .center : .top
                        proxy.scrollTo(target, anchor: anchor)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            proxy.scrollTo(target, anchor: anchor)
                            scrollToChapterId = nil
                        }
                    }
                }
            }
            .onChange(of: audioService.readingBlockId) { blockId in
                // 听书翻到下一段：那一段已经离开屏幕中心就把它滚回来，
                // 差得不多就不动 —— 每段都跳一下会晕。
                guard readerConfig.pageMode == .scroll, let blockId, readingChapterIndex >= 0 else { return }
                // UIScreen 只有 iOS 有；macOS 那边（SPM 的 swift build / swift test）只是
                // 过一遍类型检查，不跑这段逻辑，给 0 就够了。
                #if os(iOS)
                let screenCenter = UIScreen.main.bounds.midY
                #else
                let screenCenter: CGFloat = 0
                #endif
                if let rect = scrollHitRegistry.rect(forBlockId: blockId, chapterIndex: readingChapterIndex),
                   abs(rect.midY - screenCenter) < 40 {
                    AppLog.write("[听书] 段 \(blockId) 还在视野里（偏差 \(Int(rect.midY - screenCenter))pt），不回中")
                    return
                }
                AppLog.write("[听书] 回中 block \(blockId) · 第 \(readingChapterIndex + 1) 章")
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo("block_\(readingChapterIndex)_\(blockId)", anchor: .center)
                }
            }
        }
    }

    private func handleBlockFramesChanged(_ frames: [BlockFrameInfo]) {
        guard !frames.isEmpty else { return }
        // 长按命中表每轮重铺：布局变了几何就跟着变，离屏段落顺手清掉
        scrollHitRegistry.replace(with: frames)
        if let active = frames.first(where: { $0.minY <= 140 && $0.maxY >= 20 }) ??
                        frames.min(by: { abs($0.minY - 50) < abs($1.minY - 50) }) {
            if self.currentChapterIndex != active.chapterIndex {
                self.currentChapterIndex = active.chapterIndex
                self.preCacheNeighbors(around: active.chapterIndex)
            }
            self.currentReadingBlockId = active.blockId
        }
    }

    private func handleScrollOffsetChanged(scrollY: CGFloat) {
        // 下拉动画期间整页在位移，探针读到的偏移是「假的」，这时候按它换章/重排
        // 会让内容突变、文字重排变形。下拉结束再恢复。
        guard !isPullActive else { return }
        scrollOffsetY = scrollY
        guard scrollY > 0, !loadedChapters.isEmpty else { return }
        let width = max(240, readerContainerSize.width)
        let usableWidth = max(200, width - 40)
        let charsPerLine = max(10, Int(usableWidth / readerConfig.fontSize))
        let lineHeight = readerConfig.fontSize * 1.25 + readerConfig.lineSpacing
        // 跟真实布局对齐：标题 = 字高 + 章前距 + 标题下距
        let titleHeight = (readerConfig.fontSize * readerConfig.chapterTitleScale) * 1.3
            + readerConfig.chapterTopSpacing
            + readerConfig.chapterTitleSpacing

        let targetY = scrollY + 60.0
        var currentY: CGFloat = 0

        for loadedCh in loadedChapters {
            currentY += titleHeight

            for block in loadedCh.blocks {
                let blockH: CGFloat
                if block.isImage {
                    blockH = 260.0
                } else {
                    let lines = max(1, Int(ceil(Double(block.text.count) / Double(charsPerLine))))
                    blockH = CGFloat(lines) * lineHeight + readerConfig.paragraphSpacing
                }

                if targetY >= currentY && targetY < currentY + blockH {
                    if self.currentChapterIndex != loadedCh.chapter.index {
                        self.currentChapterIndex = loadedCh.chapter.index
                        self.preCacheNeighbors(around: loadedCh.chapter.index)
                    }
                    self.currentReadingBlockId = block.id
                    return
                }
                currentY += blockH
            }

            currentY += readerConfig.chapterBottomSpacing + readerConfig.chapterTopSpacing
            if targetY < currentY {
                if self.currentChapterIndex != loadedCh.chapter.index {
                    self.currentChapterIndex = loadedCh.chapter.index
                }
                return
            }
        }
    }

    // MARK: - Mode 3: Simulation (仿真翻页，系统卷页效果)
    @ViewBuilder
    private var simulationPageView: some View {
        #if os(iOS)
        let pages = currentLoadedChapter?.pages ?? []
        if pages.isEmpty {
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        } else {
            let commentMap = Dictionary(uniqueKeysWithValues:
                (currentLoadedChapter?.blocks ?? []).compactMap { block -> (Int, (count: Int, url: String))? in
                    guard block.commentCount > 0, let url = block.commentURL else { return nil }
                    return (block.id, (block.commentCount, url))
                }
            )
            PageCurlPager(
                pages: pages,
                loadedChapterIndex: currentLoadedChapter?.chapter.index ?? -1,
                chapterTitle: currentLoadedChapter?.chapter.title,
                fontSize: readerConfig.fontSize,
                lineSpacing: readerConfig.lineSpacing,
                letterSpacing: readerConfig.letterSpacing,
                paragraphSpacing: readerConfig.paragraphSpacing,
                firstLineIndent: readerConfig.firstLineIndent,
                weightLevel: readerConfig.weightLevel,
                chineseConversion: readerConfig.chineseConversion,
                fontPostScriptName: readerConfig.font.postScriptName,
                boldPostScriptName: readerConfig.font.boldPostScriptName,
                textAlignment: readerConfig.textAlignment,
                underlineEnabled: readerConfig.underlineEnabled,
                underlineColor: readerConfig.underlineColor,
                paragraphSeparatorLines: readerConfig.paragraphSeparatorLines,
                paragraphSeparatorColor: readerConfig.paragraphSeparatorColor,
                textColor: readerConfig.textColor,
                accentColor: nierPalette.accent,
                onAccentColor: nierPalette.background,
                reviewStyle: reviewCardStyle,
                reviewURLs: reviewURLMap,
                backgroundColor: readerConfig.backgroundColor,
                backgroundImage: readerConfig.backgroundImageEnabled
                    ? platformImage(atPath: readerConfig.backgroundImagePath)
                    : nil,
                chapterTitleScale: readerConfig.chapterTitleScale,
                shortTitleLength: readerConfig.shortTitleLength,
                onSelectParagraph: { page, line, offset in
                    selectCharacters(atLine: line, charOffset: offset, in: page)
                },
                selectedRange: selectedBlockRange,
                charSelection: charSelection,
                isReadingSession: { audioService.hasReadingSession },
                charAnnotations: charAnnotationRangesForCurrentChapter,
                annotationRanges: annotationRangesForCurrentChapter,
                readingBlockId: readingParagraphOrdinal,
                readingTintColor: readingTint,
                customDatePattern: readerConfig.customDatePattern,
                customBarText: readerConfig.customBarText,
                titleHTMLTemplate: readerConfig.chapterTitleHTMLTemplate,
                titleProjectJSON: readerConfig.chapterTitleProjectJSON,
                paddingTop: readerConfig.paddingTop,
                paddingBottom: readerConfig.paddingBottom,
                paddingLeft: readerConfig.paddingLeft,
                paddingRight: readerConfig.paddingRight,
                headerOffset: readerConfig.headerOffset,
                footerOffset: readerConfig.footerOffset,
                titleAlignment: readerConfig.titleAlignment,
                showHeader: readerConfig.headerEnabled,
                showFooter: readerConfig.footerEnabled,
                barDivider: readerConfig.barDivider,
                headerSlots: [readerConfig.headerLeft, readerConfig.headerCenter, readerConfig.headerRight],
                footerSlots: [readerConfig.footerLeft, readerConfig.footerCenter, readerConfig.footerRight],
                topInset: screenTopInset,
                bottomInset: screenBottomInset,
                bookName: activeBook.name,
                chapterTitleText: (!chapters.isEmpty && currentChapterIndex < chapters.count) ? chapters[currentChapterIndex].title : "",
                chapterIndex: currentChapterIndex,
                chapterCount: chapters.count,
                startIndex: currentPageIndex,
                onIndexChange: { newIndex in
                    currentPageIndex = newIndex
                    saveCurrentProgress()
                    followReadingAfterPageChange()
                    // 翻到倒数第二页就把下一章拉起来，别等翻过头才现拉
                    if let cur = currentLoadedChapter, newIndex >= cur.pages.count - 2 {
                        preCacheNeighbors(around: currentChapterIndex)
                    }
                },
                onReachEnd: {
                    if currentChapterIndex < chapters.count - 1 {
                        pageTurnForward = true
                        withAnimation(pageTurnAnimation) {
                            jumpToChapter(currentChapterIndex + 1)
                        }
                    }
                },
                onReachStart: {
                    if currentChapterIndex > 0 {
                        pageTurnForward = false
                        withAnimation(pageTurnAnimation) {
                            jumpToChapter(currentChapterIndex - 1, toEnd: true)
                        }
                    }
                },
                onTapCenter: {
                    if charSelection != nil {
                        clearParagraphSelection()
                        return
                    }
                    toggleControls("pager-tap-center")
                },
                commentMap: commentMap,
                onCommentTap: { url in
                    directCommentTarget = ReviewTarget(url: url, title: "段评")
                }
            )
            // 这里不要再挂 .id / .transition：给 pager 换 id 会让 SwiftUI 整块重建，
            // 换章就变成左右位移、没有卷页动画了。换章的卷页由 pager 内部做。
            // 仿真翻页整页也要贴屏幕物理边缘：只忽略底部的话，页眉那条会从安全区下面起算，
            // 距顶调不到灵动岛位置时，页脚贴底而顶部留空
            .ignoresSafeArea(edges: .all)
            // 朗读往下走、那一段已经不在当前页了：跟页读开着就把页翻过去，
            // 不然高亮跑到屏幕外，看着就像「高亮跟随没了」
            .onChange(of: audioService.readingBlockId) { blockId in
                followPageToReadingBlock(blockId)
            }
        }
        #else
        pageByPageView
        #endif
    }

    // MARK: - Mode 2: Page by Page (左右翻页)
    private var pageByPageView: some View {
        GeometryReader { geo in
            let pages = currentLoadedChapter?.pages ?? []

            ZStack {
                if pages.isEmpty || currentPageIndex >= pages.count {
                    VStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else {
                    let pageBlocks = pages[currentPageIndex]
                    let usableWidth = max(200, readerContainerSize.width - readerConfig.paddingLeft - readerConfig.paddingRight)

                    // GeometryReader 是贪高的：不把正文这块钉死高度，它会吃掉整页，
                    // 把 19pt 的页脚挤出可视区
                    let barHeight: CGFloat = 19
                    // 「距顶/距底」是离屏幕上沿/下沿的绝对距离，0 = 贴边。
                    // 整页本来就是贴屏幕物理边缘画的，这两条要一起算进预留高度。
                    let headerGap = readerConfig.headerEnabled ? readerConfig.headerGap : 0
                    let footerGap = readerConfig.footerEnabled ? readerConfig.footerGap : 0
                    let reservedForBars = (headerGap + barHeight) + (footerGap + barHeight)
                    let contentHeight = max(80, geo.size.height - reservedForBars)

                    VStack(spacing: 0) {
                        // 页眉那块高度直接空出来
                        Color.clear.frame(height: readerConfig.headerEnabled ? headerGap + barHeight : 0)

                        // 正文放进固定高度的容器里：正文再长也只在这块里截，顶不飞页脚
                        GeometryReader { _ in
                        VStack(alignment: .leading, spacing: 0) {
                        // If it's page 0, display Chapter Title at top
                        if currentPageIndex == 0, readerConfig.titleAlignment != .hidden, let cur = currentLoadedChapter {
                            chapterTitleView(chapterIndex: cur.chapter.index, title: cur.chapter.title)
                                .frame(maxWidth: .infinity, alignment: readerConfig.titleAlignment == .center ? .center : .leading)
                        }

                        // Page Content
                        if let block = pageBlocks.first, block.commentCount == -2 {
                            GodReviewCardView(
                                text: block.text,
                                imageURL: block.imageUrl,
                                referer: effectiveSource?.bookSourceUrl,
                                accent: nierPalette.accent,
                                textColor: nierPalette.ink,
                                onAccentColor: nierPalette.background,
                                alignment: reviewCardStyle.alignment
                            ) {
                                if let url = block.commentURL {
                                    directCommentTarget = ReviewTarget(url: url, title: "段评")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else if pageBlocks.first?.isImage == true, let urlStr = pageBlocks.first?.imageUrl {
                            ChapterImageView(urlString: urlStr, referer: effectiveSource?.bookSourceUrl)
                        } else {
                            let lines = pageBlocks.map { $0.text }
                            let isParagraphEnd = pageBlocks.map { $0.imageUrl == "p_end" }
                            let effectiveLineHeight = readerConfig.fontSize * 1.25 + readerConfig.lineSpacing
                            // 页面最后一行是段尾的话，它后面的段间距是看不见的空白，不该占高度
                            let trailingSpacing = isParagraphEnd.last == true ? 1 : 0
                            let paragraphCount = CGFloat(isParagraphEnd.filter { $0 }.count - trailingSpacing)
                            // 一页排不满时把剩下的高度匀进段间距，正文才会贴到页脚
                            let titleReserved = currentPageIndex == 0
                                ? estimatedTitleHeight(currentLoadedChapter?.chapter.title ?? "")
                                : 0
                            let filledBase = CGFloat(lines.count) * effectiveLineHeight
                            // 余量要把段间距本身先扣掉再匀，否则整页会超出可用高度
                            let slack = max(0, contentHeight - readerConfig.paddingTop - readerConfig.paddingBottom
                                            - titleReserved - filledBase
                                            - paragraphCount * readerConfig.paragraphSpacing - 10)
                            let extraPerParagraph = paragraphCount > 0
                                ? min(slack / paragraphCount, effectiveLineHeight)
                                : 0
                            // 关掉「页末匀空白」就不匀，段间距老老实实按设置走
                            let appliedExtra = readerConfig.justifyLastPage ? extraPerParagraph : 0
                            let pageContentHeight = filledBase
                                + paragraphCount * (readerConfig.paragraphSpacing + appliedExtra)
                            let commentMap = Dictionary(uniqueKeysWithValues:
                                (currentLoadedChapter?.blocks ?? []).compactMap { block -> (Int, (count: Int, url: String))? in
                                    guard block.commentCount > 0, let url = block.commentURL else { return nil }
                                    return (block.id, (block.commentCount, url))
                                }
                            )

                            CoreTextPageView(
                                lines: lines,
                                isParagraphEnd: isParagraphEnd,
                                fontSize: readerConfig.fontSize,
                                lineSpacing: readerConfig.lineSpacing,
                                textColor: readerConfig.textColor,
                                width: usableWidth,
                                height: pageContentHeight,
                                letterSpacing: readerConfig.letterSpacing,
                                paragraphSpacing: readerConfig.paragraphSpacing + appliedExtra,
                                firstLineIndent: readerConfig.firstLineIndent,
                                weightLevel: readerConfig.weightLevel,
                                chineseConversion: readerConfig.chineseConversion,
                                fontPostScriptName: readerConfig.font.postScriptName,
                                boldPostScriptName: readerConfig.font.boldPostScriptName,
                                textAlignment: readerConfig.textAlignment,
                                underlineEnabled: readerConfig.underlineEnabled,
                                underlineColor: readerConfig.underlineColor,
                                paragraphSeparatorLines: readerConfig.paragraphSeparatorLines,
                               paragraphSeparatorColor: readerConfig.paragraphSeparatorColor,
                               lineBlockIds: pageBlocks.map(\.id),
                               lineParagraphIds: pageBlocks.map(\.paragraphId),
                               lineCharStarts: pageBlocks.map(\.charStart),
                               selectedRange: selectedBlockRange,
                               charSelection: charSelection,
                               charAnnotations: charAnnotationRangesForCurrentChapter,
                               annotationRanges: annotationRangesForCurrentChapter,
                               onLongPressLine: { line, charOffset in
                                   selectCharacters(atLine: line, charOffset: charOffset, in: pageBlocks)
                               },
                               readingBlockId: readingParagraphOrdinal,
                               readingTintColor: readingTint,
                               commentMap: commentMap,
                               pageBackgroundColor: readerConfig.backgroundColor,
                               reviewAccentColor: nierPalette.accent,
                               reviewStyle: reviewCardStyle,
                               reviewURLs: reviewURLMap,
                               onCommentTap: { url in
                                   directCommentTarget = ReviewTarget(url: url, title: "段评")
                               }
                           )
                            .frame(width: usableWidth, height: pageContentHeight, alignment: .topLeading)
                        }

                        Spacer(minLength: 0)
                        }
                        .padding(.leading, readerConfig.paddingLeft)
                        .padding(.trailing, readerConfig.paddingRight)
                        .padding(.top, readerConfig.paddingTop)
                        .padding(.bottom, readerConfig.paddingBottom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        .frame(height: contentHeight)
                        .clipped()

                        // 页脚那块高度直接空出来
                        Color.clear.frame(height: readerConfig.footerEnabled ? footerGap + barHeight : 0)
                    }
                    .overlay(alignment: .top) {
                        if readerConfig.headerEnabled {
                            statusBar(left: readerConfig.headerLeft, center: readerConfig.headerCenter, right: readerConfig.headerRight, extendEdge: .top)
                                .padding(.top, headerGap)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if readerConfig.footerEnabled {
                            statusBar(left: readerConfig.footerLeft, center: readerConfig.footerCenter, right: readerConfig.footerRight, extendEdge: .bottom)
                                .padding(.bottom, footerGap)
                        }
                    }
                    .offset(x: dragOffset)
                    .id("page_\(currentChapterIndex)_\(currentPageIndex)")
                    .transition(pageTransition)
                }

                // 点击区 + 拖拽合成一层手势。
                // 子视图挂点按手势会抢走父级的拖拽，只剩边缘能滑。所以点按和拖拽合成一层。
                Color.clear
                    .contentShape(Rectangle())
            }
            .contentShape(Rectangle())
            .onAppear {
                updateContainerSizeIfNeeded(geo.size)
            }
            .onChange(of: geo.size) { newSize in
                updateContainerSizeIfNeeded(newSize)
            }
            .gesture(
                // minimumDistance 0：同一个手势同时管点击和滑动，位移小就是点击
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        // 字选模式只让手柄动，整页不再跟手翻页
                        guard charSelection == nil else { return }
                        // 横着拖才跟手，竖着划过名单不算翻页
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        guard hypot(value.translation.width, value.translation.height) > 8 else { return }
                        var dx = value.translation.width
                        let total = pages.count
                        let canForward = currentPageIndex < total - 1 || currentChapterIndex < chapters.count - 1
                        let canBackward = currentPageIndex > 0 || currentChapterIndex > 0
                        // 到头了就拖不动，只给一点点回弹的手感
                        if (dx < 0 && !canForward) || (dx > 0 && !canBackward) {
                            dx *= 0.22
                        }
                        dragOffset = dx
                    }
                    .onEnded { value in
                        let width = max(200, geo.size.width)
                        if !showControls, value.translation.height >= 70,
                           abs(value.translation.height) > abs(value.translation.width) * 2 {
                            finishBookmarkPull()
                            return
                        }
                        let moved = hypot(value.translation.width, value.translation.height)
                        // 字选模式：点一下别处退出，拖动不翻页
                        if charSelection != nil {
                            if moved < 8, !tapSuppressor.isActive {
                                clearParagraphSelection()
                            }
                            return
                        }
                        // 位移很小 = 点击：左 30% 上一页，右 30% 下一页，中间开关工具栏
                        if moved < 8 {
                            // 刚长按选中过段落：松手这一次不能再当点击使唤，否则操作栏会被菜单盖掉
                            guard !tapSuppressor.isActive else { return }
                            #if os(iOS)
                            // SwiftUI 的 global 坐标不含顶部安全区；UIKit 窗口坐标含，
                            // 直接传会整体偏一条状态栏，气泡就点不中。
                            let windowPoint = CGPoint(
                                x: value.startLocation.x,
                                y: value.startLocation.y + safeInsets.top
                            )
                            if CoreTextUIView.triggerCommentTap(atWindowPoint: windowPoint) {
                                return
                            }
                            #endif
                            // 选段中点别处：退出选段、保留这次的更改
                            if selectedBlockRange != nil {
                                clearParagraphSelection()
                                return
                            }
                            let x = value.startLocation.x - geo.frame(in: .global).minX
                            // 热评页：左右边缘仍是翻页区，中间点卡片才开段评
                            if x >= width * 0.3, x <= width * 0.7,
                               let cur = currentLoadedChapter,
                               currentPageIndex < cur.pages.count,
                               let block = cur.pages[currentPageIndex].first,
                               block.commentCount == -2 {
                                if let url = block.commentURL {
                                    directCommentTarget = ReviewTarget(url: url, title: "段评")
                                }
                                return
                            }
                            // 朗读会话期间：正文哪儿点一下都是呼菜单，不再按左右 30% 翻页。
                            // 正文几乎铺满整行，左右 30% 里全是字，用户想叫菜单结果翻页，
                            // 顺带还把这页的朗读锚点拽走——上一版「开了朗读就点不出菜单」就是这个。
                            // 翻页留给滑动和底栏，朗读不会因此被点没。
                            if audioService.hasReadingSession {
                                toggleControls("listen-tap")
                                return
                            }
                            if x < width * 0.3 {
                                turnPage(forward: false)
                            } else if x > width * 0.7 {
                                turnPage(forward: true)
                            } else {
                                toggleControls("pager-drag-center")
                            }
                            return
                        }
                        let projected = value.predictedEndTranslation.width
                        let dragged = value.translation.width
                        let threshold = width * 0.22
                        // 快速甩动按投影距离判，慢拖按实际位移判，避免拖到一半松手不翻页
                        let forwardDistance = min(projected, dragged)
                        let backwardDistance = max(projected, dragged)
                        if forwardDistance < -threshold {
                            turnPage(forward: true)
                        } else if backwardDistance > threshold {
                            turnPage(forward: false)
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
        }
    }

    /// 分页要用的容器尺寸。
    /// 按页翻时整页贴屏幕物理边缘（= 安全区高度 + 上下安全区），
    /// 用安全区高度当页高会少算约 120pt，每页末尾空出两三行。
    private func paginationContainerSize(for size: CGSize) -> CGSize {
        guard readerConfig.pageMode != .scroll else {
            return CGSize(width: size.width, height: max(200, size.height - 26))
        }
        let bleedTop = max(0, safeInsets.top)
        let bleedBottom = max(0, safeInsets.bottom)
        return CGSize(width: size.width, height: max(200, size.height + bleedTop + bleedBottom))
    }

    private func updateContainerSizeIfNeeded(_ size: CGSize) {
        // 下拉期间整页在位移，几何读数不可信；这时重排会让字号/行距当场变样。
        guard !isPullActive, pagePullOffset == 0 else { return }
        guard size.width > 100 && size.height > 100 else { return }
        if abs(size.width - readerContainerSize.width) > 6 || abs(size.height - readerContainerSize.height) > 6 {
            DispatchQueue.main.async {
                self.readerContainerSize = size
                self.recomputePagination()
            }
        }
    }

    /// 当前页第一段的 block id：页首可能是图片、热评卡片，跳过去找第一段能读的。
    /// 分页里的块是「行」——id 是行号（10000 起），paragraphId 才是正文段号；
    /// 音频队列里存的是段号，所以先认 paragraphId，再退回 id。
    /// 滚动模式没有「页」，就用视野里那一段。
    private var currentPageFirstBlockId: Int? {
        if readerConfig.pageMode == .scroll {
            if currentReadingBlockId > 0 { return currentReadingBlockId }
            return readingItemsForCurrentChapter.first?.id
        }
        guard let cur = currentLoadedChapter, currentPageIndex < cur.pages.count else { return nil }
        let items = readingItemsForCurrentChapter
        let page = cur.pages[currentPageIndex]
        guard let firstLine = page.first else { return items.first?.id }
        var anchor = firstLine
        // 页顶那行常常是上一页延续下来的残段（charStart > 0 说明不是从段首开始）。
        // 拿它当起点，就会「读的是上一段整段、高亮只涂在页顶一小角」，看着像差了一段。
        // 本页真正的起点是下一个新段。
        if firstLine.charStart > 0 {
            let firstPid = firstLine.paragraphId > 0 ? firstLine.paragraphId : firstLine.id
            if let next = page.first(where: { ($0.paragraphId > 0 ? $0.paragraphId : $0.id) != firstPid }) {
                anchor = next
            }
        }
        let anchorId = anchor.paragraphId > 0 ? anchor.paragraphId : anchor.id
        // 1) 编号直接对得上：绝大多数情况下走这条
        if items.contains(where: { $0.id == anchorId }) { return anchorId }
        // 2) 编号对不上（缓存正文和线上正文各一套 id，或者页是旧分页留下的）：
        //    按 blocks 的先后顺序数「这一页之前有多少段可读」，换算成队列里的第几段
        guard let blockIndex = cur.blocks.firstIndex(where: { $0.id == anchorId }) else {
            return items.first?.id
        }
        var ordinal = 0
        for block in cur.blocks.prefix(blockIndex)
        where !block.isImage && block.commentCount >= 0
            && !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ordinal += 1
        }
        return items.indices.contains(ordinal) ? items[ordinal].id : items.last?.id
    }

    /// 用户自己翻页：朗读这一侧只让路，不重起读。
    /// 原来是「翻到哪页就从这页第一段重念」——正文一段动辄几百字，
    /// 翻一页等于把正在念的长段腰斩，再听就像被谁按回去了。
    private func followReadingAfterPageChange() {
        // 进度格自己改的页码不算用户翻页
        if suppressFollowOnPageChange {
            suppressFollowOnPageChange = false
            return
        }
        guard ttsFollowPage, readerConfig.pageMode != .scroll else { return }
        // 暂停时翻页什么也不做：别把朗读重新点着
        guard audioService.isPlaying else { return }
        autoFollowPausedByUser = true
        AppLog.write("[听书] 用户翻页 · 第 \(currentChapterIndex + 1) 章 · 第 \(currentPageIndex + 1) 页 · 朗读不重起，暂停自动跟页")
    }

    private func updateReadingBlockIdFromCurrentPage() {
        guard let cur = currentLoadedChapter, !cur.pages.isEmpty else { return }
        var charPos = 0
        let limit = min(currentPageIndex, cur.pages.count)
        for p in 0..<limit {
            for block in cur.pages[p] {
                charPos += block.text.count
            }
        }
        var accumulated = 0
        var targetBlockId = cur.blocks.first?.id ?? 0
        for block in cur.blocks {
            if accumulated + block.text.count > charPos {
                targetBlockId = block.id
                break
            }
            accumulated += block.text.count
            targetBlockId = block.id
        }
        currentReadingBlockId = targetBlockId
    }

    // MARK: - Page Turn Handler (Once chapter ends, next chapter starts next page)
    /// 翻页动画：覆盖是滑入盖住旧页，左右和滑动是新页推进来、旧页退出去，
    /// 无动画就是一帧切换。
    private var pageTurnAnimation: Animation? {
        switch readerConfig.pageMode {
        case .none:
            return nil
        case .cover:
            return .easeOut(duration: 0.24)
        case .slide:
            return .spring(response: 0.34, dampingFraction: 0.9)
        case .pageByPage:
            return .easeInOut(duration: 0.24)
        case .simulation:
            // 仿真换章是整页滑进来，比卷页慢一点才不突兀
            return .easeInOut(duration: 0.26)
        default:
            return .easeInOut(duration: 0.18)
        }
    }

    /// 影响正文渲染的样式指纹。变了就让按页的阅读容器整个重建，
    /// 免得托管的页面拿着旧配色不放。
    private var themeRenderKey: String {
        let colors = readerConfig.useCustomColors
            ? "\(readerConfig.customBackgroundHex)|\(readerConfig.customTextHex)"
            : readerConfig.theme.rawValue
        return [
            colors,
            readerConfig.fontName,
            "\(readerConfig.weightLevel)",
            readerConfig.chineseConversion.rawValue,
            readerConfig.titleAlignment.rawValue,
            "\(readerConfig.headerEnabled)\(readerConfig.footerEnabled)\(readerConfig.barDivider)"
        ].joined(separator: "|")
    }

    private var pageTransition: AnyTransition {
        switch readerConfig.pageMode {
        case .cover:
            return .asymmetric(
                insertion: .move(edge: pageTurnForward ? .trailing : .leading),
                removal: .opacity
            )
        case .slide, .pageByPage:
            return .asymmetric(
                insertion: .move(edge: pageTurnForward ? .trailing : .leading),
                removal: .move(edge: pageTurnForward ? .leading : .trailing)
            )
        case .none:
            return .identity
        default:
            return .opacity
        }
    }

    private func turnPage(forward: Bool) {
        guard let current = currentLoadedChapter else { return }
        let totalPages = current.pages.count
        // 分页收尾可能留下空白页，后面全是空页时按本章结束处理
        let hasContentAfter = (currentPageIndex + 1..<max(0, totalPages)).contains { idx in
            current.pages[idx].contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.isImage }
        }

        if forward {
                if currentPageIndex < totalPages - 1, hasContentAfter {
                pageTurnForward = true
                withAnimation(pageTurnAnimation) {
                    currentPageIndex += 1
                    dragOffset = 0
                }
                updateReadingBlockIdFromCurrentPage()
                saveCurrentProgress()
                followReadingAfterPageChange()
                // 快翻到头了就把下一章提前拉起来，换章才不用等
                if currentPageIndex >= totalPages - 2 {
                    preCacheNeighbors(around: currentChapterIndex)
                }
            } else {
                // Chapter ended! Once one chapter ends, the new chapter starts the next page!
                // 换章期间挡住重复触发：旧章还在屏上时再滑一次，会拿旧章页数去推进页码
                if !isSwitchingChapter, currentChapterIndex < chapters.count - 1 {
                    isSwitchingChapter = true
                    pageTurnForward = true
                    audioService.stop()
                    withAnimation(pageTurnAnimation) {
                        dragOffset = 0
                    }
                    let nextIdx = currentChapterIndex + 1
                    // 换章也要走同一段动画事务，否则带 .id 的页面插入/移除不成对，
                    // 旧页会留在屏幕上叠着新页（看着就像没翻过去）
                    withAnimation(pageTurnAnimation) {
                        currentChapterIndex = nextIdx
                        currentPageIndex = 0
                        currentReadingBlockId = 0
                    }
                    loadInitialChapter(at: nextIdx, targetPageIndex: 0)
                }
            }
        } else {
            if currentPageIndex > 0 {
                pageTurnForward = false
                withAnimation(pageTurnAnimation) {
                    currentPageIndex -= 1
                    dragOffset = 0
                }
                updateReadingBlockIdFromCurrentPage()
                saveCurrentProgress()
                followReadingAfterPageChange()
            } else {
                // Return to previous chapter's last page!
                if !isSwitchingChapter, currentChapterIndex > 0 {
                    isSwitchingChapter = true
                    pageTurnForward = false
                    audioService.stop()
                    withAnimation(pageTurnAnimation) {
                        dragOffset = 0
                    }
                    let prevIdx = currentChapterIndex - 1
                    withAnimation(pageTurnAnimation) {
                        currentChapterIndex = prevIdx
                    }
                    loadInitialChapter(at: prevIdx, targetPageIndex: -1) // -1 indicates last page
                }
            }
        }
    }

    // MARK: - Navigation Bars & Toolbars (Apple Books Layout)
    private var topNavigationBar: some View {
        HStack(alignment: .center) {
            // Exit button
            Button(action: {
                audioService.stop()
                if let onDismiss = onDismiss {
                    onDismiss()
                }
                dismiss()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                    Text("书架")
                        .font(.system(size: 16))
                }
                .foregroundColor(chromeInk)
                .contentShape(Rectangle())
            }

            Spacer()

            // Book Title in Center (No reading progress/chapter info)
            Text(activeBook.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(readerConfig.textColor)
                .lineLimit(1)
                .frame(maxWidth: 240)

            Spacer()

            // 右上角统一菜单：零碎功能都收这里（这块原来是个占位空格）
            Menu {
                Button {
                    refreshCurrentChapter()
                } label: {
                    Label("刷新本章正文", systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await refreshChapterList() }
                } label: {
                    Label("刷新目录", systemImage: "list.bullet.rectangle")
                }
                Button(role: .destructive) {
                    clearCurrentBookCache()
                } label: {
                    Label("清除本书缓存", systemImage: "trash")
                }
                Menu {
                    ForEach([10, 20, 30, 50, 100], id: \.self) { n in
                        Button("往后 \(n) 章") { downloadCachedChapters(span: n) }
                    }
                    Divider()
                    Button("用设置里的默认（\(readerConfig.cachedChapterCount) 章）") { downloadCachedChapters() }
                } label: {
                    Label("下载缓存（当前 \(readerConfig.cachedChapterCount) 章）", systemImage: "arrow.down.circle")
                }
                Button {
                    showReplaceRules = true
                } label: {
                    Label("替换净化规则", systemImage: "wand.and.stars")
                }
                Button {
                    showBookmarks = true
                } label: {
                    Label("书签", systemImage: "bookmark")
                }
                Button {
                    showTTSSettings = true
                } label: {
                    Label("听书设置", systemImage: "headphones")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 19))
                    .foregroundColor(chromeInk)
                    .frame(width: 54, height: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            chromeBackground
                .opacity(0.97)
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 3)
                .ignoresSafeArea(edges: .top)
        )
        .overlay(
            Rectangle()
                .fill(chromeInk.opacity(0.12))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var bottomControlPanel: some View {
        VStack(spacing: 12) {
            chapterNavigationRow

            Rectangle()
                .fill(chromeInk.opacity(0.12))
                .frame(height: 0.5)

            bottomActionRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(
            chromeBackground
                .opacity(0.97)
                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Permanent Fixed Bottom Status Bar
    /// 设备安全区：滚动模式的页眉页脚活在安全区里，位置要按它换算。
    private var screenTopInset: CGFloat { max(0, safeInsets.top) }
    private var screenBottomInset: CGFloat { max(0, safeInsets.bottom) }

    /// 真机安全区得问窗口：NavigationView 里的 GeometryReader 有时报 0，负 padding 又会被布局钳掉，
    /// 两条一起出错时，距顶拉到 -70 页眉仍在灵动岛下方。
    private static func windowSafeInsets() -> EdgeInsets {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
            ?? scenes.first?.windows.first
        guard let insets = window?.safeAreaInsets else { return EdgeInsets() }
        return EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
        #else
        return EdgeInsets()
        #endif
    }

    /// 页眉页脚：左中右三栏，内容按配置来，跟安卓那套一致。
    /// extendEdge：把这条栏的底色顶到屏幕边缘（顶栏顶到最上面，底栏顶到最下面），文字仍留在安全区里
    private func statusBar(
        left: [ReaderBarContent],
        center: [ReaderBarContent],
        right: [ReaderBarContent],
        extendEdge: Edge.Set? = nil,
        topSpacer: CGFloat = 0,
        bottomSpacer: CGFloat = 0
    ) -> some View {
        VStack(spacing: 0) {
            // 这段空白是给灵动岛/Home 指示条留的：把这条栏的底色顶到屏幕物理边缘
            if topSpacer > 0 {
                Color.clear.frame(height: topSpacer)
            }
            if readerConfig.barDivider {
                Rectangle()
                    .fill(readerConfig.textColor.opacity(0.12))
                    .frame(height: 0.5)
            }
            HStack(spacing: 8) {
                statusSlot(left, alignment: .leading)
                statusSlot(center, alignment: .center)
                statusSlot(right, alignment: .trailing)
            }
            .font(.system(size: 11))
            .foregroundColor(readerConfig.textColor.opacity(0.8))
            .padding(.horizontal, 16)
            .frame(height: 18)
            if bottomSpacer > 0 {
                Color.clear.frame(height: bottomSpacer)
            }
        }
        .frame(height: 19 + topSpacer + bottomSpacer)
        .background(
            Group {
                // 有背景图时这两条不能再刷主题色，否则上下各留一条绿边，看着像图没铺满
                if readerConfig.backgroundImageEnabled, !readerConfig.backgroundImagePath.isEmpty {
                    Color.clear
                } else if let edge = extendEdge {
                    readerConfig.backgroundColor.ignoresSafeArea(edges: edge)
                } else {
                    readerConfig.backgroundColor
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            toggleControls("header")
        }
    }

    @ViewBuilder
    private func statusSlot(_ contents: [ReaderBarContent], alignment: Alignment) -> some View {
        let items = contents.filter { $0 != .none }
        if items.count == 1, let only = items.first {
            statusSlotView(only, alignment: alignment, fills: true)
        } else {
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    statusSlotView(item, alignment: alignment, fills: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    @ViewBuilder
    private func statusSlotView(_ content: ReaderBarContent, alignment: Alignment, fills: Bool) -> some View {
        switch content {
        case .bookPercentBar:
            statusBar(fraction: bookProgressFraction, alignment: alignment)
        case .batteryBar:
            statusBar(fraction: ReaderBarBattery.level() ?? 0, alignment: alignment)
        case .batteryIcon:
            batterySlot(showNumber: false, alignment: alignment)
        case .batteryGlyphWithPercent:
            batterySlot(showNumber: true, alignment: alignment)
        default:
            Text(statusText(content))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(fills ? 1 : 0)
                .frame(maxWidth: fills ? .infinity : nil, alignment: alignment)
        }
    }

    /// 总进度条 / 电量条这类细长条
    private func statusBar(fraction: Double, alignment: Alignment) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(readerConfig.textColor.opacity(0.18))
                Capsule()
                    .fill(readerConfig.textColor.opacity(0.65))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
            }
        }
        .frame(height: 3)
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    @ViewBuilder
    private func batterySlot(showNumber: Bool, alignment: Alignment) -> some View {
        HStack(spacing: 3) {
            Image(systemName: batterySymbolName)
                .font(.system(size: 11))
            if showNumber, let level = ReaderBarBattery.level() {
                Text("\(Int((level * 100).rounded()))%")
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
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

    private func statusText(_ content: ReaderBarContent) -> String {
        readerBarText(content, barContext)
    }

    /// 页眉页脚取值的输入，格式化交给共用的 readerBarText
    private var barContext: ReaderBarContext {
        var ctx = ReaderBarContext()
        ctx.bookName = activeBook.name
        ctx.chapterTitle = (!chapters.isEmpty && currentChapterIndex < chapters.count)
            ? chapters[currentChapterIndex].title
            : (currentLoadedChapter?.chapter.title ?? "")
        ctx.chapterIndex = currentChapterIndex
        ctx.chapterCount = chapters.count
        ctx.pageIndex = currentPageIndex
        ctx.pageCount = currentLoadedChapter?.pages.count ?? 0
        ctx.isPaged = readerConfig.pageMode.isPaged
        ctx.bookProgress = bookProgressFraction
        ctx.sessionStart = readerSessionStart
        ctx.shortTitleLength = readerConfig.shortTitleLength
        ctx.customDatePattern = readerConfig.customDatePattern
        ctx.customBarText = readerConfig.customBarText
        return ctx
    }

    /// 全书进度：章号 + 章内位置，比「按章」的百分比细一档
    private var bookProgressFraction: Double {
        guard !chapters.isEmpty else { return 0 }
        let chapterPart = Double(currentChapterIndex) / Double(chapters.count)
        var inChapter = 0.0
        if readerConfig.pageMode.isPaged,
           let cur = currentLoadedChapter, !cur.pages.isEmpty {
            inChapter = Double(currentPageIndex) / Double(max(1, cur.pages.count))
        } else if let cur = currentLoadedChapter, !cur.blocks.isEmpty {
            inChapter = Double(currentReadingBlockId) / Double(max(1, cur.blocks.count))
        }
        return min(1.0, chapterPart + inChapter / Double(chapters.count))
    }

    private var fixedBottomStatusBar: some View {
        HStack(alignment: .center, spacing: 12) {
            // Chapter Name
            if !chapters.isEmpty && currentChapterIndex < chapters.count {
                Text(chapters[currentChapterIndex].title)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(readerConfig.textColor.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(activeBook.name)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(readerConfig.textColor.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer()

            // Reading Percentage / Page Info
            if !chapters.isEmpty {
                let progressPercent = Double(currentChapterIndex + 1) / Double(chapters.count) * 100.0
                if readerConfig.pageMode.isPaged, let cur = currentLoadedChapter, !cur.pages.isEmpty {
                    Text("\(currentPageIndex + 1)/\(cur.pages.count) · \(String(format: "%.1f%%", progressPercent))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(readerConfig.textColor.opacity(0.55))
                } else {
                    Text("\(currentChapterIndex + 1)/\(chapters.count) (\(String(format: "%.1f%%", progressPercent)))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(readerConfig.textColor.opacity(0.55))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .frame(height: 26)
        .background(readerConfig.backgroundColor)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleControls("footer")
        }
    }

    private var chapterNavigationRow: some View {
        HStack(spacing: 14) {
            Button(action: {
                previousChapter()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("上一章")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(currentChapterIndex > 0 ? readerConfig.textColor : readerConfig.textColor.opacity(0.3))
            }
            .disabled(currentChapterIndex <= 0)

            if chapters.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(currentChapterIndex) },
                        set: { newValue in
                            let target = Int(newValue.rounded())
                            if target != currentChapterIndex && target >= 0 && target < chapters.count {
                                jumpToChapter(target)
                            }
                        }
                    ),
                    in: 0...Double(chapters.count - 1),
                    step: 1
                )
                .accentColor(.accentColor)
            } else {
                Spacer()
            }

            Button(action: {
                nextChapter()
            }) {
                HStack(spacing: 4) {
                    Text("下一章")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(currentChapterIndex < chapters.count - 1 ? readerConfig.textColor : readerConfig.textColor.opacity(0.3))
            }
            .disabled(currentChapterIndex >= chapters.count - 1)
        }
    }

    private func previousChapter() {
        guard currentChapterIndex > 0 else { return }
        let prevIndex = currentChapterIndex - 1

        if readerConfig.pageMode == .scroll {
            if loadedChapters.contains(where: { $0.chapter.index == prevIndex }) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    scrollToChapterId = "chapter_end_\(prevIndex)"
                }
            } else if let first = loadedChapters.first, first.chapter.index == currentChapterIndex {
                Task {
                    if let prevLoaded = await getOrFetchChapter(at: prevIndex) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.loadedChapters.insert(prevLoaded, at: 0)
                            self.currentChapterIndex = prevIndex
                            self.scrollToChapterId = "chapter_end_\(prevIndex)"
                        }
                        BookStore.shared.updateProgress(bookUrl: activeBook.bookUrl, chapterIndex: prevIndex, chapterTitle: prevLoaded.chapter.title)
                        self.preCacheNeighbors(around: prevIndex)
                    }
                }
            } else {
                jumpToChapter(prevIndex, toEnd: true)
            }
        } else {
            jumpToChapter(prevIndex, toEnd: true)
        }
    }

    private func nextChapter() {
        guard currentChapterIndex < chapters.count - 1 else { return }
        let nextIndex = currentChapterIndex + 1

        if readerConfig.pageMode == .scroll {
            if loadedChapters.contains(where: { $0.chapter.index == nextIndex }) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    scrollToChapterId = "chapter_\(nextIndex)"
                }
            } else {
                jumpToChapter(nextIndex, toEnd: false)
            }
        } else {
            jumpToChapter(nextIndex, toEnd: false)
        }
    }

    private func jumpToChapter(_ targetIndex: Int, toEnd: Bool = false, forceResumeReading: Bool = false) {
        AppLog.write("[阅读] 换章 → 第 \(targetIndex + 1) 章 / 共 \(chapters.count) 章")
        guard targetIndex >= 0 && targetIndex < chapters.count else { return }
        // 换章这一步会 stop()：原本在念的得记着，换完接着念，不然用户只看到声音没了
        let wasReading = audioService.isPlaying || audioService.isPaused
        audioService.stop()
        // 换章作废上一条挂起的起读：这一趟要么接读、要么不读，不带着旧请求走
        if pendingReadingStart != nil {
            pendingReadingStart = nil
            AppLog.write("[听书] 换章作废旧挂起")
        }
        currentChapterIndex = targetIndex
        currentPageIndex = 0
        currentReadingBlockId = 0
        scrollSessionId = UUID()
        loadInitialChapter(at: targetIndex, targetPageIndex: toEnd ? -1 : 0, scrollToTargetEnd: toEnd)
        if wasReading || forceResumeReading {
            resumeReadingAfterChapterJump(targetIndex)
        }
    }

    /// 换章后接读：等这一章铺出来，从第一段起。跟页读关着就不自作主张。
    private func resumeReadingAfterChapterJump(_ targetIndex: Int) {
        guard ttsFollowPage else {
            AppLog.write("[听书] 换章不接读 · 跟页读关着")
            return
        }
        // 以前这里是「轮询 40×150ms，等不到就放弃」。快翻时正文 6 秒没到，
        // 这条就判死、一声不吭地不读了；而且判据里那份 items 会退回上一章，非空，
        // 于是又会出现「在念上一章」。现在改成挂起：loadInitialChapter 落地即唤醒，不设超时。
        if loadedChapter(exactly: targetIndex) != nil {
            AppLog.write("[听书] 换章接读 · 第 \(targetIndex + 1) 章（正文已在）")
            startReadingChapter(chapterIndex: targetIndex, revealBar: false)
        } else {
            pendingReadingStart = PendingReadingStart(chapter: targetIndex, blockId: nil, revealBar: false)
            AppLog.write("[听书] 换章接读挂起 · 第 \(targetIndex + 1) 章 等正文")
        }
    }

    /// 找到某个朗读段所在的页。页里一行的 id 是行级伪 id（10000 起），
    /// 跟朗读段的编号不是一套，认 paragraphId（原始段 id）才对得上。
    private func pageIndex(containing blockId: Int, in chapter: LoadedChapter) -> Int? {
        chapter.pages.firstIndex { page in
            page.contains { ($0.paragraphId > 0 ? $0.paragraphId : $0.id) == blockId }
        }
    }

    /// 分页模式的「朗读 → 翻页」：朗读段跑到别的页了就跟着翻，只翻页不重起读。
    /// 这条是「高亮跟随」的另一半：底色跟着段走，页得跟着段走。
    private func followPageToReadingBlock(_ blockId: Int?) {
        guard ttsFollowPage, readerConfig.pageMode != .scroll else { return }
        guard audioService.isPlaying else { return }
        guard let blockId, let cur = currentLoadedChapter else { return }
        guard let page = pageIndex(containing: blockId, in: cur) else { return }
        guard page != currentPageIndex else { return }
        // 用户自己往后翻过：朗读还在后头念，别把页码拽回去，不然一翻就弹回来。
        // 等念到眼前这一页（page ≥ currentPageIndex）再接管，那一次是往前翻，符合预期。
        if autoFollowPausedByUser, page < currentPageIndex {
            AppLog.write("[听书] 跟页暂停中 · 朗读在第 \(page + 1) 页 · 用户停在第 \(currentPageIndex + 1) 页")
            return
        }
        autoFollowPausedByUser = false
        AppLog.write("[听书] 翻页跟读 · 第 \(currentChapterIndex + 1) 章 · 页 \(currentPageIndex + 1) → \(page + 1) block \(blockId)")
        withAnimation(.easeInOut(duration: 0.25)) { currentPageIndex = page }
        saveCurrentProgress()
    }

    /// 本章队列自然读完：跟页读开着就接下一章，睡前模式由播放端拦在前面
    private func continueReadingAfterChapterEnd() {
        let next = currentChapterIndex + 1
        guard next < chapters.count else {
            AppLog.write("[听书] 全书读完 · 已是最后一章")
            return
        }
        guard ttsFollowPage else {
            AppLog.write("[听书] 本章读完 · 跟页读关着，不自动翻章")
            return
        }
        AppLog.write("[听书] 本章读完 → 自动接第 \(next + 1) 章")
        jumpToChapter(next, forceResumeReading: true)
    }

    private func handlePageModeChange(to newMode: PageMode) {
        guard let cur = currentLoadedChapter else { return }

        if newMode.isPaged {
            // 1. Switching from Continuous Scroll to Page-by-Page:
            var charPos = 0
            for block in cur.blocks {
                if block.id == currentReadingBlockId {
                    break
                }
                charPos += block.text.count
            }

            var accumulated = 0
            var targetPage = 0
            for (pIdx, page) in cur.pages.enumerated() {
                let pageCharCount = page.reduce(0) { $0 + $1.text.count }
                if accumulated + pageCharCount > charPos {
                    targetPage = pIdx
                    break
                }
                accumulated += pageCharCount
                targetPage = pIdx
            }
            currentPageIndex = min(targetPage, max(0, cur.pages.count - 1))
            updateReadingBlockIdFromCurrentPage()
        } else {
            // 2. Switching from Page-by-Page to Continuous Scroll:
            var charPos = 0
            let limit = min(currentPageIndex, cur.pages.count)
            for p in 0..<limit {
                for block in cur.pages[p] {
                    charPos += block.text.count
                }
            }

            var accumulated = 0
            var targetBlockId = cur.blocks.first?.id ?? 0
            for block in cur.blocks {
                if accumulated + block.text.count > charPos {
                    targetBlockId = block.id
                    break
                }
                accumulated += block.text.count
                targetBlockId = block.id
            }

            currentReadingBlockId = targetBlockId
            scrollSessionId = UUID()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                scrollToChapterId = "block_\(currentChapterIndex)_\(targetBlockId)"
            }
        }
        saveCurrentProgress()
    }

    private var bottomActionRow: some View {
        return HStack(spacing: 0) {
            // Contents Table (目录)
            Button(action: {
                tocSearchText = ""
                showTOC = true
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 20))
                    Text("目录")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(readerConfig.textColor)
                .frame(maxWidth: .infinity)
            }

            // Text Search (搜索)
            Button(action: { showSearch = true }) {
                VStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                    Text("搜索")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(readerConfig.textColor)
                .frame(maxWidth: .infinity)
            }

            // 段评：书源提供了段评地址才亮，点开是本章所有热门段落
            Button(action: {
                if chapterCommentItems.isEmpty {
                    showBookmarkHint("本章暂无段评")
                } else {
                    showComments = true
                }
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 20))
                    Text(chapterCommentItems.isEmpty ? "段评" : "段评 \(chapterCommentItems.count)")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(readerConfig.textColor.opacity(chapterCommentItems.isEmpty ? 0.45 : 1))
                .frame(maxWidth: .infinity)
            }

            // Switch Book Source (换源)
            Button(action: { showSourceSwitch = true }) {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 20))
                    Text("换源")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(readerConfig.textColor)
                .frame(maxWidth: .infinity)
            }

            // Interface Settings (界面设置)
            Button(action: {
                // 真机打开面板会闪退，先留一行完整状态：崩溃后日志最后一条就是现场
                AppLog.write("[阅读设置] 点开界面 主题=\(readerConfig.theme.rawValue) 模式=\(readerConfig.pageMode.rawValue) 字号=\(readerConfig.fontSize) 行距=\(readerConfig.lineSpacing) 亮度=\(readerConfig.brightness) 面板=\(readerConfig.panelOpacity) 章=\(currentChapterIndex + 1)/\(chapters.count) 页=\(currentPageIndex + 1)")
                showSettings = true
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 20))
                    Text("界面")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(readerConfig.textColor)
                .frame(maxWidth: .infinity)
            }

        }
    }

    /// 换源：把阅读进度搬到新书源，然后在同一个阅读界面里重拉目录和正文。
    private func switchToSource(_ newSource: BookSource, _ candidate: SearchBook) {
        AppLog.write("[阅读] 开始更换书源")
        previousBook = activeBook
        previousSource = effectiveSource
        let newBook = Book(
            bookUrl: candidate.bookUrl,
            name: candidate.name,
            author: candidate.author,
            kind: candidate.kind,
            coverUrl: candidate.coverUrl,
            intro: candidate.intro,
            origin: candidate.origin,
            originName: candidate.originName,
            latestChapterTitle: candidate.latestChapterTitle
        )
        let applied = BookStore.shared.changeBookSource(from: activeBook, to: newBook)
        switchedBook = applied
        switchedSource = newSource
        chapters = []
        chapterCache.removeAll()
        loadedChapters = []
        currentChapterIndex = applied.durChapterIndex
        isLoadingInitial = true
        errorMessage = nil
        Task { await loadTOCAndStart() }
    }

    /// 新书源解析不出目录时退回原书源，避免卡在错误页。
    private func revertSourceSwitch() {
        guard let target = previousBook else { return }
        AppLog.write("[阅读] 新书源目录为空，回退原书源")
        let current = activeBook
        switchedBook = target
        switchedSource = previousSource
        previousBook = nil
        previousSource = nil
        BookStore.shared.changeBookSource(from: current, to: target)
        chapters = []
        chapterCache.removeAll()
        loadedChapters = []
        currentChapterIndex = target.durChapterIndex
        isLoadingInitial = true
        errorMessage = nil
        Task { await loadTOCAndStart() }
    }

    private var searchSheet: some View {
        ReaderSearchSheet(
            book: activeBook,
            currentChapterIndex: currentChapterIndex,
            currentChapterTitle: (!chapters.isEmpty && currentChapterIndex < chapters.count) ? chapters[currentChapterIndex].title : "",
            currentContent: currentChapterContent,
            chapters: chapters,
            onSelectChapter: { targetIndex, _ in
                showSearch = false
                withAnimation {
                    showControls = false
                }
                if targetIndex != currentChapterIndex {
                    jumpToChapter(targetIndex)
                }
            }
        )
    }

    private var tocSheet: some View {
        NavigationView {
            List(tocFilteredChapters) { ch in
                Button(action: {
                    showTOC = false
                    jumpToChapter(ch.index)
                }) {
                    HStack {
                        Text(ch.title)
                            .foregroundColor(ch.index == currentChapterIndex ? .accentColor : .primary)
                        Spacer()
                        if ch.index == currentChapterIndex {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
            .overlay {
                if tocFilteredChapters.isEmpty {
                    Text(tocSearchText.isEmpty ? "目录为空" : "没有匹配的章节")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
            #if os(iOS)
            .searchable(
                text: $tocSearchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索章节"
            )
            #else
            .searchable(text: $tocSearchText, prompt: "搜索章节")
            #endif
            .navigationTitle(
                tocSearchText.isEmpty
                    ? "目录 (\(chapters.count)章)"
                    : "目录 · \(tocFilteredChapters.count)/\(chapters.count)"
            )
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        tocReversed.toggle()
                    } label: {
                        Image(systemName: tocReversed ? "arrow.down.to.line" : "arrow.up.to.line")
                    }
                    .accessibilityLabel(tocReversed ? "倒序：开" : "倒序：关")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refreshChapterList() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新目录")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { showTOC = false }
                }
            }
        }
    }

    /// 书签 / 笔记：加、看、跳、删
    private var bookmarksSheet: some View {
        NavigationView {
            List {
                Section {
                    TextField("备注（可留空）", text: $newBookmarkNote)
                    Button {
                        addBookmarkHere()
                    } label: {
                        Label("在当前位置加书签", systemImage: "bookmark.fill")
                    }
                    #if os(iOS)
                    NavigationLink {
                        ReaderAssetsSheet { loadReaderAssets() }
                    } label: {
                        Label("下拉背景与书签外观", systemImage: "photo.on.rectangle.angled")
                    }
                    #endif
                }

                let list = visibleBookmarks
                if bookmarkMultiSelect {
                    Section {
                        HStack {
                            Button(allVisibleSelected ? "取消全选" : "全选") {
                                toggleSelectAllVisible()
                            }
                            Spacer()
                            Text("已选 \(selectedBookmarkIDs.count)")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(role: .destructive) {
                                deleteSelectedBookmarks()
                            } label: {
                                Text("删除")
                            }
                            .disabled(selectedBookmarkIDs.isEmpty)
                        }
                    }
                }

                Section(header: Text(bookmarkSectionTitle(list.count))) {
                    if list.isEmpty {
                        Text(bookmarkSearchText.isEmpty && bookmarkKindFilter == .all
                             ? "还没有书签。"
                             : "没有匹配的书签。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    ForEach(list) { bm in
                        HStack(alignment: .top, spacing: 8) {
                            if bookmarkMultiSelect {
                                Image(systemName: selectedBookmarkIDs.contains(bm.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedBookmarkIDs.contains(bm.id)
                                                     ? .accentColor : .secondary)
                                    .font(.system(size: 17))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(bm.chapterTitle)
                                        .font(.system(size: 14, weight: .medium))
                                    bookmarkKindTag(bm)
                                }
                                if !bm.snippet.isEmpty {
                                    Text(bm.snippet)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                if !bm.note.isEmpty {
                                    Text("备注：" + bm.note)
                                        .font(.system(size: 11))
                                        .foregroundColor(.accentColor)
                                }
                                Text(bm.createdAt.formatted(date: .numeric, time: .shortened))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if bookmarkMultiSelect {
                                toggleBookmarkSelection(bm)
                            } else {
                                showBookmarks = false
                                jumpToChapter(bm.chapterIndex)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet where i < list.count {
                            bookmarkStore.removeBookmark(list[i])
                        }
                    }
                }
            }
            .searchable(text: $bookmarkSearchText, prompt: "搜章节名、摘要、备注")
            .appThemedList()
            .navigationTitle("书签 / 笔记")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // 排序 / 类型菜单：iOS 放左上，macOS 只有默认位置可用
                ToolbarItem(placement: Self.bookmarkMenuPlacement) {
                    bookmarkFilterMenu
                }
                ToolbarItem(placement: Self.bookmarkSelectPlacement) {
                    Button(bookmarkMultiSelect ? "完成" : "选择") {
                        bookmarkMultiSelect.toggle()
                        if !bookmarkMultiSelect { selectedBookmarkIDs.removeAll() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { showBookmarks = false }
                }
            }
        }
    }

    /// 排序 / 类型菜单
    private var bookmarkFilterMenu: some View {
        Menu {
            Picker("排序", selection: $bookmarkSort) {
                ForEach(BookmarkSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            Picker("类型", selection: $bookmarkKindFilter) {
                ForEach(BookmarkKindFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }

    private static var bookmarkMenuPlacement: ToolbarItemPlacement {
        #if os(iOS)
        return .navigationBarLeading
        #else
        return .automatic
        #endif
    }

    private static var bookmarkSelectPlacement: ToolbarItemPlacement {
        #if os(iOS)
        return .navigationBarTrailing
        #else
        return .automatic
        #endif
    }

    /// 面板上真正显示的书签：先按类型与关键字过滤，再按选定的顺序排
    private var visibleBookmarks: [BookBookmark] {
        let all = bookmarkStore.bookmarks(for: activeBook.bookUrl)
        let byKind: [BookBookmark]
        switch bookmarkKindFilter {
        case .all: byKind = all
        case .bookmark: byKind = all.filter { $0.kind == .bookmark }
        case .underline: byKind = all.filter { $0.kind == .underline }
        case .highlight: byKind = all.filter { $0.kind == .highlight }
        }
        let keyword = bookmarkSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = keyword.isEmpty ? byKind : byKind.filter {
            $0.chapterTitle.localizedCaseInsensitiveContains(keyword)
                || $0.snippet.localizedCaseInsensitiveContains(keyword)
                || $0.note.localizedCaseInsensitiveContains(keyword)
        }
        switch bookmarkSort {
        case .newestFirst:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .oldestFirst:
            return filtered.sorted { $0.createdAt < $1.createdAt }
        case .chapterAscending:
            return filtered.sorted {
                ($0.chapterIndex, $0.createdAt) < ($1.chapterIndex, $1.createdAt)
            }
        case .chapterDescending:
            return filtered.sorted {
                ($0.chapterIndex, $0.createdAt) > ($1.chapterIndex, $1.createdAt)
            }
        }
    }

    private func bookmarkSectionTitle(_ count: Int) -> String {
        var parts = ["本书书签与笔记 (\(count))"]
        parts.append(bookmarkSort.title)
        if bookmarkKindFilter != .all { parts.append(bookmarkKindFilter.title) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func bookmarkKindTag(_ bookmark: BookBookmark) -> some View {
        switch bookmark.kind {
        case .bookmark:
            EmptyView()
        case .underline:
            bookmarkTag("下划线")
        case .highlight:
            bookmarkTag("底色")
        }
    }

    private func bookmarkTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundColor(.secondary)
    }

    private var allVisibleSelected: Bool {
        let list = visibleBookmarks
        return !list.isEmpty && list.allSatisfy { selectedBookmarkIDs.contains($0.id) }
    }

    private func toggleSelectAllVisible() {
        let list = visibleBookmarks
        if allVisibleSelected {
            for item in list { selectedBookmarkIDs.remove(item.id) }
        } else {
            for item in list { selectedBookmarkIDs.insert(item.id) }
        }
    }

    private func toggleBookmarkSelection(_ bookmark: BookBookmark) {
        if selectedBookmarkIDs.contains(bookmark.id) {
            selectedBookmarkIDs.remove(bookmark.id)
        } else {
            selectedBookmarkIDs.insert(bookmark.id)
        }
    }

    private func deleteSelectedBookmarks() {
        let doomed = bookmarkStore.bookmarks(for: activeBook.bookUrl)
            .filter { selectedBookmarkIDs.contains($0.id) }
        for item in doomed { bookmarkStore.removeBookmark(item) }
        selectedBookmarkIDs.removeAll()
        showBookmarkHint("已删除 \(doomed.count) 条")
    }

    // MARK: - 下拉加书签

    // MARK: - 段落级长按：选择与操作

    /// 长按选中段落后的操作栏（复制 / 搜索 / 书签 / 下划线 / 底色 / 替换）
    private var paragraphActionBar: some View {
        // 悬浮气泡：贴在选中段落的上方（上面放不下就挪到下面）
        GeometryReader { geo in
            if selectedBlockRange != nil {
                let rect = selectionRect ?? CGRect(x: geo.size.width / 2 - 60, y: geo.size.height * 0.45,
                                                   width: 120, height: 24)
                let origin = geo.frame(in: .global).origin
                let bubbleWidth = Self.bubbleWidth(for: geo.size.width)
                // 左右也按安全区让：横屏/刘海那点 inset 别把气泡推出去
                let sideInset = max(max(safeInsets.leading, safeInsets.trailing), 6)
                let x = min(max(rect.midX - origin.x, bubbleWidth / 2 + sideInset),
                            max(bubbleWidth / 2 + sideInset, geo.size.width - bubbleWidth / 2 - sideInset))
                // 安全区跟着阅读页自己的 safeInsets 走：刘海、底部横条、状态栏都算进去，
                // 别再拿写死的 64 当门槛；键盘弹起来时按键盘顶边算，气泡不许钻到键盘底下
                let safeTop = max(safeInsets.top, 8) + 8
                let safeBottom = max(max(safeInsets.bottom, 8), keyboardInset) + 8
                let half = Self.bubbleHeight / 2
                let minY = safeTop + half
                let maxY = max(minY, geo.size.height - safeBottom - half)
                let above = rect.minY - origin.y - half - 10
                let below = rect.maxY - origin.y + half + 10
                let placedAbove = above >= minY
                let y = placedAbove ? min(above, maxY) : max(min(below, maxY), minY)
                paragraphBubble(width: bubbleWidth)
                    .frame(width: bubbleWidth)
                    .position(x: x, y: y)
                    .transition(.opacity)
                // 尖角指回选中的那几个字：没有它，卡片就只是飘在纸上的浮块。
                // 位置跟卡片一起夹在气泡宽度里，别让角戳出圆角外面。
                let arrowX = min(max(rect.midX - origin.x, x - bubbleWidth / 2 + 24),
                                 x + bubbleWidth / 2 - 24)
                let arrowY = placedAbove
                    ? y + Self.bubbleHeight / 2 + Self.bubblePointerHeight / 2 - 1
                    : y - Self.bubbleHeight / 2 - Self.bubblePointerHeight / 2 + 1
                bubblePointer(pointsDown: placedAbove)
                    .position(x: arrowX, y: arrowY)
                    .transition(.opacity)
                if let kind = colorPickerKind {
                    // 调色板放到气泡上方；上方不够（贴着状态栏）才翻到下面，两头都不出安全区
                    let paletteHalf: CGFloat = 20
                    let paletteAbove = y - half - paletteHalf - 6
                    let paletteBelow = y + half + paletteHalf + 6
                    let paletteMin = safeTop + paletteHalf
                    let paletteMax = max(paletteMin, geo.size.height - safeBottom - paletteHalf)
                    let paletteY = paletteAbove >= paletteMin
                        ? min(paletteAbove, paletteMax)
                        : max(min(paletteBelow, paletteMax), paletteMin)
                    annotationColorRow(kind: kind)
                        .frame(width: bubbleWidth)
                        .position(x: x, y: paletteY)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .allowsHitTesting(selectedBlockRange != nil)
        #if os(iOS)
        // 键盘只在「替换」弹窗时出现，但气泡和调色板不该等它盖上来才发现放不下
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let window = scene.windows.first(where: { $0.isKeyWindow }) else { return }
            keyboardInset = max(0, window.bounds.maxY - frame.minY)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardInset = 0
        }
        #endif
    }

    /// 字选模式的两个圆形手柄：拖它们逐字伸缩
    @ViewBuilder
    private var charSelectionHandles: some View {
        #if os(iOS)
        GeometryReader { geo in
            if let sel = charSelection,
               let startPoint = CoreTextUIView.boundaryPoint(paragraphId: sel.paragraphId, offset: sel.start),
               let endPoint = CoreTextUIView.boundaryPoint(paragraphId: sel.paragraphId,
                                                           offset: sel.start + sel.length) {
                let origin = geo.frame(in: .global).origin
                charHandle(at: CGPoint(x: startPoint.x - origin.x, y: startPoint.y - origin.y), isStart: true)
                charHandle(at: CGPoint(x: endPoint.x - origin.x, y: endPoint.y - origin.y), isStart: false)
            }
        }
        .allowsHitTesting(charSelection != nil)
        #else
        EmptyView()
        #endif
    }

    #if os(iOS)
    private func charHandle(at point: CGPoint, isStart: Bool) -> some View {
        ZStack {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            // 触摸区比看得见的圆大一圈，手指才好按住
            Color.clear
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .position(x: point.x, y: point.y)
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    tapSuppressor.suppress()
                    updateCharSelection(isStart: isStart, at: value.location)
                }
                .onEnded { value in
                    tapSuppressor.suppress()
                    updateCharSelection(isStart: isStart, at: value.location)
                }
        )
    }
    #endif

    /// 气泡宽度：五个主操作一格，窄屏也不挤成 34pt
    private static func bubbleWidth(for containerWidth: CGFloat) -> CGFloat {
        min(352, max(300, containerWidth - 24))
    }

    /// 气泡高度（估）：定位和调色板让位都按它算。两行压到 40 + 26，比原来单行版没长高
    private static let bubbleHeight: CGFloat = 76
    /// 尖角高度：朝选文那一侧。7pt 太像描边毛刺，8pt 才看得出是个「角」
    private static let bubblePointerHeight: CGFloat = 8

    /// 气泡圆角跟主题走：月面终端用它自己的直角，标准主题给圆一点的卡面
    private var bubbleCornerRadius: CGFloat {
        theme.choice == .lunarTerminal ? max(6, theme.metrics.cornerRadius) : 20
    }

    /// 气泡尖角：底色跟卡片一模一样的两层填充，再只描两条斜边，
    /// 这样底边不会多出一道横线，卡片和角看起来是同一个形状。
    private func bubblePointer(pointsDown: Bool) -> some View {
        let shape = BubblePointerShape(pointsDown: pointsDown)
        return ZStack {
            shape.fill(bubbleCardColor)
            shape.fill(Color.white.opacity(bubbleLiftOpacity))
            shape.stroke(bubbleDividerColor, lineWidth: 0.7)
        }
        .frame(width: 20, height: Self.bubblePointerHeight)
    }

    private struct BubblePointerShape: Shape {
        var pointsDown: Bool

        func path(in rect: CGRect) -> Path {
            var path = Path()
            if pointsDown {
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            } else {
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            }
            // 不闭合：stroke 只落在两条斜边上，底边交给填充去压住卡片那根描边
            return path
        }
    }

    private func paragraphBubble(width: CGFloat) -> some View {
        // 第一行五个主操作，第二行是低频动作；每格都够宽，图标和字不再互相挤
        // −16 是左右内边距，−0.5 给第一行中间那根细线，别让五格加起来顶出卡面
        let actionWidth = max(50, (width - 16.5) / 5)
        // 这一段已经有的标注：气泡上直接显示状态，别让人猜「刚才是加上了还是没加上」
        let underlineNow = currentSelectionAnnotation(kind: .underline)
        let highlightNow = currentSelectionAnnotation(kind: .highlight)
        let shape = RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                paragraphAction("复制", "doc.on.doc", width: actionWidth) { copySelectedParagraph() }
                paragraphAction("搜索", "magnifyingglass", width: actionWidth) { searchSelectedParagraph() }
                paragraphAction("书签", "bookmark", width: actionWidth) { addBookmarkForSelection() }
                bubbleHairline
                paragraphAction(underlineNow == nil ? "下划线" : "已划线", "underline", width: actionWidth,
                                active: underlineNow != nil,
                                dot: underlineNow.map { readerHexColor($0.color ?? "#2F7BF6") }) {
                    colorPickerKind = .underline
                }
                paragraphAction(highlightNow == nil ? "底色" : "已底色", "highlighter", width: actionWidth,
                                active: highlightNow != nil,
                                dot: highlightNow.map { readerHexColor($0.color ?? "#FFF59D") }) {
                    colorPickerKind = .highlight
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .padding(.horizontal, 8)

            Rectangle()
                .fill(bubbleDividerColor.opacity(0.85))
                .frame(height: 0.5)
                .padding(.horizontal, 14)

            HStack(spacing: 10) {
                bubbleTextAction("替换", "arrow.left.arrow.right") {
                    replaceInput = ""
                    showReplaceInput = true
                }
                if readerConfig.pageMode != .scroll {
                    bubbleTextAction("整段", "text.alignleft") { resetToWholeParagraph() }
                }
                // 从这一段起读：显式给一个动作，别让「点一下正文」偷偷把进度拽走
                bubbleTextAction("本段读", "play.circle", emphasized: true) { readFromSelection() }
                Spacer(minLength: 6)
                // 选中多少字：字选和整段选一眼能分开，不用猜刚才选的是不是一整段
                if !selectionCountLabel.isEmpty, width >= 330 {
                    Text(selectionCountLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(bubbleInkColor.opacity(0.55))
                        .lineLimit(1)
                        .fixedSize()
                }
                bubbleDoneChip { cancelParagraphSelection() }
            }
            .padding(.horizontal, 14)
            .frame(height: 26)
            .padding(.vertical, 4)
        }
        .frame(width: width)
        .background {
            // 不透明底：regularMaterial 会把背后的纸色、标注色采上来，气泡跟着变。
            // surface 打底、再压一层白，四种主题都是同一种「纸上面一张卡」的关系。
            ZStack {
                shape.fill(bubbleCardColor)
                shape.fill(Color.white.opacity(bubbleLiftOpacity))
            }
        }
        .overlay(shape.stroke(bubbleDividerColor, lineWidth: 0.7))
        // 内侧一道极淡的白：卡面跟纸是同一个色系，全靠这道高光把边界提出来
        .overlay(shape.stroke(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.4), lineWidth: 0.5).padding(0.6))
        // 两层阴影：近处一层收边，远处一层压纸，比单层大模糊干净
        .shadow(color: Color.black.opacity(0.13), radius: 18, y: 6)
        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
    }

    /// 浮层压在纸上的提亮量：浅色主题压白多一点，夜间只提一点，免得整块发灰
    private var bubbleLiftOpacity: Double {
        colorScheme == .dark ? 0.05 : 0.55
    }

    // 气泡自己的一套颜色：跟阅读页的纸色、墨色、强调色走。
    // 之前借 App 主题的 surface，羊皮纸正文上就浮出一张冷灰卡，跟纸不是一家。
    private var bubbleCardColor: Color { readerConfig.backgroundColor }
    private var bubbleInkColor: Color { readerConfig.textColor }
    private var bubbleAccentColor: Color { readerConfig.theme.accentColor }
    private var bubbleDividerColor: Color { readerConfig.textColor.opacity(0.16) }

    /// 第一行的动作格：图标在上、标签在下；选中状态的图标和字改用主题强调色
    private func paragraphAction(_ title: String, _ icon: String, width: CGFloat,
                                 active: Bool = false, dot: Color? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button {
            // 这一下也会落到页面那套「点一下开关工具栏」的手势上，先按住它，
            // 否则操作栏刚点完就被顶出来的工具栏盖住
            tapSuppressor.suppress()
            action()
        } label: {
            VStack(spacing: 1) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: active ? .semibold : .regular))
                        .foregroundColor(active ? bubbleAccentColor : bubbleInkColor)
                        .frame(width: 22, height: 17)
                    if let dot {
                        // 当前标注色做小圆点：图标本身不再被浅色染色，看不清的问题就没了
                        Circle()
                            .fill(dot)
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Color.primary.opacity(0.3), lineWidth: 0.5))
                            .offset(x: 7, y: -1)
                    }
                }
                Text(title)
                    .font(.system(size: 10, weight: active ? .semibold : .regular))
                    .foregroundColor(active ? bubbleAccentColor : bubbleInkColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: width, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? bubbleAccentColor.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(active ? bubbleAccentColor.opacity(0.22) : Color.clear, lineWidth: 0.6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(BubbleActionButtonStyle())
    }

    /// 第一行里「文本类动作」和「标注类动作」之间的细线：不靠留白分组，省宽度
    private var bubbleHairline: some View {
        Rectangle()
            .fill(bubbleDividerColor.opacity(0.8))
            .frame(width: 0.5, height: 18)
    }

    /// 第二行的低频动作：图标文字横排，比第一行轻一档
    private func bubbleTextAction(_ title: String, _ icon: String, emphasized: Bool = false,
                                  action: @escaping () -> Void) -> some View {
        Button {
            tapSuppressor.suppress()
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11.5, weight: emphasized ? .semibold : .medium))
            }
            // 「本段读」是这张卡的主操作：强调色，别跟替换、整段混成一片灰
            .foregroundColor(emphasized ? bubbleAccentColor : bubbleInkColor.opacity(0.62))
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(BubbleActionButtonStyle())
    }

    /// 选中字数：「已选 12 字」/「142 字」。字选和整段选看这一眼就分得清
    private var selectionCountLabel: String {
        if let sel = charSelection, sel.length > 0 { return "已选 \(sel.length) 字" }
        let whole = selectedParagraphText.trimmingCharacters(in: .whitespacesAndNewlines).count
        return whole > 0 ? "\(whole) 字" : ""
    }

    /// 收尾按钮：主题色浅底胶囊，比一根孤零零的「取消」更像能按的东西
    private func bubbleDoneChip(action: @escaping () -> Void) -> some View {
        Button {
            tapSuppressor.suppress()
            action()
        } label: {
            Text("完成")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(bubbleAccentColor)
                .padding(.horizontal, 10)
                .frame(height: 22)
                // 浅底 + 一道同色细边：纯色块在深色强调色主题里会跳成整张卡最响的东西
                .background(
                    Capsule(style: .continuous)
                        .fill(bubbleAccentColor.opacity(colorScheme == .dark ? 0.18 : 0.09))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(bubbleAccentColor.opacity(0.32), lineWidth: 0.6)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(BubbleActionButtonStyle())
    }

    /// 气泡按钮按下去的回弹：0.94 缩一下 + 半透明，够轻，不抢动作本身
    private struct BubbleActionButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.55 : 1)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    /// 热评：源里的 SVG / 图片卡片换成原生样式，文字和插图都保留。
    private func godReviewCard(_ block: ContentBlock) -> some View {
        GodReviewCardView(
            text: block.text,
            imageURL: block.imageUrl,
            referer: effectiveSource?.bookSourceUrl,
            accent: nierPalette.accent,
            textColor: nierPalette.ink,
            onAccentColor: nierPalette.background,
            alignment: reviewCardStyle.alignment
        ) {
            if let url = block.commentURL {
                directCommentTarget = ReviewTarget(url: url, title: "段评")
            }
        }
    }

    /// 段评数量气泡，贴在段落右下角。
    private func paragraphCommentBadge(_ block: ContentBlock, url: String) -> some View {
        let label = block.commentCount >= 99 ? "99+" : "\(block.commentCount)"
        let bodyWidth: CGFloat = label.count > 2 ? 26 : 18
        let totalWidth = bodyWidth + 6
        return Button {
            directCommentTarget = ReviewTarget(url: url, title: "段评")
        } label: {
            ZStack {
                ReaderCommentBubbleShape()
                    .fill(readerConfig.backgroundColor)
                ReaderCommentBubbleShape()
                    .stroke(readerConfig.textColor.opacity(0.45), lineWidth: 1.2)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(readerConfig.textColor)
                    .padding(.leading, 6)
            }
            .frame(width: totalWidth, height: 22)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func annotationPalette(for kind: BookBookmark.Kind) -> [String] {
        switch kind {
        case .underline:
            return ["#2F7BF6", "#E5484D", "#2FA84F", "#F08C00", "#8B5CF6", "#8E8E93"]
        default:
            return ["#FFF59D", "#C8E6C9", "#BBDEFB", "#F8BBD0", "#FFE0B2", "#E1BEE7"]
        }
    }

    private func annotationColorRow(kind: BookBookmark.Kind) -> some View {
        let selected = kind == .underline ? underlineHex : highlightHex
        return HStack(spacing: 9) {
            ForEach(annotationPalette(for: kind), id: \.self) { hex in
                Button {
                    applyAnnotation(kind: kind, color: hex)
                } label: {
                    Circle()
                        .fill(readerHexColor(hex))
                        .frame(width: 22, height: 22)
                        // 双描边：内圈白把浅色块（#FFF59D 这种）从纸色里抠出来，
                        // 外圈黑压住白纸上「白描边看不见」的问题
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
                        .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.7))
                        .overlay(
                            Circle()
                                .stroke(readerConfig.textColor, lineWidth: selected == hex ? 2 : 0)
                                .padding(-3)
                        )
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 20)
            // 已经标过的段落：给一个明确的「清除」，不用再猜点同色能不能撤
            if currentSelectionAnnotation(kind: kind) != nil {
                Button {
                    clearAnnotation(kind: kind)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "eraser")
                            .font(.system(size: 12, weight: .semibold))
                        Text("清除")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(readerConfig.textColor)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        Capsule().stroke(readerConfig.textColor.opacity(0.35), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                Divider().frame(height: 20)
            }
            Button {
                colorPickerKind = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            // 与气泡同一块不透明底，别让调色板把标注色采上来
            ZStack {
                Capsule().fill(theme.palette.surface)
                Capsule().fill(Color.white.opacity(bubbleLiftOpacity))
            }
        }
        .overlay(Capsule().stroke(theme.palette.divider, lineWidth: 0.8))
        .shadow(color: Color.black.opacity(0.15), radius: 8, y: 3)
    }

    private var annotationRangesForCurrentChapter: [(start: Int, count: Int, style: ReaderBlockStyle)] {
        bookmarkStore.annotations(bookUrl: activeBook.bookUrl, chapterIndex: currentChapterIndex)
            .map { blockId, item in
                let style = ReaderBlockStyle(
                    underline: item.kind == .underline,
                    underlineHex: item.kind == .underline ? (item.color ?? "#2F7BF6") : nil,
                    highlightHex: item.kind == .highlight ? (item.color ?? "#FFF59D") : nil
                )
                return (start: blockId, count: max(1, item.length ?? 1), style: style)
            }
    }

    /// 这一章的逐字标注（下划线 / 底色），只画选中那几个字
    private var charAnnotationRangesForCurrentChapter: [ReaderCharAnnotation] {
        bookmarkStore.userAnnotations(bookUrl: activeBook.bookUrl, chapterIndex: currentChapterIndex)
            .filter { $0.rangeUnitRaw == "char" }
            .compactMap { item in
                guard let blockId = item.blockId, let length = item.length else { return nil }
                let style = ReaderBlockStyle(
                    underline: item.kind == .underline,
                    underlineHex: item.kind == .underline ? (item.color ?? "#2F7BF6") : nil,
                    highlightHex: item.kind == .highlight ? (item.color ?? "#FFF59D") : nil
                )
                return ReaderCharAnnotation(paragraphId: blockId,
                                            start: item.charOffset,
                                            length: max(1, length),
                                            style: style)
            }
    }

    /// 长按直接选词：按触点找到字符，选中它所在的词/单字，再弹操作栏。
    /// 段落范围只用于「整段」扩选与动作锚点，不再默认整段高亮。
    private func selectCharacters(atLine line: Int, charOffset: Int, in pageBlocks: [ContentBlock]) {
        guard line >= 0, line < pageBlocks.count else { return }
        var start = line
        while start > 0, pageBlocks[start - 1].imageUrl != "p_end" { start -= 1 }
        var end = line
        while end < pageBlocks.count - 1, pageBlocks[end].imageUrl != "p_end" { end += 1 }
        let rawText = pageBlocks[start...end].map(\.text).joined()
        let text = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        selectedBlockRange = (start: pageBlocks[start].id, count: end - start + 1)
        selectedParagraphText = text
        selectedParagraphRawText = rawText
        selectedParagraphId = pageBlocks[start].paragraphId
        selectedParagraphCharStart = pageBlocks[start].charStart
        colorPickerKind = nil
        // 触点换算成段内字符偏移，再取这个词的范围
        let lineLength = (pageBlocks[line].text as NSString).length
        let relativeInParagraph = pageBlocks[line].charStart
            + min(max(0, charOffset), max(0, lineLength - 1))
            - selectedParagraphCharStart
        let word = selectedWordRange(in: rawText, around: relativeInParagraph)
        charSelection = ReaderCharSelection(paragraphId: selectedParagraphId,
                                            start: selectedParagraphCharStart + word.location,
                                            length: max(1, word.length))
        #if os(iOS)
        selectionRect = nil
        refreshCharSelectionRect()
        selectionRect = selectionRect ?? CoreTextUIView.lastSelectionWindowRect
        #endif
        // 只在「从没选中」切进选中时拍快照，取消才有明确的还原目标
        if annotationSnapshot == nil { annotationSnapshot = currentChapterAnnotations() }
        tapSuppressor.suppress()
        withAnimation(.easeInOut(duration: 0.15)) { showControls = false }
    }

    /// 用系统分词找长按点所在的词；中文按词，找不到就退到单个字符
    private func selectedWordRange(in rawText: String, around offset: Int) -> (location: Int, length: Int) {
        let ns = rawText as NSString
        guard ns.length > 0 else { return (0, 0) }
        let clamped = max(0, min(offset, ns.length - 1))
        if let tokenizer = CFStringTokenizerCreate(
            nil,
            rawText as CFString,
            CFRange(location: 0, length: ns.length),
            kCFStringTokenizerUnitWordBoundary,
            Locale(identifier: "zh_CN") as CFLocale
        ) {
            _ = CFStringTokenizerGoToTokenAtIndex(tokenizer, clamped)
            let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if token.location != kCFNotFound, token.length > 0 {
                let location = max(0, min(token.location, ns.length - 1))
                let length = min(token.length, ns.length - location)
                if length > 0 { return (location, length) }
            }
        }
        let range = ns.rangeOfComposedCharacterSequence(at: clamped)
        return (range.location, max(1, range.length))
    }

    /// 退出选段：保留这次做的更改（点别处 / 再长按都走这条）
    private func clearParagraphSelection() {
        selectedBlockRange = nil
        selectedParagraphText = ""
        selectedParagraphRawText = ""
        selectedParagraphId = 0
        selectedParagraphCharStart = 0
        charSelection = nil
        colorPickerKind = nil
        selectionRect = nil
        annotationSnapshot = nil
    }

    // MARK: - 字选模式

    /// 手柄拖回整段
    private func resetToWholeParagraph() {
        guard charSelection != nil else { return }
        let length = (selectedParagraphRawText as NSString).length
        charSelection = ReaderCharSelection(paragraphId: selectedParagraphId,
                                            start: selectedParagraphCharStart,
                                            length: length)
        refreshCharSelectionRect()
        tapSuppressor.suppress()
    }

    /// 当前选中的文字：字选模式取字符区间，否则整段
    private var currentSelectionText: String {
        guard let sel = charSelection else { return selectedParagraphText }
        let ns = selectedParagraphRawText as NSString
        let relative = sel.start - selectedParagraphCharStart
        guard relative >= 0, relative + sel.length <= ns.length else { return selectedParagraphText }
        return ns.substring(with: NSRange(location: relative, length: sel.length))
    }

    private func refreshCharSelectionRect() {
        #if os(iOS)
        guard let sel = charSelection else { return }
        if let rect = CoreTextUIView.windowRect(paragraphId: sel.paragraphId,
                                                from: sel.start,
                                                to: sel.start + sel.length) {
            selectionRect = rect
        }
        #endif
    }

    /// 按下的位置离哪个手柄近：近就接管这次拖拽
    private func beginCharHandleDrag(at point: CGPoint) -> Bool {
        #if os(iOS)
        guard let sel = charSelection,
              let start = CoreTextUIView.boundaryPoint(paragraphId: sel.paragraphId, offset: sel.start),
              let end = CoreTextUIView.boundaryPoint(paragraphId: sel.paragraphId,
                                                     offset: sel.start + sel.length) else { return false }
        let startDistance = hypot(point.x - start.x, point.y - start.y)
        let endDistance = hypot(point.x - end.x, point.y - end.y)
        guard min(startDistance, endDistance) <= 32 else { return false }
        isDraggingCharStart = startDistance <= endDistance
        tapSuppressor.suppress()
        return true
        #else
        return false
        #endif
    }

    /// 拖圆形手柄：按落点找最近的字符边界，夹在段内可见范围里
    private func updateCharSelection(isStart: Bool, at point: CGPoint) {
        #if os(iOS)
        guard var sel = charSelection else { return }
        guard let boundary = CoreTextUIView.boundaryIndex(paragraphId: sel.paragraphId,
                                                          nearWindowPoint: point) else { return }
        let lower = selectedParagraphCharStart
        let upper = selectedParagraphCharStart + (selectedParagraphRawText as NSString).length
        let clamped = min(max(boundary, lower), upper)
        if isStart {
            let end = sel.start + sel.length
            let newStart = min(clamped, end - 1)
            sel.start = newStart
            sel.length = max(1, end - newStart)
        } else {
            let newEnd = max(clamped, sel.start + 1)
            sel.length = max(1, newEnd - sel.start)
        }
        charSelection = sel
        refreshCharSelectionRect()
        #endif
    }

    /// 按「取消」：把这一章的标注还原成选中那一刻的样子
    private func cancelParagraphSelection() {
        if let snapshot = annotationSnapshot {
            bookmarkStore.replaceAnnotations(snapshot,
                                             bookUrl: activeBook.bookUrl,
                                             chapterIndex: currentChapterIndex)
        }
        clearParagraphSelection()
        showBookmarkHint("已还原")
    }

    private func currentChapterAnnotations() -> [BookBookmark] {
        bookmarkStore.bookmarks(for: activeBook.bookUrl)
            .filter { $0.chapterIndex == currentChapterIndex && $0.kind != .bookmark }
    }

    /// 连续滚动模式：一个 block 就是一段，直接选中它
    private func selectScrollParagraph(_ block: ContentBlock, chapterIndex: Int) {
        if currentChapterIndex != chapterIndex { currentChapterIndex = chapterIndex }
        selectedBlockRange = (start: block.id, count: 1)
        selectedParagraphText = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedParagraphRawText = block.text
        selectedParagraphId = block.id
        selectedParagraphCharStart = 0
        charSelection = nil
        if let rect = scrollHitRegistry.rect(forBlockId: block.id, chapterIndex: chapterIndex) {
            selectionRect = rect
        } else {
            selectionRect = nil
        }
        if annotationSnapshot == nil { annotationSnapshot = currentChapterAnnotations() }
        tapSuppressor.suppress()
        withAnimation(.easeInOut(duration: 0.15)) { showControls = false }
    }

    /// 验收用：`JUYUE_READER_SCRIPT="wait:2;press:200,600;palette:underline;color:#2F7BF6;dump"`
    /// 语义动作代替手点，长按这条流程能无人值守地重放；截图只当证据，不当输入。
    private func runReaderDebugScriptIfNeeded() async {
        #if DEBUG || targetEnvironment(simulator)
        guard let raw = ProcessInfo.processInfo.environment["JUYUE_READER_SCRIPT"],
              !raw.isEmpty else { return }
        AppLog.write("[调试] 阅读页脚本开始：\(raw)")
        for step in raw.split(separator: ";") {
            let part = step.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            let bits = part.split(separator: ":", maxSplits: 1).map(String.init)
            let name = bits[0]
            let arg = bits.count > 1 ? bits[1] : ""
            switch name {
            case "wait":
                let seconds = Double(arg) ?? 1
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            case "press":
                #if os(iOS)
                let xy = arg.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if xy.count == 2 {
                    handleLongPressAtWindowPoint(CGPoint(x: xy[0], y: xy[1]))
                    AppLog.write("[调试] press \(xy[0]),\(xy[1])")
                }
                #endif
            case "palette":
                colorPickerKind = arg == "highlight" ? .highlight : .underline
                AppLog.write("[调试] palette \(arg)")
            case "tap":
                #if os(iOS)
                let xy = arg.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if xy.count == 2 {
                    handleTapWhileListening(at: CGPoint(x: xy[0], y: xy[1]))
                    AppLog.write("[调试] tap \(xy[0]),\(xy[1])")
                }
                #endif
            case "read":
                startReadingChapter(fromBlockId: arg.isEmpty ? nil : Int(arg))
            case "hint":
                // 单验提示层：这条显示 30 秒，截图/控件树都来得及
                showBookmarkHint(arg.isEmpty ? "提示层自测" : arg, seconds: 30)
            case "chapter":
                // 换章：复现「快翻后立刻起读」那条竞态（正文还在路上就点朗读）
                if let n = Int(arg), n >= 1, n <= chapters.count {
                    jumpToChapter(n - 1)
                    AppLog.write("[调试] 换章 → 第 \(n) 章")
                }
            case "stopread":
                audioService.stop()
                AppLog.write("[调试] 停读")
            case "pause":
                // 截图要一帧稳定的朗读底色：暂停保留位置和底色，stop 会清掉
                audioService.pause()
                AppLog.write("[调试] 暂停朗读 block \(audioService.readingBlockId.map(String.init) ?? "nil")")
            case "settingsrestart":
                // 验收「改设置就不念了」：走设置面板同一条重启路径
                AppLog.write("[调试] 设置变更重起 block \(audioService.readingBlockId.map(String.init) ?? "nil")")
                audioService.applySettingsChangeRestart()
            case "cast":
                TTSCastStore.shared.enabled = (arg == "1")
                AppLog.write("[调试] 多角色 \(TTSCastStore.shared.enabled ? "开" : "关")")
            case "resume":
                // 验完一轮暂停要接着放：脚本里没这一步就只能手点
                audioService.resume()
                AppLog.write("[调试] 继续朗读 block \(audioService.readingBlockId.map(String.init) ?? "nil") playing=\(audioService.isPlaying) paused=\(audioService.isPaused)")
            case "pids":
                // 行 → 段落 id 的对照：高亮偏一段时先看这张表
                let blocks = currentLoadedChapter?.blocks ?? []
                AppLog.write("[调试] 块 " + blocks.prefix(9).map { "\($0.id):\($0.text.prefix(6))" }.joined(separator: " | "))
                #if os(iOS)
                AppLog.write("[调试] 页 \(CoreTextUIView.debugDumpVisiblePages())")
                #endif
            case "mode":
                // 验收脚本切翻页模式，省得手点设置页
                let mode: PageMode = arg == "scroll" ? .scroll
                    : (arg == "page" ? .pageByPage
                       : (arg == "simulation" ? .simulation : .cover))
                readerConfig.pageMode = mode
                AppLog.write("[调试] 模式切到 \(mode.rawValue)")
            case "color":
                if let kind = colorPickerKind {
                    applyAnnotation(kind: kind, color: arg)
                    AppLog.write("[调试] color \(arg) 给 \(kind.rawValue)")
                }
            case "clear":
                if let kind = colorPickerKind {
                    clearAnnotation(kind: kind)
                    AppLog.write("[调试] clear \(kind.rawValue)")
                }
            case "close":
                colorPickerKind = nil
            case "panel":
                withAnimation(.easeOut(duration: 0.18)) { showReadingPanel = true }
                AppLog.write("[调试] 朗读面板 open follow=\(ttsFollowPage) tint=\(ttsTintSource)")
            case "collapse":
                withAnimation(.easeOut(duration: 0.18)) { ttsBarCollapsed = true }
                AppLog.write("[调试] 朗读条 collapsed=\(ttsBarCollapsed)")
            case "expand":
                withAnimation(.easeOut(duration: 0.18)) { ttsBarCollapsed = false }
                AppLog.write("[调试] 朗读条 collapsed=\(ttsBarCollapsed)")
            case "follow":
                ttsFollowPage = arg == "0" ? false : (arg == "1" ? true : !ttsFollowPage)
                AppLog.write("[调试] 跟页读 \(ttsFollowPage ? "开" : "关")")
            case "ttscache":
                ttsReadFromCache = arg == "0" ? false : true
                AppLog.write("[调试] 听书读缓存 \(ttsReadFromCache ? "开" : "关") 本章已缓存=\(BookContentService.shared.hasCachedChapter(bookUrl: activeBook.bookUrl, chapterIndex: currentChapterIndex))")
            case "turn":
                turnPage(forward: arg != "0")
                AppLog.write("[调试] 翻页 forward=\(arg != "0") 现在第 \(currentPageIndex + 1) 页")
            case "pageinfo":
                let page = (currentLoadedChapter.map { $0.pages.indices.contains(currentPageIndex) } == true)
                    ? currentLoadedChapter!.pages[currentPageIndex] : []
                let blocks = currentLoadedChapter?.blocks ?? []
                let lineIds = page.prefix(6).map { "\($0.id)/p\($0.paragraphId)" }.joined(separator: ",")
                let ids = readingItemsForCurrentChapter.map(\.id)
                let readableBlocks = blocks.filter { !$0.isImage && $0.commentCount >= 0 }.count
                AppLog.write("[调试] 页 \(currentPageIndex + 1) 行块 \(lineIds) · blocks \(blocks.count)(可读 \(readableBlocks)) · 可读 id \(ids.prefix(8)) · 页首段 \(currentPageFirstBlockId.map(String.init) ?? "nil")")
            case "readpage":
                if let blockId = currentPageFirstBlockId {
                    AppLog.write("[调试] 从这一页读 block \(blockId) 页 \(currentPageIndex + 1)")
                    startReadingChapter(fromBlockId: blockId)
                } else {
                    AppLog.write("[调试] 从这一页读 拿不到段落")
                }
            case "reviewcache":
                UserDefaults.standard.set(arg != "0", forKey: ReviewCache.enabledKey)
                let targets = ReviewCache.commentTargets(inContent: currentChapterContent, limit: 3)
                let firstAPI = targets.first.flatMap { ReviewCache.apiURL(fromRaw: $0.raw, mode: $0.mode)?.absoluteString }
                AppLog.write("[调试] 书评哨兵 \(targets.count) 条 · 开关=\(ReviewCache.enabled) · 首条接口=\(firstAPI ?? "无")")
                Task { await ReviewCache.prefetchComments(inContent: currentChapterContent, limit: 2) }
            case "tint":
                ttsTintSource = arg.isEmpty ? "highlight" : arg
                AppLog.write("[调试] 朗读底色来源 \(ttsTintSource)")
            case "hidebar":
                withAnimation(.easeOut(duration: 0.18)) { ttsBarHidden = arg != "0" }
                AppLog.write("[调试] 朗读条 hidden=\(ttsBarHidden)")
            case "menu":
                toggleControls("script-menu")
                AppLog.write("[调试] 底栏 controls=\(showControls)")
            case "speed":
                let times = Double(arg) ?? 1.0
                audioService.speechRate = Float(times) * AVSpeechUtteranceDefaultSpeechRate
                AppLog.write("[调试] 语速 \(times)×")
            case "sleep":
                if arg == "chapter" {
                    audioService.setSleepStopAtChapterEnd(true)
                } else if arg == "off" {
                    audioService.cancelSleepTimer()
                    audioService.setSleepStopAtChapterEnd(false)
                } else {
                    audioService.startSleepTimer(minutes: Int(arg) ?? 15)
                }
                AppLog.write("[调试] 定时 \(arg.isEmpty ? "15" : arg) · 剩 \(audioService.sleepRemaining)s · 章末停=\(audioService.sleepStopAtChapterEnd)")
            case "readsel":
                readFromSelection()
            case "compare":
                let curBlock = audioService.readingBlockId
                let allBlocks = currentLoadedChapter?.blocks ?? []
                let pageLines = (currentLoadedChapter.map { $0.pages.indices.contains(currentPageIndex) } == true)
                    ? currentLoadedChapter!.pages[currentPageIndex] : []
                // 页面上从上到下出现过哪几段（按 paragraphId 去重），每段只取前 14 字方便跟截图对照
                var pids: [Int] = []
                var lastPid = -1
                for line in pageLines {
                    let pid = line.paragraphId > 0 ? line.paragraphId : line.id
                    if pid != lastPid { pids.append(pid); lastPid = pid }
                }
                let pageDesc = pids.prefix(4).map { pid -> String in
                    let t = allBlocks.first(where: { $0.id == pid })?.text ?? "-"
                    return "\(pid)『\(String(t.prefix(14)))』"
                }.joined(separator: " ")
                let queue = readingItemsForCurrentChapter
                let curIdx = queue.firstIndex(where: { $0.id == curBlock })
                let curText = queue.first(where: { $0.id == curBlock })?.text ?? "-"
                AppLog.write("[调试] 页\(currentPageIndex + 1)段序 \(pageDesc)")
                AppLog.write("[调试] 朗读段 \(curBlock.map(String.init) ?? "nil") 队列第\(curIdx.map { $0 + 1 } ?? -1)段『\(String(curText.prefix(14)))』")
            case "dump":
                let list = bookmarkStore.userAnnotations(bookUrl: activeBook.bookUrl,
                                                         chapterIndex: currentChapterIndex)
                let desc = list.map {
                    "\($0.kind.rawValue)@\($0.blockId ?? -1)+\($0.charOffset)x\($0.length ?? 0)"
                        + "/\($0.color ?? "-")/\($0.rangeUnitRaw ?? "block")"
                }.joined(separator: " · ")
                AppLog.write("[调试] 本章标注 \(list.count) 条：\(desc.isEmpty ? "无" : desc)")
            default:
                AppLog.write("[调试] 不认识的步骤 \(part)")
            }
        }
        AppLog.write("[调试] 阅读页脚本结束")
        #endif
    }

    /// 窗口层长按落在滚动模式正文上：换算成段落再走同一条选择逻辑
    private func handleLongPressAtWindowPoint(_ point: CGPoint) {
        #if os(iOS)
        // 以前这里是一句 `guard !showControls else { return }`：菜单一开着，长按就静悄悄地没了。
        // 朗读中点一下正文就会把菜单叫出来，长按极容易撞在这个状态上，看起来就是「没法长按选字」。
        // 现在改成先收起菜单再继续走选字，两条手势不再互相挡。
        if showControls {
            withAnimation(.easeOut(duration: 0.15)) { showControls = false }
            AppLog.write("[长按] 菜单开着 · 先收起再选字 · \(Int(point.x)),\(Int(point.y))")
        }
        // 朗读条整条藏起来之后，长按正文就是唯一的召回手势：
        // 先把它叫回来，再照旧走选词/选段，不吞掉长按本身。
        if ttsBarHidden, audioService.hasReadingSession {
            withAnimation(.easeOut(duration: 0.18)) { ttsBarHidden = false }
            AppLog.write("[听书] 长按叫回朗读条")
        }

        // 分页 / 仿真：交给触点所在那一页自己判行
        if readerConfig.pageMode != .scroll {
            if CoreTextUIView.triggerLongPress(atWindowPoint: point) { return }
            AppLog.write("[长按] 分页模式没找到正文页 · \(Int(point.x)),\(Int(point.y))")
            return
        }

        guard let hit = scrollHitRegistry.hitTest(point) else {
            AppLog.write("[长按] 滚动模式未命中段落 · \(Int(point.x)),\(Int(point.y))")
            return
        }
        guard let loaded = loadedChapters.first(where: { $0.chapter.index == hit.chapterIndex }),
              let block = loaded.blocks.first(where: { $0.id == hit.blockId }),
              !block.isImage else { return }
        AppLog.write("[长按] 滚动模式命中第 \(hit.chapterIndex + 1) 章 · block \(hit.blockId)")
        // 长按点常落在行距/段间距里（段落框含内边距），上下再试几个偏移，
        // 问到第一个字位就用；两条都不行才退回整段。
        if let probe = scrollCharProbe(block: block, chapterIndex: hit.chapterIndex, point: point) {
            AppLog.write("[长按] 字位 \(probe.offset) 走\(probe.metrics == nil ? "label" : "CoreText")")
            selectScrollWord(block: block, chapterIndex: hit.chapterIndex,
                             charOffset: probe.offset, metrics: probe.metrics)
        } else {
            AppLog.write("[长按] 两条路都没问到字位，退回整段")
            selectScrollParagraph(block, chapterIndex: hit.chapterIndex)
        }
        #endif
    }


    /// 滚动模式的字位探针：UILabel（TextKit）优先，问不到再用 CoreText 复排。
    /// 落点往上挪几档，是因为段落框把段间距也算进去了，手指常在文字下面几磅。
    private func scrollCharProbe(block: ContentBlock, chapterIndex: Int,
                                 point: CGPoint) -> (offset: Int, metrics: ReaderScrollMetricsContext?)? {
        #if os(iOS)
        let label = ReaderBodyLabel.label(chapterIndex: chapterIndex, blockId: block.id)
        let ctx = scrollTextContext(for: block, chapterIndex: chapterIndex)
        let rendered = applyingKinsoku(block.text) as NSString
        for dy in [0.0, -6, -12, -18, -24, 10, 18] {
            let probe = CGPoint(x: point.x, y: point.y + dy)
            if let label, let index = label.charIndex(atWindowPoint: probe) {
                return (originalIndex(fromRendered: index, in: rendered), nil)
            }
            if let ctx, let index = ReaderScrollTextMetrics.charIndex(atWindowPoint: probe, in: ctx) {
                return (originalIndex(fromRendered: index, in: rendered), ctx)
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// 非两端对齐时正文是 SwiftUI Text 画的：按同一套字体参数重排一遍，
    /// 只回答「这个点在第几个字」。两端对齐走 ReaderBodyLabel，用不到这条。
    private func scrollTextContext(for block: ContentBlock,
                                   chapterIndex: Int) -> ReaderScrollMetricsContext? {
        #if os(iOS)
        guard let rect = scrollHitRegistry.rect(forBlockId: block.id, chapterIndex: chapterIndex) else { return nil }
        // registry 的 frame 含左右内边距，减掉才是正文的排版宽度
        let width = rect.width - readerConfig.paddingLeft - readerConfig.paddingRight
        guard width > 10 else { return nil }
        return ReaderScrollTextMetrics.Context(
            text: applyingKinsoku(block.text),
            fontSize: readerConfig.fontSize,
            lineSpacing: readerConfig.lineSpacing,
            kerning: readerConfig.letterSpacing,
            alignment: coreTextAlignment,
            origin: CGPoint(x: rect.minX + readerConfig.paddingLeft, y: rect.minY),
            width: width
        )
        #else
        return nil
        #endif
    }

    private var coreTextAlignment: NSTextAlignment {
        switch readerConfig.textAlignment {
        case .center: return .center
        case .trailing: return .right
        default: return .left
        }
    }

    /// 滚动模式选词：跟分页模式同一个口径（段内 UTF-16 偏移 + 系统分词）
    private func selectScrollWord(block: ContentBlock, chapterIndex: Int, charOffset: Int,
                                  metrics: ReaderScrollMetricsContext? = nil) {
        if currentChapterIndex != chapterIndex { currentChapterIndex = chapterIndex }
        selectedBlockRange = (start: block.id, count: 1)
        selectedParagraphText = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedParagraphRawText = block.text
        selectedParagraphId = block.id
        selectedParagraphCharStart = 0
        let word = selectedWordRange(in: block.text, around: charOffset)
        charSelection = ReaderCharSelection(paragraphId: block.id,
                                            start: word.location,
                                            length: max(1, word.length))
        colorPickerKind = nil
        // 气泡贴着选中的词，别用整段的框
        #if os(iOS)
        if let label = ReaderBodyLabel.label(chapterIndex: chapterIndex, blockId: block.id) {
            let rendered = applyingKinsoku(block.text) as NSString
            let start = renderedIndex(fromOriginal: word.location, in: rendered)
            let end = renderedIndex(fromOriginal: word.location + max(1, word.length), in: rendered)
            selectionRect = label.windowRect(forCharRange: NSRange(location: start,
                                                                   length: max(1, end - start)))
                ?? scrollHitRegistry.rect(forBlockId: block.id, chapterIndex: chapterIndex)
        } else if let metrics {
            let rendered = applyingKinsoku(block.text) as NSString
            let start = renderedIndex(fromOriginal: word.location, in: rendered)
            let end = renderedIndex(fromOriginal: word.location + max(1, word.length), in: rendered)
            selectionRect = ReaderScrollTextMetrics.rect(forRange: NSRange(location: start,
                                                                          length: max(1, end - start)),
                                                         in: metrics)
                ?? scrollHitRegistry.rect(forBlockId: block.id, chapterIndex: chapterIndex)
        } else {
            selectionRect = scrollHitRegistry.rect(forBlockId: block.id, chapterIndex: chapterIndex)
        }
        #else
        selectionRect = scrollHitRegistry.rect(forBlockId: block.id, chapterIndex: chapterIndex)
        #endif
        if annotationSnapshot == nil { annotationSnapshot = currentChapterAnnotations() }
        tapSuppressor.suppress()
        withAnimation(.easeInOut(duration: 0.15)) { showControls = false }
    }

    /// 连续滚动模式下，段落的底色标注画在段落的背景上
    /// 朗读段不走这里：整段背景会连缩进和行尾留白一起涂，改由 scrollBody 给逐字底色
    @ViewBuilder
    private func scrollAnnotationBackground(for block: ContentBlock, chapterIndex: Int) -> some View {
        // 选中的段落先铺一层淡蓝，长按下去能看出选的是哪一段
        if let range = selectedBlockRange, block.id >= range.start,
           block.id < range.start + max(1, range.count) {
            Color.accentColor.opacity(0.18)
        } else if let hit = bookmarkStore
            .annotations(bookUrl: activeBook.bookUrl, chapterIndex: chapterIndex)[block.id],
                  hit.kind == .highlight {
            readerHexColor(hit.color ?? "#FFF59D").opacity(0.55)
        } else {
            Color.clear
        }
    }

    /// 这一段是不是正在朗读（暂停也算，位置得留着）
    private func isReadingBlock(_ blockId: Int) -> Bool {
        guard let speaking = audioService.readingBlockId else { return false }
        // 合成/缓冲那 1-2 秒里 playing 和 paused 都是 false，底色要是跟着消失，
        // 每段之间就闪一下 —— 那正是「高亮跟随没了」最像的地方。
        return speaking == blockId && (audioService.isPlaying || audioService.isPaused || audioService.isSynthesizing)
    }

    /// 翻页模式给正文视图的朗读段 id（没在听书就是 nil）
    private var readingHighlightBlockId: Int? {
        guard let id = audioService.readingBlockId, isReadingBlock(id) else { return nil }
        return id
    }

    /// 朗读段的 block id：分页视图那层 `lineParagraphIds` 存的也是 ContentBlock.id，
    /// 两边同一套编号，直接递 id。以前递的是数组下标，id 从 1 起时整条高亮落后一段。
    private var readingParagraphOrdinal: Int? {
        readingHighlightBlockId
    }

    /// 朗读底色：默认跟主题强调色，也可以跟底色标注 / 划线色走，让朗读和做过的标记同一色系。
    /// 暂停时压到六成，跟阅读页那层竖线同一套口径。
    private var readingTint: Color {
        let base: Color
        switch ttsTintSource {
        case "highlight": base = readerHexColor(highlightHex)
        case "underline": base = readerHexColor(underlineHex)
        default: base = nierPalette.accent
        }
        // 浅色底（#FFF59D 这种）压 10% 在米白纸上根本看不出来，浅色得给厚一点；
        // 深色（强调色、深蓝划线）薄薄一层就够，压厚了正文发脏。
        let pale = isPaleColor(base)
        // 浅色（米黄标注色）在米白纸上 0.26 根本看不出来，读一段跟没加一样
        let alpha: Double = audioService.isPaused
            ? (pale ? 0.18 : 0.07)
            : (pale ? 0.36 : 0.12)
        return base.opacity(alpha)
    }

    /// 亮度判浅色：给朗读底色挑透明度用
    private func isPaleColor(_ color: Color) -> Bool {
        #if os(iOS)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
            return 0.299 * r + 0.587 * g + 0.114 * b > 0.72
        }
        #endif
        return false
    }

    /// 面板底色：从纸色推一层比正文更实的面。
    /// 用 .regularMaterial 会采样背后的正文，浅色纸上图标糊成一片，颜色还会随翻页变。
    private var readerPanelSurface: Color {
        #if os(iOS)
        let base = UIColor(readerConfig.backgroundColor)
        let resolved = base.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
            let luminance = 0.299 * r + 0.587 * g + 0.114 * b
            // 亮纸压暗一点点、暗纸提亮一点点，跟正文拉出层次又不刺眼
            let shift: CGFloat = luminance > 0.5 ? -0.055 : 0.12
            func clamp(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1)) }
            return Color(red: clamp(r + shift), green: clamp(g + shift), blue: clamp(b + shift))
        }
        #endif
        return readerConfig.backgroundColor
    }

    /// "#RRGGBB" → Color（标注底色）
    private func readerHexColor(_ hex: String) -> Color {
        let parsed = readerHexComponents(hex)
        return Color(red: parsed.r, green: parsed.g, blue: parsed.b, opacity: parsed.a)
    }

    /// 连续滚动模式下已加下划线的段落：在段落下沿画一条
    @ViewBuilder
    private func scrollAnnotationUnderline(for block: ContentBlock, chapterIndex: Int) -> some View {
        let hit = bookmarkStore
            .annotations(bookUrl: activeBook.bookUrl, chapterIndex: chapterIndex)[block.id]
        if let hit, hit.kind == .underline {
            Rectangle()
                .fill(readerHexColor(hit.color ?? "#2F7BF6").opacity(0.85))
                .frame(height: 1.5)
                .padding(.horizontal, readerConfig.paddingLeft)
        }
    }

    private func readerHexComponents(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else {
            return (1, 0.92, 0.4, 1)
        }
        let hasAlpha = text.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return (r, g, b, a)
    }

    /// 复制选中段落
    private func copySelectedParagraph() {
        #if os(iOS)
        UIPasteboard.general.string = currentSelectionText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
        showBookmarkHint("已复制")
    }

    /// 拿选中段落去聚合搜索
    private func searchSelectedParagraph() {
        let text = currentSelectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        SearchViewModel.shared.searchQuery = String(text.prefix(60))
        showAggregateSearch = true
    }

    private func addBookmarkForSelection() {
        addBookmarkHere()
        showBookmarkHint("已加书签 · 第 \(currentChapterIndex + 1) 章")
    }

    /// 下划线 / 底色：调色板选一个颜色就应用；同区间再点同色就取消
    private func applyAnnotation(kind: BookBookmark.Kind, color: String) {
        guard let range = selectedBlockRange, let cur = currentLoadedChapter else { return }
        if kind == .underline {
            underlineHex = color
        } else {
            highlightHex = color
        }
        tapSuppressor.suppress()
        let name = kind == .underline ? "下划线" : "底色"
        let added: Bool
        if let sel = charSelection {
            added = bookmarkStore.toggleAnnotation(
                bookUrl: activeBook.bookUrl,
                chapterIndex: currentChapterIndex,
                chapterTitle: cur.chapter.title,
                blockId: sel.paragraphId,
                charOffset: sel.start,
                length: sel.length,
                kind: kind,
                color: color,
                snippet: currentSelectionText.trimmingCharacters(in: .whitespacesAndNewlines),
                charScoped: true
            )
        } else {
            added = bookmarkStore.toggleAnnotation(
                bookUrl: activeBook.bookUrl,
                chapterIndex: currentChapterIndex,
                chapterTitle: cur.chapter.title,
                blockId: range.start,
                length: range.count,
                kind: kind,
                color: color,
                snippet: selectedParagraphText
            )
        }
        colorPickerKind = nil
        showBookmarkHint(added ? "已加\(name)" : "已取消\(name)")
    }

    /// 当前选区上已有的标注（字选按区间、整段按 block），气泡和调色板拿它显示状态
    private func currentSelectionAnnotation(kind: BookBookmark.Kind) -> BookBookmark? {
        let list = bookmarkStore.userAnnotations(bookUrl: activeBook.bookUrl,
                                                 chapterIndex: currentChapterIndex)
            .filter { $0.kind == kind }
        if let sel = charSelection {
            return list.first {
                $0.rangeUnitRaw == "char" && $0.blockId == sel.paragraphId
                    && ($0.charOffset ?? 0) == sel.start && ($0.length ?? 0) == sel.length
            }
        }
        guard let range = selectedBlockRange else { return nil }
        return list.first {
            $0.rangeUnitRaw == nil && $0.blockId == range.start
                && ($0.length ?? 1) == range.count
        }
    }

    /// 明确清除当前选区的标注：不看颜色，命中就删
    private func clearAnnotation(kind: BookBookmark.Kind) {
        guard let range = selectedBlockRange, let cur = currentLoadedChapter else { return }
        let name = kind == .underline ? "下划线" : "底色"
        guard currentSelectionAnnotation(kind: kind) != nil else {
            showBookmarkHint("这里没有\(name)")
            return
        }
        tapSuppressor.suppress()
        if let sel = charSelection {
            _ = bookmarkStore.toggleAnnotation(
                bookUrl: activeBook.bookUrl,
                chapterIndex: currentChapterIndex,
                chapterTitle: cur.chapter.title,
                blockId: sel.paragraphId,
                charOffset: sel.start,
                length: sel.length,
                kind: kind,
                charScoped: true,
                forceRemove: true
            )
        } else {
            _ = bookmarkStore.toggleAnnotation(
                bookUrl: activeBook.bookUrl,
                chapterIndex: currentChapterIndex,
                chapterTitle: cur.chapter.title,
                blockId: range.start,
                length: range.count,
                kind: kind,
                forceRemove: true
            )
        }
        colorPickerKind = nil
        showBookmarkHint("已清除\(name)")
    }

    /// 替换：把选中段落整段换成输入的词，规则按书存，加载正文时套用
    private func applyParagraphReplace() {
        guard let cur = currentLoadedChapter else { return }
        var from = currentSelectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        var to = replaceInput
        // 字选：只改选中那几个字，保留同一段其余内容。用整段做锚点，
        // 免得「替换」把本章里所有相同短词一起换掉。
        if let sel = charSelection {
            let ns = selectedParagraphRawText as NSString
            let relative = sel.start - selectedParagraphCharStart
            if relative >= 0, relative + sel.length <= ns.length {
                from = selectedParagraphRawText.trimmingCharacters(in: .whitespacesAndNewlines)
                to = ns.replacingCharacters(in: NSRange(location: relative, length: sel.length),
                                             with: replaceInput)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !from.isEmpty else { return }
        bookmarkStore.addTextReplaceRule(bookUrl: activeBook.bookUrl, from: from, to: to)
        showReplaceInput = false
        clearParagraphSelection()
        _ = cur
        refreshCurrentChapter()
        showBookmarkHint("已替换")
    }

    /// 正文加载时套用这本书的替换规则
    private func applyingBookReplaceRules(_ content: String) -> String {
        TextReplaceRules.apply(content, rules: bookmarkStore.textReplaceRules(bookUrl: activeBook.bookUrl))
    }

    /// 下拉识别器：四种翻页模式都走这一条路（见 ReaderPullDownCatcher 的说明）
    @ViewBuilder
    private var pullDownCatcherLayer: some View {
        #if os(iOS)
        ReaderPullDownCatcher(
            isEnabled: { !showControls && !readerOverlayPresented },
            isAtTop: { isAtChapterTop },
            onChanged: { dy in
                // 整页跟着手指下来，橡皮筋阻尼：起手跟手，越拉越沉，最多能拉到半屏多
                if dy > 4 { isPullActive = true }
                bookmarkPullProgress = min(1, dy / 70)
                pagePullOffset = pullOffset(for: dy)
            },
            onEnded: { _, passed in
                bookmarkPullProgress = 0
                if passed {
                    finishBookmarkPull()
                } else {
                    isPullActive = false
                    // 阻尼给得低一点：回弹带一点过冲，才有 Q 弹的手感
                    withAnimation(.interpolatingSpring(stiffness: 220, damping: 15)) {
                        pagePullOffset = 0
                    }
                    if !bookmarkRibbonSettled { bookmarkRibbonVisible = false }
                }
            },
            onLongPress: { point in
                handleLongPressAtWindowPoint(point)
            },
            onCharHandleHit: { point in
                beginCharHandleDrag(at: point)
            },
            onCharHandleDrag: { point in
                updateCharSelection(isStart: isDraggingCharStart, at: point)
            },
            onTap: { point in
                handleTapWhileListening(at: point)
            }
        )
        #endif
    }

    /// 松手达标：切书签 + 让页面停在拉下的位置，等书签落好再弹回（背景图这时是露着的）
    private func finishBookmarkPull() {
        bookmarkPullProgress = 0
        withAnimation(.easeOut(duration: 0.2)) {
            pagePullOffset = min(pullMaxOffset(), max(pagePullOffset, 96))
        }
        toggleBookmarkByPull()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            withAnimation(.interpolatingSpring(stiffness: 220, damping: 15)) {
                pagePullOffset = 0
            }
            // 等页面回到原位再放开探针，免得回弹过程被当成滚动
            try? await Task.sleep(nanoseconds: 350_000_000)
            isPullActive = false
        }
    }

    /// 分页模式没有滚动这回事，永远算在顶部；滚动模式要偏移接近 0
    private var isAtChapterTop: Bool {
        guard readerConfig.pageMode == .scroll else { return true }
        return scrollOffsetY <= 2
    }

    /// 有面板挡在前面时，下拉与长按都不该再响应
    /// （不然在弹层里往下拖，会把底下的正文一起拉走，甚至顺手切了书签）
    private var readerOverlayPresented: Bool {
        showBookmarks || showTOC || showSearch || showTTSSettings || showBookInfo
            || showSourceSwitch || showTitleDesigner || showReplaceRules
            || showAggregateSearch || showBackgroundImagePicker || showReplaceInput
            || showComments || directCommentTarget != nil
    }

    /// 下拉最多能拉多低：屏幕的一半多一点，屏幕高就多给一点
    private func pullMaxOffset() -> CGFloat {
        let screenHeight = max(320, readerContainerSize.height)
        return min(560, max(260, screenHeight * 0.62))
    }

    /// 下拉位移的阻尼曲线：`(1 - 1/(dy/max + 1))·max`
    ///
    /// 起手斜率约等于 1（跟着手指走，不粘不飘），越接近上限越沉，永远拉不到死板的上限，
    /// 这就是 iOS 那套橡皮筋手感。
    private func pullOffset(for dy: CGFloat) -> CGFloat {
        guard dy > 0 else { return 0 }
        let maxOffset = pullMaxOffset()
        return (1 - 1 / (dy / maxOffset + 1)) * maxOffset
    }

    /// 下拉是开关：这一章没书签就加，有就取消
    private func toggleBookmarkByPull() {
        guard let loaded = currentLoadedChapter else { return }
        let index = loaded.chapter.index
        let existing = bookmarkStore.bookmarks(for: activeBook.bookUrl)
            .filter { $0.chapterIndex == index && $0.kind == .bookmark }

        if existing.isEmpty {
            addBookmarkHere()
            // 从最顶上缓缓落到页顶，停一下再淡出隐藏
            bookmarkRibbonSettled = false
            bookmarkRibbonVisible = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000)
                withAnimation(.easeOut(duration: 0.85)) {
                    bookmarkRibbonSettled = true
                }
            }
            showBookmarkHint("已加书签 · 第 \(index + 1) 章")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                withAnimation(.easeOut(duration: 0.35)) {
                    bookmarkRibbonVisible = false
                }
            }
        } else {
            for item in existing {
                bookmarkStore.removeBookmark(item)
            }
            showBookmarkHint("已取消书签 · 第 \(index + 1) 章")
        }
        // 下拉这一下有时会把控制面板一起带出来（系统把释放当成点按），这里收回去
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            if showControls {
                withAnimation(.easeInOut(duration: 0.15)) { showControls = false }
            }
        }
    }

    /// 顶上那条短提示。默认 1.8 秒；「没声音」这种要用户动手的，给长一点（4 秒）
    private func showBookmarkHint(_ text: String, seconds: Double = 1.8) {
        bookmarkHintText = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if bookmarkHintText == text { bookmarkHintText = nil }
        }
    }

    private var hasBookmarkForCurrentChapter: Bool {
        bookmarkStore.bookmarks(for: activeBook.bookUrl)
            .contains { $0.chapterIndex == currentChapterIndex }
    }

    /// 下拉露出的背景图：没设置就什么都不画（还是原来的纸色）
    private func loadReaderAssets() {
        #if os(iOS)
        pullBackgroundImage = ReaderAssetStorage.image(for: ReaderAssetStorage.pullBackgroundKey)
        bookmarkImage = ReaderAssetStorage.image(for: ReaderAssetStorage.bookmarkImageKey)
        #endif
    }

    @ViewBuilder
    private var pullBackgroundLayer: some View {
        #if os(iOS)
        // 不拉的时候不画：正文层从安全区顶部开始，背景图若一直铺着，状态栏那一条也会露出图。
        if let pullBackgroundImage, pagePullOffset > 0 {
            PullBackgroundCanvas(image: pullBackgroundImage,
                                 zoom: pullBackgroundScale,
                                 offsetX: pullBackgroundOffsetX,
                                 offsetY: pullBackgroundOffsetY,
                                 alignment: pullBackgroundAlign)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        #endif
    }

    /// 下拉时绶带跟着手指下来；落定后挂在页顶
    private var ribbonOffsetY: CGFloat {
        if bookmarkRibbonSettled { return 0 }
        // 松手落定前先把它挪回最顶上，再从那里缓缓下来
        if bookmarkRibbonVisible { return -ribbonTravel }
        return -ribbonTravel + ribbonTravel * bookmarkPullProgress
    }

    /// 绶带/书签图从页面顶端往上多高开始下落
    private var ribbonTravel: CGFloat { 140 }

    @ViewBuilder
    private func bookmarkRibbonView(width: CGFloat) -> some View {
        #if os(iOS)
        let boxHeight = BookmarkBoxMetrics.height(width: width,
                                                   aspect: bookmarkAspect,
                                                   imageSize: bookmarkImage?.size)
        if let image = bookmarkImage {
            Image(uiImage: image)
                .resizable()
                // 填满「宽 × 高」这个盒子再裁掉多的：想调成别的比例不会把图压变形
                .scaledToFill()
                .frame(width: width, height: boxHeight, alignment: .top)
                .clipped()
                .shadow(color: Color.black.opacity(0.18),
                        radius: bookmarkRibbonSettled ? 2 : 9,
                        y: bookmarkRibbonSettled ? 1 : 6)
        } else {
            defaultRibbon(width: width, height: boxHeight)
        }
        #else
        defaultRibbon(width: width,
                      height: BookmarkBoxMetrics.height(width: width, aspect: bookmarkAspect, imageSize: nil))
        #endif
    }

    private func defaultRibbon(width: CGFloat, height: CGFloat) -> some View {
        BookmarkRibbonShape()
            .fill(Color.accentColor.opacity(0.95))
            .frame(width: width, height: height)
            .shadow(color: Color.black.opacity(0.18),
                    radius: bookmarkRibbonSettled ? 3 : 9,
                    y: bookmarkRibbonSettled ? 2 : 6)
    }

    private var bookmarkRibbonOverlay: some View {
        GeometryReader { geo in
            let ribbonWidth = CGFloat(bookmarkWidth)
            let maxX = max(0, geo.size.width - ribbonWidth - 6)
            let x = min(maxX, max(0, geo.size.width * CGFloat(bookmarkX) - ribbonWidth / 2))
            Group {
                if bookmarkRibbonVisible || bookmarkPullProgress > 0 {
                    bookmarkRibbonView(width: ribbonWidth)
                        // 贴屏幕最顶：y 从上沿算，-safeTop 把状态栏那条也算进来
                        .offset(x: x, y: ribbonOffsetY - safeInsets.top + 2 + CGFloat(bookmarkY))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var bookmarkHintOverlay: some View {
        Group {
            if let bookmarkHintText {
                Text(bookmarkHintText)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .padding(.top, safeInsets.top + 12)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: bookmarkHintText)
    }

    /// 听书球：阅读界面唯一的听书入口。
    ///
    /// 它挂在菜单这一层：点正文唤出菜单时一起出现，菜单收起、开界面设置、开任何浮层，
    /// 它跟着消失——正文层不再留听书控件。所有听书选项都从这颗球进朗读面板拿。
    /// 点在听状态上是暂停/继续，没在听就开面板；长按也开面板。
    private var listeningBallLayer: some View {
        Group {
            if showControls, !showSettings, !showReadingPanel, !readerOverlayPresented {
                listeningBall
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .animation(.easeInOut(duration: 0.2), value: audioService.playbackPhase)
    }

    private var listeningBall: some View {
        Image(systemName: audioService.phaseGlyph)
            .font(.system(size: 19, weight: .semibold))
            .foregroundColor(audioService.isPlaying ? theme.palette.accent : readerConfig.textColor)
            .frame(width: 46, height: 46)
            .background(Circle().fill(readerPanelSurface))
            .overlay(
                Circle().stroke(audioService.isPlaying ? theme.palette.accent : theme.palette.divider,
                                lineWidth: audioService.isPlaying ? 1.4 : 0.8)
            )
            .shadow(color: .black.opacity(0.16), radius: 7, y: 2)
            .contentShape(Circle())
            // 轻点和长按用同一个拖动手势按按住时长区分：两套手势叠在一起时，
            // 旧系统上高优先级长按会把轻点吃掉，表现就是「按了没反应」。
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if listeningBallPressBegan == nil { listeningBallPressBegan = Date() }
                    }
                    .onEnded { _ in
                        let held = Date().timeIntervalSince(listeningBallPressBegan ?? Date())
                        listeningBallPressBegan = nil
                        if held >= 0.45 {
                            handleListeningBallLongPress()
                        } else {
                            handleListeningBallTap()
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("听书")
            .accessibilityIdentifier("reader.listeningBall")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("轻点打开朗读面板；播放中轻点暂停或继续")
            .accessibilityValue(audioService.isPaused ? "已暂停"
                                : (audioService.isPlaying ? "正在朗读" : "未开始"))
            .accessibilityAction { handleListeningBallTap() }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 20)
            .padding(.bottom, screenBottomInset + 134)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .onAppear {
                AppLog.write("[听书] 球出现 · 相位=\(audioService.playbackPhase.rawValue) 有会话=\(audioService.hasReadingSession)")
            }
            .onDisappear {
                AppLog.write("[听书] 球消失 · controls=\(showControls)")
            }
    }

    /// 轻点听书球：没在听就开面板，在听就暂停/继续。
    private func handleListeningBallTap() {
        tapSuppressor.suppress()
        if audioService.isPlaying || audioService.isPaused {
            if audioService.isPlaying { audioService.pause() } else { audioService.resume() }
        } else {
            withAnimation(.easeOut(duration: 0.18)) { showReadingPanel = true }
        }
        AppLog.write("[听书] 球 · 相位=\(audioService.playbackPhase.rawValue) 有会话=\(audioService.hasReadingSession)")
    }

    private func handleListeningBallLongPress() {
        tapSuppressor.suppress()
        withAnimation(.easeOut(duration: 0.18)) { showReadingPanel = true }
        AppLog.write("[听书] 长按球 · 打开朗读面板")
    }

    /// 朗读面板的浮层：点空白处、右上角 × 都能关，别挡着读正文
    private var readingPanelOverlay: some View {
        Group {
            if showReadingPanel {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()
                        .onTapGesture { dismissReadingPanel() }
                    readingPanelCard
                        .padding(.horizontal, 16)
                        .padding(.bottom, max(safeInsets.bottom, 12) + 14)
                }
            }
        }
    }

    /// 朗读面板：从哪起读、要不要跟页、底色跟谁走，三件事一张卡说完
    private var readingPanelCard: some View {
        let items = readingItemsForCurrentChapter
        let pageCount = max(1, currentLoadedChapter?.pages.count ?? 1)
        let pageDetail = readerConfig.pageMode == .scroll
            ? "从视野里这一段起"
            : "第 \(min(currentPageIndex + 1, pageCount))/\(pageCount) 页"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "headphones")
                    .font(.system(size: 14, weight: .semibold))
                Text("朗读")
                    .font(.system(size: 15, weight: .semibold))
                if audioService.playbackPhase != .idle {
                    Text("\(audioService.progressIndex)/\(audioService.progressTotal)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(theme.palette.secondaryInk)
                }
                Spacer(minLength: 0)
                Button { dismissReadingPanel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(BubbleActionButtonStyle())
            }
            .foregroundColor(theme.palette.ink)

            // 「现在到底哪个源在响」：多角色一段一个音色，面板上不写清楚，用户只能靠耳朵猜
            if TTSCastStore.shared.enabled, !audioService.castNowLabel.isEmpty {
                Text(audioService.castNowLabel)
                    .font(.system(size: 11))
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            // 底栏撤掉那格听书以后，「跳回正在读的那一页」就没人管了。
            // 球上有会话时点一下是暂停，长按才开这张面板，所以入口放在这里最顺。
            if audioService.hasReadingSession {
                Button {
                    jumpToReadingBlock()
                    dismissReadingPanel()
                } label: {
                    readingPanelRow(icon: "scope",
                                    title: "回到正在读的位置",
                                    detail: "第 \(audioService.progressIndex)/\(audioService.progressTotal) 段")
                }
                .buttonStyle(BubbleActionButtonStyle())
            }

            Button {
                startReadingChapter()
                dismissReadingPanel()
            } label: {
                readingPanelRow(icon: "text.alignleft", title: "从本章开头读",
                                detail: "第 \(currentChapterIndex + 1) 章 · \(items.count) 段")
            }
            .buttonStyle(BubbleActionButtonStyle())
            .disabled(items.isEmpty)

            Button {
                if let blockId = currentPageFirstBlockId {
                    startReadingChapter(fromBlockId: blockId)
                } else {
                    showBookmarkHint("这一页没有可读的正文")
                }
                dismissReadingPanel()
            } label: {
                readingPanelRow(icon: "doc.text", title: "从这一页读", detail: pageDetail)
            }
            .buttonStyle(BubbleActionButtonStyle())
            .disabled(items.isEmpty)

            Button {
                dismissReadingPanel()
                showTTSSettings = true
            } label: {
                readingPanelRow(icon: "gearshape", title: "听书设置", detail: "音色、语速、多角色")
            }
            .buttonStyle(BubbleActionButtonStyle())

            Rectangle()
                .fill(theme.palette.divider.opacity(0.7))
                .frame(height: 0.5)

            Toggle(isOn: Binding(
                get: { ttsFollowPage },
                set: { value in
                    ttsFollowPage = value
                    AppLog.write("[听书] 跟页读 \(value ? "开" : "关")")
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("翻到哪页读哪页")
                        .font(.system(size: 13, weight: .medium))
                    Text(readerConfig.pageMode == .scroll
                         ? "滚动模式按段续读，不吃这个开关"
                         : "翻页后从这一页第一段重新起读")
                        .font(.system(size: 11))
                        .foregroundColor(theme.palette.secondaryInk)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: theme.palette.accent))
            .disabled(readerConfig.pageMode == .scroll)
            .foregroundColor(theme.palette.ink)

            Rectangle()
                .fill(theme.palette.divider.opacity(0.7))
                .frame(height: 0.5)

            Toggle(isOn: Binding(
                get: { ttsReadFromCache },
                set: { value in
                    ttsReadFromCache = value
                    AppLog.write("[听书] 读本地缓存 \(value ? "开" : "关")")
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("听书用本地缓存")
                        .font(.system(size: 13, weight: .medium))
                    Text(cachedChapterHint)
                        .font(.system(size: 11))
                        .foregroundColor(theme.palette.secondaryInk)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: theme.palette.accent))
            .foregroundColor(theme.palette.ink)

            Rectangle()
                .fill(theme.palette.divider.opacity(0.7))
                .frame(height: 0.5)

            VStack(alignment: .leading, spacing: 8) {
                Text("语速")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.palette.ink)
                HStack(spacing: 8) {
                    speedChip("0.8×", 0.8)
                    speedChip("1.0×", 1.0)
                    speedChip("1.2×", 1.2)
                    speedChip("1.5×", 1.5)
                    speedChip("2.0×", 2.0)
                    Spacer(minLength: 0)
                }
            }

            Rectangle()
                .fill(theme.palette.divider.opacity(0.7))
                .frame(height: 0.5)

            // 定时朗读：睡前挂上就去睡，到点自己停，位置留着
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("定时朗读")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.palette.ink)
                    Spacer(minLength: 0)
                    if audioService.sleepRemaining > 0 {
                        Text("还剩 \(audioService.sleepRemainingLabel)")
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(theme.palette.accent)
                    } else if audioService.sleepStopAtChapterEnd {
                        Text("读完本章停")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(theme.palette.accent)
                    }
                }
                HStack(spacing: 8) {
                    sleepChip("15 分", 15)
                    sleepChip("30 分", 30)
                    sleepChip("60 分", 60)
                    chapterEndSleepChip()
                    sleepOffChip()
                    Spacer(minLength: 0)
                }
            }

            Rectangle()
                .fill(theme.palette.divider.opacity(0.7))
                .frame(height: 0.5)

            VStack(alignment: .leading, spacing: 8) {
                Text("朗读底色")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.palette.ink)
                HStack(spacing: 8) {
                    tintChip("主题色", "accent")
                    tintChip("跟底色", "highlight")
                    tintChip("跟划线", "underline")
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(theme.palette.surface)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(bubbleLiftOpacity))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.palette.divider, lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func dismissReadingPanel() {
        withAnimation(.easeOut(duration: 0.18)) { showReadingPanel = false }
    }

    /// 「听书用本地缓存」下面的说明：缓存有没有，读者一眼就知道能不能靠它
    private var cachedChapterHint: String {
        let cached = BookContentService.shared.hasCachedChapter(bookUrl: activeBook.bookUrl,
                                                             chapterIndex: currentChapterIndex)
        return cached
            ? "本章已缓存 · 源站没登录时也能听真正文"
            : "这一章还没缓存，缓存后才会用这份正文"
    }

    /// 面板里的起读入口：一行图标 + 标题 + 说明 + 箭头
    private func readingPanelRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.palette.secondaryInk)
        }
        .foregroundColor(theme.palette.ink)
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.palette.divider.opacity(0.18))
        )
        .contentShape(Rectangle())
    }

    /// 语速：直接改 audioService.speechRate，正在读的段读完就按新速度接上
    /// 定时朗读的几个胶囊：选中的那个亮起来，再点一次不取消，靠右边的「关」
    private func sleepChip(_ title: String, _ minutes: Int) -> some View {
        let active = audioService.sleepMinutes == minutes
        return Button {
            audioService.startSleepTimer(minutes: minutes)
        } label: {
            sleepChipLabel(title, active: active)
        }
        .buttonStyle(BubbleActionButtonStyle())
    }

    private func chapterEndSleepChip() -> some View {
        Button {
            audioService.setSleepStopAtChapterEnd(true)
        } label: {
            sleepChipLabel("读完本章", active: audioService.sleepStopAtChapterEnd)
        }
        .buttonStyle(BubbleActionButtonStyle())
    }

    private func sleepOffChip() -> some View {
        let idle = audioService.sleepDeadline == nil && !audioService.sleepStopAtChapterEnd
        return Button {
            audioService.cancelSleepTimer()
            audioService.setSleepStopAtChapterEnd(false)
            AppLog.write("[听书] 定时关掉")
        } label: {
            sleepChipLabel("关", active: idle)
        }
        .buttonStyle(BubbleActionButtonStyle())
    }

    private func sleepChipLabel(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: active ? .semibold : .regular))
            .monospacedDigit()
            .foregroundColor(active ? theme.palette.accent : theme.palette.ink)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Capsule().fill(active ? theme.palette.accent.opacity(0.16) : theme.palette.divider.opacity(0.22)))
            .overlay(Capsule().stroke(active ? theme.palette.accent : theme.palette.divider,
                                      lineWidth: active ? 1.2 : 0.6))
    }

    private func speedChip(_ title: String, _ times: Double) -> some View {
        let active = abs(Double(audioService.speechRate / AVSpeechUtteranceDefaultSpeechRate) - times) < 0.001
        return Button {
            audioService.speechRate = Float(times) * AVSpeechUtteranceDefaultSpeechRate
            AppLog.write("[听书] 语速 \(String(format: "%.1f", times))×")
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .monospacedDigit()
                .foregroundColor(active ? theme.palette.accent : theme.palette.ink)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Capsule().fill(active ? theme.palette.accent.opacity(0.16) : theme.palette.divider.opacity(0.22)))
                .overlay(Capsule().stroke(active ? theme.palette.accent : theme.palette.divider,
                                          lineWidth: active ? 1.2 : 0.6))
        }
        .buttonStyle(BubbleActionButtonStyle())
    }

    /// 底色三选一：色点直接给出实际颜色，免得挑完才发现浅得看不见
    private func tintChip(_ title: String, _ value: String) -> some View {
        let color: Color = value == "highlight"
            ? readerHexColor(highlightHex)
            : (value == "underline" ? readerHexColor(underlineHex) : nierPalette.accent)
        let active = ttsTintSource == value
        return Button {
            ttsTintSource = value
            AppLog.write("[听书] 朗读底色来源 \(value)")
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.black.opacity(0.22), lineWidth: 0.5))
                Text(title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
            }
            .foregroundColor(active ? theme.palette.accent : theme.palette.ink)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(active ? color.opacity(0.20) : theme.palette.divider.opacity(0.22)))
            .overlay(Capsule().stroke(active ? color : theme.palette.divider, lineWidth: active ? 1.2 : 0.6))
        }
        .buttonStyle(BubbleActionButtonStyle())
    }

    private func addBookmarkHere() {
        let title = (!chapters.isEmpty && currentChapterIndex < chapters.count)
            ? chapters[currentChapterIndex].title
            : activeBook.name
        let snippet = currentChapterContent
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = BookBookmark(
            bookUrl: activeBook.bookUrl,
            chapterIndex: currentChapterIndex,
            chapterTitle: title,
            charOffset: currentChapterCharOffset(),
            snippet: String(snippet.prefix(60)),
            note: newBookmarkNote.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        bookmarkStore.addBookmark(bookmark)
        newBookmarkNote = ""
    }

    private var tocDisplayChapters: [BookChapter] {
        tocReversed ? chapters.reversed() : chapters
    }

    private var tocFilteredChapters: [BookChapter] {
        let query = tocSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tocDisplayChapters }
        return tocDisplayChapters.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// 下载缓存：从当前章往后缓存 N 章，N 在设置里调
    private func downloadCachedChapters(span chosen: Int? = nil) {
        guard let source = effectiveSource, !chapters.isEmpty else { return }
        let start = max(0, currentChapterIndex)
        let span = max(1, chosen ?? readerConfig.cachedChapterCount)
        // 当前选择记为默认值，与设置页显示一致
        if let chosen { readerConfig.cachedChapterCount = chosen }
        let end = min(chapters.count - 1, start + span - 1)
        guard start <= end else { return }
        let indices = Array(start...end)
        _ = ChapterDownloadManager.shared.start(
            book: activeBook,
            chapters: chapters,
            source: source,
            indices: indices
        )
        downloadHint = "已加入下载队列：第 \(start + 1)–\(end + 1) 章（共 \(indices.count) 章）"
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { downloadHint = nil }
        }
    }

    /// 刷新本章：把缓存里这一章丢掉重抓，尽量停在当前页
    private func refreshCurrentChapter() {
        let index = currentChapterIndex
        let page = currentPageIndex
        chapterCache[index] = nil
        audioService.stop()
        errorMessage = nil
        loadInitialChapter(at: index, targetPageIndex: page)
    }

    /// 清掉本书的章节缓存：磁盘 + 内存一起清，然后重抓当前章。
    /// 旧缓存里没有热评标记时，靠这个换一份新正文。
    private func clearCurrentBookCache() {
        let index = currentChapterIndex
        let page = currentPageIndex
        let count = BookContentService.shared.getCacheCount(for: activeBook.bookUrl)
        BookContentService.shared.clearCache(for: activeBook.bookUrl)
        chapterCache.removeAll()
        loadedChapters = []
        audioService.stop()
        errorMessage = nil
        downloadHint = count > 0 ? "已清除本书缓存（\(count) 章）" : "本书没有缓存章节，已重新加载"
        loadInitialChapter(at: index, targetPageIndex: page)
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { downloadHint = nil }
        }
    }

    /// 手动刷新目录：重新抓章节列表，尽量停在原来那一章
    private func refreshChapterList() async {
        guard let source = effectiveSource else { return }
        let title = (!chapters.isEmpty && currentChapterIndex < chapters.count) ? chapters[currentChapterIndex].title : nil
        do {
            var fetched = try await BookContentService.shared.fetchChapterList(book: activeBook, source: source)
            for i in 0..<fetched.count { fetched[i].index = i }
            await MainActor.run {
                self.chapters = fetched
                BookStore.shared.saveChapters(fetched, for: tocCacheKey(source: source))
                if let title, let idx = fetched.firstIndex(where: { $0.title == title }) {
                    currentChapterIndex = idx
                } else if currentChapterIndex >= fetched.count {
                    currentChapterIndex = max(0, fetched.count - 1)
                }
            }
            _ = BookStore.shared.saveOrUpdateBook(activeBook)
        } catch {
            await MainActor.run {
                self.errorMessage = "目录刷新失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - Bottom 1/3 Reading Settings Card (非侵入式底部设置卡片)
    private var readingSettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsHeader
            if !panelCollapsed {
                settingsPanelSwitcher
                settingsStatusStrip
                brightnessRow
                settingsPanelBody
            }
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: max(16, safeInsets.bottom), trailing: 18))
        .modifier(ReaderSettingsCardChrome(
            radius: chromeRadius,
            // 面板调半透明时不要毛玻璃，否则还是看不清底下的正文
            fill: theme.choice == .lunarTerminal
                ? theme.palette.surface.opacity(effectivePanelLayerOpacity)
                : readerConfig.backgroundColor.opacity(effectivePanelLayerOpacity),
            showsMaterial: effectivePanelOpacity >= 0.99 && theme.choice == .standard,
            ink: chromeInk,
            backdrop: chromeBackground,
            layerOpacity: effectivePanelLayerOpacity
        ))
        .fileImporter(
            isPresented: $showBackgroundImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                importBackgroundImage(from: url)
            }
        }
        .onAppear {
            AppLog.write("[阅读设置] 面板卡片已渲染 折叠=\(panelCollapsed)")
        }
        .onChange(of: layoutPreviewSignature) { _ in flashLayoutPreview() }
        .onDisappear {
            layoutPreviewToken += 1
            layoutPreviewActive = false
        }
    }

    /// 十几个 onChange 合成一个：每层 onChange 都会给视图类型再套一层泛型，
    /// iOS 27 解码这串类型名会栈溢出。
    private var layoutPreviewSignature: String {
        "\(readerConfig.fontSize)|\(readerConfig.lineSpacing)|\(readerConfig.letterSpacing)|\(readerConfig.paragraphSpacing)|\(readerConfig.paddingTop)|\(readerConfig.paddingBottom)|\(readerConfig.paddingLeft)|\(readerConfig.paddingRight)|\(readerConfig.firstLineIndent)|\(readerConfig.pageMode.rawValue)|\(readerConfig.chapterTitleScale)|\(readerConfig.chapterTitleSpacing)|\(readerConfig.chapterTopSpacing)|\(readerConfig.chapterBottomSpacing)"
    }

    /// iOS 上附带仿真翻页的手势计数，方便截屏排查；其他平台为空。
    private var pagerDebugSuffix: String {
        #if os(iOS)
        return " · 手势 pan\(PageCurlPager.Coordinator.panEnds)/\(PageCurlPager.Coordinator.panHits) swipe\(PageCurlPager.Coordinator.swipeHits) tap\(PageCurlPager.Coordinator.tapHits)"
        #else
        return ""
        #endif
    }

    /// 设置面板正文单独拆出来，避免阅读页整体表达式过大触发编译器超时。
    private var settingsPanelBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch settingsPanel {
                case .quick:
                    CollapsibleSettingBlock(
                        title: "阅读模式",
                        tint: readerConfig.textColor,
                        initiallyExpanded: true,
                        summary: readerConfig.pageMode.rawValue
                    ) { pageModeRow }
                    CollapsibleSettingBlock(
                        title: "字号与主题",
                        tint: readerConfig.textColor,
                        initiallyExpanded: true,
                        summary: "\(safeInt(readerConfig.fontSize)) pt · \(readerConfig.theme.rawValue)"
                    ) {
                        fontSizeRow
                        themeRow
                    }
                    CollapsibleSettingBlock(
                        title: "背景图",
                        tint: readerConfig.textColor,
                        summary: readerConfig.backgroundImageEnabled ? "已开启" : "关闭"
                    ) { backgroundImageSection }
                    CollapsibleSettingBlock(
                        title: "配色",
                        tint: readerConfig.textColor,
                        summary: readerConfig.useCustomColors ? "自定义" : "跟随主题"
                    ) { colorSection }
                    CollapsibleSettingBlock(
                        title: "热评卡片",
                        tint: readerConfig.textColor,
                        summary: "\(safeInt(readerConfig.reviewFontScale * 100))% · \(reviewStyleName)"
                    ) { reviewCardSection }
                    CollapsibleSettingBlock(
                        title: "显示",
                        tint: readerConfig.textColor,
                        summary: "亮度 \(safeInt(readerConfig.brightness * 100))% · 面板 \(safeInt(readerConfig.panelOpacity * 100))%"
                    ) { displaySection }
                case .spacing:
                    CollapsibleSettingBlock(
                        title: "字体与正文",
                        tint: readerConfig.textColor,
                        initiallyExpanded: true,
                        summary: readerConfig.font.displayName
                    ) { typographySection }
                    CollapsibleSettingBlock(title: "正文排版", tint: readerConfig.textColor) { bodyLayoutSection }
                    underlineSection
                    CollapsibleSettingBlock(title: "页边距", tint: readerConfig.textColor) { marginSection }
                    CollapsibleSettingBlock(title: "章节标题", tint: readerConfig.textColor) { chapterTitleSection }
                    headerFooterSection
                case .tts:
                    settingsBlock { ttsSection }
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.18), value: settingsPanel)
            .tint(settingsAccent)
            .padding(.bottom, 4)
            .onAppear {
                AppLog.write("[阅读设置] 面板内容已渲染 \(settingsPanel.rawValue)")
            }
        }
        .frame(maxHeight: 420)
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                Text("READER")
                    .font(theme.typography.label)
                    .foregroundColor(theme.palette.secondaryInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .overlay(
                        Rectangle()
                            .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
                    )

                Text("阅读设置")
                    .font(theme.typography.title)
                    .foregroundColor(chromeInk)

                Spacer(minLength: 6)

                // 收起：只留标题这一行，整页露出来看效果
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        panelCollapsed.toggle()
                    }
                }) {
                    Image(systemName: panelCollapsed ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .buttonStyle(.plain)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        showSettings = false
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .buttonStyle(.plain)
            }

            if !panelCollapsed {
                HStack(spacing: 6) {
                    settingsHeaderChip("SETTINGS / \(settingsPanel.rawValue)")
                    settingsHeaderChip(readerConfig.pageMode.rawValue)
                    settingsHeaderChip("章 \(currentChapterIndex + 1)/\(chapters.count)")
                    settingsHeaderChip("页 \(currentPageIndex + 1)/\(currentLoadedChapter?.pages.count ?? 0)")
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                // 翻页出问题时截一张就能看出来卡在哪，压到最后一行不抢视觉
                if !pagerDebugSuffix.isEmpty || isSwitchingChapter {
                    Text(gestureDebugText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(theme.palette.secondaryInk.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var gestureDebugText: String {
        var parts: [String] = []
        let gestures = pagerDebugSuffix
            .replacingOccurrences(of: " · 手势 ", with: "")
            .trimmingCharacters(in: .whitespaces)
        if !gestures.isEmpty { parts.append("手势 \(gestures)") }
        if isSwitchingChapter { parts.append("换章中") }
        return parts.joined(separator: " · ")
    }

    private func settingsHeaderChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(theme.palette.secondaryInk)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(theme.palette.elevated.opacity(effectivePanelLayerOpacity))
            )
            .overlay(
                Capsule()
                    .stroke(theme.palette.divider, lineWidth: 0.5)
            )
    }

    /// 设置面板的强调色：跟当前主题走
    private var settingsAccent: Color {
        theme.choice == .lunarTerminal ? theme.palette.accent : readerConfig.theme.accentColor
    }

    private var effectivePanelOpacity: Double {
        layoutPreviewActive ? min(readerConfig.panelOpacity, 0.24) : readerConfig.panelOpacity
    }

    private var effectivePanelLayerOpacity: Double {
        let value = max(0.0, min(1.0, effectivePanelOpacity))
        return 1 - (1 - value).squareRoot()
    }

    private func flashLayoutPreview() {
        layoutPreviewToken += 1
        let token = layoutPreviewToken
        if !layoutPreviewActive {
            withAnimation(.easeOut(duration: 0.16)) {
                layoutPreviewActive = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard token == layoutPreviewToken else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                layoutPreviewActive = false
            }
        }
    }

    /// 三个面板做成胶囊切换，比系统分段控件更贴阅读界面的调子
    private var settingsPanelSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(ReaderQuickPanel.allCases) { panel in
                let isOn = settingsPanel == panel
                Button {
                    // 自定义字体是导入来的，换容器/重装后可能只剩注册记录、文件早没了：
                    // 先按文件夹重建一次注册表，失效条目会自动出列，不会再拿它去构建字体
                    CustomFontService.shared.loadAll()
                                withAnimation(.easeInOut(duration: 0.18)) { settingsPanel = panel }
                } label: {
                    HStack(spacing: 5) {
                        Text(panelIndex(panel))
                            .font(theme.typography.mono)
                            .foregroundColor(theme.palette.secondaryInk)
                        Image(systemName: panel.symbolName)
                            .font(.system(size: 11, weight: .medium))
                        Text(panel.rawValue)
                            .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                    }
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                            .fill(isOn ? settingsAccent.opacity(0.20) : theme.palette.elevated.opacity(effectivePanelLayerOpacity))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                            .stroke(isOn ? settingsAccent.opacity(0.65) : theme.palette.divider, lineWidth: theme.metrics.borderWidth)
                    )
                    .foregroundColor(isOn ? settingsAccent : theme.palette.secondaryInk)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func panelIndex(_ panel: ReaderQuickPanel) -> String {
        switch panel {
        case .quick: return "01"
        case .spacing: return "02"
        case .tts: return "03"
        }
    }

    /// 分节标题：小号、加字距、压暗，配合上面的细线把设置分块
    private func sectionTitle(_ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(settingsAccent.opacity(0.85))
                .frame(width: 2.5, height: 11)
            Text(text)
                .font(theme.typography.label)
                .tracking(0.6)
                .foregroundColor(theme.palette.secondaryInk)
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(theme.palette.divider.opacity(0.55))
            .frame(height: 0.5)
            .padding(.top, 8)
    }

    private var settingsStatusStrip: some View {
        HStack(spacing: 0) {
            statusMetric("字号", "\(safeInt(readerConfig.fontSize)) pt")
            statusMetricDivider
            statusMetric("行距", "\(safeInt(readerConfig.lineSpacing)) pt")
            statusMetricDivider
            statusMetric("主题", readerConfig.theme.rawValue)
            statusMetricDivider
            statusMetric("翻页", readerConfig.pageMode.rawValue)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.elevated.opacity(effectivePanelLayerOpacity))
        .overlay(
            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous))
        .onAppear { AppLog.write("[阅读设置] 状态条已渲染") }
    }

    private func statusMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(theme.palette.secondaryInk.opacity(0.75))
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(theme.palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    private var statusMetricDivider: some View {
        Rectangle()
            .fill(theme.palette.divider.opacity(0.6))
            .frame(width: 0.5, height: 22)
    }

    private func settingsBlock<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(12)
        .background(theme.palette.elevated.opacity(effectivePanelLayerOpacity))
        .overlay(
            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous))
    }

    /// 页边距：上下左右四向分开调
    private var marginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionDivider
            settingSlider("上", value: $readerConfig.paddingTop, range: 0...64, step: 2)
            settingSlider("下", value: $readerConfig.paddingBottom, range: 0...64, step: 2)
            settingSlider("左", value: $readerConfig.paddingLeft, range: 0...64, step: 2)
            settingSlider("右", value: $readerConfig.paddingRight, range: 0...64, step: 2)
        }
    }

    /// 亮度调节，放在卡片靠上位置
    private var brightnessRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "sun.max")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.palette.secondaryInk)
                Text("屏幕亮度")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.palette.secondaryInk)
                Spacer()
                Text("\(safeInt(readerConfig.brightness * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.palette.secondaryInk)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 7)
                    .background(Capsule().fill(theme.palette.elevated.opacity(effectivePanelLayerOpacity)))
            }
            HStack(spacing: 10) {
                Image(systemName: "sun.min")
                    .font(.system(size: 11))
                    .foregroundColor(theme.palette.secondaryInk.opacity(0.7))
                Slider(value: Binding(
                    get: { min(max(readerConfig.brightness, 0.2), 1.0) },
                    set: { readerConfig.brightness = min(max($0, 0.2), 1.0) }
                ), in: 0.2...1.0, step: 0.05)
                    .tint(settingsAccent)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 13))
                    .foregroundColor(theme.palette.secondaryInk.opacity(0.7))
            }
        }
        .onAppear { AppLog.write("[阅读设置] 亮度条已渲染") }
    }

    /// 显示：亮度 + 自动夜间
    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("面板")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
                Slider(value: Binding(
                    get: { min(max(readerConfig.panelOpacity, 0.25), 1.0) },
                    set: { readerConfig.panelOpacity = min(max($0, 0.25), 1.0) }
                ), in: 0.25...1.0, step: 0.05)
                .tint(readerConfig.textColor.opacity(0.65))
                Text("\(safeInt(readerConfig.panelOpacity * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(readerConfig.textColor.opacity(0.6))
                    .frame(width: 40, alignment: .trailing)
            }
            Text("调布局时把面板调淡，能看见被它挡住的正文和页眉页脚。")
                .font(.system(size: 11))
                .foregroundColor(readerConfig.textColor.opacity(0.5))

            Toggle(isOn: $readerConfig.autoNight) {
                Text("自动夜间（22:00–07:00 自动切暗黑）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.75))
            }
            .toggleStyle(.switch)
        }
    }

    private var pageModeRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                spacing: 6
            ) {
                ForEach(PageMode.allCases) { mode in
                    let isOn = readerConfig.pageMode == mode
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            readerConfig.pageMode = mode
                        }
                    } label: {
                        Text(mode.rawValue)
                            .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                            .foregroundColor(isOn ? theme.palette.onAccent : theme.palette.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                                    .fill(isOn ? settingsAccent : theme.palette.elevated)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                                    .stroke(isOn ? settingsAccent : theme.palette.divider,
                                            lineWidth: theme.metrics.borderWidth)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        .onAppear { AppLog.write("[阅读设置] 阅读模式区已渲染") }
    }

    /// 排版页的字体预览：存下来的字体名可能已经不在设备上（导入过又删、跨设备带过来），
    /// 名字无效时回落到系统字体，别拿一个不存在的名字去构建字体。
    private func resolvedTypographyPreviewFont(size: CGFloat) -> Font {
        let name = readerConfig.font.postScriptName
        guard !name.isEmpty, ReaderFont.available.contains(where: { $0.postScriptName == name }) else {
            return .system(size: size)
        }
        return .custom(name, size: size)
    }

    // MARK: 排版
    private var typographySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                ForEach(ReaderFont.available) { font in
                    Button(font.displayName) {
                        readerConfig.fontName = font.postScriptName
                    }
                }
            } label: {
                HStack {
                    Text("字体")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(readerConfig.textColor.opacity(0.7))
                    Spacer()
                    Text(readerConfig.font.displayName)
                        .font(.system(size: 12))
                        .foregroundColor(readerConfig.textColor.opacity(0.55))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundColor(readerConfig.textColor.opacity(0.4))
                }
            }

            Text("天地玄黄，宇宙洪荒。日月盈昃，辰宿列张。")
                .font(resolvedTypographyPreviewFont(size: 15))
                .foregroundColor(readerConfig.textColor.opacity(0.85))
                .lineLimit(2)
                .padding(.vertical, 2)

            settingSlider("字间距", value: $readerConfig.letterSpacing, range: 0...4, step: 0.5)
            settingSlider("段间距", value: $readerConfig.paragraphSpacing, range: 0...30, step: 1)
            HStack(spacing: 8) {
                Toggle(isOn: $readerConfig.justifyLastPage) {
                    Text("页末匀空白")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(readerConfig.textColor.opacity(0.7))
                }
                .toggleStyle(.switch)
            }
            Text("开着的时候，一页没排满就把多出来的高度匀进段间距，正文一直铺到页脚，看着段距会宽一点。关掉，段距就是你填的那个数，剩下的空白全留在页尾。")
                .font(.system(size: 11))
                .foregroundColor(readerConfig.textColor.opacity(0.5))
            settingSlider("首行缩进", value: $readerConfig.firstLineIndent, range: 0...4, step: 1, suffix: " 字")

            HStack(spacing: 8) {
                Text("字重")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
                Picker("字重", selection: Binding(
                    get: { readerConfig.weight },
                    set: { readerConfig.weight = $0 }
                )) {
                    ForEach(ReaderWeight.allCases) { weight in
                        Text(weight.rawValue).tag(weight)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 8) {
                Text("简繁")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
                Picker("简繁", selection: $readerConfig.chineseConversion) {
                    ForEach(ChineseConversion.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Button(role: .destructive) {
                readerConfig.resetLayoutToDefaults()
                downloadHint = "排版设置已恢复默认"
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    await MainActor.run { downloadHint = nil }
                }
            } label: {
                Label("重置排版设置", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }

    // MARK: 正文排版（对齐与段间分隔线）
    private var bodyLayoutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionDivider

            HStack(spacing: 8) {
                Text("对齐")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
                Picker("对齐", selection: $readerConfig.textAlignment) {
                    ForEach(ReaderTextAlignment.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 8) {
                Text("段间分隔线")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
                Picker("段间分隔线", selection: $readerConfig.paragraphSeparatorLines) {
                    ForEach(0...3, id: \.self) { count in
                        Text(count == 0 ? "无" : "\(count)").tag(count)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: 正文下划线
    private var underlineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionDivider
            sectionTitle("正文下划线")

            Toggle(isOn: $readerConfig.underlineEnabled) {
                Text("给正文加下划线")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
            }
            .toggleStyle(.switch)

            if readerConfig.underlineEnabled {
                HStack(spacing: 8) {
                    Text("线型")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(readerConfig.textColor.opacity(0.7))
                    Picker("线型", selection: $readerConfig.underlinePattern) {
                        ForEach(ReaderUnderlinePattern.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                ColorPicker("下划线颜色", selection: underlineColorBinding, supportsOpacity: true)
                    .font(.system(size: 12))

                Text("Cocoa 文本接口不支持线宽和偏移，这两项调不了。")
                    .font(.system(size: 10))
                    .foregroundColor(readerConfig.textColor.opacity(0.45))
            }
        }
    }

    private var underlineColorBinding: Binding<Color> {
        Binding(
            get: { readerConfig.underlineColor ?? readerConfig.textColor },
            set: { readerConfig.underlineColorHex = $0.hexString ?? "" }
        )
    }

    // MARK: 章节标题（标题区间距）
    private var chapterTitleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionDivider
            settingSlider("字号", value: $readerConfig.chapterTitleScale, range: 1.0...1.8, step: 0.02, suffix: " ×")
            settingSlider("标题下距", value: $readerConfig.chapterTitleSpacing, range: 0...48, step: 2)
            settingSlider("章前距", value: $readerConfig.chapterTopSpacing, range: 0...48, step: 2)
            settingSlider("章后距", value: $readerConfig.chapterBottomSpacing, range: 0...72, step: 2)

            HStack(spacing: 10) {
                Button("章节标题设计器…") { showTitleDesigner = true }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundColor(readerConfig.textColor.opacity(0.85))
                Spacer()
                if readerConfig.hasDesignedChapterTitle {
                    Text("已设计")
                        .font(.system(size: 11))
                        .foregroundColor(readerConfig.textColor.opacity(0.5))
                    Button("清除") {
                        readerConfig.chapterTitleHTMLTemplate = ""
                        readerConfig.chapterTitleProjectJSON = ""
                        readerConfig.chapterTitleCanvasHeight = 0
                    }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundColor(readerConfig.textColor.opacity(0.5))
                }
            }
        }
    }

    // MARK: 阅读背景图
    private var backgroundImageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $readerConfig.backgroundImageEnabled) {
                Text("用图片做阅读背景")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
            }
            .toggleStyle(.switch)

            if readerConfig.backgroundImageEnabled {
                HStack(spacing: 10) {
                    #if os(iOS)
                    if #available(iOS 16.0, *) {
                        // 从相册选，别开文件管理器
                        PhotosPicker(selection: Binding(
                            get: { backgroundPhotoItem as? PhotosPickerItem },
                            set: { newValue in
                                backgroundPhotoItem = newValue
                                guard let item = newValue else { return }
                                Task {
                                    if let data = try? await item.loadTransferable(type: Data.self),
                                       let path = ReaderBackgroundStorage.save(data) {
                                        await MainActor.run {
                                            readerConfig.backgroundImagePath = path
                                            readerConfig.backgroundImageEnabled = true
                                        }
                                    }
                                }
                            }
                        ), matching: .images) {
                            Text(readerConfig.backgroundImagePath.isEmpty ? "从相册选图" : "换一张")
                                .font(.system(size: 12))
                                .foregroundColor(readerConfig.textColor.opacity(0.8))
                        }
                    } else {
                        Button("选择图片…") { showBackgroundImagePicker = true }
                            .font(.system(size: 12))
                            .buttonStyle(.plain)
                            .foregroundColor(readerConfig.textColor.opacity(0.8))
                    }
                    #else
                    Button("选择图片…") { showBackgroundImagePicker = true }
                        .font(.system(size: 12))
                        .buttonStyle(.plain)
                        .foregroundColor(readerConfig.textColor.opacity(0.8))
                    #endif
                    Spacer()
                    if !readerConfig.backgroundImagePath.isEmpty {
                        Button("清除") { readerConfig.backgroundImagePath = "" }
                            .font(.system(size: 12))
                            .buttonStyle(.plain)
                            .foregroundColor(readerConfig.textColor.opacity(0.5))
                    }
                }
                Text(readerConfig.backgroundImagePath.isEmpty
                     ? "未选择图片"
                     : URL(fileURLWithPath: readerConfig.backgroundImagePath).lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundColor(readerConfig.textColor.opacity(0.5))
                    .lineLimit(1)

                if !readerConfig.backgroundImagePath.isEmpty {
                    // 跟下拉背景、书签图一样：缩放 + 位置都能调
                    backgroundImageSlider("缩放", value: $backgroundImageScale, range: 0.2...4)
                    backgroundImageSlider("左右位置", value: $backgroundImageOffsetX, range: -400...400)
                    backgroundImageSlider("上下位置", value: $backgroundImageOffsetY, range: -400...400)
                }
            }
        }
    }

    private func backgroundImageSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(readerConfig.textColor.opacity(0.6))
                .frame(width: 56, alignment: .leading)
            Slider(value: Binding(
                get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
                set: { value.wrappedValue = $0 }
            ), in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(readerConfig.textColor.opacity(0.5))
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: 自定义配色
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $readerConfig.useCustomColors) {
                Text("自定义背景与文字颜色")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
            }
            .toggleStyle(.switch)

            // 预设配色，点一下同时设定背景和文字
            HStack(spacing: 10) {
                ForEach(ReaderPresetColor.allCases) { preset in
                    Button {
                        readerConfig.useCustomColors = true
                        readerConfig.customBackgroundHex = preset.backgroundHex
                        readerConfig.customTextHex = preset.textHex
                    } label: {
                        Circle()
                            .fill(Color(hex: preset.backgroundHex) ?? .gray)
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle().stroke(readerConfig.textColor.opacity(0.25), lineWidth: 1)
                            )
                            .overlay(
                                Text("文")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Color(hex: preset.textHex) ?? .black)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if readerConfig.useCustomColors {
                ColorPicker("背景颜色", selection: customBackgroundBinding, supportsOpacity: false)
                    .font(.system(size: 12))
                ColorPicker("文字颜色", selection: customTextBinding, supportsOpacity: false)
                    .font(.system(size: 12))

                HStack(spacing: 8) {
                    Text("预览")
                        .font(.system(size: 12))
                        .foregroundColor(readerConfig.textColor.opacity(0.6))
                    Text("天地玄黄，宇宙洪荒。")
                        .font(.system(size: readerConfig.fontSize))
                        .foregroundColor(readerConfig.textColor)
                        .padding(8)
                        .background(readerConfig.backgroundColor)
                        .cornerRadius(6)
                }
            }
        }
    }

    // MARK: 页眉页脚
    private var headerFooterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionDivider
            sectionTitle("正文标题")

            Picker("正文标题", selection: $readerConfig.titleAlignment) {
                ForEach(ReaderTitleAlignment.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            sectionTitle("页眉页脚")
                .padding(.top, 4)

            Toggle(isOn: $readerConfig.sharedLayout) {
                Text("共享布局")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
            }
            .toggleStyle(.switch)

            HStack(spacing: 8) {
                Text("共享布局开着一套排版给所有书用；关掉后每本书各存一份。")
                    .font(.system(size: 11))
                    .foregroundColor(readerConfig.textColor.opacity(0.5))
                Spacer()
                Button("信息") {
                    showBookInfo = true
                }
                .font(.system(size: 12, weight: .medium))
            }

            Toggle(isOn: $readerConfig.headerEnabled) {
                Text("页眉")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
            }
            .toggleStyle(.switch)
            if readerConfig.headerEnabled {
                settingSlider("距顶", value: $readerConfig.headerOffset, range: 0...160, step: 2)
                Text("这一行离屏幕上沿多远。0 = 贴屏幕上沿（跟灵动岛同高），62 是灵动岛下面，越往上拉越贴顶。")
                    .font(.system(size: 11))
                    .foregroundColor(readerConfig.textColor.opacity(0.5))
                barContentRow("左", selection: $readerConfig.headerLeft)
                barContentRow("中", selection: $readerConfig.headerCenter)
                barContentRow("右", selection: $readerConfig.headerRight)
            }

            Toggle(isOn: $readerConfig.footerEnabled) {
                Text("页脚")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
            }
            .toggleStyle(.switch)
            if readerConfig.footerEnabled {
                settingSlider("距底", value: $readerConfig.footerOffset, range: 0...120, step: 2)
                Text("这一行离屏幕下沿多远。0 = 贴屏幕最下面，34 是 Home 指示条上面。")
                    .font(.system(size: 11))
                    .foregroundColor(readerConfig.textColor.opacity(0.5))
                barContentRow("左", selection: $readerConfig.footerLeft)
                barContentRow("中", selection: $readerConfig.footerCenter)
                barContentRow("右", selection: $readerConfig.footerRight)
            }

            Toggle(isOn: $readerConfig.barDivider) {
                Text("显示分隔线")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
            }
            .toggleStyle(.switch)

            Toggle(isOn: $readerConfig.smartParagraphs) {
                Text("智能分段")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
            }
            .toggleStyle(.switch)
            Text("有的书源把整章塞成一行，中间不带空行。开着就按句末标点把这种长行切开，已经是正常段落的正文不动。")
                .font(.system(size: 11))
                .foregroundColor(readerConfig.textColor.opacity(0.5))

            Toggle(isOn: $readerConfig.punctuationKinsoku) {
                Text("标点禁则")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
            }
            .toggleStyle(.switch)
            Text("按中文的规矩排：句号逗号这类标点不许落在行首，开引号、开括号不许留在行尾。按页翻和连续滚动都管用。")
                .font(.system(size: 11))
                .foregroundColor(readerConfig.textColor.opacity(0.5))

            // 显示项自身的参数：短标题截几个字、自定义日期格式、自定义栏文字
            settingSlider("短标题", value: shortTitleLengthBinding, range: 2...12, step: 1, suffix: " 字")

            HStack(spacing: 8) {
                Text("日期格式")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
                TextField("M月d日", text: $readerConfig.customDatePattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            HStack(spacing: 8) {
                Text("自定义栏")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
                TextField("这一栏要显示的字", text: $readerConfig.customBarText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
    }

    private var shortTitleLengthBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(readerConfig.shortTitleLength) },
            set: { readerConfig.shortTitleLength = Int($0.rounded()) }
        )
    }

    /// 一栏的内容选择：默认收起只显示已选项，点「选择」才展开芯片。
    /// 原来无条件铺开 6 栏 × 24 个芯片（144 个按钮），真机上这一节一渲染就崩。
    private func barContentRow(_ title: String, selection: Binding<[ReaderBarContent]>) -> some View {
        ReaderBarPickerRow(title: title, selection: selection, tint: readerConfig.textColor)
    }

    // MARK: 听书
    private var ttsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionDivider
            sectionTitle("听书")

            HStack(spacing: 8) {
                Text(audioService.currentEngineName)
                    .font(.system(size: 12))
                    .foregroundColor(readerConfig.textColor.opacity(0.75))
                    .lineLimit(1)
                Spacer()
                Button("听书设置") {
                    showTTSSettings = true
                }
                .font(.system(size: 12, weight: .medium))
            }

            settingSlider(
                "语速",
                value: Binding(
                    get: { CGFloat(audioService.speechRate / AVSpeechUtteranceDefaultSpeechRate) },
                    set: { audioService.speechRate = Float($0) * AVSpeechUtteranceDefaultSpeechRate }
                ),
                range: 0.5...2.0,
                step: 0.05,
                suffix: "×"
            )
        }
    }

    private var customBackgroundBinding: Binding<Color> {
        Binding(
            get: { Color(hex: readerConfig.customBackgroundHex) ?? readerConfig.theme.backgroundColor },
            set: { readerConfig.customBackgroundHex = $0.hexString ?? readerConfig.customBackgroundHex }
        )
    }

    private var customTextBinding: Binding<Color> {
        Binding(
            get: { Color(hex: readerConfig.customTextHex) ?? readerConfig.theme.textColor },
            set: { readerConfig.customTextHex = $0.hexString ?? readerConfig.customTextHex }
        )
    }

    private func settingSlider(
        _ title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat,
        suffix: String = " pt"
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(readerConfig.textColor.opacity(0.68))
                .lineLimit(1)
                .frame(width: 48, alignment: .leading)
            Slider(value: Binding(
                get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
                set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
            ), in: range, step: step)
                .tint(settingsAccent)
            Text(settingValueText(value.wrappedValue, step: step, suffix: suffix))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(settingsAccent)
                .frame(width: 52, alignment: .trailing)
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(Capsule().fill(settingsAccent.opacity(0.14)))
        }
        .padding(.vertical, 1)
    }

    private func settingValueText(_ value: CGFloat, step: CGFloat, suffix: String) -> String {
        if step < 1 {
            return String(format: "%.1f%@", Double(value), suffix)
        }
        return "\(safeInt(value))\(suffix)"
    }

    /// 面板里所有 "Int(配置值)" 都走这里：NaN / 无穷大会让 Int() 直接 trap，
    /// 表现就是点开界面立刻回桌面，真机旧配置里出现一个脏值就够触发。
    private func safeInt(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int(value.rounded())
    }

    private var fontSizeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("字号")
                Spacer()
                Text("\(safeInt(readerConfig.fontSize)) pt")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(settingsAccent)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 7)
                    .background(Capsule().fill(settingsAccent.opacity(0.14)))
            }
            HStack(spacing: 12) {
                Text("A-")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(readerConfig.textColor.opacity(0.8))

                Slider(value: Binding(
                    get: { min(max(readerConfig.fontSize, 12), 32) },
                    set: { readerConfig.fontSize = min(max($0, 12), 32) }
                ), in: 12...32, step: 1)
                    .tint(settingsAccent)
                    .onChange(of: readerConfig.fontSize) { _ in
                        recomputePagination()
                    }

                Text("A+")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(readerConfig.textColor.opacity(0.8))
            }
        }
        .onAppear { AppLog.write("[阅读设置] 字号区已渲染") }
    }

    private var reviewStyleName: String {
        switch readerConfig.reviewCardStyle {
        case 1: return "左线卡"
        case 2: return "无框"
        default: return "纸面卡"
        }
    }

    private func reviewChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(selected ? settingsAccent : readerConfig.textColor.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Rectangle().fill(settingsAccent.opacity(selected ? 0.16 : 0.05)))
                .overlay(Rectangle().stroke(settingsAccent.opacity(selected ? 0.6 : 0.16), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    private var reviewCardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 缩略预览：不进二级页也能看到当前效果
            ReviewStylePreview(
                style: reviewCardStyle,
                palette: nierPalette,
                accent: nierPalette.accent,
                pageColor: readerConfig.backgroundColor,
                readerTextColor: readerConfig.textColor,
                baseFontSize: readerConfig.fontSize,
                readerLineSpacing: readerConfig.lineSpacing,
                paragraphSpacing: readerConfig.paragraphSpacing,
                readerFontName: readerConfig.font.postScriptName,
                sample: "热评 · 这条热评会跟着你的设置变化"
            )
            .overlay(Rectangle().stroke(readerConfig.textColor.opacity(0.12), lineWidth: 0.5))
            .clipShape(Rectangle())

            HStack(spacing: 8) {
                Text("字号 \(safeInt(readerConfig.reviewFontScale * 100))% · 内边距 \(safeInt(readerConfig.reviewInset))pt · 不透明 \(safeInt(readerConfig.reviewCardOpacity * 100))% · 位置 \(safeInt(readerConfig.reviewTextDrop))pt")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(readerConfig.textColor.opacity(0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Button {
                    showReviewStyleSheet = true
                } label: {
                    Text("预览调整")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(settingsAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(Rectangle().stroke(settingsAccent.opacity(0.5), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
        .sheet(isPresented: $showReviewStyleSheet) {
            ReviewStyleSheet(config: readerConfig)
        }
    }

    private var themeRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionDivider
            sectionTitle("主题")
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                ForEach(ReaderTheme.allCases) { t in
                    themeButton(for: t)
                }
            }
        }
        .onAppear { AppLog.write("[阅读设置] 主题区已渲染") }
    }

    private func themeButton(for t: ReaderTheme) -> some View {
        let isSelected = (readerConfig.theme == t)
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                readerConfig.theme = t
                // 选主题就回到主题配色，不然自定义色会一直压着主题不放
                readerConfig.useCustomColors = false
            }
        }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(t.backgroundColor)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle()
                            .stroke(readerConfig.textColor.opacity(0.25), lineWidth: 1)
                    )
                Text(t.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                    .fill(isSelected ? settingsAccent.opacity(0.16) : theme.palette.elevated.opacity(effectivePanelLayerOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                    .stroke(isSelected ? settingsAccent : theme.palette.divider, lineWidth: theme.metrics.borderWidth)
            )
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? settingsAccent : readerConfig.textColor)
    }

    // MARK: - Data Loading Pipeline
    private func loadTOCAndStart() async {
        if activeBook.origin == "local" {
            var localChapters = BookStore.shared.getChapters(for: activeBook.bookUrl)
            if !localChapters.isEmpty {
                for i in 0..<localChapters.count {
                    localChapters[i].index = i
                }
                self.chapters = localChapters
                AppLog.write("[阅读] 打开本地书籍，共 \(localChapters.count) 章")
                if currentChapterIndex >= localChapters.count {
                    currentChapterIndex = max(0, localChapters.count - 1)
                }
                loadInitialChapter(at: currentChapterIndex)
                return
            }
        }

        guard let source = effectiveSource else {
            AppLog.write("[阅读] 打开失败：未找到书籍关联书源")
            errorMessage = "未找到书籍关联的书源"
            isLoadingInitial = false
            return
        }

        // 目录在手就先用：网络书的目录以前每次进都要重抓，进书就要等一轮加载。
        // 缓存按「书 + 书源」分开存（换源后的目录是另一份），打开时先用它，
        // 再在后台静默刷新一次，有新章节就更新，不打断阅读。
        let cachedChapters = BookStore.shared.getChapters(for: tocCacheKey(source: source))
        if !cachedChapters.isEmpty {
            var list = cachedChapters
            for i in 0..<list.count { list[i].index = i }
            self.chapters = list
            AppLog.write("[阅读] 复用缓存目录，共 \(list.count) 章")
            if currentChapterIndex >= list.count {
                currentChapterIndex = max(0, list.count - 1)
            }
            loadInitialChapter(at: currentChapterIndex)
            Task { await refreshTOCInBackground(source: source) }
            return
        }

        do {
            self.loadingNote = "正在加载目录..."
            var fetchedChapters = try await BookContentService.shared.fetchChapterList(
                book: activeBook,
                source: source
            ) { fetchedPages, _ in
                Task { @MainActor in
                    self.loadingNote = "正在加载目录…已抓 \(fetchedPages) 页"
                }
            }
            self.loadingNote = "正在加载章节内容..."
            for i in 0..<fetchedChapters.count {
                fetchedChapters[i].index = i
            }
            self.chapters = fetchedChapters
            BookStore.shared.saveChapters(fetchedChapters, for: tocCacheKey(source: source))
            AppLog.write("[阅读] 打开网络书籍，共 \(fetchedChapters.count) 章")
            guard !fetchedChapters.isEmpty else {
                AppLog.write("[阅读] 目录为空 source=\(source.bookSourceName)")
                // 换源之后目录空，说明这个源用不了，直接退回原来的源
                if previousBook != nil {
                    revertSourceSwitch()
                    return
                }
                self.errorMessage = "目录为空：书源的目录规则没有匹配到章节，请检查「\(source.bookSourceName)」的目录规则。"
                self.isLoadingInitial = false
                return
            }
            if currentChapterIndex >= fetchedChapters.count {
                currentChapterIndex = max(0, fetchedChapters.count - 1)
            }
            loadInitialChapter(at: currentChapterIndex)
        } catch {
            AppLog.write("[阅读] 目录解析失败 error=\(error.localizedDescription)")
            if previousBook != nil {
                revertSourceSwitch()
                return
            }
            self.errorMessage = "目录解析失败: \(error.localizedDescription)"
            self.isLoadingInitial = false
        }
    }

    /// 目录缓存键：换源之后目录是另一份，得跟着书源分开存
    private func tocCacheKey(source: BookSource?) -> String {
        let sourceKey = source?.bookSourceUrl ?? ""
        return "\(activeBook.bookUrl)#\(sourceKey)"
    }

    /// 后台静默刷新目录：有新增章节就更新列表并落盘；章数没变就不打扰阅读
    private func refreshTOCInBackground(source: BookSource) async {
        guard let fetched = try? await BookContentService.shared.fetchChapterList(book: activeBook, source: source),
              !fetched.isEmpty else { return }
        var list = fetched
        for i in 0..<list.count { list[i].index = i }
        await MainActor.run {
            BookStore.shared.saveChapters(list, for: tocCacheKey(source: source))
            guard list.count != chapters.count else { return }
            let title = currentLoadedChapter?.chapter.title
            chapters = list
            if let title, let idx = list.firstIndex(where: { $0.title == title }) {
                currentChapterIndex = idx
            } else if currentChapterIndex >= list.count {
                currentChapterIndex = max(0, list.count - 1)
            }
            AppLog.write("[阅读] 后台刷新目录：\(list.count) 章")
        }
    }

    @MainActor
    private func getOrFetchChapter(at index: Int) async -> LoadedChapter? {
        guard index >= 0 && index < chapters.count else { return nil }
        if let cached = chapterCache[index] {
            return cached
        }
        let targetChapter = chapters[index]
        do {
            let content = applyingBookReplaceRules(try await BookContentService.shared.fetchChapterContent(chapter: targetChapter, source: effectiveSource, book: activeBook))
            let blocks = parseContentBlocks(from: content)
            let pages = paginate(blocks: blocks, title: targetChapter.title)
            let loaded = LoadedChapter(chapter: targetChapter, content: content, blocks: blocks, pages: pages)
            self.chapterCache[index] = loaded
            AppLog.write("[阅读] 正文加载完成 第 \(index + 1) 章，\(loaded.blocks.count) 段")
            return loaded
        } catch {
            AppLog.write("[阅读] 正文加载失败 第 \(index + 1) 章 error=\(error.localizedDescription)")
            return nil
        }
    }

    private func preCacheNeighbors(around index: Int) {
        let source = effectiveSource
        // 1. In-memory pre-cache previous chapter
        if index > 0 && chapterCache[index - 1] == nil {
            let prevCh = chapters[index - 1]
            Task { @MainActor in
                if let content = try? await BookContentService.shared.fetchChapterContent(chapter: prevCh, source: source, book: activeBook) {
                    let blocks = parseContentBlocks(from: content)
                    let pages = paginate(blocks: blocks, title: prevCh.title)
                    let loaded = LoadedChapter(chapter: prevCh, content: content, blocks: blocks, pages: pages)
                    self.chapterCache[index - 1] = loaded
                }
            }
        }
        // 2. In-memory pre-cache next chapter
        if index < chapters.count - 1 && chapterCache[index + 1] == nil {
            let nextCh = chapters[index + 1]
            Task { @MainActor in
                if let content = try? await BookContentService.shared.fetchChapterContent(chapter: nextCh, source: source, book: activeBook) {
                    let blocks = parseContentBlocks(from: content)
                    let pages = paginate(blocks: blocks, title: nextCh.title)
                    let loaded = LoadedChapter(chapter: nextCh, content: content, blocks: blocks, pages: pages)
                    self.chapterCache[index + 1] = loaded
                }
            }
        }
        // 3. Disk cache pre-download for 10 chapters around
        BookContentService.shared.preDownloadChapters(around: index, chapters: self.chapters, source: source)
    }

    private func loadInitialChapter(at index: Int, targetPageIndex: Int = 0, scrollToTargetEnd: Bool = false) {
        guard !chapters.isEmpty, index < chapters.count else { return }
        let currentChapter = chapters[index]
        if loadedChapters.isEmpty {
            isLoadingInitial = true
        }
        errorMessage = nil

        let source = effectiveSource

        Task { @MainActor in
            do {
                let loaded: LoadedChapter
                if let cached = self.chapterCache[index] {
                    loaded = cached
                } else {
                    let content = applyingBookReplaceRules(try await BookContentService.shared.fetchChapterContent(chapter: currentChapter, source: source, book: activeBook))
                    let blocks = parseContentBlocks(from: content)
                    let pages = paginate(blocks: blocks, title: currentChapter.title)
                    loaded = LoadedChapter(chapter: currentChapter, content: content, blocks: blocks, pages: pages)
                    self.chapterCache[index] = loaded
                    ReadingStatsStore.shared.addReading(seconds: 0, characters: loaded.content.count, chapters: 1)
                }

                self.currentChapterIndex = index
                // 按页翻的模式不会走滚动那套触发点，不在这里补一次预取的话，
                // 翻到本章最后一页才开始拉下一章，就会卡一下
                self.preCacheNeighbors(around: index)

                // Restore position if durChapterPos is saved and opening the current chapter
                if targetPageIndex == 0 && self.activeBook.durChapterPos > 0 && index == self.activeBook.durChapterIndex {
                    if self.readerConfig.pageMode.isPaged {
                        var accumulated = 0
                        var targetPage = 0
                        for (pIdx, page) in loaded.pages.enumerated() {
                            let pageCount = page.reduce(0) { $0 + $1.text.count }
                            if accumulated + pageCount > self.activeBook.durChapterPos {
                                targetPage = pIdx
                                break
                            }
                            accumulated += pageCount
                            targetPage = pIdx
                        }
                        self.currentPageIndex = min(targetPage, max(0, loaded.pages.count - 1))
                    } else {
                        var accumulated = 0
                        var targetBlock = loaded.blocks.first?.id ?? 0
                        for block in loaded.blocks {
                            if accumulated + block.text.count > self.activeBook.durChapterPos {
                                targetBlock = block.id
                                break
                            }
                            accumulated += block.text.count
                            targetBlock = block.id
                        }
                        self.currentReadingBlockId = targetBlock
                        self.scrollToChapterId = "block_\(index)_\(targetBlock)"
                    }
                } else if targetPageIndex == -1 {
                    self.currentPageIndex = max(0, loaded.pages.count - 1)
                } else {
                    self.currentPageIndex = min(targetPageIndex, max(0, loaded.pages.count - 1))
                }

                if self.currentPageIndex < loaded.pages.count {
                    self.currentReadingBlockId = loaded.pages[self.currentPageIndex].first?.id ?? 0
                }

                // If jumping to end in continuous scroll, also attach the next chapter right below it if available!
                if readerConfig.pageMode == .scroll && scrollToTargetEnd && index < self.chapters.count - 1 {
                    let nextIndex = index + 1
                    if let nextCached = self.chapterCache[nextIndex] {
                        self.loadedChapters = [loaded, nextCached]
                    } else {
                        self.loadedChapters = [loaded]
                        Task {
                            if let nextLoaded = await self.getOrFetchChapter(at: nextIndex) {
                                if !self.loadedChapters.contains(where: { $0.chapter.index == nextIndex }) {
                                    self.loadedChapters.append(nextLoaded)
                                }
                            }
                        }
                    }
                } else {
                    self.loadedChapters = [loaded]
                }

                // 挂起的起读请求：正文到了就念，用户不用再点一次。
                // 期间用户又翻去别章的话（currentChapterIndex 已经不是 index）就别再把他拽回来。
                if let pending = self.pendingReadingStart, pending.chapter == index {
                    self.pendingReadingStart = nil
                    if self.currentChapterIndex == index {
                        AppLog.write("[听书] 挂起的起读唤醒 · 第 \(index + 1) 章 · 可读 \(self.readingItemsForCurrentChapter.count) 段")
                        self.startReadingChapter(fromBlockId: pending.blockId, chapterIndex: index, revealBar: pending.revealBar)
                    } else {
                        AppLog.write("[听书] 挂起的起读作废 · 第 \(index + 1) 章（用户已翻到第 \(self.currentChapterIndex + 1) 章）")
                    }
                }

                self.isLoadingInitial = false
                self.isSwitchingChapter = false
                let currentPos = self.currentChapterCharOffset()
                BookStore.shared.updateProgress(bookUrl: activeBook.bookUrl, chapterIndex: index, chapterTitle: currentChapter.title, chapterPos: currentPos)
                self.preCacheNeighbors(around: index)

                if readerConfig.pageMode == .scroll && self.scrollToChapterId == nil {
                    self.scrollToChapterId = scrollToTargetEnd ? "chapter_end_\(index)" : "chapter_\(index)"
                }
            } catch {
                AppLog.write("[阅读] 首章正文失败 第 \(index + 1) 章 error=\(error.localizedDescription)")
                if self.pendingReadingStart?.chapter == index {
                    self.pendingReadingStart = nil
                    AppLog.write("[听书] 挂起的起读取消 · 第 \(index + 1) 章 正文失败")
                }
                self.errorMessage = "正文解析失败: \(error.localizedDescription)"
                self.isLoadingInitial = false
                self.isSwitchingChapter = false
            }
        }
    }

    private func loadNextChapterForInfiniteScroll(after index: Int) {
        let nextIndex = index + 1
        guard nextIndex < chapters.count else { return }
        if loadedChapters.contains(where: { $0.chapter.index == nextIndex }) || isLoadingNextChapter {
            return
        }

        if let cached = chapterCache[nextIndex] {
            self.loadedChapters.append(cached)
            self.preCacheNeighbors(around: nextIndex)
            return
        }

        let nextChapter = chapters[nextIndex]
        isLoadingNextChapter = true
        let source = effectiveSource

        Task { @MainActor in
            do {
                let content = applyingBookReplaceRules(try await BookContentService.shared.fetchChapterContent(chapter: nextChapter, source: source, book: activeBook))
                let blocks = parseContentBlocks(from: content)
                let pages = paginate(blocks: blocks, title: nextChapter.title)
                let loaded = LoadedChapter(chapter: nextChapter, content: content, blocks: blocks, pages: pages)

                self.loadedChapters.append(loaded)
                self.chapterCache[nextIndex] = loaded
                self.isLoadingNextChapter = false
                self.preCacheNeighbors(around: nextIndex)
            } catch {
                AppLog.write("[ReaderView] ⚠️ 预取章节 \(nextIndex) 失败：\(error)")
                self.isLoadingNextChapter = false
            }
        }
    }

    /// 影响「一页装多少行」的所有设置，凑一个签名用来触发重排
    private var layoutSignature: String {
        [
            "\(readerConfig.fontSize)",
            "\(readerConfig.lineSpacing)",
            "\(readerConfig.letterSpacing)",
            "\(readerConfig.paragraphSpacing)",
            "\(readerConfig.firstLineIndent)",
            "\(readerConfig.reviewFontScale)",
            "\(readerConfig.reviewInset)",
            "\(readerConfig.reviewCardStyle)",
            "\(readerConfig.reviewAlignment)",
            "\(readerConfig.weightLevel)",
            "\(readerConfig.paddingTop)",
            "\(readerConfig.paddingBottom)",
            "\(readerConfig.paddingLeft)",
            "\(readerConfig.paddingRight)",
            readerConfig.font.postScriptName,
            "\(readerConfig.justifyLastPage)",
            "\(readerConfig.headerEnabled)",
            "\(readerConfig.headerGap)",
            "\(readerConfig.footerEnabled)",
            "\(readerConfig.footerGap)",
            "\(readerConfig.headerOffset)",
            "\(readerConfig.footerOffset)",
            "\(readerConfig.chapterTitleScale)",
            readerConfig.titleAlignment.rawValue,
            "\(readerConfig.chapterTopSpacing)",
            "\(readerConfig.chapterTitleSpacing)",
            "\(readerConfig.chapterBottomSpacing)",
            "\(readerConfig.smartParagraphs)",
            readerConfig.chineseConversion.rawValue,
            readerConfig.textAlignment.rawValue,
            readerConfig.pageMode.rawValue
        ].joined(separator: "|")
    }

    private func recomputePagination() {
        AppLog.write("[排版] 触发重排：当前第 \(currentChapterIndex + 1) 章")
        let charPos = currentChapterCharOffset()

        // 分页是按当前排版算出来的，排版一变缓存里的页也是旧的，就地重排（别直接清空，
        // 清空会把下一章的预取一起丢掉，换章就得现拉）
        for (key, cached) in chapterCache {
            var updated = cached
            updated.pages = paginate(blocks: cached.blocks, title: cached.chapter.title)
            chapterCache[key] = updated
        }

        for i in 0..<loadedChapters.count {
            loadedChapters[i].pages = paginate(blocks: loadedChapters[i].blocks, title: loadedChapters[i].chapter.title)
        }

        if let cur = currentLoadedChapter, !cur.pages.isEmpty {
            var accumulated = 0
            var targetPage = 0
            for (pIdx, page) in cur.pages.enumerated() {
                let pageCharCount = page.reduce(0) { $0 + $1.text.count }
                if accumulated + pageCharCount > charPos {
                    targetPage = pIdx
                    break
                }
                accumulated += pageCharCount
                targetPage = pIdx
            }
            currentPageIndex = min(targetPage, max(0, cur.pages.count - 1))
            updateReadingBlockIdFromCurrentPage()
        }
    }

    // MARK: - Paragraph and Page Parser
    /// 智能分段：只处理「特别长、又完全没有段落」的行（不少书源整章塞成一行）。
    /// 按句末标点断句，再把断句拼回正常长度的段落；短行原样返回，不动已经分好段的正文。
    private func smartParagraphSplit(_ line: String) -> [String] {
        guard line.count > 120 else { return [line] }

        var sentences: [String] = []
        var buffer = ""
        for ch in line {
            buffer.append(ch)
            if "。！？…".contains(ch) {
                sentences.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { sentences.append(buffer) }
        guard sentences.count > 1 else { return [line] }

        var paragraphs: [String] = []
        var current = ""
        for sentence in sentences {
            current += sentence
            if current.count >= 100 {
                paragraphs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }

    private func parseContentBlocks(from raw: String) -> [ContentBlock] {
        // 替换净化：全局规则 + 本书规则，正文从这儿进，所以都过一遍
        let text = ReplaceRuleStore.shared.apply(to: raw, bookUrl: activeBook.bookUrl)
        var blocks: [ContentBlock] = []
        var currentId = 0
        let regex = try? NSRegularExpression(pattern: "\\[image:(.*?)\\]")
        let lines = text.components(separatedBy: "\n")

        for line in lines {
            let marked = extractReviewMarkers(from: line)
            let trimmed = marked.line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                attachReviewMarker(marked, from: blocks.count, blocks: &blocks)
                currentId = (blocks.last?.id ?? currentId) + 1
                continue
            }
            let firstBlockIndex = blocks.count

            if let regex = regex {
                let nsLine = trimmed as NSString
                let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: nsLine.length))
                if !matches.isEmpty {
                    var lastIndex = 0
                    for match in matches {
                        if match.range.location > lastIndex {
                            let textBefore = nsLine.substring(with: NSRange(location: lastIndex, length: match.range.location - lastIndex)).trimmingCharacters(in: .whitespaces)
                            if !textBefore.isEmpty {
                                let indent = (textBefore.hasPrefix("　") || textBefore.hasPrefix("    ")) ? "" : "　　"
                                blocks.append(ContentBlock(id: currentId, isImage: false, text: indent + textBefore,
                                                           imageUrl: nil, paragraphId: currentId))
                                currentId += 1
                            }
                        }
                        if match.numberOfRanges > 1 {
                            let imgUrl = nsLine.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                            blocks.append(ContentBlock(id: currentId, isImage: true, text: "", imageUrl: imgUrl))
                            currentId += 1
                        }
                        lastIndex = match.range.location + match.range.length
                    }
                    if lastIndex < nsLine.length {
                        let textAfter = nsLine.substring(with: NSRange(location: lastIndex, length: nsLine.length - lastIndex)).trimmingCharacters(in: .whitespaces)
                        if !textAfter.isEmpty {
                            let indent = (textAfter.hasPrefix("　") || textAfter.hasPrefix("    ")) ? "" : "　　"
                            blocks.append(ContentBlock(id: currentId, isImage: false, text: indent + textAfter,
                                                       imageUrl: nil, paragraphId: currentId))
                            currentId += 1
                        }
                    }
                    attachReviewMarker(marked, from: firstBlockIndex, blocks: &blocks)
                    currentId = (blocks.last?.id ?? currentId) + 1
                    continue
                }
            }

            let paragraphs = readerConfig.smartParagraphs ? smartParagraphSplit(trimmed) : [trimmed]
            for paragraph in paragraphs {
                let indent = (paragraph.hasPrefix("　") || paragraph.hasPrefix("    ")) ? "" : "　　"
                blocks.append(ContentBlock(id: currentId, isImage: false, text: indent + paragraph,
                                           imageUrl: nil, paragraphId: currentId))
                currentId += 1
            }
            attachReviewMarker(marked, from: firstBlockIndex, blocks: &blocks)
            currentId = (blocks.last?.id ?? currentId) + 1
        }
        return blocks
    }

    /// 从一行里拆出段评 / 本章说哨兵，剩下才是正文。
    private func extractReviewMarkers(from line: String)
        -> (line: String, count: Int, url: String?, chapterURL: String?, godReviews: [GodReviewMarker]) {
        guard !AppEdition.isAppStoreClean else {
            return (line, 0, nil, nil, [])
        }
        var text = line
        var count = 0
        var url: String?
        var chapterURL: String?
        var godReviews: [GodReviewMarker] = []

        if let regex = try? NSRegularExpression(pattern: "\u{E000}C\u{1F}(\\d+)\u{1F}([^\u{E001}]*)\u{E001}") {
            let nsText = text as NSString
            if let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) {
                count = Int(nsText.substring(with: match.range(at: 1))) ?? 0
                url = nsText.substring(with: match.range(at: 2))
                text = (text as NSString).replacingCharacters(in: match.range, with: "")
            }
        }
        if let regex = try? NSRegularExpression(pattern: "\u{E000}H\u{1F}([^\u{E001}]*)\u{E001}") {
            let nsText = text as NSString
            if let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) {
                chapterURL = nsText.substring(with: match.range(at: 1))
                text = (text as NSString).replacingCharacters(in: match.range, with: "")
            }
        }
        if let regex = try? NSRegularExpression(pattern: "\u{E000}G\u{1F}([^\u{E001}]*)\u{E001}") {
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                let body = nsText.substring(with: match.range(at: 1))
                let parts = body.components(separatedBy: "\u{1F}")
                let reviewText = decodeMarkerBase64(parts.first ?? "") ?? ""
                let reviewURL = parts.count > 1 ? parts[1] : ""
                let imageURL = parts.count > 2 ? decodeMarkerBase64(parts[2]) : nil
                if !reviewText.isEmpty || imageURL != nil {
                    godReviews.insert(
                        GodReviewMarker(text: reviewText, imageURL: imageURL, url: reviewURL),
                        at: 0
                    )
                }
                text = (text as NSString).replacingCharacters(in: match.range, with: "")
            }
        }
        return (text, count, url, chapterURL, godReviews)
    }

    /// 段评挂在段落最后一块上；本章说单独生成一条入口。
    private func attachReviewMarker(_ marker: (line: String, count: Int, url: String?, chapterURL: String?, godReviews: [GodReviewMarker]),
                                    from firstBlockIndex: Int,
                                    blocks: inout [ContentBlock]) {
        if marker.count > 0, let url = marker.url,
           let index = blocks.indices.last(where: { $0 >= firstBlockIndex && !blocks[$0].isImage }) {
            blocks[index].commentCount = marker.count
            blocks[index].commentURL = url
        }
        if let chapterURL = marker.chapterURL {
            let id = (blocks.last?.id ?? 0) + 1
            blocks.append(ContentBlock(id: id, isImage: false, text: "本章说 · 查看全部评论", imageUrl: nil,
                                       commentCount: -1, commentURL: chapterURL))
        }
        for review in marker.godReviews {
            let id = (blocks.last?.id ?? 0) + 1
            let text = review.text.isEmpty ? "热评" : "热评 · \(review.text)"
            blocks.append(ContentBlock(
                id: id,
                isImage: false,
                text: text,
                imageUrl: review.imageURL,
                commentCount: -2,
                commentURL: review.url.isEmpty ? nil : review.url
            ))
        }
    }

    private func decodeMarkerBase64(_ value: String) -> String? {
        guard !value.isEmpty, let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func currentChapterCharOffset() -> Int {
        guard let cur = currentLoadedChapter else { return 0 }
        if readerConfig.pageMode.isPaged {
            var offset = 0
            let limit = min(currentPageIndex, cur.pages.count)
            for p in 0..<limit {
                for block in cur.pages[p] {
                    offset += block.text.count
                }
            }
            return offset
        } else {
            var offset = 0
            for block in cur.blocks {
                if block.id == currentReadingBlockId {
                    break
                }
                offset += block.text.count
            }
            return offset
        }
    }

    private func saveCurrentProgress() {
        guard let cur = currentLoadedChapter else { return }
        let pos = currentChapterCharOffset()
        BookStore.shared.updateProgress(
            bookUrl: activeBook.bookUrl,
            chapterIndex: currentChapterIndex,
            chapterTitle: cur.chapter.title,
            chapterPos: pos
        )
    }

    /// 一页能放多高（点）：先扣掉页眉页脚和上下边距。
    /// 首页标题占的高度：按可用宽度估算折行行数，分页和渲染共用同一套算法
    private func estimatedTitleHeight(_ title: String) -> CGFloat {
        guard readerConfig.titleAlignment != .hidden else { return 0 }
        let titleFontSize = readerConfig.fontSize * readerConfig.chapterTitleScale
        let width = max(120, readerContainerSize.width - readerConfig.paddingLeft - readerConfig.paddingRight)
        let charsPerLine = max(4, Int(width / (titleFontSize + readerConfig.letterSpacing)))
        let lines = max(1, min(4, Int(ceil(Double(title.count) / Double(charsPerLine)))))
        // 略放宽：估小了最后一行会被页脚裁掉
        return titleFontSize * 1.45 * CGFloat(lines) + 12.0
    }

    /// 返回高度而非行数：段间距占位，按行数算会低估，
    /// 超出预算的部分会压到页脚上。
    private func calculateLayoutMetrics(title: String? = nil) -> (pageHeight: CGFloat, firstPageHeight: CGFloat) {
        let height = max(400, readerContainerSize.height)

        let barHeight: CGFloat = 19
        let reserved = (readerConfig.headerEnabled ? barHeight : 0)
            + (readerConfig.footerEnabled ? barHeight : 0)
            + (readerConfig.headerEnabled ? readerConfig.headerOffset : 0)
            + (readerConfig.footerEnabled ? readerConfig.footerOffset : 0)
            + readerConfig.paddingTop
            + readerConfig.paddingBottom
        let usableHeight = max(200, height - reserved - 2)

        // First page has chapter title (+ title padding)
        let titleHeight = title.map { estimatedTitleHeight($0) } ?? estimatedTitleHeight("第 1 章")
        let firstPageUsableHeight = max(100, usableHeight - titleHeight)

        return (pageHeight: usableHeight, firstPageHeight: firstPageUsableHeight)
    }

    /// 把一段正文切成行。
    ///
    /// 这里必须跟 `CoreTextPageView` 用同一套字体和字距：换字体或把字距调大后，
    /// 按默认苹方、不带字距切出来的行，画的时候会宽于量出来的宽度，整页就溢出/错位。
    /// 热评段用比正文小一号的字，并且左右各留出卡片内边距，
    /// 所以断行必须按「小字号 + 收窄宽度」来算，跟 draw 那边保持同一口径。
    private func splitParagraphIntoLines(
        text: String,
        width: Double,
        fontSizeOverride: CGFloat? = nil,
        horizontalInset: Double = 0,
        suppressFirstLineIndent: Bool = false
    ) -> [(text: String, isParagraphEnd: Bool, charStart: Int)] {
        let fontSize = fontSizeOverride ?? readerConfig.fontSize
        let font = ReaderFontFactory.ctFont(
            postScriptName: readerConfig.font.postScriptName,
            boldPostScriptName: readerConfig.font.boldPostScriptName,
            size: fontSize,
            weightLevel: readerConfig.weightLevel
        )
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTKernAttributeName: readerConfig.letterSpacing
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
            : Double(readerConfig.firstLineIndent.rounded()) * Double(fontSize)
        let textWidth = max(20, width - horizontalInset * 2)
        var isFirstLine = true

        while start < textLen {
            let available = isFirstLine ? max(20, textWidth - indentWidth) : textWidth
            var count = CTTypesetterSuggestLineBreak(typesetter, start, available)
            if count <= 0 { break }
            if readerConfig.punctuationKinsoku {
                count = Self.applyLineBreakRules(nsStr: nsStr, start: start, count: count, textLen: textLen)
            }
            let sub = nsStr.substring(with: NSRange(location: start, length: count))
            let isEnd = (start + count >= textLen)
            result.append((sub, isEnd, start))
            start += count
            isFirstLine = false
        }
        return result
    }

    /// 标点禁则：行首不该出现句读/收尾类标点，行尾不该出现开引号、开括号。
    /// 行首禁则按「标点挤压」处理：把标点拉到上一行，宽度交给两端对齐吸收；
    /// 行尾禁则把该字符挪到下一行。CoreText 不做中文禁则，需要在这里补。
    private static let forbiddenLineStart: Set<unichar> = {
        var set = Set<unichar>()
        for scalar in "。，、；：？！…～·）】》」』〉”’.，;:?!)]}%".unicodeScalars where scalar.value <= 0xFFFF {
            set.insert(unichar(scalar.value))
        }
        return set
    }()

    private static let forbiddenLineEnd: Set<unichar> = {
        var set = Set<unichar>()
        for scalar in "（【《「『〈“‘([{".unicodeScalars where scalar.value <= 0xFFFF {
            set.insert(unichar(scalar.value))
        }
        return set
    }()

    /// 连续模式用的是 SwiftUI / TextKit 的断行，插不进 CoreText 那套禁则。
    /// 这里在「不该被换行切开」的位置插 U+2060（WORD JOINER）：TextKit 认这个字符，
    /// 句读标点就不会被甩到行首，开引号开括号也不会被留在行尾。
    /// 只作用在渲染出来的字符串上，不动 block.text，免得阅读进度和字符偏移跟着漂。
    private func applyingKinsoku(_ text: String) -> String {
        guard readerConfig.punctuationKinsoku else { return text }
        let joiner = "\u{2060}"
        let chars = Array(text)
        guard chars.count > 1 else { return text }

        var out = ""
        out.reserveCapacity(chars.count + 8)
        for (index, ch) in chars.enumerated() {
            out.append(ch)
            guard index + 1 < chars.count else { continue }
            let next = chars[index + 1]
            if Self.isForbiddenLineStart(next) || Self.isForbiddenLineEnd(ch) {
                out += joiner
            }
        }
        return out
    }

    private static func isForbiddenLineStart(_ ch: Character) -> Bool {
        guard let scalar = String(ch).unicodeScalars.first, scalar.value <= 0xFFFF else { return false }
        return forbiddenLineStart.contains(unichar(scalar.value))
    }

    private static func isForbiddenLineEnd(_ ch: Character) -> Bool {
        guard let scalar = String(ch).unicodeScalars.first, scalar.value <= 0xFFFF else { return false }
        return forbiddenLineEnd.contains(unichar(scalar.value))
    }

    private static func applyLineBreakRules(nsStr: NSString, start: Int, count: Int, textLen: Int) -> Int {
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

    private func buildPageBlocks(from lines: [(text: String, isParagraphEnd: Bool, charStart: Int, paragraphId: Int)],
                                 startingId: inout Int) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        for line in lines {
            blocks.append(ContentBlock(
                id: startingId,
                isImage: false,
                text: line.text,
                imageUrl: line.isParagraphEnd ? "p_end" : nil,
                paragraphId: line.paragraphId,
                charStart: line.charStart
            ))
            startingId += 1
        }
        return blocks
    }

    private func paginate(blocks: [ContentBlock], title: String? = nil) -> [[ContentBlock]] {
        let metrics = calculateLayoutMetrics(title: title)
        let normalHeight = metrics.pageHeight
        let firstPageHeight = metrics.firstPageHeight
        let lineHeight = readerConfig.fontSize * 1.25 + readerConfig.lineSpacing
        // 热评卡片：小一号字 + 两侧内边距，跟 CoreTextUIView.draw 的口径一致
        let reviewScale = max(0.5, readerConfig.reviewFontScale)
        let reviewInset = Double(max(0, readerConfig.reviewInset))
        let reviewLineHeight = readerConfig.fontSize * reviewScale * 1.25 + readerConfig.lineSpacing
        // 跟 CoreTextUIView.reviewBands 同一个口径：卡片上下各多出这段留白
        let reviewPad = min(14, max(8, readerConfig.paragraphSpacing + 1))
        // 断行的宽度必须和渲染时用的一致，不然一行排得比页宽，右边就被切掉
        let usableWidth = Double(max(200, readerContainerSize.width - readerConfig.paddingLeft - readerConfig.paddingRight))

        var pages: [[ContentBlock]] = []
        var currentPageLines: [(text: String, isParagraphEnd: Bool, charStart: Int, paragraphId: Int)] = []
        var currentPageHeight: CGFloat = 0
        var maxHeightForCurrentPage = firstPageHeight
        var blockIdCounter = 10000

        for block in blocks {
            if block.isImage {
                if !currentPageLines.isEmpty {
                    pages.append(buildPageBlocks(from: currentPageLines, startingId: &blockIdCounter))
                    currentPageLines = []
                    currentPageHeight = 0
                    maxHeightForCurrentPage = normalHeight
                }
                pages.append([block])
                currentPageHeight = 0
                maxHeightForCurrentPage = normalHeight
            } else {
                let isReviewBlock = block.commentCount == -2
                let pLines = splitParagraphIntoLines(
                    text: block.text,
                    width: usableWidth,
                    fontSizeOverride: isReviewBlock ? readerConfig.fontSize * reviewScale : nil,
                    horizontalInset: isReviewBlock ? reviewInset : 0,
                    suppressFirstLineIndent: isReviewBlock
                )
                // 卡片整块留在同一页，不然框会从中间被页面切断
                if isReviewBlock, !currentPageLines.isEmpty {
                    let spacingBefore: CGFloat = currentPageLines.last?.isParagraphEnd == true
                        ? readerConfig.paragraphSpacing : 0
                    let topExtra: CGFloat = currentPageLines.isEmpty
                        ? 0
                        : max(0, reviewPad - spacingBefore)
                    let bottomExtra = max(0, reviewPad - readerConfig.paragraphSpacing)
                    let blockHeight = spacingBefore
                        + CGFloat(pLines.count) * reviewLineHeight
                        + readerConfig.paragraphSpacing
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
                    // 段间距算在两个段落之间：上一行是段尾时，这一行之前才加间距，
                    // 页面最后一行后面不会白留一截
                    var lineHeightWithSpacing = isReviewBlock ? reviewLineHeight : lineHeight
                    if currentPageLines.last?.isParagraphEnd == true {
                        lineHeightWithSpacing += readerConfig.paragraphSpacing
                    }
                    if !currentPageLines.isEmpty,
                       currentPageHeight + lineHeightWithSpacing > maxHeightForCurrentPage {
                        pages.append(buildPageBlocks(from: currentPageLines, startingId: &blockIdCounter))
                        currentPageLines = []
                        currentPageHeight = 0
                        maxHeightForCurrentPage = normalHeight
                    }
                    currentPageLines.append((lineInfo.text, lineInfo.isParagraphEnd, lineInfo.charStart, block.id))
                    currentPageHeight += lineHeightWithSpacing
                }
            }
        }

        if !currentPageLines.isEmpty {
            pages.append(buildPageBlocks(from: currentPageLines, startingId: &blockIdCounter))
        }

        return pages.isEmpty ? [[]] : pages
    }
}

// MARK: - Chapter Image Component with Anti-Hotlinking Headers & Cache
public struct ChapterImageView: View {
    public let urlString: String
    public let referer: String?

    @State private var imageData: Data? = nil
    @State private var isLoading: Bool = false
    @State private var loadFailed: Bool = false

    private static let imageCache = NSCache<NSString, NSData>()

    public init(urlString: String, referer: String? = nil) {
        self.urlString = urlString
        self.referer = referer
    }

    public var body: some View {
        Group {
            if let data = imageData, let img = platformImage(from: data) {
                img
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(8)
                    .padding(.vertical, 6)
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("加载插图中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
                .padding(.vertical, 6)
            } else if loadFailed {
                Button(action: { Task { await loadImage() } }) {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary)
                        Text("插图加载失败，点击重试")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .task(id: urlString) {
            await loadImage()
        }
    }

    private func loadImage() async {
        var trimmed = ImageSourceNormalizer.normalize(urlString)
        guard !trimmed.isEmpty else { return }

        // 夹了空格/中文的裸地址先补成 URLSession 能吃的形式，否则报 -10。
        if !trimmed.contains("://"), !trimmed.hasPrefix("data:") {
            if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                trimmed = encoded
            }
        }

        // data:image 内联图（聚合源常见）：直接解码，不发网络请求
        if trimmed.hasPrefix("data:image") {
            if let comma = trimmed.firstIndex(of: ",") {
                let meta = String(trimmed[trimmed.startIndex..<comma])
                let payload = String(trimmed[trimmed.index(after: comma)...])
                // 源里的 base64 常带换行和 URL-safe 字符，宽松解码
                if meta.contains("base64"), let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) {
                    if platformImage(from: data) == nil {
                        AppLog.write("[插图] 解码失败 dataURI kind=\(meta.suffix(40)) bytes=\(data.count)")
                    }
                    self.imageData = data
                    self.isLoading = false
                    self.loadFailed = false
                    return
                }
                if let decoded = payload.removingPercentEncoding, let data = decoded.data(using: .utf8) {
                    self.imageData = data
                    self.isLoading = false
                    self.loadFailed = false
                    return
                }
            }
            AppLog.write("[插图] 失败 dataURI kind=\(trimmed.prefix(32))")
            Self.dumpRaw(urlString)
            self.isLoading = false
            self.loadFailed = true
            return
        }

        // 1. Check in-memory cache
        if let cached = Self.imageCache.object(forKey: trimmed as NSString) {
            self.imageData = cached as Data
            self.isLoading = false
            self.loadFailed = false
            return
        }

        // 2. Inline data URI（部分书源把插图直接塞进正文）
        if trimmed.hasPrefix("data:image") {
            if let data = Self.decodeDataURL(trimmed) {
                Self.imageCache.setObject(data as NSData, forKey: trimmed as NSString)
                self.imageData = data
                self.isLoading = false
                self.loadFailed = false
            } else {
                self.loadFailed = true
            }
            return
        }

        // 3. Check local file
        if trimmed.hasPrefix("file://") {
            if let url = URL(string: trimmed), let data = try? Data(contentsOf: url) {
                Self.imageCache.setObject(data as NSData, forKey: trimmed as NSString)
                self.imageData = data
                return
            }
        }

        // 4. Remote URL with proper browser headers
        guard let url = URL(string: trimmed) else {
            self.loadFailed = true
            return
        }

        self.isLoading = true
        self.loadFailed = false

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
            request.setValue("image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

            // 书源的 bookSourceUrl 可能只是「大灰狼融合VIP5.0」这种标识，
            // 不是网址。无效 Referer 比不传更容易被图床拒绝，这里只接受 http(s)。
            if let ref = referer,
               let refURL = URL(string: ref),
               let scheme = refURL.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                request.setValue(ref, forHTTPHeaderField: "Referer")
            } else if let host = url.host, let scheme = url.scheme {
                request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 304), !data.isEmpty {
                if platformImage(from: data) == nil {
                    AppLog.write("[插图] 解码失败 host=\(url.host ?? "-") bytes=\(data.count)")
                }
                Self.imageCache.setObject(data as NSData, forKey: trimmed as NSString)
                await MainActor.run {
                    self.imageData = data
                    self.isLoading = false
                    self.loadFailed = false
                }
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLog.write("[插图] 失败 host=\(url.host ?? "-") status=\(status) bytes=\(data.count)")
                Self.dumpRaw(urlString)
                await MainActor.run {
                    self.isLoading = false
                    self.loadFailed = true
                }
            }
        } catch {
            AppLog.write("[插图] 失败 host=\(url.host ?? "-") error=\(error.localizedDescription)")
            Self.dumpRaw(urlString)
            await MainActor.run {
                self.isLoading = false
                self.loadFailed = true
            }
        }
    }

    // 原始地址落盘排查用：AppLog 会过滤 URL 的 path/query，这里只写本地 Documents
    private static func dumpRaw(_ raw: String) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = dir.appendingPathComponent("hot_review_debug.txt")
        let line = Date().ISO8601Format() + " " + String(raw.prefix(400)) + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    private static func decodeDataURL(_ value: String) -> Data? {
        guard let comma = value.firstIndex(of: ",") else { return nil }
        let header = String(value[value.startIndex..<comma]).lowercased()
        let payload = String(value[value.index(after: comma)...])
        if header.contains(";base64") {
            return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
        }
        guard let decoded = payload.removingPercentEncoding else { return nil }
        return decoded.data(using: .utf8)
    }

    private func platformImage(from data: Data) -> Image? {
        #if canImport(UIKit)
        if let ui = UIImage(data: data) {
            return Image(uiImage: ui)
        }
        #elseif canImport(AppKit)
        if let ns = NSImage(data: data) {
            return Image(nsImage: ns)
        }
        #endif
        return nil
    }
}

// MARK: - Reader Search Sheet
public struct ReaderSearchSheet: View {
    let book: Book
    let currentChapterIndex: Int
    let currentChapterTitle: String
    let currentContent: String
    let chapters: [BookChapter]
    let onSelectChapter: (Int, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var searchScope: Int = 0 // 0: 本章内容, 1: 目录章节

    public struct SearchItem: Identifiable {
        public let id = UUID()
        public let chapterIndex: Int
        public let title: String
        public let snippet: String
    }

    private var currentChapterMatches: [SearchItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var results: [SearchItem] = []
        let lines = currentContent.components(separatedBy: "\n")
        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.localizedCaseInsensitiveContains(query) {
                results.append(SearchItem(
                    chapterIndex: currentChapterIndex,
                    title: "\(currentChapterTitle) (第 \(lineIdx + 1) 段)",
                    snippet: trimmed
                ))
            }
        }
        return results
    }

    private var tocMatches: [SearchItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        return chapters.compactMap { ch in
            if ch.title.localizedCaseInsensitiveContains(query) {
                return SearchItem(
                    chapterIndex: ch.index,
                    title: "第 \(ch.index + 1) 章",
                    snippet: ch.title
                )
            }
            return nil
        }
    }

    private var activeResults: [SearchItem] {
        searchScope == 0 ? currentChapterMatches : tocMatches
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("搜索范围", selection: $searchScope) {
                    Text("当前章节正文").tag(0)
                    Text("目录章节搜索").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if searchText.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text(searchScope == 0 ? "输入关键词搜索当前章节正文" : "输入关键词搜索目录章节")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else if activeResults.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text("没找到包含 “\(searchText)” 的内容")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else {
                    List(activeResults) { item in
                        Button(action: {
                            onSelectChapter(item.chapterIndex, item.snippet)
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.title)
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(item.snippet)
                                    .font(.system(size: 14))
                                    .foregroundColor(.primary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("查找")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $searchText, prompt: searchScope == 0 ? "搜索当前章节内容..." : "搜索章节名称...")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - CoreText Two-End Justified Page View (两端对齐与定高排版组件)
#if os(macOS)
import AppKit

public struct CoreTextPageView: NSViewRepresentable {
    public let lines: [String]
    public let isParagraphEnd: [Bool]
    public let fontSize: CGFloat
    public let lineSpacing: CGFloat
    public let textColor: Color
    public let width: CGFloat
    public let height: CGFloat
    public var letterSpacing: CGFloat = 0
    public var paragraphSpacing: CGFloat = 0
    public var firstLineIndent: CGFloat = 0
    public var weightLevel: Int = 1
    public var chineseConversion: ChineseConversion = .none
    public var fontPostScriptName: String = "PingFangSC-Regular"
    public var boldPostScriptName: String? = "PingFangSC-Semibold"
    public var textAlignment: ReaderTextAlignment = .justify
    public var underlineEnabled: Bool = false
    public var underlineColor: Color? = nil
    public var paragraphSeparatorLines: Int = 0
    public var paragraphSeparatorColor: Color? = nil
    /// 每行属于哪一段（段落级长按选择用），与 lines 一一对应
    public var lineBlockIds: [Int] = []
    public var lineParagraphIds: [Int] = []
    public var lineCharStarts: [Int] = []
    /// 选中的段落（起始块 id + 覆盖块数）
    public var selectedRange: (start: Int, count: Int)? = nil
    public var charSelection: ReaderCharSelection? = nil
    public var charAnnotations: [ReaderCharAnnotation] = []
    /// 已加标注的段落：下划线 / 底色
    public var annotationRanges: [(start: Int, count: Int, style: ReaderBlockStyle)] = []
    /// 长按回调：页内行号 + 该行内的字符偏移（UTF-16）
    public var onLongPressLine: ((Int, Int) -> Void)?
    /// 正在朗读的段（页内序号）和它的底色。macOS 这边不画朗读高亮，
    /// 留着这两项只是为了让 iOS 的调用点能在 macOS 上编过（参数顺序要对齐）。
    public var readingBlockId: Int? = nil
    public var readingTintColor: Color = .clear
    public var commentMap: [Int: (count: Int, url: String)] = [:]
    public var pageBackgroundColor: Color = .clear
    /// 热评段落跟随阅读主题的强调色；普通正文仍用 textColor。
    public var reviewAccentColor: Color? = nil
    /// 热评卡片外观
    public var reviewStyle: ReviewCardStyle = ReviewCardStyle()
    /// 热评块 id → 评论地址；点卡片进热评页
    public var reviewURLs: [Int: String] = [:]
    public var onCommentTap: ((String) -> Void)?

    public func makeNSView(context: Context) -> CoreTextNSView {
        let view = CoreTextNSView()
        updateNSView(view, context: context)
        return view
    }

    public func updateNSView(_ nsView: CoreTextNSView, context: Context) {
        nsView.lines = lines
        nsView.isParagraphEnd = isParagraphEnd
        nsView.fontSize = fontSize
        nsView.lineSpacing = lineSpacing
        nsView.letterSpacing = letterSpacing
        nsView.paragraphSpacing = paragraphSpacing
        nsView.firstLineIndent = firstLineIndent
        nsView.weightLevel = weightLevel
        nsView.chineseConversion = chineseConversion
        nsView.fontPostScriptName = fontPostScriptName
        nsView.boldPostScriptName = boldPostScriptName
        nsView.textAlignment = textAlignment
        nsView.underlineEnabled = underlineEnabled
        nsView.underlineColor = underlineColor.map { NSColor($0) }
        nsView.paragraphSeparatorLines = paragraphSeparatorLines
        nsView.paragraphSeparatorColor = paragraphSeparatorColor.map { NSColor($0) }
        nsView.textColor = NSColor(textColor)
        nsView.containerWidth = width
        nsView.containerHeight = height
        // 只在这页内容真的变了才重绘：翻页拖动时 SwiftUI 每帧都会调进来，
        // 无条件重绘会让整页文字每帧重排一次，翻页就不跟手了
        nsView.renderSignature = nsView.currentSignature()
    }
}

public class CoreTextNSView: NSView {
    public var lines: [String] = []
    public var isParagraphEnd: [Bool] = []
    public var fontSize: CGFloat = 18
    public var lineSpacing: CGFloat = 6
    public var letterSpacing: CGFloat = 0
    public var paragraphSpacing: CGFloat = 0
    public var firstLineIndent: CGFloat = 0
    public var weightLevel: Int = 1
    public var chineseConversion: ChineseConversion = .none
    public var fontPostScriptName: String = "PingFangSC-Regular"
    public var boldPostScriptName: String? = "PingFangSC-Semibold"
    public var textColor: NSColor = .textColor
    public var containerWidth: CGFloat = 340
    public var containerHeight: CGFloat = 600
    public var textAlignment: ReaderTextAlignment = .justify
    public var underlineEnabled: Bool = false
    public var underlineColor: NSColor?
    public var paragraphSeparatorLines: Int = 0
    public var paragraphSeparatorColor: NSColor?

    /// 内容指纹：跟上次一样就不重绘
    public var renderSignature: String = "" {
        didSet {
            if oldValue != renderSignature { needsDisplay = true }
        }
    }

    public func currentSignature() -> String {
        var parts: [String] = [
            "\(lines.count)", "\(fontSize)", "\(lineSpacing)", "\(letterSpacing)",
            "\(paragraphSpacing)", "\(firstLineIndent)", "\(weightLevel)",
            chineseConversion.rawValue, fontPostScriptName, boldPostScriptName ?? "",
            "\(containerWidth)", "\(containerHeight)", textAlignment.rawValue,
            "\(underlineEnabled)", underlineColor?.description ?? "", textColor.description,
            "\(paragraphSeparatorLines)", paragraphSeparatorColor?.description ?? ""
        ]
        parts.append(contentsOf: lines)
        parts.append(isParagraphEnd.map { $0 ? "1" : "0" }.joined())
        return parts.joined(separator: "\u{1}")
    }

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !lines.isEmpty else { return }

        let ctFont = ReaderFontFactory.ctFont(
            postScriptName: fontPostScriptName,
            boldPostScriptName: boldPostScriptName,
            size: fontSize,
            weightLevel: weightLevel
        )
        let effectiveLineHeight = fontSize * 1.25 + lineSpacing
        let targetWidth = Double(max(100, containerWidth))
        var paragraphOffset: CGFloat = 0

        for (index, lineText) in lines.enumerated() {
            guard !lineText.isEmpty else { continue }
            let isParagraphStart = index == 0 || (index - 1 < isParagraphEnd.count && isParagraphEnd[index - 1])
            let convertedText = chineseConversion.apply(lineText)
            let renderedText = isParagraphStart ? String(repeating: "　", count: Int(firstLineIndent.rounded())) + convertedText : convertedText
            var attrs: [CFString: Any] = [
                kCTFontAttributeName: ctFont,
                kCTForegroundColorAttributeName: textColor.cgColor,
                kCTKernAttributeName: letterSpacing
            ]
            if underlineEnabled {
                attrs[kCTUnderlineStyleAttributeName] = CTUnderlineStyle.single.rawValue
                attrs[kCTUnderlineColorAttributeName] = (underlineColor ?? textColor).cgColor
            }
            guard let attrStr = CFAttributedStringCreate(nil, renderedText as CFString, attrs as CFDictionary) else { continue }
            let typesetter = CTTypesetterCreateWithAttributedString(attrStr)
            // 长度必须按 UTF-16 算：emoji 是代理对，用 String.count 会把范围截在半个表情上
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: (renderedText as NSString).length))

            let isEnd = (index < isParagraphEnd.count) ? isParagraphEnd[index] : false
            let finalLine: CTLine
            var penOffset: CGFloat = 0
            if textAlignment == .justify, !isEnd, lineText.count > 5 {
                finalLine = CTLineCreateJustifiedLine(ctLine, 1.0, targetWidth) ?? ctLine
            } else {
                finalLine = ctLine
                // 居中/靠右 CTLine 自己算不出位置，要用 flush 偏移推过去
                switch textAlignment {
                case .center:
                    penOffset = CGFloat(CTLineGetPenOffsetForFlush(ctLine, 0.5, targetWidth))
                case .trailing:
                    penOffset = CGFloat(CTLineGetPenOffsetForFlush(ctLine, 1.0, targetWidth))
                default:
                    break
                }
            }

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(finalLine, &ascent, &descent, &leading)

            let baselineY = CGFloat(index) * effectiveLineHeight + ascent + paragraphOffset

            // macOS 版不做段落级标注（标注绘制在 iOS 的 CoreTextUIView 里）
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: penOffset, y: baselineY)
            ctx.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(finalLine, ctx)
            ctx.restoreGState()

            if isEnd {
                if paragraphSeparatorLines > 0 {
                    let lineColor = paragraphSeparatorColor ?? textColor
                    var sepY = baselineY + descent
                        + max(2, (paragraphSpacing - CGFloat(paragraphSeparatorLines) * 3.5) / 2)
                    ctx.saveGState()
                    ctx.setStrokeColor(lineColor.cgColor)
                    ctx.setLineWidth(0.5)
                    for _ in 0..<paragraphSeparatorLines {
                        ctx.move(to: CGPoint(x: 0, y: sepY))
                        ctx.addLine(to: CGPoint(x: targetWidth, y: sepY))
                        sepY += 3.5
                    }
                    ctx.strokePath()
                    ctx.restoreGState()
                }
                paragraphOffset += paragraphSpacing
            }
        }
    }

}
#endif

#if os(iOS)
extension UIColor {
    /// "#RRGGBB" / "#RRGGBBAA" → UIColor（标注底色用）
    convenience init?(readerHex hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
#endif

/// 替换净化：全局规则对所有书生效，单书规则只对这本书
struct ReplaceRulesView: View {
    let bookUrl: String
    let bookName: String

    @ObservedObject private var store = ReplaceRuleStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ReplaceRule?
    @State private var isNewRule = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(store.rules.filter { $0.isGlobal }) { rule in
                        ruleRow(rule)
                    }
                    .onDelete { delete(global: true, $0) }

                    Button {
                        startNewRule(global: true)
                    } label: {
                        Label("加一条全局规则", systemImage: "plus")
                    }
                } header: {
                    Text("全局规则（所有书都跑）")
                }

                Section {
                    ForEach(store.rules.filter { !$0.isGlobal }) { rule in
                        ruleRow(rule)
                    }
                    .onDelete { delete(global: false, $0) }

                    Button {
                        startNewRule(global: false)
                    } label: {
                        Label("加一条本书规则", systemImage: "plus")
                    }
                } header: {
                    Text("本书规则（\(bookName)）")
                } footer: {
                    Text("按顺序作用于正文。单条正则无效时跳过该条，不影响整章。修改后需重新进入章节或点「刷新」。")
                }
            }
            .appThemedList()
            .navigationTitle("替换净化")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editing) { rule in
                ReplaceRuleEditor(rule: rule, isNew: isNewRule) { saved in
                    if let idx = store.rules.firstIndex(where: { $0.id == saved.id }) {
                        store.rules[idx] = saved
                    } else {
                        store.rules.append(saved)
                    }
                }
            }
        }
    }

    private func ruleRow(_ rule: ReplaceRule) -> some View {
        Button {
            isNewRule = false
            editing = rule
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(rule.name.isEmpty ? "（未命名规则）" : rule.name)
                        .foregroundColor(.primary)
                    Spacer()
                    if !rule.enabled {
                        Text("已停用")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Text("\(rule.isRegex ? "正则" : "文本")：\(rule.pattern) → \(rule.replacement.isEmpty ? "（删除）" : rule.replacement)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func startNewRule(global: Bool) {
        isNewRule = true
        editing = ReplaceRule(bookUrl: global ? nil : bookUrl)
    }

    private func delete(global: Bool, _ indexSet: IndexSet) {
        let scope = store.rules.filter { $0.isGlobal == global }
        let targets = indexSet.compactMap { $0 < scope.count ? scope[$0].id : nil }
        store.rules.removeAll { targets.contains($0.id) }
    }
}

/// 单条净化规则的编辑页，带一个试跑框
struct ReplaceRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReplaceRule
    @State private var sample = ""
    private let isNew: Bool
    private let onSave: (ReplaceRule) -> Void

    init(rule: ReplaceRule, isNew: Bool, onSave: @escaping (ReplaceRule) -> Void) {
        _draft = State(initialValue: rule)
        self.isNew = isNew
        self.onSave = onSave
    }

    private var previewText: String {
        let input = sample.isEmpty ? "示例：第(1)章　　正文里常见的　多余空格与广告" : sample
        return draft.apply(to: input)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("规则")) {
                    TextField("名称（备注用，可留空）", text: $draft.name)
                    TextField("要替换的内容", text: $draft.pattern)
                        .autocorrectionDisabled()
                    TextField("替换成（留空就是删掉）", text: $draft.replacement)
                        .autocorrectionDisabled()
                    Toggle("当成正则表达式", isOn: $draft.isRegex)
                    Toggle("启用这条", isOn: $draft.enabled)
                }

                Section {
                    TextField("贴一行原文试试", text: $sample)
                        .autocorrectionDisabled()
                    Text(previewText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                } header: {
                    Text("试跑")
                } footer: {
                    Text(draft.isGlobal ? "全局规则，作用于所有书籍。" : "仅作用于当前书籍。")
                }
            }
            .navigationTitle(isNew ? "新建净化规则" : "编辑净化规则")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.pattern.isEmpty)
                }
            }
        }
    }
}

#if os(iOS)
import UIKit

public struct CoreTextPageView: UIViewRepresentable {
    public let lines: [String]
    public let isParagraphEnd: [Bool]
    public let fontSize: CGFloat
    public let lineSpacing: CGFloat
    public let textColor: Color
    public let width: CGFloat
    public let height: CGFloat
    public var letterSpacing: CGFloat = 0
    public var paragraphSpacing: CGFloat = 0
    public var firstLineIndent: CGFloat = 0
    public var weightLevel: Int = 1
    public var chineseConversion: ChineseConversion = .none
    public var fontPostScriptName: String = "PingFangSC-Regular"
    public var boldPostScriptName: String? = "PingFangSC-Semibold"
    public var textAlignment: ReaderTextAlignment = .justify
    public var underlineEnabled: Bool = false
    public var underlineColor: Color? = nil
    public var paragraphSeparatorLines: Int = 0
    public var paragraphSeparatorColor: Color? = nil

    /// 每行属于哪一段（段落级长按选择用），与 lines 一一对应
    public var lineBlockIds: [Int] = []
    /// 每行所属原始段落的 id 与段内字符起点（逐字选择用）
    public var lineParagraphIds: [Int] = []
    public var lineCharStarts: [Int] = []
    /// 选中的段落（起始块 id + 覆盖块数）
    public var selectedRange: (start: Int, count: Int)? = nil
    /// 段内逐字选择
    public var charSelection: ReaderCharSelection? = nil
    /// 段内逐字标注
    public var charAnnotations: [ReaderCharAnnotation] = []
    /// 已加标注的段落：下划线 / 底色
    public var annotationRanges: [(start: Int, count: Int, style: ReaderBlockStyle)] = []
    public var onLongPressLine: ((Int, Int) -> Void)?
    /// 正在朗读的段（阅读页高亮跟随，翻页模式也画）
    public var readingBlockId: Int? = nil
    public var readingTintColor: Color? = nil
    public var commentMap: [Int: (count: Int, url: String)] = [:]
    public var pageBackgroundColor: Color = .clear
    /// 热评段落跟随阅读主题的强调色；普通正文仍用 textColor。
    public var reviewAccentColor: Color? = nil
    /// 热评卡片外观
    public var reviewStyle: ReviewCardStyle = ReviewCardStyle()
    /// 热评块 id → 评论地址；点卡片进热评页
    public var reviewURLs: [Int: String] = [:]
    public var onCommentTap: ((String) -> Void)?

    public func makeUIView(context: Context) -> CoreTextUIView {
        let view = CoreTextUIView()
        updateUIView(view, context: context)
        return view
    }

    public func updateUIView(_ uiView: CoreTextUIView, context: Context) {
        uiView.lines = lines
        uiView.isParagraphEnd = isParagraphEnd
        uiView.fontSize = fontSize
        uiView.lineSpacing = lineSpacing
        uiView.letterSpacing = letterSpacing
        uiView.paragraphSpacing = paragraphSpacing
        uiView.firstLineIndent = firstLineIndent
        uiView.weightLevel = weightLevel
        uiView.chineseConversion = chineseConversion
        uiView.fontPostScriptName = fontPostScriptName
        uiView.boldPostScriptName = boldPostScriptName
        uiView.textAlignment = textAlignment
        uiView.underlineEnabled = underlineEnabled
        uiView.underlineColor = underlineColor.map { UIColor($0) }
        uiView.paragraphSeparatorLines = paragraphSeparatorLines
        uiView.paragraphSeparatorColor = paragraphSeparatorColor.map { UIColor($0) }
        uiView.lineBlockIds = lineBlockIds
        uiView.lineParagraphIds = lineParagraphIds
        uiView.lineCharStarts = lineCharStarts
        uiView.selectedRange = selectedRange
        uiView.charSelection = charSelection
        uiView.charAnnotations = charAnnotations
        uiView.annotationRanges = annotationRanges
        uiView.onLongPressLine = onLongPressLine
        if uiView.readingBlockId != readingBlockId {
            AppLog.write("[听书] 分页视图拿到朗读段 \(readingBlockId.map(String.init) ?? "nil")")
        }
        uiView.readingBlockId = readingBlockId
        uiView.readingTintColor = readingTintColor.map { UIColor($0) }
        uiView.commentMap = commentMap
        uiView.bubbleFillColor = UIColor(pageBackgroundColor)
        uiView.reviewAccentColor = reviewAccentColor.map { UIColor($0) }
        uiView.reviewStyle = reviewStyle
        uiView.reviewURLs = reviewURLs
        uiView.onCommentTap = onCommentTap
        uiView.textColor = UIColor(textColor)
        uiView.containerWidth = width
        uiView.containerHeight = height
        uiView.backgroundColor = .clear
        // 同上：内容没变就不重绘
        uiView.renderSignature = uiView.currentSignature()
    }
}

public class CoreTextUIView: UIView {
    /// 一次绘制缓存下来的逐字排版：手柄位置和逐字高亮都从这里查
    struct LineLayout {
        var rect: CGRect
        var boundaries: [CGFloat]
        var paragraphId: Int
        var charStart: Int
    }

    public var lines: [String] = []
    public var isParagraphEnd: [Bool] = []
    /// 每一行属于哪一段（ContentBlock.id）。跟 lines 一一对应，段落级选择靠它命中。
    public var lineBlockIds: [Int] = []
    /// 每行所属原始段落 id 与段内字符起点，逐字选择/标注靠它们定位
    public var lineParagraphIds: [Int] = []
    public var lineCharStarts: [Int] = []
    /// 选中高亮的段落
    public var selectedRange: (start: Int, count: Int)?
    /// 段内逐字选择
    public var charSelection: ReaderCharSelection?
    /// 段内逐字标注
    public var charAnnotations: [ReaderCharAnnotation] = []
    /// 已加标注的段落：下划线 / 底色
    public var annotationRanges: [(start: Int, count: Int, style: ReaderBlockStyle)] = []
    /// 长按命中某一行时回调（页内行号）
    public var onLongPressLine: ((Int, Int) -> Void)?
    /// 正在朗读的段 + 那层底色：翻页模式也要能看出「读到哪」
    public var readingBlockId: Int?
    public var readingTintColor: UIColor?
    /// 只记一次「到底画没画」，验收看日志就够，不用截图
    private var hasLoggedReadingTint = false
    /// 探针预算：查「段落 id 到底怎么编的」，定位完归零
    private var probeBudget = 6
    /// 上一次绘制时记下的行矩形，命中测试用
    private var lineRects: [CGRect] = []
    /// 上一次绘制时记下的逐字边界
    private var lineLayouts: [LineLayout?] = []
    public var fontSize: CGFloat = 18
    public var lineSpacing: CGFloat = 6
    public var letterSpacing: CGFloat = 0
    public var paragraphSpacing: CGFloat = 0
    public var firstLineIndent: CGFloat = 0
    public var weightLevel: Int = 1
    public var chineseConversion: ChineseConversion = .none
    public var fontPostScriptName: String = "PingFangSC-Regular"
    public var boldPostScriptName: String? = "PingFangSC-Semibold"
    public var textColor: UIColor = .label
    public var containerWidth: CGFloat = 340
    public var containerHeight: CGFloat = 600
    public var textAlignment: ReaderTextAlignment = .justify
    public var underlineEnabled: Bool = false
    public var underlineColor: UIColor?
    public var paragraphSeparatorLines: Int = 0
    public var paragraphSeparatorColor: UIColor?
    /// 段落 id → 评论数 / 评论地址；段尾画气泡
    public var commentMap: [Int: (count: Int, url: String)] = [:]
    public var bubbleFillColor: UIColor = .clear
    public var reviewAccentColor: UIColor?
    /// 热评卡片外观（字号/内边距/透明度/样式/对齐/文字色）
    public var reviewStyle: ReviewCardStyle = ReviewCardStyle()
    /// 热评块 id → 评论地址，点卡片直接进对应热评页
    public var reviewURLs: [Int: String] = [:]
    public var onCommentTap: ((String) -> Void)?
    private var commentBubbleRects: [(rect: CGRect, url: String)] = []
    private var reviewCardRects: [(rect: CGRect, url: String)] = []

    public override init(frame: CGRect) {
        super.init(frame: frame)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.3
        press.allowableMovement = 22
        addGestureRecognizer(press)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.3
        press.allowableMovement = 22
        addGestureRecognizer(press)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    /// 点热评卡片 → 进热评页；点段评气泡 → 进段评。其余位置交给翻页手势。
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        if let hit = reviewCardRects.first(where: { $0.rect.contains(point) }) {
            onCommentTap?(hit.url)
            return
        }
        if let hit = commentBubbleRects.first(where: { $0.rect.insetBy(dx: -6, dy: -6).contains(point) }) {
            onCommentTap?(hit.url)
        }
    }

    /// 长按落在哪一行 —— 行矩形是上一次绘制的产物，够用（同一页尺寸不会在两次绘制间变）
    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let point = recognizer.location(in: self)
        guard let index = lineIndex(at: point) else {
            AppLog.write("[长按] 分页模式未命中行 · \(Int(point.x)),\(Int(point.y)) · 行数 \(lines.count)/\(lineRects.count)")
            return
        }
        AppLog.write("[长按] 分页模式命中行 \(index) · block \(index < lineBlockIds.count ? lineBlockIds[index] : -1)")
        onLongPressLine?(index, charOffset(at: point, lineIndex: index))
    }

    /// 命中测试：先找整行矩形，没中再退到最近一行（长按常落在行间空白、行尾或段末）
    private func lineIndex(at point: CGPoint) -> Int? {
        if let exact = lineRects.firstIndex(where: { !$0.isNull && $0.insetBy(dx: -12, dy: -4).contains(point) }) {
            return exact
        }
        let tolerance = (fontSize * 1.25 + lineSpacing) * 1.2
        var best: (index: Int, distance: CGFloat)?
        for (index, rect) in lineRects.enumerated() where !rect.isNull {
            let distance = abs(point.y - rect.midY)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        if let best, best.distance <= tolerance { return best.index }
        return nil
    }

    /// 触点在一行里最接近的字符边界（0...行长度）
    private func charOffset(at point: CGPoint, lineIndex: Int) -> Int {
        guard lineIndex >= 0, lineIndex < lineLayouts.count,
              let layout = lineLayouts[lineIndex], !layout.boundaries.isEmpty else { return 0 }
        var bestOffset = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, x) in layout.boundaries.enumerated() {
            let distance = abs(point.x - x)
            if distance < bestDistance {
                bestDistance = distance
                bestOffset = index
            }
        }
        return bestOffset
    }

    /// 某一行所在整段的矩形（窗口坐标），给操作气泡定位用
    func paragraphWindowRect(atLine line: Int) -> CGRect? {
        guard !lineRects.isEmpty else { return nil }
        var start = min(line, lineRects.count - 1)
        while start > 0, start - 1 < isParagraphEnd.count, !isParagraphEnd[start - 1] { start -= 1 }
        var end = min(line, lineRects.count - 1)
        while end < lineRects.count - 1, end < isParagraphEnd.count, !isParagraphEnd[end] { end += 1 }
        let rects = lineRects[start...end].filter { !$0.isNull }
        guard let first = rects.first, let last = rects.last else { return nil }
        let union = CGRect(x: first.minX, y: first.minY,
                           width: first.width, height: last.maxY - first.minY)
        // to: nil 就是窗口坐标，气泡那层也是整屏铺开的，两边对得上
        return convert(union, to: nil)
    }

    /// 内容指纹：跟上次一样就不重绘
    public var renderSignature: String = "" {
        didSet {
            if oldValue != renderSignature { setNeedsDisplay() }
        }
    }

    // MARK: - 页内长按的外部入口
    //
    // 分页那几套模式整页盖着一层 `DragGesture(minimumDistance: 0)` + 透明的点击层，
    // 触摸根本到不了 UIKit 这个视图，自己挂的识别器收不到。所以长按统一由窗口层
    // 识别器派发进来：先在一张「活动视图表」里找出触点落在哪一页，再走同一套行命中。

    private struct WeakPage {
        weak var view: CoreTextUIView?
    }

    /// 主线程访问（视图注册/注销与长按派发都在主线程）
    @MainActor private static var activePages: [WeakPage] = []

    /// 最近一次长按选中段落的窗口矩形：操作栏要浮在文字旁边，得知道选中的位置
    @MainActor public static var lastSelectionWindowRect: CGRect?

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        MainActor.assumeIsolated {
            CoreTextUIView.activePages.removeAll { $0.view == nil }
            if let index = CoreTextUIView.activePages.firstIndex(where: { $0.view === self }) {
                CoreTextUIView.activePages.remove(at: index)
            }
            if window != nil {
                CoreTextUIView.activePages.append(WeakPage(view: self))
            }
        }
    }

    /// 把窗口坐标交给落在该点的那一页；返回是否有人接手
    @discardableResult
    public static func triggerLongPress(atWindowPoint point: CGPoint) -> Bool {
        guard let index = activePageIndex(atWindowPoint: point),
              let view = activePages[index].view else {
            // 没命中就先把登记表摊开：几页、在哪、可不可见。不然只能猜
            let snapshot = activePages.map { box -> String in
                guard let v = box.view else { return "nil" }
                let f = v.convert(v.bounds, to: nil)
                return "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
                    + "/win=\(v.window != nil ? 1 : 0)/hidden=\(v.isHidden ? 1 : 0)/alpha=\(String(format: "%.2f", v.alpha))"
            }
            AppLog.write("[长按] 登记表 \(activePages.count) 页 · \(snapshot.joined(separator: " | "))")
            return false
        }
        let local = view.convert(point, from: nil)
        guard let line = view.lineIndex(at: local) else {
            AppLog.write("[长按] 分页模式落在页内但没命中行 · 行数 \(view.lines.count)/\(view.lineRects.count)")
            return false
        }
        let blockId = line < view.lineBlockIds.count ? view.lineBlockIds[line] : -1
        AppLog.write("[长按] 分页模式命中行 \(line) · block \(blockId)")
        // 段落矩形：同一段的首行到末行并起来，再换算到窗口坐标
        CoreTextUIView.lastSelectionWindowRect = view.paragraphWindowRect(atLine: line)
        view.onLongPressLine?(line, view.charOffset(at: local, lineIndex: line))
        return true
    }

    /// 分页页面上点段评气泡：命中后打开该段评论。
    @discardableResult
    public static func triggerCommentTap(atWindowPoint point: CGPoint) -> Bool {
        let candidates = activePages.compactMap(\.view).filter { $0.window != nil && !$0.isHidden && $0.alpha > 0.01 }
        // 翻页动画时可能同时有两页；逐页找，别只命中最上面那一页
        for view in candidates {
            let local = view.convert(point, from: nil)
            guard view.bounds.contains(local) else { continue }
            // 气泡贴在行尾，横向坐标受分页留白影响；按实际矩形外扩一圈命中
            let hit = view.commentBubbleRects
                .filter { $0.rect.insetBy(dx: -14, dy: -10).contains(local) }
                .min { abs(local.y - $0.rect.midY) < abs(local.y - $1.rect.midY) }
            if let hit {
                view.onCommentTap?(hit.url)
                return true
            }
        }
        return false
    }

    /// 听书时点正文：窗口坐标 → 落在哪一段。问不到就返回 nil，调用方什么都不做。
    /// 注意返回的是段落 id（lineParagraphIds），不是行级伪 block（lineBlockIds，10000 起）——
    /// 听书队列按章节里真正的 ContentBlock.id 建，拿行 id 去查会查空，点段起读就静默不动。
    public static func readingBlockId(atWindowPoint point: CGPoint) -> Int? {
        guard let index = activePageIndex(atWindowPoint: point),
              let view = activePages[index].view else { return nil }
        let local = view.convert(point, from: nil)
        guard let line = view.lineIndex(at: local) else { return nil }
        if line < view.lineParagraphIds.count { return view.lineParagraphIds[line] }
        return line < view.lineBlockIds.count ? view.lineBlockIds[line] : nil
    }

    /// 验收用：把在屏上的页逐行打出来（行号 / pid / 行 block / 前六个字）
    public static func debugDumpVisiblePages() -> String {
        let views = activePages.compactMap(\.view).filter { $0.window != nil && !$0.isHidden && $0.alpha > 0.01 }
        guard !views.isEmpty else { return "无在屏页" }
        return views.map { view in
            let head = "帧\(Int(view.frame.minX)),\(Int(view.frame.minY)) \(Int(view.bounds.width))x\(Int(view.bounds.height))"
            let rows = (0..<min(8, view.lines.count)).map { i -> String in
                let pid = i < view.lineParagraphIds.count ? view.lineParagraphIds[i] : -9
                let bid = i < view.lineBlockIds.count ? view.lineBlockIds[i] : -9
                return "行\(i)[pid\(pid) bid\(bid) \(view.lines[i].prefix(6))]"
            }
            return head + " " + rows.joined(separator: " ")
        }.joined(separator: " || ")
    }

    /// 触点落在哪一页：可见、且局部坐标在页内；多页重叠时取面积最小的
    private static func activePageIndex(atWindowPoint point: CGPoint) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, box) in activePages.enumerated() {
            guard let view = box.view, view.window != nil, !view.isHidden, view.alpha > 0.01 else { continue }
            let local = view.convert(point, from: nil)
            guard view.bounds.contains(local) else { continue }
            let area = view.bounds.width * view.bounds.height
            if best == nil || area < best!.area { best = (index, area) }
        }
        return best?.index
    }

    public func currentSignature() -> String {
        var parts: [String] = [
            "\(lines.count)", "\(fontSize)", "\(lineSpacing)", "\(letterSpacing)",
            "\(paragraphSpacing)", "\(firstLineIndent)", "\(weightLevel)",
            chineseConversion.rawValue, fontPostScriptName, boldPostScriptName ?? "",
            "\(containerWidth)", "\(containerHeight)", textAlignment.rawValue,
            "\(underlineEnabled)", underlineColor?.description ?? "", textColor.description,
            reviewAccentColor?.description ?? "",
            "\(reviewStyle.fontScale)|\(reviewStyle.inset)|\(reviewStyle.opacity)|\(reviewStyle.style)|\(reviewStyle.alignment)|\(reviewStyle.textColorMode)",
            reviewURLs.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","),
            "\(paragraphSeparatorLines)", paragraphSeparatorColor?.description ?? ""
        ]
        parts.append(contentsOf: lines)
        parts.append(isParagraphEnd.map { $0 ? "1" : "0" }.joined())
        parts.append(lineBlockIds.map(String.init).joined(separator: ","))
        parts.append(lineParagraphIds.map(String.init).joined(separator: ","))
        parts.append(lineCharStarts.map(String.init).joined(separator: ","))
        parts.append(selectedRange.map { "\($0.start)-\($0.count)" } ?? "")
        parts.append(charSelection.map { "c\($0.paragraphId):\($0.start)+\($0.length)" } ?? "")
        parts.append(charAnnotations.map {
            "\($0.paragraphId):\($0.start)+\($0.length):\($0.style.underline ? "u\($0.style.underlineHex ?? "")" : "")\($0.style.highlightHex ?? "")"
        }.joined(separator: ","))
        parts.append(annotationRanges.map {
            "\($0.start)+\($0.count):\($0.style.underline ? "u\($0.style.underlineHex ?? "")" : "")\($0.style.highlightHex ?? "")"
        }.joined(separator: ","))
        parts.append("read:\(readingBlockId.map(String.init) ?? "-"):\(readingTintColor?.description ?? "-")")
        return parts.joined(separator: "\u{1}")
    }

    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !lines.isEmpty else { return }
        commentBubbleRects.removeAll(keepingCapacity: true)

        // 行矩形是长按命中的唯一依据，每画一次就重记一次
        var rects = [CGRect](repeating: .null, count: lines.count)
        defer { lineRects = rects }
        var layouts = [LineLayout?](repeating: nil, count: lines.count)
        defer { lineLayouts = layouts }

        let ctFont = ReaderFontFactory.ctFont(
            postScriptName: fontPostScriptName,
            boldPostScriptName: boldPostScriptName,
            size: fontSize,
            weightLevel: weightLevel
        )
        let effectiveLineHeight = fontSize * 1.25 + lineSpacing
        // 热评卡片排版：小一号字、更矮的行高、左右留内边距
        let reviewScale = max(0.5, reviewStyle.fontScale)
        let reviewInset = max(0, reviewStyle.inset)
        let reviewLineHeight = fontSize * reviewScale * 1.25 + lineSpacing
        let reviewFont = ReaderFontFactory.ctFont(
            postScriptName: fontPostScriptName,
            boldPostScriptName: boldPostScriptName,
            size: fontSize * reviewScale,
            weightLevel: weightLevel
        )
        let targetWidth = Double(max(100, containerWidth))

        // 热评段的段落 id：首行带「热评 · / 神评 · 」前缀；跨页后的续行没有前缀，
        // 只能靠 reviewURLs 里的块 id 认回来，否则第二页会掉回正文样式。
        var reviewParagraphIds = Set<Int>()
        for paragraphId in lineParagraphIds where reviewURLs[paragraphId] != nil {
            reviewParagraphIds.insert(paragraphId)
        }
        for (index, lineText) in lines.enumerated()
        where lineText.hasPrefix("热评 · ") || lineText.hasPrefix("神评 · ") {
            if index < lineParagraphIds.count { reviewParagraphIds.insert(lineParagraphIds[index]) }
        }

        // 每行的顶部 y 与行高。热评行更矮，所以不能再用 index * 行高。
        var lineTops = [CGFloat](repeating: 0, count: lines.count)
        var lineHeights = [CGFloat](repeating: effectiveLineHeight, count: lines.count)
        var cursor: CGFloat = 0
        for index in lines.indices {
            let paragraphId = index < lineParagraphIds.count ? lineParagraphIds[index] : -1
            let isReview = reviewParagraphIds.contains(paragraphId)
            lineTops[index] = cursor
            lineHeights[index] = isReview ? reviewLineHeight : effectiveLineHeight
            cursor += lineHeights[index]
            if index < isParagraphEnd.count, isParagraphEnd[index] {
                cursor += paragraphSpacing
            }
        }

        var pageR: CGFloat = 0, pageG: CGFloat = 0, pageB: CGFloat = 0, pageA: CGFloat = 0
        bubbleFillColor.getRed(&pageR, green: &pageG, blue: &pageB, alpha: &pageA)
        let isDarkPage = (0.299 * pageR + 0.587 * pageG + 0.114 * pageB) < 0.5
        let paper = isDarkPage
            ? UIColor(red: 0.137, green: 0.141, blue: 0.129, alpha: 1)
            : UIColor(red: 0.949, green: 0.925, blue: 0.871, alpha: 1)
        let nierInk = isDarkPage
            ? UIColor(red: 0.914, green: 0.882, blue: 0.824, alpha: 1)
            : UIColor(red: 0.118, green: 0.114, blue: 0.102, alpha: 1)
        let nierLine = isDarkPage
            ? UIColor(red: 0.290, green: 0.282, blue: 0.255, alpha: 1)
            : UIColor(red: 0.725, green: 0.682, blue: 0.608, alpha: 1)

        // 热评段先铺一层尼尔风格的纸面卡片：方角、细描边、左上角氧化色角标。
        // 卡片跟着正文一起分页，不再单独占一页。
        reviewCardRects.removeAll(keepingCapacity: true)
        for item in reviewBands(lineTops: lineTops, lineHeights: lineHeights, targetWidth: CGFloat(targetWidth)) {
            guard let accent = reviewAccentColor else { continue }
            let band = item.rect
            if let url = reviewURLs[item.block], !url.isEmpty {
                reviewCardRects.append((band, url))
            }
            ctx.saveGState()
            let op = max(0.05, min(1, reviewStyle.opacity))
            switch reviewStyle.style {
            case 1:
                // 左线卡：只保留底色和一根氧化色导轨
                ctx.setFillColor(paper.withAlphaComponent(0.55 * op).cgColor)
                ctx.fill(band)
                ctx.setFillColor(accent.withAlphaComponent(op).cgColor)
                ctx.fill(CGRect(x: band.minX, y: band.minY + 2,
                                width: 3, height: max(6, band.height - 4)))
            case 2:
                // 无框：一层淡底，靠字号和颜色跟正文区分
                ctx.setFillColor(accent.withAlphaComponent(0.09 * op).cgColor)
                ctx.fill(band)
            default:
                // 纸面卡：纸底 + 双线 + 四角折角标
                ctx.setFillColor(paper.cgColor)
                ctx.fill(band)
                ctx.setFillColor(bubbleFillColor.withAlphaComponent((isDarkPage ? 0.12 : 0.18) * op).cgColor)
                ctx.fill(band)
                ctx.setFillColor(accent.withAlphaComponent((isDarkPage ? 0.06 : 0.04) * op).cgColor)
                ctx.fill(band)
                // 细扫描线，只在纸面上压一层很淡的终端质感
                ctx.setStrokeColor(nierLine.withAlphaComponent((isDarkPage ? 0.14 : 0.10) * op).cgColor)
                ctx.setLineWidth(0.5)
                var scanY = band.minY + 4
                while scanY < band.maxY {
                    ctx.move(to: CGPoint(x: band.minX + 1, y: scanY))
                    ctx.addLine(to: CGPoint(x: band.maxX - 1, y: scanY))
                    scanY += 4
                }
                ctx.strokePath()
                // 外框
                ctx.setStrokeColor(nierLine.withAlphaComponent(op).cgColor)
                ctx.setLineWidth(0.8)
                ctx.stroke(band)
                // 左侧氧化色导轨：字有内边距了，这条竖线不会压到正文
                ctx.setFillColor(accent.cgColor)
                ctx.fill(CGRect(x: band.minX + 4.5, y: band.minY + 9,
                                width: 2, height: max(6, band.height - 18)))
                // 内侧两道细横线：竖向留给左侧导轨，不然线和线挤在一起
                ctx.setStrokeColor(accent.withAlphaComponent((isDarkPage ? 0.34 : 0.26) * op).cgColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: band.minX + 3.5, y: band.minY + 3.5))
                ctx.addLine(to: CGPoint(x: band.maxX - 3.5, y: band.minY + 3.5))
                ctx.move(to: CGPoint(x: band.minX + 3.5, y: band.maxY - 3.5))
                ctx.addLine(to: CGPoint(x: band.maxX - 3.5, y: band.maxY - 3.5))
                ctx.strokePath()
                // 四角折角标，比纯边框更像仪器面板
                ctx.setFillColor(accent.cgColor)
                let arm: CGFloat = 11
                let thick: CGFloat = 1.6
                ctx.fill(CGRect(x: band.minX, y: band.minY, width: arm, height: thick))
                ctx.fill(CGRect(x: band.minX, y: band.minY, width: thick, height: arm))
                ctx.fill(CGRect(x: band.maxX - arm, y: band.minY, width: arm, height: thick))
                ctx.fill(CGRect(x: band.maxX - thick, y: band.minY, width: thick, height: arm))
                ctx.fill(CGRect(x: band.minX, y: band.maxY - thick, width: arm, height: thick))
                ctx.fill(CGRect(x: band.minX, y: band.maxY - arm, width: thick, height: arm))
                ctx.fill(CGRect(x: band.maxX - arm, y: band.maxY - thick, width: arm, height: thick))
                ctx.fill(CGRect(x: band.maxX - thick, y: band.maxY - arm, width: thick, height: arm))
            }
            ctx.restoreGState()
        }

        for (index, lineText) in lines.enumerated() {
            guard !lineText.isEmpty else { continue }
            let isParagraphStart = index == 0 || (index - 1 < isParagraphEnd.count && isParagraphEnd[index - 1])
            let lineParagraphId = index < lineParagraphIds.count ? lineParagraphIds[index] : -1
            // 段落 id 之外的兜底：真实章节里热评块可能没有评论地址，id 也可能跨页漂掉，
            // 首行前缀是最后的锚点，认不出来就会退回正文样式（字号、对齐全丢）。
            let isReviewLine = reviewParagraphIds.contains(lineParagraphId)
                || lineText.hasPrefix("热评 · ")
                || lineText.hasPrefix("神评 · ")
            let lineTextColor: UIColor
            if isReviewLine {
                switch reviewStyle.textColorMode {
                case 1: lineTextColor = reviewAccentColor ?? nierInk
                case 2: lineTextColor = textColor
                default: lineTextColor = nierInk
                }
            } else {
                lineTextColor = textColor
            }
            let lineFont = isReviewLine ? reviewFont : ctFont
            let lineInset = isReviewLine ? reviewInset : 0
            let lineTargetWidth = max(40, CGFloat(targetWidth) - lineInset * 2)
            let convertedText = chineseConversion.apply(lineText)
            let renderedText = isParagraphStart ? String(repeating: "　", count: Int(firstLineIndent.rounded())) + convertedText : convertedText
            var attrs: [CFString: Any] = [
                kCTFontAttributeName: lineFont,
                kCTForegroundColorAttributeName: lineTextColor.cgColor,
                kCTKernAttributeName: letterSpacing
            ]
            if underlineEnabled {
                attrs[kCTUnderlineStyleAttributeName] = CTUnderlineStyle.single.rawValue
                attrs[kCTUnderlineColorAttributeName] = (underlineColor ?? lineTextColor).cgColor
            }
            guard let attrStr = CFAttributedStringCreateMutable(nil, 0) else { continue }
            CFAttributedStringReplaceString(attrStr, CFRange(location: 0, length: 0), renderedText as CFString)
            let renderedLength = (renderedText as NSString).length
            CFAttributedStringSetAttributes(attrStr, CFRange(location: 0, length: renderedLength), attrs as CFDictionary, false)
            if isReviewLine, let accent = reviewAccentColor {
                let prefix = lineText.hasPrefix("神评 · ") ? "神评 · " : "热评 · "
                let prefixRange = (renderedText as NSString).range(of: prefix)
                if prefixRange.location != NSNotFound {
                    CFAttributedStringSetAttribute(
                        attrStr,
                        CFRange(location: prefixRange.location, length: prefixRange.length),
                        kCTForegroundColorAttributeName,
                        accent.cgColor
                    )
                }
            }
            let typesetter = CTTypesetterCreateWithAttributedString(attrStr)
            // 长度必须按 UTF-16 算：emoji 是代理对，用 String.count 会把范围截在半个表情上
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: (renderedText as NSString).length))

            let isEnd = (index < isParagraphEnd.count) ? isParagraphEnd[index] : false
            // 热评卡片的对齐只认自己的设置；正文继续跟全局对齐走。
            let effectiveAlignment: ReaderTextAlignment = isReviewLine
                ? (reviewStyle.alignment == 1 ? .center : .leading)
                : textAlignment
            let alignWidth: CGFloat = isReviewLine ? lineTargetWidth : CGFloat(targetWidth)
            let finalLine: CTLine
            var penOffset: CGFloat = 0
            if effectiveAlignment == .justify, !isEnd, lineText.count > 5 {
                finalLine = CTLineCreateJustifiedLine(ctLine, 1.0, alignWidth) ?? ctLine
            } else {
                finalLine = ctLine
                // 居中/靠右 CTLine 自己算不出位置，要用 flush 偏移推过去
                switch effectiveAlignment {
                case .center:
                    penOffset = CGFloat(CTLineGetPenOffsetForFlush(ctLine, 0.5, alignWidth))
                case .trailing:
                    penOffset = CGFloat(CTLineGetPenOffsetForFlush(ctLine, 1.0, alignWidth))
                default:
                    break
                }
            }

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(finalLine, &ascent, &descent, &leading)

            // 热评行的字面高度比行框矮，行框又上下各留了 pad，字看起来会偏上。
            // 基线下压由「文字位置」控制（默认 2.5pt），行框本身不动，分页不受影响。
            let reviewDrop: CGFloat = isReviewLine ? reviewStyle.textDrop : 0
            let baselineY = lineTops[index] + ascent + reviewDrop

            // 标注与选中：段落级底色 / 下划线，选中时再叠一层淡蓝
            let blockId = index < lineBlockIds.count ? lineBlockIds[index] : -1
            let lineRect = CGRect(x: lineInset, y: baselineY - ascent,
                                  width: lineTargetWidth, height: ascent + descent)
            rects[index] = lineRect

            // 逐字边界：CTLine 的字符偏移加上行本身的对齐位移
            let lineUnits = (lineText as NSString).length
            let convUnits = (convertedText as NSString).length
            let indentUnits = (renderedText as NSString).length - convUnits
            var boundaries: [CGFloat] = []
            boundaries.reserveCapacity(lineUnits + 1)
            for unit in 0...lineUnits {
                let mapped = lineUnits > 0
                    ? Int((Double(unit) * Double(convUnits) / Double(lineUnits)).rounded())
                    : 0
                let renderedIndex = min(convUnits, max(0, mapped)) + indentUnits
                let x = CGFloat(CTLineGetOffsetForStringIndex(finalLine, renderedIndex, nil))
                boundaries.append(x + penOffset + lineInset)
            }
            let paragraphId = index < lineParagraphIds.count ? lineParagraphIds[index] : -1
            let charStart = index < lineCharStarts.count ? lineCharStarts[index] : 0
            let layout = LineLayout(rect: lineRect,
                                    boundaries: boundaries,
                                    paragraphId: paragraphId,
                                    charStart: charStart)
            layouts[index] = layout

            let style = annotationRanges.first { blockId >= $0.start && blockId < $0.start + max(1, $0.count) }?.style
            // 朗读中的段落：先铺一层淡强调色，用户的标注再压在上面。
            // 分页模式的行是重新编号过的段落（10000 起），原文段 id 在 paragraphId 里，两个都要比。
            if let readingBlockId, probeBudget > 0 {
                probeBudget -= 1
                AppLog.write("[听书] 探针 · 朗读 \(readingBlockId) · block \(blockId) · pid \(paragraphId) · 行 \(index) · 底色 \(readingTintColor == nil ? "nil" : "有")")
            }
            if let readingBlockId, blockId == readingBlockId || paragraphId == readingBlockId,
               let tint = readingTintColor {
                ctx.saveGState()
                ctx.setFillColor(tint.cgColor)
                // 只涂本行真正有字的那一段：行首缩进、行尾对齐留白都露纸色
                let span = glyphSpanX(layout: layout, text: index < lines.count ? lines[index] : "")
                if let (x1, x2) = span {
                    ctx.fill(CGRect(x: x1, y: lineRect.minY, width: x2 - x1, height: lineRect.height))
                }
                ctx.restoreGState()
                if !hasLoggedReadingTint || probeBudget > 0 {
                    hasLoggedReadingTint = true
                    let spanText = span.map { "\(Int($0.0))..\(Int($0.1)) 宽\(Int($0.1 - $0.0))" } ?? "无字"
                    var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
                    _ = tint.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
                    let rgba = "\(Int(tr * 255)),\(Int(tg * 255)),\(Int(tb * 255)) a\(String(format: "%.2f", ta))"
                    AppLog.write("[听书] 绘到朗读底色 · 原文段 \(readingBlockId) · 行 \(index) y\(Int(lineRect.minY))..\(Int(lineRect.maxY)) x\(spanText) 行框\(Int(lineRect.minX))..\(Int(lineRect.maxX)) 色\(rgba) 视图\(Int(bounds.width))x\(Int(bounds.height)) 上窗\(window != nil ? 1 : 0)")
                }
            }
            if blockId >= 0, let style {
                if let hex = style.highlightHex, let color = UIColor(readerHex: hex) {
                    ctx.saveGState()
                    ctx.setFillColor(color.cgColor)
                    ctx.fill(lineRect)
                    ctx.restoreGState()
                }
                if style.underline {
                    ctx.saveGState()
                    let lineColor = UIColor(readerHex: style.underlineHex ?? "#2F7BF6")
                        ?? UIColor.systemBlue
                    ctx.setStrokeColor(lineColor.withAlphaComponent(0.9).cgColor)
                    ctx.setLineWidth(1.5)
                    let underlineY = baselineY + descent + 1
                    ctx.move(to: CGPoint(x: 0, y: underlineY))
                    ctx.addLine(to: CGPoint(x: lineRect.width, y: underlineY))
                    ctx.strokePath()
                    ctx.restoreGState()
                }
            }
            if charSelection == nil,
               let range = selectedRange, blockId >= range.start, blockId < range.start + max(1, range.count) {
                ctx.saveGState()
                ctx.setFillColor(UIColor.systemBlue.withAlphaComponent(0.18).cgColor)
                ctx.fill(lineRect)
                ctx.restoreGState()
            }

            // 段内逐字标注：只铺选中的那几个字
            if paragraphId >= 0 {
                for item in charAnnotations where item.paragraphId == paragraphId {
                    let rangeStart = item.start
                    let rangeEnd = item.start + max(1, item.length)
                    if let hex = item.style.highlightHex, let color = UIColor(readerHex: hex) {
                        fillCharRange(ctx, layout: layout, start: rangeStart, end: rangeEnd, color: color)
                    }
                    if item.style.underline {
                        underlineCharRange(ctx, layout: layout, start: rangeStart, end: rangeEnd,
                                           hex: item.style.underlineHex)
                    }
                }
                if let sel = charSelection, sel.paragraphId == paragraphId {
                    fillCharRange(ctx,
                                  layout: layout,
                                  start: sel.start,
                                  end: sel.start + max(1, sel.length),
                                  color: UIColor.systemBlue.withAlphaComponent(0.22))
                }
            }

            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: penOffset + lineInset, y: baselineY)
            ctx.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(finalLine, ctx)
            ctx.restoreGState()

            if isEnd, let info = commentMap[paragraphId] {
                let label = info.count >= 99 ? "99+" : "\(info.count)"
                let bodyWidth: CGFloat = label.count > 2 ? 24 : 16
                let bubbleWidth = bodyWidth + 6
                let bubbleHeight: CGFloat = 21
                let endX = boundaries.last ?? 0
                var originX = endX + 5
                if originX + bubbleWidth > CGFloat(targetWidth) {
                    originX = max(0, CGFloat(targetWidth) - bubbleWidth)
                }
                let originY = baselineY - ascent + ((ascent + descent) - bubbleHeight) / 2
                let bodyRect = CGRect(x: originX + 6, y: originY,
                                      width: bodyWidth, height: bubbleHeight)
                let path = UIBezierPath(roundedRect: bodyRect, cornerRadius: 5)
                let midY = originY + bubbleHeight / 2
                path.move(to: CGPoint(x: originX + 6, y: midY - 5))
                path.addLine(to: CGPoint(x: originX, y: midY))
                path.addLine(to: CGPoint(x: originX + 6, y: midY + 5))
                path.close()
                ctx.saveGState()
                ctx.setFillColor(bubbleFillColor.cgColor)
                ctx.addPath(path.cgPath)
                ctx.fillPath()
                ctx.setStrokeColor(textColor.withAlphaComponent(0.45).cgColor)
                ctx.setLineWidth(1)
                ctx.addPath(path.cgPath)
                ctx.strokePath()
                let attr: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: textColor
                ]
                let textSize = (label as NSString).size(withAttributes: attr)
                (label as NSString).draw(
                    at: CGPoint(x: bodyRect.midX - textSize.width / 2,
                                y: bodyRect.midY - textSize.height / 2),
                    withAttributes: attr
                )
                ctx.restoreGState()
                commentBubbleRects.append((
                    CGRect(x: originX, y: originY, width: bubbleWidth, height: bubbleHeight),
                    info.url
                ))
            }

            if isEnd {
                if paragraphSeparatorLines > 0 {
                    let lineColor = paragraphSeparatorColor ?? textColor
                    var sepY = baselineY + descent
                        + max(2, (paragraphSpacing - CGFloat(paragraphSeparatorLines) * 3.5) / 2)
                    ctx.saveGState()
                    ctx.setStrokeColor(lineColor.cgColor)
                    ctx.setLineWidth(0.5)
                    for _ in 0..<paragraphSeparatorLines {
                        ctx.move(to: CGPoint(x: 0, y: sepY))
                        ctx.addLine(to: CGPoint(x: targetWidth, y: sepY))
                        sepY += 3.5
                    }
                    ctx.strokePath()
                    ctx.restoreGState()
                }
            }
        }
    }

    /// 热评段在正文里的矩形范围。行 y 坐标直接吃 draw(_:) 算好的 lineTops / lineHeights，
    /// 两处口径不可能再漂。
    private func reviewBands(lineTops: [CGFloat], lineHeights: [CGFloat], targetWidth: CGFloat) -> [(rect: CGRect, block: Int)] {
        guard reviewAccentColor != nil else { return [] }
        // 卡片上下留白：旧值最小 4pt，热评行上沿几乎贴着边框。
        // 段间距上再多给 1pt，保证窄段距时也有呼吸；只是画在上一段行框下沿，不会盖住字。
        let pad = min(14, max(8, paragraphSpacing + 1))
        var bands: [(rect: CGRect, block: Int)] = []
        var startIndex: Int?
        var startParagraph: Int?

        for index in lines.indices {
            let paragraphId = index < lineParagraphIds.count ? lineParagraphIds[index] : -1
            let nextParagraphId = index + 1 < lineParagraphIds.count ? lineParagraphIds[index + 1] : -2

            if startIndex == nil,
               lines[index].hasPrefix("热评 · ") || lines[index].hasPrefix("神评 · ") {
                startIndex = index
                startParagraph = paragraphId
            }

            guard let start = startIndex, let pid = startParagraph else { continue }
            let isLastOfParagraph = nextParagraphId != pid
            if isLastOfParagraph {
                let top = lineTops[start] - pad
                let bottom = lineTops[index] + lineHeights[index] + pad
                let blockId = start < lineBlockIds.count ? lineBlockIds[start] : -1
                bands.append((CGRect(x: 0, y: max(0, top), width: targetWidth,
                                     height: bottom - max(0, top)), blockId))
                startIndex = nil
                startParagraph = nil
            }
        }
        return bands
    }

    // MARK: - 段内逐字：绘制

    /// 某一行里 [start, end) 这段字对应的 x 范围；跟本行不相交就返回 nil
    private func charXRange(layout: LineLayout, start: Int, end: Int) -> (CGFloat, CGFloat)? {
        let lineLength = max(0, layout.boundaries.count - 1)
        let lineStart = layout.charStart
        let lineEnd = lineStart + lineLength
        let from = max(start, lineStart)
        let to = min(end, lineEnd)
        guard to > from else { return nil }
        let first = min(lineLength, max(0, from - lineStart))
        let last = min(lineLength, max(0, to - lineStart))
        guard first < layout.boundaries.count, last < layout.boundaries.count else { return nil }
        let x1 = layout.boundaries[first]
        let x2 = layout.boundaries[last]
        guard x2 > x1 else { return nil }
        return (x1, x2)
    }

    private func fillCharRange(_ ctx: CGContext, layout: LineLayout, start: Int, end: Int, color: UIColor) {
        guard let (x1, x2) = charXRange(layout: layout, start: start, end: end) else { return }
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: x1, y: layout.rect.minY, width: x2 - x1, height: layout.rect.height))
        ctx.restoreGState()
    }

    /// 本行有字的那段 x 区间：跳过缩进和行尾留白，只算字形本身
    private func glyphSpanX(layout: LineLayout, text: String) -> (CGFloat, CGFloat)? {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return nil }
        // 半角空格、制表、全角空格、不换行空格、零宽连接符都算空白，不给它们铺底色
        func isBlank(_ unit: UInt16) -> Bool {
            unit == 0x20 || unit == 0x09 || unit == 0x3000 || unit == 0x00A0 || unit == 0x200B
        }
        guard let first = units.firstIndex(where: { !isBlank($0) }) else { return nil }
        var last = units.count - 1
        while last > first, isBlank(units[last]) { last -= 1 }
        guard first < layout.boundaries.count, last + 1 < layout.boundaries.count else { return nil }
        let x1 = layout.boundaries[first]
        let x2 = layout.boundaries[last + 1]
        guard x2 > x1 else { return nil }
        return (x1, x2)
    }

    private func underlineCharRange(_ ctx: CGContext, layout: LineLayout, start: Int, end: Int, hex: String?) {
        guard let (x1, x2) = charXRange(layout: layout, start: start, end: end) else { return }
        ctx.saveGState()
        let color = UIColor(readerHex: hex ?? "#2F7BF6") ?? UIColor.systemBlue
        ctx.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.5)
        let y = layout.rect.maxY + 1
        ctx.move(to: CGPoint(x: x1, y: y))
        ctx.addLine(to: CGPoint(x: x2, y: y))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 段内某个字符偏移落在哪一行
    private func lineLayout(paragraphId: Int, offset: Int) -> LineLayout? {
        for item in lineLayouts {
            guard let layout = item, layout.paragraphId == paragraphId else { continue }
            let lineLength = max(0, layout.boundaries.count - 1)
            if offset >= layout.charStart, offset <= layout.charStart + lineLength {
                return layout
            }
        }
        return nil
    }

    /// 段内字符边界（第 offset 个字之前）的窗口坐标：字选手柄贴在这儿
    public static func boundaryPoint(paragraphId: Int, offset: Int) -> CGPoint? {
        for box in activePages {
            guard let view = box.view,
                  let layout = view.lineLayout(paragraphId: paragraphId, offset: offset) else { continue }
            let index = max(0, min(layout.boundaries.count - 1, offset - layout.charStart))
            let point = CGPoint(x: layout.boundaries[index], y: layout.rect.midY)
            return view.convert(point, to: nil)
        }
        return nil
    }

    /// 段内字符区间的窗口矩形：操作气泡贴着选中文字
    public static func windowRect(paragraphId: Int, from: Int, to: Int) -> CGRect? {
        for box in activePages {
            guard let view = box.view else { continue }
            var union: CGRect?
            for item in view.lineLayouts {
                guard let layout = item, layout.paragraphId == paragraphId,
                      let (x1, x2) = view.charXRange(layout: layout, start: from, end: to) else { continue }
                let boxRect = CGRect(x: x1, y: layout.rect.minY - 4,
                                     width: x2 - x1, height: layout.rect.height + 8)
                union = union.map { $0.union(boxRect) } ?? boxRect
            }
            if let union {
                return view.convert(union, to: nil)
            }
        }
        return nil
    }

    /// 拖手柄时：离触点最近的字符边界（绝对段内偏移）
    public static func boundaryIndex(paragraphId: Int, nearWindowPoint point: CGPoint) -> Int? {
        var best: (view: CoreTextUIView, distance: CGFloat, layouts: [LineLayout])?
        for box in activePages {
            guard let view = box.view else { continue }
            let layouts = view.lineLayouts.compactMap { item -> LineLayout? in
                guard let item, item.paragraphId == paragraphId else { return nil }
                return item
            }
            guard !layouts.isEmpty else { continue }
            let local = view.convert(point, from: nil)
            let distance = layouts.map { layout -> CGFloat in
                if local.y < layout.rect.minY { return layout.rect.minY - local.y }
                if local.y > layout.rect.maxY { return local.y - layout.rect.maxY }
                return 0
            }.min() ?? .greatestFiniteMagnitude
            if best == nil || distance < best!.distance {
                best = (view, distance, layouts)
            }
        }
        guard let best else { return nil }
        let local = best.view.convert(point, from: nil)
        let ordered = best.layouts.sorted { $0.charStart < $1.charStart }
        guard let first = ordered.first, let last = ordered.last else { return nil }
        if local.y < first.rect.minY { return first.charStart }
        let lastLength = max(0, last.boundaries.count - 1)
        if local.y > last.rect.maxY { return last.charStart + lastLength }
        let layout = ordered.min {
            abs(local.y - $0.rect.midY) < abs(local.y - $1.rect.midY)
        } ?? first
        var bestOffset = layout.charStart
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, x) in layout.boundaries.enumerated() {
            let distance = abs(local.x - x)
            if distance < bestDistance {
                bestDistance = distance
                bestOffset = layout.charStart + index
            }
        }
        return bestOffset
    }
}

extension CoreTextUIView: UIGestureRecognizerDelegate {
    /// 只有点在热评卡片或段评气泡上才吃掉这次点击，别抢翻页的 tap
    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let tap = gestureRecognizer as? UITapGestureRecognizer else { return true }
        let point = tap.location(in: self)
        if reviewCardRects.contains(where: { $0.rect.contains(point) }) { return true }
        return commentBubbleRects.contains { $0.rect.insetBy(dx: -6, dy: -6).contains(point) }
    }
}
#endif

// MARK: - 阅读页自定义图片（下拉露出的背景 / 书签图）

/// 正文背景图（界面里「用图片做阅读背景」）：存 Documents/ReaderBackground/background.jpg。
/// ReaderConfig 里记的是绝对路径，App 升级后容器 UUID 会变，读的时候按文件名回落一次。
enum ReaderBackgroundStorage {
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ReaderBackground", isDirectory: true)
    }

    static func resolve(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if FileManager.default.fileExists(atPath: path) { return path }
        let name = (path as NSString).lastPathComponent
        let candidate = directory().appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : path
    }

    #if os(iOS)
    /// 相册选的图：长边压到 2400 再落盘，返回绝对路径
    static func save(_ data: Data) -> String? {
        let dir = directory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = ReaderAssetStorage.downscaledJPEG(from: data) ?? data
        let url = dir.appendingPathComponent("background.jpg")
        do {
            try payload.write(to: url, options: .atomic)
            ReaderBackgroundImageCache.shared.removeAll()
            return url.path
        } catch {
            return nil
        }
    }
    #endif
}

/// 书签的绘制盒子：宽固定，高按「高宽比」算。
/// 0 = 自动：自定义图按图片自身比例，默认绶带按 1.73。
/// 阅读页与外观面板的预览都走这一份算法，两边才不会对不上。
enum BookmarkBoxMetrics {
    static let defaultRibbonAspect: CGFloat = 1.73

    static func height(width: CGFloat, aspect: Double, imageSize: CGSize?) -> CGFloat {
        if aspect > 0 { return width * CGFloat(aspect) }
        if let imageSize, imageSize.width > 0, imageSize.height > 0 {
            return width * (imageSize.height / imageSize.width)
        }
        return width * defaultRibbonAspect
    }

    /// 自动比例的值（面板里显示「自动」用）
    static func autoAspect(imageSize: CGSize?) -> Double {
        if let imageSize, imageSize.width > 0, imageSize.height > 0 {
            return Double(imageSize.height / imageSize.width)
        }
        return Double(defaultRibbonAspect)
    }
}

/// 两张图存沙盒 Documents/ReaderAssets，路径记在 UserDefaults 里。
enum ReaderAssetStorage {
    static let pullBackgroundKey = "reader_pull_background_path"
    static let bookmarkImageKey = "reader_bookmark_image_path"

    static func directory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ReaderAssets", isDirectory: true)
    }

    static func save(_ data: Data, name: String) -> String? {
        let dir = directory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).jpg")
        // 存之前先缩到长边 2400 以内：相册原图动辄 4000+ 像素，解码一次几十 MB，
        // 面板里每拖动一下就要重绘一遍，主线程直接被拖死（表现就是「页面点不动」）
        #if os(iOS)
        let payload = downscaledJPEG(from: data) ?? data
        #else
        let payload = data
        #endif
        do {
            try payload.write(to: url, options: .atomic)
            // 只存文件名：沙盒绝对路径里的容器 UUID 每次升级/重装都会变，
            // 存绝对路径的话升级完这两张图就找不到了
            return url.lastPathComponent
        } catch {
            return nil
        }
    }

    #if os(iOS)
    /// 长边超过 maxDimension 就先缩再压，够当背景用，也不会把内存吃光
    static func downscaledJPEG(from data: Data, maxDimension: CGFloat = 2400) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return downscaled(image, maxDimension: maxDimension).jpegData(compressionQuality: 0.9)
    }

    /// 长边超过 maxDimension 就按比例缩下来
    static func downscaled(_ image: UIImage, maxDimension: CGFloat = 2400) -> UIImage {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > maxDimension else { return image }
        let scale = maxDimension / longSide
        let target = CGSize(width: (image.size.width * scale).rounded(),
                            height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
    #endif

    /// 存的是文件名；老的版本存过整条 file:// 绝对路径，取最后一段照样能用
    static func storedName(for key: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: key), !value.isEmpty else { return nil }
        if value.contains("/") {
            if let url = URL(string: value) { return url.lastPathComponent }
            return (value as NSString).lastPathComponent
        }
        return value
    }

    /// 当前沙盒里的实际位置
    static func fileURL(for key: String) -> URL? {
        guard let name = storedName(for: key) else { return nil }
        return directory().appendingPathComponent(name)
    }

    static func path(for key: String) -> String? {
        fileURL(for: key)?.path
    }

    static func setPath(_ value: String?, for key: String) {
        if let value, !value.isEmpty {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func clear(_ key: String) {
        if let url = fileURL(for: key) {
            try? FileManager.default.removeItem(at: url)
        }
        #if os(iOS)
        forgetCachedImage(for: key)
        #endif
        setPath(nil, for: key)
    }

    #if os(iOS)
    /// 解码过的图缓一份：面板每次重绘都会读它，直接 `UIImage(contentsOfFile:)`
    /// 等于每帧都从磁盘解码一张大图
    private static let decodedCache = NSCache<NSString, UIImage>()

    static func image(for key: String) -> UIImage? {
        guard let url = fileURL(for: key) else { return nil }
        let cacheKey = url.path as NSString
        if let cached = decodedCache.object(forKey: cacheKey) { return cached }
        guard let loaded = UIImage(contentsOfFile: url.path) else { return nil }
        // 老版本存进来的可能是没缩过的原图，读的时候顺手缩一次
        let image = downscaled(loaded)
        decodedCache.setObject(image, forKey: cacheKey)
        return image
    }

    /// 换了图 / 清了图就把缓存丢掉
    static func forgetCachedImage(for key: String) {
        guard let url = fileURL(for: key) else { return }
        decodedCache.removeObject(forKey: url.path as NSString)
    }
    #endif
}

#if os(iOS)
/// 导航栏透明：背景图预览的最上一条不会被导航栏盖住（iOS 16 以下忽略）
struct TransparentNavBar: ViewModifier {
    func body(content: Content) -> some View {
        content
        #if os(iOS)
        if #available(iOS 16.0, *) {
            content.toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// 设置页入口：正文背景图（跟阅读页「界面」面板同一批键）
struct ReaderBackgroundSettingsView: View {
    @ObservedObject private var config = ReaderConfig.shared
    @Environment(\.appTheme) private var theme
    @State private var pickedItem: Any?
    @State private var previewImage: UIImage?
    @AppStorage("reader_bg_image_scale") private var scale: Double = 1
    @AppStorage("reader_bg_image_offset_x") private var offsetX: Double = 0
    @AppStorage("reader_bg_image_offset_y") private var offsetY: Double = 0

    var body: some View {
        List {
            Section {
                if let bg = previewImage {
                    Image(uiImage: bg)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(CGFloat(scale))
                        .offset(x: CGFloat(offsetX), y: CGFloat(offsetY))
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                } else {
                    Text(config.backgroundImagePath.isEmpty ? "还没有选图" : "图片读不出来")
                        .font(.caption)
                        .foregroundColor(theme.palette.secondaryInk)
                }
            } header: {
                Text("预览")
            }
            .appThemedRows()

            Section {
                Toggle("用图片做阅读背景", isOn: $config.backgroundImageEnabled)
                if #available(iOS 16.0, *) {
                    PhotosPicker(selection: Binding(
                        get: { pickedItem as? PhotosPickerItem },
                        set: { newValue in
                            pickedItem = newValue
                            guard let item = newValue else { return }
                            Task {
                                if let data = try? await item.loadTransferable(type: Data.self),
                                   let path = ReaderBackgroundStorage.save(data) {
                                    await MainActor.run {
                                        config.backgroundImagePath = path
                                        config.backgroundImageEnabled = true
                                        previewImage = UIImage(contentsOfFile: path)
                                    }
                                }
                            }
                        }
                    ), matching: .images) {
                        Text(config.backgroundImagePath.isEmpty ? "从相册选图" : "换一张")
                    }
                }
                if !config.backgroundImagePath.isEmpty {
                    Button("清除", role: .destructive) {
                        config.backgroundImagePath = ""
                        previewImage = nil
                    }
                }
            }
            .appThemedRows()

            if !config.backgroundImagePath.isEmpty {
                Section {
                    row("缩放", value: $scale, range: 0.2...4, digits: 2)
                    row("左右位置", value: $offsetX, range: -400...400)
                    row("上下位置", value: $offsetY, range: -400...400)
                }
                .appThemedRows()
            }
        }
        .appThemedList()
        .navigationTitle("正文背景图")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { loadPreview() }
        .onChange(of: config.backgroundImagePath) { _ in loadPreview() }
    }

    private func loadPreview() {
        let path = ReaderBackgroundStorage.resolve(config.backgroundImagePath)
        previewImage = path.isEmpty ? nil : UIImage(contentsOfFile: path)
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, digits: Int = 0) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: Binding(
                get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
                set: { value.wrappedValue = $0 }
            ), in: range)
            Text(String(format: "%.\(digits)f", value.wrappedValue))
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(theme.palette.secondaryInk)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

/// 下拉背景图 / 书签图的选择面板，从阅读页右上角「…」进
struct ReaderAssetsSheet: View {
    @Environment(\.appTheme) private var theme
    /// 选完图让阅读页重新读一遍
    let onChanged: () -> Void

    @State private var pickedBackground: Any?
    @State private var pickedBookmark: Any?
    @State private var reloadToken = 0
    /// 预览用：把两张图读进来
    @State private var previewBackground: UIImage?
    @State private var previewBookmark: UIImage?
    /// 书签位置与尺寸（跟阅读页共用同一份偏好）
    @AppStorage("reader_bookmark_width") private var bookmarkWidth: Double = 34
    @AppStorage("reader_bookmark_x") private var bookmarkX: Double = 1
    /// 书签高宽比，0 = 自动
    @AppStorage("reader_bookmark_aspect") private var bookmarkAspect: Double = 0
    /// 挂下来多少：0 = 贴着屏幕最上沿
    @AppStorage("reader_bookmark_y") private var bookmarkY: Double = 0
    /// 下拉背景图的缩放与对齐（0 顶 / 1 中 / 2 底）
    @AppStorage("reader_pull_background_scale") private var pullBackgroundScale: Double = 1
    @AppStorage("reader_pull_background_align") private var pullBackgroundAlign: Int = 0
    /// 下拉背景图的位置微调（pt，正数往右 / 往下）
    @AppStorage("reader_pull_background_offset_x") private var pullBackgroundOffsetX: Double = 0
    @AppStorage("reader_pull_background_offset_y") private var pullBackgroundOffsetY: Double = 0
    /// 预览是「只露出下拉那一条」还是「整张背景铺开看」
    @State private var previewShowsWholeBackground = false
    /// 预览里模拟的下拉深度（pt，跟真机的 pagePullOffset 一个口径）
    @State private var previewPullDepth: Double = 120
    /// 预览里直接拖 / 捏时的起始快照
    @State private var backgroundDragStart: CGPoint?
    @State private var backgroundPinchStart: Double?
    @State private var bookmarkDragStart: CGPoint?

    var body: some View {
        // 这里不再自带 NavigationView：它是从「书签 / 笔记」面板里导航推入的，
        // 在 sheet 里再弹 sheet 会点好几下都进不去。
        Form {
                if #available(iOS 16.0, *) {
                    Section(header: Text("下拉背景图"),
                            footer: Text("下拉加书签时，正文页底下露出来的就是这张图。缩放滑块前 70% 管 0.05–1，后 30% 管 1–12，细调方便。")) {
                        assetPicker(
                            key: ReaderAssetStorage.pullBackgroundKey,
                            picked: $pickedBackground,
                            name: "pullBackground",
                            height: 120
                        )
                        scaleAdjustRow
                        HStack {
                            Text("缩放微调")
                                .frame(width: 64, alignment: .leading)
                            Spacer()
                            nudgeButton("minus") {
                                pullBackgroundScale = max(0.05, ((pullBackgroundScale - 0.05) * 100).rounded() / 100)
                            }
                            nudgeButton("plus") {
                                pullBackgroundScale = min(12, ((pullBackgroundScale + 0.05) * 100).rounded() / 100)
                            }
                        }
                        Picker("对齐", selection: $pullBackgroundAlign) {
                            Text("顶").tag(0)
                            Text("中").tag(1)
                            Text("底").tag(2)
                        }
                        .pickerStyle(.segmented)
                        adjustableRow(title: "左右位置",
                                      value: $pullBackgroundOffsetX,
                                      sliderRange: -400...400,
                                      limit: -4000...4000)
                        adjustableRow(title: "上下位置",
                                      value: $pullBackgroundOffsetY,
                                      sliderRange: -400...400,
                                      limit: -4000...4000)
                        nudgeRow(title: "位置微调",
                                 step: 10,
                                 left: $pullBackgroundOffsetX,
                                 up: $pullBackgroundOffsetY)
                    }
                    .appThemedRows()

                    Section(header: Text("书签图"),
                            footer: Text("留空就用默认画出来的绶带。")) {
                        assetPicker(
                            key: ReaderAssetStorage.bookmarkImageKey,
                            picked: $pickedBookmark,
                            name: "bookmark",
                            height: 80
                        )
                    }
                    .appThemedRows()
                } else {
                    Section {
                        Text("需要 iOS 16 及以上才能从相册选图。")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                    .appThemedRows()
                }

                Section(header: Text("书签位置与尺寸")) {
                    HStack {
                        Text("尺寸")
                            .frame(width: 64, alignment: .leading)
                        Slider(value: $bookmarkWidth, in: 8...200, step: 1)
                        numberField($bookmarkWidth, limit: 2...2000)
                    }
                    adjustableRow(title: "高宽比",
                                  value: $bookmarkAspect,
                                  sliderRange: 0...4,
                                  limit: 0...40,
                                  fractionDigits: 2,
                                  zeroLabel: "自动")
                    adjustableRow(title: "左右位置",
                                  value: $bookmarkX,
                                  sliderRange: 0...1,
                                  limit: -2...3,
                                  fractionDigits: 3)
                    adjustableRow(title: "上下位置",
                                  value: $bookmarkY,
                                  sliderRange: -40...200,
                                  limit: -2000...2000)
                    nudgeRow(title: "位置微调",
                             step: 0.02,
                             left: $bookmarkX,
                             up: $bookmarkY,
                             upStep: 10)
                }
                .appThemedRows()
        }
        .appThemedList()
        // 预览钉在顶上：滑到下面的滑块时也看得见调完什么效果
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                placementPreview
                    .frame(height: 210)
                // 这里不用分段 Picker：钉在顶上的这块里，分段控件的点击落不到选中态上
                // （按钮是好的，实测两次点击都到位），所以自己拼一对按钮
                HStack(spacing: 0) {
                    previewModeButton("下拉露出", whole: false)
                    previewModeButton("整张背景", whole: true)
                }
                .padding(2)
                .background(theme.palette.divider.opacity(0.12), in: Capsule())
                HStack(spacing: 8) {
                    Text("露出深度")
                        .font(.system(size: 12))
                        .foregroundColor(theme.palette.secondaryInk)
                    Slider(value: $previewPullDepth, in: 40...520, step: 10)
                    Text("\(Int(previewPullDepth))")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(theme.palette.secondaryInk)
                        .frame(width: 40, alignment: .trailing)
                }
                Text(previewShowsWholeBackground
                     ? "整图预览只看构图；调位置、缩放请切回「下拉露出」。"
                     : "在预览上直接拖可以移位置，双指捏可以改缩放；拖书签能改书签位置。")
                    .font(.system(size: 11))
                    .foregroundColor(theme.palette.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(.bar)
        }
        .navigationTitle("下拉与书签外观")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadPreviewImages() }
        .id(reloadToken)
    }

    /// 放置预览：跟阅读页同一套画法 —— 背景图整幅铺满再按对齐裁切，正文页不透明地盖住
    /// 下半部分，露出来的那条就是下拉时看到的背景，书签挂在最顶上。
    ///
    /// 之前预览是把背景图直接裁进那条窄带里，跟真机（先铺满整屏、再被正文页盖住）不是一个
    /// 构图，尺寸一对就露馅。
    private var placementPreview: some View {
        GeometryReader { geo in
            if previewShowsWholeBackground {
                wholeBackgroundPreview(in: geo.size)
            } else {
                pulledBackgroundPreview(in: geo.size)
            }
        }
    }

    /// 整张背景：把整张图等比放进预览框，先看清构图再回「下拉露出」细调。
    /// 之前按整屏比例缩进 210pt 高的框里，宽只剩不到 100pt，什么都看不清。
    private func wholeBackgroundPreview(in size: CGSize) -> some View {
        ZStack {
            if let bg = previewBackground {
                Image(uiImage: bg)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                theme.palette.divider.opacity(0.10)
            }

            previewLabel("整张背景 · 整图")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 6)
                .padding(.top, 4)
        }
        .frame(width: size.width, height: size.height)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.palette.divider.opacity(0.25), lineWidth: 0.5)
        )
    }

    /// 下拉露出：按真机屏幕比例铺满，再只露出顶部那一段（深度跟真机一个口径）
    private func pulledBackgroundPreview(in size: CGSize) -> some View {
        let screen = previewScreenSize
        let factor = size.width / max(1, screen.width)
        let canvasSize = CGSize(width: screen.width * factor, height: screen.height * factor)
        let visibleSize = size
        let pageTop = min(visibleSize.height, CGFloat(previewPullDepth) * factor)
        return ZStack(alignment: .topLeading) {
            if let bg = previewBackground {
                PullBackgroundCanvas(image: bg,
                                     zoom: pullBackgroundScale,
                                     offsetX: pullBackgroundOffsetX,
                                     offsetY: pullBackgroundOffsetY,
                                     alignment: pullBackgroundAlign)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .clipped()
                    .frame(width: visibleSize.width, height: visibleSize.height, alignment: .top)
                    .clipped()
            } else {
                LinearGradient(colors: [theme.palette.divider.opacity(0.22), theme.palette.divider.opacity(0.10)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: visibleSize.width, height: visibleSize.height)
            }

            VStack(spacing: 0) {
                Color.clear.frame(height: pageTop)
                ZStack(alignment: .topLeading) {
                    ReaderConfig.shared.backgroundColor
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(ReaderConfig.shared.textColor.opacity(0.22))
                                .frame(height: 6)
                        }
                    }
                    .padding(14)
                }
            }
            .frame(width: visibleSize.width, height: visibleSize.height, alignment: .top)
            .allowsHitTesting(false)

            bookmarkPreviewView
                .offset(x: previewBookmarkX(in: visibleSize.width), y: CGFloat(bookmarkY) * factor + 2)
                .gesture(bookmarkDragGesture(factor: factor, screen: screen))

            previewLabel("下拉露出的背景 · \(Int(previewPullDepth))pt")
                .padding(.leading, 6)
                .padding(.top, 4)
        }
        .frame(width: visibleSize.width, height: visibleSize.height, alignment: .topLeading)
        .frame(width: size.width, height: size.height, alignment: .top)
        .contentShape(Rectangle())
        .highPriorityGesture(backgroundDragGesture(factor: factor))
        .simultaneousGesture(backgroundMagnifyGesture())
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.palette.divider.opacity(0.25), lineWidth: 0.5)
        )
    }

    private func previewModeButton(_ title: String, whole: Bool) -> some View {
        let active = previewShowsWholeBackground == whole
        return Button {
            previewShowsWholeBackground = whole
        } label: {
            Text(title)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(active ? Color(.secondarySystemBackground) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 预览上直接改

    /// 拖背景 = 改左右 / 上下位置
    private func backgroundDragGesture(factor: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if backgroundDragStart == nil {
                    backgroundDragStart = CGPoint(x: pullBackgroundOffsetX, y: pullBackgroundOffsetY)
                }
                guard let start = backgroundDragStart else { return }
                let step = max(0.05, factor)
                pullBackgroundOffsetX = (start.x + value.translation.width / step).rounded()
                pullBackgroundOffsetY = (start.y + value.translation.height / step).rounded()
            }
            .onEnded { _ in backgroundDragStart = nil }
    }

    /// 双指捏 = 改缩放
    private func backgroundMagnifyGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if backgroundPinchStart == nil { backgroundPinchStart = pullBackgroundScale }
                guard let start = backgroundPinchStart else { return }
                pullBackgroundScale = min(max(start * Double(scale), 0.05), 12)
            }
            .onEnded { _ in backgroundPinchStart = nil }
    }

    /// 拖书签 = 改左右 / 上下位置
    private func bookmarkDragGesture(factor: CGFloat, screen: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if bookmarkDragStart == nil {
                    bookmarkDragStart = CGPoint(x: bookmarkX, y: bookmarkY)
                }
                guard let start = bookmarkDragStart else { return }
                let step = max(0.05, factor)
                bookmarkX = min(max(start.x + Double(value.translation.width / step / max(1, screen.width)), -2), 3)
                bookmarkY = min(max(start.y + Double(value.translation.height / step), -2000), 2000)
            }
            .onEnded { _ in bookmarkDragStart = nil }
    }

    private func previewLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(theme.palette.secondaryInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
    }

    /// 缩放滑块：前半程拉长 0.05–1 这一段，后半程再覆盖 1–12。
    private var scaleAdjustRow: some View {
        HStack {
            Text("缩放")
                .frame(width: 64, alignment: .leading)
            Slider(value: Binding(
                get: { scaleSliderPosition(pullBackgroundScale) },
                set: { pullBackgroundScale = scaleForSlider($0) }
            ), in: 0...1)
            numberField($pullBackgroundScale, limit: 0.05...12, fractionDigits: 2)
        }
    }

    private func scaleSliderPosition(_ scale: Double) -> Double {
        let value = min(max(scale, 0.05), 12)
        if value <= 1 {
            return (value - 0.05) / 0.95 * 0.7
        }
        return 0.7 + log(value) / log(12) * 0.3
    }

    private func scaleForSlider(_ position: Double) -> Double {
        let value = min(max(position, 0), 1)
        let scale: Double
        if value <= 0.7 {
            scale = 0.05 + (value / 0.7) * 0.95
        } else {
            scale = pow(12, (value - 0.7) / 0.3)
        }
        return (scale * 100).rounded() / 100
    }

    /// 一行可调项：滑块给手感，右边数字框给精确值，也能填滑块范围之外的极端值
    @ViewBuilder
    private func adjustableRow(
        title: String,
        value: Binding<Double>,
        sliderRange: ClosedRange<Double>,
        limit: ClosedRange<Double>,
        fractionDigits: Int = 0,
        zeroLabel: String? = nil
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 64, alignment: .leading)
            Slider(value: Binding(
                // 存的可能是滑块范围外的极端值，喂给 Slider 之前先夹一次，否则会 trap
                get: { min(max(value.wrappedValue, sliderRange.lowerBound), sliderRange.upperBound) },
                set: { value.wrappedValue = $0.rounded() }
            ), in: sliderRange, step: fractionDigits > 0 ? 0.01 : 1)
            if let zeroLabel, value.wrappedValue <= 0 {
                Text(zeroLabel)
                    .font(.caption)
                    .foregroundColor(theme.palette.secondaryInk)
                    .frame(width: 58, alignment: .trailing)
            } else {
                numberField(value, limit: limit, fractionDigits: fractionDigits)
            }
        }
    }

    /// 数字框：键盘直接敲，接受滑块范围之外的数值
    @ViewBuilder
    private func numberField(_ value: Binding<Double>, limit: ClosedRange<Double>, fractionDigits: Int = 0) -> some View {
        TextField("", value: Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, limit.lowerBound), limit.upperBound) }
        ), format: .number.precision(.fractionLength(fractionDigits)))
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 12, design: .rounded))
            .frame(width: 58)
            .textFieldStyle(.roundedBorder)
    }

    /// 一排微调按钮：拖拽在表单里容易被滚动抢走，方向键永远点得动
    @ViewBuilder
    private func nudgeRow(
        title: String,
        step: Double,
        left: Binding<Double>,
        up: Binding<Double>,
        upStep: Double? = nil
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 64, alignment: .leading)
            Spacer()
            nudgeButton("arrow.left") { left.wrappedValue -= step }
            nudgeButton("arrow.right") { left.wrappedValue += step }
            nudgeButton("arrow.up") { up.wrappedValue -= (upStep ?? step) }
            nudgeButton("arrow.down") { up.wrappedValue += (upStep ?? step) }
        }
    }

    private func nudgeButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 32)
                .background(theme.palette.divider.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .padding(.leading, 6)
    }

    /// 真机屏幕尺寸：预览的画布按它来，缩放/裁切才跟阅读页一致
    private var previewScreenSize: CGSize {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let bounds = scenes.first(where: { $0.activationState == .foregroundActive })?.screen.bounds
            ?? scenes.first?.screen.bounds
        if let bounds, bounds.width > 1 { return bounds.size }
        #endif
        return CGSize(width: 393, height: 852)
    }

    private func previewBookmarkX(in totalWidth: CGFloat) -> CGFloat {
        let width = CGFloat(bookmarkWidth)
        // 跟阅读页一致：右边最多留 6pt
        return min(max(0, totalWidth - width - 6), max(0, totalWidth * CGFloat(bookmarkX) - width / 2))
    }

    @ViewBuilder
    private var bookmarkPreviewView: some View {
        if let previewBookmark {
            Image(uiImage: previewBookmark)
                .resizable()
                .scaledToFill()
                .frame(width: CGFloat(bookmarkWidth), height: previewBookmarkHeight)
                .clipped()
                .shadow(color: Color.black.opacity(0.18), radius: 3, y: 2)
        } else {
            BookmarkRibbonShape()
                .fill(Color.accentColor.opacity(0.95))
                .frame(width: CGFloat(bookmarkWidth), height: previewBookmarkHeight)
                .shadow(color: Color.black.opacity(0.18), radius: 3, y: 2)
        }
    }

    /// 跟阅读页同一份算法：0 = 自动（图片自身比例 / 默认绶带 1.73）
    private var previewBookmarkHeight: CGFloat {
        BookmarkBoxMetrics.height(width: CGFloat(bookmarkWidth),
                                  aspect: bookmarkAspect,
                                  imageSize: previewBookmark?.size)
    }

    private func loadPreviewImages() {
        #if os(iOS)
        // 解码放后台：原图大的时候，这一步放在主线程会让面板开着像卡死
        Task.detached(priority: .userInitiated) {
            let background = ReaderAssetStorage.image(for: ReaderAssetStorage.pullBackgroundKey)
            let bookmark = ReaderAssetStorage.image(for: ReaderAssetStorage.bookmarkImageKey)
            await MainActor.run {
                previewBackground = background
                previewBookmark = bookmark
            }
        }
        #endif
    }

    @ViewBuilder
    @available(iOS 16.0, *)
    private func assetPicker(key: String, picked: Binding<Any?>, name: String, height: CGFloat) -> some View {
        // 走缓存，别在 body 里读磁盘解码
        if let image = ReaderAssetStorage.image(for: key) {
            HStack {
                Spacer()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: height)
                    .cornerRadius(8)
                Spacer()
            }
        }

        PhotosPicker(
            selection: Binding(
                get: { picked.wrappedValue as? PhotosPickerItem },
                set: { newValue in
                    picked.wrappedValue = newValue
                    guard let item = newValue else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let stored = ReaderAssetStorage.save(data, name: name) {
                            await MainActor.run {
                                ReaderAssetStorage.setPath(stored, for: key)
                                // 文件名固定，换图是覆盖同一个文件，缓存不清就还是旧图
                                ReaderAssetStorage.forgetCachedImage(for: key)
                                reloadToken += 1
                                onChanged()
                            }
                        }
                    }
                }
            ),
            matching: .images
        ) {
            Label(ReaderAssetStorage.path(for: key) == nil ? "从相册选图" : "换一张", systemImage: "photo.on.rectangle")
        }

        if ReaderAssetStorage.path(for: key) != nil {
            Button(role: .destructive) {
                ReaderAssetStorage.clear(key)
                reloadToken += 1
                onChanged()
            } label: {
                Label("清除", systemImage: "trash")
            }
        }
    }
}
#endif
