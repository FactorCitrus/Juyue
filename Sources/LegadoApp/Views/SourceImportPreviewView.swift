import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 导入前预览：新增 / 更新 / 同名冲突各多少，确认后才写仓库。
struct SourceImportPreviewView: View {
    let entries: [BookStore.SourceImportEntry]
    let onApply: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var overwriteConflicts = false

    private var newCount: Int { entries.filter { $0.status == .new }.count }
    private var updateCount: Int { entries.filter { $0.status == .update }.count }
    private var conflictCount: Int { entries.filter { $0.status == .conflict }.count }
    private var newerCount: Int {
        entries.filter { entry in
            guard let old = entry.existing?.lastUpdateTime,
                  let incoming = entry.incoming.lastUpdateTime else { return false }
            return incoming > old
        }.count
    }
    private var olderCount: Int {
        entries.filter { entry in
            guard let old = entry.existing?.lastUpdateTime,
                  let incoming = entry.incoming.lastUpdateTime else { return false }
            return incoming < old
        }.count
    }

    var body: some View {
        let palette = NieRPalette(colorScheme)

        ZStack {
            NieRBackdrop(palette: palette)
            VStack(spacing: 0) {
                NieRSheetHeader(
                    palette: palette,
                    kicker: "IMPORT SCAN",
                    title: "导入预览",
                    subtitle: "\(entries.count) SOURCE ENTRIES"
                ) {
                    dismiss()
                }

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        NieRPanel(palette: palette, raised: true) {
                            HStack(spacing: 0) {
                                summary("新增", newCount, palette.accent, palette: palette)
                                NieRDivider(palette: palette)
                                    .frame(width: 0.6, height: 34)
                                summary("更新", updateCount, palette.ink, palette: palette)
                                NieRDivider(palette: palette)
                                    .frame(width: 0.6, height: 34)
                                summary("同名", conflictCount, palette.warning, palette: palette)
                            }
                        }
                        .padding(.horizontal, 16)

                        if newerCount > 0 || olderCount > 0 {
                            NieRPanel(palette: palette) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("VERSION DIFF")
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .tracking(0.8)
                                        .foregroundColor(palette.muted)
                                    if newerCount > 0 {
                                        Text("\(newerCount) 个源的更新时间比本地新，导入后会覆盖本地版本。")
                                            .font(.system(size: 11))
                                            .foregroundColor(palette.accent)
                                    }
                                    if olderCount > 0 {
                                        Text("\(olderCount) 个源比本地旧，导入前确认一下。")
                                            .font(.system(size: 11))
                                            .foregroundColor(palette.warning)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        if conflictCount > 0 {
                            NieRPanel(palette: palette) {
                                VStack(alignment: .leading, spacing: 7) {
                                    Toggle("同名但网址不同也覆盖", isOn: $overwriteConflicts)
                                        .font(.system(size: 12))
                                        .foregroundColor(palette.ink)
                                        .tint(palette.accent)
                                    Text(overwriteConflicts
                                         ? "同名源会被新网址替换。"
                                         : "同名源都保留，新源名字后面加「（导入）」。")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(palette.muted)
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        NieRSectionTitle(
                            palette: palette,
                            index: "02",
                            title: "SOURCE ENTRIES",
                            trailing: "\(entries.count)"
                        )
                        .padding(.horizontal, 16)

                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            NieRPanel(palette: palette) {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text(String(format: "%02d", index + 1))
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(palette.accent)
                                        Text(entry.incoming.bookSourceName)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(palette.ink)
                                            .lineLimit(1)
                                        Spacer()
                                        NieRBadge(
                                            palette: palette,
                                            text: entry.status.rawValue,
                                            filled: entry.status == .conflict
                                        )
                                    }
                                    Text(entry.incoming.bookSourceUrl)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(palette.muted)
                                        .lineLimit(1)
                                    if let existing = entry.existing, entry.status == .conflict {
                                        Text("已有同名源：\(existing.bookSourceUrl)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(palette.warning)
                                            .lineLimit(1)
                                    }
                                    if let old = entry.existing?.lastUpdateTime,
                                       let incoming = entry.incoming.lastUpdateTime,
                                       old != incoming {
                                        Text(incoming > old ? "版本较新" : "版本较旧")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(incoming > old ? palette.accent : palette.muted)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 16)
                }

                Button {
                    onApply(overwriteConflicts)
                    dismiss()
                } label: {
                    HStack {
                        Text("IMPORT / 导入 \(entries.count) 个")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(palette.background)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(entries.isEmpty ? palette.muted : palette.accent)
                }
                .buttonStyle(.plain)
                .disabled(entries.isEmpty)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private func summary(_ title: String, _ count: Int, _ color: Color, palette: NieRPalette) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(palette.muted)
        }
        .frame(maxWidth: .infinity)
    }
}
