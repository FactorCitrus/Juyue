import Foundation
import AVFoundation

public class AudioBookService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    public static let shared = AudioBookService()

    private let synthesizer = AVSpeechSynthesizer()

    @Published public var isPlaying: Bool = false
    @Published public var isPaused: Bool = false
    @Published public var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    @Published public var currentText: String = ""

    public override init() {
        super.init()
        synthesizer.delegate = self
        setupAudioSession()
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
        if synthesizer.isSpeaking && !synthesizer.isPaused {
            synthesizer.pauseSpeaking(at: .word)
            DispatchQueue.main.async {
                self.isPlaying = false
                self.isPaused = true
            }
        }
    }

    public func resume() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            DispatchQueue.main.async {
                self.isPlaying = true
                self.isPaused = false
            }
        }
    }

    public func stop() {
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
