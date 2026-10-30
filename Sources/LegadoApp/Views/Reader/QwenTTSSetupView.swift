import SwiftUI
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 自建 TTS 地址页的规则与默认值，全部集中在这里，页面只管读写。
///
/// 这一页以前只管 Qwen3-TTS：主机、端口、音色三格，规则写死成 `/tts?...`。
/// 现在地址模板整条交给用户，`{{ }}` 由 `TTSTemplateRenderer` 求值，
/// 只要服务回了音频就接得上；Qwen3 那套规则留成「一键填入」，没丢。
enum CustomTTSSetup {
    /// 试听念这一句：够长，能量出编码和音频格式对不对。
    static let sampleText = "橘阅的自建语音接通了，念一段给你听。"

    static let defaultName = "自建 TTS"

    /// Qwen3-TTS 服务端的默认规则，跟改版前 `QwenTTSSetup.urlRule` 拼出来的一字不差。
    static let qwenTemplate = "http://127.0.0.1:9880/tts?text={{java.encodeURI(speakText)}}&speaker=vivian&speed={{speakSpeed}}"
    static let qwenHealth = "http://127.0.0.1:9880/health"

    /// 同一份模板固定一个 id，重复保存是覆盖，不会在列表里堆一串重复源。
    static func sourceId(for key: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int64(hash & 0x7fff_ffff_ffff_ffff)
    }

    /// 拿样例文本把模板渲染一遍：页面上直接给人看展开结果，省得保存后才发现 `{{ }}` 拼错。
    static func renderSample(_ template: String) -> String {
        let context = TTSTemplateContext(speakText: sampleText, speakSpeed: 10)
        return (try? TTSTemplateRenderer.shared.render(template, context: context))
            ?? "（模板有语法错，先修 {{ }} 再存）"
    }

    /// 存源用的宽松校验：光有地址没有 `{{`，服务端收不到要念的字。
    static func validate(_ template: String) -> String? {
        let text = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "地址模板空着" }
        if !text.contains("{{") { return "模板里少了 {{speakText}}，服务端不知道念哪段" }
        if !text.lowercased().hasPrefix("http") { return "地址得以 http 开头" }
        return nil
    }
}

/// 自建 TTS：填一条地址模板 → 试听 → 存成 HTTP 语音源并设为当前。
///
/// 走的是既有的 HTTP 语音源通道，不新增引擎类型；存完以后在语音源管理里跟别的源一样能删。
struct CustomTTSSetupView: View {
    @Environment(\.appTheme) private var theme

    @State private var name = CustomTTSSetup.defaultName
    @State private var template = CustomTTSSetup.qwenTemplate
    /// 可选：填了就点「连接测试」打一下，空白就跳过这一步。
    @State private var healthURL = CustomTTSSetup.qwenHealth
    @State private var message: String?
    @State private var isError = false
    @State private var busy = false
    #if canImport(AVFoundation)
    @State private var previewPlayer: AVAudioPlayer?
    #endif

    var body: some View {
        TTSPageShell(
            code: "READ / VOICE",
            title: "自建 TTS",
            detail: "地址模板",
            doneLabel: nil,
            embedsNavigation: false
        ) {
            Section {
                TextField("源名字，比如 家里的 Qwen3", text: $name)
                    .ttsURLField()
            } header: {
                Text("名称")
            } footer: {
                Text("仅用于列表显示，与请求地址无关。")
            }
            .appThemedRows()

            Section {
                TextEditor(text: $template)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 96)
                    .themedScrollBackground()
                    .background(theme.palette.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.palette.secondaryInk.opacity(0.25), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundColor(theme.palette.ink)
                    .ttsURLField()
                Button {
                    template = CustomTTSSetup.qwenTemplate
                    healthURL = CustomTTSSetup.qwenHealth
                    if name == CustomTTSSetup.defaultName { name = "Qwen3-TTS" }
                    message = "已填入 Qwen3-TTS 的默认规则，改地址和端口就行。"
                    isError = false
                } label: {
                    Label("填入 Qwen3-TTS 默认规则", systemImage: "wand.and.stars")
                }
            } header: {
                Text("地址模板")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("`{{speakText}}` 为当前段落文本，`{{speakSpeed}}` 为语速（10 = 1.0×）。文本含 `&`、`?` 时需套一层 `{{java.encodeURI(...)}}`，否则查询串会被截断。")
                    Text("要在请求头里带 Key，地址后面跟一段 JSON：`,{\"headers\":{\"Authorization\":\"Bearer xxx\"}}`")
                }
                .font(.caption2)
            }
            .appThemedRows()

            Section {
                TextField("可选，比如 http://192.168.1.5:9880/health", text: $healthURL)
                    .ttsURLField()
                Button {
                    Task { await probe() }
                } label: {
                    Label(busy ? "正在连接…" : "连接测试", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(busy || healthURL.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("测活（可选）")
            } footer: {
                Text("仅接受 200–299，响应原样显示。留空则跳过测试，以试听是否出声为准。")
            }
            .appThemedRows()

            if let message {
                Section {
                    Text(message)
                        .font(theme.typography.mono)
                        .foregroundColor(isError ? .red : theme.palette.secondaryInk)
                } header: {
                    Text("状态")
                }
                .appThemedRows()
            }

            Section {
                Text(CustomTTSSetup.renderSample(template))
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
                Button {
                    preview()
                } label: {
                    Label(busy ? "合成中…" : "试听这一段", systemImage: "waveform")
                }
                .disabled(busy)
            } header: {
                Text("展开后的样子")
            } footer: {
                Text("试听使用上方样例文本。整章共用同一音色，按角色换声需要系统语音。")
            }
            .appThemedRows()

            Section {
                Button {
                    save()
                } label: {
                    Label("保存并设为当前语音源", systemImage: "checkmark.circle")
                }
            } footer: {
                if let problem = CustomTTSSetup.validate(template) {
                    Text(problem).font(.caption2).foregroundColor(.red)
                } else {
                    Text("保存后可在「管理语音引擎」修改或删除。")
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                }
            }
            .appThemedRows()
        }
    }

    // MARK: - 网络

    private func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, code)
    }

    @MainActor
    private func probe() async {
        busy = true
        message = nil
        defer { busy = false }
        let text = healthURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text) else {
            isError = true
            message = "测活地址填得不对：\(text)"
            return
        }
        do {
            let (data, code) = try await get(url)
            let body = String(data: data.prefix(200), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "（\(data.count) 字节，非文本）"
            isError = !(200...299).contains(code)
            message = "HTTP \(code)：\(body.isEmpty ? "空响应" : body)"
        } catch {
            isError = true
            message = "连不上 \(text)：\(error.localizedDescription)"
        }
    }

    // MARK: - 存源 / 试听

    /// 用同一份模板真合成一段：URL 规则、`{{ }}` 求值、音频格式三件事一起验。
    private func preview() {
        if let problem = CustomTTSSetup.validate(template) {
            isError = true
            message = problem
            return
        }
        let rule = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = HttpTTS(
            id: CustomTTSSetup.sourceId(for: rule),
            name: displayName,
            url: rule,
            contentType: nil,
            speed: 10
        )
        busy = true
        message = nil
        Task {
            do {
                let audio = try await HttpTTSEngine.shared.fetchAudio(
                    source: source,
                    text: CustomTTSSetup.sampleText,
                    speed: 10
                )
                await MainActor.run {
                    play(data: audio.data)
                    busy = false
                    isError = false
                    message = "试听已播放：\(audio.data.count) 字节 · \(audio.contentType ?? "类型未知")"
                }
            } catch {
                await MainActor.run {
                    busy = false
                    isError = true
                    message = "试听失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? CustomTTSSetup.defaultName : trimmed
    }

    private func play(data: Data) {
        #if canImport(AVFoundation)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        previewPlayer?.stop()
        previewPlayer = try? AVAudioPlayer(data: data)
        previewPlayer?.play()
        #endif
    }

    private func save() {
        if let problem = CustomTTSSetup.validate(template) {
            isError = true
            message = problem
            return
        }
        let rule = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = HttpTTS(
            id: CustomTTSSetup.sourceId(for: rule),
            name: displayName,
            url: rule,
            contentType: nil,
            speed: 10
        )
        do {
            let store = HttpTTSStore.shared
            try? store.load()
            guard let json = String(data: try JSONEncoder().encode(source), encoding: .utf8) else {
                throw SetupError.message("规则序列化失败")
            }
            _ = try store.importJSON(json)
            TTSourceSelection.activeId = source.id
            TTSEngineChoice.current = .http
            isError = false
            message = "已保存并设为当前语音源：\(source.name)"
        } catch {
            isError = true
            message = "保存失败：\(error.localizedDescription)"
        }
    }
}

enum SetupError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// 地址输入框：关自动大写和自动更正，不然 URL 里的大小写会被顺手改掉。
private extension View {
    @ViewBuilder
    func ttsURLField() -> some View {
        #if os(iOS)
        self.keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
