import SwiftUI

struct SourceShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

#if os(iOS)
import UIKit

struct SourceShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
