import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 听书设置：选引擎、调语速、调分段长度、试听。
public struct TTSSettingsSheet: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject private var audio = AudioBookService.shared

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
    #endif
    @State private var engineTab: TTSEngineTab = .system
    @State private var systemVoiceId: String? = SystemVoiceSelection.identifier
    @ObservedObject private var cast = TTSCastStore.shared

    /// 已经被包在别人的导航栈里（设置页推进来）时传 true，外壳不再自造 NavigationView。
    private let embedded: Bool

    public init(embedded: Bool = false) { self.embedded = embedded }

    public var body: some View {
        TTSPageShell(
            code: "READ / VOICE",
            title: "听书设置",
            detail: "引擎 / 音色 / 多角色",
            doneLabel: embedded ? nil : "完成",
            embedsNavigation: !embedded
        ) {

                // 引擎放最外层：四类并行，点一下就换下面那栏音色，不再靠 subtitle 前缀猜归属。
                Section {
                    HStack(spacing: 8) {
                        ForEach(engineTabs) { tab in
                            engineCard(tab)
                        }
                    }
                    .padding(.vertical, 2)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                } header: {
                    Text("引擎")
                } footer: {
                    Text(engineFooter)
                }
                .appThemedRows()

                Section(header: Text(engineTab.voiceSectionTitle)) {
                    voiceRows

                    if engineTab != .custom {
                        Text(engineStatusLine)
                            .font(.caption2)
                            .foregroundColor(isEngineError ? theme.palette.danger : theme.palette.secondaryInk)
                    }
                }
                .appThemedRows()

                Section(header: Text("朗读参数")) {
                    HStack {
                        Text("语速")
                            .font(.footnote)
                            .frame(width: 36, alignment: .leading)
                        Text("\(String(format: "%.1f", audio.speechRate / AVSpeechUtteranceDefaultSpeechRate))×")
                            .font(.system(.footnote, design: .monospaced))
                            .frame(width: 42, alignment: .trailing)
                        Slider(
                            value: Binding(
                                get: { Double(audio.speechRate) },
                                set: { audio.speechRate = Float($0) }
                            ),
                            in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate * 1.6),
                            step: 0.01
                        )
                    }
                    HStack {
                        Text("分段")
                            .font(.footnote)
                            .frame(width: 36, alignment: .leading)
                        Text("\(audio.chunkLength) 字")
                            .font(.system(.footnote, design: .monospaced))
                            .frame(width: 42, alignment: .trailing)
                        Slider(
                            value: Binding(
                                get: { Double(audio.chunkLength) },
                                set: { audio.chunkLength = Int($0) }
                            ),
                            in: 60...400,
                            step: 10
                        )
                    }
                    Text("在线引擎按这个长度切段再合成，太长容易超时或被服务器截断。")
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .appThemedRows()

                Section {
                    Toggle("按角色换音色", isOn: $cast.enabled)

                    if cast.roles.isEmpty {
                        Button {
                            cast.makeStarterRoles()
                        } label: {
                            Label("生成一套默认角色（旁白 + 对话）", systemImage: "person.badge.plus")
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
                                    .foregroundColor(theme.palette.secondaryInk)
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
                .appThemedRows()

                // 管理类的东西全部塞进这一页，主页面只留选择。
                // 商店构建没有百度编译，这一栏就退化成语音源管理，别留死引用。
                #if os(iOS) && !NO_BAIDU_TTS
                Section {
                    NavigationLink(destination: TTSEngineAdvancedView(onVoicesChanged: {
                        baiduVoices = BaiduOfflineTTS.allVoices
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("引擎高级设置")
                            Text(advancedSubtitle)
                                .font(.caption2)
                                .foregroundColor(theme.palette.secondaryInk)
                        }
                    }
                } footer: {
                    Text("激活与诊断、音库导入、百度授权、自定义语音源都在这一层里，主页面不再铺开。")
                }
                .appThemedRows()
                #else
                Section {
                    NavigationLink(destination: TTSourceManagerView()) {
                        Label("管理 / 导入语音源", systemImage: "square.and.arrow.down")
                    }
                }
                .appThemedRows()
                #endif

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
                .appThemedRows()
        }
        .onAppear {
            reloadSources()
            syncEngineTab()
        }
    }

    // MARK: - 引擎切换

    /// 商店包没有百度编译，卡片列表也得跟着少两张。
    private var engineTabs: [TTSEngineTab] {
        var list: [TTSEngineTab] = [.system]
        #if os(iOS) && !NO_BAIDU_TTS
        list += [.baiduOffline, .baiduOnline]
        #endif
        list.append(.custom)
        return list
    }

    private var engineFooter: String {
        switch engineTab {
        case .system: return "iOS 内置合成，离线可用，不占账号。"
        case .baiduOffline: return "本地模型，首次激活要联网换授权，之后断网可用。"
        case .baiduOnline: return "走网络合成，只吃 API Key，不吃离线序列号。"
        case .custom: return "自己填接口模板，接各家在线 TTS。"
        }
    }

    private var engineStatusLine: String {
        switch engineTab {
        case .system:
            return systemVoiceHint
        case .baiduOffline:
            #if os(iOS) && !NO_BAIDU_TTS
            return baidu.statusText
            #else
            return "这个构建没带百度离线引擎。"
            #endif
        case .baiduOnline:
            #if os(iOS) && !NO_BAIDU_TTS
            return baiduOnline.statusText
            #else
            return "这个构建没带百度在线引擎。"
            #endif
        case .custom:
            return "共 \(sources.count) 个语音源"
        }
    }

    private var isEngineError: Bool {
        #if os(iOS) && !NO_BAIDU_TTS
        switch engineTab {
        case .baiduOffline: return baidu.lastError != nil
        case .baiduOnline: return baiduOnline.lastError != nil
        default: return false
        }
        #else
        return false
        #endif
    }

    private var advancedSubtitle: String {
        #if os(iOS) && !NO_BAIDU_TTS
        return "\(baidu.statusText) · \(baiduOnline.statusText)"
        #else
        return "自定义语音源 · 分段"
        #endif
    }

    /// 只显示当前引擎的音色，不再把四类混在一个列表里。
    @ViewBuilder
    private var voiceRows: some View {
        switch engineTab {
        case .system:
            ForEach(SystemVoiceSelection.chineseVoices, id: \.identifier) { voice in
                engineRow(
                    name: voice.name,
                    subtitle: "系统音色 · \(languageLabel(voice.language)) · \(SystemVoiceSelection.qualityLabel(voice))",
                    selected: systemVoiceId == voice.identifier && activeId == nil
                ) {
                    selectSystem(voice)
                }
            }
        case .baiduOffline:
            #if os(iOS) && !NO_BAIDU_TTS
            ForEach(baiduVoices) { voice in
                engineRow(name: voice.name, subtitle: voice.note, selected: baiduVoiceId == voice.id) {
                    selectBaidu(voice)
                }
            }
            #endif
        case .baiduOnline:
            #if os(iOS) && !NO_BAIDU_TTS
            ForEach(BaiduOnlineTTS.speakers) { speaker in
                engineRow(name: speaker.name, subtitle: speaker.note, selected: baiduSpeakerId == speaker.id) {
                    selectBaiduOnline(speaker)
                }
            }
            #endif
        case .custom:
            if sources.isEmpty {
                Text("还没有自定义语音源，去「引擎高级设置」里导入。")
                    .font(.caption)
                    .foregroundColor(theme.palette.secondaryInk)
            }
            ForEach(sources, id: \.id) { source in
                engineRow(name: source.name, subtitle: host(of: source.url), selected: activeId == source.id) {
                    select(source.id)
                }
            }
        }
    }

    private func engineCard(_ tab: TTSEngineTab) -> some View {
        let active = engineTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { engineTab = tab }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 17, weight: .medium))
                Text(tab.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundColor(active ? theme.palette.accent : theme.palette.ink.opacity(0.72))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? theme.palette.accent.opacity(0.12) : theme.palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(active ? theme.palette.accent.opacity(0.55) : theme.palette.divider.opacity(0.6),
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// 进页面时把标签落到当前实际在用的引擎上，免得「选了百度却显示系统」。
    private func syncEngineTab() {
        #if os(iOS) && !NO_BAIDU_TTS
        if baiduVoiceId != nil {
            engineTab = .baiduOffline
            return
        }
        if baiduSpeakerId != nil {
            engineTab = .baiduOnline
            return
        }
        #endif
        engineTab = activeId == nil ? .system : .custom
    }

    @ViewBuilder
    private func engineRow(name: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundColor(theme.palette.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(theme.palette.secondaryInk)
                        .lineLimit(1)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundColor(theme.palette.accent)
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
    @Environment(\.appTheme) private var theme

    @State private var voices: [BaiduOfflineTTS.Voice] = BaiduOfflineTTS.userVoices
    @State private var selected: Set<String> = []
    @State private var isSelecting = false
    @State private var showDeleteAlert = false

    let onDeleted: (Int) -> Void

    var body: some View {
        List {
                if voices.isEmpty {
                    Text("还没有导进来的音色。用「导入音库包（zip）」加。")
                        .font(.footnote)
                        .foregroundColor(theme.palette.secondaryInk)
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
                                .foregroundColor(theme.palette.secondaryInk)
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
        .appThemedList()
        .navigationTitle("自备音色")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // push 之后左上角是返回键，编辑态的两个按钮都放右边，不再抢取消位。
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isSelecting {
                    Button("取消") {
                        isSelecting = false
                        selected.removeAll()
                    }
                    Button(selected.isEmpty ? "全选" : "删除 \(selected.count)") {
                        if selected.isEmpty {
                            selected = Set(voices.map { $0.id })
                        } else {
                            showDeleteAlert = true
                        }
                    }
                    .foregroundColor(selected.isEmpty ? .accentColor : .red)
                } else {
                    Button("编辑") { isSelecting = true }
                        .disabled(voices.isEmpty)
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
    @Environment(\.appTheme) private var theme
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
            .appThemedRows()

            Section {
                Picker("引擎", selection: $role.engine) {
                    ForEach(TTSCastRole.Engine.allCases.filter(AppEdition.isTTSEngineAvailable)) { e in
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
                    #if os(iOS) && !NO_BAIDU_TTS
                    Picker("发音人", selection: $role.voiceId) {
                        Text("跟随全局设置").tag("")
                        ForEach(BaiduOnlineTTS.speakers) { speaker in
                            Text("\(speaker.name) · \(speaker.note)").tag(speaker.id)
                        }
                    }
                    #else
                    Text("这个构建不带百度在线引擎。")
                        .font(.caption)
                        .foregroundColor(theme.palette.secondaryInk)
                    #endif
                }
            } header: {
                Text("音色")
            } footer: {
                Text("选「跟随全局设置」就用听书设置里当前选的那个音色。")
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle(role.name.isEmpty ? "角色" : role.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// 填自己的百度语音凭据：填了覆盖内置默认值，留空回落默认
struct BaiduCredentialView: View {
    @Environment(\.appTheme) private var theme
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
            .appThemedRows()

            Section(header: Text("离线序列号（一行一条）")) {
                TextEditor(text: $serials)
                    .frame(minHeight: 90)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
            }
            .appThemedRows()

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
                        .foregroundColor(theme.palette.secondaryInk)
                }
            } footer: {
                Text("内置默认值是打包时带的那份。公开仓库里默认值为空，需要在这里填自己的 APP ID、API Key、Secret Key 和离线序列号；离线引擎要求序列号与 APP ID 配套。")
            }
            .appThemedRows()
        }
        .appThemedList()
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

/// 听书面板的引擎标签。主页面四张卡片就是它，多一个都不放。
enum TTSEngineTab: String, CaseIterable, Identifiable {
    case system
    case baiduOffline
    case baiduOnline
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统"
        case .baiduOffline: return "百度离线"
        case .baiduOnline: return "百度在线"
        case .custom: return "自定义"
        }
    }

    var icon: String {
        switch self {
        case .system: return "iphone"
        case .baiduOffline: return "internaldrive"
        case .baiduOnline: return "cloud"
        case .custom: return "square.stack.3d.up"
        }
    }

    var voiceSectionTitle: String {
        switch self {
        case .system: return "系统音色"
        case .baiduOffline: return "百度离线音色"
        case .baiduOnline: return "百度在线音色"
        case .custom: return "自定义语音源"
        }
    }
}

/// 引擎的管理面：激活、诊断、导入、授权、源管理。
/// 主页面只负责选，脏活全收在这里，避免一进设置就看见一堆按钮。
#if os(iOS) && !NO_BAIDU_TTS
struct TTSEngineAdvancedView: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject private var baidu = BaiduOfflineTTS.shared
    @ObservedObject private var baiduOnline = BaiduOnlineTTS.shared

    @State private var diagLines: [String] = []
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var customSpeakerId = ""

    /// 导入或删除音库后通知上一层刷新列表，不然返回主页要重启才看见。
    var onVoicesChanged: () -> Void = {}

    var body: some View {
        Form {
            Section(header: Text("百度离线")) {
                HStack {
                    Text(baidu.statusText)
                    Spacer()
                    if baidu.isPreparing { ProgressView() }
                }
                .font(.footnote)

                Button("加载 / 激活当前音色") {
                    let list = BaiduOfflineTTS.allVoices
                    guard let voice = BaiduOfflineTTS.voice(id: BaiduOfflineTTS.activeVoiceId) ?? list.first else { return }
                    baidu.preload(voice: voice)
                }
                .font(.footnote)

                Button("诊断音库文件") {
                    diagLines = BaiduOfflineTTS.allVoices.flatMap { voice in
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
                    // 以前是 sheet：已经在推入的页面里再开一套导航。现在同栈 push。
                    NavigationLink(destination: BaiduVoiceManagerSheet(onDeleted: { deleted in
                        onVoicesChanged()
                        importMessage = "删掉了 \(deleted) 条自备音色"
                    })) {
                        Label("管理自备音色（\(BaiduOfflineTTS.userVoices.count)）", systemImage: "trash")
                    }
                    .font(.footnote)
                }

                if let importMessage {
                    Text(importMessage)
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                }

                if !diagLines.isEmpty {
                    ForEach(diagLines, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                    Button("收起诊断") { diagLines = [] }
                        .font(.caption2)
                }

                if let error = baidu.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(theme.palette.danger)
                }

                Text("首次激活要联网，SDK 拿 APP ID + 序列号换授权文件，之后断网可用。")
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
            }
            .appThemedRows()

            Section(header: Text("百度在线")) {
                HStack {
                    Text(baiduOnline.statusText)
                    Spacer()
                    if baiduOnline.isPreparing { ProgressView() }
                }
                .font(.footnote)

                Button("取 token / 加载在线引擎") {
                    guard let speaker = BaiduOnlineTTS.speaker(id: BaiduOnlineTTS.activeSpeakerId)
                        ?? BaiduOnlineTTS.speakers.first else { return }
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
                        guard !id.isEmpty, BaiduOnlineTTS.speaker(id: id) != nil else { return }
                        BaiduOnlineTTS.activeSpeakerId = id
                    }
                    .font(.footnote)
                }

                if let error = baiduOnline.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(theme.palette.danger)
                }

                Text("在线合成走网络，不吃序列号。access_token 30 天有效，过期自动重取。精品音色要先在控制台开通。")
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
            }
            .appThemedRows()

            Section {
                NavigationLink(destination: BaiduCredentialView()) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("百度语音授权")
                        Text(BaiduCredentials.hasCustomValues ? "用的是自己填的凭据" : "用的是 App 内置默认凭据")
                            .font(.caption2)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                }
            } footer: {
                Text("APP ID / API Key / Secret Key / 离线序列号，填了以填的为准。")
            }
            .appThemedRows()

            Section {
                NavigationLink(destination: TTSourceManagerView()) {
                    Label("管理 / 导入语音源", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("自定义引擎的接口模板与音色。")
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle("引擎高级设置")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.archive, .zip, .item],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

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
                onVoicesChanged()
                importMessage = "导入了 \(url.lastPathComponent)，现在共 \(count) 条自备音色"
            } catch {
                importMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }
}
#endif

/// 听书 / 引擎这一族的统一外壳。
///
/// 每页各自写 NavigationView + Form + 头部卡片时，顶距、标题、列表样式就要每页抄一遍，
/// 四十点那道灰就是这么漏的：iOS 26 给 Form 的 scrollContent 补了约 29pt 上边距，
/// 抄漏一次清零就多一道灰。收成一处之后，改一次六页一起动。
struct TTSPageShell<Content: View>: View {
    let code: String
    let title: String
    let detail: String
    /// 非 nil 才在右上角给按钮；靠返回键退出的子页面传 nil。
    var doneLabel: String?
    /// 已经处在别人的导航栈里就传 false，别再造一层 NavigationView。
    var embedsNavigation: Bool = true
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    var body: some View {
        if embedsNavigation {
            NavigationView { chrome }
        } else {
            chrome
        }
    }

    private var chrome: some View {
            Form {
                // 导航栏已经写着页名，这里不再放一张重复标题的大卡片：
                // 米色主题下工具栏和卡片同色，两块贴一起就是一整片空米色，标题还写两遍。
                // 只留一条细标尺，红杠 + 编号 + 副标题，当这页的身份标记。
                Section {
                    HStack(spacing: 10) {
                        Rectangle()
                            .fill(theme.palette.accent)
                            .frame(width: 3, height: 15)
                        Text(code)
                            .font(theme.typography.label)
                        Text(detail)
                            .font(theme.typography.mono)
                        Spacer(minLength: 8)
                        Text("MODULE")
                            .font(theme.typography.mono)
                    }
                    .foregroundColor(theme.palette.secondaryInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                content()
            }
            .appThemedList()
            .modifier(ZeroSectionSpacing())
            .modifier(TopContentFlush())
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if let doneLabel {
                        Button(doneLabel) { dismiss() }
                    }
                }
            }
    }
}

/// Form 的段间距只有 iOS 17 起能压到 0；15/16 保留系统默认，别硬塞负 padding。
struct ZeroSectionSpacing: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.listSectionSpacing(0)
        } else {
            content
        }
    }
}

/// iOS 26 的 Form 会在安全区下沿再留一条约 29pt 的 scrollContent 上边距，头部卡片因此贴不住导航栏。
/// 这条边距只有 iOS 17+ 的 contentMargins 清得掉；15/16 本来就没有，走原样即可。
struct TopContentFlush: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.contentMargins(.top, 0, for: .scrollContent)
        } else {
            content
        }
    }
}
