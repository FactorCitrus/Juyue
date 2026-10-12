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
        NavigationView {
            Form {
                Section(header: Text("书籍")) {
                    infoRow("书名", book.name)
                    infoRow("作者", book.author.isEmpty ? "未知" : book.author)
                    if let kind = book.kind, !kind.isEmpty {
                        infoRow("类型", kind)
                    }
                    if let words = book.wordCount, !words.isEmpty {
                        infoRow("字数", words)
                    }
                }

                Section(header: Text("来源")) {
                    infoRow("书源", sourceName.isEmpty ? book.originName : sourceName)
                    infoRow("地址", book.bookUrl, lineLimit: 2)
                }

                Section(header: Text("阅读进度")) {
                    infoRow("章节", chapterCount > 0 ? "\(currentChapterIndex + 1) / \(chapterCount)" : "未知")
                    if !currentChapterTitle.isEmpty {
                        infoRow("当前", currentChapterTitle, lineLimit: 2)
                    }
                    if chapterCount > 0 {
                        let percent = Double(currentChapterIndex + 1) / Double(chapterCount) * 100
                        infoRow("百分比", String(format: "%.2f%%", percent))
                    }
                }

                if let intro = book.intro, !intro.isEmpty {
                    Section(header: Text("简介")) {
                        Text(intro)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("书籍信息")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func infoRow(_ title: String, _ value: String, lineLimit: Int = 1) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .leading)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}
