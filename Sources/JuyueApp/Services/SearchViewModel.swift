import Foundation
#if canImport(JuyueCore)
import JuyueCore
#endif

public class SearchViewModel: ObservableObject {
    public static let shared = SearchViewModel()

    @Published public var searchQuery: String = ""
    @Published public var isSearching: Bool = false
    @Published public var isLoadingMore: Bool = false
    @Published public var isPaused: Bool = false
    @Published public var currentPage: Int = 1
    @Published public var hasMore: Bool = true
    /// 空集合表示搜全部可搜源；否则只搜选中的这些。
    @Published public var selectedSourceUrls: Set<String> = [] {
        didSet { persistOptions() }
    }
    @Published public var history: [String] = []

    @Published public var groupFilter: String? = nil {
        didSet { persistOptions() }
    }
    @Published public var matchField: SourceMatchRules.SearchField = .either {
        didSet { persistOptions() }
    }
    @Published public var exactMatch: Bool = false {
        didSet { persistOptions() }
    }

    @Published private var allResults: [SearchBook] = []
    /// 上一次真正搜过的词；过滤按它算，输入框改动不立刻影响结果。
    private var lastQuery = ""

    private var exhaustedSourceUrls: Set<String> = []
    private var reportedSourceUrls: Set<String> = []
    private var seenBookIds: Set<String> = []
    private var currentSearchTask: Task<Void, Never>?
    private var pausedWasInitial = false
    private var pausedPage = 1
    private var pausedCountBefore = 0

    private enum PreferenceKey {
        static let history = "search_history_v1"
        static let options = "search_options_v1"
        static let historyLimit = 20
    }

    private struct StoredOptions: Codable {
        var sources: [String]?
        var group: String?
        var field: String = SourceMatchRules.SearchField.either.rawValue
        var exact: Bool = false
    }

    public init() {
        history = UserDefaults.standard.stringArray(forKey: PreferenceKey.history) ?? []
        guard let data = UserDefaults.standard.data(forKey: PreferenceKey.options),
              let stored = try? JSONDecoder().decode(StoredOptions.self, from: data) else {
            return
        }
        selectedSourceUrls = Set(stored.sources ?? [])
        groupFilter = stored.group
        matchField = SourceMatchRules.SearchField(rawValue: stored.field) ?? .either
        exactMatch = stored.exact
    }

    // MARK: - 结果

    public var searchResults: [SearchBook] {
        let keyword = lastQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = keyword.isEmpty
            ? allResults
            : allResults.filter {
                SourceMatchRules.matchesKeyword($0, keyword: keyword, field: matchField, exact: exactMatch)
            }

        let ranks = SourceRanking.build(from: BookStore.shared.sources)
        return filtered.enumerated()
            .sorted { left, right in
                SourceRanking.isOrderedBefore(
                    left.element,
                    offset: left.offset,
                    right.element,
                    offset: right.offset,
                    ranks: ranks
                )
            }
            .map(\.element)
    }

    public var hiddenByFilterCount: Int {
        max(0, allResults.count - searchResults.count)
    }

    public var optionsSummary: String {
        let fieldLabel: String
        switch matchField {
        case .title: fieldLabel = "书名"
        case .author: fieldLabel = "作者"
        case .either: fieldLabel = "书名或作者"
        }

        var pieces = ["\(fieldLabel)·\(exactMatch ? "精确" : "包含")"]
        if let group = groupFilter, !group.isEmpty {
            pieces.append("分组「\(group)」")
        }
        if !selectedSourceUrls.isEmpty {
            pieces.append("限定 \(selectedSourceUrls.count) 个源")
        }
        pieces.append("\(availableSources.count) 个源")
        return pieces.joined(separator: " · ")
    }

    // MARK: - 选项持久化

    private func persistOptions() {
        let stored = StoredOptions(
            sources: Array(selectedSourceUrls),
            group: groupFilter,
            field: matchField.rawValue,
            exact: exactMatch
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: PreferenceKey.options)
    }

    public func rememberQuery(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        history.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        history.insert(query, at: 0)
        if history.count > PreferenceKey.historyLimit {
            history = Array(history.prefix(PreferenceKey.historyLimit))
        }
        UserDefaults.standard.set(history, forKey: PreferenceKey.history)
    }

    public func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: PreferenceKey.history)
    }

    // MARK: - 源范围

    public var searchableSources: [BookSource] {
        let enabled = BookStore.shared.sources.filter {
            $0.enabled != false && $0.searchUrl != nil
        }
        return SourceMatchRules.filterSources(enabled, nameFilter: "", group: groupFilter)
    }

    public var availableSources: [BookSource] {
        let all = searchableSources
        guard !selectedSourceUrls.isEmpty else { return all }
        return all.filter { selectedSourceUrls.contains($0.bookSourceUrl) }
    }

    public var availableGroups: [String] {
        let labels = BookStore.shared.sources
            .filter { $0.enabled != false && $0.searchUrl != nil }
            .compactMap { $0.bookSourceGroup?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(labels)).sorted()
    }

    public var targetSources: [BookSource] {
        availableSources
    }

    // MARK: - 搜索流程

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
        let keyword = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }

        rememberQuery(keyword)
        cancelAndReset()
        lastQuery = keyword
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
        run(sources: sources, keyword: keyword, page: 1, initial: true, existingCount: 0)
    }

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

    public func resumeSearch() {
        guard isPaused else { return }

        let keyword = lastQuery.trimmingCharacters(in: .whitespaces)
        let remaining = targetSources.filter {
            !reportedSourceUrls.contains($0.bookSourceUrl)
        }
        isPaused = false

        guard !keyword.isEmpty, !remaining.isEmpty else {
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
        run(
            sources: remaining,
            keyword: keyword,
            page: pausedPage,
            initial: pausedWasInitial,
            existingCount: pausedCountBefore
        )
    }

    public func shouldAutoLoadMore(for item: SearchBook) -> Bool {
        guard !isSearching, !isLoadingMore, !isPaused, hasMore else { return false }
        guard let index = searchResults.firstIndex(where: { $0.id == item.id }) else { return false }
        return index >= searchResults.count - 3
    }

    public func loadNextPage() {
        guard !isSearching, !isLoadingMore, !isPaused, hasMore else { return }

        let keyword = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }

        let sources = targetSources.filter {
            !exhaustedSourceUrls.contains($0.bookSourceUrl)
        }
        guard !sources.isEmpty else {
            hasMore = false
            return
        }

        isLoadingMore = true
        let page = currentPage + 1
        let existingCount = allResults.count
        reportedSourceUrls.removeAll()
        AppLog.write("[搜索] 加载第 \(page) 页")
        run(sources: sources, keyword: keyword, page: page, initial: false, existingCount: existingCount)
    }

    private func run(
        sources: [BookSource],
        keyword: String,
        page: Int,
        initial: Bool,
        existingCount: Int
    ) {
        currentSearchTask = Task {
            let stream = BookSearchService.shared.searchMultiSources(
                sources: sources,
                key: keyword,
                page: page
            )

            for await (source, books) in stream {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.reportedSourceUrls.insert(source.bookSourceUrl)
                    if books.isEmpty {
                        self.exhaustedSourceUrls.insert(source.bookSourceUrl)
                    } else {
                        self.merge(books)
                    }
                }
            }

            if Task.isCancelled { return }
            await MainActor.run {
                self.finish(page: page, initial: initial, existingCount: existingCount)
            }
        }
    }

    private func finish(page: Int, initial: Bool, existingCount: Int) {
        currentSearchTask = nil

        if initial {
            isSearching = false
            currentPage = 1
            let sourceCount = targetSources.count
            hasMore = reportedSourceUrls.count < sourceCount && !allResults.isEmpty
        } else {
            isLoadingMore = false
            currentPage = page
            let grew = allResults.count > existingCount
            let remaining = targetSources.filter {
                !exhaustedSourceUrls.contains($0.bookSourceUrl)
            }
            hasMore = !remaining.isEmpty && grew
        }

        AppLog.write("[搜索] 第 \(page) 页完成 结果=\(allResults.count) 本，无结果源=\(exhaustedSourceUrls.count) 个")
    }

    private func merge(_ books: [SearchBook]) {
        var fresh: [SearchBook] = []
        for book in books where !seenBookIds.contains(book.id) {
            seenBookIds.insert(book.id)
            fresh.append(book)
        }
        allResults.append(contentsOf: fresh)
    }
}

// MARK: - 书源排序

private enum SourceRanking {
    struct Rank {
        let weight: Int
        let latency: Int64
        let position: Int
    }

    static func build(from sources: [BookSource]) -> [String: Rank] {
        var table: [String: Rank] = [:]
        for (position, source) in sources.enumerated() {
            let rank = Rank(
                weight: source.weight ?? 0,
                latency: source.respondTime ?? Int64.max,
                position: position
            )
            table[source.bookSourceUrl] = rank
            table[source.bookSourceName] = rank
        }
        return table
    }

    static func isOrderedBefore(
        _ left: SearchBook,
        offset leftOffset: Int,
        _ right: SearchBook,
        offset rightOffset: Int,
        ranks: [String: Rank]
    ) -> Bool {
        let leftRank = ranks[left.origin] ?? ranks[left.originName] ?? Rank(weight: 0, latency: Int64.max, position: leftOffset)
        let rightRank = ranks[right.origin] ?? ranks[right.originName] ?? Rank(weight: 0, latency: Int64.max, position: rightOffset)

        if leftRank.weight != rightRank.weight {
            return leftRank.weight > rightRank.weight
        }
        if leftRank.latency != rightRank.latency {
            return leftRank.latency < rightRank.latency
        }
        return leftRank.position < rightRank.position
    }
}
