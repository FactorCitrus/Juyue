import SwiftUI
#if canImport(JuyueCore)
import JuyueCore
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public struct SourceDetailView: View {
    @ObservedObject var bookStore = BookStore.shared
    @Environment(\.appTheme) private var theme

    private let origin: BookSource

    @StateObject private var categoryState: SourceCategoryState
    @StateObject private var loginState: SourceLoginCheckState
    @State private var editingSource = false
    @State private var presentingLogin = false
    @State private var searchingThisSource = false
    @State private var exploreTarget: ExploreCategory?
    @State private var inspectingCookies = false
    @State private var confirmingVariableReset = false

    public init(source: BookSource) {
        self.origin = source
        _categoryState = StateObject(wrappedValue: SourceCategoryState(source: source))
        _loginState = StateObject(wrappedValue: SourceLoginCheckState())
    }

    private var source: BookSource {
        bookStore.sources.first {
            $0.bookSourceUrl == origin.bookSourceUrl || $0.id == origin.id
        } ?? origin
    }

    public var body: some View {
        List {
            SourceIdentitySection(source: source, store: bookStore)
            SourceAccountSection(
                source: source,
                store: bookStore,
                onLogin: { presentingLogin = true },
                onLogout: { categoryState.reload(for: source) }
            )
            SourceLoginSection(
                source: source,
                state: loginState,
                onInspectCookies: { inspectingCookies = true },
                onClear: {
                    bookStore.logoutSource(sourceUrl: source.bookSourceUrl)
                    loginState.reset()
                    loginState.check(source: source, force: true)
                }
            )
            if source.customButton == true || source.eventListener == true {
                SourceCompatibilitySection(source: source)
            }
            if let variable = source.variable,
               !variable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SourceVariableSection(variable: variable) { editingSource = true }
            }
            SourceExploreSection(
                categories: categoryState.categories,
                refreshing: categoryState.refreshing,
                onSelect: { category in
                    if category.isAction {
                        guard let url = category.url else { return }
                        Task {
                            await BookExploreService.shared.runActionCategory(source: source, categoryUrl: url)
                        }
                    } else {
                        exploreTarget = category
                    }
                },
                onLogin: { presentingLogin = true }
            )
        }
        .appThemedList()
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("书源详情")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarMenu }
        .sheet(isPresented: $editingSource) { EditSourceSheet(source: source) }
        .sheet(isPresented: $presentingLogin) { SourceLoginSheet(source: source) }
        .sheet(isPresented: $searchingThisSource) { NavigationView { SearchBookView() } }
        .sheet(isPresented: $inspectingCookies) { CookieInspectorSheet(source: source) }
        .alert("清空书源变量？", isPresented: $confirmingVariableReset) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                var changed = source
                changed.variable = nil
                bookStore.updateSource(changed)
            }
        } message: {
            Text("会清掉书源自己存的服务器、token 等数据。登录信息和 Cookie 不受影响。")
        }
        .background(exploreDestinationLink)
        .onAppear {
            categoryState.reload(for: source)
            loginState.check(source: source, force: false)
        }
    }

    @ToolbarContentBuilder
    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { editingSource = true } label: {
                    Label("编辑书源", systemImage: "pencil")
                }
                Button { searchOnlyHere() } label: {
                    Label("仅在此源搜索", systemImage: "magnifyingglass")
                }
                Button { bookStore.pinSource(sourceUrl: source.bookSourceUrl) } label: {
                    Label("置顶书源", systemImage: "pin")
                }
                Button { categoryState.reload(for: source) } label: {
                    Label("刷新发现分类", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) { confirmingVariableReset = true } label: {
                    Label("清空书源变量", systemImage: "eraser")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var exploreDestinationLink: some View {
        NavigationLink(
            isActive: Binding(
                get: { exploreTarget != nil },
                set: { if !$0 { exploreTarget = nil } }
            ),
            destination: {
                if let category = exploreTarget {
                    ExploreBookListView(source: source, category: category)
                } else {
                    EmptyView()
                }
            },
            label: { EmptyView() }
        )
        .hidden()
    }

    private func searchOnlyHere() {
        SearchViewModel.shared.selectedSourceUrls = [source.bookSourceUrl]
        searchingThisSource = true
    }
}

// MARK: - 区块

private struct SourceIdentitySection: View {
    let source: BookSource
    @ObservedObject var store: BookStore
    @Environment(\.appTheme) private var theme

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(source.bookSourceName)
                        .font(.title2.bold())
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { source.enabled ?? true },
                        set: { _ in store.toggleSource(sourceUrl: source.bookSourceUrl) }
                    ))
                    .labelsHidden()
                }

                Label(source.bookSourceUrl, systemImage: "globe")
                    .font(.caption)
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(1)

                if let group = source.bookSourceGroup, !group.isEmpty {
                    Text("分组: \(group)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.palette.divider.opacity(0.12))
                        .cornerRadius(4)
                        .foregroundColor(theme.palette.secondaryInk)
                }

                HStack(spacing: 10) {
                    if let updated = source.lastUpdateTime, updated > 0 {
                        Text("更新 \(SourceDetailFormat.date(updated))")
                    }
                    if let response = source.respondTime, response > 0 {
                        Text("响应 \(response)ms")
                    }
                    Text("权重 \(source.weight ?? 0)")
                }
                .font(.caption2)
                .foregroundColor(theme.palette.secondaryInk)
            }
            .padding(.vertical, 4)
        }
        .appThemedRows()
    }
}

private struct SourceAccountSection: View {
    let source: BookSource
    @ObservedObject var store: BookStore
    let onLogin: () -> Void
    let onLogout: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Section(header: Text("账号信息")) {
            if source.loginUi != nil || source.loginUrl != nil {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(
                            source.isLogged ? "已登录账号" : "未登录账号",
                            systemImage: source.isLogged ? "checkmark.shield.fill" : "person.badge.key"
                        )
                        .font(.headline)
                        .foregroundColor(source.isLogged ? .green : .orange)

                        Spacer()

                        if source.isLogged {
                            Button("注销") {
                                store.logoutSource(sourceUrl: source.bookSourceUrl)
                                onLogout()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }

                        Button(source.isLogged ? "切换/重新登录" : "立即登录", action: onLogin)
                            .font(.caption)
                            .buttonStyle(.borderedProminent)
                    }

                    if let info = source.loginInfo, !info.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("凭证信息:")
                                .font(.caption2)
                                .foregroundColor(theme.palette.secondaryInk)
                            Text(SourceDetailFormat.loginInfo(info))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(theme.palette.secondaryInk)
                                .lineLimit(2)
                        }
                        .padding(8)
                        .background(theme.palette.divider.opacity(0.08))
                        .cornerRadius(6)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Label("这个源不用登录，也可能还没配登录脚本。", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundColor(theme.palette.secondaryInk)
            }
        }
        .appThemedRows()
    }
}

private struct SourceLoginSection: View {
    let source: BookSource
    @ObservedObject var state: SourceLoginCheckState
    let onInspectCookies: () -> Void
    let onClear: () -> Void
    @Environment(\.appTheme) private var theme

    private var cookie: String { LoginSnapshot.cookie(for: source) }

    var body: some View {
        Section(header: Text("登录状态")) {
            HStack(spacing: 8) {
                if state.checking {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Image(systemName: statusIcon)
                        .foregroundColor(statusColor)
                }
                Text(state.report?.state.label ?? (source.isLogged ? "已有登录信息" : "未检测"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("检测") { state.check(source: source, force: true) }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }

            if let message = state.report?.message, !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
                    .lineLimit(3)
            }

            if let header = source.loginHeader, !header.isEmpty {
                secretBlock(title: "登录信息", value: SourceDetailFormat.masked(header))
            }

            if !cookie.isEmpty {
                secretBlock(title: "Cookie（\(cookie.count) 字符）", value: SourceDetailFormat.masked(cookie))
            }

            HStack(spacing: 8) {
                Button("查看 Cookie", action: onInspectCookies)
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .disabled(cookie.isEmpty && (source.loginHeader ?? "").isEmpty)

                Button("清除登录信息", role: .destructive, action: onClear)
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        }
        .appThemedRows()
    }

    private func secretBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(theme.palette.secondaryInk)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(3)
        }
    }

    private var statusIcon: String {
        switch state.report?.state {
        case .loggedIn: return "checkmark.shield.fill"
        case .loggedOut: return "xmark.shield.fill"
        case .unknown: return "questionmark.circle"
        case .notRequired: return "checkmark.circle"
        case .none: return "shield"
        }
    }

    private var statusColor: Color {
        switch state.report?.state {
        case .loggedIn, .notRequired: return .green
        case .loggedOut: return .red
        case .unknown: return .orange
        case .none: return .secondary
        }
    }
}

private struct SourceCompatibilitySection: View {
    let source: BookSource
    @Environment(\.appTheme) private var theme

    var body: some View {
        Section(header: Text("兼容性")) {
            VStack(alignment: .leading, spacing: 4) {
                if source.customButton == true {
                    Text("这个源自带自定义按钮，橘阅暂时不显示。")
                }
                if source.eventListener == true {
                    Text("这个源用到了事件监听，橘阅暂时不支持。")
                }
            }
            .font(.caption2)
            .foregroundColor(theme.palette.secondaryInk)
        }
        .appThemedRows()
    }
}

private struct SourceVariableSection: View {
    let variable: String
    let onEdit: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Section(header: Text("书源变量")) {
            Text(variable)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.palette.secondaryInk)
                .lineLimit(8)
            Button("编辑变量", action: onEdit)
                .font(.subheadline)
        }
        .appThemedRows()
    }
}

private struct SourceExploreSection: View {
    let categories: [ExploreCategory]
    let refreshing: Bool
    let onSelect: (ExploreCategory) -> Void
    let onLogin: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Section(header: exploreHeader) {
            if categories.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.title2)
                        .foregroundColor(theme.palette.secondaryInk.opacity(0.5))
                    Text("这个源还没分出分类。")
                        .font(.caption)
                        .foregroundColor(theme.palette.secondaryInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(SourceCategoryGrouping.groups(from: categories), id: \.header) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        if !group.header.isEmpty {
                            Text(group.header)
                                .font(.caption.bold())
                                .foregroundColor(theme.palette.secondaryInk)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 85), spacing: 8)], spacing: 8) {
                            ForEach(group.items) { item in
                                categoryButton(item)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .appThemedRows()
    }

    private var exploreHeader: some View {
        HStack {
            Text("预设分类与发现")
            Spacer()
            if refreshing {
                ProgressView().scaleEffect(0.8)
            }
        }
    }

    @ViewBuilder
    private func categoryButton(_ item: ExploreCategory) -> some View {
        let actionable = !(item.url ?? "").isEmpty
        Button {
            if actionable {
                onSelect(item)
            } else if item.title == "账号未登录" {
                onLogin()
            }
        } label: {
            categoryChip(item.title, actionable: actionable)
        }
        .buttonStyle(.plain)
    }

    private func categoryChip(_ title: String, actionable: Bool) -> some View {
        HStack(spacing: 4) {
            if title == "账号未登录" {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(chipBackground(title: title, actionable: actionable))
        .foregroundColor(chipForeground(title: title, actionable: actionable))
        .cornerRadius(8)
    }

    private func chipBackground(title: String, actionable: Bool) -> Color {
        if actionable { return Color.blue.opacity(0.12) }
        if title == "账号未登录" { return theme.palette.warning.opacity(0.12) }
        return theme.palette.divider.opacity(0.1)
    }

    private func chipForeground(title: String, actionable: Bool) -> Color {
        if actionable { return .blue }
        if title == "账号未登录" { return theme.palette.warning }
        return theme.palette.secondaryInk
    }
}

// MARK: - Cookie 查看

private struct CookieInspectorSheet: View {
    let source: BookSource
    @Environment(\.dismiss) private var dismiss

    private var cookie: String { LoginSnapshot.cookie(for: source) }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(cookie.isEmpty ? "这个源没有 Cookie。" : cookie)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let header = source.loginHeader, !header.isEmpty {
                        Divider()
                        Text("登录信息")
                            .font(.caption.bold())
                        Text(header)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding()
            }
            .navigationTitle("登录信息")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("复制") { copyToPasteboard(cookie) }
                }
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - 状态

final class SourceCategoryState: ObservableObject {
    @Published var categories: [ExploreCategory] = []
    @Published var refreshing = false

    init(source: BookSource) {
        reload(for: source)
    }

    func reload(for source: BookSource) {
        refreshing = true
        Task.detached(priority: .userInitiated) {
            let parsed = BookExploreService.shared.parseExploreCategories(source: source)
            await MainActor.run {
                self.categories = parsed
                self.refreshing = false
            }
        }
    }
}

final class SourceLoginCheckState: ObservableObject {
    @Published var report: SourceLoginReport?
    @Published var checking = false

    func reset() {
        report = nil
    }

    func check(source: BookSource, force: Bool) {
        guard !checking else { return }
        checking = true
        Task {
            let result = await SourceLoginService.shared.check(source: source, force: force)
            await MainActor.run {
                self.report = result
                self.checking = false
            }
        }
    }
}

// MARK: - 纯函数

enum LoginSnapshot {
    static func cookie(for source: BookSource) -> String {
        let direct = CookieJar.shared.cookieString(for: source.bookSourceUrl)
        if !direct.isEmpty { return direct }
        guard let host = CookieJar.shared.lastWrittenHostKey, !host.isEmpty else { return "" }
        return CookieJar.shared.cookieString(for: host)
    }
}

enum SourceDetailFormat {
    static func date(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    static func masked(_ raw: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z0-9_\-]{0,64}=)([^;,"\s}]{4,})"#) else {
            return raw
        }
        let text = raw as NSString
        let all = regex.matches(in: raw, range: NSRange(location: 0, length: text.length))
        var output = raw
        for match in all.reversed() {
            let key = text.substring(with: match.range(at: 1))
            let secret = text.substring(with: match.range(at: 2))
            let visible = secret.count > 8 ? String(secret.suffix(4)) : ""
            let hidden = String(repeating: "•", count: min(8, secret.count))
            output = (output as NSString).replacingCharacters(in: match.range, with: key + hidden + visible)
        }
        return output
    }

    static func loginInfo(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return raw
        }
        return object.keys.sorted().map { key in
            key.lowercased().contains("password") ? "\(key): ******" : "\(key): \(object[key] ?? "")"
        }.joined(separator: " | ")
    }
}

enum SourceCategoryGrouping {
    struct Group {
        let header: String
        let items: [ExploreCategory]
    }

    static func groups(from categories: [ExploreCategory]) -> [Group] {
        var result: [Group] = []
        var header = ""
        var bucket: [ExploreCategory] = []

        for category in categories {
            guard category.isHeader else {
                bucket.append(category)
                continue
            }
            if !bucket.isEmpty {
                result.append(Group(header: header, items: bucket))
                bucket = []
            }
            header = category.title
        }

        if !bucket.isEmpty {
            result.append(Group(header: header, items: bucket))
        }
        return result
    }
}
