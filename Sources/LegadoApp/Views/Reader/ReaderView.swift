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
struct CollapsibleSettingBlock<Content: View>: View {
    let title: String
    let tint: Color
    let initiallyExpanded: Bool
    @ViewBuilder let content: () -> Content

    @State private var expanded: Bool

    /// initiallyExpanded = true 的块等于不折：进来就把内容铺出来
    init(title: String, tint: Color, initiallyExpanded: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self._expanded = State(initialValue: initiallyExpanded)
        self.title = title
        self.tint = tint
        self.initiallyExpanded = initiallyExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(tint.opacity(0.85))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(tint.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                content()
            }
        }
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

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: () -> Bool = { true }
        var isAtTop: () -> Bool = { true }
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: (CGFloat, Bool) -> Void = { _, _ in }
        var onLongPress: (CGPoint) -> Void = { _ in }
        var onCharHandleHit: ((CGPoint) -> Bool)?
        var onCharHandleDrag: ((CGPoint) -> Void)?
        private var charDragging = false
        weak var recognizer: UIPanGestureRecognizer?
        weak var longPress: UILongPressGestureRecognizer?
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
        }

        @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            onLongPress(gesture.location(in: gesture.view))
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
        let view = UIView()
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
        DispatchQueue.main.async { [weak view] in
            // 挂到 window 上：正文区（尤其仿真那套 UIKit 翻页）的触摸才会经过这里。
            // 挂在 SwiftUI 的内部小容器上时，正文区的拖拽根本不会送到这个识别器。
            guard let host = view?.window ?? view?.superview else { return }
            coordinator.attach(to: host)
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
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let recognizer = coordinator.recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        if let press = coordinator.longPress {
            press.view?.removeGestureRecognizer(press)
        }
    }
}
#endif

/// 书签绶带：矩形 + 底部三角缺口，落在页顶当书签用
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
    @State private var target: ReviewTarget?

    var body: some View {
        NavigationView {
            List {
                if let chapterURL {
                    Section {
                        Button {
                            target = ReviewTarget(url: chapterURL, title: "本章说")
                        } label: {
                            Label("本章说 · 全部评论", systemImage: "text.bubble")
                        }
                    }
                }

                Section(header: Text("段评 · \(items.count) 段")) {
                    if items.isEmpty {
                        Text("本章暂无段评")
                            .foregroundColor(.secondary)
                    }
                    ForEach(items) { item in
                        Button {
                            target = ReviewTarget(url: item.url, title: "段评")
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text(item.excerpt)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.count >= 99 ? "99+" : "\(item.count)")
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor, in: Capsule())
                            }
                        }
                    }
                }
            }
            .navigationTitle(chapterTitle.isEmpty ? "段评" : chapterTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
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

private struct NativeCommentListSheet: View {
    let target: ReviewTarget

    @Environment(\.dismiss) private var dismiss
    @State private var comments: [ReviewComment] = []
    @State private var total = 0
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("正在加载评论…")
                } else if let errorText {
                    VStack(spacing: 12) {
                        Text(errorText)
                            .foregroundColor(.secondary)
                        Button("重试") { Task { await load() } }
                    }
                } else if comments.isEmpty {
                    Text("暂无评论")
                        .foregroundColor(.secondary)
                } else {
                    List(comments) { comment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(comment.user?.user_name ?? "匿名")
                                    .font(.caption.bold())
                                    .foregroundColor(.secondary)
                                Spacer()
                                if let likes = comment.like_count, likes > 0 {
                                    Label("\(likes)", systemImage: "heart")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text(comment.content ?? "")
                                .font(.subheadline)
                            if let time = comment.create_time {
                                Text(time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(total > 0 ? "\(target.title) · \(total)" : target.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorText = nil
        guard let api = reviewAPIURL(from: target.url) else {
            errorText = "评论地址无法解析"
            isLoading = false
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: api)
            let envelope = try JSONDecoder().decode(ReviewEnvelope.self, from: data)
            comments = envelope.data?.comments ?? []
            total = envelope.data?.total ?? comments.count
        } catch {
            errorText = "加载失败：\(error.localizedDescription)"
        }
        isLoading = false
    }

    private func reviewAPIURL(from raw: String) -> URL? {
        guard var components = URLComponents(string: raw) else { return nil }
        let query = components.queryItems ?? []
        let originalMode = query.first(where: { $0.name == "mode" })?.value
        let para = query.first(where: { $0.name == "para" || $0.name == "paragraph_id" })?.value ?? "0"
        components.path = "/para_review"
        components.queryItems = [
            URLQueryItem(name: "book_id", value: query.first(where: { $0.name == "book_id" })?.value ?? ""),
            URLQueryItem(name: "item_id", value: query.first(where: { $0.name == "item_id" })?.value ?? ""),
            URLQueryItem(name: "item_version", value: query.first(where: { $0.name == "item_version" })?.value ?? ""),
            URLQueryItem(name: "para", value: para),
            URLQueryItem(name: "source", value: query.first(where: { $0.name == "source" })?.value ?? "番茄"),
            URLQueryItem(name: "mode", value: (originalMode == "paragraph" || target.title == "段评") ? "paragraph" : "chapter"),
            URLQueryItem(name: "hot", value: "1")
        ]
        return components.url
    }
}

private struct ReviewEnvelope: Decodable {
    let code: Int
    let data: ReviewData?
}

private struct ReviewData: Decodable {
    let comments: [ReviewComment]?
    let total: Int?
}

private struct ReviewComment: Decodable, Identifiable {
    let comment_id: String
    let content: String?
    let like_count: Int?
    let create_time: String?
    let user: ReviewUser?
    var id: String { comment_id }
}

private struct ReviewUser: Decodable {
    let user_name: String?
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
    @State private var tocReversed: Bool = false
    @State private var showBookmarks: Bool = false
    @State private var showComments: Bool = false
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

    private var currentChapterContent: String {
        currentLoadedChapter?.content ?? ""
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
        currentLoadedChapter?.blocks.first(where: { $0.commentCount < 0 })?.commentURL
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
                    if readerConfig.headerEnabled, readerConfig.pageMode == .scroll {
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
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showControls.toggle()
                                }
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
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showControls.toggle()
                                }
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
                    if readerConfig.footerEnabled, readerConfig.pageMode == .scroll {
                        statusBar(left: readerConfig.footerLeft, center: readerConfig.footerCenter, right: readerConfig.footerRight, extendEdge: .bottom)
                            .offset(y: screenBottomInset - readerConfig.footerGap)
                    }
                }

                // 2. Dismiss Backdrop (when controls are open, tapping anywhere outside bars dismisses them)
                if showControls && !showSettings {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
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
                    Color.black.opacity(0.2 * readerConfig.panelOpacity)
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
                    if !AppEdition.isAppStoreClean {
                        Button {
                            downloadCachedChapters()
                        } label: {
                            Label("下载缓存（\(readerConfig.cachedChapterCount) 章）", systemImage: "arrow.down.circle")
                        }
                    }
                    Button {
                        showReplaceRules = true
                    } label: {
                        Label("替换净化规则", systemImage: "wand.and.sparkles")
                    }
                    Button {
                        showBookmarks = true
                    } label: {
                        Label("书签", systemImage: "bookmark")
                    }
                    if !AppEdition.isAppStoreClean {
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
                .foregroundColor(readerConfig.textColor)
                .padding(.leading, readerConfig.paddingLeft)
                .padding(.trailing, readerConfig.paddingRight)
                .padding(.top, readerConfig.chapterTopSpacing)
                .padding(.bottom, readerConfig.chapterTitleSpacing)
        }
    }

    /// 两端对齐交给自定义排版控件，其余三档用原生 Text。
    @ViewBuilder
    private func bodyTextView(_ text: String) -> some View {
        if readerConfig.textAlignment.isJustify {
            JustifiedBodyText(
                text: text,
                fontSize: readerConfig.fontSize,
                lineSpacing: readerConfig.lineSpacing,
                letterSpacing: readerConfig.letterSpacing,
                textColor: readerConfig.textColor,
                fontName: readerConfig.font.postScriptName,
                underlineEnabled: readerConfig.underlineEnabled,
                underlineColor: readerConfig.underlineColor,
                underlineStyle: readerConfig.underlinePattern.nsUnderlineStyle
            )
        } else {
            bodyText(text, alignment: nativeTextAlignment)
        }
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
                                    } else {
                                        bodyTextView(applyingKinsoku(block.text))
                                            .padding(.leading, readerConfig.paddingLeft)
                                            .padding(.trailing, readerConfig.paddingRight)
                                            .padding(.bottom, readerConfig.paragraphSpacing)
                                            // 段落级长按：连续滚动里一个 block 就是一段
                                            .onLongPressGesture {
                                                selectScrollParagraph(block, chapterIndex: loadedCh.chapter.index)
                                            }
                                            .onTapGesture {
                                                if block.commentCount < 0 {
                                                    showComments = true
                                                }
                                            }
                                            .background(scrollAnnotationBackground(for: block, chapterIndex: loadedCh.chapter.index))
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
                // 选段中点别处：退出选段、保留这次的更改
                if selectedBlockRange != nil {
                    clearParagraphSelection()
                    return
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls.toggle()
                }
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
                charAnnotations: charAnnotationRangesForCurrentChapter,
                annotationRanges: annotationRangesForCurrentChapter,
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
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                }
            )
            // 这里不要再挂 .id / .transition：给 pager 换 id 会让 SwiftUI 整块重建，
            // 换章就变成左右位移、没有卷页动画了。换章的卷页由 pager 内部做。
            // 仿真翻页整页也要贴屏幕物理边缘：只忽略底部的话，页眉那条会从安全区下面起算，
            // 距顶调不到灵动岛位置时，页脚贴底而顶部留空
            .ignoresSafeArea(edges: .all)
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
                        if pageBlocks.first?.isImage == true, let urlStr = pageBlocks.first?.imageUrl {
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
                DragGesture(minimumDistance: 0)
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
                            // 选段中点别处：退出选段、保留这次的更改
                            if selectedBlockRange != nil {
                                clearParagraphSelection()
                                return
                            }
                            let x = value.startLocation.x
                            if x < width * 0.3 {
                                turnPage(forward: false)
                            } else if x > width * 0.7 {
                                turnPage(forward: true)
                            } else {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showControls.toggle()
                                }
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
                .foregroundColor(readerConfig.textColor)
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
                    Label("替换净化规则", systemImage: "wand.and.sparkles")
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
                    .foregroundColor(readerConfig.textColor)
                    .frame(width: 54, height: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            readerConfig.backgroundColor
                .opacity(0.97)
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 3)
                .ignoresSafeArea(edges: .top)
        )
        .overlay(
            Rectangle()
                .fill(readerConfig.textColor.opacity(0.12))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var bottomControlPanel: some View {
        VStack(spacing: 12) {
            chapterNavigationRow

            Rectangle()
                .fill(readerConfig.textColor.opacity(0.12))
                .frame(height: 0.5)

            bottomActionRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(
            readerConfig.backgroundColor
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
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls.toggle()
            }
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
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls.toggle()
            }
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

    private func jumpToChapter(_ targetIndex: Int, toEnd: Bool = false) {
        AppLog.write("[阅读] 换章 → 第 \(targetIndex + 1) 章 / 共 \(chapters.count) 章")
        guard targetIndex >= 0 && targetIndex < chapters.count else { return }
        audioService.stop()
        currentChapterIndex = targetIndex
        currentPageIndex = 0
        currentReadingBlockId = 0
        scrollSessionId = UUID()
        loadInitialChapter(at: targetIndex, targetPageIndex: toEnd ? -1 : 0, scrollToTargetEnd: toEnd)
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
        HStack(spacing: 0) {
            // Contents Table (目录)
            Button(action: { showTOC = true }) {
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

            if !AppEdition.isAppStoreClean {
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
            }

            // TTS (听书)
            Button(action: {
                if TTSCastStore.shared.enabled {
                    // 多角色：整章按段切好、逐段换音色播
                    if audioService.isPlaying {
                        audioService.pause()
                    } else if audioService.isPaused && !audioService.currentText.isEmpty {
                        audioService.resume()
                    } else {
                        audioService.speakWithCast(currentChapterContent)
                    }
                } else {
                    audioService.togglePlayPause(text: currentChapterContent)
                }
            }) {
                VStack(spacing: 4) {
                    Image(systemName: audioService.isPlaying ? "pause.circle.fill" : (audioService.isPaused ? "play.circle.fill" : "headphones"))
                        .font(.system(size: 20))
                        .foregroundColor(audioService.isPlaying ? .accentColor : readerConfig.textColor)
                    Text(audioService.isPlaying ? "暂停" : (audioService.isPaused ? "继续" : "听书"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(audioService.isPlaying ? .accentColor : readerConfig.textColor)
                }
                .foregroundColor(readerConfig.textColor)
                .frame(maxWidth: .infinity)
            }
            .onLongPressGesture {
                showTTSSettings = true
            }

            if !AppEdition.isAppStoreClean {
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
            }

            // Interface Settings (界面设置)
            Button(action: { showSettings = true }) {
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
            List(tocDisplayChapters) { ch in
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
            .navigationTitle("目录 (\(chapters.count)章)")
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
                let bubbleWidth = min(392, max(300, geo.size.width - 12))
                let x = min(max(rect.midX - origin.x, bubbleWidth / 2 + 6), max(bubbleWidth / 2 + 6, geo.size.width - bubbleWidth / 2 - 6))
                let above = rect.minY - origin.y - 44
                let y = above < 64 ? rect.maxY - origin.y + 44 : above
                paragraphBubble(width: bubbleWidth)
                    .frame(width: bubbleWidth)
                    .position(x: x, y: y)
                    .transition(.opacity)
                if let kind = colorPickerKind {
                    // 调色板放到气泡上方，别盖住刚选中的那段文字
                    let paletteY = y - 52 < 70 ? y + 54 : y - 52
                    annotationColorRow(kind: kind)
                        .frame(width: bubbleWidth)
                        .position(x: x, y: min(geo.size.height - 28, paletteY))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .allowsHitTesting(selectedBlockRange != nil)
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

    private func paragraphBubble(width: CGFloat) -> some View {
        let actionCount = readerConfig.pageMode == .scroll ? 7 : 8
        let actionWidth = max(34, (width - 9) / CGFloat(actionCount))
        return HStack(spacing: 0) {
            paragraphAction("复制", "doc.on.doc", width: actionWidth) { copySelectedParagraph() }
            paragraphAction("搜索", "magnifyingglass", width: actionWidth) { searchSelectedParagraph() }
            paragraphAction("书签", "bookmark", width: actionWidth) { addBookmarkForSelection() }
            paragraphAction("下划线", "underline", width: actionWidth, tint: readerHexColor(underlineHex)) {
                colorPickerKind = .underline
            }
            paragraphAction("底色", "highlighter", width: actionWidth, tint: readerHexColor(highlightHex)) {
                colorPickerKind = .highlight
            }
            paragraphAction("替换", "arrow.left.arrow.right", width: actionWidth) {
                replaceInput = ""
                showReplaceInput = true
            }
            if readerConfig.pageMode != .scroll {
                paragraphAction("整段", "text.alignleft", width: actionWidth) { resetToWholeParagraph() }
            }
            Divider().frame(height: 22)
            paragraphAction("取消", "xmark", width: actionWidth) { cancelParagraphSelection() }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)
    }

    private func paragraphAction(_ title: String, _ icon: String, width: CGFloat, tint: Color? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button {
            // 这一下也会落到页面那套「点一下开关工具栏」的手势上，先按住它，
            // 否则操作栏刚点完就被顶出来的工具栏盖住
            tapSuppressor.suppress()
            action()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(tint ?? .primary)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary)
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
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
                        .overlay(Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                        .overlay(
                            Circle()
                                .stroke(readerConfig.textColor, lineWidth: selected == hex ? 2 : 0)
                                .padding(-2)
                        )
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 20)
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
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5))
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

    /// 窗口层长按落在滚动模式正文上：换算成段落再走同一条选择逻辑
    private func handleLongPressAtWindowPoint(_ point: CGPoint) {
        #if os(iOS)
        guard !showControls else { return }

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
        selectScrollParagraph(block, chapterIndex: hit.chapterIndex)
        #endif
    }

    /// 连续滚动模式下，段落的底色标注画在段落的背景上
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

    private func showBookmarkHint(_ text: String) {
        bookmarkHintText = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
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
                brightnessRow
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch settingsPanel {
                    case .quick:
                        pageModeRow
                        fontSizeRow
                        themeRow
                        CollapsibleSettingBlock(title: "配色", tint: readerConfig.textColor) { colorSection }
                        backgroundImageSection
                        CollapsibleSettingBlock(title: "显示", tint: readerConfig.textColor, initiallyExpanded: true) { displaySection }
                    case .spacing:
                        typographySection
                        CollapsibleSettingBlock(title: "正文排版", tint: readerConfig.textColor) { bodyLayoutSection }
                        underlineSection
                        CollapsibleSettingBlock(title: "页边距", tint: readerConfig.textColor) { marginSection }
                        CollapsibleSettingBlock(title: "章节标题", tint: readerConfig.textColor) { chapterTitleSection }
                        headerFooterSection
                    case .tts:
                        ttsSection
                    }
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.18), value: settingsPanel)
                .tint(settingsAccent)
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 420)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                // 面板调半透明时不要毛玻璃，否则还是看不清底下的正文
                .fill(readerConfig.backgroundColor.opacity(readerConfig.panelLayerOpacity))
                .overlay(
                    Group {
                        if readerConfig.panelOpacity >= 0.99 {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(.ultraThinMaterial)
                        }
                    }
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(readerConfig.textColor.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 18, y: -6)
        .fileImporter(
            isPresented: $showBackgroundImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                importBackgroundImage(from: url)
            }
        }
        .background(
            readerConfig.backgroundColor
                .opacity(readerConfig.panelLayerOpacity)
                .shadow(color: Color.black.opacity(0.2), radius: 16, x: 0, y: -6)
                .ignoresSafeArea(edges: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(readerConfig.textColor.opacity(0.10), lineWidth: 0.5)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// iOS 上附带仿真翻页的手势计数，方便截屏排查；其他平台为空。
    private var pagerDebugSuffix: String {
        #if os(iOS)
        return " · 手势 pan\(PageCurlPager.Coordinator.panEnds)/\(PageCurlPager.Coordinator.panHits) swipe\(PageCurlPager.Coordinator.swipeHits) tap\(PageCurlPager.Coordinator.tapHits)"
        #else
        return ""
        #endif
    }

    private var settingsHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "textformat.size")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(settingsAccent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(settingsAccent.opacity(0.14)))

            VStack(alignment: .leading, spacing: 1) {
                Text("阅读设置")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(readerConfig.textColor)
                // 这行小字带状态：翻页出问题时截一张就能看出来卡在哪
                Text("\(settingsPanel.rawValue) · \(readerConfig.pageMode.rawValue) · 章 \(currentChapterIndex + 1)/\(chapters.count) · 页 \(currentPageIndex + 1)/\(currentLoadedChapter?.pages.count ?? 0)\(pagerDebugSuffix)\(isSwitchingChapter ? " · 换章中" : "")")
                    .font(.system(size: 10))
                    .foregroundColor(readerConfig.textColor.opacity(0.45))
            }

            Spacer()

            // 收起：只留标题这一行，整页露出来看效果
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    panelCollapsed.toggle()
                }
            }) {
                Image(systemName: panelCollapsed ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(readerConfig.textColor.opacity(0.45))
            }
            .buttonStyle(.plain)

            Button(action: {
                withAnimation(.easeInOut(duration: 0.22)) {
                    showSettings = false
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(readerConfig.textColor.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }

    /// 设置面板的强调色：跟当前主题走
    private var settingsAccent: Color {
        readerConfig.theme.accentColor
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
                        Image(systemName: panel.symbolName)
                            .font(.system(size: 11, weight: .medium))
                        Text(panel.rawValue)
                            .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                    }
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isOn ? settingsAccent.opacity(0.20) : readerConfig.textColor.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isOn ? settingsAccent.opacity(0.45) : .clear, lineWidth: 0.8)
                    )
                    .foregroundColor(isOn ? settingsAccent : readerConfig.textColor.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 分节标题：小号、加字距、压暗，配合上面的细线把设置分块
    private func sectionTitle(_ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(settingsAccent.opacity(0.85))
                .frame(width: 2.5, height: 11)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(readerConfig.textColor.opacity(0.5))
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(readerConfig.textColor.opacity(0.08))
            .frame(height: 0.5)
            .padding(.top, 12)
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
            HStack(spacing: 10) {
                Image(systemName: "sun.min")
                    .font(.system(size: 12))
                    .foregroundColor(readerConfig.textColor.opacity(0.6))
                Slider(value: $readerConfig.brightness, in: 0.2...1.0, step: 0.05)
                    .tint(readerConfig.textColor.opacity(0.65))
                Image(systemName: "sun.max")
                    .font(.system(size: 13))
                    .foregroundColor(readerConfig.textColor.opacity(0.6))
                Text("\(Int(readerConfig.brightness * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(readerConfig.textColor.opacity(0.6))
                    .frame(width: 50, alignment: .trailing)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(readerConfig.textColor.opacity(0.07)))
            }
    }

    /// 显示：亮度 + 自动夜间
    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionDivider
            HStack(spacing: 10) {
                Text("面板")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
                Slider(value: Binding(
                    get: { readerConfig.panelOpacity },
                    set: { readerConfig.panelOpacity = $0 }
                ), in: 0.25...1.0, step: 0.05)
                .tint(readerConfig.textColor.opacity(0.65))
                Text("\(Int((readerConfig.panelOpacity * 100).rounded()))%")
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
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("阅读模式")
            Picker("阅读模式", selection: $readerConfig.pageMode) {
                ForEach(PageMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
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
            sectionDivider
            sectionTitle("排版")

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
            Text("开着：一页没排满时把余下的高度匀进段间距，正文铺到页脚，段间距看着会变宽。关掉：段间距就是你设的那个数，余白全留在页末。")
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

                Text("线宽与偏移在 Cocoa 文本里没有公开接口，这两项无法实现。")
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
            sectionDivider
            sectionTitle("背景图")

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
            sectionDivider

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
            Text("有个别书源把整章塞成一行、没有空行。开着时按句末标点把这种超长行切成正常段落，已经分好段的正文不动。")
                .font(.system(size: 11))
                .foregroundColor(readerConfig.textColor.opacity(0.5))

            Toggle(isOn: $readerConfig.punctuationKinsoku) {
                Text("标点禁则")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(readerConfig.textColor.opacity(0.7))
            }
            .toggleStyle(.switch)
            Text("中文排版规矩：句号、逗号这类标点不甩到行首，开引号、开括号不留在行尾。按页翻和连续模式都生效。")
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
            Slider(value: value, in: range, step: step)
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
        return "\(Int(value))\(suffix)"
    }

    private var fontSizeRow: some View {
        HStack(spacing: 12) {
            Text("字号")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(readerConfig.textColor.opacity(0.7))
                .frame(width: 36, alignment: .leading)

            Text("A-")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(readerConfig.textColor.opacity(0.8))

            Slider(value: $readerConfig.fontSize, in: 12...32, step: 1)
                .accentColor(.accentColor)
                .onChange(of: readerConfig.fontSize) { _ in
                    recomputePagination()
                }

            Text("A+")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(readerConfig.textColor.opacity(0.8))

            Text("\(Int(readerConfig.fontSize)) pt")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(readerConfig.textColor.opacity(0.7))
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var themeRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionDivider
            sectionTitle("主题")
            HStack(spacing: 8) {
                ForEach(ReaderTheme.allCases) { t in
                    themeButton(for: t)
                }
            }
        }
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
            HStack(spacing: 4) {
                Circle()
                    .fill(t.backgroundColor)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(readerConfig.textColor.opacity(0.25), lineWidth: 1)
                    )
                Text(t.rawValue)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : readerConfig.textColor.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .accentColor : readerConfig.textColor)
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
            return loaded
        } catch {
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

                self.isLoadingInitial = false
                self.isSwitchingChapter = false
                let currentPos = self.currentChapterCharOffset()
                BookStore.shared.updateProgress(bookUrl: activeBook.bookUrl, chapterIndex: index, chapterTitle: currentChapter.title, chapterPos: currentPos)
                self.preCacheNeighbors(around: index)

                if readerConfig.pageMode == .scroll && self.scrollToChapterId == nil {
                    self.scrollToChapterId = scrollToTargetEnd ? "chapter_end_\(index)" : "chapter_\(index)"
                }
            } catch {
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
                                blocks.append(ContentBlock(id: currentId, isImage: false, text: indent + textBefore, imageUrl: nil))
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
                            blocks.append(ContentBlock(id: currentId, isImage: false, text: indent + textAfter, imageUrl: nil))
                            currentId += 1
                        }
                    }
                    attachReviewMarker(marked, from: firstBlockIndex, blocks: &blocks)
                    continue
                }
            }

            let paragraphs = readerConfig.smartParagraphs ? smartParagraphSplit(trimmed) : [trimmed]
            for paragraph in paragraphs {
                let indent = (paragraph.hasPrefix("　") || paragraph.hasPrefix("    ")) ? "" : "　　"
                blocks.append(ContentBlock(id: currentId, isImage: false, text: indent + paragraph, imageUrl: nil))
                currentId += 1
            }
            attachReviewMarker(marked, from: firstBlockIndex, blocks: &blocks)
        }
        return blocks
    }

    /// 从一行里拆出段评 / 本章说哨兵，剩下才是正文。
    private func extractReviewMarkers(from line: String)
        -> (line: String, count: Int, url: String?, chapterURL: String?) {
        var text = line
        var count = 0
        var url: String?
        var chapterURL: String?

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
        return (text, count, url, chapterURL)
    }

    /// 段评挂在段落最后一块上；本章说单独生成一条入口。
    private func attachReviewMarker(_ marker: (line: String, count: Int, url: String?, chapterURL: String?),
                                    from firstBlockIndex: Int,
                                    blocks: inout [ContentBlock]) {
        guard !AppEdition.isAppStoreClean else { return }
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
    private func splitParagraphIntoLines(text: String, width: Double) -> [(text: String, isParagraphEnd: Bool, charStart: Int)] {
        let font = ReaderFontFactory.ctFont(
            postScriptName: readerConfig.font.postScriptName,
            boldPostScriptName: readerConfig.font.boldPostScriptName,
            size: readerConfig.fontSize,
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
        let indentWidth = Double(readerConfig.firstLineIndent.rounded()) * Double(readerConfig.fontSize)
        var isFirstLine = true

        while start < textLen {
            let available = isFirstLine ? max(20, width - indentWidth) : width
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
                let pLines = splitParagraphIntoLines(text: block.text, width: usableWidth)
                for lineInfo in pLines {
                    // 段间距算在两个段落之间：上一行是段尾时，这一行之前才加间距，
                    // 页面最后一行后面不会白留一截
                    var lineHeightWithSpacing = lineHeight
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
                        Image(systemName: "photo.badge.exclamationmark")
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
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 1. Check in-memory cache
        if let cached = Self.imageCache.object(forKey: trimmed as NSString) {
            self.imageData = cached as Data
            self.isLoading = false
            self.loadFailed = false
            return
        }

        // 2. Check local file
        if trimmed.hasPrefix("file://") {
            if let url = URL(string: trimmed), let data = try? Data(contentsOf: url) {
                Self.imageCache.setObject(data as NSData, forKey: trimmed as NSString)
                self.imageData = data
                return
            }
        }

        // 3. Remote URL with proper browser headers
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

            // Determine Referer
            if let ref = referer, !ref.isEmpty {
                request.setValue(ref, forHTTPHeaderField: "Referer")
            } else if let host = url.host {
                request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 304), !data.isEmpty {
                Self.imageCache.setObject(data as NSData, forKey: trimmed as NSString)
                await MainActor.run {
                    self.imageData = data
                    self.isLoading = false
                    self.loadFailed = false
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                    self.loadFailed = true
                }
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.loadFailed = true
            }
        }
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
                        Text("未找到包含 “\(searchText)” 的内容")
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
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: renderedText.count))

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
                    Text("正文入库前按顺序跑一遍。正则写错的那条会被跳过，不会把整章弄没。改完重新进这一章或点阅读页的「刷新」就生效。")
                }
            }
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
                    Text(draft.isGlobal ? "这条是全局规则，所有书都跑。" : "这条只对当前这本书跑。")
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

    public override init(frame: CGRect) {
        super.init(frame: frame)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.3
        press.allowableMovement = 22
        addGestureRecognizer(press)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.3
        press.allowableMovement = 22
        addGestureRecognizer(press)
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
              let view = activePages[index].view else { return false }
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
        return parts.joined(separator: "\u{1}")
    }

    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !lines.isEmpty else { return }

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
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: renderedText.count))

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

            // 标注与选中：段落级底色 / 下划线，选中时再叠一层淡蓝
            let blockId = index < lineBlockIds.count ? lineBlockIds[index] : -1
            let lineRect = CGRect(x: 0, y: baselineY - ascent, width: CGFloat(targetWidth), height: ascent + descent)
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
                boundaries.append(x + penOffset)
            }
            let paragraphId = index < lineParagraphIds.count ? lineParagraphIds[index] : -1
            let charStart = index < lineCharStarts.count ? lineCharStarts[index] : 0
            let layout = LineLayout(rect: lineRect,
                                    boundaries: boundaries,
                                    paragraphId: paragraphId,
                                    charStart: charStart)
            layouts[index] = layout

            let style = annotationRanges.first { blockId >= $0.start && blockId < $0.start + max(1, $0.count) }?.style
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
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("预览")
            }

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

            if !config.backgroundImagePath.isEmpty {
                Section {
                    row("缩放", value: $scale, range: 0.2...4, digits: 2)
                    row("左右位置", value: $offsetX, range: -400...400)
                    row("上下位置", value: $offsetY, range: -400...400)
                }
            }
        }
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
                .foregroundColor(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

/// 下拉背景图 / 书签图的选择面板，从阅读页右上角「…」进
struct ReaderAssetsSheet: View {
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
                            footer: Text("下拉加书签时，正文页下面露出来的就是这张图。缩放滑块前 70% 覆盖 0.05–1，后 30% 覆盖 1–12，便于细调。")) {
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

                    Section(header: Text("书签图"),
                            footer: Text("留空就用默认画出来的绶带。")) {
                        assetPicker(
                            key: ReaderAssetStorage.bookmarkImageKey,
                            picked: $pickedBookmark,
                            name: "bookmark",
                            height: 80
                        )
                    }
                } else {
                    Section {
                        Text("需要 iOS 16 及以上才能从相册选图。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
        }
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
                .background(Color.secondary.opacity(0.12), in: Capsule())
                HStack(spacing: 8) {
                    Text("露出深度")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Slider(value: $previewPullDepth, in: 40...520, step: 10)
                    Text("\(Int(previewPullDepth))")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                Text(previewShowsWholeBackground
                     ? "整图预览只看构图；调位置、缩放请切回「下拉露出」。"
                     : "在预览上直接拖可以移位置，双指捏可以改缩放；拖书签能改书签位置。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
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
                Color.secondary.opacity(0.10)
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
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
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
                LinearGradient(colors: [Color.secondary.opacity(0.22), Color.secondary.opacity(0.10)],
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
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
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
            .foregroundColor(.secondary)
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
                    .foregroundColor(.secondary)
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
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
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
