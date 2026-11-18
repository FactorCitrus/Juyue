import SwiftUI
import AVKit
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(JuyueCore)
import JuyueCore
#endif

/// 漫画阅读模式：竖排连续（条漫）或左右翻页（页漫）。
enum ComicReadMode: String {
    case vertical
    case paged
}

/// 翻页时单页图片怎么摆。
enum ComicFitMode: String, CaseIterable {
    case width
    case height
    case original
}

/// 音频 / 图片 / 视频 / 文件源的阅读页。
///
/// 文本源仍走 ReaderView；这里按 `bookSourceType` 分流：
/// - 音频：AVPlayer 播放章节地址
/// - 视频：AVKit VideoPlayer
/// - 图片：按章节抓图，支持竖排连续与左右翻页
/// - 文件：下载到临时目录后交给系统分享 / 打开
struct MediaBookReaderView: View {
    let book: Book
    let source: BookSource
    let chapters: [BookChapter]
    let initialChapterIndex: Int
    let onDismiss: () -> Void

    @State private var currentIndex: Int
    @State private var payload: MediaChapterPayload?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showChapterList = false
    @State private var pageIndex = 0
    @State private var showPageJump = false
    @State private var controlsVisible = false
    @State private var verticalPage = 0
    @AppStorage("comic.readMode") private var comicReadModeRaw = ComicReadMode.vertical.rawValue
    @AppStorage("comic.rtl") private var comicRTL = true
    @AppStorage("comic.fit") private var comicFitRaw = ComicFitMode.width.rawValue
    @StateObject private var player = MediaPlayerController()

    private var comicReadMode: ComicReadMode {
        ComicReadMode(rawValue: comicReadModeRaw) ?? .vertical
    }

    private var comicFit: ComicFitMode {
        ComicFitMode(rawValue: comicFitRaw) ?? .width
    }

    init(
        book: Book,
        source: BookSource,
        chapters: [BookChapter],
        initialChapterIndex: Int = 0,
        onDismiss: @escaping () -> Void
    ) {
        self.book = book
        self.source = source
        self.chapters = chapters
        self.initialChapterIndex = initialChapterIndex
        self.onDismiss = onDismiss
        let safeIndex = chapters.isEmpty ? 0 : min(max(0, initialChapterIndex), chapters.count - 1)
        self._currentIndex = State(initialValue: safeIndex)
    }

    private var currentChapter: BookChapter? {
        guard chapters.indices.contains(currentIndex) else { return nil }
        return chapters[currentIndex]
    }

    private var kind: BookSource.Kind { source.kind }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControls() }

                if controlsVisible {
                    bottomBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(Color.black.opacity(kind == .image ? 1 : 0.96))
            .ignoresSafeArea(edges: kind == .image ? .horizontal : [])
            .navigationTitle(currentChapter?.title ?? book.name)
            #if os(iOS)
            .navigationBarHidden(!controlsVisible)
            .navigationBarTitleDisplayMode(.inline)
            .statusBar(hidden: !controlsVisible)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onDismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if kind == .image, comicReadMode == .paged, !(payload?.urls.isEmpty ?? true) {
                        Button {
                            showPageJump = true
                        } label: {
                            Image(systemName: "number")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if kind == .image {
                        Menu {
                            comicSettingsMenu
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showChapterList = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                }
            }
            .sheet(isPresented: $showChapterList) {
                mediaChapterSheet
            }
            .sheet(isPresented: $showPageJump) {
                ComicPageJumpSheet(
                    pageCount: payload?.urls.count ?? 0,
                    currentPage: pageIndex
                ) { target in
                    pageIndex = target
                }
            }
        }
            .stackNavigationStyle()
        .task(id: currentIndex) {
            await load()
        }
        .onDisappear {
            player.stop()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在加载\(kind.label)…")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
            }
        } else if let errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("重试") {
                    Task { await load() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if let payload, !payload.urls.isEmpty {
            mediaContent(payload)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "questionmark.circle")
                    .font(.largeTitle)
                    .foregroundColor(.white.opacity(0.5))
                Text("这一章没找到\(kind.label)地址")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
                if let raw = payload?.rawContent, !raw.isEmpty {
                    Text(String(raw.prefix(300)))
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.45))
                        .padding(.horizontal, 24)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    @ViewBuilder
    private func mediaContent(_ payload: MediaChapterPayload) -> some View {
        switch kind {
        case .audio:
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 96))
                    .foregroundColor(.accentColor)
                Text(currentChapter?.title ?? "音频")
                    .font(.headline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                AudioControls(controller: player)
                    .padding(.horizontal, 28)
                Spacer()
            }
        case .video:
            VideoPlayer(player: player.player)
                .onAppear { loadPlayer(payload) }
        case .image:
            GeometryReader { proxy in
                comicContent(payload, size: proxy.size)
            }
        case .file:
            FileMediaView(
                urlString: payload.urls.first ?? "",
                headers: payload.headers,
                title: currentChapter?.title ?? book.name,
                rateKey: payload.rateKey,
                rateLimit: payload.rateLimit
            )
        case .text:
            EmptyView()
        }
    }

    @ViewBuilder
    private func comicContent(_ payload: MediaChapterPayload, size: CGSize) -> some View {
        if comicReadMode == .vertical {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(payload.urls.enumerated()), id: \.offset) { index, url in
                        RemoteMediaImage(
                            urlString: url,
                            headers: payload.headers,
                            rateKey: payload.rateKey,
                            rateLimit: payload.rateLimit,
                            fixedWidth: size.width
                        )
                        .onAppear { verticalPage = index }
                    }
                }
            }
        } else {
            ComicPagedView(
                urls: payload.urls,
                headers: payload.headers,
                rateKey: payload.rateKey,
                rateLimit: payload.rateLimit,
                fit: comicFit,
                rtl: comicRTL,
                doublePage: size.width > size.height,
                containerSize: size,
                pageIndex: $pageIndex
            )
        }
    }

    @ViewBuilder
    private var comicSettingsMenu: some View {
        Picker("阅读模式", selection: $comicReadModeRaw) {
            Text("连续竖排").tag(ComicReadMode.vertical.rawValue)
            Text("左右翻页").tag(ComicReadMode.paged.rawValue)
        }
        if comicReadMode == .paged {
            Picker("翻页方向", selection: $comicRTL) {
                Text("从右往左（日漫）").tag(true)
                Text("从左往右").tag(false)
            }
            Picker("图片缩放", selection: $comicFitRaw) {
                Text("适应宽度").tag(ComicFitMode.width.rawValue)
                Text("适应高度").tag(ComicFitMode.height.rawValue)
                Text("原始尺寸").tag(ComicFitMode.original.rawValue)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                go(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(currentIndex <= 0)
            .opacity(currentIndex <= 0 ? 0.3 : 1)

            Button {
                showChapterList = true
            } label: {
                VStack(spacing: 2) {
                    Text(currentChapter?.title ?? book.name)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    Text(progressText)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button {
                go(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(currentIndex >= chapters.count - 1)
            .opacity(currentIndex >= chapters.count - 1 ? 0.3 : 1)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    private var progressText: String {
        let chapterPart = "\(min(currentIndex + 1, chapters.count)) / \(chapters.count) 章"
        guard kind == .image, let count = payload?.urls.count, count > 0 else {
            return chapterPart
        }
        let page = comicReadMode == .vertical ? verticalPage : pageIndex
        return chapterPart + "  ·  \(min(page + 1, count)) / \(count) 页"
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.22)) {
            controlsVisible.toggle()
        }
    }

    private var mediaChapterSheet: some View {
        NavigationView {
            List {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        currentIndex = index
                        showChapterList = false
                    } label: {
                        HStack {
                            Text(chapter.title)
                                .foregroundColor(index == currentIndex ? .accentColor : .primary)
                            Spacer()
                            if index == currentIndex {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("章节")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showChapterList = false }
                }
            }
        }
            .stackNavigationStyle()
    }

    private func go(_ delta: Int) {
        let next = currentIndex + delta
        guard chapters.indices.contains(next) else { return }
        currentIndex = next
        BookStore.shared.updateProgress(
            bookUrl: book.bookUrl,
            chapterIndex: next,
            chapterTitle: chapters[next].title
        )
    }

    private func load() async {
        guard let chapter = currentChapter else {
            errorMessage = "没有可用的章节"
            return
        }
        isLoading = true
        errorMessage = nil
        payload = nil
        pageIndex = 0
        verticalPage = 0
        player.stop()
        do {
            let result = try await BookMediaService.shared.resolveChapter(
                chapter: chapter,
                book: book,
                source: source
            )
            payload = result
            JuyueLog.log("[Media] [\(source.bookSourceName)] 第 \(chapter.index + 1) 章 解析到 \(result.urls.count) 个\(kind.label)地址")
            if kind == .audio || kind == .video {
                loadPlayer(result)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadPlayer(_ payload: MediaChapterPayload) {
        guard let raw = payload.urls.first,
              let url = URL(string: raw) ?? URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw) else {
            return
        }
        player.load(url: url, headers: payload.headers, autoplay: true)
    }
}

// MARK: - 播放器

final class MediaPlayerController: ObservableObject {
    let player = AVPlayer()
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var errorMessage: String?

    private var timeObserver: Any?

    func load(url: URL, headers: [String: String], autoplay: Bool) {
        stop()
        errorMessage = nil
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        duration = 0
        currentTime = 0

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            let itemDuration = self.player.currentItem?.duration.seconds ?? 0
            if itemDuration.isFinite, itemDuration > 0 {
                self.duration = itemDuration
            }
        }

        if autoplay {
            player.play()
            isPlaying = true
        }
    }

    func toggle() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func stop() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var timeText: String {
        "\(format(currentTime)) / \(format(duration))"
    }
}

private struct AudioControls: View {
    @ObservedObject var controller: MediaPlayerController

    var body: some View {
        VStack(spacing: 14) {
            Slider(
                value: Binding(
                    get: { controller.currentTime },
                    set: { controller.seek(to: $0) }
                ),
                in: 0...max(controller.duration, 1)
            )
            .tint(.accentColor)

            HStack {
                Text(controller.timeText)
                    .font(.caption.monospacedDigit())
                Spacer()
            }
            .foregroundColor(.white.opacity(0.7))

            Button {
                controller.toggle()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }
}

// MARK: - 远程图片

private final class RemoteImageLoader: ObservableObject {
    @Published var image: PlatformImage?
    @Published var failed = false

    func reset() {
        image = nil
        failed = false
    }

    func load(urlString: String, headers: [String: String], rateKey: String, rateLimit: SourceRateLimit?) async {
        if let rateLimit {
            await SourceRateLimiter.shared.acquire(key: rateKey, limit: rateLimit)
        }
        guard let url = URL(string: urlString) ?? URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            failed = true
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // 条漫一屏十几张，偶发一次超时不该让整页留空。
        for attempt in 0..<2 {
            if Task.isCancelled { return }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        continue
                    }
                    failed = true
                    return
                }
                #if canImport(UIKit)
                image = UIImage(data: data)
                #elseif canImport(AppKit)
                image = NSImage(data: data)
                #endif
                if image == nil { failed = true }
                return
            } catch {
                if attempt == 0, !(error is CancellationError) {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    continue
                }
                failed = true
                return
            }
        }
    }
}

#if canImport(UIKit)
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
typealias PlatformImage = NSImage
#endif

private struct RemoteMediaImage: View {
    let urlString: String
    let headers: [String: String]
    let rateKey: String
    let rateLimit: SourceRateLimit?
    var fit: ComicFitMode = .width
    var containerSize: CGSize? = nil
    var fixedWidth: CGFloat? = nil
    @StateObject private var loader = RemoteImageLoader()

    private var placeholderSize: CGSize {
        CGSize(
            width: fixedWidth ?? containerSize?.width ?? 320,
            height: containerSize?.height ?? (fixedWidth.map { $0 * 1.35 } ?? 220)
        )
    }

    var body: some View {
        Group {
            if let image = loader.image {
                fittedImage(image)
            } else if loader.failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("图片加载失败")
                        .font(.caption)
                }
                .foregroundColor(.white.opacity(0.6))
                .frame(width: placeholderSize.width, height: placeholderSize.height)
            } else {
                ProgressView()
                    .frame(width: placeholderSize.width, height: placeholderSize.height)
            }
        }
        .task(id: urlString) {
            loader.reset()
            await loader.load(urlString: urlString, headers: headers, rateKey: rateKey, rateLimit: rateLimit)
        }
    }

    @ViewBuilder
    private func fittedImage(_ image: PlatformImage) -> some View {
        let content = platformImage(image)

        if let fixedWidth, fixedWidth > 1 {
            content
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: fixedWidth)
        } else if let containerSize, containerSize.width > 1, containerSize.height > 1 {
            scrollableImage(content, image: image, in: containerSize)
        } else {
            content
                .resizable()
                .scaledToFit()
        }
    }

    private func scrollableImage(_ content: Image, image: PlatformImage, in containerSize: CGSize) -> some View {
        let size = displaySize(of: image, in: containerSize)
        var axes: Axis.Set = []
        if size.height > containerSize.height + 1 { axes.insert(.vertical) }
        if size.width > containerSize.width + 1 { axes.insert(.horizontal) }
        return ScrollView(axes, showsIndicators: false) {
            content
                .resizable()
                .frame(width: size.width, height: size.height)
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }

    private func platformImage(_ image: PlatformImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }

    private func displaySize(of image: PlatformImage, in container: CGSize) -> CGSize {
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return container }
        switch fit {
        case .width:
            let scale = container.width / natural.width
            return CGSize(width: container.width, height: natural.height * scale)
        case .height:
            let scale = container.height / natural.height
            return CGSize(width: natural.width * scale, height: container.height)
        case .original:
            return natural
        }
    }
}

// MARK: - 漫画翻页

/// 左右翻页：不依赖系统分页控件，手写位移 + 手势，RTL/LTR 与双页都能直接控制。
private struct ComicPagedView: View {
    let urls: [String]
    let headers: [String: String]
    let rateKey: String
    let rateLimit: SourceRateLimit?
    let fit: ComicFitMode
    let rtl: Bool
    let doublePage: Bool
    let containerSize: CGSize
    @Binding var pageIndex: Int

    @GestureState private var dragOffset: CGFloat = 0

    /// 阅读顺序的分页单元。双页时两页一组；右到左时组内右手边是前一页。
    private var units: [[Int]] {
        guard doublePage else { return urls.indices.map { [$0] } }
        var result: [[Int]] = []
        var page = 0
        while page < urls.count {
            if page + 1 < urls.count {
                result.append(rtl ? [page + 1, page] : [page, page + 1])
            } else {
                result.append([page])
            }
            page += 2
        }
        return result
    }

    /// 显示顺序：右到左时把阅读顺序倒过来，手指右滑才是翻到下一页。
    private var displayIndex: Int {
        displayIndex(forPage: pageIndex)
    }

    private var visibleDisplays: [Int] {
        [displayIndex - 1, displayIndex, displayIndex + 1].filter { units.indices.contains($0) }
    }

    var body: some View {
        ZStack {
            Color.black
            ForEach(visibleDisplays, id: \.self) { display in
                unitView(display)
                    .frame(width: containerSize.width, height: containerSize.height)
                    .offset(x: CGFloat(display - displayIndex) * containerSize.width + dragOffset)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12)
                .updating($dragOffset) { value, state, _ in
                    state = value.translation.width
                }
                .onEnded { value in
                    let threshold = max(containerSize.width * 0.18, 40)
                    if value.predictedEndTranslation.width < -threshold {
                        setDisplay(displayIndex + 1)
                    } else if value.predictedEndTranslation.width > threshold {
                        setDisplay(displayIndex - 1)
                    }
                }
        )
        .animation(.easeOut(duration: 0.22), value: displayIndex)
    }

    private func unitView(_ display: Int) -> some View {
        let unit = units[unitIndex(forDisplay: display)]
        let width = containerSize.width / CGFloat(max(unit.count, 1))
        return HStack(spacing: 0) {
            ForEach(unit, id: \.self) { page in
                RemoteMediaImage(
                    urlString: urls[page],
                    headers: headers,
                    rateKey: rateKey,
                    rateLimit: rateLimit,
                    fit: fit,
                    containerSize: CGSize(width: width, height: containerSize.height)
                )
            }
        }
    }

    private func unitIndex(forDisplay display: Int) -> Int {
        rtl ? units.count - 1 - display : display
    }

    private func displayIndex(forPage page: Int) -> Int {
        let unit = units.firstIndex { $0.contains(page) } ?? 0
        return rtl ? units.count - 1 - unit : unit
    }

    private func setDisplay(_ display: Int) {
        guard !units.isEmpty else { return }
        let clamped = min(max(display, 0), units.count - 1)
        let unit = units[unitIndex(forDisplay: clamped)]
        pageIndex = unit.min() ?? pageIndex
    }
}

// MARK: - 跳页

private struct ComicPageJumpSheet: View {
    let pageCount: Int
    let currentPage: Int
    let onJump: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    private var typedPage: Int? {
        Int(input.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text("共 \(pageCount) 页，当前第 \(min(currentPage + 1, max(pageCount, 1))) 页")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                TextField("页码 1–\(pageCount)", text: $input)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Button("跳转") {
                    guard let page = typedPage, (1...max(pageCount, 1)).contains(page) else { return }
                    onJump(page - 1)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(typedPage == nil)
                Spacer()
            }
            .padding(20)
            .navigationTitle("跳页")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .stackNavigationStyle()
    }
}

// MARK: - 文件下载

private struct FileMediaView: View {
    let urlString: String
    let headers: [String: String]
    let title: String
    let rateKey: String
    let rateLimit: SourceRateLimit?

    @State private var isDownloading = false
    @State private var localURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if let localURL {
                if #available(iOS 16.0, macOS 13.0, *) {
                    ShareLink(item: localURL) {
                        Label("打开 / 分享文件", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        openWithSystem(localURL)
                    } label: {
                        Label("打开文件", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text(localURL.lastPathComponent)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
            } else {
                Button {
                    Task { await download() }
                } label: {
                    HStack(spacing: 8) {
                        if isDownloading { ProgressView() }
                        Text(isDownloading ? "正在下载…" : "下载文件")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDownloading || urlString.isEmpty)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Spacer()
        }
        .task(id: urlString) {
            localURL = nil
            errorMessage = nil
        }
    }

    private func download() async {
        guard let url = URL(string: urlString) ?? URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            errorMessage = "文件地址无效"
            return
        }
        isDownloading = true
        errorMessage = nil
        if let rateLimit {
            await SourceRateLimiter.shared.acquire(key: rateKey, limit: rateLimit)
        }
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                throw NSError(domain: "MediaFile", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP 下载失败"])
            }
            let name = response.suggestedFilename
                ?? URL(string: urlString)?.lastPathComponent
                ?? "download"
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MediaDownloads", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(name.isEmpty ? "download" : name)
            try data.write(to: target, options: .atomic)
            localURL = target
        } catch {
            errorMessage = error.localizedDescription
        }
        isDownloading = false
    }

    private func openWithSystem(_ url: URL) {
        #if canImport(UIKit)
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
           let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
            root.present(controller, animated: true)
        }
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
