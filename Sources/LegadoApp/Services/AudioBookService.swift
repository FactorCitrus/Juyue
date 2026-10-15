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

/// 百度语音的四件套凭据。
///
/// 运行顺序：先看设置里填的（UserDefaults），没填才用这里的本地默认值。
/// 公开仓库里 `localDefaults` 是空字符串，谁用谁自己填。
enum BaiduCredentials {
    /// 本地默认凭据。公开版本保持为空，凭据在设置页里填。
    ///
    /// 不要在这里提交真实值——一旦提交，凭据就永久留在 Git 历史里。
    enum LocalDefaults {
        static let appId = ""
        static let apiKey = ""
        static let secretKey = ""
        static let serials: [String] = []
    }

    private static var defaults: UserDefaults { .standard }

    static var appId: String {
        let stored = defaults.string(forKey: "baidu_app_id") ?? ""
        return stored.isEmpty ? LocalDefaults.appId : stored
    }

    static var apiKey: String {
        let stored = defaults.string(forKey: "baidu_api_key") ?? ""
        return stored.isEmpty ? LocalDefaults.apiKey : stored
    }

    static var secretKey: String {
        let stored = defaults.string(forKey: "baidu_secret_key") ?? ""
        return stored.isEmpty ? LocalDefaults.secretKey : stored
    }

    /// 离线序列号，一行一条
    static var serials: [String] {
        let stored = defaults.string(forKey: "baidu_serials") ?? ""
        let list = stored
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return list.isEmpty ? LocalDefaults.serials : list
    }

    /// 后台设置页写回的入口
    static func store(appId: String, apiKey: String, secretKey: String, serials: String) {
        defaults.set(appId.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "baidu_app_id")
        defaults.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "baidu_api_key")
        defaults.set(secretKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "baidu_secret_key")
        defaults.set(serials.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "baidu_serials")
    }

    static var hasCustomValues: Bool {
        !(defaults.string(forKey: "baidu_app_id") ?? "").isEmpty
            || !(defaults.string(forKey: "baidu_api_key") ?? "").isEmpty
    }
}

/// 多角色朗读里的一条「角色 → 音色」规则
public struct TTSCastRole: Codable, Identifiable, Equatable {
    /// 这条规则什么时候用得上
    public enum Match: String, Codable, CaseIterable, Identifiable {
        case narration = "旁白"
        case dialogue = "对话"
        case keyword = "关键词"
        public var id: String { rawValue }
    }

    /// 走哪个引擎发音。HTTP 语音源是整章一起发的，按段换不了，所以这里只放能逐段换的两种。
    public enum Engine: String, Codable, CaseIterable, Identifiable {
        case system = "系统语音"
        case baiduOnline = "百度在线"
        public var id: String { rawValue }
    }

    public var id: UUID
    public var name: String
    public var match: Match
    public var keyword: String
    public var engine: Engine
    /// 系统语音填 AVSpeechSynthesisVoice.identifier，百度在线填发音人 id
    public var voiceId: String
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        match: Match = .narration,
        keyword: String = "",
        engine: Engine = .system,
        voiceId: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.match = match
        self.keyword = keyword
        self.engine = engine
        self.voiceId = voiceId
        self.enabled = enabled
    }
}

/// 多角色配置：总开关 + 角色表
public final class TTSCastStore: ObservableObject {
    public static let shared = TTSCastStore()

    @Published public var enabled: Bool { didSet { save() } }
    @Published public var roles: [TTSCastRole] { didSet { save() } }

    private let enabledKey = "tts_cast_enabled"
    private let rolesKey = "tts_cast_roles_v1"

    private init() {
        let defaults = UserDefaults.standard
        self.enabled = defaults.bool(forKey: enabledKey)
        if let data = defaults.data(forKey: rolesKey),
           let list = try? JSONDecoder().decode([TTSCastRole].self, from: data) {
            self.roles = list
        } else {
            self.roles = []
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: enabledKey)
        if let data = try? JSONEncoder().encode(roles) {
            defaults.set(data, forKey: rolesKey)
        }
    }

    /// 一条能直接用的起步配置：旁白 + 对话各一条
    public func makeStarterRoles() {
        var narration = TTSCastRole(name: "旁白", match: .narration)
        narration.engine = .system
        narration.voiceId = SystemVoiceSelection.identifier ?? ""

        var dialogue = TTSCastRole(name: "对话", match: .dialogue)
        dialogue.engine = .system
        dialogue.voiceId = ""

        roles = [narration, dialogue]
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

    // MARK: - 多角色朗读状态
    private struct CastSegment {
        let text: String
        let role: TTSCastRole?
    }
    private var castSegments: [CastSegment] = []
    private var castCursor = 0
    private var castActive = false
    private var castSegmentCompletion: (() -> Void)?
    private var castLanguage = "zh-CN"

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
        AppLog.write("[听书] 开始朗读，文本长度 \(text.count)")
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
        AppLog.write("[听书] 停止朗读")
        // 停就整条序一起停，别留着半截角色队列
        castActive = false
        castSegments = []
        castCursor = 0
        castSegmentCompletion = nil
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
        if castActive {
            // 多角色：这只是其中一段播完，接着下一段，别把整章当成结束
            completeCastSegment()
            return
        }
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isPaused = false
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if castActive {
            castActive = false
            castSegmentCompletion = nil
        }
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isPaused = false
        }
    }

    // MARK: - 多角色朗读

    /// 按「旁白 / 对话 / 关键词」把整章切段，逐段换音色往外播
    public func speakWithCast(_ text: String, language: String = "zh-CN") {
        AppLog.write("[听书] 开始多角色朗读，文本长度 \(text.count)，角色 \(TTSCastStore.shared.roles.count) 个")
        stop()
        let roles = TTSCastStore.shared.roles.filter { $0.enabled }
        let segments = AudioBookService.segmentsForCast(text, roles: roles)
        guard !segments.isEmpty else { return }
        castSegments = segments
        castCursor = 0
        castActive = true
        castLanguage = language
        currentText = text
        playNextCastSegment()
    }

    private func playNextCastSegment() {
        guard castActive, castCursor < castSegments.count else {
            castActive = false
            castSegmentCompletion = nil
            DispatchQueue.main.async {
                self.isPlaying = false
                self.isPaused = false
            }
            return
        }
        let item = castSegments[castCursor]
        castCursor += 1
        playCastSegment(item)
    }

    private func playCastSegment(_ item: CastSegment) {
        let spoken = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else {
            playNextCastSegment()
            return
        }

        castSegmentCompletion = { [weak self] in
            self?.playNextCastSegment()
        }

        #if os(iOS)
        if let role = item.role, role.engine == .baiduOnline,
           let speaker = BaiduOnlineTTS.speaker(id: role.voiceId) {
            baiduOnlinePlayer.onFinish = { [weak self] in
                self?.completeCastSegment()
            }
            baiduOnlinePlayer.start(speaker: speaker, text: spoken, speed: baiduOnlineSpeed, maxChunkLength: chunkLength)
            DispatchQueue.main.async {
                self.isPlaying = true
                self.isPaused = false
            }
            return
        }
        #endif

        let utterance = AVSpeechUtterance(string: spoken)
        if let role = item.role, role.engine == .system, !role.voiceId.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: role.voiceId) {
            utterance.voice = voice
        } else {
            utterance.voice = SystemVoiceSelection.selectedVoice ?? AVSpeechSynthesisVoice(language: castLanguage)
        }
        utterance.rate = speechRate

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        synthesizer.speak(utterance)
        DispatchQueue.main.async {
            self.isPlaying = true
            self.isPaused = false
        }
    }

    private func completeCastSegment() {
        let completion = castSegmentCompletion
        castSegmentCompletion = nil
        DispatchQueue.main.async { completion?() }
    }

    /// 切段规则：按行切，行内再按引号分出对话；对话给「对话」角色，其余给旁白或命中的关键词角色
    private static func segmentsForCast(_ text: String, roles: [TTSCastRole]) -> [CastSegment] {
        let narration = roles.first { $0.match == .narration }
        let dialogue = roles.first { $0.match == .dialogue }
        let keywordRoles = roles.filter { $0.match == .keyword && !$0.keyword.isEmpty }

        var result: [CastSegment] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            for piece in splitByQuotes(line) where !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let role: TTSCastRole?
                if piece.isDialogue {
                    role = dialogue
                } else if let hit = keywordRoles.first(where: { piece.text.contains($0.keyword) }) {
                    role = hit
                } else {
                    role = narration
                }
                result.append(CastSegment(text: piece.text, role: role))
            }
        }
        return result
    }

    /// 把一行按引号切成「对话 / 非对话」交替的片段
    private static func splitByQuotes(_ line: String) -> [(text: String, isDialogue: Bool)] {
        let openers: Set<Character> = ["「", "“", "『", "\""]
        let closers: Set<Character> = ["」", "”", "』", "\""]
        var pieces: [(String, Bool)] = []
        var buffer = ""
        var inQuote = false
        for ch in line {
            if !inQuote, openers.contains(ch) {
                if !buffer.isEmpty {
                    pieces.append((buffer, false))
                    buffer = ""
                }
                inQuote = true
                buffer.append(ch)
            } else if inQuote, closers.contains(ch) {
                buffer.append(ch)
                pieces.append((buffer, true))
                buffer = ""
                inQuote = false
            } else {
                buffer.append(ch)
            }
        }
        if !buffer.isEmpty {
            pieces.append((buffer, inQuote))
        }
        return pieces
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
