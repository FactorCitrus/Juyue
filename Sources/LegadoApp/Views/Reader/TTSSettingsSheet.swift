import SwiftUI
import AVFoundation
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

    public init() {}

    public var body: some View {
        NavigationView {
            Form {
                Section(header: Text("引擎")) {
                    engineRow(name: "系统语音", subtitle: "iOS 内置，离线可用", selected: activeId == nil) {
                        select(nil)
                    }

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
        }
    }

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

    private func reloadSources() {
        let store = HttpTTSStore.shared
        try? store.load()
        sources = store.sources
        activeId = TTSourceSelection.activeId
    }

    private func select(_ id: Int64?) {
        TTSourceSelection.activeId = id
        activeId = id
        audio.stop()
    }
}
