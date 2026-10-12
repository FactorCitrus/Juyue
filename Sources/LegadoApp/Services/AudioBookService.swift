import Foundation
import AVFoundation
import Combine
#if canImport(LegadoCore)
import LegadoCore
#endif

public class AudioBookService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    public static let shared = AudioBookService()

    private let synthesizer = AVSpeechSynthesizer()
    /// 选中在线语音源时改走它，否则还是系统语音。
    private let httpPlayer = HttpTTSPlayer.shared
    private var cancellables = Set<AnyCancellable>()

    @Published public var isPlaying: Bool = false
    @Published public var isPaused: Bool = false
    @Published public var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    @Published public var currentText: String = ""

    public override init() {
        super.init()
        synthesizer.delegate = self
        setupAudioSession()
        mirrorHttpPlayerState()
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
    }

    /// 把 AVSpeech 的语速换算成语音源的 speakSpeed（安卓端范围 5..50）。
    private var httpSpeed: Int {
        let ratio = speechRate / AVSpeechUtteranceDefaultSpeechRate
        return min(50, max(5, Int(ratio * 10)))
    }

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

        if let source = TTSourceSelection.activeSource {
            httpPlayer.start(source: source, text: text, speed: httpSpeed)
            DispatchQueue.main.async {
                self.isPlaying = true
                self.isPaused = false
            }
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
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
