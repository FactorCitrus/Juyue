import SwiftUI
import AVKit
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 音频 / 图片 / 视频 / 文件源的阅读页。
///
/// 文本源仍走 ReaderView；这里按 `bookSourceType` 分流：
/// - 音频：AVPlayer 播放章节地址
/// - 视频：AVKit VideoPlayer
/// - 图片：按章节抓图，纵向连续阅读
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
    @StateObject private var player = MediaPlayerController()

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
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar
            }
            .background(Color.black.opacity(kind == .image ? 1 : 0.96))
            .navigationTitle(currentChapter?.title ?? book.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onDismiss() }
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
        }
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
                Image(systemName: "doc.questionmark")
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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(payload.urls.enumerated()), id: \.offset) { _, url in
                        RemoteMediaImage(
                            urlString: url,
                            headers: payload.headers,
                            rateKey: payload.rateKey,
                            rateLimit: payload.rateLimit
                        )
                            .frame(maxWidth: .infinity)
                    }
                }
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

    private var bottomBar: some View {
        HStack {
            Button {
                go(-1)
            } label: {
                Label("上一章", systemImage: "chevron.left")
            }
            .disabled(currentIndex <= 0)

            Spacer()

            Text("\(min(currentIndex + 1, chapters.count)) / \(chapters.count)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            Button {
                go(1)
            } label: {
                Label("下一章", systemImage: "chevron.right")
            }
            .disabled(currentIndex >= chapters.count - 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.55))
        .foregroundColor(.white)
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
        player.stop()
        do {
            let result = try await BookMediaService.shared.resolveChapter(
                chapter: chapter,
                book: book,
                source: source
            )
            payload = result
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

    func load(urlString: String, headers: [String: String], rateKey: String, rateLimit: SourceRateLimit?) async {
        if let rateLimit {
            await SourceRateLimiter.shared.acquire(key: rateKey, limit: rateLimit)
        }
        guard let url = URL(string: urlString) ?? URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            failed = true
            return
        }
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                failed = true
                return
            }
            #if canImport(UIKit)
            image = UIImage(data: data)
            #elseif canImport(AppKit)
            image = NSImage(data: data)
            #endif
            if image == nil { failed = true }
        } catch {
            failed = true
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
    @StateObject private var loader = RemoteImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                #if canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                #elseif canImport(AppKit)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                #endif
            } else if loader.failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.largeTitle)
                    Text("图片加载失败")
                        .font(.caption)
                }
                .foregroundColor(.white.opacity(0.6))
                .frame(height: 220)
            } else {
                ProgressView()
                    .frame(height: 220)
            }
        }
        .task(id: urlString) {
            await loader.load(urlString: urlString, headers: headers, rateKey: rateKey, rateLimit: rateLimit)
        }
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
            Image(systemName: "doc.arrow.down")
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
