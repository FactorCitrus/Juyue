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
    @State private var engineTab: TTSEngineTab = .system
    @State private var systemVoiceId: String? = SystemVoiceSelection.identifier
    @State private var voiceExpanded = false
    @State private var paramsExpanded = false
    @State private var importingModel = false
    @State private var importNote: String?
    @State private var showCloudPicker = false
    @State private var cloudPreset: TTSOnlinePreset?
    @State private var showCustomSetup = false
    /// 标签只在这一次打开时落一次位。子页面（自建 TTS、管理语音引擎）弹回来时
    /// onAppear 会再跑一遍，不拦着就把人从「在线源」拽回「内置离线」。
    @State private var didSyncTab = false
    @ObservedObject private var cast = TTSCastStore.shared
    @ObservedObject private var modelStore = LocalTTSModelStore.shared
    /// 百度那边的授权状态要能实时刷到这一页，自检跑完立刻看见结果
    @ObservedObject private var baidu = BaiduOfflineTTS.shared

    /// 已经被包在别人的导航栈里（设置页推进来）时传 true，外壳不再自造 NavigationView。
    private let embedded: Bool

    public init(embedded: Bool = false) { self.embedded = embedded }

    /// 底部常驻的试听条。按钮给 `.borderedProminent`，是这页唯一的实心块，
    /// 一眼能认出主操作；「当前」那行缩成一行小字，长引擎名压不下去就缩字号。
    private var previewBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.25)
            HStack(spacing: 10) {
                Button {
                    audio.stop()
                    audio.preview()
                } label: {
                    Label(audio.isPlaying ? "重新试听" : "试听当前引擎",
                          systemImage: "waveform")
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.palette.accent)
                .accessibilityIdentifier("tts.preview")

                if audio.isPlaying {
                    Button {
                        audio.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("停止")
                }

                Spacer(minLength: 6)

                Text("当前：\(audio.currentEngineName)")
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .background(.ultraThinMaterial)
    }

    public var body: some View {
        TTSPageShell(
            code: "READ / VOICE",
            title: "听书设置",
            detail: "引擎 / 音色 / 多角色",
            doneLabel: embedded ? nil : "完成",
            embedsNavigation: !embedded
        ) {

                // 引擎在最外层：三张卡平级，副标题写各自当前状态
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

                // 「到底启用了哪个源」：一句话摊在这儿，不用挨个角色点进去看。
                Section {
                    HStack(spacing: 8) {
                        Text("引擎")
                        Spacer(minLength: 8)
                        Text(audio.currentEngineName)
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    if cast.enabled {
                        ForEach(castRoleLines, id: \.0) { line in
                            HStack(spacing: 8) {
                                Text(line.0)
                                Spacer(minLength: 8)
                                Text(line.1)
                                    .font(.caption)
                                    .foregroundColor(theme.palette.secondaryInk)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                    }
                } header: {
                    Text("现在用这一套")
                } footer: {
                    Text(cast.enabled
                         ? "多角色开着：上面每条角色按自己的音色念，其余段落跟随引擎。"
                         : "多角色关着：整章都用这个引擎的音色。")
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .appThemedRows()

                // 管理入口摆在引擎卡下面、tabs 外面：三个页都看得见，不用滚到页底翻。
                Section {
                    NavigationLink(destination: TTSourceManagerView()) {
                        HStack(spacing: 8) {
                            Label("管理语音引擎", systemImage: "slider.horizontal.3")
                            Spacer(minLength: 8)
                            Text(sourceCountLabel)
                                .font(.caption)
                                .foregroundColor(theme.palette.secondaryInk)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityIdentifier("tts.engineManager")
                } footer: {
                    Text("系统语音、包内模型、在线源在此切换，导入的语音源也在这里删除。")
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .appThemedRows()

                // 音色收成一行摘要，点开才铺列表；选完自动收起
                Section {
                    // DisclosureGroup 在 List 里只有右侧箭头那一小块吃点击，
                    // 点整行没反应像坏了；改成 Button，整行都能开合。
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { voiceExpanded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("音色")
                                .foregroundColor(theme.palette.ink)
                            Spacer(minLength: 8)
                            Text(voiceSummary)
                                .font(.caption)
                                .foregroundColor(theme.palette.secondaryInk)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(theme.palette.secondaryInk)
                                .rotationEffect(.degrees(voiceExpanded ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tts.voice.disclosure")

                    if voiceExpanded {
                        voiceRows
                        voiceActions
                    }
                } footer: {
                    Text(engineStatusLine)
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .appThemedRows()

                // 参数也收起来，主页面只留引擎、音色、多角色三块
                Section {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { paramsExpanded.toggle() }
                    } label: {
                        HStack {
                            Text("朗读参数")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(theme.palette.secondaryInk)
                                .rotationEffect(.degrees(paramsExpanded ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tts.params.disclosure")

                    if paramsExpanded {
                        speechRateRow
                        chunkRow
                        Text("在线引擎按此长度切分后发送。切分过长可能导致超时或响应被截断。")
                            .font(.caption2)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                }
                .appThemedRows()

                // 多角色只在主页面留一行：一个开关、一个入口。
                // 以前每条角色在这儿铺一行、每行又把引擎和音色重写一遍，人一多就是一页配置表。
                Section {
                    // 裸 Toggle 在 Form 行里只有开关本体那一小块吃点击，点标题文字毫无反应，
                    // 用起来就像坏了。整行收点击，开关只当显示。
                    AppSwitchRow(title: "按角色换音色",
                                 isOn: $cast.enabled,
                                 identifier: "tts.cast.enabled")

                    NavigationLink {
                        TTSCastRolesView()
                    } label: {
                        HStack(spacing: 8) {
                            Text("角色与音色")
                            Spacer(minLength: 8)
                            Text(castRolesSummary)
                                .font(.caption)
                                .foregroundColor(theme.palette.secondaryInk)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityIdentifier("tts.cast.roles")
                } header: {
                    Text("多角色朗读")
                } footer: {
                    Text("引号内对话归「对话」，其余为旁白；角色各自指定音色，按段切换。")
                }
                .appThemedRows()

                // 接入云服务、导入语音源、导入模型这些入口只在「管理语音引擎」里留一份。
                // 这页原来底部还跟着引擎变一套一模一样的，同一条路走两个门，看着就乱。

        }
        // 试听是这页唯一的主操作，跟着 Form 滚到屏幕外面等于没有。
        // 钉在底部安全区：音色列表再长、多角色再展开，它都还在拇指够得着的位置。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            previewBar
        }
        .onAppear {
            reloadSources()
            guard !didSyncTab else { return }
            didSyncTab = true
            syncEngineTab()
        }
        .fileImporter(
            isPresented: $importingModel,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let model = try modelStore.importModel(from: url)
                    importNote = "已导入：\(model.name)"
                    TTSEngineChoice.current = .builtIn
                    engineTab = .builtIn
                    BundledTTSEngine.shared.invalidate()
                    audio.applySettingsChangeRestart()
                } catch {
                    importNote = "导入失败：\(error.localizedDescription)"
                }
            case .failure(let error):
                importNote = "导入失败：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showCloudPicker) {
            TTSOnlinePresetPicker { preset in
                showCloudPicker = false
                // 两张表单不能同时弹，等上一张收完再弹 token 那张
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard let preset else {
                        showCustomSetup = true
                        return
                    }
                    if preset.fields.isEmpty {
                        install(preset, values: [:])
                    } else {
                        cloudPreset = preset
                    }
                }
            }
        }
        .sheet(isPresented: $showCustomSetup) {
            // 自定义云服务跟「接入自建 TTS」是同一页，这里得自带一层导航，不然退不出去
            NavigationView { CustomTTSSetupView() }
        }
        .sheet(item: $cloudPreset) { preset in
            TTSOnlinePresetSheet(preset: preset) { values in
                install(preset, values: values)
            }
        }
        .alert("朗读引擎", isPresented: Binding(
            get: { importNote != nil },
            set: { if !$0 { importNote = nil } }
        )) {
            Button("知道了", role: .cancel) { importNote = nil }
        } message: {
            Text(importNote ?? "")
        }
    }

    // MARK: - 引擎切换

    /// 三路平级：包内离线、系统语音、在线源。各管各的音色栏，不再互相改对方的状态。
    private var engineTabs: [TTSEngineTab] { [.builtIn, .system, .custom] }

    private var engineFooter: String {
        switch engineTab {
        case .builtIn:
            if BundledTTSEngine.isBaidu {
                return "百度离线引擎和女声都在包里，断网照样念，不连服务器。"
            }
            return BundledTTSEngine.isModelBundled
                ? "模型都在本机跑，断网照样念。音色就是下面那串模型，导入的也走同一套。"
                : "现在没有能用的模型。导一个带 .onnx 和 tokens.txt 的文件夹进来，或者先用系统语音顶着。"
        case .system:
            return "iOS 自己合成，不占包体积。好不好听得看系统里下没下增强音色。"
        case .custom:
            return "自己填接口模板，接各家的在线 TTS。断网就废，适合在局域网里自建。"
        }
    }

    /// 折叠状态下那一行摘要，不展开也能知道现在用的是谁。
    private var voiceSummary: String {
        switch engineTab {
        case .builtIn:
            if BundledTTSEngine.isBaidu {
                return baiduActiveVoice?.name ?? "未选择音色"
            }
            guard let model = modelStore.selected else { return "没有可用模型" }
            let speakers = modelStore.speakerCount
            if speakers > 1 {
                return "\(model.name) · 发音人 \(modelStore.speakerId + 1)/\(speakers)"
            }
            return model.name
        case .system:
            guard let id = systemVoiceId,
                  let voice = SystemVoiceSelection.chineseVoices.first(where: { $0.identifier == id })
            else { return "跟随系统默认" }
            return voice.name
        case .custom:
            if let activeId, let source = sources.first(where: { $0.id == activeId }) {
                return source.name
            }
            return "未选择语音源"
        }
    }

    private var engineStatusLine: String {
        switch engineTab {
        case .builtIn:
            if BundledTTSEngine.isBaidu {
                let count = BaiduOfflineTTS.allVoices.count
                return "包内 \(count) 个百度音色 · 断网可用 · \(BaiduOfflineTTS.shared.statusText)"
            }
            if let model = modelStore.selected {
                return "使用中：\(model.name) · \(model.subtitle)"
            }
            return "包里与文档目录都没有模型。"
        case .system:
            return systemVoiceHint
        case .custom:
            return "共 \(sources.count) 个语音源"
        }
    }

    /// 卡片底下那行小字：一眼看出这条路上有没有东西可用。
    private func engineCardSubtitle(_ tab: TTSEngineTab) -> String {
        switch tab {
        case .builtIn:
            if BundledTTSEngine.isBaidu {
                return "\(BaiduOfflineTTS.allVoices.count) 个音色"
            }
            return modelStore.models.isEmpty ? "无模型" : "\(modelStore.models.count) 个音色"
        case .system:
            return "内置"
        case .custom:
            return sources.isEmpty ? "未配置" : "\(sources.count) 个源"
        }
    }

    /// 只显示当前引擎的音色，不再把三类混在一个列表里。
    @ViewBuilder
    private var voiceRows: some View {
        switch engineTab {
        case .builtIn:
            if BundledTTSEngine.isBaidu {
                ForEach(BaiduOfflineTTS.allVoices) { voice in
                    engineRow(
                        name: voice.name,
                        subtitle: voice.id == baiduActiveVoice?.id
                            ? "\(voice.note) · 使用中"
                            : voice.note,
                        selected: voice.id == baiduActiveVoice?.id
                    ) {
                        selectBaiduVoice(voice)
                    }
                }
            } else {
                if modelStore.models.isEmpty {
                    Text("当前没有模型。点「导入音色模型…」选择含 .onnx 与 tokens.txt 的文件夹。")
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                ForEach(modelStore.models) { model in
                    engineRow(
                        name: model.name,
                        subtitle: model.id == modelStore.selected?.id
                            ? "\(model.subtitle) · 使用中"
                            : model.subtitle,
                        selected: model.id == modelStore.selected?.id
                    ) {
                        selectModel(model)
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        // 导入的真删，包内的只从列表里藏起来（文件在包内删不掉）
                        modelStore.remove(modelStore.models[index])
                        BundledTTSEngine.shared.invalidate()
                    }
                    audio.applySettingsChangeRestart()
                }
                if modelStore.speakerCount > 1 {
                    Picker("发音人", selection: speakerBinding) {
                        ForEach(0..<modelStore.speakerCount, id: \.self) { index in
                            Text("发音人 \(index + 1)").tag(index)
                        }
                    }
                }
            }
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
        case .custom:
            ForEach(TTSourceSelection.selectable(sources), id: \.id) { source in
                engineRow(name: source.name, subtitle: sourceSubtitle(source), selected: activeId == source.id) {
                    select(source.id)
                }
            }
        }
    }

    /// 音色列表底部的动作，跟当前引擎走。
    @ViewBuilder
    private var voiceActions: some View {
        switch engineTab {
        case .builtIn:
            if BundledTTSEngine.isBaidu {
                Button {
                    baidu.authorizationProbe()
                } label: {
                    Label("跑一次授权自检", systemImage: "checkmark.shield")
                }
                .accessibilityIdentifier("tts.baidu.authprobe")
                // 容器里（LiveContainer 之类）接不到 console，这几行就是唯一能看见的证据。
                // 上面那行是「引擎实际拿去换授权」的名字，下面是容器塞给系统的那串。
                Text("授权用：APP ID \(BaiduOfflineTTS.appId) · 包名 \(BaiduBundleShim.pinned)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.palette.secondaryInk)
                Text("容器里的真包名：\(Bundle.main.bundleIdentifier ?? "?")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.palette.secondaryInk)
                if BaiduCredentials.hasCustomValues {
                    Button {
                        BaiduCredentials.resetToBuiltin()
                        baidu.authorizationProbe()
                    } label: {
                        Label("清掉自填凭据，改用包内那套", systemImage: "arrow.counterclockwise")
                    }
                    .accessibilityIdentifier("tts.baidu.resetcreds")
                }
                if baidu.authReport.isEmpty {
                    Text("音色由百度离线引擎合成，全在包内。序列号授权只在激活时用一次，之后断网照念。")
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                } else {
                    Text(baidu.authReport)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.palette.secondaryInk)
                        .textSelection(.enabled)
                }
            } else {
                Button {
                    importingModel = true
                } label: {
                    Label("导入音色模型…", systemImage: "square.and.arrow.down")
                }
                if modelStore.hasHidden {
                    Button {
                        modelStore.restoreHidden()
                    } label: {
                        Label("找回藏起来的包内音色（\(modelStore.hiddenIds.count)）", systemImage: "arrow.uturn.backward")
                    }
                }
                Text("左滑删除音色。导入的音色同时删除文件；包内自带音色无法删除，仅从列表隐藏，可在「管理语音引擎」恢复。")
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
            }
        case .system:
            Text("更自然的音色需在 设置 → 辅助功能 → 朗读内容 → 声音 → 中文 下载「增强」或「高级」版本。")
                .font(.caption2)
                .foregroundColor(theme.palette.secondaryInk)
        case .custom:
            Text("在线源的接入与导入入口见上方「管理语音引擎」。")
                .font(.caption2)
                .foregroundColor(theme.palette.secondaryInk)
        }
    }

    /// 「管理语音引擎」那行右侧的摘要：自建源几条，内置那条单独算。
    private var sourceCountLabel: String {
        let custom = sources.filter { !$0.isBuiltinOnline }.count
        return custom == 0 ? "只有内置源" : "自建 \(custom) 条 + 内置"
    }

    /// 「现在用这一套」里那几行：角色名 → 实际在用的引擎和音色/源。
    /// 用户抱怨的就是这个：开着多角色，却不知道自己那几段话是被哪条源念的。
    private var castRoleLines: [(String, String)] {
        cast.roles.filter(\.enabled).map { role in
            (role.name.isEmpty ? "未命名" : role.name,
             "\(role.engine.rawValue) · \(castVoiceLabel(role))")
        }
    }

    /// 多角色那一行右侧的摘要：配了几条、都叫什么，不用点进去也知道
    private var castRolesSummary: String {
        let enabled = cast.roles.filter(\.enabled)
        guard !enabled.isEmpty else { return "还没配角色" }
        let names = enabled.prefix(2).map { $0.name.isEmpty ? "未命名" : $0.name }
        let head = names.joined(separator: " / ")
        return enabled.count > names.count ? "\(head) 等 \(enabled.count) 条" : head
    }

    private var speakerBinding: Binding<Int> {
        Binding(
            get: { min(modelStore.speakerId, max(0, modelStore.speakerCount - 1)) },
            set: { value in
                guard let model = modelStore.selected else { return }
                modelStore.select(model, speaker: value)
                BundledTTSEngine.shared.invalidate()
                audio.applySettingsChangeRestart()
            }
        )
    }

    private var speechRateRow: some View {
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
    }

    private var chunkRow: some View {
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
    }

    /// 回环源只对模拟器有意义；真机上点它等于点系统语音，列表里先说清楚。
    private func sourceSubtitle(_ source: HttpTTS) -> String {
        if source.isBuiltinOnline {
            return "免 Key · 走网络，失败自动回系统语音"
        }
        let h = host(of: source.url)
        if TTSourceSelection.isLoopback(source.url) && !TTSourceSelection.isSimulator {
            return "\(h) · 仅电脑可用，手机走系统语音"
        }
        return h
    }

    private func engineCard(_ tab: TTSEngineTab) -> some View {
        let active = engineTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { engineTab = tab }
            // 切栏必须同时把引擎选择落到 UserDefaults：只换界面的话，
            // 试听会拿上一次的 TTSEngineChoice 去路由——皮肤停在梅洛，请求还在往 Qwen 的地址连。
            // 在线源那一栏不在这里定，等用户挑了具体源再走 http。
            switch tab {
            case .builtIn where BundledTTSEngine.isModelBundled:
                TTSEngineChoice.current = .builtIn
                TTSourceSelection.activeId = nil
                activeId = nil
            case .system:
                TTSEngineChoice.current = .system
                TTSourceSelection.activeId = nil
                activeId = nil
            default:
                break
            }
            // 换栏就是换引擎：在念的话从这一段按新引擎重念，别把整章停掉
            audio.applySettingsChangeRestart()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 17, weight: .medium))
                Text(tab.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(engineCardSubtitle(tab))
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 66)
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

    /// 进页面时把标签落到实际在用的引擎上。
    private func syncEngineTab() {
        switch TTSEngineChoice.current {
        case .builtIn: engineTab = .builtIn
        case .system: engineTab = .system
        case .http: engineTab = .custom
        }
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

    /// 换内置模型：引擎跟着换，系统音色和在线源的选择一并清掉，免得三边打架。
    private func selectModel(_ model: LocalTTSModel) {
        modelStore.select(model)
        TTSEngineChoice.current = .builtIn
        SystemVoiceSelection.identifier = nil
        systemVoiceId = nil
        TTSourceSelection.activeId = nil
        activeId = nil
        BundledTTSEngine.shared.invalidate()
        audio.applySettingsChangeRestart()
        withAnimation { voiceExpanded = false }
    }

    /// 百度离线当前音色。没选过就按第一条算，跟门面那边的兜底保持一致。
    private var baiduActiveVoice: BaiduOfflineTTS.Voice? {
        BaiduOfflineTTS.activeVoice ?? BaiduOfflineTTS.allVoices.first
    }

    /// 换百度音色：跟换模型一样，把系统音色和在线源的选择清掉，三条路不打架。
    private func selectBaiduVoice(_ voice: BaiduOfflineTTS.Voice) {
        BaiduOfflineTTS.activeVoiceId = voice.id
        TTSEngineChoice.current = .builtIn
        SystemVoiceSelection.identifier = nil
        systemVoiceId = nil
        TTSourceSelection.activeId = nil
        activeId = nil
        BundledTTSEngine.shared.invalidate()
        audio.applySettingsChangeRestart()
        withAnimation { voiceExpanded = false }
    }

    private func selectSystem(_ voice: AVSpeechSynthesisVoice) {
        SystemVoiceSelection.identifier = voice.identifier
        systemVoiceId = voice.identifier
        TTSEngineChoice.current = .system
        TTSourceSelection.activeId = nil
        activeId = nil
        audio.applySettingsChangeRestart()
        withAnimation { voiceExpanded = false }
    }

    /// 系统音色区上方的说明文字。
    private var systemVoiceHint: String {
        "想更像真人：去设置 → 辅助功能 → 朗读内容 → 声音 → 中文，下「增强」或「高级」那一版，回来这儿会标出来。"
    }

    private func reloadSources() {
        let store = HttpTTSStore.shared
        try? store.load()
        sources = store.sources
        activeId = TTSourceSelection.activeId
    }

    /// 云服务加完直接切过去：用户点「接入云服务」就是想让书用这条念，不是只想列表里多一行。
    private func install(_ preset: TTSOnlinePreset, values: [String: String]) {
        do {
            let source = try TTSOnlinePreset.install(preset, values: values)
            reloadSources()
            activeId = source.id
            TTSourceSelection.activeId = source.id
            TTSEngineChoice.current = .http
            engineTab = .custom
            importNote = "已添加 \(source.name)，想删就去上面「管理语音引擎」。"
        } catch {
            importNote = "添加失败：\(error.localizedDescription)"
        }
    }

    private func select(_ id: Int64?) {
        // 选具体源才走在线；「跟随系统」这类空选择退回离线（有模型就用包内/导入的）
        TTSEngineChoice.current = id == nil
            ? (BundledTTSEngine.isModelBundled ? .builtIn : .system)
            : .http
        SystemVoiceSelection.identifier = nil
        systemVoiceId = nil
        TTSourceSelection.activeId = id
        activeId = id
        audio.applySettingsChangeRestart()
        withAnimation { voiceExpanded = false }
    }
}

/// 多角色的角色表：主页面只留一个开关和入口，配角色全在这一页里做。
/// 以前角色行铺在主设置页上，每行还把引擎和音色重写一遍，跟上面的引擎区读起来像两套东西。
struct TTSCastRolesView: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject private var cast = TTSCastStore.shared

    var body: some View {
        Form {
            Section {
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
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(role.name.isEmpty ? "（未命名角色）" : role.name)
                                    .foregroundColor(role.enabled ? theme.palette.ink : theme.palette.secondaryInk)
                                Text("\(role.match.rawValue) · \(role.engine.rawValue) · \(castVoiceLabel(role))")
                                    .font(.caption2)
                                    .foregroundColor(theme.palette.secondaryInk)
                            }
                            Spacer(minLength: 8)
                            // 停用的角色以前用 .disabled 封整行，结果人一点就再也进不去把自己打开，
                            // 只能删掉重建。这里整行照旧可点，停用只做视觉提示。
                            if !role.enabled {
                                Text("已停用")
                                    .font(.caption2)
                                    .foregroundColor(theme.palette.secondaryInk)
                            }
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
                Text("角色")
            } footer: {
                Text("按段落拆分：引号内对话归「对话」，其余为旁白，命名角色按关键词匹配。每条角色单独指定引擎与音色，按段切换；没配的角色按旁白念。")
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle("角色与音色")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// 单条角色音色的编辑页
struct TTSCastRoleEditor: View {
    @Environment(\.appTheme) private var theme
    @Binding var role: TTSCastRole
    @ObservedObject private var modelStore = LocalTTSModelStore.shared

    /// 在线源列表。内置源排在最前，用户导入的接在后面。
    private var sources: [HttpTTS] {
        TTSourceSelection.selectable(HttpTTSStore.shared.sources)
    }

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

                AppSwitchRow(title: "启用这条", isOn: $role.enabled)
            }
            .appThemedRows()

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
                case .builtin:
                    Picker("离线模型", selection: $role.voiceId) {
                        Text("跟随全局设置").tag("")
                        ForEach(modelStore.models) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    // 单发声人模型（melo、华言）恒为 1，这一行直接不出现
                    if speakers(of: role.voiceId) > 1 {
                        Picker("发音人", selection: Binding(
                            get: { role.speakerIndex ?? 0 },
                            set: { role.speakerIndex = $0 }
                        )) {
                            ForEach(0..<speakers(of: role.voiceId), id: \.self) { index in
                                Text("第 \(index + 1) 个").tag(index)
                            }
                        }
                    }
                case .http:
                    Picker("在线源", selection: Binding<Int64?>(
                        get: { role.sourceId },
                        set: { role.sourceId = $0 }
                    )) {
                        Text("未选择").tag(Int64?.none)
                        ForEach(sources, id: \.id) { source in
                            Text(source.name).tag(Int64?.some(source.id))
                        }
                    }
                }
            } header: {
                Text("音色")
            } footer: {
                Text(editorFooter)
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle(role.name.isEmpty ? "角色" : role.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if HttpTTSStore.shared.sources.isEmpty {
                try? HttpTTSStore.shared.load()
            }
        }
    }

    /// 这个模型能选几个发音人。空串表示跟随全局，那就报全局那个模型的数。
    private func speakers(of modelId: String) -> Int {
        if modelId.isEmpty { return modelStore.speakerCount }
        return max(1, modelStore.speakerCounts[modelId] ?? 1)
    }

    private var editorFooter: String {
        switch role.engine {
        case .system:
            return "选「跟随全局设置」时使用听书设置中的当前音色。"
        case .builtin:
            return speakers(of: role.voiceId) > 1
                ? "离线模型自带多个发音人，可以只给这条角色换人。"
                : "这个模型只有一个发音人，换角色就得换模型。"
        case .http:
            return "每段单独发一次请求，音色由那条语音源的地址模板决定；源失效时这一段改用系统语音。"
        }
    }
}

/// 列表里那行「音色」的显示名
private func castVoiceLabel(_ role: TTSCastRole) -> String {
    switch role.engine {
    case .system:
        guard !role.voiceId.isEmpty else { return "跟随全局" }
        return AVSpeechSynthesisVoice(identifier: role.voiceId)?.name ?? "未知音色"
    case .builtin:
        guard !role.voiceId.isEmpty else { return "全局模型" }
        let name = LocalTTSModelStore.shared.models
            .first { $0.id == role.voiceId }?.name ?? "已删除的模型"
        if let index = role.speakerIndex { return "\(name) · 发音人 \(index + 1)" }
        return name
    case .http:
        guard let id = role.sourceId else { return "未选源" }
        if id == HttpTTS.builtinOnlineId { return HttpTTS.builtinOnline.name }
        return HttpTTSStore.shared.sources.first { $0.id == id }?.name ?? "已失效的源"
    }
}

/// 听书面板的引擎标签。主页面两张卡片就是它，多一个都不放。
enum TTSEngineTab: String, CaseIterable, Identifiable {
    case builtIn
    case system
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtIn: return BundledTTSEngine.isBaidu ? "百度离线" : "内置离线"
        case .system: return "系统语音"
        case .custom: return "在线源"
        }
    }

    var icon: String {
        switch self {
        case .builtIn: return "waveform.circle"
        case .system: return "iphone"
        case .custom: return "square.stack.3d.up"
        }
    }
}

/// Form 行里的开关。
///
/// 原生 `Toggle` 放进 Form 之后，点击只认开关本体那块小方块：点标题、点行尾空白都没反应，
/// 手指粗一点或者用鼠标点，反馈就是「这开关坏了」。这里把开关降成纯显示
/// （`allowsHitTesting(false)`），点击交给外面这一整行，命中区就是 370×52 的整条。
///
/// 无障碍按一个按钮报出去：label 是标题，value 是 1/0，跟原来 CheckBox 的读法对得上。
struct AppSwitchRow: View {
    @Environment(\.appTheme) private var theme

    let title: String
    @Binding var isOn: Bool
    var detail: String? = nil
    var identifier: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundColor(theme.palette.ink)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "1" : "0")
        .modifier(OptionalAccessibilityIdentifier(identifier: identifier))
    }
}

/// 标识符可有可无；`accessibilityIdentifier("")` 会真建一个空 id，条件给更干净。
private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

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
