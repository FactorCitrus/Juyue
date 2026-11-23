import SwiftUI
#if canImport(JuyueCore)
import JuyueCore
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 总开关与触觉

/// 全 App 的趣味动效开关；关掉后只保留必要的状态切换。
enum PlayfulEffects {
    static let storageKey = "legado_playful_effects"

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: storageKey) != nil else { return true }
        return defaults.bool(forKey: storageKey)
    }

    static func allowed(reduceMotion: Bool) -> Bool {
        isEnabled && !reduceMotion
    }
}

enum PlayfulFeedback {
    case light
    case medium
    case rigid

    #if canImport(UIKit)
    var uiStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: return .light
        case .medium: return .medium
        case .rigid: return .rigid
        }
    }
    #endif
}

enum Haptics {
    static func tap(_ style: PlayfulFeedback = .light) {
        guard PlayfulEffects.isEnabled else { return }
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: style.uiStyle)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    static func success() {
        guard PlayfulEffects.isEnabled else { return }
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func soft() {
        guard PlayfulEffects.isEnabled else { return }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        #endif
    }
}

// MARK: - 按压回弹

struct PlayfulPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var feedback: PlayfulFeedback? = .light
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed && PlayfulEffects.allowed(reduceMotion: reduceMotion) ? scale : 1
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.62), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { pressed in
                guard pressed, let feedback,
                      PlayfulEffects.allowed(reduceMotion: reduceMotion) else { return }
                Haptics.tap(feedback)
            }
    }
}

// MARK: - 数字滚动

protocol RollingNumberFormatting {
    func string(from value: Double) -> String
}

/// 数值变化的插值由 animatableData 承担，外层用 `.animation(_:value:)` 驱动。
struct RollingNumber: View, Animatable {
    var value: Double
    var format: (Double) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(format(value))
    }
}

// MARK: - 整理模式抖动

struct JiggleModifier: ViewModifier {
    var active: Bool
    var angle: Double = 1.1
    @State private var tilt = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .rotationEffect(
                .degrees(active && PlayfulEffects.allowed(reduceMotion: reduceMotion) ? (tilt ? angle : -angle) : 0)
            )
            .animation(
                active && PlayfulEffects.allowed(reduceMotion: reduceMotion)
                    ? .easeInOut(duration: 0.16).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.2),
                value: tilt
            )
            .onAppear { tilt = active }
            .onChange(of: active) { on in
                tilt = on
            }
    }
}

extension View {
    func playfulJiggle(_ active: Bool) -> some View {
        modifier(JiggleModifier(active: active))
    }
}

// MARK: - 粒子爆开

struct SparkBurstModifier: ViewModifier {
    var trigger: Int
    var color: Color
    @State private var flying = false
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let count = 16

    func body(content: Content) -> some View {
        content
            .overlay(
                ZStack {
                    Circle()
                        .stroke(color, lineWidth: 2)
                        .frame(width: 34, height: 34)
                        .scaleEffect(flying ? 2.8 : 0.6)
                        .opacity(flying ? 0 : 0.85)

                    ForEach(0..<count, id: \.self) { index in
                        let angle = Double(index) / Double(count) * 2 * .pi
                        let radius = CGFloat(46 + (index % 3) * 16)
                        Image(systemName: index % 2 == 0 ? "sparkle" : "book.fill")
                            .font(.system(size: index % 3 == 0 ? 16 : 12))
                            .foregroundColor(color)
                            .offset(
                                x: flying ? cos(angle) * radius : 0,
                                y: flying ? sin(angle) * radius : 0
                            )
                            .opacity(flying ? 0 : 0.95)
                            .scaleEffect(flying ? 0.4 : 1)
                    }
                }
                .allowsHitTesting(false)
                .opacity(visible ? 1 : 0)
            )
            .onChange(of: trigger) { _ in
                guard PlayfulEffects.allowed(reduceMotion: reduceMotion) else { return }
                flying = false
                visible = true
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 1.0)) { flying = true }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    visible = false
                    flying = false
                }
            }
    }
}

extension View {
    func sparkBurst(trigger: Int, color: Color) -> some View {
        modifier(SparkBurstModifier(trigger: trigger, color: color))
    }
}

// MARK: - 今日阅读卡片

/// 卡片挂在 MainTabView 之上，而不是塞进书架页里：
/// 往 TabView 的页面里插视图会触发重建，把底部页签复制出好几份。
final class TodayReadingCenter: ObservableObject {
    static let shared = TodayReadingCenter()
    @Published var isPresented = false
}

struct TodayReadingHost: View {
    @ObservedObject private var center = TodayReadingCenter.shared

    var body: some View {
        if center.isPresented {
            TodayReadingCard {
                center.isPresented = false
            }
        }
    }
}

struct TodayReadingCard: View {
    @ObservedObject var stats = ReadingStatsStore.shared
    @ObservedObject private var archiveStyle = ArchiveStyleStore.shared
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onClose: () -> Void

    @State private var appeared = false

    private var style: ArchiveStyle { archiveStyle.style }

    private var chromeCorner: CGFloat {
        switch style {
        case .stamp: return 2
        case .ink: return 3
        case .drawer: return 22
        }
    }

    private func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分钟"
    }

    private var todayMinutes: Double {
        Double(stats.todaySeconds) / 60
    }

    var body: some View {
        ZStack(alignment: style == .drawer ? .bottom : .center) {
            Color.black.opacity(style == .drawer ? 0.38 : 0.28)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(theme.palette.accent)
                        .frame(width: 14, height: 3)
                    Text("TODAY / 阅读")
                        .font(theme.typography.label)
                        .foregroundColor(theme.palette.secondaryInk)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.palette.secondaryInk)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    RollingNumber(value: appeared ? todayMinutes : 0) { value in
                        "\(Int(value.rounded()))"
                    }
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .foregroundColor(theme.palette.ink)
                    Text("分钟")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .animation(.easeOut(duration: 1.0), value: appeared)

                Text("今天已经读了这么久")
                    .font(.footnote)
                    .foregroundColor(theme.palette.secondaryInk)

                Rectangle()
                    .fill(theme.palette.divider.opacity(0.7))
                    .frame(height: 0.5)

                HStack(spacing: 0) {
                    metric(title: "连续", value: "\(stats.streakDays) 天")
                    metric(title: "累计", value: duration(stats.totalSeconds))
                    metric(title: "章节", value: "\(stats.chaptersRead)")
                }

                Text("点空白处关闭")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.palette.secondaryInk.opacity(0.7))
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: chromeCorner, style: .continuous)
                    .fill(style == .ink ? theme.palette.elevated : theme.palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: chromeCorner, style: .continuous)
                    .stroke(
                        style == .stamp ? theme.palette.accent.opacity(0.85) : theme.palette.divider,
                        lineWidth: style == .stamp ? 1.2 : theme.metrics.borderWidth
                    )
            )
            .overlay(alignment: .top) {
                if style == .drawer {
                    Capsule()
                        .fill(theme.palette.divider)
                        .frame(width: 36, height: 4)
                        .padding(.top, 8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if style == .stamp {
                    Text("橘阅档案")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.palette.accent.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(theme.palette.accent.opacity(0.55), lineWidth: 1)
                        )
                        .rotationEffect(.degrees(-7))
                        .padding(14)
                }
            }
            .rotationEffect(.degrees(style == .stamp && appeared ? 0.8 : 0))
            .shadow(
                color: .black.opacity(style == .drawer ? 0.22 : 0.16),
                radius: style == .drawer ? 30 : 20,
                y: style == .drawer ? 18 : 10
            )
            .padding(.horizontal, 32)
            .padding(.bottom, style == .drawer ? 24 : 0)
            .offset(y: appeared || reduceMotion ? 0 : (style == .drawer ? 60 : -14))
            .opacity(appeared ? 1 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.78), value: appeared)
        }
        .onAppear { appeared = true }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.palette.secondaryInk)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.18)) {
            onClose()
        }
    }
}

// MARK: - 档案样式

enum ArchiveStyle: String, CaseIterable, Identifiable {
    case stamp
    case ink
    case drawer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stamp: return "钢印档案"
        case .ink: return "墨迹显影"
        case .drawer: return "抽屉抽卡"
        }
    }

    var subtitle: String {
        switch self {
        case .stamp: return "方角钢印、虚线编号，像户口簿"
        case .ink: return "旧纸登记表，墨迹慢慢显出来"
        case .drawer: return "从书桌抽屉底部抽出一张卡"
        }
    }
}

final class ArchiveStyleStore: ObservableObject {
    static let shared = ArchiveStyleStore()
    private static let key = "archive_style_v1"

    @Published var style: ArchiveStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.key) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? ""
        style = ArchiveStyle(rawValue: raw) ?? .stamp
    }
}

// MARK: - 档案员徽章

struct ArchiveBadge: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let unlocked: (BadgeStore) -> Bool
}

final class BadgeStore: ObservableObject {
    static let shared = BadgeStore()
    private static let stampKey = "archive_stamp_count_v1"
    private static let nightKey = "archive_night_stamps_v1"

    @Published private(set) var stampCount: Int
    @Published private(set) var nightStamps: Int

    private init() {
        let defaults = UserDefaults.standard
        stampCount = defaults.integer(forKey: Self.stampKey)
        nightStamps = defaults.integer(forKey: Self.nightKey)
    }

    var level: Int { stampCount / 10 + 1 }
    var nextLevelStamps: Int { 10 - stampCount % 10 }
    var streak: Int { ReadingStatsStore.shared.streakDays }
    var shelfCount: Int { BookStore.shared.bookshelf.count }
    var finishedBooks: Int {
        BookStore.shared.bookshelf.filter { book in
            book.totalChapterNum > 0 && book.durChapterIndex + 1 >= book.totalChapterNum
        }.count
    }

    func stampNow() {
        stampCount += 1
        UserDefaults.standard.set(stampCount, forKey: Self.stampKey)
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 23 || hour < 5 {
            nightStamps += 1
            UserDefaults.standard.set(nightStamps, forKey: Self.nightKey)
        }
    }

    static let catalogue: [ArchiveBadge] = [
        ArchiveBadge(id: "first", title: "初次盖章", detail: "长按书架图标一次", symbol: "seal") { $0.stampCount >= 1 },
        ArchiveBadge(id: "level2", title: "档案员 II", detail: "累计盖章 10 次", symbol: "rosette") { $0.stampCount >= 10 },
        ArchiveBadge(id: "streak7", title: "连续七天", detail: "连续阅读 7 天", symbol: "flame") { $0.streak >= 7 },
        ArchiveBadge(id: "streak30", title: "月满", detail: "连续阅读 30 天", symbol: "moon.stars") { $0.streak >= 30 },
        ArchiveBadge(id: "finish10", title: "读完十本", detail: "书架里读完 10 本", symbol: "books.vertical") { $0.finishedBooks >= 10 },
        ArchiveBadge(id: "night", title: "夜班", detail: "23 点到 5 点盖一次章", symbol: "moon") { $0.nightStamps >= 1 },
        ArchiveBadge(id: "shelf500", title: "藏书五百", detail: "书架满 500 本", symbol: "archivebox") { $0.shelfCount >= 500 }
    ]

    var unlockedCount: Int { Self.catalogue.filter { $0.unlocked(self) }.count }
}

// MARK: - 每日在读记录（时间胶囊）

struct DailyBookEntry: Codable {
    var bookUrl: String
    var name: String
    var chapterTitle: String
}

final class DailyBookLog {
    static let shared = DailyBookLog()
    private static let key = "archive_daily_books_v1"

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var entries: [String: DailyBookEntry]
    private var lastWrite = Date.distantPast
    private let queue = DispatchQueue(label: "juyue.archive.dailylog", qos: .utility)

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: DailyBookEntry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func record(book: Book, chapterTitle: String) {
        let now = Date()
        guard now.timeIntervalSince(lastWrite) > 30 else { return }
        lastWrite = now
        entries[formatter.string(from: now)] = DailyBookEntry(
            bookUrl: book.bookUrl,
            name: book.name,
            chapterTitle: chapterTitle
        )
        let snapshot = entries
        queue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    func capsule(now: Date = Date()) -> (dateKey: String, entry: DailyBookEntry?, seconds: Int)? {
        let calendar = Calendar.current
        for yearsAgo in 1...5 {
            guard let past = calendar.date(byAdding: .year, value: -yearsAgo, to: now) else { continue }
            let key = formatter.string(from: past)
            let entry = entries[key]
            let seconds = ReadingStatsStore.shared.snapshot.dailySeconds[key] ?? 0
            if entry != nil || seconds > 0 {
                return (key, entry, seconds)
            }
        }
        return nil
    }
}

// MARK: - 书架体检

struct ShelfHealthReport {
    var total = 0
    var unstarted = 0
    var reading = 0
    var finished = 0
    var uncached = 0
    var stuck: [Book] = []

    static func scan(books: [Book]) -> ShelfHealthReport {
        var report = ShelfHealthReport()
        report.total = books.count
        let now = Date()
        for book in books {
            let totalChapters = max(book.totalChapterNum, 1)
            let isFinished = book.durChapterIndex + 1 >= totalChapters

            if book.durChapterIndex == 0 && book.durChapterTime == 0 {
                report.unstarted += 1
            } else if isFinished {
                report.finished += 1
            } else {
                report.reading += 1
                let last = Date(timeIntervalSince1970: TimeInterval(book.durChapterTime) / 1000)
                if now.timeIntervalSince(last) > 30 * 86400 {
                    report.stuck.append(book)
                }
            }

            if OfflineBookStore.shared.cachedIndices(for: book.bookUrl).isEmpty {
                report.uncached += 1
            }
        }
        report.stuck.sort { $0.durChapterTime > $1.durChapterTime }
        return report
    }
}

// MARK: - 跨页打开书籍

final class ShelfReaderRequestCenter: ObservableObject {
    static let shared = ShelfReaderRequestCenter()
    @Published var pendingBook: Book?

    func open(_ book: Book) {
        pendingBook = book
    }
}

// MARK: - 档案抽屉

final class ArchiveDrawerCenter: ObservableObject {
    static let shared = ArchiveDrawerCenter()
    @Published var isPresented = false
}

struct ArchiveDrawerHost: View {
    @ObservedObject private var center = ArchiveDrawerCenter.shared

    var body: some View {
        if center.isPresented {
            ArchiveDrawer {
                center.isPresented = false
            }
        }
    }
}

private enum ArchiveTab: String, CaseIterable, Identifiable {
    case health
    case badges
    case capsule
    case theme

    var id: String { rawValue }

    var title: String {
        switch self {
        case .health: return "体检"
        case .badges: return "徽章"
        case .capsule: return "胶囊"
        case .theme: return "主题"
        }
    }
}

struct ArchiveDrawer: View {
    @ObservedObject private var styleStore = ArchiveStyleStore.shared
    @ObservedObject private var badges = BadgeStore.shared
    @ObservedObject private var stats = ReadingStatsStore.shared
    @ObservedObject private var bookStore = BookStore.shared
    @ObservedObject private var themeManager = AppThemeManager.shared
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tab: ArchiveTab = .health
    @State private var appeared = false
    @State private var health: ShelfHealthReport?
    @State private var drawn: Book?
    @State private var inkReveal = false
    @State private var tabDirection = 1
    @State private var drawLift = false
    @State private var measuredContentHeight: CGFloat = 0

    let onClose: () -> Void

    private var style: ArchiveStyle { styleStore.style }
    private var isInk: Bool { style == .ink }
    private var isDeck: Bool { style == .drawer }

    private var cornerRadius: CGFloat {
        switch style {
        case .stamp: return 1
        case .ink: return 3
        case .drawer: return 20
        }
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var entryOffset: CGFloat {
        switch style {
        case .stamp: return -22
        case .ink: return 0
        case .drawer: return 90
        }
    }

    private var entryAnimation: Animation {
        switch style {
        case .stamp: return .spring(response: 0.4, dampingFraction: 0.82)
        case .ink: return .easeOut(duration: 0.36)
        case .drawer: return .spring(response: 0.46, dampingFraction: 0.78)
        }
    }

    private func bodyFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: isInk ? .serif : .default)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: isDeck ? .bottom : .center) {
                Color.black.opacity(isDeck ? 0.38 : 0.32)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                panel(contentMaxHeight: max(96, geo.size.height * 0.58 - 205))
            }
        }
        .onAppear {
            appeared = true
            loadHealth()
            startInkReveal()
        }
        .onChange(of: styleStore.style) { _ in
            drawLift = false
            startInkReveal()
        }
    }

    private func panel(contentMaxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            tabStrip
            styleRule
            contentScroller(maxHeight: contentMaxHeight)
            footer
        }
        .padding(isInk ? 16 : 14)
        .padding(.top, isDeck ? 8 : 0)
        .frame(maxWidth: 440)
        .background(panelBackground)
        .overlay(panelBorder)
        .overlay(alignment: .top) {
            if isDeck {
                Capsule()
                    .fill(theme.palette.divider)
                    .frame(width: 36, height: 4)
                    .padding(.top, 8)
            }
        }
        .overlay {
            if style == .stamp { stampCornerMarks }
        }
        .shadow(
            color: .black.opacity(isInk ? 0.14 : 0.2),
            radius: isDeck ? 32 : 28,
            y: isDeck ? 18 : 14
        )
        .padding(.horizontal, 20)
        .padding(.bottom, isDeck ? 12 : 0)
        .offset(y: appeared || reduceMotion ? 0 : entryOffset)
        .scaleEffect(appeared || reduceMotion || !isDeck ? 1 : 0.97)
        .opacity(appeared ? 1 : 0)
        .animation(reduceMotion ? nil : entryAnimation, value: appeared)
    }

    private func contentScroller(maxHeight: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ArchiveContentHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .onPreferenceChange(ArchiveContentHeightKey.self) { height in
            measuredContentHeight = height
        }
        .frame(height: measuredContentHeight > 0 ? min(measuredContentHeight, maxHeight) : nil)
        .clipped()
    }

    @ViewBuilder
    private var panelBackground: some View {
        switch style {
        case .stamp:
            panelShape.fill(theme.palette.surface)
        case .ink:
            ZStack {
                panelShape.fill(theme.palette.surface)
                panelShape.fill(theme.palette.accent.opacity(0.05))
                ArchiveRuledLines(color: theme.palette.divider.opacity(0.35))
                    .clipShape(panelShape)
                    .allowsHitTesting(false)
            }
        case .drawer:
            panelShape.fill(theme.palette.surface)
        }
    }

    @ViewBuilder
    private var panelBorder: some View {
        switch style {
        case .stamp:
            panelShape.stroke(theme.palette.accent.opacity(0.85), lineWidth: 1.2)
            panelShape.inset(by: 3).stroke(theme.palette.accent.opacity(0.3), lineWidth: 0.5)
        case .ink:
            panelShape.stroke(theme.palette.divider, lineWidth: 1)
            panelShape.inset(by: 3.5).stroke(theme.palette.divider.opacity(0.6), lineWidth: 0.5)
        case .drawer:
            panelShape.stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
        }
    }

    @ViewBuilder
    private var styleRule: some View {
        if isInk {
            VStack(spacing: 1.5) {
                Rectangle()
                    .fill(theme.palette.accent.opacity(0.55))
                    .frame(height: 1)
                Rectangle()
                    .fill(theme.palette.divider)
                    .frame(height: 0.5)
            }
        } else {
            Rectangle()
                .fill(theme.palette.divider.opacity(0.7))
                .frame(height: 0.5)
        }
    }

    private var stampCornerMarks: some View {
        VStack {
            HStack { stampCornerMark; Spacer(); stampCornerMark }
            Spacer()
            HStack { stampCornerMark; Spacer(); stampCornerMark }
        }
        .padding(7)
        .allowsHitTesting(false)
    }

    private var stampCornerMark: some View {
        ZStack {
            Rectangle()
                .fill(theme.palette.accent.opacity(0.5))
                .frame(width: 7, height: 0.8)
            Rectangle()
                .fill(theme.palette.accent.opacity(0.5))
                .frame(width: 0.8, height: 7)
        }
        .frame(width: 7, height: 7)
    }

    private var header: some View {
        Group {
            switch style {
            case .stamp: stampHeader
            case .ink: inkHeader
            case .drawer: deckHeader
            }
        }
    }

    private var stampHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("橘阅档案室")
                    .font(theme.typography.title)
                    .foregroundColor(theme.palette.ink)
                headerLine
            }
            Spacer()
            closeButton
        }
    }

    private var inkHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("阅览登记簿")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundColor(theme.palette.ink)
                Spacer()
                Text("No.\(String(format: "%05d", badges.stampCount))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.palette.secondaryInk)
                closeButton
            }
            Text("登记员 LV.\(badges.level) · 落章 \(badges.stampCount) 次 · 连续 \(stats.streakDays) 日")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.palette.secondaryInk)
        }
        .modifier(ArchiveReveal(enabled: isInk, active: inkReveal, index: 0, reduceMotion: reduceMotion))
    }

    private var deckHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.palette.accent)
                    Text("书桌抽屉")
                        .font(theme.typography.title)
                        .foregroundColor(theme.palette.ink)
                }
                headerLine
            }
            Spacer()
            closeButton
        }
    }

    private var headerLine: some View {
        Text("档案员 LV.\(badges.level) · 已盖 \(badges.stampCount) 戳 · 连续 \(stats.streakDays) 天")
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(theme.palette.secondaryInk)
    }

    private var closeButton: some View {
        Button {
            Haptics.tap()
            close()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.palette.secondaryInk)
                .padding(6)
        }
        .buttonStyle(.plain)
    }

    private var tabStrip: some View {
        Group {
            switch style {
            case .stamp: stampTabs
            case .ink: inkTabs
            case .drawer: deckTabs
            }
        }
    }

    private var stampTabs: some View {
        HStack(spacing: 6) {
            ForEach(ArchiveTab.allCases) { item in
                Button {
                    select(item)
                } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(tab == item ? theme.palette.background : theme.palette.secondaryInk)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 2)
                                .fill(tab == item ? theme.palette.accent : theme.palette.elevated)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var inkTabs: some View {
        HStack(spacing: 13) {
            ForEach(Array(ArchiveTab.allCases.enumerated()), id: \.offset) { index, item in
                Button {
                    select(item)
                } label: {
                    VStack(spacing: 3) {
                        Text("\(String(format: "%02d", index + 1)) \(item.title)")
                            .font(.system(size: 11, weight: tab == item ? .semibold : .regular, design: .monospaced))
                            .foregroundColor(tab == item ? theme.palette.ink : theme.palette.secondaryInk)
                        Rectangle()
                            .fill(tab == item ? theme.palette.accent : Color.clear)
                            .frame(height: 1.5)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .modifier(ArchiveReveal(enabled: isInk, active: inkReveal, index: 1, reduceMotion: reduceMotion))
    }

    private var deckTabs: some View {
        HStack(spacing: 8) {
            ForEach(ArchiveTab.allCases) { item in
                Button {
                    select(item)
                } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(tab == item ? theme.palette.ink : theme.palette.secondaryInk)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(tab == item ? theme.palette.elevated : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(tab == item ? theme.palette.accent.opacity(0.45) : Color.clear, lineWidth: 1)
                        )
                        .shadow(color: tab == item ? Color.black.opacity(0.12) : Color.clear, radius: 5, y: 2)
                }
                .buttonStyle(ArchiveCardPressStyle(reduceMotion: reduceMotion))
            }
            Spacer()
        }
    }

    private func select(_ item: ArchiveTab) {
        guard item != tab else { return }
        Haptics.soft()
        let old = ArchiveTab.allCases.firstIndex(of: tab) ?? 0
        let new = ArchiveTab.allCases.firstIndex(of: item) ?? 0
        tabDirection = new >= old ? 1 : -1
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.86)) {
            tab = item
        }
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .stamp:
            tabContent
        case .ink:
            tabContent
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 2).fill(theme.palette.elevated)
                        RoundedRectangle(cornerRadius: 2).fill(theme.palette.accent.opacity(0.035))
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(theme.palette.divider.opacity(0.8), lineWidth: 0.8)
                )
                .modifier(ArchiveReveal(enabled: isInk, active: inkReveal, index: 2, reduceMotion: reduceMotion))
        case .drawer:
            deck
        }
    }

    private var deck: some View {
        ZStack {
            deckBack(offset: 11, inset: 9, opacity: 0.45)
            deckBack(offset: 5.5, inset: 4.5, opacity: 0.7)
            tabContent
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(theme.palette.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(theme.palette.divider.opacity(0.8), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                .id(tab)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: tabDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: tabDirection > 0 ? .leading : .trailing).combined(with: .opacity)
                    )
                )
        }
    }

    private func deckBack(offset: CGFloat, inset: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(theme.palette.elevated.opacity(0.7))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(theme.palette.divider.opacity(0.7), lineWidth: 1)
            )
            .padding(.horizontal, inset)
            .offset(y: offset)
            .opacity(opacity)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .health: healthPanel
        case .badges: badgePanel
        case .capsule: capsulePanel
        case .theme: themePanel
        }
    }

    private var healthPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let report = health {
                healthRow("藏书", "\(report.total) 本")
                healthRow("未开始", "\(report.unstarted) 本")
                healthRow("读到一半", "\(report.reading) 本")
                healthRow("卡住 30 天", "\(report.stuck.count) 本")
                healthRow("没有离线缓存", "\(report.uncached) 本")
                if let book = report.stuck.first {
                    Button {
                        openBook(book)
                    } label: {
                        Text("抽查：《\(book.name)》停在「\(book.durChapterTitle ?? "第 \(book.durChapterIndex + 1) 章")」")
                            .font(.system(size: 11))
                            .foregroundColor(theme.palette.accent)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                }
                Text(verdict(for: report))
                    .font(bodyFont(11))
                    .foregroundColor(theme.palette.secondaryInk)
                    .padding(.top, 2)
            } else {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("正在翻旧账……")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.palette.secondaryInk)
                }
            }
        }
    }

    private func verdict(for report: ShelfHealthReport) -> String {
        if report.total == 0 { return "书架还空着，先收几本书进来。" }
        if !report.stuck.isEmpty { return "有 \(report.stuck.count) 本卡了一个月，挑一本续上，比继续收藏划算。" }
        if report.unstarted > report.total / 2 { return "大半书架还没拆封，今天随手挑一本开个头。" }
        return "账面整齐，没有明显烂尾。"
    }

    private func healthRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(bodyFont(12))
                .foregroundColor(theme.palette.secondaryInk)
            Rectangle()
                .fill(theme.palette.divider.opacity(0.5))
                .frame(height: 0.5)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.palette.ink)
        }
    }

    private var badgePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("已解锁 \(badges.unlockedCount) / \(BadgeStore.catalogue.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.palette.secondaryInk)
                Spacer()
                Text("再盖 \(badges.nextLevelStamps) 戳升一级")
                    .font(.system(size: 10))
                    .foregroundColor(theme.palette.secondaryInk.opacity(0.8))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                ForEach(BadgeStore.catalogue) { badge in
                    badgeCell(badge)
                }
            }
        }
    }

    private func badgeCell(_ badge: ArchiveBadge) -> some View {
        let unlocked = badge.unlocked(badges)
        return VStack(spacing: 4) {
            badgeTile(unlocked: unlocked, symbol: badge.symbol)
            Text(badge.title)
                .font(.system(size: 9, weight: .medium, design: isInk ? .serif : .default))
                .foregroundColor(unlocked ? theme.palette.ink : theme.palette.secondaryInk.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    @ViewBuilder
    private func badgeTile(unlocked: Bool, symbol: String) -> some View {
        ZStack {
            switch style {
            case .stamp:
                Circle()
                    .fill(unlocked ? theme.palette.accent.opacity(0.14) : theme.palette.elevated)
            case .ink:
                RoundedRectangle(cornerRadius: 1)
                    .fill(unlocked ? theme.palette.accent.opacity(0.06) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1)
                            .stroke(unlocked ? theme.palette.accent.opacity(0.7) : theme.palette.divider, lineWidth: 1)
                    )
            case .drawer:
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(unlocked ? theme.palette.accent.opacity(0.14) : theme.palette.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(theme.palette.divider.opacity(0.7), lineWidth: 0.8)
                    )
            }
            Image(systemName: unlocked ? symbol : "lock")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(unlocked ? theme.palette.accent : theme.palette.secondaryInk.opacity(0.6))
        }
        .frame(width: 36, height: 36)
    }

    private var capsulePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let capsule = DailyBookLog.shared.capsule() {
                HStack(spacing: 6) {
                    if isInk {
                        Text("登记日")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(theme.palette.accent)
                    }
                    Text(capsule.dateKey)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.palette.secondaryInk)
                }
                if let entry = capsule.entry {
                    Text("那天在读《\(entry.name)》")
                        .font(bodyFont(13, weight: .semibold))
                        .foregroundColor(theme.palette.ink)
                    Text(entry.chapterTitle)
                        .font(bodyFont(11))
                        .foregroundColor(theme.palette.secondaryInk)
                        .lineLimit(2)
                    Button {
                        openEntry(entry)
                    } label: {
                        Text(isDeck ? "把这张卡翻回去" : "翻回那一章")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.palette.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("那天读了 \(max(1, capsule.seconds / 60)) 分钟，档案里没留下书名。")
                        .font(bodyFont(12))
                        .foregroundColor(theme.palette.ink)
                }
            } else {
                Text("旧档案里还没有一年前的今天。到明年这时候，这里会有一封信。")
                    .font(bodyFont(12))
                    .foregroundColor(theme.palette.secondaryInk)
            }
        }
    }

    private var themePanel: some View {
        VStack(alignment: .leading, spacing: isDeck ? 8 : 2) {
            ForEach(AppThemeChoice.allCases) { choice in
                Button {
                    Haptics.tap()
                    themeManager.choice = choice
                } label: {
                    HStack(spacing: 10) {
                        Group {
                            if isInk {
                                Rectangle()
                                    .fill(choice == themeManager.choice ? theme.palette.accent : theme.palette.divider)
                                    .frame(width: 7, height: 7)
                            } else {
                                Circle()
                                    .fill(choice == themeManager.choice ? theme.palette.accent : theme.palette.divider)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(choice.title)
                                .font(bodyFont(12, weight: .semibold))
                                .foregroundColor(theme.palette.ink)
                            Text(choice.subtitle)
                                .font(bodyFont(10))
                                .foregroundColor(theme.palette.secondaryInk)
                                .lineLimit(1)
                        }
                        Spacer()
                        if choice == themeManager.choice {
                            Text(isInk ? "已登记" : "当前")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(theme.palette.accent)
                        }
                    }
                    .padding(.vertical, isDeck ? 9 : 7)
                    .padding(.horizontal, isDeck ? 10 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(isDeck ? theme.palette.elevated : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(isDeck ? theme.palette.divider.opacity(0.7) : Color.clear, lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        Group {
            switch style {
            case .stamp: stampFooter
            case .ink: inkFooter
            case .drawer: deckFooter
            }
        }
    }

    private var stampFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(theme.palette.divider.opacity(0.7))
                .frame(height: 0.5)
            HStack(spacing: 10) {
                Button {
                    draw()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "signature")
                        Text("抽一签")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.palette.background)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(theme.palette.accent)
                    )
                }
                .buttonStyle(.plain)

                if let book = drawn {
                    Text("《\(book.name)》")
                        .font(.system(size: 12))
                        .foregroundColor(theme.palette.ink)
                        .lineLimit(1)
                } else {
                    Text("让书架替你挑一本")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.palette.secondaryInk)
                }
                Spacer()
            }
            if let book = drawn {
                Button {
                    openBook(book)
                } label: {
                    Text("就它了，去读「\(book.durChapterTitle ?? "第 \(book.durChapterIndex + 1) 章")」")
                        .font(.system(size: 10))
                        .foregroundColor(theme.palette.accent)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var inkFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    draw()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                        Text("登记抽签")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.palette.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .overlay(
                        Rectangle()
                            .stroke(theme.palette.accent.opacity(0.65), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                if let book = drawn {
                    Text("《\(book.name)》")
                        .font(bodyFont(12))
                        .foregroundColor(theme.palette.ink)
                        .lineLimit(1)
                } else {
                    Text("按号抽取书架一册")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.palette.secondaryInk)
                }
                Spacer()
            }
            if let book = drawn {
                Button {
                    openBook(book)
                } label: {
                    Text("调阅「\(book.durChapterTitle ?? "第 \(book.durChapterIndex + 1) 章")」")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.palette.accent)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
        .modifier(ArchiveReveal(enabled: isInk, active: inkReveal, index: 3, reduceMotion: reduceMotion))
    }

    private var deckFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    draw()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                        Text("抽一签")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.palette.onAccent)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(theme.palette.accent)
                    )
                    .shadow(color: theme.palette.accent.opacity(0.25), radius: 6, y: 3)
                }
                .buttonStyle(ArchiveCardPressStyle(reduceMotion: reduceMotion))

                Text(drawn == nil ? "让抽屉替你抽一张" : "刚抽出一张")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.palette.secondaryInk)
                Spacer()
            }
            if let book = drawn {
                drawnCard(book)
            }
        }
    }

    private func drawnCard(_ book: Book) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.palette.surface)
                    .frame(width: 40, height: 54)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(theme.palette.accent.opacity(0.35), lineWidth: 1)
                    )
                    .rotationEffect(.degrees(-6))
                Image(systemName: "book.closed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.palette.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(book.name)
                    .font(bodyFont(12, weight: .semibold))
                    .foregroundColor(theme.palette.ink)
                    .lineLimit(1)
                Text(book.durChapterTitle ?? "第 \(book.durChapterIndex + 1) 章")
                    .font(.system(size: 10))
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                openBook(book)
            } label: {
                Text("去读")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.palette.onAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.palette.accent)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.palette.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.palette.divider.opacity(0.8), lineWidth: 1)
        )
        .opacity(reduceMotion || drawLift ? 1 : 0)
        .offset(y: reduceMotion || drawLift ? 0 : 22)
        .rotation3DEffect(
            .degrees(reduceMotion || drawLift ? 0 : 16),
            axis: (x: 1, y: 0, z: 0),
            anchor: .bottom
        )
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.78), value: drawLift)
    }

    private func loadHealth() {
        let books = BookStore.shared.bookshelf
        DispatchQueue.global(qos: .userInitiated).async {
            let report = ShelfHealthReport.scan(books: books)
            DispatchQueue.main.async {
                health = report
            }
        }
    }

    private func startInkReveal() {
        inkReveal = false
        guard isInk, !reduceMotion else {
            inkReveal = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            inkReveal = true
        }
    }

    private func draw() {
        let shelf = bookStore.bookshelf
        guard !shelf.isEmpty else { return }
        var next = shelf.randomElement()
        if shelf.count > 1, next?.bookUrl == drawn?.bookUrl {
            next = shelf.filter { $0.bookUrl != drawn?.bookUrl }.randomElement()
        }
        drawn = next
        if isDeck {
            drawLift = false
            withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.78)) {
                drawLift = true
            }
        }
        Haptics.success()
    }

    private func openBook(_ book: Book) {
        ShelfReaderRequestCenter.shared.open(book)
        close()
    }

    private func openEntry(_ entry: DailyBookEntry) {
        guard let book = bookStore.bookshelf.first(where: { $0.bookUrl == entry.bookUrl }) else { return }
        openBook(book)
    }

    private func close() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            onClose()
        }
    }
}

// MARK: - 徽章墙

struct BadgeWallView: View {
    @ObservedObject private var badges = BadgeStore.shared
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("档案员 LV.\(badges.level)")
                        .font(theme.typography.title)
                        .foregroundColor(theme.palette.ink)
                    Text("已解锁 \(badges.unlockedCount) / \(BadgeStore.catalogue.count) · 累计盖章 \(badges.stampCount) 次")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.palette.secondaryInk)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(BadgeStore.catalogue) { badge in
                        badgeRow(badge)
                    }
                }
            }
            .padding(16)
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("徽章墙")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func badgeRow(_ badge: ArchiveBadge) -> some View {
        let unlocked = badge.unlocked(badges)
        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(unlocked ? theme.palette.accent.opacity(0.14) : theme.palette.elevated)
                    .frame(width: 38, height: 38)
                Image(systemName: unlocked ? badge.symbol : "lock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(unlocked ? theme.palette.accent : theme.palette.secondaryInk.opacity(0.6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(badge.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(unlocked ? theme.palette.ink : theme.palette.secondaryInk)
                Text(badge.detail)
                    .font(.system(size: 10))
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius)
                .fill(theme.palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.metrics.cornerRadius)
                .stroke(theme.palette.divider, lineWidth: theme.metrics.borderWidth)
        )
    }
}

// MARK: - 档案皮肤零件

private struct ArchiveContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ArchiveRuledLines: View {
    let color: Color

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 22.5) {
                ForEach(0..<64, id: \.self) { _ in
                    Rectangle()
                        .fill(color)
                        .frame(height: 0.5)
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .padding(.top, 18)
        }
    }
}

private struct ArchiveReveal: ViewModifier {
    let enabled: Bool
    let active: Bool
    let index: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(enabled && !active && !reduceMotion ? 0 : 1)
            .offset(y: enabled && !active && !reduceMotion ? 6 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.36).delay(Double(index) * 0.07), value: active)
    }
}

private struct ArchiveCardPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed && !reduceMotion ? -2 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: configuration.isPressed)
    }
}
