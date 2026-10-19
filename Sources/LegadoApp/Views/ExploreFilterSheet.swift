import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

/// exploreScreen 的编辑面板。选中的值由 CategoryExploreView 保存并作为查询参数发给分类 URL。
struct ExploreFilterSheet: View {
    let filters: [ExploreFilter]
    @Binding var values: [String: String]
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: [String: String]

    init(filters: [ExploreFilter], values: Binding<[String: String]>, onApply: @escaping () -> Void) {
        self.filters = filters
        self._values = values
        self.onApply = onApply
        self._draft = State(initialValue: values.wrappedValue)
    }

    var body: some View {
        let palette = NieRPalette(colorScheme)

        ZStack {
            NieRBackdrop(palette: palette)
            VStack(spacing: 0) {
                NieRSheetHeader(
                    palette: palette,
                    kicker: "DISCOVERY PARAMS",
                    title: "发现筛选",
                    subtitle: "\(filters.count) PARAMETERS"
                ) {
                    dismiss()
                }

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(filters.enumerated()), id: \.element.id) { index, filter in
                            NieRPanel(palette: palette) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Text(String(format: "%02d", index + 1))
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundColor(palette.accent)
                                        Text(filter.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(palette.ink)
                                        Spacer()
                                    }

                                    if filter.isSelect {
                                        Picker(filter.name, selection: Binding(
                                            get: { draft[filter.name] ?? filter.defaultValue },
                                            set: { draft[filter.name] = $0 }
                                        )) {
                                            Text("不限").tag("")
                                            ForEach(filter.options) { option in
                                                Text(option.name).tag(option.value)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .tint(palette.accent)
                                    } else {
                                        TextField("值", text: Binding(
                                            get: { draft[filter.name] ?? filter.defaultValue },
                                            set: { draft[filter.name] = $0 }
                                        ))
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(palette.ink)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 7)
                                        .background(palette.background.opacity(0.7))
                                        .overlay(
                                            Rectangle()
                                                .stroke(palette.line.opacity(0.7), lineWidth: 0.6)
                                        )
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        Button {
                            var defaults: [String: String] = [:]
                            for filter in filters where !filter.defaultValue.isEmpty {
                                defaults[filter.name] = filter.defaultValue
                            }
                            draft = defaults
                        } label: {
                            HStack {
                                Text("重置为默认值")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                Spacer()
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundColor(palette.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .overlay(
                                Rectangle()
                                    .stroke(palette.line.opacity(0.7), lineWidth: 0.6)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 16)
                }

                Button {
                    values = draft
                    dismiss()
                    onApply()
                } label: {
                    HStack {
                        Text("APPLY / 应用")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(palette.background)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(palette.accent)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }
}
