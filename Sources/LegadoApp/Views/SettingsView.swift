import SwiftUI
import Darwin
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(WebKit)
import WebKit
#endif
#if canImport(LegadoCore)
import LegadoCore
#endif

enum AppIconChoice: String, CaseIterable, Identifiable {
    case modern
    case classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modern: return "猫与橙（新）"
        case .classic: return "像素猫（经典）"
        }
    }

    var subtitle: String {
        switch self {
        case .modern: return "当前默认图标"
        case .classic: return "紫色像素风旧图标"
        }
    }

    var alternateIconName: String? {
        switch self {
        case .modern: return nil
        case .classic: return "AppIconClassic"
        }
    }
}

private enum SettingsBoard: Int, CaseIterable, Identifiable {
    case read
    case display
    case sources
    case data
    case system

    var id: Int { rawValue }
    var index: String { String(format: "%02d", rawValue + 1) }

    var title: String {
        switch self {
        case .read: return "阅读"
        case .display: return "外观"
        case .sources: return "内容源"
        case .data: return "数据"
        case .system: return "系统"
        }
    }
}

final class AppIconManager: ObservableObject {
    static let shared = AppIconManager()

    @Published private(set) var choice: AppIconChoice
    @Published private(set) var isSwitching = false
    @Published var errorMessage: String?

    private let defaultsKey = "juyue_app_icon_choice"

    private init() {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)
        choice = AppIconChoice(rawValue: stored ?? "") ?? .modern
        #if os(iOS)
        if let current = UIApplication.shared.alternateIconName,
           current == AppIconChoice.classic.alternateIconName {
            choice = .classic
        }
        #endif
    }

    func apply(_ newChoice: AppIconChoice) {
        #if os(iOS)
        guard UIApplication.shared.supportsAlternateIcons else {
            AppLog.write("[图标] 请求切换 \(newChoice.rawValue)，但系统不支持")
            errorMessage = "当前系统不支持切换应用图标。"
            return
        }
        guard !isSwitching, newChoice != choice else {
            return
        }
        AppLog.write("[图标] 请求切换 \(newChoice.rawValue)")
        let previous = choice
        choice = newChoice
        isSwitching = true
        performSwitch(to: newChoice, previous: previous, retries: 5)
        #else
        choice = newChoice
        UserDefaults.standard.set(newChoice.rawValue, forKey: defaultsKey)
        #endif
    }

    #if os(iOS)
    private func performSwitch(to newChoice: AppIconChoice, previous: AppIconChoice, retries: Int) {
        UIApplication.shared.setAlternateIconName(newChoice.alternateIconName) { [weak self] error in
            DispatchQueue.main.async {
                // iOS 26 可能返回 Code 35 但图标已切换，系统实际值才是准的
                let actual = UIApplication.shared.alternateIconName
                if actual == newChoice.alternateIconName {
                    AppLog.write("[图标] 切换成功 \(newChoice.rawValue)")
                    self?.choice = newChoice
                    self?.isSwitching = false
                    UserDefaults.standard.set(newChoice.rawValue, forKey: self?.defaultsKey ?? "juyue_app_icon_choice")
                    return
                }
                if let error, retries > 0 {
                    let delays: [TimeInterval] = [0.5, 1.5, 3, 6, 10]
                    let delay = delays[min(delays.count - 1, 5 - retries)]
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self?.performSwitch(to: newChoice, previous: previous, retries: retries - 1)
                    }
                    return
                }
                let nsError = error as NSError?
                AppLog.write("[图标] 切换失败 domain=\(nsError?.domain ?? "-") code=\(nsError?.code ?? -1) desc=\(nsError?.localizedDescription ?? "-") actual=\(actual ?? "nil") uptime=\(Int(ProcessInfo.processInfo.systemUptime / 60))m")
                self?.choice = previous
                self?.isSwitching = false
                self?.errorMessage = nsError?.code == -54
                    ? "系统图标服务暂不可用，请重启手机后再试。"
                    : "系统暂时无法切换图标，请重试。"
            }
        }
    }
    #endif
}

public struct SettingsView: View {
    @ObservedObject var bookStore = BookStore.shared
    @ObservedObject var readerConfig = ReaderConfig.shared
    @ObservedObject var shelfConfig = BookshelfConfig.shared
    @StateObject private var appIcon = AppIconManager.shared
    @ObservedObject private var themeManager = AppThemeManager.shared
    @Environment(\.appTheme) private var theme

    @AppStorage("legado_app_theme") private var appTheme: String = "system"

    @State private var showRestoreAlert: Bool = false
    @State private var restoreSuccessMessage: String? = nil
    @State private var showClearCacheAlert: Bool = false
    /// WebDAV 那行的小字：填了地址就算「已配置」，同步过才是「已同步」。
    /// 之前只看 lastSyncTime，所以填完地址回来还显示「未配置」。
    @State private var webDAVStatusText: String = "未配置"
    @State private var clearCacheMessage: String? = nil
    @State private var showAppIconOptions: Bool = false
    @State private var presentedBoard: SettingsBoard? = nil
    @State private var boardContentVisible = false

    public init() {}

    private var badgeColorBinding: Binding<Color> {
        Binding(
            get: { shelfConfig.badgeColor },
            set: { shelfConfig.badgeColorHex = $0.hexString ?? shelfConfig.badgeColorHex }
        )
    }

    /// 与书架页一致：卡片越小列数越多。
    private var shelfAutoColumns: Int {
        let scale = shelfConfig.cardScale
        if scale >= 0.95 { return 2 }
        if scale >= 0.75 { return 3 }
        return 4
    }

    public var body: some View {
        NavigationView {
            ZStack {
                ScrollView {
                    VStack(spacing: 14) {
                        settingsHero
                        boardTile(.read, height: 132)
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)
                            ],
                            spacing: 12
                        ) {
                            boardTile(.display)
                            boardTile(.sources)
                            boardTile(.data)
                            boardTile(.system)
                        }

                        settingsFooter
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 110)
                }
                .background(AppThemeBackdrop())

                if let board = presentedBoard {
                    boardExpandedScreen(board)
                        .zIndex(2)
                }
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            #endif
            .onAppear {
                let cfg = WebDAVService.shared.loadConfig()
                if cfg.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    webDAVStatusText = "未配置"
                } else {
                    webDAVStatusText = cfg.lastSyncTime != nil ? "已同步" : "已配置"
                }
            }
            .onChange(of: appTheme) { newValue in
                AppLog.write("[设置] 外观模式 → \(newValue)")
            }
            .alert("重置书源", isPresented: $showRestoreAlert) {
                Button("取消", role: .cancel) {}
                Button("确定重置", role: .destructive) {
                    AppLog.write("[设置] 重置书源")
                    bookStore.loadBundledSources(forceReset: true)
                    restoreSuccessMessage = "书源已重置为预装状态"
                }
            } message: {
                Text("确定要把书源重置为预装默认状态吗？自己导入的书源会被覆盖，重新导入即可。")
            }
            .alert("清理阅读缓存", isPresented: $showClearCacheAlert) {
                Button("取消", role: .cancel) {}
                Button("确定清理", role: .destructive) {
                    AppLog.write("[设置] 清理阅读缓存")
                    clearCacheMessage = "缓存已成功清理"
                }
            } message: {
                Text("清理临时章节和图片缓存？书架和阅读进度会保留。")
            }
            .alert("图标切换失败", isPresented: Binding(
                get: { appIcon.errorMessage != nil },
                set: { if !$0 { appIcon.errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(appIcon.errorMessage ?? "")
            }
        }
    }

    private var settingsHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SETTINGS / 橘阅")
                    .font(theme.typography.label)
                    .foregroundColor(theme.palette.secondaryInk)
                Spacer()
                Text("SYS.ONLINE")
                    .font(theme.typography.mono)
                    .foregroundColor(theme.palette.secondaryInk)
            }

            Text("设置")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(theme.palette.ink)

            Text("本地设置 · 即时生效 · 05 MODULES · v\(shortVersion)")
                .font(theme.typography.mono)
                .foregroundColor(theme.palette.secondaryInk)

            HStack(spacing: 0) {
                Rectangle()
                    .fill(theme.palette.accent)
                    .frame(width: 24, height: 2)
                Rectangle()
                    .fill(theme.palette.divider.opacity(0.9))
                    .frame(height: 0.5)
                Rectangle()
                    .fill(theme.palette.ink.opacity(0.75))
                    .frame(width: 4, height: 4)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                .fill(theme.palette.surface)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.palette.accent)
                .frame(width: 3)
                .padding(.vertical, 14)
        }
        .overlay(
            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
        )
    }

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// 宫格之后的终端页脚：模块结束标记 + 当前包与库的状态。
    private var settingsFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(theme.palette.accent)
                    .frame(width: 14, height: 2)
                Text("END OF MODULES / 05")
                    .font(theme.typography.label)
                    .foregroundColor(theme.palette.secondaryInk)
                Rectangle()
                    .fill(theme.palette.divider.opacity(0.7))
                    .frame(height: 0.5)
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.appVersionText)
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.ink)
                    Text("书架 \(bookStore.bookshelf.count) 本 · 书源 \(bookStore.sources.count) 个 · WebDAV \(webDAVStatusText)")
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.secondaryInk)
                }

                Spacer(minLength: 8)

                NavigationLink(destination: LogViewerView()) {
                    HStack(spacing: 4) {
                        Text("诊断日志")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                .fill(theme.palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
        )
    }

    private var panelFill: Color {
        theme.palette.surface
    }

    private func boardTile(_ board: SettingsBoard, height: CGFloat = 146) -> some View {
        return Button {
            boardContentVisible = false
            withAnimation(.easeInOut(duration: 0.26)) {
                presentedBoard = board
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeOut(duration: 0.18)) {
                    boardContentVisible = true
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(board.index)
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.secondaryInk)
                    Spacer()
                    Image(systemName: boardSymbol(board))
                        .font(theme.typography.symbol)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                Spacer(minLength: 0)
                Text(board.title)
                    .font(.headline)
                    .foregroundColor(theme.palette.ink)
                Text(boardDescription(board))
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(2)
                Text(boardSummary(board))
                    .font(theme.typography.mono)
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                    .fill(panelFill)
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                    .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
            )
            .overlay(alignment: .bottomTrailing) {
                Text(board.index)
                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.palette.ink.opacity(0.045))
                    .padding(8)
            }
        }
        .buttonStyle(.plain)
    }

    private func boardSymbol(_ board: SettingsBoard) -> String {
        switch board {
        case .read: return "book.closed"
        case .display: return "paintpalette"
        case .sources: return "square.stack.3d.up"
        case .data: return "externaldrive"
        case .system: return "gearshape"
        }
    }

    private func boardExpandedScreen(_ board: SettingsBoard) -> some View {
        ZStack {
            AppThemeBackdrop()

            // 展开页整屏实底：不再跟着卡片做几何动画，避免动画/截图里留出浅色方块
            panelFill
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        boardContentVisible = false
                        withAnimation(.easeInOut(duration: 0.22)) {
                            presentedBoard = nil
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(theme.palette.ink)
                            .padding(8)
                    }
                    .buttonStyle(.plain)

                    Text(board.index)
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.secondaryInk)
                    Text(board.title)
                        .font(.headline)
                        .foregroundColor(theme.palette.ink)
                    Spacer()
                    Text("MODULE \(board.index)")
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        boardContent(board)
                    }
                    .padding(16)
                    .padding(.bottom, 40)
                }
            }
            .opacity(boardContentVisible ? 1 : 0)
            .scaleEffect(boardContentVisible ? 1 : 0.985)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func boardContent(_ board: SettingsBoard) -> some View {
        switch board {
        case .read: readBoard
        case .display: displayBoard
        case .sources: sourcesBoard
        case .data: dataBoard
        case .system: systemBoard
        }
    }

    private func boardDescription(_ board: SettingsBoard) -> String {
        switch board {
        case .read: return "字号、行距、背景与净化"
        case .display: return "主题、图标与书架外观"
        case .sources: return "书源、OPDS、RSS 与订阅"
        case .data: return "云同步、缓存与下载"
        case .system: return "朗读、日志与关于"
        }
    }

    private func boardSummary(_ board: SettingsBoard) -> String {
        switch board {
        case .read:
            return "字号 \(Int(readerConfig.fontSize)) / 行距 \(Int(readerConfig.lineSpacing))"
        case .display:
            let appearance: String
            switch appTheme {
            case "light": appearance = "浅色"
            case "dark": appearance = "深色"
            default: appearance = "跟随系统"
            }
            return "\(appearance) / \(appIcon.choice.title)"
        case .sources:
            return "书源 \(bookStore.sources.count) / OPDS \(OPDSStore.shared.catalogs.count) / RSS \(RSSStore.shared.sources.count)"
        case .data:
            return "WebDAV \(webDAVStatusText)"
        case .system:
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            return "v\(version) / 5 MODULES"
        }
    }

    /// 分组标题：小色条 + 等宽标签 + 细线，把子页内容切成有层级的段落。
    private func sectionCard<Content: View>(
        _ title: String,
        tag: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(theme.palette.accent)
                    .frame(width: 12, height: 2)
                Text(title)
                    .font(theme.typography.label)
                    .foregroundColor(theme.palette.secondaryInk)
                Rectangle()
                    .fill(theme.palette.divider.opacity(0.6))
                    .frame(height: 0.5)
                Text(tag)
                    .font(theme.typography.mono)
                    .foregroundColor(theme.palette.secondaryInk.opacity(0.75))
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                    .fill(theme.palette.surface)
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                    .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
            )
        }
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(theme.palette.divider.opacity(0.55))
            .frame(height: 0.5)
            .padding(.leading, 56)
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.palette.accent)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: max(6, theme.metrics.cornerRadius - 3), style: .continuous)
                    .fill(theme.palette.elevated)
            )
    }

    private func settingLabel(
        _ title: String,
        icon: String?,
        value: String?,
        detail: String?,
        chevron: Bool
    ) -> some View {
        HStack(spacing: 12) {
            if let icon {
                rowIcon(icon)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.typography.body)
                    .foregroundColor(theme.palette.ink)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.system(size: 13))
                    .foregroundColor(theme.palette.secondaryInk)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.palette.secondaryInk.opacity(0.65))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func settingLink<Destination: View>(
        _ title: String,
        icon: String? = nil,
        value: String? = nil,
        detail: String? = nil,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            settingLabel(title, icon: icon, value: value, detail: detail, chevron: true)
        }
        .buttonStyle(.plain)
    }

    private func settingRow(
        _ title: String,
        icon: String? = nil,
        value: String? = nil,
        detail: String? = nil
    ) -> some View {
        settingLabel(title, icon: icon, value: value, detail: detail, chevron: false)
    }

    private func settingSlider(
        _ title: String,
        icon: String? = nil,
        value: String,
        _ binding: Binding<CGFloat>,
        in range: ClosedRange<CGFloat>,
        step: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let icon {
                    rowIcon(icon)
                }
                Text(title)
                    .font(theme.typography.body)
                    .foregroundColor(theme.palette.ink)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.palette.secondaryInk)
            }
            Slider(value: binding, in: range, step: step)
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 13)
    }

    private func settingBlock<Content: View>(
        _ title: String? = nil,
        icon: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                HStack(spacing: 12) {
                    if let icon {
                        rowIcon(icon)
                    }
                    Text(title)
                        .font(theme.typography.body)
                        .foregroundColor(theme.palette.ink)
                }
            }
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func settingStepper(
        _ title: String,
        icon: String? = nil,
        value: String,
        _ binding: Binding<Int>,
        in range: ClosedRange<Int>,
        step: Int = 1
    ) -> some View {
        HStack(spacing: 12) {
            if let icon {
                rowIcon(icon)
            }
            Text(title)
                .font(theme.typography.body)
                .foregroundColor(theme.palette.ink)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(theme.palette.secondaryInk)
            Stepper("", value: binding, in: range, step: step)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func chipPicker<Option: Hashable>(
        selection: Binding<Option>,
        options: [(Option, String)],
        columns: Int
    ) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: max(1, columns)),
            spacing: 6
        ) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, item in
                let isSelected = selection.wrappedValue == item.0
                Button {
                    selection.wrappedValue = item.0
                } label: {
                    Text(item.1)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? theme.palette.onAccent : theme.palette.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                                .fill(isSelected ? theme.palette.accent : theme.palette.elevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                                .stroke(isSelected ? theme.palette.accent : theme.palette.divider,
                                        lineWidth: theme.metrics.borderWidth)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var readBoard: some View {
        sectionCard("排版", tag: "TYPE") {
            settingLink(
                "字体管理",
                icon: "textformat",
                value: readerConfig.font.displayName,
                detail: "导入 ttf / otf，选中即用"
            ) {
                FontManageView()
            }
            cardDivider
            settingSlider(
                "正文字号",
                icon: "textformat.size",
                value: "\(Int(readerConfig.fontSize)) pt",
                $readerConfig.fontSize,
                in: 12...32,
                step: 1
            )
            cardDivider
            settingSlider(
                "段落行距",
                icon: "text.alignleft",
                value: "\(Int(readerConfig.lineSpacing)) pt",
                $readerConfig.lineSpacing,
                in: 4...24,
                step: 1
            )
            cardDivider
            settingStepper(
                "默认缓存章数",
                icon: "tray.and.arrow.down",
                value: "\(readerConfig.cachedChapterCount) 章",
                $readerConfig.cachedChapterCount,
                in: 1...200
            )
        }

        sectionCard("背景", tag: "SURFACE") {
            settingBlock("阅读底色", icon: "paintpalette") {
                chipPicker(
                    selection: $readerConfig.theme,
                    options: ReaderTheme.allCases.map { ($0, $0.rawValue) },
                    columns: 2
                )
            }
            cardDivider
            settingBlock {
                VStack(alignment: .leading, spacing: 6) {
                    Text("排版预览")
                        .font(theme.typography.label)
                        .foregroundColor(theme.palette.secondaryInk)
                    Text("这是示例文本，天地玄黄，宇宙洪荒。日月盈昃，辰宿列张。")
                        .font(.system(size: readerConfig.fontSize))
                        .lineSpacing(readerConfig.lineSpacing)
                        .foregroundColor(readerConfig.theme.textColor)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(readerConfig.theme.backgroundColor)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.palette.divider.opacity(0.2), lineWidth: 1)
                        )
                }
            }
            #if os(iOS)
            cardDivider
            settingLink("正文背景图", icon: "photo", value: "预览 / 缩放 / 位置") {
                ReaderBackgroundSettingsView()
            }
            cardDivider
            settingLink("下拉背景与书签外观", icon: "bookmark", value: "背景图 / 书签图") {
                ReaderAssetsSheet { }
            }
            #endif
        }

        sectionCard("内容处理", tag: "PIPELINE") {
            settingLink(
                "替换净化",
                icon: "wand.and.stars",
                value: "\(TextPurifier.shared.rules.filter { $0.enabled }.count) 条启用"
            ) {
                ReplacementRulesView()
            }
            cardDivider
            settingLink(
                "阅读统计",
                icon: "chart.bar",
                value: "\(ReadingStatsStore.shared.streakDays) 天连续"
            ) {
                ReadingStatsView()
            }
        }
    }

    @ViewBuilder
    private var displayBoard: some View {
        sectionCard("界面主题", tag: "THEME") {
            settingBlock("配色方案", icon: "paintpalette") {
                Picker("界面主题", selection: $themeManager.choice) {
                    ForEach(AppThemeChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                Text(themeManager.choice.subtitle)
                    .font(.caption)
                    .foregroundColor(theme.palette.secondaryInk)
            }
            cardDivider
            settingBlock("外观模式", icon: "circle.lefthalf.filled") {
                Picker("外观模式", selection: $appTheme) {
                    Text("跟随系统").tag("system")
                    Text("浅色模式").tag("light")
                    Text("深色模式").tag("dark")
                }
                .pickerStyle(.segmented)
            }
        }

        sectionCard("应用图标", tag: "ICON") {
            DisclosureGroup(isExpanded: $showAppIconOptions) {
                VStack(spacing: 0) {
                    ForEach(AppIconChoice.allCases) { option in
                        Button {
                            appIcon.apply(option)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .font(theme.typography.body)
                                        .foregroundColor(theme.palette.ink)
                                    Text(option.subtitle)
                                        .font(.caption2)
                                        .foregroundColor(theme.palette.secondaryInk)
                                }
                                Spacer()
                                if appIcon.choice == option {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(theme.palette.accent)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(appIcon.isSwitching)
                    }
                    if showAppIconOptions {
                        Text("切换后系统桌面图标会更新；若没变化，回桌面或重启 App。")
                            .font(.caption2)
                            .foregroundColor(theme.palette.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    rowIcon("app.badge")
                    Text("当前图标")
                        .font(theme.typography.body)
                        .foregroundColor(theme.palette.ink)
                    Spacer()
                    if appIcon.isSwitching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(appIcon.choice.title)
                            .font(.system(size: 13))
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .tint(theme.palette.accent)
        }

        sectionCard("书架排列", tag: "SHELF") {
            settingBlock("排列方式", icon: "rectangle.grid.2x2") {
                chipPicker(
                    selection: $shelfConfig.layout,
                    options: BookshelfLayoutStyle.allCases.map { ($0, $0.rawValue) },
                    columns: 2
                )
            }
            cardDivider
            settingSlider(
                "卡片大小",
                icon: "arrow.up.left.and.arrow.down.right",
                value: "\(Int((shelfConfig.cardScale * 100).rounded()))% · \(shelfAutoColumns) 列",
                $shelfConfig.cardScale,
                in: 0.40...1.40,
                step: 0.01
            )
        }

        sectionCard("书架角标", tag: "BADGE") {
            settingBlock("角标样式", icon: "bookmark") {
                chipPicker(
                    selection: $shelfConfig.badgeStyle,
                    options: BookshelfBadgeStyle.allCases.map { ($0, $0.rawValue) },
                    columns: 3
                )
            }

            if shelfConfig.badgeStyle == .count {
                cardDivider
                settingStepper(
                    "数字封顶",
                    value: shelfConfig.badgeCap == 0 ? "不封顶" : "\(shelfConfig.badgeCap)+",
                    $shelfConfig.badgeCap,
                    in: 0...999,
                    step: 5
                )
            }

            if shelfConfig.badgeStyle != .hidden {
                cardDivider
                settingBlock {
                    HStack(spacing: 12) {
                        rowIcon("eyedropper")
                        ColorPicker("角标颜色", selection: badgeColorBinding, supportsOpacity: false)
                            .font(theme.typography.body)
                    }
                }
                cardDivider
                settingBlock("角标位置", icon: "square.grid.2x2") {
                    chipPicker(
                        selection: $shelfConfig.badgeCorner,
                        options: BookshelfBadgeCorner.allCases.map { ($0, $0.rawValue) },
                        columns: 2
                    )
                }
                cardDivider
                settingSlider(
                    "字号",
                    icon: "textformat.size.smaller",
                    value: "\(Int(shelfConfig.badgeFontSize)) pt",
                    $shelfConfig.badgeFontSize,
                    in: 7...16,
                    step: 1
                )
                cardDivider
                settingSlider(
                    "离封面距离",
                    icon: "arrow.up.left.and.arrow.down.right",
                    value: "\(Int(shelfConfig.badgeOffset)) pt",
                    $shelfConfig.badgeOffset,
                    in: 0...16,
                    step: 1
                )
                cardDivider
                settingBlock {
                    Toggle("白色描边", isOn: $shelfConfig.badgeOutline)
                        .font(theme.typography.body)
                        .tint(theme.palette.accent)
                }
            }
        }
    }

    @ViewBuilder
    private var sourcesBoard: some View {
        sectionCard("网络书源", tag: "BOOK") {
            settingLink(
                "管理全部书源",
                icon: "square.stack.3d.up",
                value: "\(bookStore.sources.filter { $0.enabled != false }.count) / \(bookStore.sources.count) 个可用"
            ) {
                SourceManagerView()
            }
            cardDivider
            Button {
                showRestoreAlert = true
            } label: {
                settingLabel("重置书源", icon: "arrow.clockwise", value: "恢复预装", detail: nil, chevron: false)
            }
            .buttonStyle(.plain)
        }

        sectionCard("外部内容", tag: "FEED") {
            settingLink(
                "OPDS / Calibre 书库",
                icon: "books.vertical",
                value: "\(OPDSStore.shared.catalogs.count) 个"
            ) {
                OPDSCatalogsView()
            }
            cardDivider
            settingLink(
                "订阅源（阅读订阅源）",
                icon: "text.book.closed",
                value: "\(SubscribeSourceStore.shared.sources.count) 个源"
            ) {
                SubscribeSourcesView()
            }
            cardDivider
            settingLink(
                "订阅（RSS）",
                icon: "dot.radiowaves.left.and.right",
                value: "\(RSSStore.shared.sources.count) 个源"
            ) {
                RSSFeedsView()
            }
        }
    }

    @ViewBuilder
    private var dataBoard: some View {
        sectionCard("应用设置", tag: "CONFIG") {
            settingLink(
                "设置备份",
                icon: "externaldrive.badge.timemachine",
                value: "导入 / 导出 settings.json",
                detail: "阅读排版、书架外观、主题、替换规则、书源、朗读设置"
            ) {
                AppSettingsBackupView()
            }
        }

        sectionCard("云同步", tag: "CLOUD") {
            settingLink(
                "WebDAV 云同步",
                icon: "icloud.and.arrow.up",
                value: webDAVStatusText,
                detail: "备份、恢复与进度同步"
            ) {
                WebDAVSyncView()
            }
        }

        sectionCard("存储", tag: "LOCAL") {
            settingRow("书架藏书", icon: "books.vertical", value: "\(bookStore.bookshelf.count) 本")
            cardDivider
            settingRow("缓存章数上限", icon: "internaldrive", value: "\(readerConfig.cachedChapterCount) 章")
            cardDivider
            Button {
                showClearCacheAlert = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.palette.danger)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: max(6, theme.metrics.cornerRadius - 3), style: .continuous)
                                .fill(theme.palette.danger.opacity(0.08))
                        )
                    Text("清理阅读缓存")
                        .font(theme.typography.body)
                        .foregroundColor(theme.palette.danger)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        sectionCard("下载", tag: "QUEUE") {
            settingLink(
                "下载管理",
                icon: "arrow.down.circle",
                value: downloadStatusText
            ) {
                DownloadManagerView()
            }
        }
    }

    private var downloadStatusText: String {
        let running = ChapterDownloadManager.shared.jobs.filter { $0.isRunning }.count
        return running > 0 ? "\(running) 个进行中" : "空闲"
    }

    @ViewBuilder
    private var systemBoard: some View {
        sectionCard("朗读", tag: "TTS") {
            settingLink(
                "朗读引擎",
                icon: "speaker.wave.2",
                value: TTSourceSelection.displayName(in: HttpTTSStore.shared.sources),
                detail: "HTTP TTS 与系统语音"
            ) {
                TTSourceManagerView()
            }
        }

        sectionCard("诊断", tag: "LOG") {
            settingLink("诊断日志", icon: "doc.text.magnifyingglass", value: "操作与崩溃") {
                LogViewerView()
            }
        }

        sectionCard("关于", tag: "ABOUT") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Legado iOS")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(theme.palette.ink)
                Text("橘阅 · 开源阅读")
                    .font(theme.typography.mono)
                    .foregroundColor(theme.palette.secondaryInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            cardDivider
            settingRow("当前版本", icon: "number", value: Self.appVersionText)
            cardDivider
            settingRow("内核引擎", icon: "cpu", value: "Swift + JavaScriptCore")
            cardDivider
            Link(destination: URL(string: "https://github.com/FactorCitrus/Legado-iOS")!) {
                settingLabel("GitHub", icon: "link", value: "FactorCitrus/Legado-iOS", detail: nil, chevron: true)
            }
            .buttonStyle(.plain)
        }

        Text("© 2026 FactorCitrus。橘阅名称、图标与截图保留所有权利；非官方分支请改名换标。")
            .font(.caption2)
            .foregroundColor(theme.palette.secondaryInk)
            .padding(.horizontal, 4)
            .padding(.top, 2)
    }

    /// 装的是哪个包，一眼能看出来：版本号 + 构建号 + 这个可执行文件的编译时间。
    static var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        guard let path = Bundle.main.executablePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let created = attrs[.creationDate] as? Date else {
            return "\(short) (\(build))"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "\(short) (\(build)) · \(formatter.string(from: created))"
    }
}

/// 字体管理：导入 ttf/otf、删除，选中的字体立刻能在阅读设置里用。
struct FontManageView: View {
    @ObservedObject private var readerConfig = ReaderConfig.shared
    @ObservedObject private var fontService = CustomFontService.shared
    @Environment(\.appTheme) private var theme

    @State private var showImporter = false
    @State private var message: String?
    @State private var showMessage = false

    var body: some View {
        List {
            Section {
                TerminalPageHeader(code: "READ / FONT", title: "字体管理", detail: "内置字体 / 自定义字体")
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }
            .appThemedRows()

            Section(header: Text("正在使用")) {
                HStack {
                    Text(readerConfig.font.displayName)
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundColor(theme.palette.accent)
                }
            }
            .appThemedRows()

            Section(header: Text("内置字体")) {
                ForEach(ReaderFont.candidates.filter { $0.isAvailable }) { font in
                    fontRow(font)
                }
            }
            .appThemedRows()

            Section(header: Text("自定义字体")) {
                if fontService.registered.isEmpty {
                    Text("还没导入字体。点上面的「导入字体」，选 ttf / otf 文件。")
                        .font(.footnote)
                        .foregroundColor(theme.palette.secondaryInk)
                } else {
                    ForEach(fontService.registered) { font in
                        fontRow(font)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            fontService.remove(fontService.registered[index])
                        }
                    }
                }
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle("字体管理")
        .toolbar {
            Button {
                showImporter = true
            } label: {
                Label("导入字体", systemImage: "plus")
            }
        }
        #if os(iOS)
        // SwiftUI 的 fileImporter 在这种设置页里经常收不到回调，
        // 用户按「打开」就像没反应，所以 iOS 上改用 UIKit 的文档选择器
        .sheet(isPresented: $showImporter) {
            FontDocumentPicker { urls in
                // 等选择器退场再处理，不然弹窗会被吞
                DispatchQueue.main.async { importPicked(urls) }
            }
        }
        #else
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let urls):
                    importPicked(urls)
                case .failure(let error):
                    message = "导入失败：" + error.localizedDescription
                    showMessage = true
                }
            }
        }
        #endif
        .alert("字体", isPresented: $showMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    /// 选择器收回后统一处理：成功、被拒、以及为什么被拒都要说清楚
    private func importPicked(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var imported: [String] = []
        var rejected: [String] = []
        var reasons: [String] = []
        for url in urls {
            if let font = fontService.importFont(from: url) {
                imported.append(font.displayName)
            } else {
                rejected.append(url.lastPathComponent)
                if let reason = fontService.lastError, !reasons.contains(reason) {
                    reasons.append(reason)
                }
            }
        }
        if imported.isEmpty {
            var text = "没导入成功：" + rejected.joined(separator: "、")
            text += "\n只支持 ttf / otf / ttc；如果是 iCloud 里的文件，先下载到本机再选。"
            if !reasons.isEmpty { text += "\n原因：" + reasons.joined(separator: "；") }
            message = text
        } else if rejected.isEmpty {
            message = "已导入：" + imported.joined(separator: "、")
        } else {
            message = "已导入：" + imported.joined(separator: "、")
                + "\n没读进来：" + rejected.joined(separator: "、")
            if !reasons.isEmpty { message = (message ?? "") + "\n原因：" + reasons.joined(separator: "；") }
        }
        showMessage = true
    }

    private func fontRow(_ font: ReaderFont) -> some View {
        Button {
            readerConfig.fontName = font.postScriptName
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                TerminalInfoRow(
                    symbol: "textformat",
                    title: font.displayName,
                    value: readerConfig.fontName == font.postScriptName ? "使用中" : nil
                )
                // 用这个字体本身预览一行，选之前先看清长什么样
                Text("天地玄黄，宇宙洪荒")
                    .font(.custom(font.postScriptName, size: 15))
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(1)
            }
        }
    }

}

#if os(iOS)
/// UIKit 的文档选择器：asCopy 会先把文件拷进 App 沙箱再交回来，
/// 比 SwiftUI 的 fileImporter 稳，也不会出现「按了打开没反应」。
struct FontDocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
#endif

// MARK: - 替换净化
/// 正文替换净化：规则按顺序过一遍，用来去广告、水印、站点名
struct ReplacementRulesView: View {
    @ObservedObject private var purifier = TextPurifier.shared
    @Environment(\.appTheme) private var theme
    @State private var editing: ReplacementRule? = nil
    @State private var showImport = false
    @State private var importText = ""
    @State private var importMessage: String?
    @State private var showFileImporter = false

    var body: some View {
        List {
            Section {
                TerminalPageHeader(code: "READ / PURIFY", title: "替换净化", detail: "按顺序执行的正则与文本规则")
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }
            .appThemedRows()

            Section {
                HStack(spacing: 8) {
                    TerminalActionTile(symbol: "plus", title: "新增规则", detail: "文本 / 正则") {
                        editing = ReplacementRule(name: "", pattern: "", replacement: "")
                    }
                    TerminalActionTile(symbol: "square.and.arrow.down", title: "一键导入", detail: "JSON 规则包") {
                        importText = ""
                        importMessage = nil
                        showImport = true
                    }
                }
                .padding(.vertical, 4)
            }
            .appThemedRows()

            Section(header: Text("规则（从上到下依次执行）")) {
                if purifier.rules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 28))
                            .foregroundColor(theme.palette.secondaryInk)
                        Text("还没有替换规则")
                            .font(theme.typography.body.weight(.semibold))
                        Text("新增一条规则，去掉广告、水印或站点名。")
                            .font(theme.typography.mono)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }
                ForEach(Array(purifier.rules.enumerated()), id: \.element.id) { index, rule in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(String(format: "%02d", index + 1))
                                    .font(theme.typography.mono)
                                    .foregroundColor(theme.palette.secondaryInk)
                                Text(rule.name.isEmpty ? (rule.isRegex ? "正则规则" : "文本替换") : rule.name)
                                    .font(.system(size: 14, weight: .semibold))
                                TerminalStatusPill(text: rule.isRegex ? "REGEX" : "TEXT",
                                                   color: rule.isRegex ? theme.palette.accent : theme.palette.secondaryInk)
                            }
                            Text(rule.pattern)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.palette.secondaryInk)
                                .lineLimit(2)
                            if !rule.replacement.isEmpty {
                                Text("→ " + rule.replacement)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(theme.palette.secondaryInk)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: enabledBinding(rule))
                            .labelsHidden()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = rule }
                }
                .onDelete { indexSet in
                    purifier.rules.remove(atOffsets: indexSet)
                }
            }
            .appThemedRows()

            Section {
                Text("留空替换内容＝直接删掉匹配到的文字。正则用 NSRegularExpression 语法，$1 表示第一个捕获组。")
                    .font(.footnote)
                    .foregroundColor(theme.palette.secondaryInk)
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle("替换净化")
        .sheet(item: $editing) { rule in
            ReplacementRuleEditor(rule: rule) { saved in
                if let idx = purifier.rules.firstIndex(where: { $0.id == saved.id }) {
                    purifier.rules[idx] = saved
                } else {
                    purifier.rules.append(saved)
                }
            }
        }
        .sheet(isPresented: $showImport) { importSheet }
    }

    /// 导入面板：贴 JSON，或者从文件选（对齐安卓 legado 导出的替换净化格式）
    private var importSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text("把替换净化的 JSON 贴进来，或者从文件里选。认安卓导出的那套键：name / pattern / replacement / isRegex / enabled。")
                    .font(.footnote)
                    .foregroundColor(theme.palette.secondaryInk)

                TextEditor(text: $importText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 200)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.divider.opacity(0.3)))

                if let importMessage {
                    Text(importMessage)
                        .font(.footnote)
                        .foregroundColor(importMessage.hasPrefix("导入") ? .green : .red)
                }

                Button {
                    showFileImporter = true
                } label: {
                    Label("从文件导入", systemImage: "doc")
                }

                Spacer()
            }
            .padding()
            .background(AppThemeBackdrop())
            .appThemedPage()
            .navigationTitle("导入替换净化")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showImport = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { importRules(importText) }
                        .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.json, .plainText, .item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        importText = text
                        importRules(text)
                    } else {
                        importMessage = "读不了这个文件"
                    }
                case .failure(let error):
                    importMessage = "选择文件失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func importRules(_ json: String) {
        guard let parsed = ReplacementRulesView.parseRules(json) else {
            importMessage = "解析失败：不是可用的替换净化 JSON"
            return
        }
        var added = 0
        for rule in parsed {
            let duplicate = purifier.rules.contains {
                $0.pattern == rule.pattern && $0.replacement == rule.replacement && $0.isRegex == rule.isRegex
            }
            if !duplicate {
                purifier.rules.append(rule)
                added += 1
            }
        }
        importMessage = "导入 \(added) 条（跳过重复 \(parsed.count - added) 条）"
        if added > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { showImport = false }
        }
    }

    /// 认安卓 legado 的导出格式，也认本 App 自己存的键
    static func parseRules(_ json: String) -> [ReplacementRule]? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var items: [Any] = []
        if let array = object as? [Any] {
            items = array
        } else if let dict = object as? [String: Any] {
            items = (dict["rules"] as? [Any]) ?? [dict]
        }

        var rules: [ReplacementRule] = []
        for item in items {
            guard let dict = item as? [String: Any] else { continue }
            var pattern = (dict["pattern"] as? String) ?? ""
            var isRegex = (dict["isRegex"] as? Bool) ?? true
            if let rawRegex = dict["regex"] {
                if let text = rawRegex as? String, pattern.isEmpty { pattern = text }
                if let flag = rawRegex as? Bool { isRegex = flag }
            }
            guard !pattern.isEmpty else { continue }
            rules.append(ReplacementRule(
                name: (dict["name"] as? String) ?? "",
                pattern: pattern,
                replacement: (dict["replacement"] as? String) ?? "",
                isRegex: isRegex,
                enabled: (dict["enabled"] as? Bool) ?? true
            ))
        }
        return rules.isEmpty ? nil : rules
    }

    private func enabledBinding(_ rule: ReplacementRule) -> Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { value in
                if let idx = purifier.rules.firstIndex(where: { $0.id == rule.id }) {
                    purifier.rules[idx].enabled = value
                }
            }
        )
    }
}

struct ReplacementRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var draft: ReplacementRule
    private let onSave: (ReplacementRule) -> Void

    init(rule: ReplacementRule, onSave: @escaping (ReplacementRule) -> Void) {
        _draft = State(initialValue: rule)
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("名称（可留空）", text: $draft.name)
                Toggle("按正则匹配", isOn: $draft.isRegex)
                TextField(draft.isRegex ? "正则表达式" : "要查找的文本", text: $draft.pattern)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("替换成（留空＝删掉）", text: $draft.replacement)
                    .autocorrectionDisabled()
                Toggle("启用", isOn: $draft.enabled)
            }
            .appThemedList()
            .navigationTitle("编辑规则")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.pattern.isEmpty)
                }
            }
        }
    }
}

// MARK: - 阅读统计
struct ReadingStatsView: View {
    @ObservedObject private var stats = ReadingStatsStore.shared
    @Environment(\.appTheme) private var theme

    private func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分"
    }

    var body: some View {
        List {
            Section {
                TerminalPageHeader(code: "READ / STATS", title: "阅读统计", detail: "今日数据 / 累计数据 / 最近 7 天")
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }
            .appThemedRows()

            Section {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    TerminalMetricCard(label: "今日阅读", value: duration(stats.todaySeconds), symbol: "clock")
                    TerminalMetricCard(label: "连续天数", value: "\(stats.streakDays) 天", symbol: "flame")
                    TerminalMetricCard(label: "总时长", value: duration(stats.totalSeconds), symbol: "calendar")
                    TerminalMetricCard(
                        label: "总字数",
                        value: NumberFormatter.localizedString(from: NSNumber(value: stats.totalCharacters), number: .decimal),
                        symbol: "text.alignleft"
                    )
                    TerminalMetricCard(label: "读完章节", value: "\(stats.chaptersRead) 章", symbol: "book.closed")
                    TerminalMetricCard(label: "有记录天数", value: "\(stats.daysRead) 天", symbol: "chart.bar")
                }
                .padding(.vertical, 4)
            }
            .appThemedRows()

            Section(header: Text("最近 7 天")) {
                VStack(spacing: 9) {
                    let days = stats.recentDays(7)
                    let maxSeconds = max(1, days.map { $0.seconds }.max() ?? 1)
                    ForEach(days, id: \.day) { item in
                        HStack(spacing: 10) {
                            Text(String(item.day.suffix(5)))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.palette.secondaryInk)
                                .frame(width: 44, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(theme.palette.divider.opacity(0.35))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(theme.palette.accent.opacity(0.72))
                                        .frame(width: max(2, geo.size.width * CGFloat(item.seconds) / CGFloat(maxSeconds)))
                                }
                            }
                            .frame(height: 12)
                            Text(item.seconds > 0 ? duration(item.seconds) : "—")
                                .font(.system(size: 11))
                                .foregroundColor(theme.palette.secondaryInk)
                                .frame(width: 74, alignment: .trailing)
                        }
                    }
                }
                .padding(12)
                .background(theme.palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                        .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
                )
                .clipShape(RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous))
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle("阅读统计")
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        let symbol: String
        switch title {
        case "阅读时长", "总时长": symbol = "clock"
        case "连续天数": symbol = "flame"
        case "总字数": symbol = "text.alignleft"
        case "读完章节": symbol = "book.closed"
        case "有记录天数": symbol = "calendar"
        default: symbol = "chart.bar"
        }
        return TerminalInfoRow(symbol: symbol, title: title, value: value)
    }
}

// MARK: - 下载管理
struct DownloadManagerView: View {
    @ObservedObject private var manager = ChapterDownloadManager.shared
    @Environment(\.appTheme) private var theme

    var body: some View {
        List {
            Section {
                TerminalPageHeader(code: "DATA / DOWNLOAD", title: "下载管理", detail: "缓存队列与失败重试")
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }
            .appThemedRows()

            if manager.jobs.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 30))
                        .foregroundColor(theme.palette.secondaryInk)
                    Text("没有下载任务")
                        .font(theme.typography.body.weight(.semibold))
                    Text("在书籍详情页右上「⋯」里缓存全本或未读章节。")
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.secondaryInk)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .appThemedRows()
            }
            ForEach(manager.jobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(job.bookName)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        TerminalStatusPill(
                            text: job.isCancelled ? "已取消" : (job.isPaused ? "已暂停" : (job.isRunning ? "下载中" : "已完成")),
                            color: job.isCancelled ? theme.palette.danger : theme.palette.accent
                        )
                    }
                    ProgressView(value: job.progress)
                    HStack(spacing: 8) {
                        Text("\(job.finished)/\(job.total)" + (job.failed > 0 ? "，失败 \(job.failed)" : ""))
                            .font(.system(size: 11))
                            .foregroundColor(theme.palette.secondaryInk)
                        if !job.currentChapter.isEmpty {
                            Text(job.currentChapter)
                                .font(.system(size: 11))
                                .foregroundColor(theme.palette.secondaryInk)
                                .lineLimit(1)
                        }
                        Spacer()
                        if job.isRunning {
                            Button(job.isPaused ? "继续" : "暂停") {
                                AppLog.write("[下载] \(job.isPaused ? "继续" : "暂停")任务 \(job.finished)/\(job.total)")
                                job.isPaused ? manager.resume(job.id) : manager.pause(job.id)
                            }
                            .font(.system(size: 12))
                            Button("取消") {
                                AppLog.write("[下载] 取消任务 \(job.finished)/\(job.total)")
                                manager.cancel(job.id)
                            }
                                .font(.system(size: 12))
                                .foregroundColor(theme.palette.danger)
                        }
                    }
                }
                .padding(10)
                .background(theme.palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                        .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
                )
                .clipShape(RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous))
                .padding(.vertical, 3)
                .appThemedRows()
            }
        }
        .appThemedList()
        .navigationTitle("下载管理")
        .toolbar {
            Button("清理已完成") {
                AppLog.write("[下载] 清理已完成任务 \(manager.jobs.count) 个")
                manager.clearFinished()
            }
        }
    }
}

// MARK: - 订阅源（阅读订阅源）

/// 订阅源的本地存储：整份 JSON 存 UserDefaults，按 sourceUrl 去重
final class SubscribeSourceStore: ObservableObject {
    static let shared = SubscribeSourceStore()

    @Published var sources: [SubscribeSource] = [] {
        didSet { save() }
    }
    @Published var refreshIntervals: [String: Int] = [:] {
        didSet { defaults.set(refreshIntervals, forKey: refreshIntervalsKey) }
    }
    @Published var lastRefreshes: [String: Double] = [:] {
        didSet { defaults.set(lastRefreshes, forKey: lastRefreshesKey) }
    }

    private let key = "subscribe_sources_v1"
    private let refreshIntervalsKey = "subscribe_refresh_intervals_v1"
    private let lastRefreshesKey = "subscribe_last_refreshes_v1"
    private let defaults = UserDefaults.standard

    init() {
        if let data = defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([SubscribeSource].self, from: data) {
            sources = list
        }
        refreshIntervals = defaults.dictionary(forKey: refreshIntervalsKey) as? [String: Int] ?? [:]
        lastRefreshes = defaults.dictionary(forKey: lastRefreshesKey) as? [String: Double] ?? [:]
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: key)
        }
    }

    func refreshInterval(for sourceUrl: String) -> Int {
        refreshIntervals[sourceUrl] ?? 0
    }

    func setRefreshInterval(_ minutes: Int, for sourceUrl: String) {
        if minutes > 0 {
            refreshIntervals[sourceUrl] = minutes
        } else {
            refreshIntervals.removeValue(forKey: sourceUrl)
        }
    }

    func lastRefresh(for sourceUrl: String) -> Date? {
        lastRefreshes[sourceUrl].map { Date(timeIntervalSince1970: $0) }
    }

    func markRefreshed(_ sourceUrl: String) {
        lastRefreshes[sourceUrl] = Date().timeIntervalSince1970
    }

    func isRefreshDue(_ source: SubscribeSource) -> Bool {
        let minutes = refreshInterval(for: source.sourceUrl)
        guard minutes > 0 else { return false }
        guard let last = lastRefresh(for: source.sourceUrl) else { return true }
        return Date().timeIntervalSince(last) >= Double(minutes * 60)
    }

    /// 导入：同地址的覆盖更新，其余追加。返回 (新增, 更新)
    @discardableResult
    func merge(_ list: [SubscribeSource]) -> (added: Int, updated: Int) {
        var added = 0
        var updated = 0
        for item in list where !item.sourceUrl.isEmpty {
            if let idx = sources.firstIndex(where: { $0.sourceUrl == item.sourceUrl }) {
                sources[idx] = item
                updated += 1
            } else {
                sources.append(item)
                added += 1
            }
        }
        LegadoLog.log("[订阅源] 导入 新增=\(added) 更新=\(updated) 总计=\(sources.count)")
        return (added, updated)
    }

    func remove(sourceUrl: String) {
        sources.removeAll { $0.sourceUrl == sourceUrl }
        LegadoLog.log("[订阅源] 删除 剩余=\(sources.count)")
    }

    func toggle(sourceUrl: String) {
        guard let idx = sources.firstIndex(where: { $0.sourceUrl == sourceUrl }) else { return }
        sources[idx].enabled = !(sources[idx].enabled ?? true)
    }
}

struct CachedSubscribeArticle: Codable, Identifiable, Equatable {
    var id: String
    var sourceUrl: String
    var sourceName: String
    var title: String
    var link: String
    var date: String?
    var summary: String?
    var imageUrl: String?
    var content: String
    var savedAt: Date

    var article: SubscribeArticle {
        SubscribeArticle(
            title: title,
            link: link,
            date: date,
            summary: summary,
            imageUrl: imageUrl
        )
    }
}

/// 订阅文章状态：已读、收藏、正文离线缓存，以及每个源最近抓到哪些文章。
/// 文章 key 用「源 URL + 文章链接」，避免不同源的相同链接互相污染。
final class SubscribeArticleStateStore: ObservableObject {
    static let shared = SubscribeArticleStateStore()

    @Published private(set) var readKeys: Set<String>
    @Published private(set) var favoriteKeys: Set<String>
    @Published private(set) var cachedArticles: [String: CachedSubscribeArticle]
    @Published private(set) var articleKeysBySource: [String: [String]]

    private let readKey = "subscribe_article_read_v1"
    private let favoriteKey = "subscribe_article_favorites_v1"
    private let cacheKey = "subscribe_article_cache_v1"
    private let sourceKeysKey = "subscribe_article_source_keys_v1"

    private init() {
        let defaults = UserDefaults.standard
        readKeys = Set(defaults.stringArray(forKey: readKey) ?? [])
        favoriteKeys = Set(defaults.stringArray(forKey: favoriteKey) ?? [])
        articleKeysBySource = defaults.dictionary(forKey: sourceKeysKey) as? [String: [String]] ?? [:]
        if let data = defaults.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([String: CachedSubscribeArticle].self, from: data) {
            cachedArticles = decoded
        } else {
            cachedArticles = [:]
        }
    }

    static func key(sourceUrl: String, article: SubscribeArticle) -> String {
        let link = article.link.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = link.isEmpty ? article.title : link
        return "\(sourceUrl)::\(suffix)"
    }

    func isRead(sourceUrl: String, article: SubscribeArticle) -> Bool {
        readKeys.contains(Self.key(sourceUrl: sourceUrl, article: article))
    }

    func markRead(sourceUrl: String, article: SubscribeArticle) {
        let key = Self.key(sourceUrl: sourceUrl, article: article)
        guard readKeys.insert(key).inserted else { return }
        UserDefaults.standard.set(Array(readKeys), forKey: readKey)
    }

    func markUnread(sourceUrl: String, article: SubscribeArticle) {
        let key = Self.key(sourceUrl: sourceUrl, article: article)
        guard readKeys.remove(key) != nil else { return }
        UserDefaults.standard.set(Array(readKeys), forKey: readKey)
    }

    func markAllRead(sourceUrl: String, articles: [SubscribeArticle]) {
        var changed = false
        for article in articles {
            if readKeys.insert(Self.key(sourceUrl: sourceUrl, article: article)).inserted {
                changed = true
            }
        }
        if changed {
            UserDefaults.standard.set(Array(readKeys), forKey: readKey)
        }
    }

    func isFavorite(sourceUrl: String, article: SubscribeArticle) -> Bool {
        favoriteKeys.contains(Self.key(sourceUrl: sourceUrl, article: article))
    }

    @discardableResult
    func toggleFavorite(sourceUrl: String, sourceName: String, article: SubscribeArticle) -> Bool {
        let key = Self.key(sourceUrl: sourceUrl, article: article)
        if favoriteKeys.remove(key) != nil {
            UserDefaults.standard.set(Array(favoriteKeys), forKey: favoriteKey)
            return false
        }
        favoriteKeys.insert(key)
        if cachedArticles[key] == nil {
            cachedArticles[key] = CachedSubscribeArticle(
                id: key, sourceUrl: sourceUrl, sourceName: sourceName,
                title: article.title, link: article.link, date: article.date,
                summary: article.summary, imageUrl: article.imageUrl,
                content: "", savedAt: Date()
            )
            persistCache()
        }
        UserDefaults.standard.set(Array(favoriteKeys), forKey: favoriteKey)
        return true
    }

    func cacheContent(sourceUrl: String, sourceName: String, article: SubscribeArticle, content: String) {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let key = Self.key(sourceUrl: sourceUrl, article: article)
        var item = cachedArticles[key] ?? CachedSubscribeArticle(
            id: key, sourceUrl: sourceUrl, sourceName: sourceName,
            title: article.title, link: article.link, date: article.date,
            summary: article.summary, imageUrl: article.imageUrl,
            content: "", savedAt: Date()
        )
        item.title = article.title
        item.link = article.link
        item.date = article.date
        item.summary = article.summary
        item.imageUrl = article.imageUrl
        item.content = content
        item.savedAt = Date()
        cachedArticles[key] = item
        persistCache()
    }

    func cachedContent(sourceUrl: String, article: SubscribeArticle) -> String? {
        let key = Self.key(sourceUrl: sourceUrl, article: article)
        let content = cachedArticles[key]?.content ?? ""
        return content.isEmpty ? nil : content
    }

    func favorites() -> [CachedSubscribeArticle] {
        favoriteKeys.compactMap { cachedArticles[$0] }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func recordArticles(sourceUrl: String, articles: [SubscribeArticle]) {
        let keys = articles.map { Self.key(sourceUrl: sourceUrl, article: $0) }
        guard !keys.isEmpty else { return }
        articleKeysBySource[sourceUrl] = keys
        UserDefaults.standard.set(articleKeysBySource, forKey: sourceKeysKey)
    }

    func unreadCount(sourceUrl: String) -> Int? {
        guard let keys = articleKeysBySource[sourceUrl], !keys.isEmpty else { return nil }
        return keys.filter { !readKeys.contains($0) }.count
    }

    private func persistCache() {
        if let data = try? JSONEncoder().encode(cachedArticles) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
}

/// 非 http(s) 的 singleUrl 深链，交给系统 App 处理。
struct SubscribeExternalSourceView: View {
    let source: SubscribeSource
    @Environment(\.appTheme) private var theme
    @State private var opened = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 34))
                .foregroundColor(theme.palette.accent)
            Text(source.sourceName)
                .font(theme.typography.body.weight(.semibold))
                .foregroundColor(theme.palette.ink)
            Text(source.sourceUrl)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.palette.secondaryInk)
                .multilineTextAlignment(.center)
            Text("这个订阅源使用外部 App 深链，不能在应用内直接抓取。")
                .font(.caption)
                .foregroundColor(theme.palette.secondaryInk)
                .multilineTextAlignment(.center)
            Button {
                open()
            } label: {
                Label("在系统应用中打开", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.palette.accent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppThemeBackdrop())
        .navigationTitle(source.sourceName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .appThemedPage()
        .onAppear {
            guard !opened else { return }
            opened = true
            open()
        }
    }

    private func open() {
        guard let url = URL(string: source.sourceUrl) else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}

struct DownloadedImportFile: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    let displayName: String
}

/// 网页里下载下来的文件不直接猜类型，先列可导入方式让用户选。
struct DownloadedImportSheet: View {
    let sourceName: String
    let file: DownloadedImportFile
    let onFinish: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var message: String?
    @State private var importing = false

    private enum ImportKind: String, Identifiable {
        case bookSource = "书源 JSON"
        case subscribeSource = "订阅源 JSON"
        case purifier = "净化规则"
        case book = "书籍文件"
        case font = "字体"
        case backup = "备份包"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .bookSource: return "square.stack.3d.up"
            case .subscribeSource: return "dot.radiowaves.left.and.right"
            case .purifier: return "wand.and.stars"
            case .book: return "book.closed"
            case .font: return "textformat"
            case .backup: return "externaldrive"
            }
        }
    }

    private var candidates: [ImportKind] {
        let ext = file.url.pathExtension.lowercased()
        if ["ttf", "otf", "ttc"].contains(ext) { return [.font] }

        var result: [ImportKind] = []
        if ext == "zip" { result.append(.backup) }
        if ["epub", "pdf", "mobi", "azw3", "cbz", "cb7"].contains(ext) {
            result.append(.book)
        }
        if ["json", "txt"].contains(ext), let text = try? String(contentsOf: file.url, encoding: .utf8) {
            if ReplacementRulesView.parseRules(text) != nil {
                result.append(.purifier)
            }
            let data = Data(text.utf8)
            if (try? JSONDecoder().decode([BookSource].self, from: data)) != nil {
                result.append(.bookSource)
            }
            if let sources = try? SubscribeSourceService.decodeSources(from: text),
               let first = sources.first,
               first.ruleArticles != nil || first.sortUrl != nil || first.sourceIcon != nil {
                result.append(.subscribeSource)
            }
            if ext == "txt" {
                if !result.contains(.purifier) { result.append(.purifier) }
                result.append(.book)
            }
        }
        if result.isEmpty {
            result.append(.book)
        }
        return result
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(file.fileName)
                            .font(theme.typography.body.weight(.semibold))
                            .foregroundColor(theme.palette.ink)
                        Text(sourceName)
                            .font(.caption2)
                            .foregroundColor(theme.palette.secondaryInk)
                        Text(file.url.pathExtension.uppercased().isEmpty ? "未知格式" : file.url.pathExtension.uppercased())
                            .font(theme.typography.mono)
                            .foregroundColor(theme.palette.accent)
                    }
                    .padding(.vertical, 4)
                }
                .appThemedRows()

                Section(header: Text("选择导入方式")) {
                    ForEach(candidates) { kind in
                        Button {
                            importFile(as: kind)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: kind.symbol)
                                    .foregroundColor(theme.palette.accent)
                                    .frame(width: 26)
                                Text(kind.rawValue)
                                    .foregroundColor(theme.palette.ink)
                                Spacer()
                                if importing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(theme.palette.secondaryInk)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .disabled(importing)
                    }
                }
                .appThemedRows()

                if let message {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(theme.palette.ink)
                    }
                    .appThemedRows()
                }
            }
            .appThemedList()
            .navigationTitle("导入下载文件")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .disabled(message == nil)
                }
            }
        }
    }

    private func importFile(as kind: ImportKind) {
        importing = true
        message = nil
        Task { @MainActor in
            do {
                let result: String
                switch kind {
                case .bookSource:
                    result = "书源导入：\(try BookStore.shared.importSources(json: try textContent())) 个"
                case .subscribeSource:
                    let sources = try SubscribeSourceService.decodeSources(from: try textContent())
                    let merged = SubscribeSourceStore.shared.merge(sources)
                    result = "订阅源导入：新增 \(merged.added) 个，更新 \(merged.updated) 个"
                case .purifier:
                    let rules = try purifierRules()
                    var added = 0
                    for rule in rules where !TextPurifier.shared.rules.contains(where: {
                        $0.pattern == rule.pattern && $0.replacement == rule.replacement && $0.isRegex == rule.isRegex
                    }) {
                        TextPurifier.shared.rules.append(rule)
                        added += 1
                    }
                    result = "净化规则导入：新增 \(added) 条"
                case .book:
                    let book = try BookStore.shared.importFile(from: file.url)
                    result = "书籍已加入书架：\(book.name)"
                case .font:
                    guard let font = CustomFontService.shared.importFont(from: file.url) else {
                        throw NSError(domain: "Import", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "字体注册失败，只支持 ttf / otf / ttc"])
                    }
                    result = "字体已导入：\(font.displayName)"
                case .backup:
                    let restored = try WebDAVService.shared.restoreFromZip(fileUrl: file.url)
                    let counts = BookStore.shared.restoreFromWebDAV(
                        books: restored.books, sources: restored.sources, mode: .merge
                    )
                    var settingsNote = ""
                    if let data = WebDAVService.shared.extractSettingsJSON(fromZipFileUrl: file.url),
                       let payload = AppSettingsBackup.decode(data) {
                        settingsNote = "，设置：\(AppSettingsBackup.apply(payload, mode: .merge))"
                    }
                    result = "备份恢复：新增书籍 \(counts.booksAdded) 本，新增书源 \(counts.sourcesAdded) 个\(settingsNote)"
                }
                importing = false
                message = result
                onFinish(result)
            } catch {
                importing = false
                message = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    private func textContent() throws -> String {
        guard let text = try? String(contentsOf: file.url, encoding: .utf8) else {
            throw NSError(domain: "Import", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "文件不是 UTF-8 文本"])
        }
        return text
    }

    private func purifierRules() throws -> [ReplacementRule] {
        let text = try textContent()
        if let rules = ReplacementRulesView.parseRules(text), !rules.isEmpty {
            return rules
        }
        var rules: [ReplacementRule] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            let separators = ["==>", "=>", "|||", "@@", "\t"]
            var pattern = line
            var replacement = ""
            for separator in separators {
                if let range = line.range(of: separator) {
                    pattern = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    replacement = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            if !pattern.isEmpty {
                rules.append(ReplacementRule(name: "", pattern: pattern,
                                             replacement: replacement, isRegex: true, enabled: true))
            }
        }
        guard !rules.isEmpty else {
            throw NSError(domain: "Import", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "没读到净化规则"])
        }
        return rules
    }
}

/// `singleUrl` 订阅源在 Legado 里是发布页，不是文章列表。直接用内嵌网页打开，
/// 同时接管网页里的 `legado://import/rssSource?src=...`，点一下就能更新源。
struct SubscribeSourceWebView: View {
    let source: SubscribeSource
    @ObservedObject private var store = SubscribeSourceStore.shared
    @ObservedObject private var bookStore = BookStore.shared
    @Environment(\.appTheme) private var theme

    @State private var webView: WKWebView
    @State private var isLoading = true
    @State private var title = ""
    @State private var currentURL: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var loadError: String?
    @State private var statusMessage: String?
    @State private var pendingImportFile: DownloadedImportFile?

    init(source: SubscribeSource) {
        self.source = source
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        if #available(iOS 14.0, macOS 11.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = source.enableJs ?? true
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = NetworkClient.defaultUserAgent
        webView.allowsBackForwardNavigationGestures = true
        _webView = State(initialValue: webView)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(theme.palette.accent)
            }

            ZStack {
                SubscribeSourceWebViewBox(
                    webView: webView,
                    onLoadingChanged: { loading in
                        isLoading = loading
                        updateNavigationState()
                    },
                    onTitleChanged: { title = $0 },
                    onURLChanged: { url in
                        currentURL = url
                        updateNavigationState()
                        mirrorCookies()
                    },
                    onLegadoURL: handleLegadoURL,
                    onExternalURL: openExternal,
                    onDownloadURL: downloadFile
                )

                if loadError != nil {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 30))
                            .foregroundColor(theme.palette.warning)
                        Text("网页打不开")
                            .font(theme.typography.body.weight(.semibold))
                            .foregroundColor(theme.palette.ink)
                        Text(loadError ?? "")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                            .multilineTextAlignment(.center)
                        Button("重试") {
                            loadError = nil
                            loadInitialPage()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.palette.accent)
                    }
                    .padding(24)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: theme.metrics.cornerRadius))
                }
            }

            Divider()

            HStack(spacing: 24) {
                Button {
                    webView.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoBack)

                Button {
                    webView.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canGoForward)

                Button {
                    webView.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }

                Spacer()

                Button {
                    if let currentURL { openExternal(currentURL) }
                } label: {
                    Image(systemName: "safari")
                }
                .disabled(currentURL == nil)
            }
            .font(.system(size: 17, weight: .medium))
            .foregroundColor(theme.palette.accent)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(theme.palette.surface)
        }
        .background(AppThemeBackdrop())
        .navigationTitle(title.isEmpty ? source.sourceName : title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .appThemedPage()
        .onAppear {
            if webView.url == nil {
                loadInitialPage()
            }
        }
        .alert("订阅源", isPresented: Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(statusMessage ?? "")
        }
        .sheet(item: $pendingImportFile) { file in
            DownloadedImportSheet(sourceName: source.sourceName, file: file) { result in
                statusMessage = result
            }
        }
    }

    private func loadInitialPage() {
        guard let url = URL(string: source.sourceUrl) else {
            loadError = "地址不合法"
            isLoading = false
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = (source.cacheFirst ?? false) ? .returnCacheDataElseLoad : .useProtocolCachePolicy
        for (key, value) in source.staticRequestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        isLoading = true
        webView.load(request)
    }

    private func updateNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func mirrorCookies() {
        guard source.enabledCookieJar ?? true else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
                CookieJar.shared.setCookies("\(cookie.name)=\(cookie.value)", for: cookie.domain)
            }
        }
    }

    private func handleLegadoURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "legado" else {
            return
        }
        let route = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard components.host == "import",
              let src = components.queryItems?.first(where: { $0.name == "src" })?.value,
              !src.isEmpty else {
            statusMessage = "暂不支持这个导入链接：\(url.absoluteString)"
            return
        }
        switch route {
        case "rssSource":
            importRemoteSubscribeSource(src)
        case "bookSource":
            importRemoteBookSource(src)
        default:
            statusMessage = "暂不支持这个导入链接：\(url.absoluteString)"
        }
    }

    private func importRemoteSubscribeSource(_ rawURL: String) {
        guard let url = URL(string: rawURL) else {
            statusMessage = "导入地址不合法：\(rawURL)"
            return
        }
        isLoading = true
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                    throw NSError(domain: "SubscribeSource", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(((response as? HTTPURLResponse)?.statusCode) ?? 0)"])
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw NSError(domain: "SubscribeSource", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "返回内容不是 UTF-8 文本"])
                }
                let sources = try SubscribeSourceService.decodeSources(from: text)
                guard !sources.isEmpty else {
                    throw NSError(domain: "SubscribeSource", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "没读到订阅源"])
                }
                let result = await MainActor.run { store.merge(sources) }
                await MainActor.run {
                    isLoading = false
                    statusMessage = "订阅源已更新：新增 \(result.added) 个，更新 \(result.updated) 个。"
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    statusMessage = "导入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func importRemoteBookSource(_ rawURL: String) {
        guard let url = URL(string: rawURL) else {
            statusMessage = "导入地址不合法：\(rawURL)"
            return
        }
        isLoading = true
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                    throw NSError(domain: "BookSource", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(((response as? HTTPURLResponse)?.statusCode) ?? 0)"])
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw NSError(domain: "BookSource", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "返回内容不是 UTF-8 文本"])
                }
                let count = try await MainActor.run { try bookStore.importSources(json: text) }
                await MainActor.run {
                    isLoading = false
                    statusMessage = "书源已导入：新增或更新 \(count) 个。"
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    statusMessage = "导入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func openExternal(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func downloadFile(_ url: URL) {
        isLoading = true
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let suggested = response.suggestedFilename
                    ?? url.lastPathComponent
                let safeName = suggested.isEmpty ? "download" : suggested
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + safeName)
                try data.write(to: tempURL)
                await MainActor.run {
                    isLoading = false
                    pendingImportFile = DownloadedImportFile(
                        url: tempURL,
                        fileName: safeName,
                        displayName: source.sourceName
                    )
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    statusMessage = "下载失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

#if os(iOS)
private struct SubscribeSourceWebViewBox: UIViewRepresentable {
    let webView: WKWebView
    let onLoadingChanged: (Bool) -> Void
    let onTitleChanged: (String) -> Void
    let onURLChanged: (URL?) -> Void
    let onLegadoURL: (URL) -> Void
    let onExternalURL: (URL) -> Void
    let onDownloadURL: (URL) -> Void

    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: SubscribeSourceWebViewBox

        init(parent: SubscribeSourceWebViewBox) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url {
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme == "legado" {
                    parent.onLegadoURL(url)
                    decisionHandler(.cancel)
                    return
                }
                if !scheme.isEmpty && !["http", "https", "about", "data", "file", "blob"].contains(scheme) {
                    parent.onExternalURL(url)
                    decisionHandler(.cancel)
                    return
                }
                if Self.isDownloadable(url) {
                    parent.onDownloadURL(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        private static let downloadExtensions: Set<String> = [
            "txt", "json", "ttf", "otf", "ttc", "zip", "epub", "pdf",
            "mobi", "azw3", "cbz", "cb7"
        ]

        private static func isDownloadable(_ url: URL) -> Bool {
            downloadExtensions.contains(url.pathExtension.lowercased())
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoadingChanged(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoadingChanged(false)
            parent.onTitleChanged(webView.title ?? "")
            parent.onURLChanged(webView.url)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoadingChanged(false)
            parent.onURLChanged(webView.url)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onLoadingChanged(false)
            parent.onURLChanged(webView.url)
        }
    }
}
#elseif os(macOS)
private struct SubscribeSourceWebViewBox: NSViewRepresentable {
    let webView: WKWebView
    let onLoadingChanged: (Bool) -> Void
    let onTitleChanged: (String) -> Void
    let onURLChanged: (URL?) -> Void
    let onLegadoURL: (URL) -> Void
    let onExternalURL: (URL) -> Void
    let onDownloadURL: (URL) -> Void

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: SubscribeSourceWebViewBox

        init(parent: SubscribeSourceWebViewBox) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url {
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme == "legado" {
                    parent.onLegadoURL(url)
                    decisionHandler(.cancel)
                    return
                }
                if !scheme.isEmpty && !["http", "https", "about", "data", "file", "blob"].contains(scheme) {
                    parent.onExternalURL(url)
                    decisionHandler(.cancel)
                    return
                }
                if Self.isDownloadable(url) {
                    parent.onDownloadURL(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        private static let downloadExtensions: Set<String> = [
            "txt", "json", "ttf", "otf", "ttc", "zip", "epub", "pdf",
            "mobi", "azw3", "cbz", "cb7"
        ]

        private static func isDownloadable(_ url: URL) -> Bool {
            downloadExtensions.contains(url.pathExtension.lowercased())
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoadingChanged(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoadingChanged(false)
            parent.onTitleChanged(webView.title ?? "")
            parent.onURLChanged(webView.url)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoadingChanged(false)
            parent.onURLChanged(webView.url)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onLoadingChanged(false)
            parent.onURLChanged(webView.url)
        }
    }
}
#endif

struct SubscribeSourcesView: View {
    @ObservedObject private var store = SubscribeSourceStore.shared
    @ObservedObject private var articleState = SubscribeArticleStateStore.shared
    @Environment(\.appTheme) private var theme

    @State private var showImport = false
    @State private var importText = ""
    @State private var importURL = ""
    @State private var message: String?
    @State private var showFileImporter = false
    @State private var editing: SubscribeSource?
    @State private var webLoginSource: SubscribeSource?
    @State private var searchText = ""
    @State private var selectedGroup: String?
    @State private var sortMode: SubscribeSortMode = .customOrder
    @State private var health: [String: SourceHealth] = [:]
    @State private var checkingAll = false
    @State private var showDeleteFiltered = false
    @State private var refreshingSources = false
    @State private var didAutoRefresh = false
    @State private var pendingImportSources: [SubscribeSource] = []
    @State private var pendingImportMessage = ""
    @State private var showPendingImport = false

    private enum SubscribeSortMode: String, CaseIterable, Identifiable {
        case customOrder = "默认顺序"
        case name = "按名称"
        case updated = "最近更新"
        case enabledFirst = "已启用优先"

        var id: String { rawValue }
    }

    private enum SourceHealth {
        case checking
        case ok(String)
        case failed(String)
    }

    private var allGroups: [String] {
        var groups = Set<String>()
        for source in store.sources {
            for group in Self.splitGroups(source.sourceGroup) {
                groups.insert(group)
            }
        }
        return groups.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var filteredSources: [SubscribeSource] {
        var list = store.sources
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !keyword.isEmpty {
            list = list.filter { source in
                [
                    source.sourceName,
                    source.sourceUrl,
                    source.sourceGroup ?? "",
                    source.sourceComment ?? ""
                ].joined(separator: " ").lowercased().contains(keyword)
            }
        }
        if let selectedGroup {
            list = list.filter { Self.splitGroups($0.sourceGroup).contains(selectedGroup) }
        }
        switch sortMode {
        case .customOrder:
            list.sort {
                let lhs = $0.customOrder ?? 0
                let rhs = $1.customOrder ?? 0
                if lhs != rhs { return lhs < rhs }
                return $0.sourceName.localizedStandardCompare($1.sourceName) == .orderedAscending
            }
        case .name:
            list.sort { $0.sourceName.localizedStandardCompare($1.sourceName) == .orderedAscending }
        case .updated:
            list.sort {
                let lhs = $0.lastUpdateTime ?? 0
                let rhs = $1.lastUpdateTime ?? 0
                if lhs != rhs { return lhs > rhs }
                return $0.sourceName.localizedStandardCompare($1.sourceName) == .orderedAscending
            }
        case .enabledFirst:
            list.sort {
                let lhs = ($0.enabled ?? true) ? 0 : 1
                let rhs = ($1.enabled ?? true) ? 0 : 1
                if lhs != rhs { return lhs < rhs }
                return ($0.customOrder ?? 0) < ($1.customOrder ?? 0)
            }
        }
        return list
    }

    private static func splitGroups(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.components(separatedBy: CharacterSet(charactersIn: ",，、;； "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        List {
            if store.sources.isEmpty {
                Section {
                    Text("还没有订阅源。右上角可以粘贴 / 导入 Legado 的 rssSources.json。")
                        .font(.footnote)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .appThemedRows()
            }

            if !store.sources.isEmpty {
                Section {
                    HStack {
                        Text("显示 \(filteredSources.count) / 共 \(store.sources.count)")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                        Spacer()
                        Menu {
                            Button("全部分组") { selectedGroup = nil }
                            ForEach(allGroups, id: \.self) { group in
                                Button(group) { selectedGroup = group }
                            }
                        } label: {
                            Label(selectedGroup ?? "全部分组", systemImage: "folder")
                                .font(.caption)
                        }
                        Menu {
                            ForEach(SubscribeSortMode.allCases) { mode in
                                Button(mode.rawValue) { sortMode = mode }
                            }
                        } label: {
                            Label(sortMode.rawValue, systemImage: "arrow.up.arrow.down")
                                .font(.caption)
                        }
                    }

                    if !allGroups.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                groupChip("全部", value: nil)
                                ForEach(allGroups, id: \.self) { group in
                                    groupChip(group, value: group)
                                }
                            }
                        }
                    }

                    NavigationLink {
                        SubscribeFavoritesView()
                    } label: {
                        HStack {
                            Label("收藏文章", systemImage: "star")
                            Spacer()
                            Text("\(articleState.favorites().count)")
                                .foregroundColor(theme.palette.secondaryInk)
                        }
                        .font(.caption)
                    }

                    HStack(spacing: 12) {
                        Button {
                            Task { await checkAllSources() }
                        } label: {
                            Label(checkingAll ? "检测中…" : "检测全部", systemImage: "checkmark.shield")
                                .font(.caption)
                        }
                        .disabled(checkingAll || filteredSources.isEmpty)

                        Menu {
                            Button("刷新到期源") {
                                Task { await refreshSources(dueOnly: true, showMessage: true) }
                            }
                            Button("刷新全部") {
                                Task { await refreshSources(dueOnly: false, showMessage: true) }
                            }
                        } label: {
                            Label(refreshingSources ? "刷新中…" : "刷新", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .disabled(refreshingSources || filteredSources.isEmpty)

                        Spacer()

                        Menu {
                            Button("启用当前筛选") { setEnabled(true) }
                            Button("停用当前筛选") { setEnabled(false) }
                            Divider()
                            Button(role: .destructive) {
                                showDeleteFiltered = true
                            } label: {
                                Text("删除当前筛选（\(filteredSources.count)）")
                            }
                        } label: {
                            Label("批量操作", systemImage: "checklist")
                                .font(.caption)
                        }
                        .disabled(filteredSources.isEmpty)
                    }
                }
                .appThemedRows()
            }

            Section(header: Text("订阅源（\(store.sources.count)）")) {
                if !store.sources.isEmpty && filteredSources.isEmpty {
                    Text("没有匹配的订阅源")
                        .font(.footnote)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                ForEach(filteredSources) { source in
                    NavigationLink {
                        if source.isExternalDeepLink {
                            SubscribeExternalSourceView(source: source)
                        } else if source.usesDirectWebPage {
                            SubscribeSourceWebView(source: source)
                        } else {
                            SubscribeArticlesView(source: source)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            sourceIconView(source)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(source.sourceName.isEmpty ? source.sourceUrl : source.sourceName)
                                        .font(.system(size: 15, weight: .medium))
                                    if let typeLabel = sourceTypeLabel(source) {
                                        Text(typeLabel)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundColor(theme.palette.accent)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(theme.palette.accent.opacity(0.10), in: Capsule())
                                    }
                                    Spacer()
                                    if source.enabled == false {
                                        Text("已停用")
                                            .font(.caption2)
                                            .foregroundColor(theme.palette.secondaryInk)
                                    } else if let unread = articleState.unreadCount(sourceUrl: source.sourceUrl), unread > 0 {
                                        Text("未读 \(unread)")
                                            .font(.caption2)
                                            .foregroundColor(theme.palette.accent)
                                    }
                                }
                                Text(source.sourceUrl)
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.palette.secondaryInk)
                                    .lineLimit(1)
                                if let status = health[source.sourceUrl] {
                                    healthLabel(status)
                                }
                                refreshLabel(for: source)
                            }
                        }
                    }
                    .contextMenu {
                        Button {
                            editing = source
                        } label: {
                            Label("看 / 改源码", systemImage: "curlybraces")
                        }
                        Button {
                            store.toggle(sourceUrl: source.sourceUrl)
                        } label: {
                            Label(source.enabled == false ? "启用" : "停用", systemImage: "power")
                        }
                        Button {
                            Task { await checkSource(source) }
                        } label: {
                            Label("检测源", systemImage: "checkmark.shield")
                        }
                        if source.usesDirectWebPage || !(source.loginUrl ?? "").isEmpty {
                            Button {
                                webLoginSource = source
                            } label: {
                                Label("登录 / Cookie", systemImage: "person.badge.key")
                            }
                        }
                        Menu {
                            Button("关闭自动刷新") {
                                store.setRefreshInterval(0, for: source.sourceUrl)
                            }
                            ForEach([15, 30, 60, 120, 360], id: \.self) { minutes in
                                Button("每 \(minutes) 分钟") {
                                    store.setRefreshInterval(minutes, for: source.sourceUrl)
                                }
                            }
                        } label: {
                            Label("自动刷新", systemImage: "clock.arrow.circlepath")
                        }
                        Button(role: .destructive) {
                            store.remove(sourceUrl: source.sourceUrl)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .onDelete { indexSet in
                    let list = filteredSources
                    for idx in indexSet where idx < list.count {
                        store.remove(sourceUrl: list[idx].sourceUrl)
                    }
                }
            }
            .appThemedRows()
        }
        .appThemedList()
        .searchable(text: $searchText, prompt: "搜索源名 / 网址 / 分组")
        .task {
            guard !didAutoRefresh else { return }
            didAutoRefresh = true
            await refreshSources(dueOnly: true, showMessage: false)
        }
        .navigationTitle("订阅源")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImport = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
        }
        .alert(message ?? "", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) {}
        }
        .alert("删除筛选结果", isPresented: $showDeleteFiltered) {
            Button("取消", role: .cancel) {}
            Button("删除 \(filteredSources.count) 个", role: .destructive) {
                for source in filteredSources {
                    store.remove(sourceUrl: source.sourceUrl)
                }
            }
        } message: {
            Text("会删除当前筛选出的 \(filteredSources.count) 个订阅源。")
        }
        .alert("导入预览", isPresented: $showPendingImport) {
            Button("取消", role: .cancel) {}
            Button("导入 \(pendingImportSources.count) 个") {
                let result = store.merge(pendingImportSources)
                message = "导入完成：新增 \(result.added) 个，更新 \(result.updated) 个。"
            }
        } message: {
            Text(pendingImportMessage)
        }
        .sheet(isPresented: $showImport) {
            SubscribeImportSheet(
                importText: $importText,
                importURL: $importURL,
                onDone: { text in message = text },
                onPickFile: { showFileImporter = true }
            )
        }
        .sheet(item: $editing) { source in
            SubscribeSourceEditor(source: source) { updated in
                store.merge([updated])
            }
        }
        .sheet(item: $webLoginSource) { source in
            NavigationView {
                SubscribeSourceWebView(source: source)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { webLoginSource = nil }
                        }
                    }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json, .plainText]) { result in
            switch result {
            case .success(let url):
                let canAccess = url.startAccessingSecurityScopedResource()
                defer { if canAccess { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url),
                   let text = String(data: data, encoding: .utf8) {
                    preparePendingImport(text, label: url.lastPathComponent)
                } else {
                    message = "文件读不出来。"
                }
            case .failure(let error):
                message = "打开文件失败：\(error.localizedDescription)"
            }
        }
    }

    private func groupChip(_ title: String, value: String?) -> some View {
        let isSelected = selectedGroup == value
        return Button {
            selectedGroup = value
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? theme.palette.onAccent : theme.palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isSelected ? theme.palette.accent : theme.palette.elevated)
                )
                .overlay(
                    Capsule().stroke(isSelected ? theme.palette.accent : theme.palette.divider,
                                     lineWidth: theme.metrics.borderWidth)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func healthLabel(_ status: SourceHealth) -> some View {
        switch status {
        case .checking:
            Text("检测中…")
                .font(.caption2)
                .foregroundColor(theme.palette.secondaryInk)
        case .ok(let text):
            Text(text)
                .font(.caption2)
                .foregroundColor(theme.palette.success)
        case .failed(let text):
            Text(text)
                .font(.caption2)
                .foregroundColor(theme.palette.danger)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func refreshLabel(for source: SubscribeSource) -> some View {
        let minutes = store.refreshInterval(for: source.sourceUrl)
        if minutes > 0 || store.lastRefresh(for: source.sourceUrl) != nil {
            HStack(spacing: 8) {
                if minutes > 0 {
                    Text("每 \(minutes) 分钟")
                }
                if let last = store.lastRefresh(for: source.sourceUrl) {
                    Text("上次 \(Self.refreshFormatter.string(from: last))")
                }
            }
            .font(.system(size: 10))
            .foregroundColor(theme.palette.secondaryInk)
        }
    }

    private static let refreshFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private func setEnabled(_ enabled: Bool) {
        for source in filteredSources where (source.enabled ?? true) != enabled {
            store.toggle(sourceUrl: source.sourceUrl)
        }
    }

    @MainActor
    private func checkAllSources() async {
        checkingAll = true
        for source in filteredSources {
            await checkSource(source)
        }
        checkingAll = false
    }

    @MainActor
    private func checkSource(_ source: SubscribeSource) async {
        health[source.sourceUrl] = .checking
        if source.isExternalDeepLink {
            health[source.sourceUrl] = .ok("外部链接")
            return
        }
        if source.usesDirectWebPage, let url = URL(string: source.sourceUrl) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                health[source.sourceUrl] = (200..<400).contains(code)
                    ? .ok("网页 \(code)")
                    : .failed("HTTP \(code)")
            } catch {
                health[source.sourceUrl] = .failed(error.localizedDescription)
            }
            return
        }
        do {
            let page = try await SubscribeSourceService.fetchPage(source: source)
            if page.articles.isEmpty {
                health[source.sourceUrl] = .failed("没有条目")
            } else {
                health[source.sourceUrl] = .ok("\(page.articles.count) 条")
            }
        } catch {
            health[source.sourceUrl] = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func refreshSources(dueOnly: Bool, showMessage: Bool) async {
        guard !refreshingSources else { return }
        let targets = filteredSources.filter { !dueOnly || store.isRefreshDue($0) }
        guard !targets.isEmpty else {
            if showMessage { message = "当前没有到期需要刷新的订阅源。" }
            return
        }
        refreshingSources = true
        var refreshed = 0
        var failed = 0
        for source in targets {
            if source.isExternalDeepLink {
                store.markRefreshed(source.sourceUrl)
                health[source.sourceUrl] = .ok("外部链接")
                refreshed += 1
                continue
            }
            if source.usesDirectWebPage, let url = URL(string: source.sourceUrl) {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   let code = (response as? HTTPURLResponse)?.statusCode,
                   (200..<400).contains(code) {
                    store.markRefreshed(source.sourceUrl)
                    health[source.sourceUrl] = .ok("网页 \(code)")
                    refreshed += 1
                } else {
                    failed += 1
                }
                continue
            }
            do {
                let page = try await SubscribeSourceService.fetchPage(source: source)
                articleState.recordArticles(sourceUrl: source.sourceUrl, articles: page.articles)
                store.markRefreshed(source.sourceUrl)
                health[source.sourceUrl] = page.articles.isEmpty
                    ? .failed("没有条目") : .ok("\(page.articles.count) 条")
                refreshed += 1
            } catch {
                health[source.sourceUrl] = .failed(error.localizedDescription)
                failed += 1
            }
        }
        refreshingSources = false
        if showMessage {
            message = "刷新完成：成功 \(refreshed) 个，失败 \(failed) 个。"
        }
    }

    @ViewBuilder
    private func sourceIconView(_ source: SubscribeSource) -> some View {
        let iconURL = URL(string: source.sourceIcon ?? "")
        Group {
            if let iconURL {
                AsyncImage(url: iconURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        sourceIconPlaceholder
                    }
                }
            } else {
                sourceIconPlaceholder
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: max(6, theme.metrics.cornerRadius - 3), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: max(6, theme.metrics.cornerRadius - 3), style: .continuous)
                .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
        )
    }

    private var sourceIconPlaceholder: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(theme.palette.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.palette.elevated)
    }

    private func sourceTypeLabel(_ source: SubscribeSource) -> String? {
        if source.isExternalDeepLink { return "外部" }
        switch source.type {
        case 1: return "图片"
        case 2: return "视频"
        case 3: return "文件"
        default: return source.usesDirectWebPage ? "网页" : nil
        }
    }

    private func preparePendingImport(_ text: String, label: String) {
        guard let list = try? SubscribeSourceService.decodeSources(from: text), !list.isEmpty else {
            message = "没读到订阅源，检查是不是 rssSources.json 的格式。"
            return
        }
        let existing = Set(store.sources.map(\.sourceUrl))
        let updated = list.filter { existing.contains($0.sourceUrl) }
        let added = list.count - updated.count
        pendingImportSources = list
        pendingImportMessage = "\(label)\n共 \(list.count) 个：新增 \(added) 个，覆盖 \(updated.count) 个。"
        if !updated.isEmpty {
            let names = updated.prefix(5).map(\.sourceName).joined(separator: "、")
            pendingImportMessage += "\n将覆盖：\(names)\(updated.count > 5 ? " 等" : "")"
        }
        showPendingImport = true
    }
}

struct SubscribeImportSheet: View {
    @Binding var importText: String
    @Binding var importURL: String
    let onDone: (String) -> Void
    let onPickFile: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var isFetching = false
    @State private var previewSources: [SubscribeSource] = []
    @State private var previewMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("粘贴 JSON")) {
                    TextEditor(text: $importText)
                        .frame(height: 180)
                        .font(.system(.caption, design: .monospaced))
                    Button {
                        preparePreview(importText)
                    } label: {
                        Label("预览粘贴的内容", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .appThemedRows()

                Section(header: Text("从网址导入")) {
                    TextField("https://…/rssSources.json", text: $importURL)
                        .autocorrectionDisabled()
                    Button {
                        fetchRemote()
                    } label: {
                        HStack {
                            Label("下载并预览", systemImage: "arrow.down.circle")
                            Spacer()
                            if isFetching { ProgressView() }
                        }
                    }
                    .disabled(isFetching || importURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .appThemedRows()

                if let previewMessage {
                    Section(header: Text("导入预览")) {
                        Text(previewMessage)
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                        Button {
                            commitPreview()
                        } label: {
                            Label("确认导入 \(previewSources.count) 个", systemImage: "checkmark.circle")
                        }
                        .disabled(previewSources.isEmpty)
                    }
                    .appThemedRows()
                }

                Section {
                    Button {
                        onPickFile()
                    } label: {
                        Label("从文件导入", systemImage: "folder")
                    }
                } footer: {
                    Text("跟安卓版 Legado 的订阅源文件互通：数组或单个对象都认。")
                }
                .appThemedRows()
            }
            .appThemedList()
            .navigationTitle("导入订阅源")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !previewSources.isEmpty {
                        Button("导入 \(previewSources.count) 个") {
                            commitPreview()
                        }
                    }
                }
            }
        }
    }

    private func preparePreview(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            previewMessage = "没有内容。"
            previewSources = []
            return
        }
        guard let list = try? SubscribeSourceService.decodeSources(from: text), !list.isEmpty else {
            previewMessage = "解析失败，检查 JSON 格式。"
            previewSources = []
            return
        }
        let existingURLs = Set(SubscribeSourceStore.shared.sources.map(\.sourceUrl))
        let updated = list.filter { existingURLs.contains($0.sourceUrl) }
        let added = list.count - updated.count
        var message = "共 \(list.count) 个：新增 \(added) 个，覆盖 \(updated.count) 个。"
        if !updated.isEmpty {
            let names = updated.prefix(5).map(\.sourceName).joined(separator: "、")
            message += "\n将覆盖：\(names)\(updated.count > 5 ? " 等" : "")"
        }
        previewSources = list
        previewMessage = message
    }

    private func commitPreview() {
        guard !previewSources.isEmpty else { return }
        let result = SubscribeSourceStore.shared.merge(previewSources)
        onDone("导入完成：新增 \(result.added) 个，更新 \(result.updated) 个。")
        dismiss()
    }

    private func fetchRemote() {
        let url = importURL.trimmingCharacters(in: .whitespaces)
        guard let target = URL(string: url) else {
            onDone("网址不合法。")
            return
        }
        isFetching = true
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: target)
                let text = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run {
                    isFetching = false
                    importText = text
                    preparePreview(text)
                }
            } catch {
                await MainActor.run {
                    isFetching = false
                    onDone("下载失败：\(error.localizedDescription)")
                }
            }
        }
    }
}

struct SubscribeSourceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var raw: String
    @State private var error: String?
    private let original: SubscribeSource
    private let onSave: (SubscribeSource) -> Void

    init(source: SubscribeSource, onSave: @escaping (SubscribeSource) -> Void) {
        self.original = source
        self.onSave = onSave
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self._raw = State(initialValue: (try? encoder.encode(source)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("整段 JSON（保存时解析回写）")) {
                    TextEditor(text: $raw)
                        .frame(minHeight: 360)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                }
                .appThemedRows()
                if let error {
                    Section {
                        Text(error).font(.caption).foregroundColor(theme.palette.danger)
                    }
                    .appThemedRows()
                }
            }
            .appThemedList()
            .navigationTitle("订阅源源码")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let list = try? SubscribeSourceService.decodeSources(from: raw), let parsed = list.first else {
                            error = "JSON 解析失败，检查括号和引号。"
                            return
                        }
                        onSave(parsed)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct SubscribeArticlesView: View {
    let source: SubscribeSource
    @ObservedObject private var articleState = SubscribeArticleStateStore.shared
    @Environment(\.appTheme) private var theme

    @State private var articles: [SubscribeArticle] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var nextPage: String?
    @State private var errorText: String?
    @State private var selected: SubscribeArticle?
    @State private var searchText = ""
    @State private var categories: [(name: String, url: String)] = []
    @State private var selectedCategory = 0

    private var displayedArticles: [SubscribeArticle] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return articles }
        return articles.filter { article in
            [article.title, article.summary ?? "", article.date ?? ""]
                .joined(separator: " ")
                .lowercased()
                .contains(keyword)
        }
    }

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                        Text("正在抓取…").font(.caption).foregroundColor(theme.palette.secondaryInk)
                    }
                }
                .appThemedRows()
            }
            if let errorText {
                Section {
                    Text(errorText).font(.caption).foregroundColor(theme.palette.danger)
                }
                .appThemedRows()
            }
            Section {
                ForEach(displayedArticles) { article in
                    Button {
                        articleState.markRead(sourceUrl: source.sourceUrl, article: article)
                        selected = article
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            articleThumbnail(article)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    if !articleState.isRead(sourceUrl: source.sourceUrl, article: article) {
                                        Circle()
                                            .fill(theme.palette.accent)
                                            .frame(width: 6, height: 6)
                                    }
                                    Text(article.title)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(articleState.isRead(sourceUrl: source.sourceUrl, article: article)
                                                         ? theme.palette.secondaryInk : theme.palette.ink)
                                        .lineLimit(2)
                                }
                                if let date = article.date, !date.isEmpty {
                                    Text(date).font(.caption2).foregroundColor(theme.palette.secondaryInk)
                                }
                                if let summary = article.summary, !summary.isEmpty {
                                    Text(summary)
                                        .font(.caption2)
                                        .foregroundColor(theme.palette.secondaryInk)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            articleState.toggleFavorite(
                                sourceUrl: source.sourceUrl,
                                sourceName: source.sourceName,
                                article: article
                            )
                        } label: {
                            Label(
                                articleState.isFavorite(sourceUrl: source.sourceUrl, article: article) ? "取消收藏" : "收藏",
                                systemImage: articleState.isFavorite(sourceUrl: source.sourceUrl, article: article) ? "star.slash" : "star"
                            )
                        }
                        .tint(theme.palette.accent)

                        Button {
                            if articleState.isRead(sourceUrl: source.sourceUrl, article: article) {
                                articleState.markUnread(sourceUrl: source.sourceUrl, article: article)
                            } else {
                                articleState.markRead(sourceUrl: source.sourceUrl, article: article)
                            }
                        } label: {
                            Label(
                                articleState.isRead(sourceUrl: source.sourceUrl, article: article) ? "标未读" : "标已读",
                                systemImage: "envelope.badge"
                            )
                        }
                        .tint(theme.palette.secondaryInk)
                    }
                }
            } header: {
                Text(articleSectionTitle)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if categories.count > 1 {
                        Menu {
                            ForEach(Array(categories.enumerated()), id: \.offset) { index, item in
                                Button(item.name) {
                                    selectedCategory = index
                                    articles = []
                                    nextPage = nil
                                    Task { await load() }
                                }
                            }
                        } label: {
                            Label(
                                categories.indices.contains(selectedCategory)
                                    ? categories[selectedCategory].name : "分类",
                                systemImage: "list.bullet"
                            )
                            .font(.system(size: 13, weight: .medium))
                        }
                    }
                    if let nextPage, !nextPage.isEmpty {
                        Button {
                            Task { await loadMore(nextPage) }
                        } label: {
                            HStack(spacing: 6) {
                                if isLoadingMore { ProgressView().controlSize(.small) }
                                Text(isLoadingMore ? "正在加载下一页…" : "加载下一页")
                            }
                            .font(.system(size: 13, weight: .medium))
                        }
                        .disabled(isLoadingMore)
                    }
                    Text(source.sourceName.isEmpty ? source.sourceUrl : source.sourceName)
                }
            }
            .appThemedRows()
        }
        .appThemedList()
        .searchable(text: $searchText, prompt: "搜索文章标题 / 摘要")
        .navigationTitle(source.sourceName.isEmpty ? "订阅" : source.sourceName)
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("全部已读") {
                    articleState.markAllRead(sourceUrl: source.sourceUrl, articles: articles)
                }
                .disabled(articles.isEmpty)
            }
        }
        .sheet(item: $selected) { article in
            SubscribeArticleView(article: article, source: source)
        }
    }

    private var articleSectionTitle: String {
        guard !articles.isEmpty else { return "没有条目" }
        let unread = displayedArticles.filter {
            !articleState.isRead(sourceUrl: source.sourceUrl, article: $0)
        }.count
        let count = displayedArticles.count
        return unread > 0 ? "\(count) 条 · 未读 \(unread)" : "\(count) 条"
    }

    @ViewBuilder
    private func articleThumbnail(_ article: SubscribeArticle) -> some View {
        Group {
            if let url = URL(string: article.imageUrl ?? "") {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        articleThumbnailPlaceholder
                    }
                }
            } else {
                articleThumbnailPlaceholder
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
        )
    }

    private var articleThumbnailPlaceholder: some View {
        Image(systemName: "doc.text")
            .font(.system(size: 18))
            .foregroundColor(theme.palette.secondaryInk)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.palette.elevated)
    }

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            if categories.isEmpty, source.singleUrl == false {
                categories = await SubscribeSourceService.fetchSortUrls(source: source)
                if selectedCategory >= categories.count { selectedCategory = 0 }
            }
            let categoryURL = categories.indices.contains(selectedCategory)
                ? categories[selectedCategory].url : nil
            let page = try await SubscribeSourceService.fetchPage(source: source, pageUrl: categoryURL)
            articles = page.articles
            nextPage = page.nextPage
            articleState.recordArticles(sourceUrl: source.sourceUrl, articles: articles)
            SubscribeSourceStore.shared.markRefreshed(source.sourceUrl)
            LegadoLog.log("[订阅源] 抓取完成 \(articles.count) 条")
            if articles.isEmpty { errorText = "这条源没抓到条目：检查规则或地址。" }
        } catch {
            LegadoLog.log("[订阅源] 抓取失败 \(error.localizedDescription)")
            errorText = "抓取失败：\(error.localizedDescription)"
        }
        isLoading = false
    }

    private func loadMore(_ pageUrl: String) async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let page = try await SubscribeSourceService.fetchPage(source: source, pageUrl: pageUrl)
            let existing = Set(articles.map(\.id))
            articles.append(contentsOf: page.articles.filter { !existing.contains($0.id) })
            nextPage = page.nextPage
            articleState.recordArticles(sourceUrl: source.sourceUrl, articles: articles)
            LegadoLog.log("[订阅源] 下一页 \(page.articles.count) 条，累计 \(articles.count) 条")
        } catch {
            LegadoLog.log("[订阅源] 翻页失败 \(error.localizedDescription)")
            errorText = "翻页失败：\(error.localizedDescription)"
        }
        isLoadingMore = false
    }
}

struct SubscribeArticleView: View {
    let article: SubscribeArticle
    let source: SubscribeSource

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @ObservedObject private var articleState = SubscribeArticleStateStore.shared
    @State private var content = ""
    @State private var isLoading = true
    @State private var isFromCache = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let url = URL(string: article.imageUrl ?? "") {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            default:
                                EmptyView()
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    Text(article.title)
                        .font(.title3.bold())
                        .foregroundColor(theme.palette.ink)
                    if let date = article.date, !date.isEmpty {
                        Text(date).font(.caption).foregroundColor(theme.palette.secondaryInk)
                    }
                    if source.type == 2, let url = URL(string: article.link) {
                        Link(destination: url) {
                            Label("打开视频页面", systemImage: "play.rectangle")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.vertical, 6)
                        }
                    }
                    if isFromCache {
                        Text("离线缓存")
                            .font(.caption2)
                            .foregroundColor(theme.palette.accent)
                    }
                    if isLoading {
                        ProgressView().padding(.top, 20)
                    } else {
                        Text(content.isEmpty ? "没取到正文，点右上角去网页看。" : content)
                            .font(.system(size: 16))
                            .lineSpacing(6)
                            .foregroundColor(theme.palette.ink)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(AppThemeBackdrop())
            .appThemedPage()
            .navigationTitle("正文")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 14) {
                        Button {
                            articleState.toggleFavorite(
                                sourceUrl: source.sourceUrl,
                                sourceName: source.sourceName,
                                article: article
                            )
                        } label: {
                            Image(systemName: articleState.isFavorite(sourceUrl: source.sourceUrl, article: article)
                                  ? "star.fill" : "star")
                        }
                        if let url = URL(string: article.link) {
                            Link(destination: url) {
                                Image(systemName: "safari")
                            }
                            if #available(iOS 16.0, macOS 13.0, *) {
                                ShareLink(item: url) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                        }
                    }
                }
            }
            .task {
                articleState.markRead(sourceUrl: source.sourceUrl, article: article)
                if let cached = articleState.cachedContent(sourceUrl: source.sourceUrl, article: article) {
                    content = cached
                    isFromCache = true
                    isLoading = false
                }
                let fetched = (try? await SubscribeSourceService.fetchContent(article: article, source: source)) ?? ""
                if !fetched.isEmpty {
                    content = fetched
                    isFromCache = false
                    articleState.cacheContent(
                        sourceUrl: source.sourceUrl,
                        sourceName: source.sourceName,
                        article: article,
                        content: fetched
                    )
                }
                isLoading = false
            }
        }
    }
}

struct SubscribeFavoritesView: View {
    @ObservedObject private var articleState = SubscribeArticleStateStore.shared
    @ObservedObject private var sourceStore = SubscribeSourceStore.shared
    @Environment(\.appTheme) private var theme

    private var favorites: [CachedSubscribeArticle] {
        articleState.favorites()
    }

    var body: some View {
        List {
            if favorites.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "star")
                            .font(.system(size: 28))
                            .foregroundColor(theme.palette.secondaryInk)
                        Text("还没有收藏文章")
                            .font(theme.typography.body.weight(.semibold))
                            .foregroundColor(theme.palette.ink)
                        Text("在文章列表左滑，或正文右上角点星标。")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
                .appThemedRows()
            } else {
                Section(header: Text("收藏文章（\(favorites.count)）")) {
                    ForEach(favorites) { item in
                        NavigationLink {
                            SubscribeArticleView(article: item.article, source: source(for: item))
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                favoriteThumbnail(item)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(theme.palette.ink)
                                        .lineLimit(2)
                                    Text(item.sourceName.isEmpty ? item.sourceUrl : item.sourceName)
                                        .font(.caption2)
                                        .foregroundColor(theme.palette.accent)
                                    if let date = item.date, !date.isEmpty {
                                        Text(date).font(.caption2).foregroundColor(theme.palette.secondaryInk)
                                    }
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                articleState.toggleFavorite(
                                    sourceUrl: item.sourceUrl,
                                    sourceName: item.sourceName,
                                    article: item.article
                                )
                            } label: {
                                Label("取消收藏", systemImage: "star.slash")
                            }
                        }
                    }
                }
                .appThemedRows()
            }
        }
        .appThemedList()
        .navigationTitle("收藏文章")
    }

    private func source(for item: CachedSubscribeArticle) -> SubscribeSource {
        sourceStore.sources.first(where: { $0.sourceUrl == item.sourceUrl })
            ?? SubscribeSource(sourceUrl: item.sourceUrl, sourceName: item.sourceName, singleUrl: false)
    }

    @ViewBuilder
    private func favoriteThumbnail(_ item: CachedSubscribeArticle) -> some View {
        Group {
            if let url = URL(string: item.imageUrl ?? "") {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        favoritePlaceholder
                    }
                }
            } else {
                favoritePlaceholder
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
        )
    }

    private var favoritePlaceholder: some View {
        Image(systemName: "star")
            .font(.system(size: 16))
            .foregroundColor(theme.palette.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.palette.elevated)
    }
}

// MARK: - RSS 订阅
struct RSSFeedsView: View {
    @ObservedObject private var store = RSSStore.shared
    @Environment(\.appTheme) private var theme
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newURL = ""

    var body: some View {
        List {
            Section {
                TerminalPageHeader(code: "SOURCE / RSS", title: "RSS 订阅", detail: "公众号镜像 / 博客 / 新闻源")
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }
            .appThemedRows()

            Section {
                Button {
                    newName = ""; newURL = ""
                    showAdd = true
                } label: {
                    Label("添加订阅源", systemImage: "plus")
                }
            }
            .appThemedRows()
            Section(header: Text("订阅源")) {
                if store.sources.isEmpty {
                    Text("还没有订阅源。填 RSS / Atom 地址即可，比如公众号镜像、博客、新闻站点。")
                        .font(.footnote)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                ForEach(store.sources) { source in
                    NavigationLink(destination: RSSItemsView(source: source)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name.isEmpty ? source.url : source.name)
                                .font(.system(size: 15))
                            if !source.name.isEmpty {
                                Text(source.url).font(.system(size: 11)).foregroundColor(theme.palette.secondaryInk).lineLimit(1)
                            }
                        }
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet where i < store.sources.count { store.remove(store.sources[i]) }
                }
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle("订阅（RSS）")
        .alert("添加订阅源", isPresented: $showAdd) {
            TextField("名称（可留空）", text: $newName)
            TextField("RSS / Atom 地址", text: $newURL)
                .autocorrectionDisabled()
            Button("添加") { store.add(name: newName, url: newURL) }
            Button("取消", role: .cancel) {}
        }
    }
}

struct RSSItemsView: View {
    let source: RSSSource
    @Environment(\.appTheme) private var theme
    @State private var items: [RSSItem] = []
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        List {
            if let errorText {
                Text(errorText).font(.footnote).foregroundColor(theme.palette.danger)
                    .appThemedRows()
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 15, weight: .medium))
                    if !item.date.isEmpty {
                        Text(item.date).font(.system(size: 11)).foregroundColor(theme.palette.secondaryInk)
                    }
                    if !item.summary.isEmpty {
                        Text(item.summary).font(.system(size: 12)).foregroundColor(theme.palette.secondaryInk).lineLimit(3)
                    }
                    if !item.link.isEmpty {
                        Link("打开原文", destination: URL(string: item.link) ?? URL(string: "about:blank")!)
                            .font(.system(size: 12))
                    }
                }
                .padding(.vertical, 2)
                .appThemedRows()
            }
        }
        .overlay { if loading { ProgressView() } }
        .appThemedList()
        .navigationTitle(source.name.isEmpty ? "订阅" : source.name)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        errorText = nil
        do {
            items = try await RSSService.shared.fetchFeed(url: source.url, sourceName: source.name)
            AppLog.write("[RSS] 抓取完成 \(items.count) 条")
            if items.isEmpty { errorText = "没读到条目，确认地址是 RSS / Atom。" }
        } catch {
            AppLog.write("[RSS] 抓取失败 \(error.localizedDescription)")
            errorText = "拉取失败：" + error.localizedDescription
        }
        loading = false
    }
}

// MARK: - OPDS / Calibre
struct OPDSCatalogsView: View {
    @ObservedObject private var store = OPDSStore.shared
    @Environment(\.appTheme) private var theme
    @State private var showAdd = false
    @State private var name = ""
    @State private var url = ""
    @State private var user = ""
    @State private var pass = ""

    var body: some View {
        List {
            Section {
                TerminalPageHeader(code: "SOURCE / OPDS", title: "OPDS 书库", detail: "Calibre 与自建 OPDS")
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }
            .appThemedRows()

            Section {
                Button {
                    name = ""; url = ""; user = ""; pass = ""
                    showAdd = true
                } label: {
                    Label("添加书库", systemImage: "plus")
                }
            }
            .appThemedRows()
            Section(header: Text("OPDS / Calibre 书库")) {
                if store.catalogs.isEmpty {
                    Text("填 OPDS 地址即可，例如 Calibre-Web 的 /opds 或 Calibre 内容服务器的 /opds。")
                        .font(.footnote)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                ForEach(store.catalogs) { catalog in
                    NavigationLink(destination: OPDSBrowserView(catalog: catalog, path: catalog.url, title: catalog.name)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(catalog.name.isEmpty ? catalog.url : catalog.name).font(.system(size: 15))
                            if !catalog.name.isEmpty {
                                Text(catalog.url).font(.system(size: 11)).foregroundColor(theme.palette.secondaryInk).lineLimit(1)
                            }
                        }
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet where i < store.catalogs.count { store.remove(store.catalogs[i]) }
                }
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle("OPDS 书库")
        .alert("添加书库", isPresented: $showAdd) {
            TextField("名称（可留空）", text: $name)
            TextField("OPDS 地址", text: $url)
                .autocorrectionDisabled()
            TextField("用户名（可留空）", text: $user)
                .autocorrectionDisabled()
            SecureField("密码（可留空）", text: $pass)
            Button("添加") { store.add(name: name, url: url, username: user, password: pass) }
            Button("取消", role: .cancel) {}
        }
    }
}

struct OPDSBrowserView: View {
    let catalog: OPDSCatalog
    let path: String
    let title: String

    @Environment(\.appTheme) private var theme
    @State private var entries: [OPDSEntry] = []
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        List {
            if let message {
                Text(message).font(.footnote).foregroundColor(theme.palette.secondaryInk)
                    .appThemedRows()
            }
            ForEach(entries) { entry in
                if entry.isNavigation {
                    NavigationLink(destination: OPDSBrowserView(catalog: catalog, path: entry.href, title: entry.title)) {
                        entryRow(entry)
                    }
                    .appThemedRows()
                } else if let first = entry.acquisitions.first {
                    Button {
                        Task { await download(first.href, name: entry.title) }
                    } label: {
                        entryRow(entry)
                    }
                    .appThemedRows()
                } else {
                    entryRow(entry)
                        .appThemedRows()
                }
            }
        }
        .appThemedList()
        .overlay { if loading { ProgressView() } }
        .navigationTitle(title.isEmpty ? "书库" : title)
        .task { await load() }
        .refreshable { await load() }
    }

    private func entryRow(_ entry: OPDSEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title).font(.system(size: 15, weight: .medium))
            if !entry.author.isEmpty {
                Text(entry.author).font(.system(size: 11)).foregroundColor(theme.palette.secondaryInk)
            }
            if !entry.summary.isEmpty {
                Text(entry.summary).font(.system(size: 11)).foregroundColor(theme.palette.secondaryInk).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        loading = true
        message = nil
        do {
            let result = try await OPDSService.shared.fetch(path, username: catalog.username, password: catalog.password)
            entries = result.entries
            AppLog.write("[OPDS] 目录加载完成 \(entries.count) 条")
            if entries.isEmpty { message = "这个地址没返回条目。" }
        } catch {
            AppLog.write("[OPDS] 目录加载失败 \(error.localizedDescription)")
            message = "拉取失败：" + error.localizedDescription
        }
        loading = false
    }

    private func download(_ href: String, name: String) async {
        loading = true
        message = "正在下载 " + name + "…"
        do {
            let file = try await OPDSService.shared.download(href, username: catalog.username, password: catalog.password)
            _ = try BookStore.shared.importFile(from: file)
            AppLog.write("[OPDS] 下载并导入完成")
            message = "已加入书架：" + name
        } catch {
            AppLog.write("[OPDS] 下载失败 \(error.localizedDescription)")
            message = "下载失败：" + error.localizedDescription
        }
        loading = false
    }
}

// MARK: - 诊断日志

/// 极简应用日志：写在沙盒 Documents/AppLogs/app.log，最多保留 512KB。
/// 挂未捕获异常处理器，崩溃时留下一条日志。
enum AppLog {
    static let defaultMaxLines = 100

    /// 是否记录常规日志（崩溃标记不受它影响，永远写）
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "app_log_enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "app_log_enabled") }
    }

    /// 保留多少行，默认 100
    static var maxLines: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "app_log_max_lines")
            return value > 0 ? value : defaultMaxLines
        }
        set { UserDefaults.standard.set(max(20, newValue), forKey: "app_log_max_lines") }
    }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AppLogs", isDirectory: true).appendingPathComponent("app.log")
    }

    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let stacks = exception.callStackSymbols.prefix(14).joined(separator: " | ")
            AppLog.writeSync("💥 未捕获异常 \(exception.name.rawValue): \(exception.reason ?? "") || \(stacks)")
        }
        // Swift 运行时的 fatalError / 前提条件失败 / 野指针走的是信号，不走 NSException，
        // 所以要单独接一层：只写一行标记再交还给系统，保持原本的崩溃行为
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig, { received in
                let name = AppLog.signalName(received)
                AppLog.writeSync("💥 信号 \(name)——运行时崩溃，上一行日志就是最后的动作\n")
                signal(received, SIG_DFL)
                raise(received)
            })
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        // Core 层的日志出口接到这里：LegadoCore 不依赖 App 层，只能运行时注入
        LegadoLog.handler = { line in AppLog.write(line) }
        // 启动行属于常规日志，跟着开关走
        write("—— 启动 v\(version) (\(build)) ——")
    }

    /// 落盘前的隐私过滤。
    ///
    /// 规矩：日志只记「操作类型 / 序数 / 耗时 / 状态码 / 字节数 / 错误类型」，
    /// 不记搜索词、书名作者、章节标题、正文、URL 的 path 与 query、任何凭据、
    /// 设备名、绝对路径的兜底过滤，命中就整行不写。
    static func sanitize(_ line: String) -> String {
        let banned = [
            "password", "passwd", "secret", "apikey", "api_key", "appid", "app_id",
            "serial", "token", "authorization", "key=", "keyword=", "/users/", "/var/"
        ]
        let lowered = line.lowercased()
        if banned.contains(where: { lowered.contains($0) }) {
            return "[已过滤] 这一行命中隐私关键词，未写入"
        }
        return line
    }

    /// 信号处理里能安全调用的写盘方式（只有 open/write/close）
    static func writeSync(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(sanitize(line))\n"
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = text.withCString { Darwin.write(fd, $0, strlen($0)) }
        Darwin.close(fd)
    }

    static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGFPE: return "SIGFPE"
        default: return "SIG\(sig)"
        }
    }

    static func write(_ line: String) {
        guard isEnabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(sanitize(line))\n"
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: fileURL)
        }
        trimToLines()
    }

    /// 超过保留行数就从前面砍
    private static func trimToLines() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return }
        lines = Array(lines.suffix(maxLines))
        try? Data((lines.joined(separator: "\n")).utf8).write(to: fileURL)
    }

    static func read() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "（还没有日志）"
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// 日志查看：崩溃后进来复制一份发我就够定位了
struct LogViewerView: View {
    @Environment(\.appTheme) private var theme
    @State private var text = ""
    @State private var copied = false
    @State private var logEnabled = AppLog.isEnabled
    @State private var lineLimit = AppLog.maxLines

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("记录日志", isOn: $logEnabled)
                    .onChange(of: logEnabled) { newValue in
                        AppLog.isEnabled = newValue
                        load()
                    }
                Spacer()
                Stepper(value: $lineLimit, in: 20...2000, step: 20) {
                    Text("保留 \(lineLimit) 行")
                        .font(.caption)
                }
                .onChange(of: lineLimit) { newValue in
                    AppLog.maxLines = newValue
                    load()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            Divider()
            HStack(spacing: 12) {
                Button(copied ? "已复制" : "复制全部") {
                    #if os(iOS)
                    UIPasteboard.general.string = text
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    #endif
                    copied = true
                }
                if #available(iOS 16.0, macOS 13.0, *) {
                    ShareLink(item: AppLog.fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Button("刷新") { load() }
                Button("清空", role: .destructive) {
                    AppLog.clear()
                    load()
                }
                Spacer()
                Text("\(text.count) 字符")
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
            }
            .padding(12)
        }
        .background(theme.palette.background)
        .appThemedPage()
        .navigationTitle("诊断日志")
        .onAppear { load() }
    }

    private func load() {
        copied = false
        text = AppLog.read()
    }
}
