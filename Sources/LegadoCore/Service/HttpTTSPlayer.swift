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
    /// 正在取音频。首段合成等十几秒是常态，界面靠它显示「合成中」。
    @Published public private(set) var isLoading = false

    /// 一次取音失败的全部现场。
    /// 光有一句错误文案不够：同一句「The request timed out」连着来三次，
    /// 界面没法说清是第几段、整段是不是都废了，日志复盘时也对不上段号。
    public struct Failure: Equatable {
        /// 单调递增。同一句文案连着来两次，外部也照样收得到两回。
        public let ticket: Int
        /// 第几块（从 0 开始）、这次一共切了几块
        public let chunkIndex: Int
        public let chunkTotal: Int
        public let message: String
    }

    /// 失败现场。谁订阅谁决定重念还是跳过；播放器自己不再拿它当「无事发生」往下跳。
    @Published public private(set) var failure: Failure?
    private var failureTicket = 0

    /// 一整段文字播完时回调，交给外部翻页或继续下一章。
    public var onFinish: (() -> Void)?

    private let engine: HttpTTSEngine
    private var source: HttpTTS?
    private var chunks: [String] = []
    private var player: AVAudioPlayer?
    private var loadTask: Task<Void, Never>?
    private var cancelled = false
    /// 记住本次朗读的语速，续段沿用；否则第二段起会掉回源默认值。
    private var currentSpeed: Int?

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
        LegadoLog.log("[听书] http.start len=\(text.count) chunks=\(TTSTextChunker.split(text, maxLength: maxChunkLength).count)")
        stop()
        cancelled = false
        self.source = source
        chunks = TTSTextChunker.split(text, maxLength: maxChunkLength)
        currentIndex = 0
        totalChunks = chunks.count
        lastError = nil
        failure = nil
        isLoading = false
        currentSpeed = speed
        guard !chunks.isEmpty else {
            LegadoLog.log("[听书] http.start 切不出块 · 文本 \(text.count) 字")
            onFinish?()
            return
        }
        playChunk(at: 0, speed: speed)
    }

    public func stop() {
        LegadoLog.log("[听书] http.stop cancelled=\(cancelled) playing=\(isPlaying)")
        cancelled = true
        loadTask?.cancel()
        loadTask = nil
        player?.stop()
        player = nil
        isLoading = false
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
        let total = chunks.count
        isLoading = true

        loadTask = Task { [weak self] in
            guard let self else { return }
            LegadoLog.log("[听书] playChunk \(index) cancelled=\(self.cancelled) len=\(text.count)")
            do {
                let audio = try await self.engine.fetchAudio(
                    source: source,
                    text: text,
                    speed: speed
                )
                if Task.isCancelled || self.cancelled {
                    LegadoLog.log("[听书] 取音后已取消 段\(index)")
                    return
                }
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(true)
                #endif
                // 诊断用：确认音频真的取回来了，以及取回来的字节数对不对。
                LegadoLog.log("[听书] 取音成功 \(audio.data.count)B · ct=\(audio.contentType ?? "-") · 段\(index + 1)/\(total)")
                let player = try AVAudioPlayer(data: audio.data)
                player.delegate = self
                player.prepareToPlay()
                self.player = player
                player.play()
                // 诊断用：duration=0 就是解码出空音频，play() 会立刻返回。
                let duration = player.duration
                LegadoLog.log("[听书] 播放开始 dur=\(String(format: "%.2f", duration)) vol=\(player.volume) 段\(index + 1)/\(total)")
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.isPlaying = true
                    self.isPaused = false
                }
                // 接口回了音频、内容却是空的：play() 立刻返回，delegate 一到就等于跳过这一段。
                // 这种和取音失败一样算失败，别让它在日志里伪装成「播放正常」。
                if duration < HttpTTSPlayer.minimumPlayableDuration {
                    LegadoLog.log("[听书] 取音失败 · 音频时长 \(String(format: "%.2f", duration))s，当空音频处理 · 段\(index + 1)/\(total)")
                    player.stop()
                    self.player = nil
                    self.reportFailure(index: index, total: total,
                                       message: "音频为空（时长 \(String(format: "%.2f", duration))s）")
                    if self.cancelled { return }
                    self.advance()
                    return
                }
            } catch {
                if Task.isCancelled || self.cancelled { return }
                // 诊断用：失败原本是静默跳段，这里把原因写出来。
                LegadoLog.log("[听书] 取音失败 · 段\(index + 1)/\(total) · \(error.localizedDescription)")
                self.reportFailure(index: index, total: total, message: error.localizedDescription)
                // 外部（AudioBookService）收到失败会立刻 stop() 并改系统语音重念这一段。
                // 它既然接了手，这里就绝不能再往下跳，否则就是用户说的「静默跳段」。
                if self.cancelled { return }
                // 没人接手才按老规矩跳到下一块，行为和安卓端「用无声音频代替」一致。
                self.advance()
            }
        }
    }

    /// 低于这个时长就当空音频：正文段最短也有十几个字，正常不会短过 0.15 秒。
    private static let minimumPlayableDuration: TimeInterval = 0.15

    /// 把失败交到主线程，并且**同步等它处理完**。
    ///
    /// 以前这里是 `DispatchQueue.main.async`：失败还没送到界面，下一块的请求已经发出去了，
    /// 外部就算想接手也拦不住「已经跳过去」这件事，一段接一段跳完，球就回耳机了。
    /// 现在同步投递，处理方 stop() 之后 `cancelled` 立刻为真，下面的 advance() 直接被拦住。
    private func reportFailure(index: Int, total: Int, message: String) {
        let report = {
            guard !self.cancelled else { return }
            self.failureTicket += 1
            self.isLoading = false
            self.isPlaying = false
            self.lastError = message
            self.failure = Failure(ticket: self.failureTicket,
                                   chunkIndex: index,
                                   chunkTotal: total,
                                   message: message)
        }
        if Thread.isMainThread {
            report()
        } else {
            DispatchQueue.main.sync(execute: report)
        }
    }

    private func advance() {
        let next = currentIndex + 1
        if next < chunks.count {
            playChunk(at: next, speed: currentSpeed)
        } else {
            finish()
        }
    }

    private func finish() {
        DispatchQueue.main.async {
            self.isLoading = false
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
        let message = error?.localizedDescription ?? "音频解码失败"
        LegadoLog.log("[听书] 解码失败 · 段\(currentIndex + 1)/\(chunks.count) · \(message)")
        reportFailure(index: currentIndex, total: chunks.count, message: message)
        if cancelled { return }
        advance()
    }
}
#endif
