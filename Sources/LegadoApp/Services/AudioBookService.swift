import Foundation
import AVFoundation
import Combine
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 系统语音的音色选择。iOS 里中文音色有婷婷、Sandy、Shelley 这些，
/// 在「设置 → 辅助功能 → 朗读内容 → 声音 → 中文」里下载增强/高级版之后，同一个 id 会自动变成高质量那版。
enum SystemVoiceSelection {
    static let defaultsKey = "legado_system_voice_identifier"

    static var identifier: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    static var selectedVoice: AVSpeechSynthesisVoice? {
        guard let id = identifier else { return nil }
        return AVSpeechSynthesisVoice(identifier: id)
    }

    /// 中文音色，质量高的排前面。quality 要 iOS 16+ 才有。
    static var chineseVoices: [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
        return all.sorted { lhs, rhs in
            let lq = qualityRank(lhs), rq = qualityRank(rhs)
            if lq != rq { return lq > rq }
            if lhs.language != rhs.language { return lhs.language < rhs.language }
            return lhs.name < rhs.name
        }
    }

    static func qualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        guard #available(iOS 16.0, macOS 13.0, *) else { return 1 }
        switch voice.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        guard #available(iOS 16.0, macOS 13.0, *) else { return "默认" }
        switch voice.quality {
        case .premium: return "高级"
        case .enhanced: return "增强"
        default: return "默认"
        }
    }
}

public class AudioBookService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    public static let shared = AudioBookService()

    private let synthesizer = AVSpeechSynthesizer()
    /// 选中在线语音源时改走它，否则还是系统语音。
    private let httpPlayer = HttpTTSPlayer.shared
    #if os(iOS)
    /// 选中百度离线音色时改走它。
    private let baiduPlayer = BaiduOfflineTTS.shared
    /// 选中百度在线发音人时改走它。
    private let baiduOnlinePlayer = BaiduOnlineTTS.shared
    #endif
    private var cancellables = Set<AnyCancellable>()

    @Published public var isPlaying: Bool = false
    @Published public var isPaused: Bool = false
    /// 语速倍率，1.0 是系统默认。系统语音和在线语音源都按它换算。
    @Published public var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate {
        didSet { UserDefaults.standard.set(Double(speechRate), forKey: "tts_speech_rate") }
    }
    /// 单次合成的最大字数，段落太长就切段，避免接口超时或截断。
    @Published public var chunkLength: Int = 150 {
        didSet { UserDefaults.standard.set(chunkLength, forKey: "tts_chunk_length") }
    }
    @Published public var currentText: String = ""

    /// 试听用的固定句子
    public static let sampleText = "这是一段试听，用来确认音色和语速是否合适。"

    public override init() {
        super.init()
        synthesizer.delegate = self
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "tts_speech_rate") != nil {
            speechRate = Float(defaults.double(forKey: "tts_speech_rate"))
        }
        if defaults.object(forKey: "tts_chunk_length") != nil {
            chunkLength = defaults.integer(forKey: "tts_chunk_length")
        }
        setupAudioSession()
        mirrorHttpPlayerState()
    }

    /// 当前引擎名，设置面板和阅读界面都用它显示
    public var currentEngineName: String {
        #if os(iOS)
        if let voice = BaiduOfflineTTS.activeVoice {
            return "百度离线 · \(voice.name)"
        }
        if let speaker = BaiduOnlineTTS.activeSpeaker {
            return "百度在线 · \(speaker.name)"
        }
        #endif
        if let voice = SystemVoiceSelection.selectedVoice {
            return "系统语音 · \(voice.name)"
        }
        return TTSourceSelection.activeSource?.name ?? "系统语音"
    }

    /// 试听一句话
    public func preview() {
        speak(text: AudioBookService.sampleText)
    }

    /// 在线语音源的播放状态要同步给界面。
    private func mirrorHttpPlayerState() {
        httpPlayer.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                guard let self, TTSourceSelection.activeId != nil else { return }
                self.isPlaying = playing
            }
            .store(in: &cancellables)

        httpPlayer.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paused in
                guard let self, TTSourceSelection.activeId != nil else { return }
                self.isPaused = paused
            }
            .store(in: &cancellables)

        #if os(iOS)
        baiduPlayer.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                guard let self, BaiduOfflineTTS.activeVoiceId != nil else { return }
                self.isPlaying = playing
            }
            .store(in: &cancellables)

        baiduPlayer.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paused in
                guard let self, BaiduOfflineTTS.activeVoiceId != nil else { return }
                self.isPaused = paused
            }
            .store(in: &cancellables)

        baiduOnlinePlayer.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                guard let self, BaiduOnlineTTS.activeSpeakerId != nil else { return }
                self.isPlaying = playing
            }
            .store(in: &cancellables)

        baiduOnlinePlayer.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paused in
                guard let self, BaiduOnlineTTS.activeSpeakerId != nil else { return }
                self.isPaused = paused
            }
            .store(in: &cancellables)
        #endif
    }

    /// 把 AVSpeech 的语速换算成语音源的 speakSpeed（安卓端范围 5..50）。
    private var httpSpeed: Int {
        let ratio = speechRate / AVSpeechUtteranceDefaultSpeechRate
        return min(50, max(5, Int(ratio * 10)))
    }

    #if os(iOS)
    /// 换算成百度离线引擎的 paramSpeed，区间 0..15，5 是 1 倍速。
    private var baiduSpeed: Int {
        let ratio = Double(speechRate / AVSpeechUtteranceDefaultSpeechRate)
        return min(15, max(0, Int((ratio - 0.5) * 10)))
    }

    /// 换算成在线引擎的 paramSpeed，区间 0..25（最高 3 倍速）。
    private var baiduOnlineSpeed: Int {
        let ratio = Double(speechRate / AVSpeechUtteranceDefaultSpeechRate)
        return min(25, max(0, Int((ratio - 0.5) * 10)))
    }
    #endif

    private func setupAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioBookService] Failed to activate audio session: \(error)")
        }
        #endif
    }

    public func speak(text: String, language: String = "zh-CN") {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        self.currentText = text

        #if os(iOS)
        if let voice = BaiduOfflineTTS.activeVoice {
            baiduPlayer.start(voice: voice, text: text, speed: baiduSpeed, maxChunkLength: chunkLength)
            DispatchQueue.main.async {
                self.isPlaying = true
                self.isPaused = false
            }
            return
        }
        if let speaker = BaiduOnlineTTS.activeSpeaker {
            baiduOnlinePlayer.start(speaker: speaker, text: text, speed: baiduOnlineSpeed, maxChunkLength: chunkLength)
            DispatchQueue.main.async {
                self.isPlaying = true
                self.isPaused = false
            }
            return
        }
        #endif

        if let source = TTSourceSelection.activeSource {
            httpPlayer.start(source: source, text: text, speed: httpSpeed, maxChunkLength: chunkLength)
            DispatchQueue.main.async {
                self.isPlaying = true
                self.isPaused = false
            }
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SystemVoiceSelection.selectedVoice ?? AVSpeechSynthesisVoice(language: language)
        utterance.rate = speechRate

        // Ensure audio session is active
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        synthesizer.speak(utterance)
        DispatchQueue.main.async {
            self.isPlaying = true
            self.isPaused = false
        }
    }

    public func togglePlayPause(text: String, language: String = "zh-CN") {
        if isPlaying {
            pause()
        } else if isPaused && !currentText.isEmpty {
            resume()
        } else {
            speak(text: text, language: language)
        }
    }

    public func pause() {
        #if os(iOS)
        if BaiduOfflineTTS.activeVoiceId != nil {
            baiduPlayer.pause()
        }
        if BaiduOnlineTTS.activeSpeakerId != nil {
            baiduOnlinePlayer.pause()
        }
        #endif
        if TTSourceSelection.activeId != nil {
            httpPlayer.pause()
        }
        if synthesizer.isSpeaking && !synthesizer.isPaused {
            synthesizer.pauseSpeaking(at: .word)
            DispatchQueue.main.async {
                self.isPlaying = false
                self.isPaused = true
            }
        }
    }

    public func resume() {
        #if os(iOS)
        if BaiduOfflineTTS.activeVoiceId != nil {
            baiduPlayer.resume()
        }
        if BaiduOnlineTTS.activeSpeakerId != nil {
            baiduOnlinePlayer.resume()
        }
        #endif
        if TTSourceSelection.activeId != nil {
            httpPlayer.resume()
        }
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            DispatchQueue.main.async {
                self.isPlaying = true
                self.isPaused = false
            }
        }
    }

    public func stop() {
        #if os(iOS)
        baiduPlayer.stop()
        baiduOnlinePlayer.stop()
        #endif
        httpPlayer.stop()
        // Critical: in iOS AVFoundation, stopSpeaking while isPaused can deadlock mediaserverd.
        // If paused, we must resume before stopping immediately.
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
        }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isPaused = false
            self.currentText = ""
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isPaused = false
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isPaused = false
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isPaused = true
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isPlaying = true
            self.isPaused = false
        }
    }
}
