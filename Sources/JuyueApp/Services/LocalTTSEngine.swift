import Foundation
import AVFoundation
#if canImport(CSherpaOnnx)
import CSherpaOnnx
#endif


#if !canImport(CSherpaOnnx)
/// SPM 里没有 xcframework 的 include 路径时（单测、纯 swift build），
/// 这套实现整块让位给下面的空壳，App 照常编译，只是没有包内模型。
final class LocalTTSEngine {
    static let shared = LocalTTSEngine()
    static let displayName = "内置离线语音"
    static let detailText = "包内自带模型 · 断网可用 · 不依赖系统音色下载"
    static var isModelBundled: Bool { false }
    var isAvailable: Bool { false }
    private init() {}
    func invalidate() {}
    func speak(text: String, speed: Float,
               modelId: String? = nil,
               speakerId: Int? = nil,
               onFinish: @escaping () -> Void,
               onFailure: @escaping (String) -> Void) {
        onFailure("sherpa-onnx 未链接")
    }
    func pause() {}
    func resume() {}
    func suspendForSystemSpeech() {}
    func stop() {}
}
#else
/// 包内自带的离线神经语音。
///
/// 推理库是 sherpa-onnx（静态 xcframework），声学模型是 VITS/piper 的
/// `zh_CN-huayan-medium`，两者都躺在 App 包里，第一次用也不用下载音色、
/// 不用连任何服务器。系统语音那套（AVSpeechSynthesizer）留作兜底：
/// 模型没打进包、或者推理初始化失败，就退回去，用户至少还能听。
final class LocalTTSEngine {
    static let shared = LocalTTSEngine()

    /// 展示给用户的名字。名字描述的是引擎，不是某一个模型——模型现在能换。
    static let displayName = "内置离线语音"
    static let detailText = "包内与导入的模型都在本机跑 · 断网可用"

    /// 有任一可用模型（包内 `TTSModel/*` 或导入的 `Documents/TTSModels/*`）就为 true。
    static var isModelBundled: Bool { LocalTTSModelStore.shared.available }

    // MARK: - 状态

    private let synthQueue = DispatchQueue(label: "com.factorcitrus.juyue.localtts.synth",
                                           qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.factorcitrus.juyue.localtts.audio",
                                           qos: .userInitiated)
    private let loadLock = NSLock()

    /// 一个已加载的模型句柄。
    private struct LoadedModel {
        let handle: OpaquePointer
        let rate: Double
        let speakers: Int
    }

    /// 多角色朗读会在同一章里换模型（旁白一个、对话一个）。只留一个句柄的话，
    /// 每换一次角色就得重读一遍 onnx：melo 163MB，一段几百毫秒到几秒，段落之间
    /// 全是空档。留两个刚好覆盖最常见的两条模型，再多按最久未用淘汰。
    private static let maxLoadedModels = 2
    private var loadedModels: [String: LoadedModel] = [:]
    /// 最久未用在最前。只在 loadLock 里读写。
    private var loadOrder: [String] = []
    /// 加载失败过的模型，别每段都去撞一次 abort。
    private var loadFailures: [String: String] = [:]

    /// 引擎实例只碰主线程的音频图，合成在 synthQueue 上跑。
    private var audioEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playerFormat: AVAudioFormat?

    /// 音频图还在跑吗。听书那边判「到底出声没有」要用它：
    /// 真机见过 `AVAudioIONodeImpl … error -10879`，音频图整个没起来，
    /// 界面却老老实实显示「正在朗读」。别再让上层自己猜。
    var isGraphRunning: Bool { audioEngine?.isRunning == true }

    /// `JUYUE_TTS_METER=1` 时在混音器上挂 tap，数真正送进输出设备的帧。
    /// 合成有样点不等于播出去了，验收要的是混音器那侧的帧数与峰值。
    private let meterLock = NSLock()
    private var meterFrames: Int64 = 0
    private var meterPeak: Float = 0
    private var meterBuffers = 0
    private var metering = false

    /// 每次 speak/stop 递增。合成和回调都带着它，对不上就丢掉，
    /// 免得翻页之后上一段的尾巴把新的一段当成播完。
    private var generation = 0
    private var pending = 0
    /// 暂停标记。只在 audioQueue 上读写。
    /// 以前只调 player.pause()，但下一块合成完 enqueue 时看到 isPlaying==false
    /// 就顺手 play() 了，暂停几秒后又自己念起来——一路把剩下的块放完。
    private var paused = false

    /// 排空检测。`scheduleBuffer(_:completionCallbackType: .dataPlayedBack)` 的回调
    /// 在最后一块正好卡在暂停/恢复边界上时偶尔不来：节点已经停了、回调没到，
    /// 上一级就永远等不到「这段读完了」，整章停在半句话上（实测停过 72 秒）。
    /// 自己盯节点状态，合成排完 + 没暂停 + 节点不响了，就补一次播完。
    private var drainTimer: DispatchSourceTimer?
    /// 这一段的块是否已经全部排进节点
    private var drainScheduledAll = true
    /// 播完是否已经报过，报过就不许重复报
    private var drainReported = true
    /// 节点至少响过一次。没响过就判停会把「还没开始」当成「已经结束」
    private var drainSawPlaying = false
    /// 音频图被系统掐停时试着重启的次数，试两次不行就按排空算，免得每 0.4 秒刷一行日志
    private var drainRestartTries = 0
    private var drainFinish: (() -> Void)?

    /// 上一段的响度增益。句与句之间靠它做斜坡过渡，不给句头留「啪」的一声。
    /// 只在 synthQueue 上读写，每次 speak 开头清掉。
    private var chunkGain: Float?

    private init() {}

    /// 模型缺失或初始化失败时为 false，调用方应当退回系统语音。
    var isAvailable: Bool {
        guard Self.isModelBundled else { return false }
        loadLock.lock()
        defer { loadLock.unlock() }
        // 只有当前选中的那个模型失败才算不可用；别的模型失败不该拖累全局
        if let id = LocalTTSModelStore.shared.selected?.id, loadFailures[id] != nil {
            return false
        }
        return true
    }

    // MARK: - 加载

    /// 取（必要时加载）某个模型的句柄。`modelId` 为 nil 时用商店里选中的那个。
    /// 同步加载，只在 synthQueue 上跑：淘汰旧句柄时得跟合成串行，否则正在跑的合成拿着野指针。
    private func loadedEngine(modelId: String?) -> LoadedModel? {
        loadLock.lock()
        defer { loadLock.unlock() }

        let store = LocalTTSModelStore.shared
        let model: LocalTTSModel?
        if let modelId, let found = store.models.first(where: { $0.id == modelId }) {
            model = found
        } else {
            // 角色绑的模型被删了、或者压根没绑，就跟随全局选择，别让这一段落空
            model = store.selected
        }
        guard let model else {
            AppLog.write("[听书] 内置引擎 没有可用的离线模型")
            return nil
        }
        if let cached = loadedModels[model.id] {
            touchLocked(model.id)
            return cached
        }
        if let reason = loadFailures[model.id] {
            AppLog.write("[听书] 内置引擎 跳过已知失败的模型 · \(model.name) · \(reason)")
            return nil
        }
        return buildLocked(model)
    }

    /// 把 id 挪到 LRU 末尾。
    private func touchLocked(_ id: String) {
        loadOrder.removeAll { $0 == id }
        loadOrder.append(id)
    }

    private func buildLocked(_ model: LocalTTSModel) -> LoadedModel? {
        let started = Date()
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.num_threads = 2
        config.model.debug = 0
        config.max_num_sentences = 1
        config.silence_scale = 0.2

        // 读音规则两条路：带 espeak-ng-data 的走音素前端（华言），
        // 只有 lexicon.txt 的走词典（小雅、超文）。两个都空的话初始化会返回 NULL。
        let dataPath = model.dataDir?.path ?? ""
        let lexiconPath = model.lexiconFile?.path ?? ""
        let voicesPath = model.voicesFile?.path ?? ""
        // Kokoro 1.1-zh 的中文分词词典放在 `dict/`（jieba），
        // 不给就会掉回按字切，多音字和数字读得很难听。
        let dictDir = model.folder.appendingPathComponent("dict", isDirectory: true)
        let dictPath = FileManager.default.fileExists(atPath: dictDir.path) ? dictDir.path : ""
        // 多语 Kokoro 要求 lexicon 与 lang 至少给一个，缺了 InitFrontend 直接 abort。
        let kokoroLang = model.lexiconLanguage ?? ""
        // 规则 FST 挂在 OfflineTtsConfig 顶层，是个逗号串，不在 vits 子结构里。
        // 顺序由 LocalTTSModelStore 排好（date → phone → number → new_heteronym）。
        let ruleFstsPath = model.ruleFsts.map(\.path).joined(separator: ",")
        // 两个模型族的字段互不相干，填错族的等于没填：Kokoro 只认 kokoro 那组，
        // 把 .onnx 塞进 vits.model 会得到一个加载失败的句柄。
        let handle = Self.withCStrings([model.modelFile.path, model.tokensFile.path, voicesPath,
                                        dataPath, lexiconPath, "cpu",
                                        dictPath, kokoroLang, ruleFstsPath]) { paths in
            switch model.family {
            case .vits:
                config.model.vits.model = paths[0]
                config.model.vits.tokens = paths[1]
                config.model.vits.data_dir = paths[3]
                config.model.vits.lexicon = paths[4]
                config.model.vits.noise_scale = 0.667
                config.model.vits.noise_scale_w = 0.8
                config.model.vits.length_scale = 1.0
            case .kokoro:
                config.model.kokoro.model = paths[0]
                config.model.kokoro.voices = paths[2]
                config.model.kokoro.tokens = paths[1]
                config.model.kokoro.data_dir = paths[3]
                config.model.kokoro.lexicon = paths[4]
                config.model.kokoro.dict_dir = paths[6]
                config.model.kokoro.lang = paths[7]
                config.model.kokoro.length_scale = 1.0
            }
            config.model.provider = paths[5]
            // 空串等于不设，sherpa 对空指针和空串一视同仁。
            config.rule_fsts = paths[8]
            return SherpaOnnxCreateOfflineTts(&config)
        }
        guard let handle else {
            let reason = "模型加载失败：\(model.name)"
            loadFailures[model.id] = reason
            // 少一样关键输入就是一句 abort，日志里先把这几个空位报出来，省得来回猜。
            AppLog.write(String(format: "[听书] 内置引擎 加载失败 · %@ · 族=%@ · lexicon=%@ · lang=%@ · dict=%@ · fst=%d",
                                reason, model.family.rawValue,
                                lexiconPath.isEmpty ? "无" : "有",
                                kokoroLang.isEmpty ? "无" : kokoroLang,
                                dictPath.isEmpty ? "无" : "有",
                                model.ruleFsts.count))
            return nil
        }
        let rate = Double(SherpaOnnxOfflineTtsSampleRate(handle))
        let speakers = max(1, Int(SherpaOnnxOfflineTtsNumSpeakers(handle)))
        let loaded = LoadedModel(handle: handle, rate: rate, speakers: speakers)
        loadedModels[model.id] = loaded
        touchLocked(model.id)
        while loadOrder.count > Self.maxLoadedModels {
            let victim = loadOrder.removeFirst()
            if let old = loadedModels.removeValue(forKey: victim) {
                SherpaOnnxDestroyOfflineTts(old.handle)
                AppLog.write("[听书] 内置引擎 卸载缓存 · \(victim)")
            }
        }
        // 句柄里读出来的发音人数回填给商店，界面才知道要不要出「发音人」这一行
        DispatchQueue.main.async {
            LocalTTSModelStore.shared.report(speakers: speakers, for: model.id)
        }
        AppLog.write(String(format: "[听书] 内置引擎 就绪 · %@ · %.0fHz · %d 发音人 · fst=%d · %.0fms",
                            model.name, rate, speakers, model.ruleFsts.count,
                            Date().timeIntervalSince(started) * 1000))
        return loaded
    }

    /// 一次性把多个字符串变成 C 指针，省掉六层 `withCString` 嵌套。
    /// 指针只在 `body` 执行期间有效，别往外传。
    private static func withCStrings<R>(_ values: [String],
                                        _ body: ([UnsafePointer<CChar>]) -> R) -> R {
        func step(_ index: Int, _ acc: [UnsafePointer<CChar>]) -> R {
            guard index < values.count else { return body(acc) }
            return values[index].withCString { pointer in
                step(index + 1, acc + [pointer])
            }
        }
        return step(0, [])
    }

    /// 换了模型或者发音人之后调一次。放 synthQueue 上销毁，避免正在合成的段落拿着野指针。
    func invalidate() {
        synthQueue.async { [weak self] in
            guard let self else { return }
            self.loadLock.lock()
            self.destroyAllLocked()
            self.loadLock.unlock()
        }
    }

    private func destroyAllLocked() {
        for old in loadedModels.values {
            SherpaOnnxDestroyOfflineTts(old.handle)
        }
        loadedModels.removeAll()
        loadOrder.removeAll()
        // 失败记录也一起清：用户可能刚把模型补全了，下次该重试
        loadFailures.removeAll()
    }

    // MARK: - 朗读

    /// 合一段文字往外播。onFinish 在该段最后一帧播完后回主线程。
    ///
    /// `modelId` / `speakerId` 是给多角色用的：一段旁白、一段对话可以分别指定
    /// 不同模型和不同发音人。传 nil 就是跟随全局设置，行为和以前一致。
    func speak(text: String, speed: Float,
               modelId: String? = nil,
               speakerId: Int? = nil,
               onFinish: @escaping () -> Void,
               onFailure: @escaping (String) -> Void) {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { onFinish(); return }

        generation += 1
        let gen = generation
        pending = 0
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.drainScheduledAll = false
            self.drainReported = false
            self.drainSawPlaying = false
            self.drainRestartTries = 0
            self.drainFinish = onFinish
            self.startDrainMonitor()
        }

        synthQueue.async { [weak self] in
            guard let self else { return }
            self.chunkGain = nil
            guard let loaded = self.loadedEngine(modelId: modelId) else {
                DispatchQueue.main.async { onFailure("内置模型未加载") }
                return
            }
            let tts = loaded.handle
            let rate = loaded.rate
            // 发音人在开头这一段就定下来：中途换音色，已经排队的句子不会跟着串味。
            // 上限按这个模型自己的发音人数算，别拿全局那个模型的数去夹。
            let requested = speakerId ?? LocalTTSModelStore.shared.speakerId
            let sid = Int32(min(max(0, requested), max(0, loaded.speakers - 1)))
            let chunks = Self.chunks(of: spoken)
            var collected: [Float] = []
            let saveWav = ProcessInfo.processInfo.environment["JUYUE_TTS_SAVE_WAV"] == "1"

            for (index, chunk) in chunks.enumerated() {
                guard self.generation == gen else { return }
                let began = Date()
                guard let audio = Self.synthesize(tts: tts, text: chunk, speed: speed, sid: sid) else {
                    DispatchQueue.main.async { onFailure("合成失败：\(chunk.prefix(12))…") }
                    return
                }
                var samples = Array(UnsafeBufferPointer(start: audio.pointee.samples,
                                                        count: Int(audio.pointee.n)))
                let sampledRate = Double(audio.pointee.sample_rate)
                SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)

                // 梅洛出来的样点峰值只有 0.13–0.17，比华言的 0.48 低十几个 dB，
                // 手机外放听着像把音量拧掉一半。先归一化，再落盘、再排队播放，
                // 这样 wav 跟耳朵里听到的是同一份。
                if ProcessInfo.processInfo.environment["JUYUE_TTS_NO_LEVEL"] != "1" {
                    let leveled = Self.leveled(samples, rate: sampledRate, previous: self.chunkGain)
                    samples = leveled.samples
                    self.chunkGain = leveled.gain
                    AppLog.write(String(format: "[听书] 响度归一 · rms %.4f · peak %.4f → gain %.2fx",
                                        leveled.rms, leveled.peak, leveled.gain))
                }

                if saveWav { collected.append(contentsOf: samples) }

                // 首段合成完就先出声，后面边播边攒，别等整段都算完
                self.enqueue(samples: samples, rate: sampledRate, generation: gen,
                             isLast: index == chunks.count - 1, onFinish: onFinish)
                AppLog.write(String(format: "[听书] 内置引擎 出音 · %.2fs 音频 · %.0fms 合成 · %d/%d",
                                    Double(samples.count) / sampledRate,
                                    Date().timeIntervalSince(began) * 1000,
                                    index + 1, chunks.count))
            }
            if saveWav {
                self.dumpWav(samples: collected, rate: rate)
            }
        }
    }

    private static func synthesize(tts: OpaquePointer, text: String, speed: Float, sid: Int32)
        -> UnsafePointer<SherpaOnnxGeneratedAudio>? {
        var config = SherpaOnnxGenerationConfig()
        config.sid = sid
        config.speed = speed
        config.silence_scale = 0.2
        return text.withCString { cText in
            SherpaOnnxOfflineTtsGenerateWithConfig(tts, cText, &config, nil, nil)
        }
    }

    // MARK: - 响度归一

    /// 固定乘个倍数最省事，可一段话里长句短句会一大一小，而且碰上气口多的句子
    /// 会把底噪一起抬起来。所以按「活动段 RMS」求增益（静音段先剔掉，免得
    /// 一段长停顿把 RMS 拖低、增益反而冲高），再拿峰值上限卡一道不许削波，
    /// 最后在句头 80ms 里从上一段的增益斜坡过去。
    private static let levelTargetRMS: Float = 0.105     // 约 -19.6 dBFS：对齐华言实测 activeRms 0.1042
    private static let levelPeakCeiling: Float = 0.891   // -1 dBFS，留一点余量给重采样
    private static let levelGate: Float = 0.005          // 低于这个幅度当静音，不算进 RMS
    private static let levelGainRange: ClosedRange<Float> = 0.5...4.0   // -6 dB ~ +12 dB

    private static func leveled(_ samples: [Float], rate: Double, previous: Float?)
        -> (samples: [Float], gain: Float, rms: Float, peak: Float) {
        guard !samples.isEmpty else { return (samples, 1, 0, 0) }
        var sum: Double = 0
        var active = 0
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            if magnitude >= levelGate {
                sum += Double(sample) * Double(sample)
                active += 1
            }
        }
        let rms = active > 0 ? Float((sum / Double(active)).squareRoot()) : 0
        // 这一段基本没声音（比如纯停顿），别去放大空气
        guard rms > 0.0001 else { return (samples, 1, rms, peak) }

        var gain = levelTargetRMS / rms
        if peak > 0 { gain = min(gain, levelPeakCeiling / peak) }
        gain = min(max(gain, levelGainRange.lowerBound), levelGainRange.upperBound)

        // 首段直接上目标增益；之后每段开头 80ms 从上一段的值滑过来
        let start = previous ?? gain
        let ramp = max(1, min(samples.count, Int(0.08 * rate)))
        var out = samples
        for index in 0..<samples.count {
            let position = Float(min(index, ramp)) / Float(ramp)
            out[index] = samples[index] * (start + (gain - start) * position)
        }
        return (out, gain, rms, peak)
    }

    // MARK: - 播放

    private func ensureAudioGraph(rate: Double) -> AVAudioPlayerNode? {
        // 音色能换，采样率就跟着换：22.05k 的华言和 44.1k 的梅洛共用一台音频图，
        // 不重建的话后一支的样点会按旧格式排进去，听着就是没声或慢半拍。
        if let player, let format = playerFormat, abs(format.sampleRate - rate) < 1 {
            // 上一段播完或让给系统语音时图被 pause 过：不重新 start 就只剩静音，
            // 节点照样报 playing。多角色来回切的时候这条路走得很频繁。
            if let engine = audioEngine, !engine.isRunning {
                do {
                    try engine.start()
                    AppLog.write("[听书] 内置引擎 音频图复起 · 之前被暂停过")
                } catch {
                    AppLog.write("[听书] 内置引擎 音频图复起失败 · \(error.localizedDescription)")
                }
            }
            return player
        }
        teardownAudioGraph()
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)
        guard let format else { return nil }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            AppLog.write("[听书] 内置引擎 音频图启动失败 · \(error.localizedDescription)")
            return nil
        }
        AppLog.write(String(format: "[听书] 音频图重建 · %.0fHz · engine=%@ · 混音器 %.0fHz",
                            rate,
                            engine.isRunning ? "running" : "stopped",
                            engine.mainMixerNode.outputFormat(forBus: 0).sampleRate))
        installMeteringIfRequested(engine)
        audioEngine = engine
        player = node
        playerFormat = format
        return node
    }

    /// 只在验收时挂：每 40 个 tap 缓冲（约 0.9 秒）报一次累计帧与峰值，
    /// 播完再报一次总数。混音器出帧为 0 就是真的没播出去。
    private func installMeteringIfRequested(_ engine: AVAudioEngine) {
        guard ProcessInfo.processInfo.environment["JUYUE_TTS_METER"] == "1", !metering else { return }
        let mixer = engine.mainMixerNode
        meterLock.lock()
        meterFrames = 0
        meterPeak = 0
        meterBuffers = 0
        metering = true
        meterLock.unlock()
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var peak: Float = 0
            for index in 0..<count {
                peak = max(peak, abs(data[index]))
            }
            self.meterLock.lock()
            self.meterFrames += Int64(count)
            self.meterPeak = max(self.meterPeak, peak)
            self.meterBuffers += 1
            let frames = self.meterFrames
            let peakSoFar = self.meterPeak
            let shouldReport = self.meterBuffers % 40 == 0
            self.meterLock.unlock()
            if shouldReport {
                AppLog.write(String(format: "[听书] 混音器出帧 · %lld帧 · 峰值 %.4f", frames, peakSoFar))
            }
        }
        AppLog.write("[听书] 混音器探针已挂")
    }

    private func stopMetering(reason: String) {
        meterLock.lock()
        guard metering else { meterLock.unlock(); return }
        let frames = meterFrames
        let peak = meterPeak
        metering = false
        meterLock.unlock()
        audioEngine?.mainMixerNode.removeTap(onBus: 0)
        AppLog.write(String(format: "[听书] 混音器收尾 · %@ · %lld帧 · 峰值 %.4f", reason, frames, peak))
    }

    private func teardownAudioGraph() {
        player?.stop()
        audioEngine?.stop()
        player = nil
        audioEngine = nil
        playerFormat = nil
    }

    private func enqueue(samples: [Float], rate: Double, generation gen: Int,
                         isLast: Bool, onFinish: @escaping () -> Void) {
        audioQueue.async { [weak self] in
            guard let self, self.generation == gen else { return }
            guard let player = self.ensureAudioGraph(rate: rate),
                  let format = self.playerFormat,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
            // 暂停中不许被下一块顺手叫醒
            if !player.isPlaying, !self.paused { player.play() }
            if player.isPlaying { self.drainSawPlaying = true }
            AppLog.write(String(format: "[听书] 内置引擎 播放开始 · %.0fHz · %.2fs/段 · engine=%@ · player=%@",
                                rate, Double(samples.count) / rate,
                                self.audioEngine?.isRunning == true ? "running" : "stopped",
                                player.isPlaying ? "playing" : "idle"))
            if isLast {
                self.drainScheduledAll = true
                player.scheduleBuffer(buffer, at: nil, options: [],
                                      completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let self, self.generation == gen else { return }
                    self.audioQueue.async {
                        guard self.generation == gen else { return }
                        self.drainFinish = onFinish
                        self.reportDrained(reason: "播完")
                    }
                }
            } else {
                player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            }
        }
    }

    // MARK: - 排空检测

    private func startDrainMonitor() {
        drainTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(deadline: .now() + 0.4, repeating: 0.4, leeway: .milliseconds(120))
        timer.setEventHandler { [weak self] in self?.tickDrain() }
        drainTimer = timer
        timer.resume()
    }

    private func stopDrainMonitor() {
        drainTimer?.cancel()
        drainTimer = nil
    }

    /// 只在 audioQueue 上跑：合成排完了、没暂停、节点早就不响了，说明回调没到，自己补。
    private func tickDrain() {
        guard !drainReported else {
            stopDrainMonitor()
            return
        }
        guard drainScheduledAll, drainSawPlaying, !paused else { return }
        guard let player else { return }
        if player.isPlaying { return }
        // 引擎被系统掐停时节点也不响：先拉起来，拉起来了就不是排空
        if let engine = audioEngine, !engine.isRunning, drainRestartTries < 2 {
            drainRestartTries += 1
            do {
                try engine.start()
                player.play()
                AppLog.write("[听书] 内置引擎 音频图被系统停掉 · 已重启")
                return
            } catch {
                AppLog.write("[听书] 内置引擎 音频图重启失败 · \(error.localizedDescription)")
            }
        }
        AppLog.write("[听书] 内置引擎 排空补报 · 节点已停、播完回调没来，补一次")
        reportDrained(reason: "排空")
    }

    /// 唯一出口：谁先到算谁，晚到的丢掉，免得一段念出两遍。
    private func reportDrained(reason: String) {
        guard !drainReported else { return }
        drainReported = true
        stopDrainMonitor()
        stopMetering(reason: reason)
        let handler = drainFinish
        drainFinish = nil
        guard let handler else { return }
        DispatchQueue.main.async { handler() }
    }

    // MARK: - 控制

    func pause() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.paused = true
            self.player?.pause()
        }
    }

    /// 让出输出给系统语音：AVSpeech 和 AVAudioEngine 抢同一个输出时，
    /// 合成器会一路报「在念」却一个字都不出声。切段之前把图按下去。
    func suspendForSystemSpeech() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.player?.pause()
            self.audioEngine?.pause()
        }
    }

    func resume() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.paused = false
            if let player = self.player, !player.isPlaying { player.play() }
        }
    }

    func stop() {
        generation += 1
        pending = 0
        audioQueue.async { [weak self] in
            guard let self else { return }
            // 停了就别再补报播完，否则上一段的尾巴会把下一段顶掉
            self.drainReported = true
            self.drainScheduledAll = true
            self.drainFinish = nil
            self.stopDrainMonitor()
            self.paused = false
            self.player?.stop()
            self.audioEngine?.pause()
        }
    }

    // MARK: - 文本切段

    /// 按标点切段，单段不超过约 60 字。切得小一点，第一声来得快。
    static func chunks(of text: String, limit: Int = 60) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            let isBreak = "。！？；…!?;\n".contains(ch)
            if isBreak || current.count >= limit {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(current)
                }
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(current)
        }
        return result.isEmpty ? [text] : result
    }

    // MARK: - 调试产物

    /// `JUYUE_TTS_SAVE_WAV=1` 启动时把最后一段合成结果落到 Documents，
    /// 模拟器验收拿它当"真出过声"的证据，不靠耳朵。
    private func dumpWav(samples: [Float], rate: Double) {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: samples.count)
        }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("tts-last.wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            AppLog.write("[听书] 内置引擎 样本已存 · \(url.lastPathComponent) · \(samples.count)帧")
        } catch {
            AppLog.write("[听书] 内置引擎 样本落盘失败 · \(error.localizedDescription)")
        }
    }
}
#endif
