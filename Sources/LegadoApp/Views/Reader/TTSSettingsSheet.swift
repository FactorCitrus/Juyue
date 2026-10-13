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

    /// 系统音色区上面那行说明，别让用户对着「默认」两个字发呆。
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
