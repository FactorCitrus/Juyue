#if os(iOS)
import Foundation
import AVFoundation
import Combine

/// 百度在线语音合成。
///
/// 和离线那套的区别：不用序列号，用 API Key / Secret Key 换 access_token（30 天有效），
/// 换到之后调用在线引擎。token 缓存在 UserDefaults，过期自动重取。
final class BaiduOnlineTTS: NSObject, ObservableObject {
    static let shared = BaiduOnlineTTS()

    struct Speaker: Identifiable, Hashable {
        let id: String
        let name: String
        let note: String
    }

    // 凭据统一走 BaiduCredentials：设置里填过就用填的，否则用本地默认
    private static var apiKey: String { BaiduCredentials.apiKey }
    private static var secretKey: String { BaiduCredentials.secretKey }

    /// 在线发音人，按百度语音接口文档的编号
    static let speakers: [Speaker] = [
        Speaker(id: "0", name: "普通女声", note: "在线 · 基础"),
        Speaker(id: "1", name: "普通男声", note: "在线 · 基础"),
        Speaker(id: "3", name: "度逍遥", note: "在线 · 磁性男声"),
        Speaker(id: "4", name: "度丫丫", note: "在线 · 可爱童声"),
        Speaker(id: "5003", name: "度逍遥精品", note: "在线 · 精品音库"),
        Speaker(id: "106", name: "度博文", note: "在线 · 情感男声"),
        Speaker(id: "110", name: "度小童", note: "在线 · 活泼童声"),
        Speaker(id: "111", name: "度小萌", note: "在线 · 可爱童声"),
        Speaker(id: "103", name: "度米朵", note: "在线 · 可爱童声"),
        Speaker(id: "5", name: "度小娇", note: "在线 · 情感女声"),
        Speaker(id: "5118", name: "度小鹿", note: "在线 · 甜美女声")
    ]

    static func speaker(id: String?) -> Speaker? {
        guard let id, !id.isEmpty else { return nil }
        if let known = speakers.first(where: { $0.id == id }) { return known }
        // 控制台里开通了别的音色也能直接用，填 id 就行
        return Speaker(id: id, name: "自定义 \(id)", note: "在线 · 自定义音色 ID")
    }

    private static let speakerKey = "baidu_online_speaker"
    private static let tokenKey = "baidu_online_token"
    private static let tokenExpiryKey = "baidu_online_token_expiry"

    static var activeSpeakerId: String? {
        get { UserDefaults.standard.string(forKey: speakerKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: speakerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: speakerKey)
            }
        }
    }

    static var activeSpeaker: Speaker? { speaker(id: activeSpeakerId) }

    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentIndex = 0
    @Published private(set) var totalChunks = 0
    @Published private(set) var lastError: String?
    @Published private(set) var isPreparing = false
    @Published private(set) var statusText = "未加载"

    var onFinish: (() -> Void)?

    private var synthesizer: BDSSpeechSynthesizer?
    private var loadedSpeakerId: String?
    private var chunks: [String] = []
    private var cancelled = false
    private var pendingUtteranceId: String?
    private var lastSpeed = 5
    private let workQueue = DispatchQueue(label: "legado.baidu.online.tts")
    private let session = URLSession(configuration: .default)

    private override init() {
        super.init()
    }

    // MARK: - token

    private var cachedToken: String? {
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: BaiduOnlineTTS.tokenKey) else { return nil }
        let expiry = defaults.double(forKey: BaiduOnlineTTS.tokenExpiryKey)
        // 提前一天算过期，免得正好卡在边界上
        guard expiry - 86400 > Date().timeIntervalSince1970 else { return nil }
        return token
    }

    private func fetchToken(completion: @escaping (Result<String, Error>) -> Void) {
        if let token = cachedToken {
            completion(.success(token))
            return
        }
        var comps = URLComponents(string: "https://aip.baidubce.com/oauth/2.0/token")!
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: BaiduOnlineTTS.apiKey),
            URLQueryItem(name: "client_secret", value: BaiduOnlineTTS.secretKey)
        ]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"

        session.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "无响应"
                completion(.failure(NSError(
                    domain: "BaiduOnlineTTS", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "取 access_token 失败：\(text.prefix(200))"]
                )))
                return
            }
            let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 2592000
            let defaults = UserDefaults.standard
            defaults.set(token, forKey: BaiduOnlineTTS.tokenKey)
            defaults.set(Date().timeIntervalSince1970 + expiresIn, forKey: BaiduOnlineTTS.tokenExpiryKey)
            completion(.success(token))
        }.resume()
    }

    // MARK: - 引擎

    private func ensureEngine(speaker: Speaker, completion: @escaping (Result<Void, Error>) -> Void) {
        if loadedSpeakerId == speaker.id, synthesizer != nil {
            completion(.success(()))
            return
        }
        DispatchQueue.main.async {
            self.isPreparing = true
            self.statusText = "正在取 token / 加载在线引擎…"
        }

        fetchToken { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.publish(error: error, speaker: speaker)
                completion(.failure(error))
            case .success(let token):
                self.workQueue.async {
                    self.synthesizer?.releaseEngine()
                    self.synthesizer = nil
                    self.loadedSpeakerId = nil
                    let synth = BDSSpeechSynthesizer(delegate: self)
                    _ = synth.setParam(BDSSpeechSynthesizerParams.paramAccessToken, value: token)
                    _ = synth.setParam(BDSSpeechSynthesizerParams.paramOnlineSpeaker, value: speaker.id)
                    let loadResult = synth.loadOnlineEngine()
                    if loadResult.code == 0 {
                        self.synthesizer = synth
                        DispatchQueue.main.async {
                            self.loadedSpeakerId = speaker.id
                            self.isPreparing = false
                            self.statusText = "已加载 在线 · \(speaker.name)"
                            self.lastError = nil
                        }
                        completion(.success(()))
                    } else {
                        synth.releaseEngine()
                        let error = NSError(
                            domain: "BaiduOnlineTTS",
                            code: Int(loadResult.code),
                            userInfo: [NSLocalizedDescriptionKey: "在线引擎加载失败 \(loadResult.code)：\(loadResult.desc)"]
                        )
                        self.publish(error: error, speaker: speaker)
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    private func publish(error: Error, speaker: Speaker) {
        DispatchQueue.main.async {
            self.isPreparing = false
            self.lastError = error.localizedDescription
            self.statusText = "在线 · \(speaker.name) 加载失败"
        }
    }

    func preload(speaker: Speaker) {
        ensureEngine(speaker: speaker) { _ in }
    }

    // MARK: - 播放

    func start(speaker: Speaker, text: String, speed: Int, maxChunkLength: Int = 150) {
        stop()
        cancelled = false
        chunks = TTSTextChunker.split(text, maxLength: maxChunkLength)
        currentIndex = 0
        totalChunks = chunks.count
        guard !chunks.isEmpty else {
            onFinish?()
            return
        }
        activateAudioSession()
        ensureEngine(speaker: speaker) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.speakChunk(at: 0, speed: speed)
            case .failure:
                DispatchQueue.main.async {
                    self.isPlaying = false
                    self.isPaused = false
                }
            }
        }
    }

    func stop() {
        cancelled = true
        pendingUtteranceId = nil
        synthesizer?.stop()
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isPaused = false
        }
    }

    func pause() {
        guard synthesizer?.pause().code == 0 else { return }
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isPaused = true
        }
    }

    func resume() {
        guard synthesizer?.resume().code == 0 else { return }
        DispatchQueue.main.async {
            self.isPlaying = true
            self.isPaused = false
        }
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("[BaiduOnlineTTS] 音频会话激活失败：\(error)")
        }
    }

    private func speakChunk(at index: Int, speed: Int) {
        guard !cancelled, let synthesizer, index < chunks.count else {
            finish()
            return
        }
        currentIndex = index
        lastSpeed = speed
        // 在线语速区间 0..25，5 是 1 倍速
        let paramSpeed = min(25, max(0, speed))
        _ = synthesizer.setParam(BDSSpeechSynthesizerParams.paramSpeed, value: "\(paramSpeed)")

        let utteranceId = UUID().uuidString
        pendingUtteranceId = utteranceId
        let entity = BDSSpeechEntity(text: chunks[index], mode: .online, utteranceId: utteranceId, params: nil)
        let result = synthesizer.speak(entity)
        if result.code != 0 {
            DispatchQueue.main.async {
                self.lastError = "合成失败 \(result.code)：\(result.desc)"
            }
            pendingUtteranceId = nil
            advance()
        }
    }

    private func advance() {
        let next = currentIndex + 1
        if next < chunks.count {
            speakChunk(at: next, speed: lastSpeed)
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
}

extension BaiduOnlineTTS: BDSSpeechSynthesizerDelegate {
    func onSynthesizerResponse(_ response: BDSSpeechSynthesizerResponse) {
        guard !cancelled else { return }
        switch response.synthesizeType {
        case .start:
            DispatchQueue.main.async {
                self.isPlaying = true
                self.isPaused = false
            }
        case .error:
            DispatchQueue.main.async {
                self.lastError = "\(response.result.code)：\(response.result.desc)"
            }
            if response.utteranceId == pendingUtteranceId {
                pendingUtteranceId = nil
                advance()
            }
        case .playFinish:
            if response.utteranceId == pendingUtteranceId {
                pendingUtteranceId = nil
                advance()
            }
        default:
            break
        }
    }
}
#endif
