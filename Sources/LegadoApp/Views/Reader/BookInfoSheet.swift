import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 书籍信息面板，对应安卓底部那排里的「信息」。
public struct BookInfoSheet: View {
    let book: Book
    let chapterCount: Int
    let currentChapterIndex: Int
    let currentChapterTitle: String
    let sourceName: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    public init(
        book: Book,
        chapterCount: Int,
        currentChapterIndex: Int,
        currentChapterTitle: String,
        sourceName: String
    ) {
        self.book = book
        self.chapterCount = chapterCount
        self.currentChapterIndex = currentChapterIndex
        self.currentChapterTitle = currentChapterTitle
        self.sourceName = sourceName
    }

    public var body: some View {
        let palette = NieRPalette(colorScheme)

        ZStack {
            NieRBackdrop(palette: palette)
            VStack(spacing: 0) {
                NieRSheetHeader(
                    palette: palette,
                    kicker: "BOOK DATA",
                    title: "书籍信息",
                    subtitle: book.name
                ) {
                    dismiss()
                }

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        NieRSectionTitle(palette: palette, index: "01", title: "TARGET", trailing: nil)
                            .padding(.horizontal, 16)
                        NieRPanel(palette: palette, raised: true) {
                            VStack(spacing: 0) {
                                infoRow("书名", book.name, palette: palette)
                                NieRDivider(palette: palette)
                                infoRow("作者", book.author.isEmpty ? "未知" : book.author, palette: palette)
                                if let kind = book.kind, !kind.isEmpty {
                                    NieRDivider(palette: palette)
                                    infoRow("类型", kind, palette: palette)
                                }
                                if let words = book.wordCount, !words.isEmpty {
                                    NieRDivider(palette: palette)
                                    infoRow("字数", words, palette: palette)
                                }
                            }
                        }
                        .padding(.horizontal, 16)

                        NieRSectionTitle(palette: palette, index: "02", title: "SOURCE", trailing: nil)
                            .padding(.horizontal, 16)
                        NieRPanel(palette: palette) {
                            VStack(spacing: 0) {
                                infoRow("书源", sourceName.isEmpty ? book.originName : sourceName, palette: palette)
                                NieRDivider(palette: palette)
                                infoRow("地址", book.bookUrl, lineLimit: 2, palette: palette)
                            }
                        }
                        .padding(.horizontal, 16)

                        NieRSectionTitle(palette: palette, index: "03", title: "PROGRESS", trailing: nil)
                            .padding(.horizontal, 16)
                        NieRPanel(palette: palette) {
                            VStack(spacing: 0) {
                                infoRow("章节", chapterCount > 0 ? "\(currentChapterIndex + 1) / \(chapterCount)" : "未知", palette: palette)
                                if !currentChapterTitle.isEmpty {
                                    NieRDivider(palette: palette)
                                    infoRow("当前", currentChapterTitle, lineLimit: 2, palette: palette)
                                }
                                if chapterCount > 0 {
                                    NieRDivider(palette: palette)
                                    infoRow("百分比", String(format: "%.2f%%", Double(currentChapterIndex + 1) / Double(chapterCount) * 100), palette: palette)
                                    NieRScanBar(
                                        palette: palette,
                                        progress: Double(currentChapterIndex + 1) / Double(chapterCount)
                                    )
                                    .padding(.top, 8)
                                }
                            }
                        }
                        .padding(.horizontal, 16)

                        if let intro = book.intro, !intro.isEmpty {
                            NieRSectionTitle(palette: palette, index: "04", title: "SYNOPSIS", trailing: nil)
                                .padding(.horizontal, 16)
                            NieRPanel(palette: palette) {
                                Text(intro)
                                    .font(.system(size: 12))
                                    .foregroundColor(palette.ink.opacity(0.86))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
        }
    }

    @ViewBuilder
    private func infoRow(
        _ title: String,
        _ value: String,
        lineLimit: Int = 1,
        palette: NieRPalette
    ) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(palette.muted)
                .frame(width: 64, alignment: .leading)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(palette.ink)
                .multilineTextAlignment(.trailing)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
    }
}
