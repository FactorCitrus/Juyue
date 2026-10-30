#if !NO_BAIDU_TTS
#if os(iOS)
import Foundation
import AVFoundation
import Combine
import ZIPFoundation

/// 百度离线语音合成（BDSpeechClientSDK）。
///
/// 一条音色 = 一个文本模型 + 一个声学模型。引擎按音色切；切音色会重载离线引擎。
/// 长文先切段，逐段 speak，播完一段再投下一段。
final class BaiduOfflineTTS: NSObject, ObservableObject {
    static let shared = BaiduOfflineTTS()

    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
        let note: String
        /// 文本模型的绝对路径
        let textPath: String
        /// 声学模型的绝对路径
        let speechPath: String
        /// 自备音库的 text.dat 是旧版，跟这版引擎对不上时拿 SDK 的文本模型再试一次
        var alternateTextPath: String? = nil

        var speechFileName: String { (speechPath as NSString).lastPathComponent }
        var textFileName: String { (textPath as NSString).lastPathComponent }
    }

    /// 控制台里的 APP ID（设置里填过就用填的）
    static var appId: String { BaiduCredentials.appId }
    /// 控制台申请的离线序列号，第一条授权失败就换第二条
    static var serialNumbers: [String] { BaiduCredentials.serials }

    /// SDK 自带只带两条；自备音库放 Documents/BaiduTTS 里，能放几包放几包
    static let builtinVoices: [Voice] = {
        guard let text = bundlePath("text_v6") else { return [] }
        var list: [Voice] = []
        list.append(Voice(id: "duxiaomei", name: "度小美", note: "SDK 自带 · 女声",
                          textPath: text, speechPath: bundlePath("duxiaomei") ?? ""))
        list.append(Voice(id: "duxiaoyu", name: "度小宇", note: "SDK 自带 · 男声",
                          textPath: text, speechPath: bundlePath("duxiaoyu") ?? ""))
        // 包里多放的声学模型也算音色：往 Resources/BaiduTTS 里丢 .dat 就行
        let known = Set(["duxiaomei", "duxiaoyu"])
        list.append(contentsOf: scannedVoices(text: text).filter { !known.contains($0.id) })
        return list.filter { !$0.speechPath.isEmpty }
    }()

    /// 用户自己导进来的音库（Documents/BaiduTTS 下扫出来的）
    static private(set) var userVoices: [Voice] = []

    /// SDK 自带的 + 导入的
    static var allVoices: [Voice] { builtinVoices + userVoices }

    static func voice(id: String?) -> Voice? {
        guard let id else { return nil }
        return allVoices.first { $0.id == id }
    }

    private static let voiceKey = "baidu_tts_voice"

    /// 当前选中的百度音色，nil 表示没选百度离线。
    static var activeVoiceId: String? {
        get { UserDefaults.standard.string(forKey: voiceKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: voiceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: voiceKey)
            }
        }
    }

    static var activeVoice: Voice? { voice(id: activeVoiceId) }

    // MARK: - 播放状态（和 HttpTTSPlayer 保持一致，便于 AudioBookService 转发）

    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentIndex = 0
    @Published private(set) var totalChunks = 0
    @Published private(set) var lastError: String?
    /// 已经成功载入的音色 id
    @Published private(set) var loadedVoiceId: String?
    @Published private(set) var isPreparing = false
    @Published private(set) var statusText = "未加载"
    /// 授权自检的逐行结果。LiveContainer 这类容器里没法接 console，只能让用户在 App 里看。
    @Published private(set) var authReport: String = ""

    var onFinish: (() -> Void)?

    // MARK: - 内部状态

    private var synthesizer: BDSSpeechSynthesizer?
    private var chunks: [String] = []
    private var cancelled = false
    private var pendingUtteranceId: String?
    private let workQueue = DispatchQueue(label: "legado.baidu.tts")

    private override init() {
        super.init()
        BaiduOfflineTTS.refreshUserVoices()
        // 自检由 BaiduOfflineTTS.probeIfNeeded() 在启动时触发
    }

    // MARK: - 资源

    /// bundle 内 Resources/BaiduTTS 下的资源，名字不带扩展名

    // MARK: - 授权自检（跑通授权用）

    /// 启动时调一次。跑过就跳过；JUYUE_BAIDU_AUTH_PROBE 可强制（=1）或禁用（=0）。
    static func probeIfNeeded() {
        // 引擎取包名会缓存，先装垫片再让任何 SDK 调用发生
        BaiduBundleShim.install()
        let env = ProcessInfo.processInfo.environment["JUYUE_BAIDU_AUTH_PROBE"]
        guard env != "0" else { NSLog("[BaiduAuth] skipped by env"); return }
        // 以前用布尔标记，跑过一次以后换包也不跑了，日志里就永远静悄悄。
        // 改成按版本号记：每换一版自动跑一次，同版本里不重复。
        let stamp = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let doneFor = UserDefaults.standard.string(forKey: "baidu_auth_probe_version")
        guard env == "1" || doneFor != stamp else { return }
        UserDefaults.standard.set(stamp, forKey: "baidu_auth_probe_version")
        // 从旧备份恢复过来的 APP ID 会盖住包内那套（见过 124571480），授权永远对不上。
        // 这里只在值和包内不一致时清一次，用户自己填的其它值也会被清，但这台机器上没有第二套。
        let storedAppId = UserDefaults.standard.string(forKey: "baidu_app_id") ?? ""
        if !storedAppId.isEmpty, storedAppId != BaiduCredentials.LocalDefaults.appId {
            BaiduCredentials.resetToBuiltin()
            AppLog.write("[BaiduAuth] 清掉旧 APP ID \(storedAppId)，改用 \(BaiduCredentials.LocalDefaults.appId)")
        }
        shared.authorizationProbe()
    }

    /// 只跑一次 loadOfflineEngine，不放音。每条序列号的结果都用 NSLog 打出来。
    /// 触发方式：`xcrun devicectl device process launch --console --environment JUYUE_BAIDU_AUTH_PROBE=1 <bundleid>`
    /// 或者设置里填过凭据后自动在后台跑一次（App 冷启动时）。
    func authorizationProbe() {
        let appId = BaiduOfflineTTS.appId
        let serials = BaiduOfflineTTS.serialNumbers
        let voices = BaiduOfflineTTS.builtinVoices
        let bundle = Bundle.main.bundleIdentifier ?? "?"
        DispatchQueue.main.async { self.authReport = "" }
        probeLog(String(format: "[BaiduAuth] start appId=%@ bundle=%@ serials=%d voices=%d",
                        appId, bundle, serials.count, voices.count))
        probeLog("[BaiduAuth] 引擎将看到的包名 = "
                 + (BaiduBundleShim.withOverride { Bundle.main.bundleIdentifier ?? "?" }))
        guard appId.isEmpty == false else { probeLog("[BaiduAuth] 没有 APP ID，停止"); return }
        guard let voice = voices.first else { probeLog("[BaiduAuth] 包里没有内置音色，停止"); return }

        let model: [String: String] = [
            BDSSpeechSynthesizerParams.ttsTextModelFile: voice.textPath,
            BDSSpeechSynthesizerParams.ttsSpeechModelFile: voice.speechPath,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: model),
              let modelJSON = String(data: data, encoding: .utf8) else {
            probeLog("[BaiduAuth] 模型 JSON 组不出来，停止")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // 引擎自己那套网络栈不吐东西就只能猜。verbose 打开，把 URL 和错误码直接抓下来。
            var logCount = 0
            if let level = BDSSpeechLogLevel(rawValue: 1) {
                BDSSpeechLogger.sharedInstance().setLogLevel(level, path: nil) { [weak self] message in
                    guard let self else { return }
                    logCount += 1
                    guard logCount <= 150 else { return }
                    self.probeLog("[BdsLog] \(message)")
                }
            }
            self.probeNetworkSync()
            guard serials.isEmpty == false else {
                self.probeLog("[BaiduAuth] 没有序列号，停止")
                return
            }
            for (index, serial) in serials.enumerated() {
                let synth = BDSSpeechSynthesizer(delegate: self)
                _ = synth.setParam(BDSSpeechSynthesizerParams.paramAppId, value: appId)
                _ = synth.setParam(BDSSpeechSynthesizerParams.paramAuthSerialNumber, value: serial)
                _ = synth.setParam(BDSSpeechSynthesizerParams.paramOfflineModel, value: modelJSON)
                let result = BaiduBundleShim.withOverride { synth.loadOfflineEngine() }
                self.probeLog(String(format: "[BaiduAuth] serial#%d len=%d -> code=%d desc=%@",
                                     index, serial.count, Int(result.code), result.desc))
                synth.releaseEngine()
                if result.code == 0 {
                    self.probeLog(String(format: "[BaiduAuth] 授权通过，序列号 %@ 可用", serial))
                    break
                }
            }
            self.probeLog("[BaiduAuth] done")
        }
    }

    /// 探针的输出去三个地方：NSLog（接 console 时）、AppLog（用户能翻日志）、authReport（设置页直接显示）。
    private func probeLog(_ line: String) {
        NSLog("%@", line)
        AppLog.write(line)
        DispatchQueue.main.async {
            self.authReport += (self.authReport.isEmpty ? "" : "\n") + line
        }
    }

    /// 网络自检：先 DNS，再 HTTPS。
    ///
    /// 容器里最常见的死法是引擎自己那套 DoH（httpsdns.baidu.com/v4/resolve）挂了，
    /// 报 `download error -1003`（cannotFindHost），跟包名、序列号都无关。
    /// 先用系统解析加一条真请求把这一层摘干净，免得后面白折腾。
    private func probeNetworkSync() {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo("tts.baidu.com", "443", &hints, &res)
        var ips: [String] = []
        if rc == 0, let head = res {
            var node: UnsafeMutablePointer<addrinfo>? = head
            while let cur = node {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(cur.pointee.ai_addr, cur.pointee.ai_addrlen,
                               &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    ips.append(String(cString: buf))
                }
                node = cur.pointee.ai_next
            }
            freeaddrinfo(head)
        }
        probeLog("[BaiduNet] getaddrinfo tts.baidu.com rc=\(rc) ips=\(ips.prefix(4).joined(separator: ","))")

        guard let url = URL(string: "https://tts.baidu.com/offline/auth") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let headText = data.flatMap { String(data: $0.prefix(100), encoding: .utf8) } ?? ""
            self.probeLog("[BaiduNet] GET /offline/auth http=\(code) err=\(error?.localizedDescription ?? "none") head=\(headText)")
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
    }

    /// 音色 ID → 显示名。没登记的按 ID 原样显示。
    static func displayName(for id: String) -> String {
        let table = [
            "duxiaomei": "度小美", "duxiaoyu": "度小宇",
            "duxiaolu": "度小鹿", "duxiaowen": "度小雯",
            "duxiaoqiao": "度小乔", "duxiaojiao": "度小娇",
            "dumiduo": "度米朵", "duxiaotai": "度小台",
            "duxiaoyao": "度小遥", "duxiaomeng": "度小萌",
            "duyaya": "度丫丫", "duxiaoxian": "度小贤",
        ]
        return table[id] ?? id
    }

    /// 扫包内 BaiduTTS 目录，除文本模型外的 .dat 都当声学模型
    static private func scannedVoices(text: String) -> [Voice] {
        let candidates = ([Bundle.main] + Bundle.allBundles)
            .compactMap { $0.resourceURL?.appendingPathComponent("BaiduTTS").path }
        guard let dir = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return []
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files
            .filter { $0.hasSuffix(".dat") && !$0.hasPrefix("text_") }
            .sorted()
            .map { file in
                let id = String(file.dropLast(4))
                return Voice(id: id, name: BaiduOfflineTTS.displayName(for: id),
                             note: "精品音色", textPath: text, speechPath: dir + "/" + file)
            }
    }

    static func bundlePath(_ name: String) -> String? {
        let bundles = [Bundle.main] + Bundle.allBundles
        for bundle in bundles {
            if let path = bundle.path(forResource: name, ofType: "dat", inDirectory: "BaiduTTS") {
                return path
            }
            if let path = bundle.path(forResource: name, ofType: "dat") {
                return path
            }
        }
        return nil
    }

    // MARK: - 自备音库（多角色）

    /// 用户音库的落脚点：Documents/BaiduTTS
    static func libraryRoot() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("BaiduTTS", isDirectory: true)
    }

    /// 扫一遍 Documents/BaiduTTS，把每包里的每个 *.voc.dat 认成一条音色。
    /// 支持两种摆放：包目录下直接放 voc.dat，或者放 acoustic/ 子目录里。
    @discardableResult
    static func refreshUserVoices() -> [Voice] {
        let fm = FileManager.default
        let root = libraryRoot()
        guard let packs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            userVoices = []
            return []
        }

        let fallbackText = bundlePath("text_v6")
        var found: [Voice] = []

        for pack in packs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: pack.path, isDirectory: &isDir), isDir.boolValue else { continue }

            // 找文本模型：包根目录的 text.dat / text_*.dat，找不到就用 SDK 的
            var textPath = fallbackText
            if let files = try? fm.contentsOfDirectory(at: pack, includingPropertiesForKeys: nil) {
                if let own = files.first(where: {
                    $0.pathExtension.lowercased() == "dat" &&
                    $0.lastPathComponent.lowercased().contains("text")
                }) {
                    textPath = own.path
                }
            }
            guard let text = textPath else { continue }

            // 递归捞 *.voc.dat
            var voiceFiles: [URL] = []
            if let walker = fm.enumerator(at: pack, includingPropertiesForKeys: nil) {
                for case let url as URL in walker where url.pathExtension.lowercased() == "dat" {
                    if url.lastPathComponent.lowercased().hasSuffix(".voc.dat") {
                        voiceFiles.append(url)
                    }
                }
            }

            for voiceFile in voiceFiles.sorted(by: { $0.path < $1.path }) {
                let rawName = voiceFile.lastPathComponent
                let base = rawName.lowercased().hasSuffix(".voc.dat")
                    ? String(rawName.dropLast(".voc.dat".count))
                    : voiceFile.deletingPathExtension().lastPathComponent
                found.append(Voice(
                    id: "user:\(pack.lastPathComponent):\(base)",
                    name: base,
                    note: "自备音库 · \(pack.lastPathComponent)",
                    textPath: text,
                    speechPath: voiceFile.path,
                    alternateTextPath: text != fallbackText ? fallbackText : nil
                ))
            }
        }

        userVoices = found
        return found
    }

    /// 导入一个音库压缩包（MultiTTS 那种 bdetts_xxx.zip 直接丢进来就行）。
    /// 返回导进来的音色数量。
    @discardableResult
    static func importPackage(from zipURL: URL) throws -> Int {
        let fm = FileManager.default
        let root = libraryRoot()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // 用压缩包名前缀建目录，避免不同包互相覆盖
        let stem = zipURL.deletingPathExtension().lastPathComponent
        let safeStem = stem.replacingOccurrences(of: "/", with: "_")
        let destination = root.appendingPathComponent(safeStem, isDirectory: true)
        if !fm.fileExists(atPath: destination.path) {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        try fm.unzipItem(at: zipURL, to: destination)
        return refreshUserVoices().count
    }

    /// 删掉自己导进来的音色（连同它所在的包目录）。
    /// SDK 自带音色不能删，已打进包内。
    @discardableResult
    static func deleteVoices(_ voices: [Voice]) -> Int {
        let fm = FileManager.default
        var removed = 0
        for voice in voices {
            for path in [voice.speechPath, voice.textPath] where path.hasPrefix(libraryRoot().path) {
                if fm.fileExists(atPath: path) {
                    try? fm.removeItem(atPath: path)
                    removed += 1
                }
            }
            // 包目录空了就一起收掉
            let packDir = URL(fileURLWithPath: voice.speechPath).deletingLastPathComponent()
            for dir in [packDir, packDir.deletingLastPathComponent()] where dir.path.hasPrefix(libraryRoot().path) {
                if let items = try? fm.contentsOfDirectory(atPath: dir.path), items.isEmpty {
                    try? fm.removeItem(at: dir)
                }
            }
        }
        refreshUserVoices()
        return removed
    }

    /// 模型体检：交给 SDK 自己判定，结果直接返回字符串给界面看。
    func diagnose(voice: Voice) -> [String] {
        var lines: [String] = []
        var candidates: [(String, String)] = [
            ("文本模型", voice.textPath),
            ("声学模型", voice.speechPath)
        ]
        if let alt = voice.alternateTextPath {
            candidates.append(("备用文本模型", alt))
        }
        for (label, path) in candidates {
            let name = (path as NSString).lastPathComponent
            let verify = BDSSpeechOfflineEngineTool.verifyModelFile(path)
            let match = BDSSpeechOfflineEngineTool.matchResEngine(path)
            let rate = BDSSpeechOfflineEngineTool.getSpeechSampleRate(path)
            let info = BDSSpeechOfflineEngineTool.getModelInfo(path) ?? "-"
            lines.append("\(label)[\(name)]：校验 \(verify.code)（\(verify.desc)），版本匹配 \(match)，采样率 \(rate)")
            lines.append("　　\(info)")
        }
        return lines
    }

    // MARK: - 引擎

    /// 载入指定音色的离线引擎。同一个音色重复调用会直接返回。
    private func ensureEngine(voice: Voice, completion: @escaping (Result<Void, Error>) -> Void) {
        if loadedVoiceId == voice.id, synthesizer != nil {
            completion(.success(()))
            return
        }
        let speechPath = voice.speechPath
        guard FileManager.default.fileExists(atPath: speechPath) else {
            let error = NSError(domain: "BaiduOfflineTTS", code: -122,
                                userInfo: [NSLocalizedDescriptionKey: "找不到声学模型 \(voice.speechFileName)"])
            publish(error: error, voice: voice)
            completion(.failure(error))
            return
        }
        // 一组文本模型配一个声学模型；自备音库会再拿 SDK 的文本模型试一次
        var pairings: [(String, String)] = []
        if FileManager.default.fileExists(atPath: voice.textPath) {
            pairings.append((voice.textFileName, voice.textPath))
        }
        if let alt = voice.alternateTextPath, FileManager.default.fileExists(atPath: alt) {
            pairings.append(((alt as NSString).lastPathComponent, alt))
        }
        guard !pairings.isEmpty else {
            let error = NSError(domain: "BaiduOfflineTTS", code: -122,
                                userInfo: [NSLocalizedDescriptionKey: "找不到文本模型 \(voice.textFileName)"])
            publish(error: error, voice: voice)
            completion(.failure(error))
            return
        }

        DispatchQueue.main.async {
            self.isPreparing = true
            self.statusText = "正在加载 \(voice.name)…"
        }

        workQueue.async { [weak self] in
            guard let self else { return }
            self.synthesizer?.releaseEngine()
            self.synthesizer = nil
            self.loadedVoiceId = nil

            var lastCode: Int32 = 0
            var lastDesc = ""
            var lastPairing = ""
            var loaded = false
            var usedPairing = ""

            outer: for (textName, textPath) in pairings {
                let model = [
                    BDSSpeechSynthesizerParams.ttsTextModelFile: textPath,
                    BDSSpeechSynthesizerParams.ttsSpeechModelFile: speechPath
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: model),
                      let modelJSON = String(data: data, encoding: .utf8) else {
                    continue
                }
                for serial in BaiduOfflineTTS.serialNumbers {
                    let synth = BDSSpeechSynthesizer(delegate: self)
                    _ = synth.setParam(BDSSpeechSynthesizerParams.paramAppId, value: BaiduOfflineTTS.appId)
                    _ = synth.setParam(BDSSpeechSynthesizerParams.paramAuthSerialNumber, value: serial)
                    _ = synth.setParam(BDSSpeechSynthesizerParams.paramOfflineModel, value: modelJSON)
                    let result = BaiduBundleShim.withOverride { synth.loadOfflineEngine() }
                    if result.code == 0 {
                        self.synthesizer = synth
                        loaded = true
                        usedPairing = textName
                        break outer
                    }
                    lastCode = result.code
                    lastDesc = result.desc
                    lastPairing = textName
                    synth.releaseEngine()
                    // 只有授权类错误才换下一条 SN，其它错误换也没用
                    let authCodes: Set<Int32> = [-100, -102, -105, -106, -107, -124]
                    if !authCodes.contains(result.code) { break }
                }
            }

            if loaded {
                DispatchQueue.main.async {
                    self.loadedVoiceId = voice.id
                    self.isPreparing = false
                    self.statusText = usedPairing == voice.textFileName
                        ? "已加载 \(voice.name)"
                        : "已加载 \(voice.name)（用 SDK 文本模型）"
                    self.lastError = nil
                }
                completion(.success(()))
            } else {
                let error = NSError(
                    domain: "BaiduOfflineTTS",
                    code: Int(lastCode),
                    userInfo: [NSLocalizedDescriptionKey: "离线引擎加载失败 \(lastCode)（文本模型 \(lastPairing)）：\(lastDesc)"]
                )
                self.publish(error: error, voice: voice)
                completion(.failure(error))
            }
        }
    }

    private func publish(error: Error, voice: Voice) {
        DispatchQueue.main.async {
            self.isPreparing = false
            self.lastError = error.localizedDescription
            self.statusText = "\(voice.name) 加载失败"
        }
    }

    /// 设置面板里的「加载 / 激活引擎」用，第一次联网取授权。
    func preload(voice: Voice) {
        ensureEngine(voice: voice) { _ in }
    }

    func resetEngine() {
        clearError()
        workQueue.async { [weak self] in
            guard let self else { return }
            self.synthesizer?.releaseEngine()
            self.synthesizer = nil
            DispatchQueue.main.async {
                self.loadedVoiceId = nil
                self.statusText = "未加载"
            }
        }
    }

    /// 门面每次起播前清一次错误位。lastError 是 private(set)，外面改不了。
    func clearError() {
        if lastError != nil { lastError = nil }
    }

    // MARK: - 播放

    func start(voice: Voice, text: String, speed: Int, maxChunkLength: Int = 150) {
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
        ensureEngine(voice: voice) { [weak self] result in
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
            NSLog("[BaiduOfflineTTS] 音频会话激活失败：\(error)")
        }
    }

    private func speakChunk(at index: Int, speed: Int) {
        guard !cancelled, let synthesizer, index < chunks.count else {
            finish()
            return
        }
        currentIndex = index
        lastSpeed = speed
        // 离线语速区间 0..15，5 是 1 倍速
        let paramSpeed = min(15, max(0, speed))
        _ = synthesizer.setParam(BDSSpeechSynthesizerParams.paramSpeed, value: "\(paramSpeed)")

        let utteranceId = UUID().uuidString
        pendingUtteranceId = utteranceId
        let entity = BDSSpeechEntity(text: chunks[index], mode: .offline, utteranceId: utteranceId, params: nil)
        let result = BaiduBundleShim.withOverride { synthesizer.speak(entity) }
        if result.code != 0 {
            DispatchQueue.main.async {
                self.lastError = "合成失败 \(result.code)：\(result.desc)"
            }
            advance()
        }
    }

    private func advance() {
        let next = currentIndex + 1
        if next < chunks.count {
            // 语速已经在 speakChunk 里设过，这里复用上一次的设定
            speakChunk(at: next, speed: lastSpeed)
        } else {
            finish()
        }
    }

    private var lastSpeed = 5

    private func finish() {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isPaused = false
            self.onFinish?()
        }
    }
}

extension BaiduOfflineTTS: BDSSpeechSynthesizerDelegate {
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
            // 只认播报结束，合成结束还会接着播，不能拿它推进
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

#else
// 没有百度离线 SDK 的构建（比如 CI）：只提供同形状的空实现，功能关掉
import Foundation
import Combine

public final class BaiduOfflineTTS: ObservableObject {
    public struct Voice: Identifiable, Hashable {
        public var id: String
        public var name: String
        public var note: String
        public init(id: String, name: String, note: String = "") {
            self.id = id
            self.name = name
            self.note = note
        }
    }

    public static let shared = BaiduOfflineTTS()

    @Published public private(set) var isPlaying = false
    @Published public private(set) var isPaused = false
    @Published public private(set) var currentIndex = 0
    @Published public private(set) var totalChunks = 0
    @Published public private(set) var lastError: String?
    @Published public private(set) var loadedVoiceId: String?
    @Published public private(set) var isPreparing = false
    @Published public private(set) var statusText = "未编译百度离线引擎"
    @Published public private(set) var authReport: String = ""

    public var onFinish: (() -> Void)?

    public static var allVoices: [Voice] { [] }
    public static var userVoices: [Voice] { [] }
    // 真机那边这两项读 BaiduCredentials；桩实现也得有同形状的成员，
    // 否则设置页里「授权用：APP ID …」那段在模拟器/CI 编不过。
    public static var appId: String { "" }
    public static var serialNumbers: [String] { [] }
    public static var activeVoiceId: String? {
        get { nil }
        set { }
    }
    public static var activeVoice: Voice? { nil }
    public static func voice(id: String?) -> Voice? { nil }
    @discardableResult public static func deleteVoices(_ voices: [Voice]) -> Int { 0 }
    public static func refreshUserVoices() -> [Voice] { [] }
    @discardableResult public static func importPackage(from zipURL: URL) throws -> Int { 0 }
    public func preload(voice: Voice) {}
    public func authorizationProbe() {
        authReport = "这个构建没带百度离线引擎。"
    }
    public func resetEngine() {}
    public func clearError() {}
    public func diagnose(voice: Voice) -> [String] { ["这个构建没带百度离线引擎，无法诊断。"] }
    public static func enableVoice(_ id: String) { }
    public static func setActiveVoiceId(_ id: String?) { }

    public func start(voice: Voice, text: String, speed: Int, maxChunkLength: Int = 150) {
        lastError = "这个构建没带百度离线引擎。"
    }
    public func stop() {}
    public func pause() {}
    public func resume() {}
}
#endif
