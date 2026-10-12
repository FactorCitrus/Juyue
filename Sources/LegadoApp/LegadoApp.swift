import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

@main
public struct LegadoApp: App {
    @StateObject private var bookStore = BookStore.shared
    @AppStorage("legado_app_theme") private var appTheme: String = "system"

    private var selectedColorScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    public init() {
        preloadDefaultSources()
    }

    public var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(bookStore)
                .preferredColorScheme(selectedColorScheme)
        }
    }

    private func preloadDefaultSources() {
        if bookStore.sources.isEmpty {
            // Load bundled default sources if available
            if let bundleUrl = Bundle.main.url(forResource: "bookSources", withExtension: "json"),
               let data = try? Data(contentsOf: bundleUrl),
               let json = String(data: data, encoding: .utf8) {
                _ = try? bookStore.importSources(json: json)
            }
        }
    }
}

public struct MainTabView: View {
    public init() {}

    public var body: some View {
        TabView {
            BookshelfView()
                .tabItem {
                    Label("书架", systemImage: "books.vertical.fill")
                }

            CategoryExploreView()
                .tabItem {
                    Label("分类", systemImage: "square.grid.2x2.fill")
                }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
        }
    }
}
