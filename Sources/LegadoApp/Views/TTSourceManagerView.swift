import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 听书引擎管理：系统语音 + 导入的在线语音源。
public struct TTSourceManagerView: View {
    @State private var sources: [HttpTTS] = []
    @State private var activeSourceId: Int64? = TTSourceSelection.activeId
    @State private var showImportSheet = false
    @State private var importText = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        List {
            Section(header: Text("当前引擎")) {
                HStack {
                    Text("使用中")
                    Spacer()
                    Text(TTSourceSelection.displayName(in: sources))
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("引擎列表")) {
                Button {
                    TTSourceSelection.activeId = nil
                    activeSourceId = nil
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("系统语音").foregroundColor(.primary)
                            Text("iOS 内置 AVSpeechSynthesizer，离线可用")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if activeSourceId == nil {
                            Image(systemName: "checkmark").foregroundColor(.accentColor)
                        }
                    }
                }

                ForEach(sources, id: \.id) { source in
                    Button {
                        TTSourceSelection.activeId = source.id
                        activeSourceId = source.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name).foregroundColor(.primary)
                                Text(host(of: source.url))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if activeSourceId == source.id {
                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            remove(source)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }

            Section {
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
                Text("支持阅读（Legado）的 httpTTS 格式，单条对象或数组都行。")
            }

            if let statusMessage {
                Section {
                    Text(statusMessage).font(.caption).foregroundColor(.green)
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).font(.caption).foregroundColor(.red)
                }
            }
        }
        .navigationTitle("朗读引擎")
        .task { reload() }
        .sheet(isPresented: $showImportSheet) {
            NavigationView {
                VStack(spacing: 12) {
                    TextEditor(text: $importText)
                        .font(.system(.footnote, design: .monospaced))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3))
                        )
                        .padding(.horizontal)
                    Text("把语音源 JSON 粘在这里，比如 {\"name\":\"有道\",\"url\":\"https://dict.youdao.com/dictvoice?audio={{java.encodeURI(speakText)}}&le=zh\",\"contentType\":\"audio/mpeg\"}")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
                .navigationTitle("导入语音源")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showImportSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导入") {
                            importSource(importText)
                            showImportSheet = false
                        }
                        .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
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
        let store = HttpTTSStore.shared
        try? store.remove(id: source.id)
        if activeSourceId == source.id {
            TTSourceSelection.activeId = nil
        }
        reload()
        statusMessage = "已删除 \(source.name)"
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
            if let newValue {
                UserDefaults.standard.set(NSNumber(value: newValue), forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    public static var activeSource: HttpTTS? {
        guard let id = activeId else { return nil }
        let store = HttpTTSStore.shared
        if store.sources.isEmpty {
            try? store.load()
        }
        return store.source(id: id)
    }

    public static func displayName(in sources: [HttpTTS]) -> String {
        #if os(iOS)
        if let voice = BaiduOfflineTTS.activeVoice {
            return "百度离线 · \(voice.name)"
        }
        if let speaker = BaiduOnlineTTS.activeSpeaker {
            return "百度在线 · \(speaker.name)"
        }
        #endif
        if let voice = SystemVoiceSelection.selectedVoice {
            return "系统语音 · \(voice.name)"
        }
        guard let id = activeId else { return "系统语音" }
        if let named = sources.first(where: { $0.id == id })?.name {
            return named
        }
        if let loaded = activeSource?.name {
            return loaded
        }
        return "在线语音源（已失效）"
    }
}
