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

    /// 交给 AVSpeech 的音色：手选的 > 本机最好的中文音色 > 系统默认。
    /// 手机上没下过增强/高级音色时，前一条会退到默认音色，至少不会哑。
    static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        if let picked = selectedVoice { return picked }
        if let best = chineseVoices.first { return best }
        return AVSpeechSynthesisVoice(language: language)
    }

    /// 本机有没有装增强/高级中文音色。没装就只能听到默认那版，得提示去系统里下。
    static var hasHighQualityVoice: Bool {
        chineseVoices.contains { qualityRank($0) >= 2 }
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

/// 朗读引擎三条路：包内离线模型、系统合成、在线源。
/// 包内模型和系统合成都断网可用，区别是音色从哪来：一个跟着 App 走，一个跟着 iOS 走。
public enum TTSEngineChoice: String, CaseIterable, Identifiable {
    case builtIn = "builtin"
    case system = "system"
    case http = "http"

    public var id: String { rawValue }

    static let defaultsKey = "legado_tts_engine_choice"

    public var title: String {
        switch self {
        case .builtIn: return BundledTTSEngine.displayName
        case .system: return "系统语音"
        case .http: return "在线语音源"
        }
    }

    public var detail: String {
        switch self {
        case .builtIn: return BundledTTSEngine.detailText
        case .system: return "iOS 自带 AVSpeechSynthesizer，音色要系统里下载"
        case .http: return "HTTP 接口，电脑或服务器得在线"
        }
    }

    /// 存过就用存的；没存过优先包内模型，模型不在包里就退系统语音。
    public static var current: TTSEngineChoice {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let saved = TTSEngineChoice(rawValue: raw) {
                if saved == .builtIn && !BundledTTSEngine.isModelBundled { return .system }
                return saved
            }
            return BundledTTSEngine.isModelBundled ? .builtIn : .system
        }
        set {
            let previous = TTSEngineChoice.current
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            // 离开在线源这条路就把源 id 摘掉，免得 pause/stop 还往 httpPlayer 上撞
            if newValue != .http { TTSourceSelection.activeId = nil }
            // 换引擎之后声音不对，先看这一条：上一档、新一档、还有没有挂着的源
            if previous != newValue {
                // 只记事件本身：紧接着有一条「语音源」记录说明挂了哪条，两个字段拼一起反而对不上
                LegadoLog.log("[听书] 引擎切换 \(previous.rawValue) → \(newValue.rawValue)")
            }
        }
    }

    /// 真在走 HTTP：选了在线源、而且那条源在真机上没被回环地址判死。
    public static var isUsingHTTP: Bool {
        TTSEngineChoice.current == .http && TTSourceSelection.activeSource != nil
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

    /// 走哪个引擎发音。
    ///
    /// 以前这里只有系统语音，理由是「在线源整章一起发，按段换不了」。三条通道
    /// 现在都能按段起停（系统语音本来就行；内置引擎按句合成完就回调）；
    /// 在线源按段取音频、播完就回 onFinish），所以一段一个引擎是成立的。
    public enum Engine: String, Codable, CaseIterable, Identifiable {
        case system = "系统语音"
        case builtin = "内置离线"
        case http = "在线源"
        /// 老数据里可能还留着已下线引擎的规则，解码时落到系统语音，不让整份配置解不出来
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = TTSCastRole.Engine(rawValue: raw) ?? .system
        }
        public var id: String { rawValue }
    }

    public var id: UUID
    public var name: String
    public var match: Match
    public var keyword: String
    public var engine: Engine
    /// 系统语音填 `AVSpeechSynthesisVoice.identifier`；内置离线填 `LocalTTSModel.id`
    public var voiceId: String
    /// 内置离线模型里的发音人序号，单发声人模型恒为 0
    public var speakerIndex: Int?
    /// 在线源填 `HttpTTS.id`
    public var sourceId: Int64?
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        match: Match = .narration,
        keyword: String = "",
        engine: Engine = .system,
        voiceId: String = "",
        speakerIndex: Int? = nil,
        sourceId: Int64? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.match = match
        self.keyword = keyword
        self.engine = engine
        self.voiceId = voiceId
        self.speakerIndex = speakerIndex
        self.sourceId = sourceId
        self.enabled = enabled
    }
}

/// 多角色配置：总开关 + 角色表
public final class TTSCastStore: ObservableObject {
    public static let shared = TTSCastStore()

    // 存盘之后还要广播一声：正在读的那一段得按新音色重念，不然改完设置这一章就哑了
    // 顺手落一行日志：这个开关一晚上被报过三次「点不动」，有日志才好判是没收到点击还是没存上
    @Published public var enabled: Bool {
        didSet {
            AppLog.write("[听书] 多角色开关 \(enabled ? "开" : "关")")
            save()
            notifyChanged()
        }
    }
    @Published public var roles: [TTSCastRole] { didSet { save(); notifyChanged() } }

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

    private func notifyChanged() {
        NotificationCenter.default.post(name: .ttsCastChanged, object: nil)
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

/// 多角色里角色指向的那条在线源。
///
/// `TTSourceSelection.activeSource` 只认「全局选中的那条」，角色要按自己的 id 取，
/// 所以这里单独走一遍；内置源不在 store 里，得先判一下。
extension Notification.Name {
    /// 角色表、总开关变了：正在读的那一段要按新设置重念
    static let ttsCastChanged = Notification.Name("juyue.ttsCastChanged")
}

enum TTSCastSourceLookup {
    static func source(id: Int64?) -> HttpTTS? {
        guard let id else { return nil }
        if id == HttpTTS.builtinOnlineId { return HttpTTS.builtinOnline }
        let store = HttpTTSStore.shared
        if store.sources.isEmpty { try? store.load() }
        return store.source(id: id)
    }
}

public class AudioBookService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    public static let shared = AudioBookService()

    private let synthesizer = AVSpeechSynthesizer()
    /// 正在播的那一条 AVSpeech 语句。
    /// stopSpeaking 的回调是异步回来的，翻页时「停旧的 + 起新的」会撞在一起：
    /// 旧语句的 didFinish 迟到，把刚起的那一段当成播完，于是一章几秒内被空转着跳完，
    /// 高亮一路往下冲、耳朵还在上一段。delegate 里认这个身份，对不上就丢掉。
    private var currentAVUtterance: AVSpeechUtterance?
    /// 选中在线语音源时改走它，否则还是系统语音。
    private let httpPlayer = HttpTTSPlayer.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 多角色朗读状态
    private struct CastSegment {
        let text: String
        let role: TTSCastRole?
        /// 这段属于正文哪一段：多角色把长段切成对话/旁白，高亮还得回到原来那一段上。
        /// 以前这个字段没有，readingBlockId 在整章多角色朗读里一直是 nil，高亮和翻页跟随全哑。
        let blockId: Int?
    }
    private var castSegments: [CastSegment] = []
    private var castCursor = 0
    private var castActive = false
    /// 起读时用的原料：改设置要重念、或者中途关掉多角色，都得靠它重新铺一遍，
    /// 不然 stop() 一清，用户改个音色回来书就不念了
    private var castText = ""
    private var castBlocks: [(id: Int, text: String)] = []
    /// 当前这一段的身份证。晚到的回调——上一段的看门狗、取音失败、合成器 didFinish——
    /// 拿着旧号码回来时必须作废：那段早就翻过去了，再被兜底逻辑念一遍，
    /// 用户听到的就是「两个角色重复读同一段」。
    private var castToken = 0
    /// 这一段走在线源时记下它的 id，失败了好把它拉黑
    private var castCurrentSourceId: Int64?
    /// 这一轮里已经确认连不上的在线源：后面的段直接跳系统语音，不再每段等一次超时
    private var deadCastSources: Set<Int64> = []
    /// 当前这半句是谁在念，面板上一行字回答「现在到底是哪个源在响」
    private var castCurrentRoleName = ""
    @Published public var castNowLabel: String = ""
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
    /// 这一轮真正要念的正文快照。
    ///
    /// `stop()` 末尾那段 async 会把 `currentText` 清空，而 `speak()` 是「先 stop() 再写正文」：
    /// 清空那一帧晚一步落地，正好落在取音请求还没回来的空档里。取音失败时
    /// `currentText` 已经是空的，兜底那句 `guard !text.isEmpty else { return }` 直接把
    /// 「改系统语音重念」吞掉——听感上就是这段没了、队列还在往前推。
    private var speakTextSnapshot = ""
    /// 本次朗读里在线源是否已经失败过。失败后整段改走系统语音，不再逐段卡超时。
    private var httpSourceFailed = false
    /// 已经处理过的那条失败。订阅重入或者同一刻来两条事件时不重复念。
    private var lastHandledHttpFailureTicket = 0
    /// 朗读条上的一句话状态：已降级之类。空着就不显示。
    @Published public var playbackNote: String?
    /// 在线源正在合成。首段可能要十几秒，界面得说一声，否则用户以为按了没反应。
    @Published public var isSynthesizing: Bool = false

    /// 三层入口（球、朗读条、底栏听书格、朗读面板）共用的播放相位。
    ///
    /// 以前每层自己拼 `isPlaying` / `isPaused` / `readingBlockId`：
    /// 读完那一刻球还在转、底栏还挂着耳机、面板还在报第几段，三处说的是三件事。
    /// 取音那十几秒里 `isPlaying` 和 `isPaused` 又都是 false，于是球先消失再冒出来。
    /// 现在只有一个判据，谁要看状态都问 `playbackPhase`。
    public enum PlaybackPhase: String {
        /// 没有会话
        case idle
        /// 已经起读，声音还没出来（取音、合成）
        case preparing
        case playing
        case paused
    }

    public var playbackPhase: PlaybackPhase {
        if isPlaying { return .playing }
        if isPaused { return .paused }
        // 取音/合成要十几秒，这期间两个标志都是 false，但它明明是个活着的会话
        if isSynthesizing || httpPlayer.isLoading { return .preparing }
        // 段还在手上来着，只是暂时没声：停在半句、等下一段，都算会话没结束
        if readingBlockId != nil { return .preparing }
        return .idle
    }

    /// 有没有在听的会话。球、朗读条、底栏听书格、朗读面板的显隐都只认它
    public var hasReadingSession: Bool { playbackPhase != .idle }

    /// 相位对应的图标。球、朗读条、底栏听书格共用这一份，别再各写一套三元
    public var phaseGlyph: String {
        switch playbackPhase {
        case .playing: return "waveform"
        case .paused: return "play.fill"
        case .preparing: return "ellipsis"
        case .idle: return "headphones"
        }
    }

    /// 朗读条和面板上那一格进度。
    ///
    /// 多角色有自己的一条队列（castCursor/castSegments），普通按段朗读走 readingIndex/readingTotal。
    /// 以前两处都只读后者，多角色念到第 3/120 段时条上写着「朗读 0/1」——同一件事两个数。
    public var progressIndex: Int {
        castActive ? min(max(1, castCursor), max(1, castSegments.count)) : readingIndex + 1
    }

    public var progressTotal: Int {
        castActive ? max(1, castSegments.count) : max(1, readingTotal)
    }

    // MARK: - 音频环境自检

    /// 出口现在长什么样，一句话说清。
    /// 宿主机静音、耳机拔了、蓝牙断了、音频图没起来，这四件事在用户眼里都是「没声」，
    /// 日志里得分得出来是哪一件，不然每次都要从头猜。
    public var audioEnvironmentSummary: String {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        let outs = s.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        // AVAudioSession 不对外露 isActive；「有没有出口」看 currentRoute.outputs 就够
        return "类别=\(s.category.rawValue)/\(s.mode.rawValue) 输出=[\(outs.isEmpty ? "无" : outs)] 采样率=\(Int(s.sampleRate)) 其它音频=\(s.isOtherAudioPlaying ? "是" : "否")"
        #else
        return "非 iOS，跳过"
        #endif
    }

    /// 起读、恢复、回前台各跑一次。出口空了就别装着在念——停一下、留一行话，
    /// 比让用户盯着朗读条猜「是不是卡了」强。
    @discardableResult
    public func runAudioSelfCheck(reason: String) -> Bool {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        // 模拟器里没有「拔掉所有输出」这个动作，留一个自测口把这条分支跑一遍：
        // JUYUE_AUDIO_SELFTEST=empty 当没有出口，silent 让看门狗当成没出声
        let forcedEmpty = ProcessInfo.processInfo.environment["JUYUE_AUDIO_SELFTEST"] == "empty"
        AppLog.write("[听书] 音频自检 · \(reason) · \(audioEnvironmentSummary)\(forcedEmpty ? " · 自测=强制无输出" : "")")
        if forcedEmpty || s.currentRoute.outputs.isEmpty {
            AppLog.write("[听书] 音频自检 · 没有输出设备 → 暂停并提示")
            playbackNote = "没有音频输出，检查耳机或蓝牙"
            if isPlaying { pause() }
            return false
        }
        #endif
        return true
    }

    /// 起读前问一句出口。有问题就返回一句话给界面——
    /// 朗读条只在「有会话」时才出现，会话根本没起来，那条提示就没地方落。
    public func audioIssueBeforeReading() -> String? {
        #if os(iOS)
        let forced = ProcessInfo.processInfo.environment["JUYUE_AUDIO_SELFTEST"] == "empty"
        if forced || AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty {
            AppLog.write("[听书] 音频自检 · 起读拦截 · 没有输出设备")
            return "没有音频输出，检查耳机或蓝牙"
        }
        #endif
        return nil
    }

    /// 各通道「这会儿有没有在出声」的判据。取音/合成中不算无声：在线源首段要十几秒。
    private var hasAudibleActivity: Bool {
        #if DEBUG || targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["JUYUE_AUDIO_SELFTEST"] == "silent" { return false }
        #endif
        if castActive {
            switch castRoute {
            case .http: return httpPlayer.isPlaying || httpPlayer.isLoading
            case .builtin: return BundledTTSEngine.shared.isGraphRunning
            case .system: return synthesizer.isSpeaking || synthesizer.isPaused
            }
        }
        if TTSEngineChoice.isUsingHTTP { return httpPlayer.isPlaying || httpPlayer.isLoading }
        if TTSEngineChoice.current == .builtIn { return BundledTTSEngine.shared.isGraphRunning }
        return synthesizer.isSpeaking || synthesizer.isPaused
    }

    private var silenceTimer: Timer?

    /// 起读/恢复后盯 6 秒：只要这期间抓到过一次「在出声」就算过。
    ///
    /// 以前是一枪 4 秒判死，按段朗读段与段之间本来就有几百毫秒的空档，
    /// 一枪正好打空档上就会把好好的朗读按停。改成每 0.5 秒采样一次，
    /// 抓到声就收工；整段窗口一次都没抓到、又不在取音/合成中，才判没声。
    private func scheduleSilenceWatchdog(reason: String, delay: TimeInterval = 4) {
        silenceTimer?.invalidate()
        let started = Date()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard self.playbackPhase == .playing else { t.invalidate(); return }
            // 取音/合成中不算无声：在线源首段要十几秒，本地模型也要几秒
            if self.isSynthesizing || self.httpPlayer.isLoading { return }
            if self.hasAudibleActivity {
                AppLog.write("[听书] 音频自检 · 有声 · \(reason)")
                t.invalidate()
                return
            }
            guard Date().timeIntervalSince(started) >= delay + 2 else { return }
            t.invalidate()
            AppLog.write("[听书] 音频自检 · \(reason) 后无声 · 通道=\(String(describing: self.castRoute)) · \(self.audioEnvironmentSummary)")
            _ = self.runAudioSelfCheck(reason: "\(reason)后无声")
            self.playbackNote = "没声音：音频输出不可用"
            if self.isPlaying { self.pause() }
        }
        silenceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelSilenceWatchdog() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }


    /// 本章队列读完之后叫一声：阅读页用它接着读下一章。
    /// 只在这一章自然读完时触发，stop() 停的不算。
    public var onReadingQueueFinished: (() -> Void)?

    /// 兜底闹钟：引擎不回调 onFinish 的时候自己往下走一段。
    /// 对话段、刚换完音色的第一段都撞见过「没声也没回调」，一章就那么停在半句话上。
    private var watchdogWork: DispatchWorkItem?
    private var watchdogGeneration = 0

    /// 定时朗读：到点自动暂停，位置留着，第二天点一下就能接着听。
    @Published public var sleepDeadline: Date?
    @Published public var sleepRemaining: Int = 0
    /// 选中的是几分钟，界面靠它给胶囊上色；0 表示没开
    @Published public var sleepMinutes: Int = 0
    /// 睡前听完本章就停，不往下一章跑
    @Published public var sleepStopAtChapterEnd: Bool = false
    private var sleepTicker: Timer?

    /// 试听用的固定句子
    public static let sampleText = "这是一段试听，用来确认音色和语速是否合适。"

    public override init() {
        super.init()
        synthesizer.delegate = self
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "tts_speech_rate") != nil {
            // 旧版本存进去的 0 或负数直接喂 AVSpeech 就是不出声，读回来先夹一遍。
            let stored = Float(defaults.double(forKey: "tts_speech_rate"))
            speechRate = stored.isFinite ? min(1.0, max(0.1, stored)) : AVSpeechUtteranceDefaultSpeechRate
        }
        if defaults.object(forKey: "tts_chunk_length") != nil {
            chunkLength = defaults.integer(forKey: "tts_chunk_length")
        }
        setupAudioSession()
        mirrorHttpPlayerState()
        #if os(iOS)
        // 耳机拔了、蓝牙断了：系统只发通知，不会替你把朗读停下来
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleAudioRouteChange(note) }
            .store(in: &cancellables)
        // 来电、其它 App 抢音频：结束了能接着念就接着念
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleAudioInterruption(note) }
            .store(in: &cancellables)
        #endif
        // 角色表、音色一改就重念当前那段：以前改完设置这一章直接哑掉，用户以为开关坏了
        NotificationCenter.default.publisher(for: .ttsCastChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartReadingAfterSettingsChange() }
            .store(in: &cancellables)
    }

    // MARK: - 音频路由 / 打断

    private func handleAudioRouteChange(_ note: Notification) {
        #if os(iOS)
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ",")
        AppLog.write("[听书] 音频路由变化 · \(String(describing: reason)) · 输出=[\(outs.isEmpty ? "无" : outs)]")
        // 拔耳机 / 断蓝牙：声音突然改走外放会吓人一跳，也可能压根没有出口了。
        // 停在原处，位置留着，用户接好设备点一下就能续。
        if reason == .oldDeviceUnavailable, playbackPhase != .idle, isPlaying {
            pause()
            playbackNote = "音频输出断开，已暂停"
            AppLog.write("[听书] 音频输出断开 → 暂停（位置保留）")
        }
        #endif
    }

    private func handleAudioInterruption(_ note: Notification) {
        #if os(iOS)
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            AppLog.write("[听书] 音频被打断 · 相位=\(playbackPhase.rawValue)")
            if isPlaying {
                pause()
                playbackNote = "被打断，已暂停"
            }
        case .ended:
            let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw)
            let shouldResume = opts.contains(.shouldResume)
            AppLog.write("[听书] 音频打断结束 · 可恢复=\(shouldResume)")
            if shouldResume, isPaused {
                resume()
            }
        @unknown default:
            break
        }
        #endif
    }

    // MARK: - 兜底闹钟

    /// 开了多久以后停。0 就是关掉。
    public func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        guard minutes > 0 else { return }
        sleepDeadline = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        sleepRemaining = minutes * 60
        sleepMinutes = minutes
        AppLog.write("[听书] 定时朗读 \(minutes) 分钟")
        // 用 common 模式挂上去：滑页、松手后计时不会跟着暂停
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let deadline = self.sleepDeadline else { return }
            let left = Int(deadline.timeIntervalSinceNow.rounded())
            if left > 0 {
                self.sleepRemaining = left
                return
            }
            AppLog.write("[听书] 定时到点 · 暂停朗读（位置保留）")
            self.cancelSleepTimer()
            if self.isPlaying { self.pause() }
            self.playbackNote = "定时到，已暂停"
        }
        sleepTicker = ticker
        RunLoop.main.add(ticker, forMode: .common)
    }

    public func cancelSleepTimer() {
        sleepTicker?.invalidate()
        sleepTicker = nil
        sleepDeadline = nil
        sleepRemaining = 0
        sleepMinutes = 0
    }

    /// 睡前本章读完就停
    public func setSleepStopAtChapterEnd(_ on: Bool) {
        sleepStopAtChapterEnd = on
        if on { cancelSleepTimer() }
        AppLog.write("[听书] 本章读完就停 \(on ? "开" : "关")")
    }

    /// 展开条上那一行剩余时间：0 就不显示
    public var sleepRemainingLabel: String {
        guard sleepRemaining > 0 else { return "" }
        let m = sleepRemaining / 60
        let s = sleepRemaining % 60
        return String(format: "%d:%02d", m, s)
    }

    /// 按字数给一个宽裕上限：正常朗读永远碰不到它，只有引擎不回调时才会响。
    private func armWatchdog(for textLength: Int, action: @escaping () -> Void) {
        cancelWatchdog()
        watchdogGeneration += 1
        let generation = watchdogGeneration
        let rate = max(0.4, Double(clampedRate) / Double(AVSpeechUtteranceDefaultSpeechRate))
        let seconds = 6.0 + Double(max(1, textLength)) * 0.45 / rate
        scheduleWatchdog(generation: generation, seconds: seconds, action: action)
    }

    private func scheduleWatchdog(generation: Int, seconds: Double,
                                  action: @escaping () -> Void) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.watchdogGeneration == generation else { return }
            if self.isPaused {
                // 暂停不算卡住，等恢复以后重新计时
                self.scheduleWatchdog(generation: generation, seconds: 8, action: action)
                return
            }
            // 在线源正在取音：首段合成十几秒是常态，不能按卡死算。
            // 以前短段的闹钟（十几字不到 11 秒）会在取音还没回来时先响，
            // 把这一段推走，用户听到的就是「漏了一句」——失败还没来，段先没了。
            if self.isSynthesizing || self.httpPlayer.isLoading {
                AppLog.write("[听书] 兜底闹钟延后 · 在线源取音中(\(Int(seconds))s)")
                self.scheduleWatchdog(generation: generation, seconds: 8, action: action)
                return
            }
            AppLog.write("[听书] 兜底闹钟响 · \(Int(seconds))s 没等到回调，往下走一段")
            action()
        }
        watchdogWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelWatchdog() {
        watchdogGeneration += 1
        watchdogWork?.cancel()
        watchdogWork = nil
    }

    /// 换角色、换音色以后把这一段按新设置重念，别让会话停在无声状态
    private func restartReadingAfterSettingsChange() {
        // 起读之后 1 秒内到的那条「设置变了」，是同一次操作的余波：音已经起来了，
        // 再按它重切一遍就是把刚念的那一段从头再念。放它过去。
        let since = Date().timeIntervalSince(lastSessionStartAt)
        if since >= 0, since < 1.0 {
            AppLog.write(String(format: "[听书] 设置变更重起跳过 · 距起读 %.2fs，算同一次操作", since))
            return
        }
        // 段号和原料要趁掐音频之前拿：后面的 stop() 会把 readingBlockId 清成 nil
        let anchor = readingBlockId
        let wasCast = castActive
        let savedCastText = castText
        let savedCastBlocks = castBlocks
        haltCurrentAudio()
        BundledTTSEngine.shared.invalidate()
        if wasCast, TTSCastStore.shared.enabled, !savedCastBlocks.isEmpty {
            // 多角色这条原来根本走不到：readingActive 是 false，guard 直接吞掉，
            // 用户一改音色就彻底没声了。这里按新角色重切一遍，从当前段接着念。
            let roles = TTSCastStore.shared.roles.filter { $0.enabled }
            let segments = AudioBookService.segmentsForCast(savedCastText, roles: roles, blocks: savedCastBlocks)
            guard !segments.isEmpty else {
                castActive = false
                AppLog.write("[听书] 设置变了 · 多角色重切失败，没有可念的段")
                return
            }
            var resumeAt = 0
            if let anchor, let hit = segments.firstIndex(where: { $0.blockId == anchor }) {
                resumeAt = hit
            }
            castSegments = segments
            castCursor = resumeAt
            // 换了设置就是新的一轮：上一轮拉黑过的源重新给一次机会
            deadCastSources.removeAll()
            castActive = true
            AppLog.write("[听书] 设置变了 · 多角色从第 \(resumeAt + 1)/\(segments.count) 段重念")
            playNextCastSegment()
            return
        }
        if wasCast, !savedCastBlocks.isEmpty {
            // 多角色刚被关掉：按段朗读接上，接着念手里的这一段
            let items = savedCastBlocks.map { AudioBookService.ReadingItem(id: $0.id, text: $0.text) }
            let startAt = anchor.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
            AppLog.write("[听书] 设置变了 · 多角色已关，转按段朗读第 \(startAt + 1)/\(items.count) 段")
            speakReadings(items, startAt: startAt)
            return
        }
        guard readingActive, readingItems.indices.contains(readingIndex) else { return }
        let items = readingItems
        let restartAt = readingIndex
        AppLog.write("[听书] 设置变了 · 从第 \(restartAt + 1) 段按新设置重念")
        speakReadings(items, startAt: restartAt, language: readingLanguage)
    }

    /// 把三条通道上正在响的都掐掉，但不改 readingActive。
    /// 换引擎的时候旧引擎还捏着一段音频，不掐就是新旧两路一起念。
    private func haltCurrentAudio() {
        BundledTTSEngine.shared.stop()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        httpPlayer.stop()
    }

    /// 设置面板换引擎、换音色、换在线源以后调这个，别再直接 stop()：
    /// stop() 把整章状态一起清掉，用户改个音色回来发现书不念了，还以为设置是坏的。
    public func applySettingsChangeRestart() {
        if readingActive || castActive {
            restartReadingAfterSettingsChange()
            return
        }
        stop()
    }

    /// 当前引擎名，设置面板和阅读界面都用它显示
    public var currentEngineName: String {
        if TTSEngineChoice.isUsingHTTP, let source = TTSourceSelection.activeSource {
            return source.name
        }
        if TTSEngineChoice.current == .builtIn {
            return BundledTTSEngine.displayName
        }
        if let voice = SystemVoiceSelection.selectedVoice {
            return "系统语音 · \(voice.name)"
        }
        return "系统语音"
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
                guard let self, TTSEngineChoice.isUsingHTTP else { return }
                self.isPlaying = playing
            }
            .store(in: &cancellables)

        httpPlayer.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paused in
                guard let self, TTSEngineChoice.isUsingHTTP else { return }
                self.isPaused = paused
            }
            .store(in: &cancellables)

        httpPlayer.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                guard let self, TTSEngineChoice.isUsingHTTP else { return }
                self.isSynthesizing = loading
            }
            .store(in: &cancellables)

        // 取音失败原来只写进 lastError 就跳下一段，界面一个字都看不见，四段跳完球就回耳机。
        // 这里接住失败：停掉在线源，这一轮改让系统语音把当前这段读出来，并在条上留一句说明。
        // 不套 receive(on:)：这个订阅必须在 reportFailure 主线程同步投递的当下跑完，
        // 这样 stop() 才会赶在播放器决定「跳到下一段」之前落地。
        httpPlayer.$failure
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.handleHttpSourceFailure(message)
            }
            .store(in: &cancellables)

    }

    private func handleHttpSourceFailure(_ failure: HttpTTSPlayer.Failure) {
        // 同一条失败只处理一次：订阅重入、或者 stop() 之后迟到的重放，都不能再念一遍
        guard failure.ticket != lastHandledHttpFailureTicket else { return }
        lastHandledHttpFailureTicket = failure.ticket
        let message = failure.message
        let where_ = "失败块\(failure.chunkIndex + 1)/\(failure.chunkTotal)"
        // 多角色：每段都可能是一条不同的源，不能因为第一段失败就把后面全判死。
        // 这一段原地退回系统语音重念，队列位置不动。
        if castActive {
            AppLog.write("[听书] 多角色 语音源失败 · 第 \(castCursor)/\(castSegments.count) 段 · \(where_) · \(message) → 本段改系统语音")
            isSynthesizing = false
            // 这条源这一轮别再用：每段都先连一次死源，听感就是念一句卡几秒
            if let id = castCurrentSourceId {
                deadCastSources.insert(id)
                AppLog.write("[听书] 多角色 在线源 \(id) 本轮拉黑，后续段直接走系统语音")
            }
            httpPlayer.onFinish = nil
            httpPlayer.stop()
            playbackNote = "语音源不可用，本段改系统语音"
            let index = castCursor - 1
            guard index >= 0, index < castSegments.count else {
                AppLog.write("[听书] 多角色 语音源失败，段号越界(cursor=\(castCursor))，按队列往下走")
                playNextCastSegment()
                return
            }
            // 兜底这一遍也要有自己的闹钟和段号，不然系统语音不回调就卡在这半句
            let token = castToken
            let text = castSegments[index].text
            armWatchdog(for: text.count) { [weak self] in self?.completeCastSegment(token) }
            playCastWithSystem(text, role: nil, token: token)
            castNowLabel = "\(castCurrentRoleName) · 系统语音（源不可用）"
            return
        }
        // 以前这里有一道一次性闸门：第二次失败直接 return，什么都不做。
        // 结果是队列照常被播放器推走，界面一个字没有，听起来就是「静默跳段」。
        // 现在每一回都收：停掉在线源、这一段改系统语音重念，只是日志里记清是不是头一回。
        let firstTime = !httpSourceFailed
        httpSourceFailed = true
        isSynthesizing = false
        AppLog.write("[听书] 语音源失败\(firstTime ? "" : "（本轮第 \(failure.ticket) 回）") · \(where_) · \(message) → 本段改系统语音")
        // 先摘回调再停：停下来的 finish() 不能替我们把下一段悄悄推进
        httpPlayer.onFinish = nil
        httpPlayer.stop()
        playbackNote = "语音源不可用，本段改系统语音"

        if readingActive {
            // playNextReading 开播前已经把 cursor 加过一，当前这段在 cursor - 1，
            // 别调 playNextReading，那会再跳一段。
            let index = readingCursor - 1
            guard index >= 0, index < readingItems.count else {
                finishReading()
                return
            }
            let item = readingItems[index]
            readingIndex = index
            readingBlockId = item.id
            playReadingItem(item)
            return
        }

        // currentText 可能已经被 stop() 的异步清空抹掉了，快照才是这一轮真正要念的正文
        let text = (currentText.isEmpty ? speakTextSnapshot : currentText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        AppLog.write("[听书] 语音源失败后续 · 定稿正文 \(text.count) 字 · currentText=\(currentText.count) 快照=\(speakTextSnapshot.count) · 引擎=\(TTSEngineChoice.current.rawValue)")
        guard !text.isEmpty else {
            AppLog.write("[听书] 语音源失败后续 · 手里没有正文，这一段念不出来（currentText 与快照都空）")
            return
        }
        speakWithSystemVoice(text, language: "zh-CN")
    }

    /// 直接交给系统语音读一遍，不经过 speak()，免得又把在线源拉回来。
    private func speakWithSystemVoice(_ text: String, language: String) {
        // 包内模型优先。模型缺失或初始化失败，下面的系统语音照旧兜住。
        if TTSEngineChoice.current == .builtIn, BundledTTSEngine.shared.isAvailable {
            speakWithLocalEngine(text, language: language)
            return
        }
        speakWithAVSpeech(text, language: language)
    }

    /// 包内模型：合成在 LocalTTSEngine 的后台队列里跑，出一段播一段。
    private func speakWithLocalEngine(_ text: String, language: String) {
        guard language.hasPrefix("zh") else {
            // 中文模型不认英文，外文段落还是交给系统语音
            speakWithAVSpeech(text, language: language)
            return
        }
        let speed = min(2.0, max(0.5, clampedRate / AVSpeechUtteranceDefaultSpeechRate))
        AppLog.write(String(format: "[听书] 内置引擎 起 · rate=%.2f · %d字",
                            speed, text.count))
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        currentAVUtterance = nil
        BundledTTSEngine.shared.speak(
            text: text,
            speed: speed,
            onFinish: { [weak self] in
                self?.handleLocalSpeechFinished()
            },
            onFailure: { [weak self] reason in
                guard let self else { return }
                AppLog.write("[听书] 内置引擎 失败，改走系统语音 · \(reason)")
                self.playbackNote = "内置语音不可用，已切系统语音"
                self.speakWithAVSpeech(text, language: language)
            }
        )
        DispatchQueue.main.async {
            self.isPlaying = true
            self.isPaused = false
        }
    }

    private func handleLocalSpeechFinished() {
        AppLog.write("[听书] 内置引擎 完 · 段\(readingIndex)")
        if readingActive {
            completeReadingItem()
            return
        }
        if castActive {
            completeCastSegment(castToken)
            return
        }
        isPlaying = false
        isPaused = false
    }

    private func speakWithAVSpeech(_ text: String, language: String) {
        let utterance = AVSpeechUtterance(string: text)
        let voice = SystemVoiceSelection.voice(for: language)
        utterance.voice = voice
        utterance.rate = clampedRate
        let voiceDesc = voice.map { "\($0.name)·\(SystemVoiceSelection.qualityLabel($0))" } ?? "默认"
        AppLog.write("[听书] 系统语音 起 · \(voiceDesc) · rate=\(String(format: "%.2f", clampedRate)) · \(text.count)字")
        // 内置引擎刚放过音的话，输出还捏在它手里，系统语音这时开口只会是静音
        BundledTTSEngine.shared.suspendForSystemSpeech()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        currentAVUtterance = utterance
        lastSpokenBucket = 0
        synthesizer.speak(utterance)
        DispatchQueue.main.async {
            self.isPlaying = true
            self.isPaused = false
        }
    }

    // MARK: - 系统语音段看门狗

    private func startCastGuard(text: String, role: TTSCastRole?, token: Int) {
        castGuardToken += 1
        let guardToken = castGuardToken
        castGuardText = text
        castGuardRole = role
        castGuardBegin = Date()
        castGuardLastProgress = nil
        castGuardTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: castGuardQueue)
        // 头 1.2 秒是 speak 到真正开口的空档，不能判
        timer.schedule(deadline: .now() + 1.2, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, self.castGuardToken == guardToken else { return }
            // 段号对不上：这一段早就翻过去了，这只闹钟管不着
            guard self.castActive, self.castRoute == .system, !self.isPaused, self.castToken == token else { return }
            // 开口要 3.5 秒还没动静，或者念到一半 9 秒没往前挪，都算卡死
            let dead: Bool
            let why: String
            if let last = self.castGuardLastProgress {
                let idle = Date().timeIntervalSince(last)
                dead = idle > 9
                why = String(format: "念着念着停了 %.0fs", idle)
            } else {
                let waited = Date().timeIntervalSince(self.castGuardBegin)
                dead = waited > 3.5
                why = String(format: "%.1fs 没开口", waited)
            }
            guard dead else { return }
            DispatchQueue.main.async {
                guard self.castGuardToken == guardToken,
                      self.castActive, self.castRoute == .system,
                      !self.isPaused, self.castToken == token else { return }
                self.stopCastGuard()
                // 合成器这会儿还以为自己在念，不收掉它就会跟内置那条路抢音频
                self.currentAVUtterance = nil
                if self.synthesizer.isSpeaking { self.synthesizer.stopSpeaking(at: .immediate) }
                let text = self.castGuardText
                let role = self.castGuardRole
                if BundledTTSEngine.isModelBundled {
                    AppLog.write("[听书] 多角色 系统语音卡住（\(why)） · 改内置补念 · \(text.prefix(12))")
                    self.playCastWithLocal(text, role: role, token: token)
                } else {
                    AppLog.write("[听书] 多角色 系统语音卡住（\(why)） · 没内置可用，跳过这一段 · \(text.prefix(12))")
                    self.completeCastSegment(token)
                }
            }
        }
        castGuardTimer = timer
        timer.resume()
    }

    private func stopCastGuard() {
        castGuardToken += 1
        castGuardTimer?.cancel()
        castGuardTimer = nil
    }

    /// 真正喂给引擎的语速。0、负数、NaN 都会让 AVSpeech 静音，统一夹在 0.1...1.0。
    private var clampedRate: Float {
        guard speechRate.isFinite else { return AVSpeechUtteranceDefaultSpeechRate }
        return min(1.0, max(0.1, speechRate))
    }

    /// 把 AVSpeech 的语速换算成语音源的 speakSpeed（安卓端范围 5..50）。
    private var httpSpeed: Int {
        let ratio = clampedRate / AVSpeechUtteranceDefaultSpeechRate
        return min(50, max(5, Int(ratio * 10)))
    }

    private func setupAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // 以前只 print，AppLog 里一个字都没有：模拟器见过 -10879 时查了一整轮才发现这里断了
            print("[AudioBookService] Failed to activate audio session: \(error)")
            AppLog.write("[听书] 音频自检 · 会话激活失败 · \(error.localizedDescription)")
            playbackNote = "音频输出不可用，检查扬声器或耳机"
        }
        #endif
    }

    public func speak(text: String, language: String = "zh-CN") {
        AppLog.write("[听书] 开始朗读，文本长度 \(text.count)")
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.currentText = text
        speakTextSnapshot = text
        playbackNote = nil
        httpSourceFailed = false
        // 自检要在 stop() 之后：stop 把上一轮相位清干净了，这会儿判「有没有出口」才算数。
        // 出口不对就别往下走——念了也听不见，还让朗读条假装在动。
        guard runAudioSelfCheck(reason: "起读") else { return }
        // 只在起读/恢复时挂一次：每段都挂会在日志里刷出成串「有声」
        scheduleSilenceWatchdog(reason: "起读")
        lastSessionStartAt = Date()

        if TTSEngineChoice.isUsingHTTP, let source = TTSourceSelection.activeSource {
            httpPlayer.start(source: source, text: text, speed: httpSpeed, maxChunkLength: chunkLength)
            DispatchQueue.main.async {
                self.isPlaying = true
                self.isPaused = false
            }
            return
        }
        // 包内模型 / 系统语音：由 speakWithSystemVoice 分流，模型不在包里自动退系统
        speakWithSystemVoice(text, language: language)
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
        // 多角色一段一个引擎，得按当前这一段实际走的通道停，不能用全局引擎那个开关
        AppLog.write("[听书] 暂停 · 第 \(progressIndex)/\(progressTotal) 段 · 多角色=\(castActive) 通道=\(String(describing: castRoute))")
        if castActive {
            switch castRoute {
            case .http:
                httpPlayer.pause()
            case .builtin:
                BundledTTSEngine.shared.pause()
            case .system:
                if synthesizer.isSpeaking && !synthesizer.isPaused {
                    synthesizer.pauseSpeaking(at: .word)
                }
            }
            DispatchQueue.main.async {
                self.isPlaying = false
                self.isPaused = true
            }
            return
        }
        if TTSEngineChoice.isUsingHTTP {
            httpPlayer.pause()
        }
        if TTSEngineChoice.current == .builtIn, isPlaying, !isPaused {
            BundledTTSEngine.shared.pause()
            DispatchQueue.main.async {
                self.isPlaying = false
                self.isPaused = true
            }
            return
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
        AppLog.write("[听书] 恢复 · 第 \(progressIndex)/\(progressTotal) 段 · 多角色=\(castActive) 通道=\(String(describing: castRoute)) 引擎=\(TTSEngineChoice.current.title)")
        // 恢复也要再看一眼：暂停期间耳机可能被拔了
        scheduleSilenceWatchdog(reason: "恢复", delay: 3)
        if castActive {
            switch castRoute {
            case .http:
                httpPlayer.resume()
            case .builtin:
                BundledTTSEngine.shared.resume()
            case .system:
                if synthesizer.isPaused { synthesizer.continueSpeaking() }
            }
            DispatchQueue.main.async {
                self.isPlaying = true
                self.isPaused = false
            }
            return
        }
        if TTSEngineChoice.isUsingHTTP {
            httpPlayer.resume()
        }
        if TTSEngineChoice.current == .builtIn, isPaused {
            BundledTTSEngine.shared.resume()
            DispatchQueue.main.async {
                self.isPlaying = true
                self.isPaused = false
            }
            return
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
        cancelWatchdog()
        cancelSilenceWatchdog()
        stopCastGuard()
        // 停就整条序一起停，别留着半截角色队列
        castActive = false
        castSegments = []
        castCursor = 0
        // 原料也一起丢：留着上一章的内容，下次改设置会照着旧章重念
        castText = ""
        castBlocks = []
        // 正文快照跟着会话一起清；speak()/speakWithCast() 会在 stop() 之后重新写进去
        speakTextSnapshot = ""
        // 号码往后拨一格：所有在飞的回调回来都认不出自己
        castToken &+= 1
        castCurrentSourceId = nil
        deadCastSources.removeAll()
        castCurrentRoleName = ""
        castNowLabel = ""
        castRoute = .system
        // 停在半截的在线段不能再把 onFinish 打回来接着推进
        httpPlayer.onFinish = nil
        // 按段朗读的队列也一起清，否则下一段的开头会把刚停的朗读接回去
        readingActive = false
        readingItems = []
        readingCursor = 0
        readingCompletion = nil
        readingBlockId = nil
        readingIndex = -1
        readingTotal = 0
        // 先撤掉身份再叫停：stopSpeaking 的回调回来时认不出自己，就不会去推进新起的朗读
        currentAVUtterance = nil
        httpPlayer.stop()
        BundledTTSEngine.shared.stop()
        isSynthesizing = false
        playbackNote = nil
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
        // 迟到的旧语句（翻页、重起读留下的）不许推进队列，否则新段会被当成已播完
        guard utterance === currentAVUtterance else { return }
        AppLog.write("[听书] 系统语音 完 · 段\(readingIndex) · \(utterance.speechString.count)字")
        currentAVUtterance = nil
        if readingActive {
            // 按段朗读：这一段播完就续下一段，整章结束才收工
            completeReadingItem()
            return
        }
        if castActive {
            // 多角色：一段播完继续下一段，不作为整章结束
            completeCastSegment(castToken)
            return
        }
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isPaused = false
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === currentAVUtterance else { return }
        currentAVUtterance = nil
        if castActive {
            // 被掐掉的这一段立刻作废，别让它的收尾把下一段顶过去
            castToken &+= 1
            castActive = false
        }
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isPaused = false
        }
    }

    // MARK: - 多角色朗读

    /// 按「旁白 / 对话 / 关键词」把整章切段，逐段换音色往外播
    public func speakWithCast(_ text: String, language: String = "zh-CN",
                              blocks: [(id: Int, text: String)] = []) {
        AppLog.write("[听书] 开始多角色朗读，文本长度 \(text.count)，角色 \(TTSCastStore.shared.roles.count) 个")
        stop()
        let roles = TTSCastStore.shared.roles.filter { $0.enabled }
        let segments = AudioBookService.segmentsForCast(text, roles: roles, blocks: blocks)
        guard !segments.isEmpty else { return }
        guard runAudioSelfCheck(reason: "起读") else { return }
        scheduleSilenceWatchdog(reason: "起读")
        castSegments = segments
        castCursor = 0
        castActive = true
        castText = text
        castBlocks = blocks
        castLanguage = language
        currentText = text
        speakTextSnapshot = text
        lastSessionStartAt = Date()
        playNextCastSegment()
    }

    private func playNextCastSegment() {
        guard castActive, castCursor < castSegments.count else {
            castActive = false
            // 队列见底：号码再拨一格，收尾那一秒里冒出来的回调一律作废
            castToken &+= 1
            AppLog.write("[听书] 多角色 结束 · \(castSegments.count) 段")
            DispatchQueue.main.async {
                self.isPlaying = false
                self.isPaused = false
                // 多角色也走同一套收尾口径：读完本章要么接着下一章，要么按睡前模式停
                if self.sleepStopAtChapterEnd {
                    AppLog.write("[听书] 睡前模式 · 读完本章就停")
                    self.sleepStopAtChapterEnd = false
                } else {
                    self.readingBlockId = nil
                    self.readingIndex = -1
                    self.onReadingQueueFinished?()
                }
            }
            return
        }
        let item = castSegments[castCursor]
        castCursor += 1
        playCastSegment(item)
    }

    /// 这一段交给谁念。暂停、恢复、失败兜底都按它分流，不然在线源那段会被
    /// 系统语音那条路按暂停键吃掉。
    private enum CastRoute { case system, builtin, http }
    private var castRoute: CastRoute = .system

    /// 系统语音段的看门狗。AVSpeech 在多角色里偶尔「speak 了却不开口、也不回调」——
    /// 上一段刚用内置引擎念完，紧接着这一段就走不动，整章停在这半句上。
    /// 这里每秒看一眼：还在系统语音路由、没暂停、合成器不响了，就改内置补念，别掉段。
    private let castGuardQueue = DispatchQueue(label: "com.factorcitrus.juyue.cast.guard")
    private var castGuardTimer: DispatchSourceTimer?
    private var castGuardToken = 0
    private var castGuardText = ""
    private var castGuardRole: TTSCastRole?
    /// 这一段开口的时刻，和最后一次「念到第几个字」的时刻。
    /// AVSpeech 卡住时 isSpeaking 会一直是 true，只看这个标志永远等不到头，
    /// 得看它到底有没有往前念。
    private var castGuardBegin = Date()
    private var castGuardLastProgress: Date?
    /// 系统语音进度日志的分桶，换一段就归零
    private var lastSpokenBucket = 0
    /// 上一次起读的时刻。设置变更的通知是异步投递的：开多角色、切引擎都会先起读，
    /// 紧跟着那条「设置变了」才落地，于是同一段被从头再念一遍——
    /// 用户听到的就是两个角色重复读同一段。这条闸门专门吃掉这种余波。
    private var lastSessionStartAt = Date.distantPast

    private func playCastSegment(_ item: CastSegment) {
        let spoken = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else {
            playNextCastSegment()
            return
        }
        // 每段一张新身份证：这一段之后的所有回调都得对得上号
        castToken &+= 1
        let token = castToken
        castCurrentSourceId = nil
        // 高亮跟的是「正文第几段」，不是「多角色第几段」：一段对白切出来的三个碎段，
        // 都得落回同一段正文，否则整章读完高亮一格都不动
        if let blockId = item.blockId {
            DispatchQueue.main.async { self.readingBlockId = blockId }
        }

        // 对话段最容易「没声也没回调」，同样给它一只闹钟
        armWatchdog(for: spoken.count) { [weak self] in self?.completeCastSegment(token) }

        let role = item.role
        castCurrentRoleName = role?.name ?? "默认"
        AppLog.write("[听书] 多角色 段\(castCursor)/\(castSegments.count) · \(role?.name ?? "默认") · \((role?.engine ?? .system).rawValue) · \(spoken.count)字 · block \(item.blockId.map(String.init) ?? "-") · \(spoken.prefix(12))")
        switch role?.engine ?? .system {
        case .system:
            playCastWithSystem(spoken, role: role, token: token)
        case .builtin:
            // 没模型就退回系统语音，别让一条规则把整段吞成静音
            guard BundledTTSEngine.isModelBundled else {
                playbackNote = "没有可用的内置模型，本段改系统语音"
                playCastWithSystem(spoken, role: nil, token: token)
                return
            }
            playCastWithLocal(spoken, role: role, token: token)
        case .http:
            guard let source = TTSCastSourceLookup.source(id: role?.sourceId) else {
                playbackNote = "在线源不可用，本段改系统语音"
                playCastWithSystem(spoken, role: nil, token: token)
                return
            }
            // 回环源在真机上必死；这一轮里已经失败过的源也不再试——
            // 每段都先连一次死源，听到的就是「念一句、卡几秒、再念一句」。
            let hopeless = TTSourceSelection.isLoopback(source.url) && !TTSourceSelection.isSimulator
            if hopeless || deadCastSources.contains(source.id) {
                playbackNote = "\(source.name) 用不上，本段改系统语音"
                AppLog.write("[听书] 多角色 段\(castCursor)/\(castSegments.count) · 源 \(source.name) \(hopeless ? "回环不可用" : "本轮已失败") → 系统语音")
                playCastWithSystem(spoken, role: nil, token: token)
                return
            }
            playCastWithHTTP(spoken, source: source, token: token)
        }
    }

    private func playCastWithSystem(_ spoken: String, role: TTSCastRole?, token: Int,
                                    allowFallbackToLocal: Bool = true) {
        guard token == castToken else {
            AppLog.write("[听书] 多角色 系统语音 作废（旧段 token=\(token) 当前=\(castToken)）")
            return
        }
        castRoute = .system
        // 三条通道同时出声，听感就是两个角色念同一段。开这一段之前，先把别的路按死：
        // 内置引擎停、在线源撤掉 onFinish 再停，合成器自己下面单独收。
        BundledTTSEngine.shared.stop()
        httpPlayer.onFinish = nil
        httpPlayer.stop()
        let utterance = AVSpeechUtterance(string: spoken)
        if let role, !role.voiceId.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: role.voiceId) {
            utterance.voice = voice
        } else {
            utterance.voice = SystemVoiceSelection.voice(for: castLanguage)
        }
        castNowLabel = "\(castCurrentRoleName) · 系统语音" + (utterance.voice.map { " \($0.name)" } ?? "")
        // 系统里没有这条中文语音时 AVSpeechSynthesizer 不报错也出声：
        // 对话段就这么整段吞掉。有声就让它念，没声就交给内置引擎，别掉段。
        if utterance.voice == nil, allowFallbackToLocal, BundledTTSEngine.isModelBundled {
            playbackNote = "系统语音缺这条音色，本段改内置"
            AppLog.write("[听书] 多角色 系统语音无可用音色 → 内置")
            playCastWithLocal(spoken, role: nil, token: token)
            return
        }
        utterance.rate = clampedRate

        // 先把内置引擎的音频图按下去，再让系统语音开口：
        // 两边抢同一个输出时，合成器会报「在念」却不出声，日志上完全看不出问题。
        BundledTTSEngine.shared.suspendForSystemSpeech()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        // AVSpeech 是把语句排队念的：上一段还赖在队列里，这一段就得等它念完，
        // 中间插一段别的音色进来，听着就像两个角色在念同一段。先清空再开口。
        currentAVUtterance = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        currentAVUtterance = utterance
        synthesizer.speak(utterance)
        startCastGuard(text: spoken, role: role, token: token)
        DispatchQueue.main.async {
            self.isPlaying = true
            self.isPaused = false
        }
    }

    private func playCastWithLocal(_ spoken: String, role: TTSCastRole?, token: Int) {
        guard token == castToken else {
            AppLog.write("[听书] 多角色 内置 作废（旧段 token=\(token) 当前=\(castToken)）")
            return
        }
        castRoute = .builtin
        // 系统语音万一还赖着不放，会跟内置这一路抢输出，先把它收掉
        currentAVUtterance = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        stopCastGuard()
        httpPlayer.onFinish = nil
        httpPlayer.stop()
        castNowLabel = "\(castCurrentRoleName) · 内置模型"
        // 内置引擎吃的是倍率（1.0 为原速），系统语音的 rate 是另一套刻度
        let speed = min(2.0, max(0.5, clampedRate / AVSpeechUtteranceDefaultSpeechRate))
        // 角色没绑模型就跟随全局选择；绑了就按那个模型、那个发音人念
        let modelId = (role?.voiceId.isEmpty == false) ? role?.voiceId : nil
        let speakerId = role?.speakerIndex
        AppLog.write("[听书] 多角色 内置 · \(modelId ?? "全局模型") · sid=\(speakerId.map(String.init) ?? "全局") · \(spoken.count)字")

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        currentAVUtterance = nil
        BundledTTSEngine.shared.speak(
            text: spoken,
            speed: speed,
            modelId: modelId,
            speakerId: speakerId,
            onFinish: { [weak self] in
                self?.completeCastSegment(token)
            },
            onFailure: { [weak self] reason in
                guard let self else { return }
                AppLog.write("[听书] 多角色 内置失败，本段改系统语音 · \(reason)")
                DispatchQueue.main.async {
                    self.playbackNote = "内置语音不可用，本段改系统语音"
                    self.playCastWithSystem(spoken, role: nil, token: token)
                }
            }
        )
        DispatchQueue.main.async {
            self.isPlaying = true
            self.isPaused = false
        }
    }

    private func playCastWithHTTP(_ spoken: String, source: HttpTTS, token: Int) {
        guard token == castToken else {
            AppLog.write("[听书] 多角色 在线源 作废（旧段 token=\(token) 当前=\(castToken)）")
            return
        }
        castRoute = .http
        castCurrentSourceId = source.id
        // 系统语音和内置引擎都不许跟在线源一起响
        currentAVUtterance = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        stopCastGuard()
        BundledTTSEngine.shared.stop()
        castNowLabel = "\(castCurrentRoleName) · \(source.name)"
        // 先挂再起：上一段迟到的 finish 不能替这一段收尾，把队列推多一格
        httpPlayer.onFinish = { [weak self] in
            self?.completeCastSegment(token)
        }
        httpPlayer.start(source: source, text: spoken, speed: httpSpeed, maxChunkLength: chunkLength)
        DispatchQueue.main.async {
            self.isPlaying = true
            self.isPaused = false
        }
    }

    /// 一段收尾。只有拿着当前这一段身份证的回调才推得动队列：
    /// 上一段的看门狗、取音失败、didFinish 晚到一步都得作废，否则同一段会被念两遍。
    private func completeCastSegment(_ token: Int) {
        guard castActive, token == castToken else {
            AppLog.write("[听书] 多角色 段收尾作废 · 回调 token=\(token) 当前=\(castToken) 多角色=\(castActive)")
            return
        }
        // 这一段只认一次收尾：号码先作废，第二条回调就进不来了
        castToken &+= 1
        cancelWatchdog()
        stopCastGuard()
        DispatchQueue.main.async { [weak self] in self?.playNextCastSegment() }
    }

    // MARK: - 按段朗读（阅读页：看到读到哪一段，也能从任意一段起读）

    /// 一段正文：id 用 ContentBlock.id，阅读页靠它对上高亮
    public struct ReadingItem: Identifiable, Equatable {
        public let id: Int
        public let text: String
        public init(id: Int, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// 正在朗读的段（readingBlockId 对上阅读页的 block）
    @Published public var readingBlockId: Int?
    /// 队列里的第几段（从 0 开始），-1 表示没在按段读
    @Published public var readingIndex: Int = -1
    @Published public var readingTotal: Int = 0

    private var readingItems: [ReadingItem] = []
    private var readingCursor = 0
    private var readingActive = false
    private var readingLanguage = "zh-CN"
    private var readingCompletion: (() -> Void)?

    /// 从第 startAt 段开始，一段接一段往下读。
    /// 三套引擎都靠各自的 onFinish 续段，所以「换引擎」不影响进度口径。
    public func speakReadings(_ items: [ReadingItem], startAt index: Int = 0, language: String = "zh-CN") {
        AppLog.write("[听书] 按段朗读，\(items.count) 段，从第 \(index + 1) 段起")
        stop()
        guard !items.isEmpty else { return }
        guard runAudioSelfCheck(reason: "起读") else { return }
        scheduleSilenceWatchdog(reason: "起读")
        readingItems = items
        readingCursor = min(max(0, index), items.count - 1)
        readingActive = true
        readingLanguage = language
        readingTotal = items.count
        // 新的一轮重新赌一次在线源：用户可能刚把服务修好
        httpSourceFailed = false
        playbackNote = nil
        currentText = items.map(\.text).joined(separator: "\n")
        lastSessionStartAt = Date()
        playNextReading()
    }

    /// 当前段播完后从下一段继续
    private func playNextReading() {
        guard readingActive, readingCursor < readingItems.count else {
            finishReading()
            return
        }
        let item = readingItems[readingCursor]
        readingIndex = readingCursor
        readingBlockId = item.id
        AppLog.write("[听书] 播第 \(readingCursor + 1)/\(readingItems.count) 段 block \(item.id) 长度 \(item.text.count)")
        readingCursor += 1
        playReadingItem(item)
    }

    private func playReadingItem(_ item: ReadingItem) {
        // 诊断用：这一笔到底走 http 还是系统语音。httpSourceFailed 之后本轮不再试在线源，
        // 日志必须按实际分支写，否则一行 http=true 会把故障复盘带偏（5.0.12 就吃过这个亏）。
        // 引擎选的是包内/系统时，在线源就算还在 UserDefaults 里也不走
        let onlineSource = (httpSourceFailed || !TTSEngineChoice.isUsingHTTP)
            ? nil : TTSourceSelection.activeSource
        if onlineSource != nil {
            AppLog.write("[听书] 引擎选择 http=true id=\(String(describing: TTSourceSelection.activeId)) speed=\(httpSpeed) chunk=\(chunkLength) len=\(item.text.count)")
        } else {
            AppLog.write("[听书] 引擎选择 \(TTSEngineChoice.current.title) · 跳过在线源(本轮已失败=\(httpSourceFailed)) id=\(String(describing: TTSourceSelection.activeId)) len=\(item.text.count)")
        }
        let spoken = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else {
            playNextReading()
            return
        }
        readingCompletion = { [weak self] in self?.playNextReading() }
        // 这一段的兜底：引擎不回调也得往下走，不然整章停在这儿
        armWatchdog(for: spoken.count) { [weak self] in self?.completeReadingItem() }

        if let source = onlineSource {
            httpPlayer.onFinish = { [weak self] in self?.completeReadingItem() }
            httpPlayer.start(source: source, text: spoken, speed: httpSpeed, maxChunkLength: chunkLength)
            markReadingPlaying()
            return
        }

        // 包内有模型就走包内，没有就系统语音；两条路都会在播完后推进下一段
        speakWithSystemVoice(spoken, language: readingLanguage)
        markReadingPlaying()
    }

    private func markReadingPlaying() {
        DispatchQueue.main.async {
            self.isPlaying = true
            self.isPaused = false
        }
    }

    private func completeReadingItem() {
        guard readingActive else { return }
        cancelWatchdog()
        let completion = readingCompletion
        readingCompletion = nil
        DispatchQueue.main.async { completion?() }
    }

    private func finishReading() {
        cancelWatchdog()
        readingActive = false
        readingCompletion = nil
        readingItems = []
        readingCursor = 0
        // 队列已经空了，blockId 留着会让球的 hasReadingSession 永远为真：
        // 界面以为会话还在，球只肯展开条、不肯起读，按下去就是没声音。
        // 读完就复位，球回到耳机入口，下一按重新起读。
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isPaused = false
            self.readingBlockId = nil
            self.readingIndex = -1
            // 三个判据就是 ReaderView.hasReadingSession 的全部输入，落地后打一行存证
            AppLog.write("[听书] 读完收尾 · playing=false paused=false blockId=nil → 球回耳机入口")
            if self.sleepStopAtChapterEnd {
                AppLog.write("[听书] 睡前模式 · 读完本章就停")
                self.sleepStopAtChapterEnd = false
            } else {
                // 本章自然读完：阅读页拿这个回调接着读下一章
                self.onReadingQueueFinished?()
            }
        }
    }

    /// 切段规则：按行切，行内再按引号分出对话；对话给「对话」角色，其余给旁白或命中的关键词角色
    private static func segmentsForCast(_ text: String, roles: [TTSCastRole],
                                        blocks: [(id: Int, text: String)] = []) -> [CastSegment] {
        let narration = roles.first { $0.match == .narration }
        let dialogue = roles.first { $0.match == .dialogue }
        let keywordRoles = roles.filter { $0.match == .keyword && !$0.keyword.isEmpty }

        // 入参 text 是各段按序用换行拼起来的，所以「第几行属于哪一段」可以按段内换行数摊平
        var lineBlocks: [Int?] = []
        for block in blocks {
            let lines = block.text.components(separatedBy: .newlines).count
            lineBlocks.append(contentsOf: Array(repeating: block.id, count: max(1, lines)))
        }

        var result: [CastSegment] = []
        for (lineIndex, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let blockId = lineBlocks.indices.contains(lineIndex) ? lineBlocks[lineIndex] : nil
            for piece in splitByQuotes(line) where !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let role: TTSCastRole?
                if piece.isDialogue {
                    role = dialogue
                } else if let hit = keywordRoles.first(where: { piece.text.contains($0.keyword) }) {
                    role = hit
                } else {
                    role = narration
                }
                // 一整段 1165 字直接丢给 AVSpeech，要念四五分钟：中间任何一次回调丢失
                // 都像「读到对话就不读了」，用户也没法判断是慢还是卡。按句切开，一段几十字。
                for chunk in splitForSpeech(piece.text) {
                    result.append(CastSegment(text: chunk, role: role, blockId: blockId))
                }
            }
        }
        return result
    }

    /// 长段按标点切成短句：给系统语音念的每一段控制在 90 字上下，最长不超过 130。
    private static func splitForSpeech(_ text: String, limit: Int = 90) -> [String] {
        guard text.count > limit else { return [text] }
        let softBreaks: Set<Character> = ["。", "！", "？", "；", "…", "，", "、", "」", "”", "』", "!", "?", ";", ","]
        var chunks: [String] = []
        var buffer = ""
        for ch in text {
            buffer.append(ch)
            guard buffer.count >= limit else { continue }
            if softBreaks.contains(ch) || buffer.count >= limit + 40 {
                chunks.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        return chunks
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

    /// 系统语音每念一个字都会报一次：拿它当「还在往前走」的凭证。
    /// 卡死的那些段一个字都不报，看门狗就靠这个分清「慢」和「死」。
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                  willSpeakRangeOfSpeechString characterRange: NSRange,
                                  utterance: AVSpeechUtterance) {
        guard utterance === currentAVUtterance else { return }
        castGuardLastProgress = Date()
        // 每过一百字落一行：长段是「还在念」还是「卡死了」，日志里得看得出来
        let spokenChars = characterRange.location + characterRange.length
        let bucket = spokenChars / 100
        if bucket > lastSpokenBucket {
            lastSpokenBucket = bucket
            AppLog.write("[听书] 系统语音 进度 · \(spokenChars)/\(utterance.speechString.count)字")
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
