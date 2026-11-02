import Foundation
#if canImport(LegadoCore)
import LegadoCore
#endif

public class SearchViewModel: ObservableObject {
    public static let shared = SearchViewModel()

    @Published public var searchQuery: String = ""
    @Published public var isSearching: Bool = false
    @Published public var isLoadingMore: Bool = false
    @Published public var isPaused: Bool = false
    @Published public var currentPage: Int = 1
    @Published public var hasMore: Bool = true
    /// 限定源：空集合表示搜全部可搜源；否则只搜选中的这些
    @Published public var selectedSourceUrls: Set<String> = [] {
        didSet { persistOptions() }
    }
    /// 最近搜索过的词，点一下就能重搜
    @Published public var history: [String] = []

    /// 搜索范围与匹配选项（跟换源面板一个路子，记住下次沿用）
    @Published public var groupFilter: String? = nil {
        didSet { persistOptions() }
    }
    @Published public var matchField: SourceMatchRules.SearchField = .either {
        didSet { persistOptions() }
    }
    @Published public var exactMatch: Bool = false {
        didSet { persistOptions() }
    }

    /// 抓回来的原始结果（没过滤）。分页都往这里加，界面读下面的 `searchResults`。
    @Published private var allResults: [SearchBook] = []
    /// 上一次真正搜过的关键词：过滤按它算，免得用户改了输入框还没搜就把结果筛没了
    private var lastQuery = ""

    /// 界面上的结果：按匹配口径就地过滤，改选项立刻重筛，不重新联网搜。
    public var searchResults: [SearchBook] {
        let key = lastQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return allResults }
        let filtered = allResults.filter {
            SourceMatchRules.matchesKeyword($0, keyword: key, field: matchField, exact: exactMatch)
        }
        // 多源结果按书源 weight 降序、实测 respondTime 升序排；同源内保持原顺序。
        let rank = sourceRankMap()
        return filtered.enumerated().sorted { lhs, rhs in
            let l = rank[lhs.element.origin] ?? rank[lhs.element.originName] ?? (weight: 0, respond: Int64.max, order: lhs.offset)
            let r = rank[rhs.element.origin] ?? rank[rhs.element.originName] ?? (weight: 0, respond: Int64.max, order: rhs.offset)
            if l.weight != r.weight { return l.weight > r.weight }
            if l.respond != r.respond { return l.respond < r.respond }
            return l.order < r.order
        }.map(\.element)
    }

    /// 书源排序键：origin URL 为主键，源名做兼容键。
    private func sourceRankMap() -> [String: (weight: Int, respond: Int64, order: Int)] {
        var map: [String: (weight: Int, respond: Int64, order: Int)] = [:]
        for (index, source) in BookStore.shared.sources.enumerated() {
            let value = (source.weight ?? 0, source.respondTime ?? Int64.max, index)
            map[source.bookSourceUrl] = value
            map[source.bookSourceName] = value
        }
        return map
    }

    /// 有多少条被匹配口径挡掉了（给个提示，免得以为源不行）
    public var hiddenByFilterCount: Int {
        max(0, allResults.count - searchResults.count)
    }

    /// 「范围与匹配」收起时显示的一行口径
    public var optionsSummary: String {
        let field: String
        switch matchField {
        case .title: field = "书名"
        case .author: field = "作者"
        case .either: field = "书名或作者"
        }
        var parts = ["\(field)·\(exactMatch ? "精确" : "包含")"]
        if let group = groupFilter, !group.isEmpty { parts.append("分组「\(group)」") }
        if !selectedSourceUrls.isEmpty { parts.append("限定 \(selectedSourceUrls.count) 个源") }
        parts.append("\(availableSources.count) 个源")
        return parts.joined(separator: " · ")
    }

    private let historyKey = "search_history_v1"
    private let historyLimit = 20
    private let optionsKey = "search_options_v1"

    private struct StoredOptions: Codable {
        var sources: [String]?
        var group: String?
        var field: String = SourceMatchRules.SearchField.either.rawValue
        var exact: Bool = false
    }

    private var exhaustedSourceUrls: Set<String> = []
    /// 本轮搜索已经回报过的源（暂停/继续时用来跳过已完成的部分）
    private var reportedSourceUrls: Set<String> = []
    private var seenBookIds: Set<String> = []
    private var currentSearchTask: Task<Void, Never>? = nil
    /// 暂停时的现场：继续时从同一页、未回报的源接着搜
    private var pausedWasInitial = false
    private var pausedPage = 1
    private var pausedCountBefore = 0

    public init() {
        history = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        if let data = UserDefaults.standard.data(forKey: optionsKey),
           let stored = try? JSONDecoder().decode(StoredOptions.self, from: data) {
            selectedSourceUrls = Set(stored.sources ?? [])
            groupFilter = stored.group
            matchField = SourceMatchRules.SearchField(rawValue: stored.field) ?? .either
            exactMatch = stored.exact
        }
    }

    private func persistOptions() {
        let stored = StoredOptions(sources: Array(selectedSourceUrls),
                                   group: groupFilter,
                                   field: matchField.rawValue,
                                   exact: exactMatch)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: optionsKey)
        }
    }

    public func rememberQuery(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        history.removeAll { $0.caseInsensitiveCompare(key) == .orderedSame }
        history.insert(key, at: 0)
        if history.count > historyLimit { history = Array(history.prefix(historyLimit)) }
        UserDefaults.standard.set(history, forKey: historyKey)
    }

    public func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    /// 当前分组下所有可搜的源。给「限定源」列表用，不受已选源的影响。
    public var searchableSources: [BookSource] {
        let enabled = BookStore.shared.sources.filter { $0.enabled != false && $0.searchUrl != nil }
        return SourceMatchRules.filterSources(enabled, nameFilter: "", group: groupFilter)
    }

    /// 实际参与搜索的源：选了限定源就只留选中的。
    public var availableSources: [BookSource] {
        let all = searchableSources
        guard !selectedSourceUrls.isEmpty else { return all }
        return all.filter { selectedSourceUrls.contains($0.bookSourceUrl) }
    }

    /// 启用且可搜的源里出现过的分组，给「范围」下拉用
    public var availableGroups: [String] {
        let groups = BookStore.shared.sources
            .filter { $0.enabled != false && $0.searchUrl != nil }
            .compactMap { $0.bookSourceGroup?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(groups)).sorted()
    }

    public var targetSources: [BookSource] {
        availableSources
    }

    public func cancelAndReset() {
        currentSearchTask?.cancel()
        currentSearchTask = nil
        allResults.removeAll()
        seenBookIds.removeAll()
        exhaustedSourceUrls.removeAll()
        reportedSourceUrls.removeAll()
        isSearching = false
        isLoadingMore = false
        isPaused = false
        pausedWasInitial = false
        currentPage = 1
        hasMore = true
    }

    public func startSearch() {
        let key = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        rememberQuery(key)

        cancelAndReset()
        lastQuery = key
        isSearching = true

        let sources = targetSources
        guard !sources.isEmpty else {
            AppLog.write("[搜索] 没有可用书源")
            isSearching = false
            hasMore = false
            return
        }
        AppLog.write("[搜索] 开始 源=\(sources.count) 个")
        reportedSourceUrls.removeAll()
        launchSearch(sources: sources, key: key, page: 1, isInitial: true, countBefore: 0)
    }

    /// 暂停：停掉当前这一轮，只保留已经拿到的结果。
    public func pauseSearch() {
        guard isSearching || isLoadingMore else { return }
        pausedWasInitial = isSearching
        pausedPage = isSearching ? 1 : currentPage + 1
        pausedCountBefore = allResults.count
        currentSearchTask?.cancel()
        currentSearchTask = nil
        isPaused = true
        isSearching = false
        isLoadingMore = false
        AppLog.write("[搜索] 已暂停 · 结果=\(allResults.count) 本 · 已完成源=\(reportedSourceUrls.count)")
    }

    /// 继续：从暂停时那一页、还没回报的源接着搜。
    public func resumeSearch() {
        guard isPaused else { return }
        let key = lastQuery.trimmingCharacters(in: .whitespaces)
        let remaining = targetSources.filter { !reportedSourceUrls.contains($0.bookSourceUrl) }
        isPaused = false
        guard !key.isEmpty, !remaining.isEmpty else {
            hasMore = false
            AppLog.write("[搜索] 继续时没有剩余书源")
            return
        }
        if pausedWasInitial {
            isSearching = true
        } else {
            isLoadingMore = true
        }
        AppLog.write("[搜索] 继续 · 第 \(pausedPage) 页 · 剩余 \(remaining.count) 个源")
        launchSearch(sources: remaining,
                     key: key,
                     page: pausedPage,
                     isInitial: pausedWasInitial,
                     countBefore: pausedCountBefore)
    }

    private func launchSearch(sources: [BookSource], key: String, page: Int, isInitial: Bool, countBefore: Int) {
        currentSearchTask = Task {
            let stream = BookSearchService.shared.searchMultiSources(sources: sources, key: key, page: page)

            for await (source, books) in stream {
                if Task.isCancelled { return }

                await MainActor.run {
                    self.reportedSourceUrls.insert(source.bookSourceUrl)
                    if books.isEmpty {
                        self.exhaustedSourceUrls.insert(source.bookSourceUrl)
                    } else {
                        self.appendDeduplicated(books)
                    }
                }
            }

            if Task.isCancelled { return }

            await MainActor.run {
                self.currentSearchTask = nil
                if isInitial {
                    self.isSearching = false
                    self.currentPage = 1
                    self.hasMore = self.reportedSourceUrls.count < self.targetSources.count && !self.allResults.isEmpty
                } else {
                    self.isLoadingMore = false
                    self.currentPage = page
                    let foundAny = self.allResults.count > countBefore
                    let remaining = self.targetSources.filter {
                        !self.exhaustedSourceUrls.contains($0.bookSourceUrl)
                    }
                    self.hasMore = remaining.isEmpty == false && foundAny
                }
                AppLog.write("[搜索] 第 \(page) 页完成 结果=\(self.allResults.count) 本，无结果源=\(self.exhaustedSourceUrls.count) 个")
            }
        }
    }

    public func shouldAutoLoadMore(for item: SearchBook) -> Bool {
        guard !isSearching, !isLoadingMore, !isPaused, hasMore else { return false }
        guard let index = searchResults.firstIndex(where: { $0.id == item.id }) else { return false }
        return index >= searchResults.count - 3
    }

    public func loadNextPage() {
        guard !isSearching, !isLoadingMore, !isPaused, hasMore else { return }

        let key = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }

        let sourcesToQuery = targetSources.filter { !exhaustedSourceUrls.contains($0.bookSourceUrl) }
        guard !sourcesToQuery.isEmpty else {
            hasMore = false
            return
        }

        isLoadingMore = true
        let nextPage = currentPage + 1
        let countBeforeNextPage = allResults.count
        reportedSourceUrls.removeAll()
        AppLog.write("[搜索] 加载第 \(nextPage) 页")
        launchSearch(sources: sourcesToQuery,
                     key: key,
                     page: nextPage,
                     isInitial: false,
                     countBefore: countBeforeNextPage)
    }

    private func appendDeduplicated(_ newBooks: [SearchBook]) {
        var added: [SearchBook] = []
        for book in newBooks {
            if !seenBookIds.contains(book.id) {
                seenBookIds.insert(book.id)
                added.append(book)
            }
        }
        self.allResults.append(contentsOf: added)
    }
}
