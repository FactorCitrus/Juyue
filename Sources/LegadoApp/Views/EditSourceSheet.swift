import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

public struct EditSourceSheet: View {
    @ObservedObject var bookStore = BookStore.shared
    @Environment(\.dismiss) private var dismiss

    let originalSource: BookSource

    /// 表单改常用字段，源码直接改整段 JSON
    enum Mode: String, CaseIterable, Identifiable {
        case form = "表单"
        case source = "源码"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .form
    @State private var rawJSON: String
    @State private var rawError: String? = nil
    @State private var copiedHint = false

    @State private var name: String
    @State private var url: String
    @State private var group: String
    @State private var loginUrl: String
    @State private var exploreUrl: String
    @State private var isEnabled: Bool

    public init(source: BookSource) {
        self.originalSource = source
        self._rawJSON = State(initialValue: Self.prettyJSON(of: source))
        self._name = State(initialValue: source.bookSourceName)
        self._url = State(initialValue: source.bookSourceUrl)
        self._group = State(initialValue: source.bookSourceGroup ?? "")
        self._loginUrl = State(initialValue: source.loginUrl ?? "")
        self._exploreUrl = State(initialValue: source.exploreUrl ?? "")
        self._isEnabled = State(initialValue: source.enabled ?? true)
    }

    /// 书源对象转成好看的 JSON：键排序、斜杠不转义，方便直接看和改
    private static func prettyJSON(of source: BookSource) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(source),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    public var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("编辑方式", selection: $mode) {
                        ForEach(Mode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .form {
                    formSections
                } else {
                    sourceSections
                }
            }
            .navigationTitle(mode == .form ? "编辑书源" : "书源源码")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        switch mode {
                        case .form:
                            saveChanges()
                            dismiss()
                        case .source:
                            if saveRawJSON() { dismiss() }
                        }
                    }
                    .disabled(mode == .form && (name.trimmingCharacters(in: .whitespaces).isEmpty || url.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
    }

    @ViewBuilder
    private var formSections: some View {
                Section(header: Text("基本信息")) {
                    HStack {
                        Text("书源名称")
                            .frame(width: 80, alignment: .leading)
                        TextField("如：示例书源", text: $name)
                    }

                    HStack {
                        Text("书源网址")
                            .frame(width: 80, alignment: .leading)
                        TextField("https://...", text: $url)
                            #if os(iOS)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            #endif
                    }

                    HStack {
                        Text("分组")
                            .frame(width: 80, alignment: .leading)
                        TextField("如：网络小说", text: $group)
                    }

                    Toggle("启用该书源", isOn: $isEnabled)
                }

                Section(header: Text("发现分类配置 (exploreUrl)")) {
                    TextEditor(text: $exploreUrl)
                        .frame(minHeight: 120)
                        .font(.system(.caption, design: .monospaced))
                }

                Section(header: Text("登录脚本配置 (loginUrl / JS)")) {
                    TextEditor(text: $loginUrl)
                        .frame(minHeight: 100)
                        .font(.system(.caption, design: .monospaced))
                }
    }

    @ViewBuilder
    private var sourceSections: some View {
        Section(header: Text("整段 JSON（保存时按 JSON 解析回写）")) {
            TextEditor(text: $rawJSON)
                .frame(minHeight: 380)
                .font(.system(.caption, design: .monospaced))
                #if os(iOS)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                #endif
        }

        if let rawError {
            Section {
                Text(rawError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }

        Section {
            Button {
                copyRawJSON()
                copiedHint = true
            } label: {
                Label(copiedHint ? "已复制" : "复制源码", systemImage: "doc.on.doc")
            }

            Button {
                rawJSON = Self.prettyJSON(of: originalSource)
                rawError = nil
            } label: {
                Label("还原成当前书源", systemImage: "arrow.uturn.backward")
            }
        }
    }

    private func saveChanges() {
        var updated = originalSource
        updated.bookSourceName = name.trimmingCharacters(in: .whitespaces)
        updated.bookSourceUrl = url.trimmingCharacters(in: .whitespaces)
        updated.bookSourceGroup = group.isEmpty ? nil : group.trimmingCharacters(in: .whitespaces)
        updated.loginUrl = loginUrl.isEmpty ? nil : loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.exploreUrl = exploreUrl.isEmpty ? nil : exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.enabled = isEnabled

        bookStore.updateSource(originalSource: originalSource, newSource: updated)
    }

    /// 源码模式保存：按 JSON 解回书源对象；解不出来就留在页面上报错，不关面板
    private func saveRawJSON() -> Bool {
        rawError = nil
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            rawError = "文本编码失败，检查有没有不支持的字符。"
            return false
        }
        do {
            let parsed = try JSONDecoder().decode(BookSource.self, from: data)
            guard !parsed.bookSourceUrl.trimmingCharacters(in: .whitespaces).isEmpty else {
                rawError = "bookSourceUrl 不能为空。"
                return false
            }
            bookStore.updateSource(originalSource: originalSource, newSource: parsed)
            return true
        } catch {
            rawError = "JSON 解析失败：\(error.localizedDescription)"
            return false
        }
    }

    private func copyRawJSON() {
        #if os(iOS)
        UIPasteboard.general.string = rawJSON
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawJSON, forType: .string)
        #endif
    }
}
