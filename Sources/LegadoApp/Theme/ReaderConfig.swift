import SwiftUI

public enum ReaderTheme: String, CaseIterable, Identifiable {
    case white = "默认白"
    case parchment = "复古羊皮纸"
    case eyeCare = "护眼绿"
    case dark = "夜间暗黑"

    public var id: String { rawValue }

    public var backgroundColor: Color {
        switch self {
        case .white: return Color(red: 0.98, green: 0.98, blue: 0.98)
        case .parchment: return Color(red: 0.95, green: 0.90, blue: 0.82)
        case .eyeCare: return Color(red: 0.88, green: 0.94, blue: 0.88)
        case .dark: return Color(red: 0.12, green: 0.12, blue: 0.12)
        }
    }

    public var textColor: Color {
        switch self {
        case .white: return Color(red: 0.15, green: 0.15, blue: 0.15)
        case .parchment: return Color(red: 0.22, green: 0.18, blue: 0.15)
        case .eyeCare: return Color(red: 0.15, green: 0.25, blue: 0.15)
        case .dark: return Color(red: 0.80, green: 0.80, blue: 0.80)
        }
    }
}

public enum PageMode: String, CaseIterable, Identifiable {
    case scroll = "连续滚动"
    case pageByPage = "左右翻页"

    public var id: String { rawValue }
}

public class ReaderConfig: ObservableObject {
    public static let shared = ReaderConfig()

    @Published public var fontSize: CGFloat = 18.0
    @Published public var lineSpacing: CGFloat = 8.0
    @Published public var theme: ReaderTheme = .parchment

    @Published public var pageMode: PageMode {
        didSet {
            UserDefaults.standard.set(pageMode.rawValue, forKey: "reader_page_mode")
        }
    }

    public init() {
        if let savedMode = UserDefaults.standard.string(forKey: "reader_page_mode"),
           let mode = PageMode(rawValue: savedMode) {
            self.pageMode = mode
        } else {
            self.pageMode = .scroll
        }
    }
}
