import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
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

    let initialSource: BookSource

    @State private var showEditSheet: Bool = false
    @State private var showLoginSheet: Bool = false
    @State private var showSingleSourceSearch: Bool = false
    @State private var categories: [ExploreCategory] = []
    @State private var isRefreshingCategories: Bool = false
    @State private var selectedCategoryForExplore: ExploreCategory? = nil
    @State private var loginReport: SourceLoginReport? = nil
    @State private var isCheckingLogin = false
    @State private var showCookieSheet = false
    @State private var showClearVariableAlert = false

    public init(source: BookSource) {
        self.initialSource = source
    }

    /// Finds the latest state of this source from BookStore
    private var currentSource: BookSource {
        bookStore.sources.first(where: { $0.bookSourceUrl == initialSource.bookSourceUrl || $0.id == initialSource.id }) ?? initialSource
    }

    public var body: some View {
        List {
            // Section 1: Basic Info
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(currentSource.bookSourceName)
                            .font(.title2.bold())
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { currentSource.enabled ?? true },
                            set: { _ in bookStore.toggleSource(sourceUrl: currentSource.bookSourceUrl) }
                        ))
                        .labelsHidden()
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                        Text(currentSource.bookSourceUrl)
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                            .lineLimit(1)
                    }

                    if let group = currentSource.bookSourceGroup, !group.isEmpty {
                        HStack(spacing: 4) {
                            Text("分组: \(group)")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.palette.divider.opacity(0.12))
                                .cornerRadius(4)
                                .foregroundColor(theme.palette.secondaryInk)
                        }
                    }

                    HStack(spacing: 10) {
                        if let updated = currentSource.lastUpdateTime, updated > 0 {
                            Text("更新 \(formattedDate(updated))")
                        }
                        if let respond = currentSource.respondTime, respond > 0 {
                            Text("响应 \(respond)ms")
                        }
                        Text("权重 \(currentSource.weight ?? 0)")
                    }
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
                }
                .padding(.vertical, 4)
            }
            .appThemedRows()

            // Section 2: Account & Login Information
            Section(header: Text("账号信息")) {
                if currentSource.loginUi != nil || currentSource.loginUrl != nil {
                    accountInfoRow
                } else {
                    HStack {
                        Image(systemName: "checkmark.circle")
                            .foregroundColor(theme.palette.secondaryInk)
                        Text("这个源不用登录，也可能还没配登录脚本。")
                            .font(.subheadline)
                            .foregroundColor(theme.palette.secondaryInk)
                    }
                }
            }
            .appThemedRows()

            Section(header: Text("登录状态")) {
                HStack(spacing: 8) {
                    if isCheckingLogin {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: loginStateIcon)
                            .foregroundColor(loginStateColor)
                    }
                    Text(loginReport?.state.label ?? (currentSource.isLogged ? "已有登录信息" : "未检测"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("检测") { checkLogin(force: true) }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }

                if let message = loginReport?.message, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                        .lineLimit(3)
                }

                if let header = currentSource.loginHeader, !header.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录信息")
                            .font(.caption2)
                            .foregroundColor(theme.palette.secondaryInk)
                        Text(masked(header))
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(3)
                    }
                }

                let cookie = currentCookie
                if !cookie.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cookie（\(cookie.count) 字符）")
                            .font(.caption2)
                            .foregroundColor(theme.palette.secondaryInk)
                        Text(masked(cookie))
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(3)
                    }
                }

                HStack(spacing: 8) {
                    Button("查看 Cookie") { showCookieSheet = true }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .disabled(cookie.isEmpty && (currentSource.loginHeader ?? "").isEmpty)
                    Button("清除登录信息", role: .destructive) {
                        bookStore.logoutSource(sourceUrl: currentSource.bookSourceUrl)
                        loginReport = nil
                        checkLogin(force: true)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .appThemedRows()

            if currentSource.customButton == true || currentSource.eventListener == true {
                Section(header: Text("兼容性")) {
                    VStack(alignment: .leading, spacing: 4) {
                        if currentSource.customButton == true {
                            Text("这个源自带自定义按钮，橘阅暂时不显示。")
                        }
                        if currentSource.eventListener == true {
                            Text("这个源用到了事件监听，橘阅暂时不支持。")
                        }
                    }
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
                }
                .appThemedRows()
            }

            if let variable = currentSource.variable, !variable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section(header: Text("书源变量")) {
                    Text(variable)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.palette.secondaryInk)
                        .lineLimit(8)
                    Button("编辑变量") { showEditSheet = true }
                        .font(.subheadline)
                }
                .appThemedRows()
            }

            // Section 3: Preset Explore Categories
            Section(header: HStack {
                Text("预设分类与发现")
                Spacer()
                if isRefreshingCategories {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }) {
                if categories.isEmpty {
                    VStack(alignment: .center, spacing: 8) {
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
                    exploreCategoriesView
                }
            }
            .appThemedRows()
        }
        .appThemedList()
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("书源详情")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showEditSheet = true
                    } label: {
                        Label("编辑书源", systemImage: "pencil")
                    }

                    Button {
                        openScopedSearch()
                    } label: {
                        Label("仅在此源搜索", systemImage: "magnifyingglass")
                    }

                    Button {
                        bookStore.pinSource(sourceUrl: currentSource.bookSourceUrl)
                    } label: {
                        Label("置顶书源", systemImage: "pin")
                    }

                    Button {
                        refreshCategories()
                    } label: {
                        Label("刷新发现分类", systemImage: "arrow.clockwise")
                    }

                    Button(role: .destructive) {
                        showClearVariableAlert = true
                    } label: {
                        Label("清空书源变量", systemImage: "eraser")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            EditSourceSheet(source: currentSource)
        }
        .sheet(isPresented: $showLoginSheet) {
            SourceLoginSheet(source: currentSource)
        }
        .sheet(isPresented: $showSingleSourceSearch) {
            NavigationView {
                SearchBookView()
            }
        }
        .sheet(isPresented: $showCookieSheet) {
            cookieSheet
        }
        .alert("清空书源变量？", isPresented: $showClearVariableAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                var updated = currentSource
                updated.variable = nil
                bookStore.updateSource(updated)
            }
        } message: {
            Text("会清掉书源自己存的服务器、token 等数据。登录信息和 Cookie 不受影响。")
        }
        .background(
            NavigationLink(
                isActive: Binding(
                    get: { selectedCategoryForExplore != nil },
                    set: { if !$0 { selectedCategoryForExplore = nil } }
                ),
                destination: {
                    if let cat = selectedCategoryForExplore {
                        ExploreBookListView(source: currentSource, category: cat)
                    } else {
                        EmptyView()
                    }
                },
                label: { EmptyView() }
            )
            .hidden()
        )
        .onAppear {
            refreshCategories()
            checkLogin(force: false)
        }
    }

    private var loginStateIcon: String {
        switch loginReport?.state {
        case .loggedIn: return "checkmark.shield.fill"
        case .loggedOut: return "xmark.shield.fill"
        case .unknown: return "questionmark.circle"
        case .notRequired: return "checkmark.circle"
        case .none: return "shield"
        }
    }

    private var loginStateColor: Color {
        switch loginReport?.state {
        case .loggedIn, .notRequired: return .green
        case .loggedOut: return .red
        case .unknown: return .orange
        case .none: return .secondary
        }
    }

    /// 有些聚合源的 bookSourceUrl 不是域名，登录脚本把 Cookie 写在真实 host 上。
    private var currentCookie: String {
        let direct = CookieJar.shared.cookieString(for: currentSource.bookSourceUrl)
        if !direct.isEmpty { return direct }
        if let host = CookieJar.shared.lastWrittenHostKey, !host.isEmpty {
            return CookieJar.shared.cookieString(for: host)
        }
        return ""
    }

    private func checkLogin(force: Bool) {
        guard !isCheckingLogin else { return }
        isCheckingLogin = true
        let source = currentSource
        Task {
            let report = await SourceLoginService.shared.check(source: source, force: force)
            await MainActor.run {
                loginReport = report
                isCheckingLogin = false
            }
        }
    }

    private func masked(_ raw: String) -> String {
        let pattern = #"([A-Za-z0-9_\-]{0,64}=)([^;,"\s}]{4,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }
        let ns = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        var result = raw
        for match in matches.reversed() {
            let key = ns.substring(with: match.range(at: 1))
            let value = ns.substring(with: match.range(at: 2))
            let tail = value.count > 8 ? String(value.suffix(4)) : ""
            result = (result as NSString).replacingCharacters(
                in: match.range,
                with: "\(key)\(String(repeating: "•", count: min(8, value.count)))\(tail)"
            )
        }
        return result
    }

    private func formattedDate(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private var cookieSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let cookie = currentCookie
                    Text(cookie.isEmpty ? "这个源没有 Cookie。" : cookie)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let header = currentSource.loginHeader, !header.isEmpty {
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
                    Button("关闭") { showCookieSheet = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("复制") {
                        let cookie = currentCookie
                        #if canImport(UIKit)
                        UIPasteboard.general.string = cookie
                        #elseif canImport(AppKit)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cookie, forType: .string)
                        #endif
                    }
                }
            }
        }
    }

    // MARK: - Account Info Subview
    @ViewBuilder
    private var accountInfoRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: currentSource.isLogged ? "checkmark.shield.fill" : "person.badge.key")
                        .foregroundColor(currentSource.isLogged ? .green : .orange)
                    Text(currentSource.isLogged ? "已登录账号" : "未登录账号")
                        .font(.headline)
                        .foregroundColor(currentSource.isLogged ? .green : .primary)
                }

                Spacer()

                if currentSource.isLogged {
                    Button("注销") {
                        bookStore.logoutSource(sourceUrl: currentSource.bookSourceUrl)
                        refreshCategories()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                Button(currentSource.isLogged ? "切换/重新登录" : "立即登录") {
                    showLoginSheet = true
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
            }

            if let info = currentSource.loginInfo, !info.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("凭证信息:")
                        .font(.caption2)
                        .foregroundColor(theme.palette.secondaryInk)
                    Text(infoSummary(info))
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
    }

    private func infoSummary(_ info: String) -> String {
        if let data = info.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var parts: [String] = []
            for (k, v) in dict {
                if k.lowercased().contains("password") {
                    parts.append("\(k): ******")
                } else {
                    parts.append("\(k): \(v)")
                }
            }
            return parts.joined(separator: " | ")
        }
        return info
    }

    // MARK: - Explore Categories Layout
    @ViewBuilder
    private var exploreCategoriesView: some View {
        let grouped = groupCategories(categories)

        ForEach(grouped, id: \.header) { group in
            VStack(alignment: .leading, spacing: 8) {
                if !group.header.isEmpty {
                    Text(group.header)
                        .font(.caption.bold())
                        .foregroundColor(theme.palette.secondaryInk)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 85), spacing: 8)], spacing: 8) {
                    ForEach(group.items) { item in
                        if let _ = item.url, !item.url!.isEmpty {
                            Button {
                                // 动作类分类不跳页面：跳过去先出「暂无书籍」，登录页再叠上来
                                if item.isAction {
                                    runActionCategory(item)
                                } else {
                                    selectedCategoryForExplore = item
                                }
                            } label: {
                                categoryChip(title: item.title, isActionable: true)
                            }
                            .buttonStyle(.plain)
                        } else {
                            // Non-actionable or login prompt chip
                            Button {
                                if item.title == "账号未登录" {
                                    showLoginSheet = true
                                }
                            } label: {
                                categoryChip(title: item.title, isActionable: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// 执行动作类分类，脚本里弹浏览器或弹提示。
    private func runActionCategory(_ category: ExploreCategory) {
        guard let url = category.url else { return }
        Task { await BookExploreService.shared.runActionCategory(source: currentSource, categoryUrl: url) }
    }

    @ViewBuilder
    private func categoryChip(title: String, isActionable: Bool) -> some View {
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
        .background(
            isActionable
                ? Color.blue.opacity(0.12)
                : (title == "账号未登录" ? theme.palette.warning.opacity(0.12) : theme.palette.divider.opacity(0.1))
        )
        .foregroundColor(
            isActionable
                ? Color.blue
                : (title == "账号未登录" ? theme.palette.warning : theme.palette.secondaryInk)
        )
        .cornerRadius(8)
    }

    // MARK: - Category Grouping Helper
    private struct CategoryGroup {
        let header: String
        let items: [ExploreCategory]
    }

    private func groupCategories(_ list: [ExploreCategory]) -> [CategoryGroup] {
        var groups: [CategoryGroup] = []
        var currentHeader: String = ""
        var currentItems: [ExploreCategory] = []

        for cat in list {
            if cat.isHeader {
                if !currentItems.isEmpty {
                    groups.append(CategoryGroup(header: currentHeader, items: currentItems))
                    currentItems = []
                }
                currentHeader = cat.title
            } else {
                currentItems.append(cat)
            }
        }

        if !currentItems.isEmpty {
            groups.append(CategoryGroup(header: currentHeader, items: currentItems))
        }

        return groups
    }

    private func refreshCategories() {
        isRefreshingCategories = true
        // 分类由书源 JS 算出来（聚合源的 jsLib 三万字符），放后台线程跑，界面显示加载中
        let source = currentSource
        Task.detached(priority: .userInitiated) {
            let parsed = BookExploreService.shared.parseExploreCategories(source: source)
            await MainActor.run {
                self.categories = parsed
                self.isRefreshingCategories = false
            }
        }
    }

    private func openScopedSearch() {
        SearchViewModel.shared.selectedSourceUrl = currentSource.bookSourceUrl
        showSingleSourceSearch = true
    }
}
