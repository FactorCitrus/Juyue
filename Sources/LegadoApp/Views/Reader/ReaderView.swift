import SwiftUI
import AVFoundation
import CoreText
import UniformTypeIdentifiers
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

public struct ContentBlock: Identifiable {
    public let id: Int
    public let isImage: Bool
    public let text: String
    public let imageUrl: String?
}

public struct LoadedChapter: Identifiable {
    public var id: Int { chapter.index }
    public let chapter: BookChapter
    public var content: String
    public var blocks: [ContentBlock]
    public var pages: [[ContentBlock]] = []
}

public struct BlockFrameInfo: Equatable {
    public let chapterIndex: Int
    public let blockId: Int
    public let minY: CGFloat
    public let maxY: CGFloat
}

public struct ReaderScrollPreferenceKey: PreferenceKey {
    public static var defaultValue: [BlockFrameInfo] = []
    public static func reduce(value: inout [BlockFrameInfo], nextValue: () -> [BlockFrameInfo]) {
        value.append(contentsOf: nextValue())
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
    @State private var readingTickStart: Date? = nil
    @State private var newBookmarkNote: String = ""
    @State private var showSettings: Bool = false
    @State private var showSearch: Bool = false
    @State private var showTTSSettings: Bool = false
    @State private var showBookInfo: Bool = false
    @State private var showSourceSwitch: Bool = false
    @State private var showControls: Bool = false
    @State private var showBackgroundImagePicker: Bool = false
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

    public var body: some View {
        GeometryReader { outerGeo in
            ZStack {
                readerBackground
                    .ignoresSafeArea()

                // 1. Reading Canvas with Permanent Fixed Bottom Info Bar
                VStack(spacing: 0) {
                    // 按页翻的模式（左右/覆盖/滑动/仿真）页眉页脚画在每页里，跟着一起翻
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
                            // 翻页时看起来就是「最上面没跟着翻」
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
                safeInsets = newValue
            }
        }
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
                    Button {
                        downloadCachedChapters()
                    } label: {
                        Label("下载缓存（\(readerConfig.cachedChapterCount) 章）", systemImage: "arrow.down.circle")
                    }
                    Button {
                        showReplaceRules = true
                    } label: {
                        Label("替换净化规则", systemImage: "wand.and.sparkles")
                    }
                    Button {
                        showTTSSettings = true
                    } label: {
                        Label("听书设置", systemImage: "headphones")
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
        .task {
            readerConfig.loadLayout(for: activeBook.bookUrl)
            await loadTOCAndStart()
        }
        .onAppear { readingTickStart = Date() }
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
        // 否则会出现「段间距调小了，页面下半部分空着」——那是旧分页的行数还没更新
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
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
    }

    private func platformImage(atPath path: String) -> Image? {
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
                                                                maxY: geo.frame(in: .named("readerScrollCoordinate")).maxY
                                                            )]
                                                        )
                                                }
                                            )
                                    } else {
                                        bodyTextView(applyingKinsoku(block.text))
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
                                                                maxY: geo.frame(in: .named("readerScrollCoordinate")).maxY
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
            // 「距顶」怎么调都顶不到灵动岛上（页脚却是贴底的，看起来就是上下都有空）
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
                    // 把 19pt 的页脚挤出可视区（页脚"看不见"就是这么来的）
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
                                paragraphSeparatorColor: readerConfig.paragraphSeparatorColor
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
                // 以前是三块 Color.clear 各挂 onTapGesture，父级再挂 DragGesture：
                // 子视图的点按会把父级的拖拽抢走，结果就是「根本滑不动，只能点边缘」。
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
                        let moved = hypot(value.translation.width, value.translation.height)
                        // 位移很小 = 点击：左 30% 上一页，右 30% 下一页，中间开关工具栏
                        if moved < 8 {
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
                        // 甩得快用投影距离，慢慢拖就按实际位移判，别让人拖到一半松手却没反应
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
    /// 按页翻时整页贴屏幕物理边缘（= 安全区高度 + 上下安全区），用安全区高度当页高会少算约 120pt，
    /// 表现就是每页末尾空两三行——「段间距调小了，下面还是空的」就是这么来的。
    private func paginationContainerSize(for size: CGSize) -> CGSize {
        guard readerConfig.pageMode != .scroll else {
            return CGSize(width: size.width, height: max(200, size.height - 26))
        }
        let bleedTop = max(0, safeInsets.top)
        let bleedBottom = max(0, safeInsets.bottom)
        return CGSize(width: size.width, height: max(200, size.height + bleedTop + bleedBottom))
    }

    private func updateContainerSizeIfNeeded(_ size: CGSize) {
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
        // 末尾可能有空白页（分页收尾留下的），别让它把换章挡在后面：后面全是空页就当本章到头
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
    /// 两条一起出问题就是「距顶拉到 -70 页眉还在灵动岛下面」。
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
                if let edge = extendEdge {
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

            // Bookmarks / Notes (书签)
            Button(action: { showBookmarks = true }) {
                VStack(spacing: 4) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 20))
                    Text("书签")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(readerConfig.theme.textColor)
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

            // 刷新本章
            Button {
                refreshCurrentChapter()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 20))
                    Text("刷新")
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
                }

                let list = bookmarkStore.bookmarks(for: activeBook.bookUrl)
                Section(header: Text("本书书签与笔记 (\(list.count))")) {
                    if list.isEmpty {
                        Text("还没有书签。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    ForEach(list) { bm in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bm.chapterTitle)
                                .font(.system(size: 14, weight: .medium))
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
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showBookmarks = false
                            jumpToChapter(bm.chapterIndex)
                        }
                    }
                    .onDelete { indexSet in
                        let current = bookmarkStore.bookmarks(for: activeBook.bookUrl)
                        for i in indexSet where i < current.count {
                            bookmarkStore.removeBookmark(current[i])
                        }
                    }
                }
            }
            .navigationTitle("书签 / 笔记")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { showBookmarks = false }
                }
            }
        }
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
        // 现挑的数量顺手记成默认，下次点和设置里显示的都对得上
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

    /// 亮度：放在卡片靠上，随手能拖（原来埋在「显示」里）
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
                    Button("选择图片…") { showBackgroundImagePicker = true }
                        .font(.system(size: 12))
                        .buttonStyle(.plain)
                        .foregroundColor(readerConfig.textColor.opacity(0.8))
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
            }
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

    @MainActor
    private func getOrFetchChapter(at index: Int) async -> LoadedChapter? {
        guard index >= 0 && index < chapters.count else { return nil }
        if let cached = chapterCache[index] {
            return cached
        }
        let targetChapter = chapters[index]
        do {
            let content = try await BookContentService.shared.fetchChapterContent(chapter: targetChapter, source: effectiveSource)
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
                if let content = try? await BookContentService.shared.fetchChapterContent(chapter: prevCh, source: source) {
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
                if let content = try? await BookContentService.shared.fetchChapterContent(chapter: nextCh, source: source) {
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
                    let content = try await BookContentService.shared.fetchChapterContent(chapter: currentChapter, source: source)
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
                let content = try await BookContentService.shared.fetchChapterContent(chapter: nextChapter, source: source)
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
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

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
                    continue
                }
            }

            let paragraphs = readerConfig.smartParagraphs ? smartParagraphSplit(trimmed) : [trimmed]
            for paragraph in paragraphs {
                let indent = (paragraph.hasPrefix("　") || paragraph.hasPrefix("    ")) ? "" : "　　"
                blocks.append(ContentBlock(id: currentId, isImage: false, text: indent + paragraph, imageUrl: nil))
                currentId += 1
            }
        }
        return blocks
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

    /// 这里必须返回高度而不是行数——段间距也要占地方，按行数算会低估，
    /// 渲染出来超出预算的那半行就会压到页脚上（正文糊在页脚上）。
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
    private func splitParagraphIntoLines(text: String, width: Double) -> [(text: String, isParagraphEnd: Bool)] {
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
            return [(text, true)]
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attrString)
        var start = 0
        let textLen = CFStringGetLength(text as CFString)
        var result: [(text: String, isParagraphEnd: Bool)] = []
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
            result.append((sub, isEnd))
            start += count
            isFirstLine = false
        }
        return result
    }

    /// 标点禁则：行首不该出现句读/收尾类标点，行尾不该出现开引号、开括号。
    /// 行首禁则按「标点挤压」处理——把标点拉到上一行，那点宽度交给两端对齐吸收；
    /// 行尾禁则把那个字符挪到下一行。CoreText 自己不做中文禁则，得在这里补。
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
        // 行首禁则：后面紧跟的是句读类标点就拉到本行，一次最多拉两个，别把整行挤爆
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

    private func buildPageBlocks(from lines: [(text: String, isParagraphEnd: Bool)], startingId: inout Int) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        for line in lines {
            blocks.append(ContentBlock(
                id: startingId,
                isImage: false,
                text: line.text,
                imageUrl: line.isParagraphEnd ? "p_end" : nil
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
        var currentPageLines: [(text: String, isParagraphEnd: Bool)] = []
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
                    currentPageLines.append(lineInfo)
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
        uiView.textColor = UIColor(textColor)
        uiView.containerWidth = width
        uiView.containerHeight = height
        uiView.backgroundColor = .clear
        // 同上：内容没变就不重绘
        uiView.renderSignature = uiView.currentSignature()
    }
}

public class CoreTextUIView: UIView {
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
    public var textColor: UIColor = .label
    public var containerWidth: CGFloat = 340
    public var containerHeight: CGFloat = 600
    public var textAlignment: ReaderTextAlignment = .justify
    public var underlineEnabled: Bool = false
    public var underlineColor: UIColor?
    public var paragraphSeparatorLines: Int = 0
    public var paragraphSeparatorColor: UIColor?

    /// 内容指纹：跟上次一样就不重绘
    public var renderSignature: String = "" {
        didSet {
            if oldValue != renderSignature { setNeedsDisplay() }
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

    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !lines.isEmpty else { return }

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
