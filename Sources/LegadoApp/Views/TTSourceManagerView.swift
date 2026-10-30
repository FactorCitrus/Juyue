import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 听书引擎管理：系统语音 + 导入的在线语音源。
public struct TTSourceManagerView: View {
    @Environment(\.appTheme) private var theme
    @State private var sources: [HttpTTS] = []
    @State private var activeSourceId: Int64? = TTSourceSelection.activeId
    /// 引擎选择存在 UserDefaults 里，不是 @Published，本页自己留一份状态好刷新勾。
    @State private var engineChoice: TTSEngineChoice = TTSEngineChoice.current
    // 验收用：JUYUE_TTS_IMPORT=1 时直接展开导入区，省得手点。
    @State private var showImportSheet = ProcessInfo.processInfo.environment["JUYUE_TTS_IMPORT"] == "1"
    @State private var importText = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    /// 点「添加在线服务」里的某一条时，把要填的字段摆成一张表单。
    @State private var pendingPreset: TTSOnlinePreset?
    @State private var showPresetPicker = false
    @State private var showCustomSetup = false

    public init() {}

    public var body: some View {
        List {
            if showImportSheet {
                Section(header: Text("导入语音源")) {
                    TextEditor(text: $importText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                        .themedScrollBackground()
                        // TextEditor 默认是一张纯白纸，跟主题的米色对不上；铺成页面底色再描一圈边
                        .background(theme.palette.background)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.palette.secondaryInk.opacity(0.25), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundColor(theme.palette.ink)
                    Text("把语音源 JSON 粘在这里，比如 {\"name\":\"有道\",\"url\":\"https://dict.youdao.com/dictvoice?audio={{java.encodeURI(speakText)}}&le=zh\",\"contentType\":\"audio/mpeg\"}")
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                    HStack {
                        Button("取消") {
                            showImportSheet = false
                            importText = ""
                        }
                        Spacer()
                        Button("导入") {
                            importSource(importText)
                            showImportSheet = false
                        }
                        .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .font(.footnote)
                }
                .appThemedRows()
            }

            Section(header: Text("当前引擎")) {
                HStack {
                    Text("使用中")
                    Spacer()
                    Text(TTSourceSelection.displayName(in: sources))
                        .foregroundColor(theme.palette.secondaryInk)
                }
            }
            .appThemedRows()

            Section(header: Text("引擎列表")) {
                // 包内模型排第一：手机上最常见的场景是飞机上、地铁里翻书，先给这条
                if BundledTTSEngine.isModelBundled {
                    Button {
                        TTSEngineChoice.current = .builtIn
                        engineChoice = .builtIn
                        activeSourceId = nil
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(BundledTTSEngine.displayName).foregroundColor(theme.palette.ink)
                                Text(BundledTTSEngine.detailText)
                                    .font(.caption)
                                    .foregroundColor(theme.palette.secondaryInk)
                            }
                            Spacer()
                            if engineChoice == .builtIn {
                                Image(systemName: "checkmark").foregroundColor(theme.palette.accent)
                            }
                        }
                    }
                }

                Button {
                    TTSEngineChoice.current = .system
                    engineChoice = .system
                    TTSourceSelection.activeId = nil
                    activeSourceId = nil
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("系统语音").foregroundColor(theme.palette.ink)
                            Text("iOS 自带的 AVSpeechSynthesizer，断网也能念。")
                                .font(.caption)
                                .foregroundColor(theme.palette.secondaryInk)
                        }
                        Spacer()
                        if engineChoice == .system {
                            Image(systemName: "checkmark").foregroundColor(theme.palette.accent)
                        }
                    }
                }

                ForEach(TTSourceSelection.selectable(sources), id: \.id) { source in
                    Button {
                        TTSEngineChoice.current = .http
                        engineChoice = .http
                        TTSourceSelection.activeId = source.id
                        activeSourceId = source.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name).foregroundColor(theme.palette.ink)
                                Text(sourceHostLabel(source))
                                    .font(.caption)
                                    .foregroundColor(theme.palette.secondaryInk)
                            }
                            Spacer()
                            if engineChoice == .http && activeSourceId == source.id {
                                Image(systemName: "checkmark").foregroundColor(theme.palette.accent)
                            }
                        }
                    }
                    .swipeActions {
                        if !source.isBuiltinOnline {
                            Button(role: .destructive) {
                                remove(source)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .appThemedRows()

            Section {
                NavigationLink(destination: CustomTTSSetupView()) {
                    Label("自己填地址模板", systemImage: "square.and.pencil")
                }

                Button {
                    showPresetPicker = true
                } label: {
                    Label("添加在线服务", systemImage: "plus.circle")
                }

                Button {
                    importText = ""
                    showImportSheet = true
                } label: {
                    Label("导入语音源", systemImage: "square.and.arrow.down")
                }

                Button {
                    importFromClipboard()
                } label: {
                    Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                }
            } footer: {
                Text("需要 Key 的服务：选发音人、填 access_token。列表外的服务走 httpTTS.json，兼容 Legado 格式。")
            }
            .appThemedRows()

            if let statusMessage {
                Section {
                    Text(statusMessage).font(.caption).foregroundColor(theme.palette.success)
                }
                .appThemedRows()
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).font(.caption).foregroundColor(theme.palette.danger)
                }
                .appThemedRows()
            }
        }
        .appThemedList()
        .navigationTitle("语音源")
        .task { reload() }
        .sheet(item: $pendingPreset) { preset in
            TTSOnlinePresetSheet(preset: preset) { values in
                add(preset, values: values)
            }
        }
        .sheet(isPresented: $showPresetPicker) {
            TTSOnlinePresetPicker { preset in
                showPresetPicker = false
                // 两张表单不能同时弹，等上一张收完再弹 token 那张
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if let preset {
                        start(preset)
                    } else {
                        showCustomSetup = true
                    }
                }
            }
        }
        .sheet(isPresented: $showCustomSetup) {
            // 这页本来靠上级导航栈推，塞进 sheet 得自己给一层，不然没有返回键
            NavigationView { CustomTTSSetupView() }
        }
    }

    private func host(of rule: String) -> String {
        let firstPiece = rule.split(separator: ",", maxSplits: 1).first.map(String.init) ?? rule
        if let url = URL(string: firstPiece), let host = url.host {
            return host
        }
        return String(firstPiece.prefix(60))
    }

    private func sourceHostLabel(_ source: HttpTTS) -> String {
        if source.isBuiltinOnline {
            return "免 Key · 走网络，离线时自动回系统语音"
        }
        let h = host(of: source.url)
        if TTSourceSelection.isLoopback(source.url) && !TTSourceSelection.isSimulator {
            return "\(h) · 仅电脑可用，手机走系统语音"
        }
        return h
    }

    private func reload() {
        let store = HttpTTSStore.shared
        try? store.load()
        sources = store.sources
        activeSourceId = TTSourceSelection.activeId
    }

    private func importSource(_ json: String) {
        let store = HttpTTSStore.shared
        do {
            let imported = try store.importJSON(json, replace: false)
            reload()
            errorMessage = nil
            statusMessage = "已导入 \(imported.count) 个语音源"
        } catch {
            statusMessage = nil
            errorMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    private func importFromClipboard() {
        #if os(iOS)
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            errorMessage = "剪贴板里没有文本"
            return
        }
        importSource(text)
        #else
        errorMessage = "当前平台不支持剪贴板导入"
        #endif
    }

    private func remove(_ source: HttpTTS) {
        guard !source.isBuiltinOnline else { return }
        let store = HttpTTSStore.shared
        try? store.remove(id: source.id)
        if activeSourceId == source.id {
            TTSourceSelection.activeId = nil
        }
        reload()
        statusMessage = "已删除 \(source.name)"
    }

    /// 有字段要填就弹表单，没有的直接落盘（有道那种免 Key 的）。
    private func start(_ preset: TTSOnlinePreset) {
        if preset.fields.isEmpty {
            add(preset, values: [:])
        } else {
            pendingPreset = preset
        }
    }

    private func add(_ preset: TTSOnlinePreset, values: [String: String]) {
        do {
            let source = try TTSOnlinePreset.install(preset, values: values)
            reload()
            errorMessage = nil
            statusMessage = "已添加 \(source.name)，点上面列表里那条就切过去"
        } catch {
            statusMessage = nil
            errorMessage = "添加失败：\(error.localizedDescription)"
        }
    }
}

/// 预设是编进包里的，删不掉；这里只记「哪几条不想看见」，左滑收进隐藏表。
/// 换个说法就是把删除做成可逆的：想找回来点一下恢复默认，不用重装。
enum TTSOnlinePresetVisibility {
    private static let key = "legado_tts_hidden_presets"

    static var hidden: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func hide(_ id: String) {
        var next = hidden
        next.insert(id)
        UserDefaults.standard.set(Array(next), forKey: key)
    }

    static func restoreAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static var visible: [TTSOnlinePreset] {
        let hidden = hidden
        return TTSOnlinePreset.all.filter { !hidden.contains($0.id) }
    }
}

/// 选服务的那张表：按品牌分组，一条一个发音人，右边标要不要 Key。
/// 左滑能把不要的收起来，底部留一条恢复默认的回头路。
struct TTSOnlinePresetPicker: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// nil 表示「自定义云服务」：表里没有的服务，走地址模板那一页。
    let onPick: (TTSOnlinePreset?) -> Void

    @State private var hidden: Set<String> = TTSOnlinePresetVisibility.hidden
    /// 二十多条一路滚下去找某家太费劲，给个搜索框
    @State private var query = ""

    private var presets: [TTSOnlinePreset] {
        let visible = TTSOnlinePreset.all.filter { !hidden.contains($0.id) }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return visible }
        return visible.filter {
            $0.name.localizedCaseInsensitiveContains(keyword)
                || $0.detail.localizedCaseInsensitiveContains(keyword)
                || $0.brand.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var brands: [String] {
        var seen: [String] = []
        for preset in presets where !seen.contains(preset.brand) {
            seen.append(preset.brand)
        }
        return seen
    }

    var body: some View {
        NavigationView {
            List {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.footnote)
                        .foregroundColor(theme.palette.secondaryInk)
                    TextField("搜品牌或音色", text: $query)
                        .font(.footnote)
                        .foregroundColor(theme.palette.ink)
                        .accessibilityIdentifier("tts.preset.search")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(theme.palette.secondaryInk)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tts.preset.search.clear")
                    }
                }
                .listRowBackground(theme.palette.surface)

                if presets.isEmpty {
                    Text("没有匹配的服务。换个关键词，或用下方「自定义云服务」填地址模板。")
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                        .listRowBackground(theme.palette.surface)
                }

                ForEach(brands, id: \.self) { brand in
                    Section(header: Text(brand)) {
                        ForEach(presets.filter { $0.brand == brand }) { preset in
                            Button {
                                onPick(preset)
                            } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preset.name)
                                            .foregroundColor(theme.palette.ink)
                                        Text(preset.detail)
                                            .font(.caption2)
                                            .foregroundColor(theme.palette.secondaryInk)
                                    }
                                    Spacer(minLength: 6)
                                    if !preset.fields.isEmpty {
                                        Image(systemName: "key")
                                            .font(.footnote)
                                            .foregroundColor(theme.palette.secondaryInk)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    TTSOnlinePresetVisibility.hide(preset.id)
                                    hidden = TTSOnlinePresetVisibility.hidden
                                } label: {
                                    Label("隐藏", systemImage: "eye.slash")
                                }
                                .tint(theme.palette.secondaryInk)
                            }
                            .accessibilityIdentifier("tts.preset.\(preset.id)")
                        }
                    }
                    .appThemedRows()
                }

                if presets.isEmpty {
                    Section {
                        Text("预设已全部隐藏。点下方恢复默认可重新显示。")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                    .appThemedRows()
                }

                if !hidden.isEmpty {
                    Section {
                        Button {
                            TTSOnlinePresetVisibility.restoreAll()
                            hidden = []
                        } label: {
                            Label("恢复默认预设（\(hidden.count) 条已隐藏）", systemImage: "arrow.counterclockwise")
                        }
                        .accessibilityIdentifier("tts.preset.restore")
                    } footer: {
                        Text("左滑隐藏单条，底部可恢复全部默认预设。")
                            .font(.caption2)
                    }
                    .appThemedRows()
                }

                Section {
                    Button {
                        onPick(nil)
                    } label: {
                        Label("自定义云服务", systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("tts.preset.custom")
                } footer: {
                    Text("表内没有的服务，或需调整音色参数，在此填写完整地址模板。")
                        .font(.caption2)
                }
                .appThemedRows()
            }
            .appThemedList()
            .navigationTitle("在线服务")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

/// 表里可挑的一项：填进模板的值 + 给人看的名字 + 归到哪一组。
struct TTSVoiceOption: Identifiable, Hashable {
    var id: String { value }
    let value: String
    let label: String
    let group: String
}

/// 百度短文本在线合成的 per 全表。抄自官方文档 per 参数那一节（2026-06 版）。
/// 基础便宜，精品和臻品按字数计费，大模型那档语气更软。
/// 官方以后加号这里不会自动长出来，所以选择页尾部留了「其它编号」手填。
enum TTSBaiduVoices {
    static let all: [TTSVoiceOption] = {
        let base: [(String, String, String)] = [
            ("0", "度小美", "基础女声"),
            ("1", "度小宇", "基础男声"),
            ("3", "度逍遥", "基础男声"),
            ("4", "度丫丫", "基础童声"),
        ]
        let fine: [(String, String, String)] = [
            ("5003", "度逍遥", "精品男声"),
            ("5118", "度小鹿", "精品女声"),
            ("106", "度博文", "精品男声"),
            ("110", "度小童", "精品童声"),
            ("111", "度小萌", "精品童声"),
            ("103", "度米朵", "精品亲和女声"),
            ("5", "度小娇", "精品女声"),
        ]
        let supreme: [(String, String, String)] = [
            ("4003", "度逍遥", "臻品男声"),
            ("4106", "度博文", "臻品男声"),
            ("4115", "度小贤", "臻品男声"),
            ("4119", "度小鹿", "臻品女声"),
            ("4105", "度灵儿", "臻品女声"),
            ("4117", "度小乔", "臻品女声"),
            ("4100", "度小雯", "臻品女声"),
            ("4103", "度米朵", "臻品女声"),
            ("4144", "度姗姗", "臻品女声"),
            ("4278", "度小贝", "臻品童声"),
            ("4143", "度清风", "臻品男声"),
            ("4140", "度小新", "臻品男声"),
            ("4129", "度小彦", "臻品男声"),
            ("4149", "度星河", "臻品男声"),
            ("4254", "度小清", "臻品女声"),
            ("4206", "度博文", "臻品男声 · 第二个号"),
            ("4226", "南方", "臻品男声"),
        ]
        let model: [(String, String, String)] = [
            ("4179", "度泽言", "大模型温暖男声"),
            ("4146", "度禧禧", "大模型阳光女声"),
            ("6567", "度小柔", "大模型温柔女声"),
            ("4189", "度涵竹", "大模型开朗女声"),
            ("4194", "度嫣然", "大模型活泼女声"),
            ("4193", "度泽言", "大模型开朗男声"),
            ("4195", "度怀安", "大模型磁性男声"),
            ("4196", "度清影", "大模型甜美女声"),
            ("4197", "度沁遥", "大模型知性女声"),
            ("20100", "度小粤", "大模型粤语女声"),
            ("20101", "度晓芸", "大模型粤语女声"),
            ("4257", "四川小哥", "大模型四川男声"),
            ("4132", "度阿闽", "大模型闽南男声"),
            ("4139", "度小蓉", "大模型四川女声"),
        ]
        func wrap(_ rows: [(String, String, String)], _ group: String) -> [TTSVoiceOption] {
            rows.map { TTSVoiceOption(value: $0.0, label: "\($0.1) · \($0.2)", group: group) }
        }
        return wrap(base, "基础音库")
            + wrap(fine, "精品音库")
            + wrap(supreme, "臻品音库")
            + wrap(model, "大模型音库")
    }()
}

/// 表单底部「去网站办」的入口。走系统浏览器，不在 App 里塞 WebView。
struct TTSDocsLink: Identifiable {
    var id: String { url }
    let title: String
    let url: String
    let note: String?
}

/// 一个现成的在线服务模板。字段留成占位符，表单填完再拼成 URL。
struct TTSOnlinePreset: Identifiable {
    struct Field: Identifiable {
        /// 这个格子怎么填：打字，还是从表里挑。
        enum Kind {
            case text
            /// allowCustom = true 时，选择页底部多一栏「表里没有的」，填任意编号。
            case choice([TTSVoiceOption], allowCustom: Bool)
        }

        var id: String { key }
        let key: String
        let label: String
        let placeholder: String
        let help: String?
        var kind: Kind = .text
        /// 进表单就先摆上这个值，省得每次从零开始。
        var defaultValue: String?
    }

    let id: String
    let brand: String
    let name: String
    let detail: String
    let template: String
    let fields: [Field]
    /// 表单底部那几条链接，空数组就不显示这一节。
    var links: [TTSDocsLink] = []

    static let all: [TTSOnlinePreset] = {
        // 百度的发音人就是 per，一个 per 一条源。aue=3 是 mp3，别的格式这里播不了。
        let baiduVoices: [(String, String, String)] = [
            ("度小美", "0", "基础女声"),
            ("度小宇", "1", "基础男声"),
            ("度逍遥", "3", "基础男声 · 语气偏稳"),
            ("度丫丫", "4", "童声"),
            ("度小鹿", "5118", "精品女声"),
            ("度博文", "106", "精品男声"),
            ("度米朵", "103", "精品 · 亲和女声"),
        ]
        // 表单底部那两个入口：一个去建应用拿 token，一个去看官方 per 对照表。
        // 都走系统浏览器，App 里不塞 WebView，省得跟主题打架。
        let baiduDocs: [TTSDocsLink] = [
            TTSDocsLink(
                title: "百度智能云控制台 · 建应用取 access_token",
                url: "https://console.bce.baidu.com/ai/#/ai/speech/app/list",
                note: "应用列表 → 新建应用 → 勾「语音合成」→ 拿 API Key 和 Secret Key 换 24.xxx 那串，30 天有效。"
            ),
            TTSDocsLink(
                title: "发音人对照表（官方文档）",
                // ai-doc 那条在模拟器 Safari 里一直白屏（SPA 渲染），换智能云文档站这条，同样一张 per 表
                url: "https://cloud.baidu.com/doc/SPEECH/s/mlbxh7xie",
                note: "往下翻到「请求参数」，per 那张表里基础 / 精品 / 臻品 / 大模型四档都在。"
            ),
        ]
        let tokenField = Field(
            key: "token",
            label: "access_token",
            placeholder: "24.xxxx.xxxxx",
            help: "百度智能云控制台建个应用，用 API Key / Secret Key 换 token，有效期 30 天，过期重换。点下面第一条去建。"
        )
        var list = baiduVoices.map { voice, per, note in
            TTSOnlinePreset(
                id: "baidu-\(per)",
                brand: "百度",
                name: voice,
                detail: "\(note) · per=\(per)",
                template: "https://tsn.baidu.com/text2audio?tex={{java.encodeURI(speakText)}}&tok={token}&cuid=juyue&ctp=1&lan=zh&aue=3&per=\(per)&spd=5&pit=5&vol=5",
                fields: [tokenField],
                links: baiduDocs
            )
        }
        // 上面七个人是常见的那几个，不是全部：per 是百度后台编的号，官方加了新发音人这里跟不上。
        // 留一条自选的，填多少发多少，省得每次等更新。
        list.append(
            TTSOnlinePreset(
                id: "baidu-custom",
                brand: "百度",
                name: "自选发音人",
                detail: "表里挑音色，只填 token 就能用",
                template: "https://tsn.baidu.com/text2audio?tex={{java.encodeURI(speakText)}}&tok={token}&cuid=juyue&ctp=1&lan=zh&aue=3&per={per}&spd=5&pit=5&vol=5",
                fields: [
                    tokenField,
                    Field(
                        key: "per",
                        label: "发音人",
                        placeholder: "点一下从表里挑",
                        help: "两百多个号里常见的 42 个都编进表了，分基础 / 精品 / 臻品 / 大模型四档。表里没有的，进选择页最底下自己填数字。",
                        kind: .choice(TTSBaiduVoices.all, allowCustom: true),
                        defaultValue: "5118"
                    )
                ],
                links: baiduDocs
            )
        )
        // 百度翻译那台播报机不收 Key，整句也能念，16 kHz，拿来直接听书够用。
        list.append(
            TTSOnlinePreset(
                id: "baidu-fanyi",
                brand: "百度",
                name: "翻译朗读",
                // 实测 27 字整句 200 回 audio/mpeg，49824 字节；spd 5 是常速
                detail: "免 Key · 16 kHz · 整句可念",
                template: "https://fanyi.baidu.com/gettts?lan=zh&text={{java.encodeURI(speakText)}}&spd=5&source=web",
                fields: []
            )
        )
        // 有道词典那条接口不收 Key，填个词就念，拿来试通道最快。
        list.append(
            TTSOnlinePreset(
                id: "youdao",
                brand: "有道",
                name: "词典发音",
                // 实测：整句 21 字会回 500 returned null audio，只认词条，别当朗读引擎用
                detail: "免 Key · 只认词条，整句会回 500",
                template: "https://dict.youdao.com/dictvoice?audio={{java.encodeURI(speakText)}}&le=zh",
                fields: []
            )
        )
        // 谷歌翻译的播报口，免 Key，24 kHz 是这批里采样率最高的；国内得能连出去。
        list.append(
            TTSOnlinePreset(
                id: "google-translate",
                brand: "谷歌",
                name: "翻译朗读",
                // 实测 27 字整句 200 回 audio/mpeg，63744 字节；不带 UA 也回音频
                detail: "免 Key · 24 kHz · 整句可念，需能连外网",
                template: "https://translate.google.com/translate_tts?ie=UTF-8&q={{java.encodeURI(speakText)}}&tl=zh-CN&client=tw-ob",
                fields: []
            )
        )
        return list
    }()
}

/// 选完发音人之后那张表单：只填 token 这一格。
struct TTSOnlinePresetSheet: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let preset: TTSOnlinePreset
    let onSave: ([String: String]) -> Void

    @State private var values: [String: String]

    init(preset: TTSOnlinePreset, onSave: @escaping ([String: String]) -> Void) {
        self.preset = preset
        self.onSave = onSave
        // 带默认值的格子先摆好，剩下的留空等用户填
        var seed: [String: String] = [:]
        for field in preset.fields {
            if let def = field.defaultValue { seed[field.key] = def }
        }
        _values = State(initialValue: seed)
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func openInBrowser(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #endif
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("服务")
                        Spacer()
                        Text("\(preset.brand) · \(preset.name)")
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                    HStack {
                        Text("音色")
                        Spacer()
                        Text(preset.detail)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                } header: {
                    Text("要加的服务")
                }
                .appThemedRows()

                ForEach(preset.fields) { field in
                    Section {
                        switch field.kind {
                        case .text:
                            TextField(field.placeholder, text: binding(for: field.key))
                                // textInputAutocapitalization 只在 iOS 的 SwiftUI 里有，
                                // macOS 侧（swift build / swift test）没有这个类型，报出来的
                                // 还是 ForEach 泛型推不出来的错，找不到根。
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                                .autocorrectionDisabled()
                                .font(.system(.footnote, design: .monospaced))
                                .accessibilityIdentifier("tts.preset.\(field.key)")
                        case let .choice(options, allowCustom):
                            TTSChoiceRow(
                                value: binding(for: field.key),
                                options: options,
                                allowCustom: allowCustom,
                                placeholder: field.placeholder
                            )
                            .accessibilityIdentifier("tts.preset.\(field.key)")
                        }
                    } header: {
                        Text(field.label)
                    } footer: {
                        if let help = field.help {
                            Text(help)
                        }
                    }
                    .appThemedRows()
                }

                if !preset.links.isEmpty {
                    Section {
                        ForEach(preset.links) { link in
                            Button {
                                openInBrowser(link.url)
                            } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(link.title)
                                        if let note = link.note {
                                            Text(note)
                                                .font(.caption)
                                                .foregroundColor(theme.palette.secondaryInk)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right.square")
                                        .foregroundColor(theme.palette.secondaryInk)
                                }
                            }
                        }
                    } header: {
                        Text("去网站办")
                    } footer: {
                        Text("用系统浏览器打开，登录后取 token 填回上方。")
                    }
                    .appThemedRows()
                }
            }
            .navigationTitle("添加 \(preset.brand)·\(preset.name)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // 表单也得跟着主题走，不然弹出来一块白
            .themedScrollBackground()
            .background(theme.palette.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(values)
                        dismiss()
                    }
                    .disabled(preset.fields.contains { (values[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
            }
        }
    }
}

/// 表单里「从表里挑」那一行：显示当前挑中的音色，点进去推一页分组列表。
struct TTSChoiceRow: View {
    @Environment(\.appTheme) private var theme

    @Binding var value: String
    let options: [TTSVoiceOption]
    let allowCustom: Bool
    let placeholder: String

    private var matched: TTSVoiceOption? { options.first { $0.value == value } }

    var body: some View {
        NavigationLink(destination: TTSVoicePickerView(selection: $value, options: options, allowCustom: allowCustom)) {
            HStack {
                if let hit = matched {
                    Text(hit.label)
                    Spacer()
                    Text("per=\(hit.value)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(theme.palette.secondaryInk)
                } else if value.isEmpty {
                    Text(placeholder)
                        .foregroundColor(theme.palette.secondaryInk)
                } else {
                    Text("其它编号")
                    Spacer()
                    Text("per=\(value)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(theme.palette.secondaryInk)
                }
            }
        }
    }
}

/// 分组挑发音人。挑完自己退回去，不用再点一次保存。
struct TTSVoicePickerView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.presentationMode) private var presentationMode

    @Binding var selection: String
    let options: [TTSVoiceOption]
    let allowCustom: Bool

    @State private var manual: String = ""

    private struct Group: Identifiable {
        var id: String { title }
        let title: String
        let items: [TTSVoiceOption]
    }

    /// 按 group 第一次出现的顺序分组，别让顺序每次进来都不一样
    private var groups: [Group] {
        var order: [String] = []
        var bucket: [String: [TTSVoiceOption]] = [:]
        for option in options {
            if bucket[option.group] == nil {
                order.append(option.group)
                bucket[option.group] = []
            }
            bucket[option.group]?.append(option)
        }
        return order.map { Group(title: $0, items: bucket[$0] ?? []) }
    }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        Button {
                            selection = item.value
                            presentationMode.wrappedValue.dismiss()
                        } label: {
                            HStack {
                                Text(item.label)
                                Spacer()
                                Text("per=\(item.value)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(theme.palette.secondaryInk)
                                if selection == item.value {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } header: {
                    Text(group.title)
                }
            }

            if allowCustom {
                Section {
                    TextField("数字", text: $manual)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .font(.system(.footnote, design: .monospaced))
                        .accessibilityIdentifier("tts.per.manual")
                    Button("用这个编号") {
                        let trimmed = manual.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        selection = trimmed
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("tts.per.manualApply")
                } header: {
                    Text("表里没有的")
                } footer: {
                    Text("填 per 数字。编号无效时服务端返回错误，原文会显示。")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("挑发音人")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .themedScrollBackground()
    }
}

/// 当前选中的在线语音源，存在 UserDefaults 里，系统语音用 nil 表示。
public enum TTSourceSelection {
    static let defaultsKey = "legado_active_tts_source_id"

    public static var activeId: Int64? {
        get {
            let raw = UserDefaults.standard.object(forKey: defaultsKey)
            guard let number = raw as? NSNumber else { return nil }
            return number.int64Value
        }
        set {
            let previous = activeId
            if let newValue {
                UserDefaults.standard.set(NSNumber(value: newValue), forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
            if previous != newValue {
                LegadoLog.log("[听书] 语音源 \(previous.map(String.init) ?? "nil") → \(newValue.map(String.init) ?? "nil")")
            }
        }
    }

    public static var activeSource: HttpTTS? {
        guard let id = activeId else { return nil }
        if id == HttpTTS.builtinOnlineId { return HttpTTS.builtinOnline }
        let store = HttpTTSStore.shared
        if store.sources.isEmpty {
            try? store.load()
        }
        guard let source = store.source(id: id) else { return nil }
        // 回环地址指向的是「跑这个 App 的机器」。模拟器里那是 Mac 上的服务，能用；
        // 真机上 127.0.0.1 就是手机自己，电脑一拔线这条源必死。
        // 别让死源把整段朗读吞掉，直接当没选，落到系统语音。
        if isLoopback(source.url) && !isSimulator { return nil }
        return source
    }

    /// 回环地址（含 localhost / ::1），真机上等同本地死源。
    public static func isLoopback(_ rule: String) -> Bool {
        let firstPiece = rule.split(separator: ",", maxSplits: 1).first.map(String.init) ?? rule
        guard let host = URL(string: firstPiece)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "0.0.0.0"
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    public static func displayName(in sources: [HttpTTS]) -> String {
        // 引擎选择优先于源选择：选了包内模型就报包内模型，别拿在线源的名字糊上去
        if TTSEngineChoice.current == .builtIn { return BundledTTSEngine.displayName }
        // 在线源优先：只要用户选过 HTTP 语音源，设置页那行就该报这个源的名字。
        // 之前先查系统音色，导致选了 Qwen3-TTS 还显示「系统语音 · Tingting」。
        if let id = activeId {
            if id == HttpTTS.builtinOnlineId { return HttpTTS.builtinOnline.name }
            if let named = sources.first(where: { $0.id == id })?.name {
                // 真机上选了回环源，实际跑的是离线的那条路，别在设置页撒谎。
                if isLoopback(sources.first(where: { $0.id == id })?.url ?? ""), !isSimulator {
                    let fallback = BundledTTSEngine.isModelBundled ? BundledTTSEngine.displayName : "系统语音"
                    return "\(fallback)（\(named) 仅电脑可用）"
                }
                return named
            }
            if let loaded = activeSource?.name {
                return loaded
            }
            return "在线语音源（已失效）"
        }
        if let voice = SystemVoiceSelection.selectedVoice {
            return "系统语音 · \(voice.name)"
        }
        return "系统语音"
    }

    /// 列表里永远先摆内置源，再接用户自己导入的。
    public static func selectable(_ sources: [HttpTTS]) -> [HttpTTS] {
        [HttpTTS.builtinOnline] + sources.filter { $0.id != HttpTTS.builtinOnlineId }
    }
}

/// iOS 16 才有 `scrollContentBackground`；15 上只能把 UITextView 的底色改成透明。
/// 用完立刻放回去，别让别处的编辑器跟着变透明。
extension View {
    @ViewBuilder
    func themedScrollBackground() -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            #if os(iOS)
            self
                .onAppear { UITextView.appearance().backgroundColor = .clear }
                .onDisappear { UITextView.appearance().backgroundColor = nil }
            #else
            self
            #endif
        }
    }
}

extension TTSOnlinePreset {
    enum InstallError: LocalizedError {
        case missingField(String)
        var errorDescription: String? {
            switch self {
            case .missingField(let label): return "少了 \(label)"
            }
        }
    }

    /// 把表单里的值填进模板，拼成一条能直接用的语音源。
    func build(values: [String: String]) throws -> HttpTTS {
        var rule = template
        for field in fields {
            let raw = (values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { throw InstallError.missingField(field.label) }
            // token 里带 + / = 这类字符，塞进 query 前得转义，否则服务端收到的是半个
            let escaped = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? raw
            rule = rule.replacingOccurrences(of: "{\(field.key)}", with: escaped)
        }
        return HttpTTS(name: "\(brand)·\(name)", url: rule, contentType: "audio/.*")
    }

    /// 落地：写进 httpTTS.json。先 load 一遍，否则内存里空数组会把已有源整个盖掉。
    @discardableResult
    static func install(_ preset: TTSOnlinePreset, values: [String: String]) throws -> HttpTTS {
        let source = try preset.build(values: values)
        let store = HttpTTSStore.shared
        try? store.load()
        let data = try JSONEncoder().encode([source])
        _ = try store.importJSON(String(decoding: data, as: UTF8.self), replace: false)
        return source
    }
}
