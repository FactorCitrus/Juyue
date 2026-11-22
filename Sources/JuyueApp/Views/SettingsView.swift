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
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(AVKit)
import AVKit
import AVFoundation
#endif
#if canImport(JuyueCore)
import JuyueCore
#endif

enum AppIconChoice: String, CaseIterable, Identifiable {
    case modern
    case orange
    case classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modern: return "黑猫红日（新）"
        case .orange: return "猫与橙"
        case .classic: return "像素猫（经典）"
        }
    }

    var subtitle: String {
        switch self {
        case .modern: return "当前默认图标"
        case .orange: return "上一版黑猫与番茄"
        case .classic: return "紫色像素风旧图标"
        }
    }

    var alternateIconName: String? {
        switch self {
        case .modern: return nil
        case .orange: return "AppIconOrange"
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
           let matched = AppIconChoice.allCases.first(where: { $0.alternateIconName == current }) {
            choice = matched
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

private struct SettingsAlerts {
    var restorePresented = false
    var clearCachePresented = false
}

private struct AppearanceModePicker: View {
    @Binding var selection: String

    private static let modes: [(id: String, title: String)] = [
        ("system", "跟随系统"),
        ("light", "浅色模式"),
        ("dark", "深色模式")
    ]

    var body: some View {
        Picker(selection: $selection) {
            ForEach(Self.modes, id: \.id) { mode in
                Text(mode.title).tag(mode.id)
            }
        } label: {
            Text("外观模式")
        }
        .pickerStyle(SegmentedPickerStyle())
    }
}

private struct SettingsTrailingRow<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        leading
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) { trailing }
    }
}

private struct ImportFileSummary: View {
    let fileName: String
    let sourceName: String
    let fileExtension: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fileName)
                .font(theme.typography.body.weight(.semibold))
                .foregroundColor(theme.palette.ink)
            Text(sourceName)
                .font(.caption2)
                .foregroundColor(theme.palette.secondaryInk)
            Text(fileExtension.isEmpty ? "未知格式" : fileExtension)
                .font(theme.typography.mono)
                .foregroundColor(theme.palette.accent)
        }
        .padding(.vertical, 4)
    }
}

public struct SettingsView: View {
    @ObservedObject var bookStore = BookStore.shared
    @ObservedObject var readerConfig = ReaderConfig.shared
    @ObservedObject var shelfConfig = BookshelfConfig.shared
    @StateObject private var shelfLogo = ShelfLogoStore.shared
    @StateObject private var appIcon = AppIconManager.shared
    @ObservedObject private var themeManager = AppThemeManager.shared
    @ObservedObject private var readingStats = ReadingStatsStore.shared
    @ObservedObject private var archiveStyle = ArchiveStyleStore.shared
    @ObservedObject private var archiveBadges = BadgeStore.shared
    @Environment(\.appTheme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PlayfulEffects.storageKey) private var playfulEffects: Bool = true

    @AppStorage("juyue_app_theme") private var appTheme: String = "system"
    /// 阅读时随着正文抓书评（段评 / 本章说）首页
    @AppStorage("reader_cache_reviews") private var cacheReviews: Bool = false

    @State private var alerts = SettingsAlerts()
    /// WebDAV 那行的小字：填了地址就算「已配置」，同步过才是「已同步」。
    /// 之前只看 lastSyncTime，所以填完地址回来还显示「未配置」。
    @State private var webDAVStatusText: String = "未配置"
    @State private var showAppIconOptions: Bool = false
    @State private var logoPhotoItem: Any?
    @State private var iconGroupExpanded = false
    @State private var titleGroupExpanded = true
    @State private var presentedBoard: SettingsBoard? = nil
    @State private var boardContentVisible = false
    @State private var heroSweep: CGFloat = 1.4
    @State private var livingPulse = false
    @State private var livingGear: Double = 0

    public init() {}

    private var badgeColorBinding: Binding<Color> {
        Binding(
            get: { shelfConfig.badgeColor },
            set: { shelfConfig.badgeColorHex = $0.hexString ?? shelfConfig.badgeColorHex }
        )
    }

    /// iPhone 两列；iPad（regular 宽度）三列，避免卡片被拉成整屏宽。
    private var boardColumns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
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
                            columns: boardColumns,
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
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
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
                // 只看地址会把默认服务器当成「填过了」，账号密码空着也叫已配置
                if !cfg.isConfigured {
                    webDAVStatusText = "未配置"
                } else {
                    webDAVStatusText = cfg.lastSyncTime != nil ? "已同步" : "已配置"
                }
                startLivingAnimations()
            }
            .onChange(of: appTheme) { newValue in
                AppLog.write("[设置] 外观模式 → \(newValue)")
            }
            .alert("重置书源", isPresented: $alerts.restorePresented) {
                Button("取消", role: .cancel) {}
                Button("确定重置", role: .destructive) {
                    AppLog.write("[设置] 重置书源")
                    bookStore.loadBundledSources(forceReset: true)
                }
            } message: {
                Text("确定要把书源重置为预装默认状态吗？自己导入的书源会被覆盖，重新导入即可。")
            }
            .alert("清理阅读缓存", isPresented: $alerts.clearCachePresented) {
                Button("取消", role: .cancel) {}
                Button("确定清理", role: .destructive) {
                    AppLog.write("[设置] 清理阅读缓存")
                    let count = BookContentService.shared.getTotalCacheCount()
                    BookContentService.shared.clearAllChapterCaches()
                    ReviewCache.clearAll()
                    URLCache.shared.removeAllCachedResponses()
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
            .stackNavigationStyle()
    }

    private var settingsHero: some View {
        Group {
        if theme.isClassTrial {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("SETTINGS / 橘阅")
                        .font(theme.typography.label)
                        .foregroundColor(theme.palette.accent)
                    Spacer()
                    Text("CLASS TRIAL / 05")
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.onInk.opacity(0.55))
                }

                Text("设置")
                    .font(.system(size: 40, weight: .black))
                    .foregroundColor(theme.palette.onInk)

                HStack(spacing: 6) {
                    Text("05 MODULES")
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.onAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.palette.accent)
                    Text("本地设置 · 即时生效 · v\(shortVersion)")
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.onInk.opacity(0.7))
                }

                HStack(spacing: 0) {
                    Rectangle()
                        .fill(theme.palette.accent)
                        .frame(height: 5)
                    Rectangle()
                        .fill(theme.palette.onInk.opacity(0.18))
                        .frame(height: 5)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.ink)
            .overlay(alignment: .trailing) {
                Text("判")
                    .font(.system(size: 96, weight: .black))
                    .foregroundColor(theme.palette.accent.opacity(0.16))
                    .rotationEffect(.degrees(-8))
                    .offset(x: -6, y: 10)
            }
            .clipped()
            .background(
                Rectangle()
                    .fill(theme.palette.accent)
                    .offset(x: 5, y: 5)
            )
        } else {
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
        }
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            GeometryReader { geo in
                Rectangle()
                    .fill(theme.palette.accent.opacity(0.5))
                    .frame(width: 2)
                    .offset(x: heroSweep * geo.size.width)
                    .opacity(heroSweep > 1.2 ? 0 : 1)
            }
            .allowsHitTesting(false)
        }
        .onTapGesture {
            guard PlayfulEffects.allowed(reduceMotion: reduceMotion) else { return }
            heroSweep = -0.02
            withAnimation(.easeOut(duration: 0.7)) { heroSweep = 1.1 }
            Haptics.tap(.medium)
        }
    }

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private func startLivingAnimations() {
        guard PlayfulEffects.allowed(reduceMotion: reduceMotion) else { return }
        withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
            livingPulse = true
        }
        withAnimation(.linear(duration: 10).repeatForever(autoreverses: false)) {
            livingGear = 360
        }
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
        .appThemePanel()
    }

    private var panelFill: Color {
        theme.palette.surface
    }

    private func boardTile(_ board: SettingsBoard, height: CGFloat = 146) -> some View {
        return Button {
            AppLog.write("[设置] 打开板块 \(board.title)")
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
                    boardLiveIcon(board)
                }
                Spacer(minLength: 0)
                Text(board.title)
                    .font(theme.isClassTrial ? .system(size: 21, weight: .black) : .headline)
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
            .appThemePanel()
            .overlay(alignment: .bottomTrailing) {
                Text(board.index)
                    .font(.system(size: theme.isClassTrial ? 54 : 38, weight: .black, design: .monospaced))
                    .foregroundColor(theme.isClassTrial
                        ? theme.palette.accent.opacity(0.14)
                        : theme.palette.ink.opacity(0.045))
                    .rotationEffect(.degrees(theme.isClassTrial ? -8 : 0))
                    .padding(8)
            }
        }
        .buttonStyle(PlayfulPressStyle(scale: 0.97))
    }

    /// 宫格右上角的小图标不是装饰：阅读环看今日时长，系统齿轮持续转动，
    /// 让设置首页一眼有活气。关掉趣味动效或系统减弱动态效果时保持静止。
    @ViewBuilder
    private func boardLiveIcon(_ board: SettingsBoard) -> some View {
        let animate = PlayfulEffects.allowed(reduceMotion: reduceMotion)

        switch board {
        case .read:
            let progress = min(1.0, max(0.02, Double(readingStats.todaySeconds) / 3600.0))
            ZStack {
                Circle()
                    .stroke(theme.palette.divider.opacity(0.7), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(theme.palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)

        case .display:
            HStack(spacing: 2) {
                Rectangle().fill(theme.palette.accent).frame(width: 5, height: 5)
                Rectangle().fill(theme.palette.ink.opacity(0.65)).frame(width: 5, height: 5)
                Rectangle().fill(theme.palette.divider).frame(width: 5, height: 5)
            }

        case .sources:
            Image(systemName: boardSymbol(board))
                .font(theme.typography.symbol)
                .foregroundColor(theme.palette.secondaryInk)

        case .data:
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(theme.palette.secondaryInk.opacity(0.7))
                        .frame(width: 3, height: animate && livingPulse ? CGFloat(6 + index * 3) : CGFloat(5 + (2 - index) * 2))
                }
            }
            .frame(height: 13, alignment: .bottom)

        case .system:
            Image(systemName: "gearshape")
                .font(theme.typography.symbol)
                .foregroundColor(theme.palette.secondaryInk)
                .rotationEffect(.degrees(animate ? livingGear : 0))
        }
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
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                    .onAppear {
                        AppLog.write("[设置] 板块内容已渲染 \(board.title)")
                    }
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
            return "\(themeManager.choice.title) / \(appearance)"
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
    ) -> AnyView {
        if theme.isClassTrial {
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(title)
                        .font(.system(size: 12, weight: .black))
                        .foregroundColor(theme.palette.onInk)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(theme.palette.ink)
                    Text(tag)
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.onAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(theme.palette.accent)
                    Rectangle()
                        .fill(theme.palette.ink)
                        .frame(maxWidth: .infinity, maxHeight: 2)
                }
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.palette.surface)
                .overlay(
                    Rectangle()
                        .stroke(theme.palette.ink, lineWidth: 2)
                )
                .overlay(alignment: .bottomTrailing) {
                    Rectangle()
                        .fill(theme.palette.accent)
                        .frame(width: 34, height: 5)
                }
            })
        }
        return AnyView(VStack(alignment: .leading, spacing: 10) {
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
        })
    }

    /// 主题选择行：左边一小块纸样，直接把背景、墨色和强调色摆出来。
    private func themeChoiceRow(_ choice: AppThemeChoice) -> some View {
        let preview = AppThemeManager.tokens(for: choice)
        return Button {
            themeManager.choice = choice
            AppLog.write("[设置] 界面主题 → \(choice.rawValue)")
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(preview.palette.background)
                    VStack(alignment: .leading, spacing: 3) {
                        Rectangle()
                            .fill(preview.palette.ink)
                            .frame(width: 24, height: 2)
                        Rectangle()
                            .fill(preview.palette.secondaryInk.opacity(0.7))
                            .frame(width: 30, height: 1)
                        Rectangle()
                            .fill(preview.palette.accent)
                            .frame(width: 14, height: 3)
                    }
                    .padding(.leading, 7)
                }
                .frame(width: 54, height: 38)
                .overlay(alignment: .bottom) {
                    if preview.isClassTrial {
                        HStack(spacing: 0) {
                            ForEach(0..<6, id: \.self) { index in
                                Rectangle()
                                    .fill(index % 2 == 0 ? preview.palette.ink : preview.palette.accent)
                                    .frame(width: 9, height: 6)
                            }
                        }
                    }
                }
                .overlay(
                    Rectangle()
                        .stroke(preview.isClassTrial ? preview.palette.ink : preview.palette.divider,
                                lineWidth: preview.isClassTrial ? 2 : 0.5)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                        .font(theme.typography.body)
                        .foregroundColor(theme.palette.ink)
                    Text(choice.subtitle)
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                }

                Spacer(minLength: 8)

                if themeManager.choice == choice {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.palette.accent)
                }
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(theme.palette.divider.opacity(0.55))
            .frame(height: 0.5)
            .padding(.leading, 56)
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: theme.isClassTrial ? .bold : .medium))
            .foregroundColor(theme.isClassTrial ? theme.palette.onInk : theme.palette.accent)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: theme.isClassTrial ? 0 : max(6, theme.metrics.cornerRadius - 3), style: .continuous)
                    .fill(theme.isClassTrial ? theme.palette.ink : theme.palette.elevated)
            )
            .overlay(alignment: .bottomTrailing) {
                if theme.isClassTrial {
                    Rectangle()
                        .fill(theme.palette.accent)
                        .frame(width: 7, height: 7)
                }
            }
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
    ) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 6) {
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
        .padding(.bottom, 13))
    }

    private func settingBlock<Content: View>(
        _ title: String? = nil,
        icon: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 9) {
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
        .padding(.vertical, 12))
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
                                .fill(isSelected
                                    ? theme.palette.accent
                                    : (theme.isClassTrial ? theme.palette.surface : theme.palette.elevated))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                                .stroke(theme.isClassTrial
                                    ? (isSelected ? theme.palette.accent : theme.palette.ink)
                                    : (isSelected ? theme.palette.accent : theme.palette.divider),
                                        lineWidth: theme.isClassTrial ? 2 : theme.metrics.borderWidth)
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
        }

        sectionCard("背景", tag: "SURFACE") {
            settingBlock("阅读底色", icon: "paintpalette") {
                chipPicker(
                    selection: $readerConfig.theme,
                    options: ReaderTheme.allCases.map { ($0, $0.rawValue) },
                    columns: 2
                )
                Text("阅读主题决定阅读页配色；在阅读页「界面 → 自定义背景与文字颜色」里可单独设定底色。")
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
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
                        .foregroundColor(readerConfig.pageTextColor)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(readerConfig.pageBackgroundColor)
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
            cardDivider
            settingLink(
                "徽章墙",
                icon: "rosette",
                value: "\(archiveBadges.unlockedCount) / \(BadgeStore.catalogue.count) 已解锁"
            ) {
                BadgeWallView()
            }
        }
    }

    @ViewBuilder
    private var displayBoard: some View {
        sectionCard("界面主题", tag: "THEME") {
            settingBlock("配色方案", icon: "paintpalette") {
                VStack(spacing: 0) {
                    ForEach(AppThemeChoice.allCases) { choice in
                        themeChoiceRow(choice)
                        if choice != AppThemeChoice.allCases.last {
                            Rectangle()
                                .fill(theme.palette.divider.opacity(0.55))
                                .frame(height: 0.5)
                        }
                    }
                }
            }
            cardDivider
            settingBlock("外观模式", icon: "circle.lefthalf.filled") {
                if theme.isClassTrial {
                    chipPicker(
                        selection: $appTheme,
                        options: [
                            ("system", "跟随系统"),
                            ("light", "浅色模式"),
                            ("dark", "深色模式")
                        ],
                        columns: 3
                    )
                } else {
                    AppearanceModePicker(selection: $appTheme)
                }
            }
        }

        sectionCard("应用图标", tag: "ICON") {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showAppIconOptions.toggle() }
            } label: {
                shelfGroupLabel(
                    "当前图标",
                    icon: "app.badge",
                    summary: appIcon.isSwitching ? "切换中…" : appIcon.choice.title,
                    expanded: showAppIconOptions
                )
            }
            .buttonStyle(.plain)

            if showAppIconOptions {
                VStack(spacing: 0) {
                    ForEach(AppIconChoice.allCases) { option in
                        Button {
                            appIcon.apply(option)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .font(theme.isClassTrial
                                            ? .system(size: 15, weight: .heavy)
                                            : theme.typography.body)
                                        .foregroundColor(theme.palette.ink)
                                    Text(option.subtitle)
                                        .font(.caption2)
                                        .foregroundColor(theme.palette.secondaryInk)
                                }
                                Spacer()
                                if appIcon.choice == option {
                                    Image(systemName: theme.isClassTrial
                                        ? "checkmark.square.fill"
                                        : "checkmark.circle.fill")
                                        .font(theme.isClassTrial
                                            ? .system(size: 18, weight: .bold)
                                            : .body)
                                        .foregroundColor(theme.palette.accent)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(appIcon.isSwitching)

                        if option != AppIconChoice.allCases.last {
                            Rectangle()
                                .fill(theme.palette.divider.opacity(0.55))
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                    }

                    Text("换完桌面图标会跟着变。没变的话，回一趟桌面，或者重启 App。")
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
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

        sectionCard("书架标题与图标", tag: "TITLE") {
            shelfTitlePreview
            cardDivider
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { iconGroupExpanded.toggle() }
            } label: {
                shelfGroupLabel("图标", icon: "photo", summary: "\(Int(shelfConfig.logoHeight)) pt", expanded: iconGroupExpanded)
            }
            .buttonStyle(.plain)

            if iconGroupExpanded {
                settingBlock("书架图标", icon: "photo") {
                    HStack(spacing: 14) {
                        #if os(iOS)
                        if #available(iOS 16.0, *) {
                            PhotosPicker(selection: Binding(
                                get: { logoPhotoItem as? PhotosPickerItem },
                                set: { newValue in
                                    logoPhotoItem = newValue
                                    guard let item = newValue else { return }
                                    Task {
                                        if let data = try? await item.loadTransferable(type: Data.self),
                                           shelfLogo.save(data) {
                                            await MainActor.run {
                                                AppLog.write("[设置] 书架图标已更换（相册）")
                                                logoPhotoItem = nil
                                            }
                                        }
                                    }
                                }
                            ), matching: .images) {
                                Text(ShelfLogoStorage.hasImage ? "更换图片" : "从相册选择")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(theme.palette.accent)
                            }
                        } else {
                            Button(ShelfLogoStorage.hasImage ? "更换图片" : "选择图片…") {
                                presentLogoPicker()
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.palette.accent)
                        }
                        #else
                        Button(ShelfLogoStorage.hasImage ? "更换图片" : "选择图片…") {
                            presentLogoPicker()
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.palette.accent)
                        #endif

                        if ShelfLogoStorage.hasImage {
                            Button("清除", role: .destructive) {
                                shelfLogo.clear()
                                AppLog.write("[设置] 清除自定义书架图标")
                            }
                            .font(.system(size: 13))
                            .foregroundColor(theme.palette.danger)
                        }
                        Spacer(minLength: 0)
                    }
                }
                cardDivider
                settingSlider(
                    "图标大小",
                    icon: "arrow.up.left.and.arrow.down.right",
                    value: "\(Int(shelfConfig.logoHeight)) pt",
                    $shelfConfig.logoHeight,
                    in: 32...160,
                    step: 1
                )
                cardDivider
                settingSlider(
                    "图标水平位置",
                    icon: "arrow.left.and.right",
                    value: "\(Int(shelfConfig.logoOffsetX)) pt",
                    $shelfConfig.logoOffsetX,
                    in: -80...80,
                    step: 1
                )
                cardDivider
                settingSlider(
                    "图标垂直位置",
                    icon: "arrow.up.and.down",
                    value: "\(Int(shelfConfig.logoOffsetY)) pt",
                    $shelfConfig.logoOffsetY,
                    in: -40...40,
                    step: 1
                )
            }

            cardDivider
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { titleGroupExpanded.toggle() }
            } label: {
                shelfGroupLabel(
                    "标题文字",
                    icon: "textformat",
                    summary: shelfConfig.titleVisible ? "显示" : "已隐藏",
                    expanded: titleGroupExpanded
                )
            }
            .buttonStyle(.plain)

            if titleGroupExpanded {
                settingBlock("标题文字", icon: "textformat") {
                    Toggle("显示标题文字", isOn: $shelfConfig.titleVisible)
                        .font(theme.typography.body)
                        .tint(theme.palette.accent)
                    TextField("我的书架", text: $shelfConfig.titleText)
                        .font(theme.typography.body)
                        .foregroundColor(theme.palette.ink)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!shelfConfig.titleVisible)
                        .opacity(shelfConfig.titleVisible ? 1 : 0.5)
                        .onSubmit {
                            AppLog.write("[设置] 书架标题已修改 长度=\(shelfConfig.titleText.count)")
                        }
                }
                cardDivider
                settingSlider(
                    "字号",
                    icon: "textformat.size",
                    value: "\(Int(shelfConfig.titleFontSize)) pt",
                    $shelfConfig.titleFontSize,
                    in: 14...75,
                    step: 1
                )
                cardDivider
                settingSlider(
                    "水平位置",
                    icon: "arrow.left.and.right",
                    value: "\(Int(shelfConfig.titleOffsetX)) pt",
                    $shelfConfig.titleOffsetX,
                    in: -120...120,
                    step: 1
                )
                cardDivider
                settingSlider(
                    "垂直位置",
                    icon: "arrow.up.and.down",
                    value: "\(Int(shelfConfig.titleOffsetY)) pt",
                    $shelfConfig.titleOffsetY,
                    in: -40...60,
                    step: 1
                )
                cardDivider
                settingBlock {
                    Button("恢复默认标题") {
                        shelfConfig.titleText = "我的书架"
                        shelfConfig.titleVisible = true
                        shelfConfig.titleFontSize = 30
                        shelfConfig.titleOffsetX = 0
                        shelfConfig.titleOffsetY = 0
                        AppLog.write("[设置] 恢复默认书架标题")
                    }
                    .font(.system(size: 13))
                    .foregroundColor(theme.palette.accent)
                }
            }
        }

        sectionCard("档案样式", tag: "ARCHIVE") {
            settingBlock("长按图标 / 今日阅读", icon: "doc.text.magnifyingglass") {
                chipPicker(
                    selection: $archiveStyle.style,
                    options: ArchiveStyle.allCases.map { ($0, $0.title) },
                    columns: 3
                )
            }
            cardDivider
            settingBlock {
                Text("长按书架图标会盖一枚章，并打开档案抽屉：体检 / 徽章 / 胶囊 / 主题。单击仍看今日阅读。")
                    .font(.system(size: 11))
                    .foregroundColor(theme.palette.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    private func presentLogoPicker() {
        SystemDocumentPicker.present(contentTypes: [.image]) { urls in
            guard let url = urls.first else { return }
            if let data = try? Data(contentsOf: url), shelfLogo.save(data) {
                AppLog.write("[设置] 书架图标已更换（文件）")
            }
        }
    }

    /// 书架标题实时预览：改字、字号、位置都按真实书架的比例立刻显示
    @ViewBuilder
    private var shelfTitlePreview: some View {
        if theme.isClassTrial {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 12) {
                    Group {
                        if let custom = shelfLogo.image {
                            #if canImport(UIKit)
                            Image(uiImage: custom)
                                .resizable()
                                .scaledToFit()
                            #else
                            Image(nsImage: custom)
                                .resizable()
                                .scaledToFit()
                            #endif
                        } else {
                            ClassTrialShelfMark(block: theme.markBlock, mark: theme.markLine, accent: theme.palette.accent)
                                .frame(width: shelfConfig.logoHeight * 0.82,
                                       height: shelfConfig.logoHeight * 0.82)
                        }
                    }
                    .frame(height: shelfConfig.logoHeight)
                    .offset(x: shelfConfig.logoOffsetX, y: shelfConfig.logoOffsetY)

                    if shelfConfig.titleVisible {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SHELF / FILE")
                                .font(theme.typography.label)
                                .foregroundColor(theme.palette.accent)
                            Text(shelfTitlePreviewText)
                                .font(.system(size: shelfConfig.titleFontSize, weight: .black))
                                .foregroundColor(theme.palette.ink)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.bottom, 6)
                                .overlay(alignment: .bottomLeading) {
                                    Rectangle()
                                        .fill(theme.palette.accent)
                                        .frame(height: 5)
                                }
                        }
                        .rotationEffect(.degrees(-1))
                        .offset(x: shelfConfig.titleOffsetX, y: shelfConfig.titleOffsetY)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 0) {
                    Rectangle()
                        .fill(theme.palette.ink)
                        .frame(height: 3)
                    Rectangle()
                        .fill(theme.palette.accent)
                        .frame(width: 46, height: 7)
                }
                .padding(.leading, 6)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 120, alignment: .bottomLeading)
            .background(theme.palette.surface)
            .overlay(
                Rectangle()
                    .stroke(theme.palette.ink, lineWidth: 2)
            )
            .overlay(alignment: .bottomTrailing) {
                Rectangle()
                    .fill(theme.palette.accent)
                    .frame(width: 34, height: 6)
            }
            .clipped()
            .background(
                Rectangle()
                    .fill(theme.palette.offsetShadow)
                    .offset(x: 4, y: 4)
            )
            .padding(.horizontal, 14)
            .padding(.top, 10)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 12) {
                    Group {
                        if let custom = shelfLogo.image {
                            #if canImport(UIKit)
                            Image(uiImage: custom)
                                .resizable()
                                .scaledToFit()
                            #else
                            Image(nsImage: custom)
                                .resizable()
                                .scaledToFit()
                            #endif
                        } else if AppEdition.isAppStoreClean {
                            ShelfEditionMark(ink: theme.palette.ink, accent: theme.palette.accent)
                        } else {
                            Image("ShelfMark")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(theme.palette.ink)
                        }
                    }
                    .frame(height: shelfConfig.logoHeight)
                    .offset(x: shelfConfig.logoOffsetX, y: shelfConfig.logoOffsetY)

                    if shelfConfig.titleVisible {
                        Text(shelfTitlePreviewText)
                            .font(.system(size: shelfConfig.titleFontSize, weight: .bold))
                            .foregroundColor(theme.palette.ink)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .offset(x: shelfConfig.titleOffsetX, y: shelfConfig.titleOffsetY)
                            .padding(.bottom, 4)
                    }

                    Spacer(minLength: 0)
                }

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
                .padding(.leading, 6)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 120, alignment: .bottomLeading)
            .background(
                LinearGradient(
                    colors: [theme.palette.elevated.opacity(0.9), theme.palette.surface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                    .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
            )
            .clipped()
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }

    private var shelfTitlePreviewText: String {
        let text = shelfConfig.titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "我的书架" : text
    }

    private func shelfGroupLabel(_ title: String, icon: String, summary: String, expanded: Bool) -> some View {
        HStack(spacing: 12) {
            rowIcon(icon)
            Text(title)
                .font(theme.typography.body)
                .foregroundColor(theme.palette.ink)
            Spacer(minLength: 8)
            Text(summary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.palette.secondaryInk)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.palette.secondaryInk)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
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
                alerts.restorePresented = true
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
            Button {
                alerts.clearCachePresented = true
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

        sectionCard("缓存", tag: "CACHE") {
            cacheChapterControl
            cardDivider
            Toggle(isOn: $cacheReviews) {
                HStack(spacing: 12) {
                    rowIcon("text.bubble")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("阅读时预取书评")
                            .font(theme.typography.body)
                            .foregroundColor(theme.palette.ink)
                        Text("段评和本章说随正文一起抓首页；下载时的书评范围在下载面板里选。")
                            .font(.system(size: 11))
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .toggleStyle(SwitchToggleStyle(tint: theme.palette.accent))
            .padding(.trailing, 14)
            .onChange(of: cacheReviews) { newValue in
                AppLog.write("[设置] 缓存书评 \(newValue ? "开" : "关")")
            }
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

    /// 缓存范围：章数可输入、可 ±10/±20 批量调；打开「下载全书」就不限章数。
    private var cacheChapterControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                rowIcon("internaldrive")
                VStack(alignment: .leading, spacing: 2) {
                    Text("默认缓存章节")
                        .font(theme.typography.body)
                        .foregroundColor(theme.palette.ink)
                    Text(readerConfig.cachedAllChapters
                         ? "下载面板默认选「全书」"
                         : "下载面板默认往后 \(readerConfig.cachedChapterCount) 章")
                        .font(.system(size: 11))
                        .foregroundColor(theme.palette.secondaryInk)
                }
                Spacer(minLength: 0)
            }
            if !readerConfig.cachedAllChapters {
                HStack(spacing: 8) {
                    cacheStepButton("-20", delta: -20)
                    cacheStepButton("-10", delta: -10)
                    TextField("", value: Binding(
                        get: { readerConfig.cachedChapterCount },
                        set: { readerConfig.cachedChapterCount = min(max($0, 1), 200) }
                    ), format: .number)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .multilineTextAlignment(.center)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.palette.ink)
                    .frame(width: 64, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.palette.elevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
                    )
                    cacheStepButton("+10", delta: 10)
                    cacheStepButton("+20", delta: 20)
                    Spacer(minLength: 0)
                }
                Text("点数字可直接输入，范围 1–200 章。")
                    .font(.system(size: 11))
                    .foregroundColor(theme.palette.secondaryInk)
            }
            Toggle(isOn: $readerConfig.cachedAllChapters) {
                HStack(spacing: 12) {
                    rowIcon("books.vertical")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下载全书")
                            .font(theme.typography.body)
                            .foregroundColor(theme.palette.ink)
                        Text("打开后下载缓存不再受章数上限限制，按目录总章数一次下完。")
                            .font(.system(size: 11))
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: theme.palette.accent))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func cacheStepButton(_ title: String, delta: Int) -> some View {
        Button {
            readerConfig.cachedChapterCount = min(max(readerConfig.cachedChapterCount + delta, 1), 200)
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.palette.accent)
                .frame(minWidth: 44, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.palette.accent.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
    }

    private var downloadStatusText: String {
        let running = ChapterDownloadManager.shared.jobs.filter { $0.isRunning && !$0.isPaused }.count
        return running > 0 ? "\(running) 个进行中" : "空闲"
    }

    @ViewBuilder
    private var systemBoard: some View {
        sectionCard("体验", tag: "MOTION") {
            Toggle(isOn: $playfulEffects) {
                HStack(spacing: 12) {
                    rowIcon("sparkles")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("趣味动效")
                            .font(theme.typography.body)
                            .foregroundColor(theme.palette.ink)
                        Text("按压回弹、触觉反馈、数字滚动与图标小动效；关掉后界面保持安静。")
                            .font(.system(size: 11))
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .toggleStyle(SwitchToggleStyle(tint: theme.palette.accent))
            .padding(.trailing, 14)
            .onChange(of: playfulEffects) { newValue in
                AppLog.write("[设置] 趣味动效 \(newValue ? "开" : "关")")
            }
        }

        sectionCard("朗读", tag: "TTS") {
            settingLink(
                "朗读引擎",
                icon: "speaker.wave.2",
                value: TTSourceSelection.displayName(in: HttpTTSStore.shared.sources),
                detail: "内置离线 · 系统语音 · 在线源"
            ) {
                // 内嵌进设置这条导航栈：音色、朗读参数、语音源都从这一页往下推，
                // 不再各开一套导航，也不再有「语音源再推回听书设置」的循环。
                TTSSettingsSheet(embedded: true)
            }
        }

        sectionCard("诊断", tag: "LOG") {
            settingLink("诊断日志", icon: "doc.text.magnifyingglass", value: "操作与崩溃") {
                LogViewerView()
            }
        }

        sectionCard("关于", tag: "ABOUT") {
            VStack(alignment: .leading, spacing: 4) {
                Text("橘阅")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(theme.palette.ink)
                Text("Juyue · 阅读 iOS")
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
            Link(destination: URL(string: "https://github.com/FactorCitrus/Juyue")!) {
                settingLabel("GitHub", icon: "link", value: "FactorCitrus/Juyue", detail: nil, chevron: true)
            }
            .buttonStyle(.plain)
        }

        Text("© 2026 FactorCitrus。橘阅的名称、图标与截图保留所有权利。")
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
            text += "\n只认 ttf / otf / ttc。iCloud 里的文件，先下到本机再选。"
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
    @ObservedObject private var store = ReplaceRuleStore.shared
    @Environment(\.appTheme) private var theme
    @State private var editing: ReplaceRule? = nil
    @State private var editingIsNew = false
    @State private var showImport = false
    @State private var importText = ""
    @State private var importMessage: String?

    /// 设置页只管全局规则；本书规则在阅读界面的「替换净化」里编辑
    private var rules: [ReplaceRule] { store.rules.filter(\.isGlobal) }

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
                        editingIsNew = true
                        editing = ReplaceRule(bookUrl: nil)
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
                if rules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 28))
                            .foregroundColor(theme.palette.secondaryInk)
                        Text("还没有替换规则")
                            .font(theme.typography.body.weight(.semibold))
                        Text("添一条规则，把广告、水印、站点名去掉。")
                            .font(theme.typography.mono)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }
                ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
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
                    .onTapGesture {
                        editingIsNew = false
                        editing = rule
                    }
                }
                .onDelete { indexSet in
                    let ids = indexSet.map { rules[$0].id }
                    store.rules.removeAll { ids.contains($0.id) }
                }
            }
            .appThemedRows()

            Section {
                Text("替换那栏留空，就是把匹配到的字直接删掉。正则走 NSRegularExpression 语法，$1 指第一个捕获组。")
                    .font(.footnote)
                    .foregroundColor(theme.palette.secondaryInk)
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle("替换净化")
        .sheet(item: $editing) { rule in
            ReplaceRuleEditor(rule: rule, isNew: editingIsNew) { saved in
                if let idx = store.rules.firstIndex(where: { $0.id == saved.id }) {
                    store.rules[idx] = saved
                } else {
                    store.rules.append(saved)
                }
            }
        }
        .sheet(isPresented: $showImport) { importSheet }
    }

    /// 导入面板：贴 JSON，或者从文件选（对齐安卓阅读导出的替换净化格式）
    private var importSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text("把替换规则的 JSON 贴进来，或者从文件里挑。安卓导出的那套键都认：name / pattern / replacement / isRegex / enabled。")
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
                    presentRulesFilePicker()
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
        }
            .stackNavigationStyle()
    }

    private func presentRulesFilePicker() {
        SystemDocumentPicker.present(contentTypes: [.json, .plainText, .item]) { urls in
            guard let url = urls.first else {
                importMessage = "选择文件失败"
                return
            }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                importText = text
                importRules(text)
            } else {
                importMessage = "读不了这个文件"
            }
        }
    }

    private func importRules(_ json: String) {
        guard let parsed = ReplacementRulesView.parseRules(json) else {
            importMessage = "解析失败：不是可用的替换净化 JSON"
            return
        }
        var added = 0
        for rule in parsed.rules {
            let duplicate = store.rules.contains {
                $0.pattern == rule.pattern && $0.replacement == rule.replacement && $0.isRegex == rule.isRegex
            }
            if !duplicate {
                store.rules.append(rule)
                added += 1
            }
        }
        var message = "导入 \(added) 条（跳过重复 \(parsed.rules.count - added) 条）"
        if parsed.skipped > 0 {
            message += "，跳过不支持规则 \(parsed.skipped) 条"
        }
        importMessage = message
        if added > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { showImport = false }
        }
    }

    struct ParsedRules {
        var rules: [ReplaceRule]
        /// @js 脚本和只作用于标题的规则这里执行不了，导入时丢掉
        var skipped: Int
    }

    /// 认安卓阅读的导出格式，也认本 App 自己存的键
    static func parseRules(_ json: String) -> ParsedRules? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var items: [Any] = []
        if let array = object as? [Any] {
            items = array
        } else if let dict = object as? [String: Any] {
            items = (dict["rules"] as? [Any]) ?? [dict]
        }

        var rules: [ReplaceRule] = []
        var skipped = 0
        for item in items {
            guard let dict = item as? [String: Any] else { continue }
            var pattern = (dict["pattern"] as? String) ?? ""
            var isRegex = (dict["isRegex"] as? Bool) ?? true
            if let rawRegex = dict["regex"] {
                if let text = rawRegex as? String, pattern.isEmpty { pattern = text }
                if let flag = rawRegex as? Bool { isRegex = flag }
            }
            guard !pattern.isEmpty else { continue }
            let replacement = (dict["replacement"] as? String) ?? ""
            // @js: 替换要由 JS 引擎逐匹配执行，当普通模板套用会把脚本源码灌进正文
            if replacement.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@js:") {
                skipped += 1
                continue
            }
            // scopeContent=false 的规则只作用于章节标题，不该进正文
            if let scopeContent = dict["scopeContent"] as? Bool, !scopeContent {
                skipped += 1
                continue
            }
            rules.append(ReplaceRule(
                name: (dict["name"] as? String) ?? "",
                pattern: pattern,
                replacement: replacement,
                isRegex: isRegex,
                enabled: (dict["enabled"] as? Bool) ?? true,
                bookUrl: nil
            ))
        }
        return rules.isEmpty && skipped == 0 ? nil : ParsedRules(rules: rules, skipped: skipped)
    }

    private func enabledBinding(_ rule: ReplaceRule) -> Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { value in
                if let idx = store.rules.firstIndex(where: { $0.id == rule.id }) {
                    store.rules[idx].enabled = value
                }
            }
        )
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
    @ObservedObject private var library = OfflineBookStore.shared
    @Environment(\.appTheme) private var theme
    @State private var alertText = ""
    @State private var alertVisible = false
    @State private var isEditing = false
    @State private var selection = Set<String>()

    var body: some View {
        List {
            Section {
                TerminalPageHeader(code: "DATA / DOWNLOAD", title: "下载管理", detail: "缓存队列与离线书库")
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }
            .appThemedRows()

            summaryStrip

            librarySection

            if !manager.jobs.isEmpty {
                Section {
                    ForEach(manager.jobs) { job in
                        jobRow(job)
                    }
                } header: {
                    HStack(spacing: 7) {
                        Rectangle()
                            .fill(theme.palette.accent)
                            .frame(width: 3, height: 11)
                        Text("进行中的任务")
                            .font(theme.typography.mono)
                            .foregroundColor(theme.palette.ink)
                        Spacer(minLength: 0)
                        Text("\(manager.jobs.count) 个")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                }
            }
        }
        .appThemedList()
        .navigationTitle("下载管理")
        .onAppear { library.refresh() }
        .onChange(of: manager.jobs.count) { _ in library.refresh() }
        .safeAreaInset(edge: .bottom) {
            if isEditing && !library.entries.isEmpty {
                HStack(spacing: 16) {
                    Button(allSelected ? "取消全选" : "全选") {
                        selection = allSelected ? [] : Set(library.entries.map(\.bookUrl))
                    }
                    .font(.system(size: 13))
                    Spacer()
                    Button("删除所选（\(selection.count)）") { deleteSelected() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(selection.isEmpty ? theme.palette.secondaryInk : theme.palette.danger)
                        .disabled(selection.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(theme.palette.surface)
            }
        }
        .alert(isPresented: $alertVisible) {
            Alert(title: Text(alertText))
        }
        .toolbar {
            if !library.entries.isEmpty {
                Button(isEditing ? "完成" : "选择") {
                    isEditing.toggle()
                    if !isEditing { selection.removeAll() }
                }
            }
            Button {
                importOfflineBook()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("导入离线书")
        }
    }

    private var summaryStrip: some View {
        Section {
            HStack(spacing: 0) {
                summaryCell("离线书", value: "\(library.entries.count)", unit: "本")
                summaryDivider
                summaryCell("占用", value: byteText(library.totalBytes), unit: "")
                summaryDivider
                summaryCell("进行中", value: "\(manager.jobs.filter(\.isRunning).count)", unit: "个")
            }
            .padding(.vertical, 11)
            .background(theme.palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous)
                    .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.cornerRadius, style: .continuous))
            .appThemedRows()
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12))
        }
    }

    private func summaryCell(_ title: String, value: String, unit: String) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10))
                        .foregroundColor(theme.palette.secondaryInk)
                }
            }
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(theme.palette.secondaryInk)
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(theme.palette.divider)
            .frame(width: theme.metrics.borderWidth, height: 26)
    }

    private func sectionLabel(_ title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 7) {
            Rectangle()
                .fill(theme.palette.accent)
                .frame(width: 3, height: 11)
            Text(title)
                .font(theme.typography.mono)
                .foregroundColor(theme.palette.ink)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.palette.secondaryInk)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var librarySection: some View {
        Section {
            if library.entries.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 30))
                        .foregroundColor(theme.palette.secondaryInk)
                    Text("离线书库还是空的")
                        .font(theme.typography.body.weight(.semibold))
                        .foregroundColor(theme.palette.ink)
                    Text("缓存全本，或者在书架上长按书籍「分享离线书」，都会收进这里。")
                        .font(theme.typography.mono)
                        .foregroundColor(theme.palette.secondaryInk)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .appThemedRows()
            } else {
                ForEach(library.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            if isEditing {
                                Image(systemName: selection.contains(entry.bookUrl) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundColor(selection.contains(entry.bookUrl) ? theme.palette.accent : theme.palette.secondaryInk)
                            }
                            Text(entry.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(theme.palette.ink)
                                .lineLimit(1)
                            if !entry.author.isEmpty {
                                Text(entry.author)
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.palette.secondaryInk)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(byteText(entry.bytes))
                                .font(.system(size: 11))
                                .foregroundColor(theme.palette.secondaryInk)
                        }
                        let cached = liveChapters(entry)
                        let ratio = entry.totalChapters > 0
                            ? min(1, Double(cached) / Double(entry.totalChapters))
                            : 0
                        HStack(spacing: 8) {
                            Text("已缓存 \(cached)/\(entry.totalChapters) 章 · 书评 \(liveReviews(entry)) 条")
                                .font(.system(size: 11))
                                .foregroundColor(theme.palette.secondaryInk)
                            Spacer(minLength: 8)
                            Capsule()
                                .fill(theme.palette.divider)
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(theme.palette.accent)
                                        .scaleEffect(x: ratio, anchor: .leading)
                                }
                                .frame(width: 64, height: 3)
                        }
                        HStack(spacing: 12) {
                            Text(shortDate(entry.updatedAt))
                                .font(.system(size: 11))
                                .foregroundColor(theme.palette.secondaryInk)
                            Spacer()
                            if !isEditing {
                                Button("分享") { share(entry) }
                                    .font(.system(size: 12))
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isEditing { toggleSelection(entry.bookUrl) }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !isEditing {
                            Button(role: .destructive) { deleteCache([entry]) } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if !isEditing {
                            Button { share(entry) } label: {
                                Label("分享", systemImage: "square.and.arrow.up")
                            }
                            .tint(theme.palette.accent)
                        }
                    }
                }
            }

            // 页脚在 List 里不吃 listRowBackground，会露出系统白底，这里当成普通行铺主题色
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                Text("离线包存在 Documents/OfflineBooks 下，书架长按书籍可以「分享离线书」。")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundColor(theme.palette.secondaryInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .appThemedRows()
            .listRowSeparator(.hidden)
        } header: {
            sectionLabel("离线书库", trailing: library.entries.isEmpty ? nil : "\(library.entries.count) 本 · \(byteText(library.totalBytes))")
        }
    }

    private func jobRow(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.bookName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(theme.palette.ink)
                    .lineLimit(1)
                Spacer()
                TerminalStatusPill(
                    text: statusText(job),
                    color: job.isCancelled ? theme.palette.danger : theme.palette.accent
                )
            }
            if job.phase == .reviews && job.isRunning {
                ProgressView()
            } else {
                ProgressView(value: job.progress)
            }
            HStack(spacing: 8) {
                if job.phase == .reviews {
                    Text(job.reviewTotal > 0
                         ? "书评 \(job.reviewsDone)/\(job.reviewTotal) 条 · \(job.reviewChapterDone)/\(job.reviewChapterTotal) 章"
                         : "书评已缓存 \(job.cachedReviews) 条")
                        .font(.system(size: 11))
                        .foregroundColor(theme.palette.secondaryInk)
                } else {
                    Text("\(job.finished)/\(job.total)"
                         + (job.skipped > 0 ? "，跳过 \(job.skipped)" : "")
                         + (job.failed > 0 ? "，失败 \(job.failed)" : ""))
                        .font(.system(size: 11))
                        .foregroundColor(theme.palette.secondaryInk)
                }
                if job.phase == .chapters && !job.currentChapter.isEmpty {
                    Text(job.currentChapter)
                        .font(.system(size: 11))
                        .foregroundColor(theme.palette.secondaryInk)
                        .lineLimit(1)
                }
                if let eta = etaText(job) {
                    Text(eta)
                        .font(.system(size: 11))
                        .foregroundColor(theme.palette.secondaryInk)
                }
                Text("\(job.concurrency) 路")
                    .font(.system(size: 11))
                    .foregroundColor(theme.palette.secondaryInk)
                Spacer()
                if job.isRunning || job.isPaused {
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
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if job.isRunning || job.isPaused {
                Button(role: .destructive) {
                    AppLog.write("[下载] 左滑取消任务 \(job.finished)/\(job.total)")
                    manager.cancel(job.id)
                } label: {
                    Label("取消", systemImage: "xmark.circle")
                }
            }
        }
    }

    private func statusText(_ job: DownloadJob) -> String {
        switch job.status {
        case .running: return job.phase == .reviews ? "缓存书评" : "下载中"
        case .paused: return "已暂停"
        case .cancelling: return "正在取消"
        case .cancelled: return "已取消"
        case .finished: return "已完成"
        }
    }

    private func etaText(_ job: DownloadJob) -> String? {
        guard job.isRunning, !job.isPaused else { return nil }
        let total = job.phase == .reviews ? job.reviewTotal : job.total
        let done = job.phase == .reviews ? job.reviewsDone : job.finished + job.failed
        let remaining = total - done
        guard remaining > 0, done > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(job.phaseStartedAt)
        guard elapsed > 1 else { return nil }
        let eta = elapsed / Double(done) * Double(remaining)
        guard eta.isFinite else { return nil }
        if eta < 60 { return "预计剩余 <1 分钟" }
        let minutes = Int((eta / 60).rounded())
        if minutes < 60 { return "预计剩余约 \(minutes) 分钟" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "预计剩余约 \(hours) 小时" : "预计剩余约 \(hours) 小时 \(rest) 分"
    }

    private func liveChapters(_ entry: OfflineBookEntry) -> Int {
        max(entry.cachedChapters, manager.liveCounts[entry.bookUrl]?.chapters ?? 0)
    }

    private func liveReviews(_ entry: OfflineBookEntry) -> Int {
        max(entry.reviewCount, manager.liveCounts[entry.bookUrl]?.reviews ?? 0)
    }

    private var allSelected: Bool {
        !library.entries.isEmpty && selection.count == library.entries.count
    }

    private func toggleSelection(_ bookUrl: String) {
        if selection.contains(bookUrl) {
            selection.remove(bookUrl)
        } else {
            selection.insert(bookUrl)
        }
    }

    private func deleteCache(_ entries: [OfflineBookEntry]) {
        guard !entries.isEmpty else { return }
        for entry in entries {
            AppLog.write("[离线书库] 删除缓存 \(entry.name)")
            library.removeCache(for: entry.bookUrl)
        }
        let text = entries.count == 1
            ? "已删除《\(entries[0].name)》的缓存"
            : "已删除 \(entries.count) 本的离线缓存"
        ScriptToastWindow.shared.show(text)
    }

    private func deleteSelected() {
        let targets = library.entries.filter { selection.contains($0.bookUrl) }
        guard !targets.isEmpty else { return }
        AppLog.write("[离线书库] 批量删除缓存 \(targets.count) 本：\(targets.map(\.name).joined(separator: "、"))")
        deleteCache(targets)
        selection.removeAll()
        isEditing = false
    }

    private func importOfflineBook() {
        let type = UTType(filenameExtension: OfflineBookShare.fileExtension) ?? .data
        SystemDocumentPicker.present(contentTypes: [type]) { urls in
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let manifest = try OfflineBookShare.unpack(at: url)
                _ = BookStore.shared.importOfflineBook(manifest.book, chapters: manifest.chapters)
                library.refresh()
                AppLog.write("[导入] 下载管理页导入离线书《\(manifest.book.name)》\(manifest.chapters.count) 章")
            } catch {
                alertText = "导入失败：\(error.localizedDescription)"
                alertVisible = true
            }
        }
    }

    private func share(_ entry: OfflineBookEntry) {
        let meta = library.meta(for: entry.bookUrl)
        let book = meta?.book ?? BookStore.shared.bookshelf.first { $0.bookUrl == entry.bookUrl }
        let chapters = meta?.chapters ?? BookStore.shared.getChapters(for: entry.bookUrl)
        guard let book, !chapters.isEmpty else {
            alertText = "这本书缺少目录，去书架上重新分享一次就能补上"
            alertVisible = true
            return
        }
        do {
            let url = try OfflineBookShare.export(book: book, chapters: chapters)
            presentShareSheet(url: url)
        } catch {
            alertText = "导出失败：\(error.localizedDescription)"
            alertVisible = true
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func shortDate(_ date: Date) -> String {
        guard date != .distantPast else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
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
        JuyueLog.log("[订阅源] 导入 新增=\(added) 更新=\(updated) 总计=\(sources.count)")
        return (added, updated)
    }

    func remove(sourceUrl: String) {
        sources.removeAll { $0.sourceUrl == sourceUrl }
        JuyueLog.log("[订阅源] 删除 剩余=\(sources.count)")
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
            Text("这个源走的是外部 App 的深链，应用里抓不到内容。")
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
    /// 下载时建的临时目录；导入页关闭后整个删掉。
    var workingDirectory: URL?

    func cleanup() {
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

enum ImportDownloadError: LocalizedError {
    case invalidResponse
    case badStatus(Int)
    case notText
    case unsupportedLink

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器没有返回文件"
        case .badStatus(let code): return "服务器返回 HTTP \(code)，链接可能已失效"
        case .notText: return "返回内容不是 UTF-8 文本"
        case .unsupportedLink: return "暂不支持这个链接"
        }
    }
}

/// 网页和文章正文共用：带 WebView Cookie / 当前页 Referer 下载到临时目录。
enum ImportDownloader {
    static func download(
        url: URL,
        referer: URL?,
        cookies: [HTTPCookie] = [],
        displayName: String,
        requestWithoutUA: Bool = false
    ) async throws -> DownloadedImportFile {
        let (data, response) = try await URLSession.shared.data(
            for: makeRequest(url: url, referer: referer, cookies: cookies, sendUserAgent: !requestWithoutUA)
        )
        try validate(response)

        let http = response as? HTTPURLResponse
        let name = DownloadLinkClassifier.suggestedFileName(
            url: url,
            contentDisposition: http?.value(forHTTPHeaderField: "Content-Disposition"),
            mimeType: http?.mimeType ?? response.mimeType
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportDownload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name)
        try data.write(to: destination, options: .atomic)
        return DownloadedImportFile(
            url: destination,
            fileName: name,
            displayName: displayName,
            workingDirectory: directory
        )
    }

    static func loadText(from url: URL, referer: URL?, requestWithoutUA: Bool = false) async throws -> String {
        let (data, response) = try await URLSession.shared.data(
            for: makeRequest(url: url, referer: referer, cookies: [], sendUserAgent: !requestWithoutUA)
        )
        try validate(response)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportDownloadError.notText
        }
        return text
    }

    private static func makeRequest(
        url: URL,
        referer: URL?,
        cookies: [HTTPCookie],
        sendUserAgent: Bool
    ) -> URLRequest {
        var request = URLRequest(url: url)
        // 源站 404/522 或者连接挂起时，60 秒静默等待看起来就像点了没反应。
        request.timeoutInterval = 20
        if sendUserAgent {
            request.setValue(NetworkClient.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        var merged: [String: HTTPCookie] = [:]
        for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] {
            merged["\(cookie.name)|\(cookie.domain)|\(cookie.path)"] = cookie
        }
        for cookie in cookies {
            merged["\(cookie.name)|\(cookie.domain)|\(cookie.path)"] = cookie
        }
        for (key, value) in HTTPCookie.requestHeaderFields(with: Array(merged.values)) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ImportDownloadError.invalidResponse
        }
        guard (200..<400).contains(http.statusCode) else {
            throw ImportDownloadError.badStatus(http.statusCode)
        }
    }
}

/// 正文里的 legado:// / juyue://import/... 深链。
enum RemoteSourceImporter {
    @MainActor
    static func importSource(
        route: String,
        sourceURL: String,
        referer: URL?,
        requestWithoutUA: Bool = false
    ) async throws -> String {
        guard let url = URL(string: sourceURL) else {
            throw ImportDownloadError.unsupportedLink
        }
        let text = try await ImportDownloader.loadText(
            from: url,
            referer: referer,
            requestWithoutUA: requestWithoutUA
        )
        switch route {
        case "rssSource":
            let sources = try SubscribeSourceService.decodeSources(from: text)
            guard !sources.isEmpty else {
                throw NSError(domain: "Import", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "没读到订阅源"])
            }
            let merged = SubscribeSourceStore.shared.merge(sources)
            return "订阅源已更新：新增 \(merged.added) 个，更新 \(merged.updated) 个。"
        case "bookSource":
            let count = try BookStore.shared.importSources(json: text)
            return "书源已导入：新增或更新 \(count) 个。"
        case "httpTTS":
            // 内存里可能是空的，先读盘再合并，否则会把已有朗读引擎整个盖掉。
            let store = HttpTTSStore.shared
            try? store.load()
            let imported = try store.importJSON(text, replace: false)
            let names = imported.map(\.name).joined(separator: "、")
            return "朗读引擎已导入：\(names)"
        default:
            throw ImportDownloadError.unsupportedLink
        }
    }
}

/// 下载下来的文件先逐条识别，再让用户勾选要导入哪些类型。
struct DownloadedImportSheet: View {
    let sourceName: String
    let file: DownloadedImportFile
    let onFinish: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var scan: ImportScanResult?
    @State private var selectedKinds: Set<ImportAssetKind> = []
    @State private var message: String?
    @State private var importing = false
    /// 备份包一导入就会合并数据，先弹一次确认。
    @State private var showBackupConfirm = false
    @State private var didCleanup = false

    private var assetRows: [ImportAsset] {
        if let scan, !scan.orderedAssets.isEmpty {
            return scan.orderedAssets
        }
        // 认不出来时保留旧的“当书籍导入”兜底。
        return [ImportAsset(kind: .book, files: [file.url])]
    }

    private var importButtonTitle: String {
        importing ? "导入中…" : "导入所选（\(selectedKinds.count)）"
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    ImportFileSummary(
                        fileName: file.fileName,
                        sourceName: sourceName,
                        fileExtension: file.url.pathExtension.uppercased()
                    )
                }
                .appThemedRows()

                Section(header: Text("选择要导入的内容")) {
                    if scan == nil {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在识别文件…")
                                .font(.caption)
                                .foregroundColor(theme.palette.secondaryInk)
                        }
                    } else {
                        ForEach(assetRows) { asset in
                            Button {
                                toggle(asset.kind)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedKinds.contains(asset.kind)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedKinds.contains(asset.kind)
                                                         ? theme.palette.accent : theme.palette.secondaryInk)
                                    Image(systemName: asset.kind.symbol)
                                        .foregroundColor(theme.palette.accent)
                                        .frame(width: 24)
                                    Text(asset.kind.title)
                                        .foregroundColor(theme.palette.ink)
                                    Spacer()
                                    if asset.isApproximate {
                                        Text("按行识别")
                                            .font(.caption2)
                                            .foregroundColor(theme.palette.secondaryInk)
                                    } else {
                                        Text("\(asset.count) 个")
                                            .font(theme.typography.mono)
                                            .foregroundColor(theme.palette.secondaryInk)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                            .disabled(importing)
                        }

                        Button("全选") {
                            selectedKinds = Set(assetRows.map(\.kind))
                        }
                        .font(.caption)
                        .disabled(importing)
                    }

                    if let scan, !scan.notes.isEmpty {
                        ForEach(scan.notes, id: \.self) { note in
                            Text(note)
                                .font(.caption2)
                                .foregroundColor(theme.palette.warning)
                        }
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
            .alert("恢复这个备份包？", isPresented: $showBackupConfirm) {
                Button("取消", role: .cancel) {}
                Button("恢复") {
                    performImport()
                }
            } message: {
                Text("备份里的书、书源和设置会合并进当前数据，已有内容不会被清空。")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(importButtonTitle) { beginImport() }
                        .disabled(importing || scan == nil || selectedKinds.isEmpty)
                }
            }
            .task { await prepare() }
            .onDisappear { cleanupIfNeeded() }
        }
            .stackNavigationStyle()
    }

    private func prepare() async {
        guard scan == nil else { return }
        let fileURL = file.url
        let result = await Task.detached(priority: .userInitiated) {
            ImportSniffer.scan(fileURL: fileURL)
        }.value
        scan = result
        // 备份包不默认勾选：带来源文件的 zip 不应该一点就恢复整个备份。
        let rows = result.orderedAssets
        let contentKinds = rows.map(\.kind).filter { $0 != .backup }
        if contentKinds.isEmpty, rows.contains(where: { $0.kind == .backup }) {
            selectedKinds = [.backup]
        } else {
            selectedKinds = Set(contentKinds.isEmpty ? [.book] : contentKinds)
        }
    }

    private func toggle(_ kind: ImportAssetKind) {
        guard !importing else { return }
        if selectedKinds.contains(kind) {
            selectedKinds.remove(kind)
        } else {
            selectedKinds.insert(kind)
        }
    }

    private func beginImport() {
        guard !importing, !selectedKinds.isEmpty else { return }
        if selectedKinds.contains(.backup) {
            showBackupConfirm = true
        } else {
            performImport()
        }
    }

    private func cleanupIfNeeded() {
        guard !didCleanup else { return }
        didCleanup = true
        if let directory = scan?.extractionDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        file.cleanup()
    }

    private func performImport() {
        guard let scan else { return }
        let kinds = selectedKinds
        importing = true
        message = nil
        Task { @MainActor in
            do {
                var parts: [String] = []
                if kinds.contains(.bookSource), let asset = scan.assets[.bookSource] {
                    let count = try BookStore.shared.importSources(json: jsonArray(asset.items))
                    parts.append("书源 \(count) 个")
                }
                if kinds.contains(.subscribeSource), let asset = scan.assets[.subscribeSource] {
                    let sources = try SubscribeSourceService.decodeSources(from: jsonArray(asset.items))
                    let merged = SubscribeSourceStore.shared.merge(sources)
                    parts.append("订阅源 新增 \(merged.added) / 更新 \(merged.updated)")
                }
                if kinds.contains(.purifier), let asset = scan.assets[.purifier] {
                    let rules = try purifierRules(from: asset)
                    var added = 0
                    for rule in rules where !ReplaceRuleStore.shared.rules.contains(where: {
                        $0.pattern == rule.pattern
                            && $0.replacement == rule.replacement
                            && $0.isRegex == rule.isRegex
                    }) {
                        ReplaceRuleStore.shared.rules.append(rule)
                        added += 1
                    }
                    parts.append("净化规则 \(added) 条")
                }
                if kinds.contains(.book), let asset = scan.assets[.book] {
                    var imported = 0
                    for url in asset.files where (try? BookStore.shared.importFile(from: url)) != nil {
                        imported += 1
                    }
                    parts.append("书籍 \(imported) 本")
                }
                if kinds.contains(.font), let asset = scan.assets[.font] {
                    var imported = 0
                    for url in asset.files where CustomFontService.shared.importFont(from: url) != nil {
                        imported += 1
                    }
                    parts.append("字体 \(imported) 个")
                }
                if kinds.contains(.backup) {
                    let restored = try WebDAVService.shared.restoreFromZip(fileUrl: file.url)
                    let counts = BookStore.shared.restoreFromWebDAV(
                        books: restored.books, sources: restored.sources, mode: .merge
                    )
                    var settingsNote = ""
                    if let data = WebDAVService.shared.extractSettingsJSON(fromZipFileUrl: file.url),
                       let payload = AppSettingsBackup.decode(data) {
                        settingsNote = "，设置：\(AppSettingsBackup.apply(payload, mode: .merge))"
                    }
                    parts.append("备份恢复：新增书籍 \(counts.booksAdded) 本，新增书源 \(counts.sourcesAdded) 个\(settingsNote)")
                }
                importing = false
                let result = parts.isEmpty ? "没有可导入的内容" : "导入完成：" + parts.joined(separator: "，")
                message = result
                onFinish(result)
            } catch {
                importing = false
                message = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    private func jsonArray(_ items: [Data]) -> String {
        let objects = items.compactMap { String(data: $0, encoding: .utf8) }
        return "[" + objects.joined(separator: ",") + "]"
    }

    private func textContent() throws -> String {
        guard let text = try? String(contentsOf: file.url, encoding: .utf8) else {
            throw NSError(domain: "Import", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "文件不是 UTF-8 文本"])
        }
        return text
    }

    private func purifierRules(from asset: ImportAsset) throws -> [ReplaceRule] {
        if !asset.items.isEmpty,
           let parsed = ReplacementRulesView.parseRules(jsonArray(asset.items)),
           !parsed.rules.isEmpty {
            return parsed.rules
        }
        return try purifierRulesFromText()
    }

    private func purifierRulesFromText() throws -> [ReplaceRule] {
        let text = try textContent()
        if let parsed = ReplacementRulesView.parseRules(text), !parsed.rules.isEmpty {
            return parsed.rules
        }
        var rules: [ReplaceRule] = []
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
                rules.append(ReplaceRule(name: "", pattern: pattern,
                                         replacement: replacement, isRegex: true, enabled: true,
                                         bookUrl: nil))
            }
        }
        guard !rules.isEmpty else {
            throw NSError(domain: "Import", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "没读到净化规则"])
        }
        return rules
    }
}

/// 网盘分享页：蓝奏云这类地址不是文件直链，要先在内置网页里跑脚本、
/// 用户点一下下载，再由 WKWebView 接管，下完直接进导入面板。
struct ImportWebPage: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

struct ImportWebSheet: View {
    let page: ImportWebPage
    let onFinish: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var webView: WKWebView
    @State private var isLoading = true
    @State private var title = ""
    @State private var currentURL: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var pendingImportFile: DownloadedImportFile?
    @State private var pendingImportLink: URL?
    @State private var statusMessage: String?

    init(page: ImportWebPage, onFinish: @escaping (String) -> Void) {
        self.page = page
        self.onFinish = onFinish
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        if #available(iOS 14.0, macOS 11.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = NetworkClient.defaultUserAgent
        webView.allowsBackForwardNavigationGestures = true
        _webView = State(initialValue: webView)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(theme.palette.accent)
                }

                SubscribeSourceWebViewBox(
                    webView: webView,
                    sourceName: page.title,
                    onLoadingChanged: { loading in
                        isLoading = loading
                        updateNavigationState()
                    },
                    onTitleChanged: { if !$0.isEmpty { title = $0 } },
                    onURLChanged: { url in
                        currentURL = url
                        updateNavigationState()
                    },
                    onJuyueURL: { pendingImportLink = $0 },
                    onExternalURL: openExternal,
                    onDownloadedFile: { file in
                        isLoading = false
                        pendingImportFile = file
                    },
                    onDownloadFailed: { message in
                        isLoading = false
                        statusMessage = "下载失败：\(message)"
                    }
                )

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
            .appThemedPage()
            .navigationTitle(title.isEmpty ? page.title : title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                if webView.url == nil {
                    isLoading = true
                    webView.load(URLRequest(url: page.url))
                }
            }
            .sheet(item: $pendingImportFile) { file in
                DownloadedImportSheet(sourceName: page.title, file: file) { result in
                    statusMessage = result
                    onFinish(result)
                }
            }
            .alert("下载", isPresented: Binding(
                get: { statusMessage != nil },
                set: { if !$0 { statusMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(statusMessage ?? "")
            }
            .confirmationDialog(
                pendingImportLink.flatMap(SourceDeepLinkParser.parse)?.title ?? "导入？",
                isPresented: Binding(
                    get: { pendingImportLink != nil },
                    set: { if !$0 { pendingImportLink = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("导入") {
                    if let url = pendingImportLink { confirmImport(url) }
                    pendingImportLink = nil
                }
                Button("取消", role: .cancel) { pendingImportLink = nil }
            } message: {
                Text(pendingImportLink?.absoluteString ?? "")
            }
        }
    }

    private func confirmImport(_ url: URL) {
        guard let link = SourceDeepLinkParser.parse(url) else {
            statusMessage = "暂不支持这个导入链接：\(url.absoluteString)"
            return
        }
        isLoading = true
        Task { @MainActor in
            do {
                if let route = link.route {
                    statusMessage = try await RemoteSourceImporter.importSource(
                        route: route,
                        sourceURL: link.sourceURL.absoluteString,
                        referer: page.url,
                        requestWithoutUA: link.requestWithoutUA
                    )
                } else {
                    pendingImportFile = try await ImportDownloader.download(
                        url: link.sourceURL,
                        referer: page.url,
                        displayName: page.title,
                        requestWithoutUA: link.requestWithoutUA
                    )
                }
            } catch {
                statusMessage = "导入失败：\(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    private func updateNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func openExternal(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}

/// `singleUrl` 订阅源在阅读里是发布页，不是文章列表。直接用内嵌网页打开，
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
    @State private var pendingImportLink: URL?

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
                    sourceName: source.sourceName,
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
                    onJuyueURL: handleJuyueURL,
                    onExternalURL: openExternal,
                    onDownloadedFile: { file in
                        isLoading = false
                        pendingImportFile = file
                    },
                    onDownloadFailed: { message in
                        isLoading = false
                        statusMessage = "下载失败：\(message)"
                    }
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
        .confirmationDialog(
            pendingImportLink.flatMap(SourceDeepLinkParser.parse)?.title ?? "导入？",
            isPresented: Binding(
                get: { pendingImportLink != nil },
                set: { if !$0 { pendingImportLink = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("导入") {
                if let url = pendingImportLink { confirmImport(url) }
                pendingImportLink = nil
            }
            Button("取消", role: .cancel) { pendingImportLink = nil }
        } message: {
            Text(pendingImportLink?.absoluteString ?? "")
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

    private func handleJuyueURL(_ url: URL) {
        guard SourceDeepLinkParser.parse(url) != nil else {
            statusMessage = "暂不支持这个导入链接：\(url.absoluteString)"
            return
        }
        pendingImportLink = url
    }

    private func confirmImport(_ url: URL) {
        guard let link = SourceDeepLinkParser.parse(url) else { return }
        let referer = URL(string: source.sourceUrl)
        isLoading = true
        Task { @MainActor in
            do {
                if let route = link.route {
                    statusMessage = try await RemoteSourceImporter.importSource(
                        route: route,
                        sourceURL: link.sourceURL.absoluteString,
                        referer: referer,
                        requestWithoutUA: link.requestWithoutUA
                    )
                } else {
                    pendingImportFile = try await ImportDownloader.download(
                        url: link.sourceURL,
                        referer: referer,
                        displayName: source.sourceName,
                        requestWithoutUA: link.requestWithoutUA
                    )
                }
            } catch {
                statusMessage = "导入失败：\(error.localizedDescription)"
            }
            isLoading = false
        }
    }


    private func openExternal(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}

#if os(iOS)
private struct SubscribeSourceWebViewBox: UIViewRepresentable {
    let webView: WKWebView
    let sourceName: String
    let onLoadingChanged: (Bool) -> Void
    let onTitleChanged: (String) -> Void
    let onURLChanged: (URL?) -> Void
    let onJuyueURL: (URL) -> Void
    let onExternalURL: (URL) -> Void
    let onDownloadedFile: (DownloadedImportFile) -> Void
    let onDownloadFailed: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        private let parent: SubscribeSourceWebViewBox
        private var activeDownloads: [WKDownload] = []
        private var destinations: [ObjectIdentifier: (name: String, file: URL, directory: URL)] = [:]

        init(parent: SubscribeSourceWebViewBox) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // target=_blank / window.open 打开的链接 WKWebView 默认不处理，
            // 不接管时下载按钮点了没反应。改在同一个 webView 里加载，交给导航代理判下载。
            guard let url = navigationAction.request.url else { return nil }
            if let target = DownloadLinkClassifier.opappTarget(url) {
                webView.load(URLRequest(url: target))
                return nil
            }
            if SourceDeepLinkParser.parse(url) != nil {
                parent.onJuyueURL(url)
                return nil
            }
            webView.load(navigationAction.request)
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            if let url = navigationAction.request.url {
                if let target = DownloadLinkClassifier.opappTarget(url) {
                    webView.load(URLRequest(url: target))
                    decisionHandler(.cancel, preferences)
                    return
                }
                let scheme = url.scheme?.lowercased() ?? ""
                if SourceDeepLinkParser.parse(url) != nil {
                    parent.onJuyueURL(url)
                    decisionHandler(.cancel, preferences)
                    return
                }
                if navigationAction.shouldPerformDownload {
                    decisionHandler(.download, preferences)
                    return
                }
                if !scheme.isEmpty && !["http", "https", "about", "data", "file", "blob"].contains(scheme) {
                    parent.onExternalURL(url)
                    decisionHandler(.cancel, preferences)
                    return
                }
                if (scheme == "http" || scheme == "https"), DownloadLinkClassifier.isDownloadable(url) {
                    decisionHandler(.download, preferences)
                    return
                }
            }
            decisionHandler(.allow, preferences)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.isForMainFrame {
                let http = navigationResponse.response as? HTTPURLResponse
                let disposition = http?.value(forHTTPHeaderField: "Content-Disposition")
                let mime = http?.mimeType ?? navigationResponse.response.mimeType
                if DownloadLinkClassifier.isAttachment(disposition)
                    || DownloadLinkClassifier.isBinaryMIME(mime)
                    || !navigationResponse.canShowMIMEType {
                    decisionHandler(.download)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            start(download)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            start(download)
        }

        private func start(_ download: WKDownload) {
            download.delegate = self
            activeDownloads.append(download)
            parent.onLoadingChanged(true)
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let http = response as? HTTPURLResponse
            let disposition = http?.value(forHTTPHeaderField: "Content-Disposition")
            let mime = http?.mimeType ?? response.mimeType
            var name = DownloadLinkClassifier.suggestedFileName(
                url: response.url ?? URL(fileURLWithPath: suggestedFilename),
                contentDisposition: disposition,
                mimeType: mime,
                fallback: suggestedFilename
            )
            if (name as NSString).pathExtension.isEmpty,
               let ext = DownloadLinkClassifier.fileExtension(forMIME: mime) {
                name += ".\(ext)"
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ImportDownload-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                completionHandler(nil)
                return
            }
            let destination = directory.appendingPathComponent(name)
            destinations[ObjectIdentifier(download)] = (name, destination, directory)
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            let id = ObjectIdentifier(download)
            activeDownloads.removeAll { $0 === download }
            guard let info = destinations.removeValue(forKey: id) else { return }
            let file = DownloadedImportFile(
                url: info.file,
                fileName: info.name,
                displayName: parent.sourceName,
                workingDirectory: info.directory
            )
            parent.onDownloadedFile(file)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            let id = ObjectIdentifier(download)
            activeDownloads.removeAll { $0 === download }
            if let info = destinations.removeValue(forKey: id) {
                try? FileManager.default.removeItem(at: info.directory)
            }
            parent.onDownloadFailed(error.localizedDescription)
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
    let sourceName: String
    let onLoadingChanged: (Bool) -> Void
    let onTitleChanged: (String) -> Void
    let onURLChanged: (URL?) -> Void
    let onJuyueURL: (URL) -> Void
    let onExternalURL: (URL) -> Void
    let onDownloadedFile: (DownloadedImportFile) -> Void
    let onDownloadFailed: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        private let parent: SubscribeSourceWebViewBox
        private var activeDownloads: [WKDownload] = []
        private var destinations: [ObjectIdentifier: (name: String, file: URL, directory: URL)] = [:]

        init(parent: SubscribeSourceWebViewBox) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // target=_blank / window.open 打开的链接 WKWebView 默认不处理，
            // 不接管时下载按钮点了没反应。改在同一个 webView 里加载，交给导航代理判下载。
            guard let url = navigationAction.request.url else { return nil }
            if let target = DownloadLinkClassifier.opappTarget(url) {
                webView.load(URLRequest(url: target))
                return nil
            }
            if SourceDeepLinkParser.parse(url) != nil {
                parent.onJuyueURL(url)
                return nil
            }
            webView.load(navigationAction.request)
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            if let url = navigationAction.request.url {
                if let target = DownloadLinkClassifier.opappTarget(url) {
                    webView.load(URLRequest(url: target))
                    decisionHandler(.cancel, preferences)
                    return
                }
                let scheme = url.scheme?.lowercased() ?? ""
                if SourceDeepLinkParser.parse(url) != nil {
                    parent.onJuyueURL(url)
                    decisionHandler(.cancel, preferences)
                    return
                }
                if navigationAction.shouldPerformDownload {
                    decisionHandler(.download, preferences)
                    return
                }
                if !scheme.isEmpty && !["http", "https", "about", "data", "file", "blob"].contains(scheme) {
                    parent.onExternalURL(url)
                    decisionHandler(.cancel, preferences)
                    return
                }
                if (scheme == "http" || scheme == "https"), DownloadLinkClassifier.isDownloadable(url) {
                    decisionHandler(.download, preferences)
                    return
                }
            }
            decisionHandler(.allow, preferences)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.isForMainFrame {
                let http = navigationResponse.response as? HTTPURLResponse
                let disposition = http?.value(forHTTPHeaderField: "Content-Disposition")
                let mime = http?.mimeType ?? navigationResponse.response.mimeType
                if DownloadLinkClassifier.isAttachment(disposition)
                    || DownloadLinkClassifier.isBinaryMIME(mime)
                    || !navigationResponse.canShowMIMEType {
                    decisionHandler(.download)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            start(download)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            start(download)
        }

        private func start(_ download: WKDownload) {
            download.delegate = self
            activeDownloads.append(download)
            parent.onLoadingChanged(true)
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
        ) {
            let http = response as? HTTPURLResponse
            let disposition = http?.value(forHTTPHeaderField: "Content-Disposition")
            let mime = http?.mimeType ?? response.mimeType
            var name = DownloadLinkClassifier.suggestedFileName(
                url: response.url ?? URL(fileURLWithPath: suggestedFilename),
                contentDisposition: disposition,
                mimeType: mime,
                fallback: suggestedFilename
            )
            if (name as NSString).pathExtension.isEmpty,
               let ext = DownloadLinkClassifier.fileExtension(forMIME: mime) {
                name += ".\(ext)"
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ImportDownload-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                completionHandler(nil)
                return
            }
            let destination = directory.appendingPathComponent(name)
            destinations[ObjectIdentifier(download)] = (name, destination, directory)
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            let id = ObjectIdentifier(download)
            activeDownloads.removeAll { $0 === download }
            guard let info = destinations.removeValue(forKey: id) else { return }
            let file = DownloadedImportFile(
                url: info.file,
                fileName: info.name,
                displayName: parent.sourceName,
                workingDirectory: info.directory
            )
            parent.onDownloadedFile(file)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            let id = ObjectIdentifier(download)
            activeDownloads.removeAll { $0 === download }
            if let info = destinations.removeValue(forKey: id) {
                try? FileManager.default.removeItem(at: info.directory)
            }
            parent.onDownloadFailed(error.localizedDescription)
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
                    Text("还没有订阅源。右上角可以粘贴 / 导入阅读的 rssSources.json。")
                        .font(.footnote)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .appThemedRows()
            }

            if !store.sources.isEmpty {
                Section {
                    SettingsTrailingRow {
                        Text("显示 \(filteredSources.count) / 共 \(store.sources.count)")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                    } trailing: {
                        HStack(spacing: 10) {
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
                        SettingsTrailingRow {
                            Label("收藏文章", systemImage: "star")
                        } trailing: {
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
                onPickFile: { presentSourceFilePicker() }
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
                .stackNavigationStyle()
        }
    }

    private func presentSourceFilePicker() {
        SystemDocumentPicker.present(contentTypes: [.json, .plainText]) { urls in
            guard let url = urls.first else {
                message = "文件读不出来。"
                return
            }
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                preparePendingImport(text, label: url.lastPathComponent)
            } else {
                message = "文件读不出来。"
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
                        SettingsTrailingRow {
                            Label("下载并预览", systemImage: "arrow.down.circle")
                        } trailing: {
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
                    Text("兼容安卓版阅读订阅源文件，数组与单个对象两种结构均可。")
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
            .stackNavigationStyle()
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
            .stackNavigationStyle()
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
                                return
                            }
                            articleState.markRead(sourceUrl: source.sourceUrl, article: article)
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
        // 源没配 ruleImage 时本来就取不到图，画个空占位框只会让人以为图片没加载。
        if let url = URL(string: article.imageUrl ?? "") {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
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
            JuyueLog.log("[订阅源] 抓取完成 \(articles.count) 条")
            if articles.isEmpty { errorText = "这条源没抓到条目：检查规则或地址。" }
        } catch {
            JuyueLog.log("[订阅源] 抓取失败 \(error.localizedDescription)")
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
            JuyueLog.log("[订阅源] 下一页 \(page.articles.count) 条，累计 \(articles.count) 条")
        } catch {
            JuyueLog.log("[订阅源] 翻页失败 \(error.localizedDescription)")
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
    @State private var contentBaseURL = ""
    @State private var detailHTML: String?
    @State private var showWeb = true
    @State private var mediaHeaders: [String: String] = [:]
    @State private var isLoading = true
    @State private var isFromCache = false
    @State private var isDownloading = false
    @State private var pendingImportFile: DownloadedImportFile?
    @State private var pendingWebPage: ImportWebPage?
    @State private var pendingImportLink: URL?
    @State private var pendingExternalLink: URL?
    @State private var statusMessage: String?

    private var blocks: [SubscribeArticleBlock] {
        SubscribeArticleBlock.parse(content)
    }

    private var linkBaseURL: URL? {
        if contentBaseURL.hasPrefix("http"), let url = URL(string: contentBaseURL) { return url }
        return URL(string: article.link)
    }

    private func attributedText(_ text: String) -> AttributedString {
        // 清理阶段把导入深链转成了 `[文字](地址)`；这里拆回可点文字，地址本身不上屏。
        let pattern = #"\[([^\]]+)\]\(([a-zA-Z][a-zA-Z0-9+.\-]*://[^)\s]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return plainAttributedText(text)
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return plainAttributedText(text) }

        var result = AttributedString()
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let gap = NSRange(location: cursor, length: match.range.location - cursor)
                result += plainAttributedText(ns.substring(with: gap))
            }
            let label = ns.substring(with: match.range(at: 1))
            let href = ns.substring(with: match.range(at: 2))
            var piece = AttributedString(label)
            if let url = URL(string: href) {
                piece.link = url
                piece.foregroundColor = theme.palette.accent
                piece.underlineStyle = .single
            }
            result += piece
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += plainAttributedText(ns.substring(from: cursor))
        }
        return result
    }

    private func plainAttributedText(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let base = linkBaseURL else { return attributed }
        for link in ArticleLinkExtractor.links(in: text, baseURL: base) {
            guard let stringRange = Range(link.range, in: text),
                  let indexRange = Range<AttributedString.Index>(stringRange, in: attributed) else {
                continue
            }
            attributed[indexRange].link = link.url
            attributed[indexRange].foregroundColor = theme.palette.accent
            attributed[indexRange].underlineStyle = .single
        }
        return attributed
    }

    var body: some View {
        NavigationView {
            Group {
                if showWeb, let html = detailHTML, !html.isEmpty {
                    #if canImport(UIKit)
                    SubscribeWebReader(
                        html: html,
                        url: URL(string: contentBaseURL.isEmpty ? article.link : contentBaseURL),
                        baseURL: source.loadWithBaseUrl == false
                            ? nil
                            : URL(string: contentBaseURL.isEmpty ? article.link : contentBaseURL),
                        headers: mediaHeaders,
                        enableJS: source.enableJs ?? true,
                        cacheFirst: source.cacheFirst ?? false,
                        allowInsecureTLS: source.allowInsecureTLS ?? false,
                        preloadJS: nil,
                        darkMode: theme.isDark,
                        onImportLink: { pendingImportLink = $0 },
                        onDownloadLink: { startDownload($0) },
                        onExternalLink: { pendingExternalLink = $0 }
                    )
                    #else
                    Text("网页阅读在 iOS 上可用")
                    #endif
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let cover = article.imageUrl, !cover.isEmpty {
                                SubscribeBodyImage(urlString: cover, headers: mediaHeaders)
                                    .frame(maxWidth: .infinity)
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
                            if isDownloading {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("正在下载…")
                                        .font(.caption2)
                                        .foregroundColor(theme.palette.secondaryInk)
                                }
                            }
                            if isLoading {
                                ProgressView().padding(.top, 20)
                            } else if content.isEmpty {
                                Text("没取到正文，点右上角去网页看。")
                                    .font(.system(size: 16))
                                    .lineSpacing(6)
                                    .foregroundColor(theme.palette.ink)
                            } else {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(blocks) { block in
                                        switch block.kind {
                                        case .text:
                                            Text(attributedText(block.value))
                                                .font(.system(size: 16))
                                                .lineSpacing(6)
                                                .foregroundColor(theme.palette.ink)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .environment(\.openURL, OpenURLAction { handleLink($0) })
                                        case .image:
                                            SubscribeBodyImage(urlString: block.value, headers: mediaHeaders)
                                        case .video:
                                            SubscribeBodyVideo(urlString: block.value, headers: mediaHeaders)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                    .background(AppThemeBackdrop())
                    .appThemedPage()
                }
            }
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
                        if detailHTML != nil {
                            Button {
                                showWeb.toggle()
                            } label: {
                                Image(systemName: showWeb ? "text.alignleft" : "safari")
                            }
                            .accessibilityLabel(showWeb ? "切换文字模式" : "切换网页模式")
                        }
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
            .alert("订阅", isPresented: Binding(
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
            .sheet(item: $pendingWebPage) { page in
                ImportWebSheet(page: page) { result in
                    statusMessage = result
                }
            }
            .confirmationDialog(
                importPrompt,
                isPresented: Binding(
                    get: { pendingImportLink != nil },
                    set: { if !$0 { pendingImportLink = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("导入") {
                    if let url = pendingImportLink { handleImportLink(url) }
                    pendingImportLink = nil
                }
                Button("取消", role: .cancel) { pendingImportLink = nil }
            } message: {
                Text(pendingImportLink?.absoluteString ?? "")
            }
            .alert("打开外部 App？", isPresented: Binding(
                get: { pendingExternalLink != nil },
                set: { if !$0 { pendingExternalLink = nil } }
            )) {
                Button("打开") {
                    if let url = pendingExternalLink { openExternalURL(url) }
                    pendingExternalLink = nil
                }
                Button("取消", role: .cancel) { pendingExternalLink = nil }
            } message: {
                Text(pendingExternalLink?.absoluteString ?? "")
            }
            .task {
                articleState.markRead(sourceUrl: source.sourceUrl, article: article)
                if let cached = articleState.cachedContent(sourceUrl: source.sourceUrl, article: article) {
                    content = cached
                    contentBaseURL = article.link
                    mediaHeaders = SubscribeSourceService.mediaRequestHeaders(
                        source: source, header: source.header, referer: article.link
                    )
                    isFromCache = true
                    isLoading = false
                }
                let detail = try? await SubscribeSourceService.fetchContentDetail(
                    article: article, source: source
                )
                if let detail {
                    if let html = detail.html, !html.isEmpty {
                        detailHTML = html
                        contentBaseURL = detail.baseURL.isEmpty ? article.link : detail.baseURL
                        mediaHeaders = detail.headers
                    }
                    if !detail.text.isEmpty {
                        content = detail.text
                        contentBaseURL = detail.baseURL.isEmpty ? article.link : detail.baseURL
                        mediaHeaders = detail.headers
                        isFromCache = false
                        articleState.cacheContent(
                            sourceUrl: source.sourceUrl,
                            sourceName: source.sourceName,
                            article: article,
                            content: detail.text
                        )
                    } else if mediaHeaders.isEmpty {
                        mediaHeaders = SubscribeSourceService.mediaRequestHeaders(
                            source: source, header: source.header, referer: article.link
                        )
                    }
                } else if mediaHeaders.isEmpty {
                    mediaHeaders = SubscribeSourceService.mediaRequestHeaders(
                        source: source, header: source.header, referer: article.link
                    )
                }
                isLoading = false
            }
        }
            .stackNavigationStyle()
    }

    private var importPrompt: String {
        guard let url = pendingImportLink else { return "导入" }
        return SourceDeepLinkParser.parse(url)?.title ?? "导入？"
    }

    private func handleLink(_ url: URL) -> OpenURLAction.Result {
        // 订阅源正文里的 `yuedu://opapp/<下载地址>`：iOS 没有外部下载器，直接内置下载。
        if let target = DownloadLinkClassifier.opappTarget(url) {
            startDownload(target)
            return .handled
        }
        switch DownloadLinkClassifier.schemeKind(url) {
        case .importDeepLink:
            guard SourceDeepLinkParser.parse(url) != nil else { return .systemAction }
            pendingImportLink = url
            return .handled
        case .data, .blob:
            statusMessage = "这种链接由网页脚本生成，暂时下载不了。"
            return .handled
        case .downloadable:
            startDownload(url)
            return .handled
        case .web:
            // 蓝奏云这类分享页得先跑脚本才给直链，放进内置网页里点下载
            if DownloadLinkClassifier.isLanzouCloud(url) {
                pendingWebPage = ImportWebPage(url: url, title: "下载")
                return .handled
            }
            return .systemAction
        case .externalDeepLink, .other:
            return .systemAction
        }
    }

    private func handleImportLink(_ url: URL) {
        guard let link = SourceDeepLinkParser.parse(url) else {
            statusMessage = "暂不支持这个导入链接：\(url.absoluteString)"
            return
        }
        guard let route = link.route else {
            // 类型认不出来（replaceRule / theme 等或未知路径）：下载后按内容判定。
            startDownload(link.sourceURL, requestWithoutUA: link.requestWithoutUA)
            return
        }
        Task { @MainActor in
            do {
                statusMessage = try await RemoteSourceImporter.importSource(
                    route: route,
                    sourceURL: link.sourceURL.absoluteString,
                    referer: URL(string: article.link),
                    requestWithoutUA: link.requestWithoutUA
                )
            } catch {
                statusMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    private func openExternalURL(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func startDownload(_ url: URL, requestWithoutUA: Bool = false) {
        guard !isDownloading else {
            statusMessage = "正在下载，请稍候…"
            return
        }
        isDownloading = true
        let referer = URL(string: article.link) ?? URL(string: source.sourceUrl)
        Task { @MainActor in
            do {
                let file = try await ImportDownloader.download(
                    url: url,
                    referer: referer,
                    displayName: source.sourceName,
                    requestWithoutUA: requestWithoutUA
                )
                isDownloading = false
                pendingImportFile = file
            } catch {
                isDownloading = false
                statusMessage = "下载失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 订阅正文的图片 / 视频

/// 正文里的图片、视频在 cleanHtml 阶段已经换成 `[image:url]`、`[video:url]`。
/// 这里按标记切块：文字照常走链接识别，媒体交给原生视图。
private struct SubscribeArticleBlock: Identifiable {
    enum Kind { case text, image, video }

    let id: Int
    let kind: Kind
    let value: String

    static func parse(_ text: String) -> [SubscribeArticleBlock] {
        guard !text.isEmpty else { return [] }
        let pattern = "\\[(image|video):([^\\]]+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [SubscribeArticleBlock(id: 0, kind: .text, value: text)]
        }
        let ns = text as NSString
        var result: [SubscribeArticleBlock] = []
        var cursor = 0
        var identifier = 0

        func appendText(_ chunk: String) {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            result.append(SubscribeArticleBlock(id: identifier, kind: .text, value: trimmed))
            identifier += 1
        }

        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                appendText(ns.substring(with: NSRange(
                    location: cursor, length: match.range.location - cursor
                )))
            }
            let kind = ns.substring(with: match.range(at: 1)).lowercased()
            let url = ns.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty {
                result.append(SubscribeArticleBlock(
                    id: identifier, kind: kind == "video" ? .video : .image, value: url
                ))
                identifier += 1
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            appendText(ns.substring(from: cursor))
        }
        return result
    }
}

/// 正文图片：按订阅源请求头去取，反盗链站点才给图。点击全屏，长按可存相册 / 浏览器打开。
private struct SubscribeBodyImage: View {
    let urlString: String
    let headers: [String: String]

    @Environment(\.appTheme) private var theme
    @State private var image: PlatformImage?
    @State private var failed = false
    @State private var showFullScreen = false

    private static let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 40
        return cache
    }()

    var body: some View {
        Group {
            if let image {
                imageView(image)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contextMenu { contextMenu(image) }
                    .onTapGesture { showFullScreen = true }
            } else if failed {
                Button {
                    Task { await load(force: true) }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 22))
                        Text("图片加载失败，点一下重试").font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(theme.palette.secondaryInk.opacity(0.08))
                    .cornerRadius(8)
                    .foregroundColor(theme.palette.secondaryInk)
                }
                .buttonStyle(.plain)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
        .task(id: headerSignature) { await load() }
        #if os(iOS)
        .fullScreenCover(isPresented: $showFullScreen) { viewer }
        #else
        .sheet(isPresented: $showFullScreen) { viewer }
        #endif
    }

    private var viewer: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                ScrollView([.vertical, .horizontal]) {
                    imageView(image).padding()
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button { showFullScreen = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func imageView(_ image: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
        #else
        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
        #endif
    }

    @ViewBuilder
    private func contextMenu(_ image: PlatformImage) -> some View {
        #if canImport(UIKit)
        Button {
            ImageExport.saveToPhotos(image)
        } label: {
            Label("保存到相册", systemImage: "square.and.arrow.down")
        }
        #else
        Button {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "image.png"
            guard panel.runModal() == .OK, let url = panel.url,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        } label: {
            Label("保存图片…", systemImage: "square.and.arrow.down")
        }
        #endif
        if let url = Self.makeURL(urlString) {
            Link(destination: url) {
                Label("在浏览器打开", systemImage: "safari")
            }
        }
    }

    private var headerSignature: String {
        headers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&")
    }

    private func load(force: Bool = false) async {
        if !force, let cached = Self.cache.object(forKey: urlString as NSString) {
            image = cached
            return
        }
        failed = false
        if urlString.lowercased().hasPrefix("data:") {
            if let decoded = Self.decodeDataURL(urlString) {
                image = decoded
                Self.cache.setObject(decoded, forKey: urlString as NSString)
            } else {
                failed = true
            }
            return
        }
        guard let url = Self.makeURL(urlString) else { failed = true; return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if request.value(forHTTPHeaderField: "Cookie") == nil {
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
                failed = true
                return
            }
            guard let decoded = PlatformImage(data: data) else { failed = true; return }
            image = decoded
            Self.cache.setObject(decoded, forKey: urlString as NSString)
        } catch {
            failed = true
        }
    }

    private static func makeURL(_ string: String) -> URL? {
        URL(string: string)
            ?? URL(string: string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
    }

    private static func decodeDataURL(_ string: String) -> PlatformImage? {
        guard let comma = string.firstIndex(of: ",") else { return nil }
        let meta = string[..<comma].lowercased()
        let payload = String(string[string.index(after: comma)...])
        let data: Data?
        if meta.contains("base64") {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8)
        }
        guard let data else { return nil }
        return PlatformImage(data: data)
    }
}

/// 正文视频：HLS / MP4 直接 AVPlayer 播，Referer 和 Cookie 一起带上。
private struct SubscribeBodyVideo: View {
    let urlString: String
    let headers: [String: String]

    @Environment(\.appTheme) private var theme
    @State private var player: AVPlayer?
    @State private var builtSignature = ""

    private var headerSignature: String {
        headers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if isPlayable {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 24))
                    Text("这个格式要用浏览器播放").font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(theme.palette.secondaryInk.opacity(0.08))
                .cornerRadius(8)
                .foregroundColor(theme.palette.secondaryInk)
            }
            if let url = remoteURL {
                Link(destination: url) {
                    Label("在浏览器打开", systemImage: "safari")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
        }
        .task(id: headerSignature) { setup() }
        .onDisappear { player?.pause() }
    }

    private var remoteURL: URL? {
        URL(string: urlString)
            ?? URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
    }

    private var isPlayable: Bool {
        guard let url = remoteURL else { return false }
        let ext = url.pathExtension.lowercased()
        if ["m3u8", "mp4", "m4v", "mov"].contains(ext) { return true }
        if urlString.lowercased().contains(".m3u8") { return true }
        // 没扩展名的多是流地址，交给 AVPlayer 试一次
        return ext.isEmpty
    }

    private func setup() {
        guard isPlayable, let url = remoteURL else { return }
        let signature = headerSignature
        if player != nil, builtSignature == signature { return }
        var options: [String: Any] = [:]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        if !cookies.isEmpty {
            options["AVURLAssetHTTPCookiesKey"] = cookies
        }
        let asset = AVURLAsset(url: url, options: options.isEmpty ? nil : options)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        builtSignature = signature
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
                        Text("文章列表里左滑，或者点正文右上角那颗星。")
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
        if let url = URL(string: item.imageUrl ?? "") {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
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
                    Text("填写 OPDS 地址，例如 Calibre-Web 的 /opds，或 Calibre 内容服务器的 /opds。")
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
    /// 单个文件上限，按字节算。行数没有意义：一行响应摘要能顶十几行。
    static let defaultMaxKilobytes = 64

    /// 是否记录常规日志（崩溃标记不受它影响，永远写）
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "app_log_enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "app_log_enabled") }
    }

    static var maxKilobytes: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "app_log_max_kb")
            if value >= 8 { return min(2048, value) }
            // 旧版本按行数设置，迁移成字节：一行按 200 字节估
            let legacyLines = UserDefaults.standard.integer(forKey: "app_log_max_lines")
            if legacyLines > 0 { return min(2048, max(8, legacyLines * 200 / 1024)) }
            return defaultMaxKilobytes
        }
        set { UserDefaults.standard.set(min(2048, max(8, newValue)), forKey: "app_log_max_kb") }
    }

    static var directoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppLogs", isDirectory: true)
    }

    static var fileURL: URL { directoryURL.appendingPathComponent("app.log") }

    /// 崩溃记录单独一份，永不裁剪。跟运行日志放一起的话，用户崩溃后再点两下，
    /// 崩溃标记会被 trim 从头砍掉，而那正是唯一想看的行。
    static var crashFileURL: URL { directoryURL.appendingPathComponent("crash.log") }

    // 写盘全在这个串行队列上做：调用者可能是任意线程的 async 任务，
    // 以前直接在调用线程开句柄，两章并发时行会交错。
    private static let queue = DispatchQueue(label: "com.factorcitrus.juyue.applog", qos: .utility)
    private static let queueKey = DispatchSpecificKey<Void>()
    private static var pending: [String] = []
    private static var flushScheduled = false
    /// 攒够这么多行就先落一次
    private static let flushBatch = 16
    private static let flushDelay: TimeInterval = 0.25

    static func install() {
        queue.setSpecific(key: queueKey, value: ())

        NSSetUncaughtExceptionHandler { exception in
            let stacks = exception.callStackSymbols.prefix(14).joined(separator: " | ")
            AppLog.writeCrash("💥 未捕获异常 \(exception.name.rawValue): \(exception.reason ?? "") || \(stacks)")
        }
        // 信号处理里不能分配内存，提前把目录和路径准备好
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if crashPath == nil {
            crashPath = strdup(crashFileURL.path)
        }
        // Swift 运行时的 fatalError / 前提条件失败 / 野指针走的是信号，不走 NSException，
        // 所以要单独接一层：只写一行标记再交还给系统，保持原本的崩溃行为
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig, { received in
                AppLog.writeSignalCrash(received)
                signal(received, SIG_DFL)
                raise(received)
            })
        }
        // 进后台 / 退出前把攒着的行落盘，否则最后几行随进程一起没了
        #if canImport(UIKit)
        observe(UIApplication.didEnterBackgroundNotification)
        observe(UIApplication.willTerminateNotification)
        #elseif canImport(AppKit)
        observe(NSApplication.willTerminateNotification)
        #endif

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        // Core 层的日志出口接到这里：JuyueCore 不依赖 App 层，只能运行时注入
        JuyueLog.handler = { line in AppLog.write(line) }
        write("—— 启动 v\(version) (\(build)) ——")
        DiagnosticHub.shared.loadFromDiskIfNeeded()
    }

    private static func observe(_ name: Notification.Name) {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            flushNow()
        }
    }

    /// 信号处理专用：只用 open/write/close，不建目录、不做字符串插值
    private static var crashPath: UnsafeMutablePointer<CChar>?

    private static func writeSignalCrash(_ sig: Int32) {
        guard let path = crashPath else { return }
        let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        let message: StaticString
        switch sig {
        case SIGABRT: message = "💥 SIGABRT\n"
        case SIGSEGV: message = "💥 SIGSEGV\n"
        case SIGBUS: message = "💥 SIGBUS\n"
        case SIGILL: message = "💥 SIGILL\n"
        case SIGTRAP: message = "💥 SIGTRAP\n"
        case SIGFPE: message = "💥 SIGFPE\n"
        default: message = "💥 SIGNAL\n"
        }
        _ = Darwin.write(fd, message.utf8Start, message.utf8CodeUnitCount)
        Darwin.close(fd)
    }

    /// 未捕获异常 / 崩溃前同步写：先把缓冲刷掉，再写崩溃行。
    static func writeCrash(_ line: String) {
        flushNow()
        let text = "[\(stamp())] \(LogRedaction.redact(line))\n"
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fd = Darwin.open(crashFileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = text.withCString { Darwin.write(fd, $0, strlen($0)) }
        Darwin.close(fd)
    }

    /// 旧名保留，语义变成「写崩溃文件」。
    static func writeSync(_ line: String) {
        writeCrash(line)
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
        // 只入队，不在调用者线程上碰文件
        queue.async { enqueue(line) }
    }

    /// 把缓冲立刻落盘。已经在队列上时直接执行，避免自己等自己。
    static func flushNow() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            flush()
        } else {
            queue.sync { flush() }
        }
    }

    private static func enqueue(_ line: String) {
        pending.append("[\(stamp())] \(LogRedaction.redact(line))\n")
        if pending.count >= flushBatch {
            flush()
        } else {
            scheduleFlush()
        }
    }

    private static func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + flushDelay) { flush() }
    }

    private static func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let text = pending.joined()
        pending.removeAll(keepingCapacity: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        append(text, to: fileURL)
        trimIfNeeded()
    }

    private static func append(_ text: String, to url: URL) {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// 超过上限只留尾部：读文件尾一段写回去，不再整文件解成行数组。
    private static func trimIfNeeded() {
        let limit = maxKilobytes * 1024
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int,
              size > limit,
              let handle = try? FileHandle(forReadingFrom: fileURL)
        else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(size - limit))) != nil,
              var tail = try? handle.readToEnd() else { return }
        // 砍在半个字符或半行上都会让日志难读，挪到下一个换行之后
        if let newline = tail.firstIndex(of: 0x0A) {
            tail = tail[tail.index(after: newline)...]
        }
        try? Data(tail).write(to: fileURL, options: .atomic)
    }

    private static func stamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static func read() -> String {
        var parts: [String] = []
        if let crash = try? String(contentsOf: crashFileURL, encoding: .utf8), !crash.isEmpty {
            parts.append("—— 崩溃记录（不裁剪）——\n" + crash)
        }
        if let log = try? String(contentsOf: fileURL, encoding: .utf8), !log.isEmpty {
            parts.append("—— 运行日志 ——\n" + log)
        }
        return parts.isEmpty ? "（还没有日志）" : parts.joined(separator: "\n\n")
    }

    static func clear() {
        flushNow()
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: crashFileURL)
    }
}

/// 日志查看：崩溃后进来复制一份发我就够定位了
struct LogViewerView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case log = "运行日志"
        case diagnostics = "请求诊断"
        var id: String { rawValue }
    }

    @Environment(\.appTheme) private var theme
    @State private var mode: Mode = .log
    @State private var text = ""
    @State private var diagnostics: [SourceRequestDiagnostic] = []
    @State private var copied = false
    @State private var logEnabled = AppLog.isEnabled
    @State private var maxKilobytes = AppLog.maxKilobytes

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if mode == .log {
                logPane
            } else {
                diagnosticsPane
            }
        }
        .appThemePageBackground()
        .appThemedPage()
        .navigationTitle("诊断日志")
        .onAppear { load() }
    }

    private var logPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("记录日志", isOn: $logEnabled)
                    .onChange(of: logEnabled) { newValue in
                        AppLog.isEnabled = newValue
                        load()
                    }
                Spacer()
                Stepper(value: $maxKilobytes, in: 8...1024, step: 8) {
                    Text("保留 \(maxKilobytes) KB")
                        .font(.caption)
                }
                .onChange(of: maxKilobytes) { newValue in
                    AppLog.maxKilobytes = newValue
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
            footer(payload: text, charCount: text.count)
        }
    }

    private var diagnosticsPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("本机最近 \(diagnostics.count) 条请求记录，搜索和阅读路径都在里面")
                    .font(.caption)
                    .foregroundColor(theme.palette.secondaryInk)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(diagnostics.reversed()) { item in
                        diagnosticRow(item)
                        Divider()
                    }
                }
                .padding(12)
            }
            Divider()
            footer(payload: diagnosticsText(), charCount: diagnostics.count)
        }
    }

    private func diagnosticRow(_ item: SourceRequestDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.step)
                    .font(.caption)
                    .bold()
                if !item.sourceName.isEmpty {
                    Text(item.sourceName)
                        .font(.caption2)
                        .lineLimit(1)
                }
                Spacer()
                if !item.failureKind.isEmpty {
                    Text(item.failureKind)
                        .font(.caption2)
                        .foregroundColor(.red)
                }
                Text(item.statusCode > 0 ? "HTTP \(item.statusCode)" : "无 HTTP")
                    .font(.caption2)
            }
            Text(timingLine(item))
                .font(.system(size: 11, design: .monospaced))
            if !item.headersSummary.isEmpty {
                Text(item.headersSummary)
                    .font(.system(size: 11, design: .monospaced))
            }
            Text(item.url)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            if !item.note.isEmpty {
                Text(item.note)
                    .font(.caption2)
            }
            if !item.responsePreview.isEmpty {
                Text(item.responsePreview)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundColor(theme.palette.secondaryInk)
            }
        }
    }

    private func timingLine(_ item: SourceRequestDiagnostic) -> String {
        var parts = [
            Self.timeFormatter.string(from: item.at),
            "\(item.elapsedMs) ms"
        ]
        if item.ruleEvalMs > 0 {
            parts.append("规则 \(item.ruleEvalMs) ms")
        }
        parts.append("\(item.responseBytes) B")
        parts.append("命中 \(item.ruleHits)")
        return parts.joined(separator: " · ")
    }

    private func footer(payload: String, charCount: Int) -> some View {
        HStack(spacing: 12) {
            Button(copied ? "已复制" : "复制全部") {
                copyToPasteboard(payload)
                copied = true
            }
            if #available(iOS 16.0, macOS 13.0, *), mode == .log {
                ShareLink(item: AppLog.fileURL) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            Button("刷新") { load() }
            Button("清空", role: .destructive) {
                if mode == .log {
                    AppLog.clear()
                } else {
                    DiagnosticHub.shared.clear()
                }
                load()
            }
            Spacer()
            Text(mode == .log ? "\(charCount) 字符" : "\(charCount) 条")
                .font(.caption2)
                .foregroundColor(theme.palette.secondaryInk)
        }
        .padding(12)
    }

    private func copyToPasteboard(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }

    private func diagnosticsText() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(diagnostics),
              let string = String(data: data, encoding: .utf8)
        else { return "（还没有诊断记录）" }
        return string
    }

    private func load() {
        copied = false
        text = AppLog.read()
        diagnostics = DiagnosticHub.shared.snapshot()
        maxKilobytes = AppLog.maxKilobytes
    }
}
