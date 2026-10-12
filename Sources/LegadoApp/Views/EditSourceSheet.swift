import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

public struct EditSourceSheet: View {
    @ObservedObject var bookStore = BookStore.shared
    @Environment(\.dismiss) private var dismiss

    let originalSource: BookSource

    @State private var name: String
    @State private var url: String
    @State private var group: String
    @State private var loginUrl: String
    @State private var exploreUrl: String
    @State private var isEnabled: Bool

    public init(source: BookSource) {
        self.originalSource = source
        self._name = State(initialValue: source.bookSourceName)
        self._url = State(initialValue: source.bookSourceUrl)
        self._group = State(initialValue: source.bookSourceGroup ?? "")
        self._loginUrl = State(initialValue: source.loginUrl ?? "")
        self._exploreUrl = State(initialValue: source.exploreUrl ?? "")
        self._isEnabled = State(initialValue: source.enabled ?? true)
    }

    public var body: some View {
        NavigationView {
            Form {
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
            .navigationTitle("编辑书源")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveChanges()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
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
}
