import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

public struct SourceDetailView: View {
    @ObservedObject var bookStore = BookStore.shared

    let initialSource: BookSource

    @State private var showEditSheet: Bool = false
    @State private var showLoginSheet: Bool = false
    @State private var showSingleSourceSearch: Bool = false
    @State private var categories: [ExploreCategory] = []
    @State private var isRefreshingCategories: Bool = false
    @State private var selectedCategoryForExplore: ExploreCategory? = nil

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
                            .foregroundColor(.secondary)
                        Text(currentSource.bookSourceUrl)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    if let group = currentSource.bookSourceGroup, !group.isEmpty {
                        HStack(spacing: 4) {
                            Text("分组: \(group)")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(4)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // Section 2: Account & Login Information
            Section(header: Text("账号信息")) {
                if currentSource.loginUi != nil || currentSource.loginUrl != nil {
                    accountInfoRow
                } else {
                    HStack {
                        Image(systemName: "checkmark.circle")
                            .foregroundColor(.secondary)
                        Text("该书源无需登录或未配置登录脚本")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
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
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("该书源暂未配置发现分类 (exploreUrl)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    exploreCategoriesView
                }
            }
        }
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
                        .foregroundColor(.secondary)
                    Text(infoSummary(info))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
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
                        .foregroundColor(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 85), spacing: 8)], spacing: 8) {
                    ForEach(group.items) { item in
                        if let _ = item.url, !item.url!.isEmpty {
                            Button {
                                selectedCategoryForExplore = item
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
                : (title == "账号未登录" ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.1))
        )
        .foregroundColor(
            isActionable
                ? Color.blue
                : (title == "账号未登录" ? Color.orange : Color.secondary)
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
        let parsed = BookExploreService.shared.parseExploreCategories(source: currentSource)
        self.categories = parsed
        self.isRefreshingCategories = false
    }

    private func openScopedSearch() {
        SearchViewModel.shared.selectedSourceUrl = currentSource.bookSourceUrl
        showSingleSourceSearch = true
    }
}
