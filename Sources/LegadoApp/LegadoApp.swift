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
        AppLog.install()
        preloadDefaultSources()
        // 导入过的自定义字体要在用之前注册进进程，否则 CoreText 认不出来
        CustomFontService.shared.loadAll()
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
    /// 三个页签始终建出来，否则未选中的 tabItem 会消失（试过用条件包 Group，tab 栏就只剩书架了）。
    /// 启动卡顿改成由各页自己按 isActive 决定要不要干活。
    @State private var selection: Int = 0

    public init() {}

    public var body: some View {
        TabView(selection: $selection) {
            BookshelfView()
                .tabItem {
                    Label("书架", systemImage: "books.vertical.fill")
                }
                .tag(0)

            CategoryExploreView(isActive: selection == 1)
                .tabItem {
                    Label("分类", systemImage: "square.grid.2x2.fill")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
                .tag(2)
        }
    }
}
