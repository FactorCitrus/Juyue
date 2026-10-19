import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

/// 书架上这本书找不到对应书源时的收口页。
/// 明确说明「没有自动串到别的源」，并给一个直接换源的入口。
struct MissingBookSourceView: View {
    let book: Book
    let onDismiss: () -> Void

    @ObservedObject private var store = BookStore.shared
    @State private var showSourceSwitch = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "link.badge.plus")
                .font(.system(size: 56))
                .foregroundColor(.orange)
            Text("这本书的书源不在了")
                .font(.headline)
            Text("「\(book.originName.isEmpty ? book.origin : book.originName)」这个源已经不在了。\n换一个源，或者先把原来的书源导回来。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button("换源") {
                showSourceSwitch = true
            }
            .buttonStyle(.borderedProminent)
            Button("返回书架") {
                onDismiss()
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .sheet(isPresented: $showSourceSwitch) {
            SourceSwitchSheet(book: book, currentSourceUrl: nil) { newSource, candidate in
                var updated = book
                updated.bookUrl = candidate.bookUrl
                updated.origin = newSource.bookSourceUrl
                updated.originName = newSource.bookSourceName
                if !candidate.name.isEmpty { updated.name = candidate.name }
                if let cover = candidate.coverUrl, !cover.isEmpty { updated.coverUrl = cover }
                _ = store.changeBookSource(from: book, to: updated)
                showSourceSwitch = false
                onDismiss()
            }
        }
        .navigationTitle(book.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { onDismiss() }
            }
        }
    }
}
