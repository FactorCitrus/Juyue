import Foundation
import Combine

#if canImport(AVFoundation)
import AVFoundation
#endif

/// 用在线语音源逐段合成并播放。
///
/// 与安卓端 HttpReadAloudService 的差别：安卓走 ExoPlayer + 缓存数据源，
/// 这里是先取回整段音频再交给 AVAudioPlayer 播，先保证能用。
#if canImport(AVFoundation)
public final class HttpTTSPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    public static let shared = HttpTTSPlayer()

    @Published public private(set) var isPlaying = false
    @Published public private(set) var isPaused = false
    @Published public private(set) var currentIndex = 0
    @Published public private(set) var totalChunks = 0
    @Published public private(set) var lastError: String?

    /// 一整段文字播完时回调，交给外部翻页或继续下一章。
    public var onFinish: (() -> Void)?

    private let engine: HttpTTSEngine
    private var source: HttpTTS?
    private var chunks: [String] = []
    private var player: AVAudioPlayer?
    private var loadTask: Task<Void, Never>?
    private var cancelled = false

    public init(engine: HttpTTSEngine = .shared) {
        self.engine = engine
        super.init()
        configureAudioSession()
    }

    private func configureAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("[HttpTTSPlayer] 音频会话激活失败：\(error)")
        }
        #endif
    }

    public func start(source: HttpTTS, text: String, speed: Int? = nil, maxChunkLength: Int = 150) {
        stop()
        cancelled = false
        self.source = source
        chunks = TTSTextChunker.split(text, maxLength: maxChunkLength)
        currentIndex = 0
        totalChunks = chunks.count
        lastError = nil
        guard !chunks.isEmpty else {
            onFinish?()
            return
        }
        playChunk(at: 0, speed: speed)
    }

    public func stop() {
        cancelled = true
        loadTask?.cancel()
        loadTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        isPaused = false
    }

    public func pause() {
        guard let player, player.isPlaying else { return }
        player.pause()
        isPlaying = false
        isPaused = true
    }

    public func resume() {
        guard let player, !player.isPlaying else { return }
        player.play()
        isPlaying = true
        isPaused = false
    }

    private func playChunk(at index: Int, speed: Int?) {
        guard !cancelled, let source, index < chunks.count else {
            finish()
            return
        }
        currentIndex = index
        let text = chunks[index]

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.engine.fetchAudio(
                    source: source,
                    text: text,
                    speed: speed
                )
                if Task.isCancelled || self.cancelled { return }
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(true)
                #endif
                let player = try AVAudioPlayer(data: audio.data)
                player.delegate = self
                player.prepareToPlay()
                self.player = player
                player.play()
                DispatchQueue.main.async {
                    self.isPlaying = true
                    self.isPaused = false
                }
            } catch {
                if Task.isCancelled || self.cancelled { return }
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.isPlaying = false
                }
                // 单段失败不整段停，跳到下一段，行为和安卓端「用无声音频代替」一致。
                self.advance()
            }
        }
    }

    private func advance() {
        let next = currentIndex + 1
        if next < chunks.count {
            playChunk(at: next, speed: nil)
        } else {
            finish()
        }
    }

    private func finish() {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isPaused = false
            self.onFinish?()
        }
    }

    // MARK: - AVAudioPlayerDelegate

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard !cancelled else { return }
        advance()
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async {
            self.lastError = error?.localizedDescription ?? "音频解码失败"
        }
        advance()
    }
}
#endif
