import Foundation
import Combine

/// 一个能拿来朗读的离线音色。
///
/// 包内自带的与用户导入的共用一套结构：目录里必须有 `*.onnx`（声学模型）
/// 和 `tokens.txt`（词表），`espeak-ng-data` 可有可无——没有它的模型读英文
/// 和数字会走默认规则，中文照常。
struct LocalTTSModel: Identifiable, Hashable {
    enum Origin: String {
        case bundled
        case imported
    }

    /// 声学模型族。VITS 和 Kokoro 在 sherpa-onnx 里是两套完全不同的配置结构，
    /// 靠目录里有没有 `voices.bin` 区分——Kokoro 的音色是打包在 weights 里的，
    /// 才需要这个文件。
    enum Family: String {
        case vits
        case kokoro
    }

    /// `bundle:huayan` / `user:<目录名>`。持久化就用它，目录被删自然失效。
    let id: String
    let name: String
    let folder: URL
    let modelFile: URL
    let tokensFile: URL
    let voicesFile: URL?
    let family: Family
    /// 有的模型带 `lexicon.txt`（piper 中文那几支），没有就用 espeak-ng-data。
    let lexiconFile: URL?
    /// Kokoro ≥1.0 的多语模型只认 `lexicon` 或 `lang` 二者之一，否则前端直接 abort。
    /// 词典文件名本身就是语言标记：`lexicon-zh.txt` → `zh`，`lexicon.txt` 推不出来。
    var lexiconLanguage: String? {
        guard let lexiconFile else { return nil }
        let stem = lexiconFile.deletingPathExtension().lastPathComponent
        let prefix = "lexicon-"
        guard stem.hasPrefix(prefix), stem.count > prefix.count else { return nil }
        return String(stem.dropFirst(prefix.count))
    }
    let dataDir: URL?
    /// 文本规则 FST（Melo、aishell3 这类包带的 `date.fst` / `number.fst`）。
    /// sherpa 顶层 `rule_fsts` 字段按串起来的顺序依次应用，顺序错了日期会先被拆成
    /// 单个数字，再想拼回去就没救了。
    let ruleFsts: [URL]
    let origin: Origin
    let sizeBytes: Int64

    var subtitle: String {
        "\(origin == .bundled ? "包内" : "导入") · \(Self.sizeText(sizeBytes))"
    }

    static func sizeText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 10 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }
}

/// 扫描、持久化、导入离线音色模型。
///
/// 包内模型是 `Resources/TTSModel` 这个蓝色文件夹，整个目录进了 bundle，
/// 往里加一个子目录就等于多一个音色，不用改工程文件。用户导入的落
/// `Documents/TTSModels/<名>`，跟包内的并列显示。
final class LocalTTSModelStore: ObservableObject {
    static let shared = LocalTTSModelStore()

    static let modelKey = "juyue_tts_local_model"
    static let speakerKey = "juyue_tts_local_speaker"
    static let hiddenKey = "juyue_tts_local_hidden"

    @Published private(set) var models: [LocalTTSModel] = []
    @Published private(set) var selectedId: String
    @Published private(set) var speakerId: Int
    /// 引擎真正加载过之后回报的发音人数；没加载过的模型按 1 算。
    @Published private(set) var speakerCounts: [String: Int] = [:]
    /// 包内模型删不掉文件，只能从列表里藏起来；导入的走真删。
    @Published private(set) var hiddenIds: Set<String> = []

    enum ImportError: LocalizedError {
        case emptySelection
        case missingModel
        case missingTokens
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptySelection: return "没选到文件夹"
            case .missingModel: return "文件夹里找不到 .onnx 模型"
            case .missingTokens: return "文件夹里找不到 tokens.txt"
            case .copyFailed(let detail): return "拷进文档目录失败：\(detail)"
            }
        }
    }

    private init() {
        selectedId = UserDefaults.standard.string(forKey: Self.modelKey) ?? ""
        speakerId = UserDefaults.standard.integer(forKey: Self.speakerKey)
        hiddenIds = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        reload()
    }

    var available: Bool { !models.isEmpty }

    var selected: LocalTTSModel? {
        models.first { $0.id == selectedId } ?? models.first
    }

    /// 当前模型能选几个发音人。单说话人模型返回 1，UI 据此决定藏不藏这一行。
    var speakerCount: Int {
        guard let id = selected?.id else { return 1 }
        return max(1, speakerCounts[id] ?? 1)
    }

    // MARK: - 扫描

    func reload() {
        var found: [LocalTTSModel] = []
        found += scan(Self.bundleRoot, origin: .bundled)
        found += scan(Self.userRoot, origin: .imported)
        let visible = found.filter { !hiddenIds.contains($0.id) }
        models = visible

        if !visible.contains(where: { $0.id == selectedId }) {
            selectedId = visible.first?.id ?? ""
            persistSelection()
        }
    }

    private static var bundleRoot: URL {
        Bundle.main.bundleURL.appendingPathComponent("TTSModel", isDirectory: true)
    }

    private static var userRoot: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("TTSModels", isDirectory: true)
    }

    private func scan(_ root: URL, origin: LocalTTSModel.Origin) -> [LocalTTSModel] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [LocalTTSModel] = []
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let id = "\(origin == .bundled ? "bundle" : "user"):\(dir.lastPathComponent)"
            if let model = makeModel(folder: dir, origin: origin, id: id) {
                result.append(model)
            }
        }
        return result
    }

    private func makeModel(folder: URL, origin: LocalTTSModel.Origin, id: String) -> LocalTTSModel? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        guard let onnx = files.first(where: {
            $0.pathExtension == "onnx" && !$0.lastPathComponent.hasSuffix(".onnx.json")
        }) else { return nil }

        let tokens = folder.appendingPathComponent("tokens.txt")
        guard FileManager.default.fileExists(atPath: tokens.path) else { return nil }

        let data = folder.appendingPathComponent("espeak-ng-data", isDirectory: true)
        let hasData = FileManager.default.fileExists(atPath: data.path)
        // 先认通用的 `lexicon.txt`，再认多语 Kokoro 的 `lexicon-<lang>.txt`。
        let lexicon = ["lexicon.txt", "lexicon-zh.txt"]
            .map { folder.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let voices = folder.appendingPathComponent("voices.bin")
        let hasVoices = FileManager.default.fileExists(atPath: voices.path)
        // 顺序取官方 melo demo 的排法：日期在数字前面，读音修正在后。
        // 没见过的规则文件排最后并按名字定序，免得同一目录两次扫描顺序不同。
        let fstOrder = ["date.fst", "phone.fst", "number.fst", "new_heteronym.fst"]
        let ruleFsts = files.filter { $0.pathExtension == "fst" }
            .sorted { lhs, rhs in
                let li = fstOrder.firstIndex(of: lhs.lastPathComponent) ?? fstOrder.count
                let ri = fstOrder.firstIndex(of: rhs.lastPathComponent) ?? fstOrder.count
                return li == ri ? lhs.lastPathComponent < rhs.lastPathComponent : li < ri
            }

        return LocalTTSModel(
            id: id,
            name: Self.displayName(id: id, folder: folder, origin: origin),
            folder: folder,
            modelFile: onnx,
            tokensFile: tokens,
            voicesFile: hasVoices ? voices : nil,
            family: hasVoices ? .kokoro : .vits,
            lexiconFile: lexicon,
            dataDir: hasData ? data : nil,
            ruleFsts: ruleFsts,
            origin: origin,
            sizeBytes: Self.folderSize(folder)
        )
    }

    /// 目录名是拼音的，列表里给个能读的名字；用户自己导入的就用目录名。
    private static func displayName(id: String, folder: URL, origin: LocalTTSModel.Origin) -> String {
        let raw = folder.lastPathComponent
        if origin == .bundled {
            switch raw {
            case "huayan": return "华言 · 普通话女声"
            case "melo": return "梅洛 · 普通话女声（44.1kHz）"
            case "xiao_ya": return "小雅 · 普通话女声"
            default: break
            }
        }
        return raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func folderSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total += Int64(v.fileAllocatedSize ?? v.fileSize ?? 0)
        }
        return total
    }

    // MARK: - 选择

    func select(_ model: LocalTTSModel, speaker: Int = 0) {
        selectedId = model.id
        speakerId = speaker
        persistSelection()
    }

    /// 引擎加载完一个模型后回报真实发音人数，UI 才知道要不要出「发音人」这一行。
    func report(speakers: Int, for id: String) {
        guard speakerCounts[id] != speakers else { return }
        speakerCounts[id] = speakers
        if speakers <= 1 { speakerId = 0 }
    }

    private func persistSelection() {
        UserDefaults.standard.set(selectedId, forKey: Self.modelKey)
        UserDefaults.standard.set(speakerId, forKey: Self.speakerKey)
    }

    // MARK: - 导入 / 删除

    /// 把用户选的文件夹整个拷进 `Documents/TTSModels`，校验不过就不落盘。
    @discardableResult
    func importModel(from picked: URL) throws -> LocalTTSModel {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

        guard let source = Self.resolveModelFolder(picked) else {
            throw Self.diagnose(picked)
        }

        let name = Self.uniqueFolderName(base: source.lastPathComponent)
        let dest = Self.userRoot.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: Self.userRoot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }

        reload()
        let id = "user:\(name)"
        guard let model = models.first(where: { $0.id == id }) else {
            throw ImportError.missingModel
        }
        select(model)
        return model
    }

    /// 列表里划掉一个音色。导入的真删；包内的删不得文件，只能藏起来（可恢复）。
    func remove(_ model: LocalTTSModel) {
        switch model.origin {
        case .imported:
            try? FileManager.default.removeItem(at: model.folder)
        case .bundled:
            hiddenIds.insert(model.id)
            persistHidden()
        }
        if selectedId == model.id { selectedId = "" }
        reload()
    }

    var hasHidden: Bool { !hiddenIds.isEmpty }

    func restoreHidden() {
        hiddenIds.removeAll()
        persistHidden()
        reload()
    }

    private func persistHidden() {
        UserDefaults.standard.set(Array(hiddenIds), forKey: Self.hiddenKey)
    }

    /// 用户可能选到「装模型的上一级目录」，往里看一层也认。
    private static func resolveModelFolder(_ url: URL) -> URL? {
        if isValidModelFolder(url) { return url }
        let subs = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        let dirs = subs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if dirs.count == 1, let only = dirs.first, isValidModelFolder(only) { return only }
        return nil
    }

    private static func isValidModelFolder(_ url: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        let hasModel = files.contains { $0.hasSuffix(".onnx") }
        let hasTokens = files.contains("tokens.txt")
        return hasModel && hasTokens
    }

    private static func diagnose(_ url: URL) -> ImportError {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return .emptySelection
        }
        if !files.contains(where: { $0.hasSuffix(".onnx") }) { return .missingModel }
        return .missingTokens
    }

    private static func uniqueFolderName(base: String) -> String {
        let clean = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = clean.isEmpty ? "model" : clean.replacingOccurrences(of: "/", with: "-")
        var candidate = safe
        var n = 2
        while FileManager.default.fileExists(
            atPath: userRoot.appendingPathComponent(candidate).path
        ) {
            candidate = "\(safe)-\(n)"
            n += 1
        }
        return candidate
    }
}
