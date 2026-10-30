import Foundation

/// 包内离线语音的统一门面。
///
/// 以前「包内离线」这一档只认 sherpa-onnx 那套 .onnx 模型。现在包里带的是百度离线
/// 引擎，两条路的方法形状又不一样，调用点分散在听书服务和设置页里，各处 if 一遍必然
/// 漏。收成一个门面：谁在包里就用谁，调用方只认这一层。
///
/// 优先级：百度（有音色且在包里）> sherpa（有模型）> 都不可用（调用方退系统语音）。
final class BundledTTSEngine {
    static let shared = BundledTTSEngine()
    private init() {}

    /// 每次起播/停止都 +1。延迟检查躺在闭包里，靠它认出「这条早就翻篇了」，
    /// 否则用户手动停止后两秒，那只闹钟还会把「没有起播」报成失败。
    private var generation = 0

    /// 百度离线可用 = 包里扫到了至少一条音色。AppStore 构建里 allVoices 恒为空，
    /// 这条判断顺带把百度整条路关掉，不用再编一层宏。
    static var isBaidu: Bool {
        #if os(iOS)
        return !BaiduOfflineTTS.allVoices.isEmpty
        #else
        return false
        #endif
    }

    static var displayName: String {
        isBaidu ? "百度离线语音" : LocalTTSEngine.displayName
    }

    static var detailText: String {
        isBaidu
            ? "包内带百度离线引擎与女声音库 · 断网可用 · 不连服务器"
            : LocalTTSEngine.detailText
    }

    /// 这一档有没有东西能用。菜单里退不退系统语音就看它。
    static var isModelBundled: Bool {
        isBaidu || LocalTTSEngine.isModelBundled
    }

    var isAvailable: Bool {
        Self.isModelBundled
    }

    /// 「这会儿有没有在出声」。AudioBookService 的静音看门狗拿它判死，合成中不算无声。
    var isGraphRunning: Bool {
        #if os(iOS)
        if Self.isBaidu {
            let engine = BaiduOfflineTTS.shared
            return engine.isPlaying || engine.isPaused || engine.isPreparing
        }
        #endif
        return LocalTTSEngine.shared.isGraphRunning
    }

    // MARK: - 播放

    func speak(text: String, speed: Float,
               modelId: String? = nil,
               speakerId: Int? = nil,
               onFinish: @escaping () -> Void,
               onFailure: @escaping (String) -> Void) {
        #if os(iOS)
        guard Self.isBaidu else {
            LocalTTSEngine.shared.speak(text: text, speed: speed,
                                        modelId: modelId, speakerId: speakerId,
                                        onFinish: onFinish, onFailure: onFailure)
            return
        }
        guard let voice = BaiduOfflineTTS.activeVoice ?? BaiduOfflineTTS.allVoices.first else {
            onFailure("百度离线引擎没有可用音色")
            return
        }
        // 没选过音色时把第一条钉住，免得每次启动都在「无选中」和「默认」之间飘
        if BaiduOfflineTTS.activeVoiceId == nil {
            BaiduOfflineTTS.activeVoiceId = voice.id
        }
        // 百度语速 0…15，5 是 1 倍速；这边传进来的是 0.5…2.0 的倍率
        let rate = min(15, max(0, Int((speed * 5).rounded())))
        let engine = BaiduOfflineTTS.shared
        generation += 1
        let token = generation
        var finished = false
        engine.clearError()
        engine.onFinish = {
            finished = true
            onFinish()
        }
        engine.start(voice: voice, text: text, speed: rate)
        // 引擎起不来时它只把 isPlaying 置回 false，不调 onFinish，所以补一只闹钟兜住。
        // 短句两秒内念完是正常的：finished 先落地，这条直接放行。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak engine] in
            guard let self, let engine else { return }
            guard self.generation == token, !finished else { return }
            guard !engine.isPlaying, !engine.isPreparing, !engine.isPaused else { return }
            if let reason = engine.lastError {
                engine.clearError()
                onFailure(reason)
            } else {
                onFailure("百度离线引擎没有起播")
            }
        }
        #else
        LocalTTSEngine.shared.speak(text: text, speed: speed,
                                    modelId: modelId, speakerId: speakerId,
                                    onFinish: onFinish, onFailure: onFailure)
        #endif
    }

    func pause() {
        #if os(iOS)
        if Self.isBaidu {
            BaiduOfflineTTS.shared.pause()
            return
        }
        #endif
        LocalTTSEngine.shared.pause()
    }

    func resume() {
        #if os(iOS)
        if Self.isBaidu {
            BaiduOfflineTTS.shared.resume()
            return
        }
        #endif
        LocalTTSEngine.shared.resume()
    }

    func stop() {
        #if os(iOS)
        if Self.isBaidu {
            generation += 1
            BaiduOfflineTTS.shared.onFinish = nil
            BaiduOfflineTTS.shared.stop()
        }
        #endif
        LocalTTSEngine.shared.stop()
    }

    /// 切回系统语音前递一句：百度那套自己捏着 AVAudioSession，不撒手系统语音就是静音。
    func suspendForSystemSpeech() {
        #if os(iOS)
        if Self.isBaidu {
            generation += 1
            BaiduOfflineTTS.shared.onFinish = nil
            BaiduOfflineTTS.shared.stop()
        }
        #endif
        LocalTTSEngine.shared.suspendForSystemSpeech()
    }

    /// 换音色、换模型以后丢一次缓存的引擎句柄。
    func invalidate() {
        #if os(iOS)
        if Self.isBaidu {
            generation += 1
            BaiduOfflineTTS.shared.resetEngine()
        }
        #endif
        LocalTTSEngine.shared.invalidate()
    }
}
