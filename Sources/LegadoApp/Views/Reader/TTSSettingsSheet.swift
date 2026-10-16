import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 听书设置：选引擎、调语速、调分段长度、试听。
public struct TTSSettingsSheet: View {
    @ObservedObject private var audio = AudioBookService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [HttpTTS] = []
    @State private var activeId: Int64? = TTSourceSelection.activeId
    @State private var testResult: String?
    @State private var isTesting = false
    #if os(iOS)
    @ObservedObject private var baidu = BaiduOfflineTTS.shared
    @ObservedObject private var baiduOnline = BaiduOnlineTTS.shared
    @State private var baiduVoiceId: String? = BaiduOfflineTTS.activeVoiceId
    @State private var baiduSpeakerId: String? = BaiduOnlineTTS.activeSpeakerId
    @State private var baiduVoices: [BaiduOfflineTTS.Voice] = BaiduOfflineTTS.allVoices
    @State private var diagLines: [String] = []
    @State private var showImporter = false
    @State private var showVoiceManager = false
    @State private var importMessage: String?
    #endif
    @State private var systemVoiceId: String? = SystemVoiceSelection.identifier
    @State private var customSpeakerId: String = ""
    @ObservedObject private var cast = TTSCastStore.shared

    public init() {}

    public var body: some View {
        NavigationView {
            Form {
                Section(header: Text("引擎")) {
                    engineRow(name: "系统语音", subtitle: "iOS 内置，离线可用", selected: activeId == nil) {
                        select(nil)
                    }

                    ForEach(SystemVoiceSelection.chineseVoices, id: \.identifier) { voice in
                        engineRow(
                            name: voice.name,
                            subtitle: "系统音色 · \(languageLabel(voice.language)) · \(SystemVoiceSelection.qualityLabel(voice))",
                            selected: systemVoiceId == voice.identifier && activeId == nil
                        ) {
                            selectSystem(voice)
                        }
                    }

                    Text(systemVoiceHint)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    #if os(iOS)
                    ForEach(baiduVoices) { voice in
                        engineRow(
                            name: voice.name,
                            subtitle: "百度离线 · \(voice.note)",
                            selected: baiduVoiceId == voice.id
                        ) {
                            selectBaidu(voice)
                        }
                    }

                    ForEach(BaiduOnlineTTS.speakers) { speaker in
                        engineRow(
                            name: speaker.name,
                            subtitle: "\(speaker.note)",
                            selected: baiduSpeakerId == speaker.id
                        ) {
                            selectBaiduOnline(speaker)
                        }
                    }
                    #endif

                    ForEach(sources, id: \.id) { source in
                        engineRow(
                            name: source.name,
                            subtitle: host(of: source.url),
                            selected: activeId == source.id
                        ) {
                            select(source.id)
                        }
                    }

                    NavigationLink(destination: TTSourceManagerView()) {
                        Label("管理 / 导入语音源", systemImage: "square.and.arrow.down")
                    }
                }

                #if os(iOS)
                Section(header: Text("百度离线引擎")) {
                    HStack {
                        Text(baidu.statusText)
                        Spacer()
                        if baidu.isPreparing {
                            ProgressView()
                        }
                    }
                    .font(.footnote)

                    Button("加载 / 激活引擎") {
                        guard let voice = BaiduOfflineTTS.voice(id: baiduVoiceId) ?? baiduVoices.first else { return }
                        baidu.preload(voice: voice)
                    }
                    .font(.footnote)

                    Button("诊断音库文件") {
                        diagLines = baiduVoices.flatMap { voice -> [String] in
                            ["【\(voice.name)】"] + baidu.diagnose(voice: voice)
                        }
                    }
                    .font(.footnote)

                    Button {
                        showImporter = true
                    } label: {
                        Label("导入音库包（zip）", systemImage: "square.and.arrow.down")
                    }
                    .font(.footnote)

                    if !BaiduOfflineTTS.userVoices.isEmpty {
                        Button {
                            showVoiceManager = true
                        } label: {
                            Label("管理自备音色（\(BaiduOfflineTTS.userVoices.count)）", systemImage: "trash")
                        }
                        .font(.footnote)
                    }

                    if let importMessage {
                        Text(importMessage)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    ForEach(diagLines, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    if let error = baidu.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }

                    Text("首次激活要联网，SDK 会拿 APP ID + 序列号换授权文件，之后可以断网用。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("百度在线引擎")) {
                    HStack {
                        Text(baiduOnline.statusText)
                        Spacer()
                        if baiduOnline.isPreparing {
                            ProgressView()
                        }
                    }
                    .font(.footnote)

                    Button("取 token / 加载在线引擎") {
                        guard let speaker = BaiduOnlineTTS.speaker(id: baiduSpeakerId) ?? BaiduOnlineTTS.speakers.first else { return }
                        baiduOnline.preload(speaker: speaker)
                    }
                    .font(.footnote)

                    HStack {
                        TextField("自定义音色 ID", text: $customSpeakerId)
                            .font(.footnote)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        Button("用这个") {
                            let id = customSpeakerId.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !id.isEmpty, let speaker = BaiduOnlineTTS.speaker(id: id) else { return }
                            selectBaiduOnline(speaker)
                        }
                        .font(.footnote)
                    }

                    if let error = baiduOnline.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }

                    Text("在线合成走网络，不吃序列号。access_token 有效期 30 天，过期自动重取。精品音色要在控制台开通过才能用。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                #endif

                #if os(iOS)
                Section {
                    NavigationLink(destination: BaiduCredentialView()) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("百度语音授权")
                            Text(BaiduCredentials.hasCustomValues ? "用的是自己填的凭据" : "用的 App 内置默认凭据")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    Text("APP ID / API Key / Secret Key / 离线序列号。填了就以填的为准，留空回落到内置默认。")
                }
                #endif

                Section(header: Text("语速")) {
                    HStack {
                        Text("\(String(format: "%.1f", audio.speechRate / AVSpeechUtteranceDefaultSpeechRate))×")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 48, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { Double(audio.speechRate) },
                                set: { audio.speechRate = Float($0) }
                            ),
                            in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate * 1.6),
                            step: 0.01
                        )
                    }
                    Button("恢复默认语速") {
                        audio.speechRate = AVSpeechUtteranceDefaultSpeechRate
                    }
                    .font(.footnote)
                }

                Section(header: Text("分段")) {
                    HStack {
                        Text("\(audio.chunkLength) 字")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 72, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { Double(audio.chunkLength) },
                                set: { audio.chunkLength = Int($0) }
                            ),
                            in: 60...400,
                            step: 10
                        )
                    }
                    Text("在线语音源会按这个长度切段再合成。太长容易超时或被服务器截断。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle("按角色换音色", isOn: $cast.enabled)

                    if cast.roles.isEmpty {
                        Button {
                            cast.makeStarterRoles()
                        } label: {
                            Label("生成一套默认角色（旁白 + 对话）", systemImage: "person.2.badge.plus")
                        }
                    }

                    ForEach($cast.roles) { $role in
                        NavigationLink {
                            TTSCastRoleEditor(role: $role)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(role.name.isEmpty ? "（未命名角色）" : role.name)
                                Text("\(role.match.rawValue) · \(role.engine.rawValue) · \(castVoiceLabel(role))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        cast.roles.remove(atOffsets: indexSet)
                    }

                    Button {
                        cast.roles.append(TTSCastRole(name: "新角色"))
                    } label: {
                        Label("添加角色", systemImage: "plus")
                    }
                } header: {
                    Text("多角色朗读")
                } footer: {
                    Text("打开后按段落切分：引号里的对话走「对话」角色，正文走旁白，命名角色按关键词命中。逐段换音色只支持系统语音和百度在线；HTTP 语音源仍是整章一个音色。")
                }

                Section {
                    Button {
                        audio.stop()
                        audio.preview()
                    } label: {
                        Label("试听当前引擎", systemImage: "waveform")
                    }
                    if audio.isPlaying {
                        Button(role: .destructive) {
                            audio.stop()
                        } label: {
                            Label("停止", systemImage: "stop.fill")
                        }
                    }
                } footer: {
                    Text("当前：\(audio.currentEngineName)")
                }
            }
            .navigationTitle("听书设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { reloadSources() }
            #if os(iOS)
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.archive, .zip, .item],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .sheet(isPresented: $showVoiceManager) {
                BaiduVoiceManagerSheet { deleted in
                    baiduVoices = BaiduOfflineTTS.allVoices
                    importMessage = "删掉了 \(deleted) 条自备音色"
                }
            }
            #endif
        }
    }

    #if os(iOS)
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importMessage = "导入失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let count = try BaiduOfflineTTS.importPackage(from: url)
                baiduVoices = BaiduOfflineTTS.allVoices
                importMessage = "导入了 \(url.lastPathComponent)，现在共 \(count) 条自备音色"
            } catch {
                importMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }
    #endif

    @ViewBuilder
    private func engineRow(name: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
            }
        }
    }

    private func host(of rule: String) -> String {
        let firstPiece = rule.split(separator: ",", maxSplits: 1).first.map(String.init) ?? rule
        if let url = URL(string: firstPiece), let host = url.host {
            return host
        }
        return String(firstPiece.prefix(60))
    }

    private func languageLabel(_ code: String) -> String {
        switch code {
        case "zh-CN", "zh_CN": return "大陆"
        case "zh-TW", "zh_TW": return "台湾"
        case "zh-HK", "zh_HK": return "香港"
        default: return code
        }
    }

    private func selectSystem(_ voice: AVSpeechSynthesisVoice) {
        SystemVoiceSelection.identifier = voice.identifier
        systemVoiceId = voice.identifier
        #if os(iOS)
        BaiduOfflineTTS.activeVoiceId = nil
        baiduVoiceId = nil
        BaiduOnlineTTS.activeSpeakerId = nil
        baiduSpeakerId = nil
        #endif
        TTSourceSelection.activeId = nil
        activeId = nil
        audio.stop()
    }

    /// 系统音色区上方的说明文字。
    private var systemVoiceHint: String {
        "想更真人一点：设置 → 辅助功能 → 朗读内容 → 声音 → 中文，把「增强」或「高级」那版下下来，回来这里会标出来。"
    }

    private func reloadSources() {
        let store = HttpTTSStore.shared
        try? store.load()
        sources = store.sources
        activeId = TTSourceSelection.activeId
        #if os(iOS)
        BaiduOfflineTTS.refreshUserVoices()
        baiduVoices = BaiduOfflineTTS.allVoices
        #endif
    }

    private func select(_ id: Int64?) {
        #if os(iOS)
        if id == nil {
            BaiduOfflineTTS.activeVoiceId = nil
            baiduVoiceId = nil
            BaiduOnlineTTS.activeSpeakerId = nil
            baiduSpeakerId = nil
        }
        #endif
        SystemVoiceSelection.identifier = nil
        systemVoiceId = nil
        TTSourceSelection.activeId = id
        activeId = id
        audio.stop()
    }

    #if os(iOS)
    private func selectBaidu(_ voice: BaiduOfflineTTS.Voice) {
        BaiduOfflineTTS.activeVoiceId = voice.id
        baiduVoiceId = voice.id
        BaiduOnlineTTS.activeSpeakerId = nil
        baiduSpeakerId = nil
        SystemVoiceSelection.identifier = nil
        systemVoiceId = nil
        TTSourceSelection.activeId = nil
        activeId = nil
        audio.stop()
    }

    private func selectBaiduOnline(_ speaker: BaiduOnlineTTS.Speaker) {
        BaiduOnlineTTS.activeSpeakerId = speaker.id
        baiduSpeakerId = speaker.id
        BaiduOfflineTTS.activeVoiceId = nil
        baiduVoiceId = nil
        SystemVoiceSelection.identifier = nil
        systemVoiceId = nil
        TTSourceSelection.activeId = nil
        activeId = nil
        audio.stop()
    }
    #endif
}

#if os(iOS)
/// 自备音色管理：多选、批量删。
struct BaiduVoiceManagerSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var voices: [BaiduOfflineTTS.Voice] = BaiduOfflineTTS.userVoices
    @State private var selected: Set<String> = []
    @State private var isSelecting = false
    @State private var showDeleteAlert = false

    let onDeleted: (Int) -> Void

    var body: some View {
        NavigationView {
            List {
                if voices.isEmpty {
                    Text("还没有导进来的音色。用「导入音库包（zip）」加。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(voices) { voice in
                    HStack(spacing: 10) {
                        if isSelecting {
                            Image(systemName: selected.contains(voice.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selected.contains(voice.id) ? .accentColor : .secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.name)
                            Text(voice.note)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard isSelecting else { return }
                        if selected.contains(voice.id) {
                            selected.remove(voice.id)
                        } else {
                            selected.insert(voice.id)
                        }
                    }
                }
            }
            .navigationTitle("自备音色")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isSelecting ? "取消" : "编辑") {
                        isSelecting.toggle()
                        if !isSelecting { selected.removeAll() }
                    }
                    .disabled(voices.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSelecting {
                        Button(selected.isEmpty ? "全选" : "删除 \(selected.count)") {
                            if selected.isEmpty {
                                selected = Set(voices.map { $0.id })
                            } else {
                                showDeleteAlert = true
                            }
                        }
                        .foregroundColor(selected.isEmpty ? .accentColor : .red)
                    } else {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .alert("删除选中的音色？", isPresented: $showDeleteAlert) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { deleteSelected() }
            } message: {
                Text("会把这些音色的文件从设备上删掉。SDK 自带的音色不在这个列表里，删不了。")
            }
        }
    }

    private func deleteSelected() {
        let targets = voices.filter { selected.contains($0.id) }
        let removed = BaiduOfflineTTS.deleteVoices(targets)
        voices = BaiduOfflineTTS.userVoices
        selected.removeAll()
        isSelecting = false
        onDeleted(removed)
    }
}
#endif

/// 单条角色音色的编辑页
struct TTSCastRoleEditor: View {
    @Binding var role: TTSCastRole

    var body: some View {
        Form {
            Section(header: Text("角色")) {
                TextField("角色名（随便起，只影响列表显示）", text: $role.name)

                Picker("什么时候用", selection: $role.match) {
                    ForEach(TTSCastRole.Match.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }

                if role.match == .keyword {
                    TextField("关键词（正文里出现就用这条音色）", text: $role.keyword)
                        .autocorrectionDisabled()
                }

                Toggle("启用这条", isOn: $role.enabled)
            }

            Section {
                Picker("引擎", selection: $role.engine) {
                    ForEach(TTSCastRole.Engine.allCases) { e in
                        Text(e.rawValue).tag(e)
                    }
                }
                .pickerStyle(.segmented)

                switch role.engine {
                case .system:
                    Picker("系统音色", selection: $role.voiceId) {
                        Text("跟随全局设置").tag("")
                        ForEach(SystemVoiceSelection.chineseVoices, id: \.identifier) { voice in
                            Text("\(voice.name) · \(SystemVoiceSelection.qualityLabel(voice))")
                                .tag(voice.identifier)
                        }
                    }

                case .baiduOnline:
                    #if os(iOS)
                    Picker("发音人", selection: $role.voiceId) {
                        Text("跟随全局设置").tag("")
                        ForEach(BaiduOnlineTTS.speakers) { speaker in
                            Text("\(speaker.name) · \(speaker.note)").tag(speaker.id)
                        }
                    }
                    #else
                    Text("百度在线发音人只在 iOS 上可用。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    #endif
                }
            } header: {
                Text("音色")
            } footer: {
                Text("选「跟随全局设置」就用听书设置里当前选的那个音色。")
            }
        }
        .navigationTitle(role.name.isEmpty ? "角色" : role.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// 填自己的百度语音凭据：填了覆盖内置默认值，留空回落默认
struct BaiduCredentialView: View {
    @State private var appId = ""
    @State private var apiKey = ""
    @State private var secretKey = ""
    @State private var serials = ""
    @State private var savedHint: String?

    var body: some View {
        Form {
            Section(header: Text("百度智能云语音")) {
                TextField("APP ID（离线用）", text: $appId)
                    .autocorrectionDisabled()
                TextField("API Key（在线用）", text: $apiKey)
                    .autocorrectionDisabled()
                TextField("Secret Key（在线用）", text: $secretKey)
                    .autocorrectionDisabled()
            }

            Section(header: Text("离线序列号（一行一条）")) {
                TextEditor(text: $serials)
                    .frame(minHeight: 90)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
            }

            Section {
                Button {
                    BaiduCredentials.store(appId: appId, apiKey: apiKey, secretKey: secretKey, serials: serials)
                    savedHint = "已保存，重启 App 后生效。"
                } label: {
                    Label("保存", systemImage: "checkmark.circle")
                }

                Button(role: .destructive) {
                    BaiduCredentials.store(appId: "", apiKey: "", secretKey: "", serials: "")
                    load()
                    savedHint = "已清空，回到内置默认值。"
                } label: {
                    Label("清空并回到默认", systemImage: "arrow.uturn.backward")
                }

                if let savedHint {
                    Text(savedHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } footer: {
                Text("内置默认值是打包时带的那份。公开仓库里默认值为空，需要在这里填自己的 APP ID、API Key、Secret Key 和离线序列号；离线引擎要求序列号与 APP ID 配套。")
            }
        }
        .navigationTitle("百度语音授权")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear(perform: load)
    }

    private func load() {
        let defaults = UserDefaults.standard
        appId = defaults.string(forKey: "baidu_app_id") ?? ""
        apiKey = defaults.string(forKey: "baidu_api_key") ?? ""
        secretKey = defaults.string(forKey: "baidu_secret_key") ?? ""
        serials = defaults.string(forKey: "baidu_serials") ?? ""
    }
}

/// 列表里那行「音色」的显示名
private func castVoiceLabel(_ role: TTSCastRole) -> String {
    guard !role.voiceId.isEmpty else { return "跟随全局" }
    switch role.engine {
    case .system:
        return AVSpeechSynthesisVoice(identifier: role.voiceId)?.name ?? "未知音色"
    case .baiduOnline:
        #if os(iOS)
        return BaiduOnlineTTS.speaker(id: role.voiceId)?.name ?? "未知发音人"
        #else
        return "在线发音人"
        #endif
    }
}
