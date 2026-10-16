import Foundation
#if canImport(LegadoCore)
import LegadoCore
#endif

public class SearchViewModel: ObservableObject {
    public static let shared = SearchViewModel()

    @Published public var searchQuery: String = ""
    @Published public var isSearching: Bool = false
    @Published public var isLoadingMore: Bool = false
    @Published public var currentPage: Int = 1
    @Published public var hasMore: Bool = true
    @Published public var selectedSourceUrl: String? = nil
    /// 最近搜索过的词，点一下就能重搜
    @Published public var history: [String] = []

    /// 搜索范围与匹配选项（跟换源面板一个路子，记住下次沿用）
    @Published public var sourceNameFilter: String = "" {
        didSet { persistOptions() }
    }
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
        return allResults.filter {
            SourceMatchRules.matchesKeyword($0, keyword: key, field: matchField, exact: exactMatch)
        }
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
        let filter = sourceNameFilter.trimmingCharacters(in: .whitespaces)
        if !filter.isEmpty { parts.append("限定「\(filter)」") }
        parts.append("\(availableSources.count) 个源")
        return parts.joined(separator: " · ")
    }

    private let historyKey = "search_history_v1"
    private let historyLimit = 20
    private let optionsKey = "search_options_v1"

    private struct StoredOptions: Codable {
        var nameFilter: String = ""
        var group: String?
        var field: String = SourceMatchRules.SearchField.either.rawValue
        var exact: Bool = false
    }

    private var exhaustedSourceUrls: Set<String> = []
    private var seenBookIds: Set<String> = []
    private var currentSearchTask: Task<Void, Never>? = nil

    public init() {
        history = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        if let data = UserDefaults.standard.data(forKey: optionsKey),
           let stored = try? JSONDecoder().decode(StoredOptions.self, from: data) {
            sourceNameFilter = stored.nameFilter
            groupFilter = stored.group
            matchField = SourceMatchRules.SearchField(rawValue: stored.field) ?? .either
            exactMatch = stored.exact
        }
    }

    private func persistOptions() {
        let stored = StoredOptions(nameFilter: sourceNameFilter,
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

    public var availableSources: [BookSource] {
        let enabled = BookStore.shared.sources.filter { $0.enabled != false && $0.searchUrl != nil }
        // 范围：限定源（源名 / 分组含这几个字）+ 指定分组
        return SourceMatchRules.filterSources(enabled, nameFilter: sourceNameFilter, group: groupFilter)
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
        if let selectedUrl = selectedSourceUrl {
            return availableSources.filter { $0.bookSourceUrl == selectedUrl }
        } else {
            return availableSources
        }
    }

    public func cancelAndReset() {
        currentSearchTask?.cancel()
        currentSearchTask = nil
        allResults.removeAll()
        seenBookIds.removeAll()
        exhaustedSourceUrls.removeAll()
        isSearching = false
        isLoadingMore = false
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
            isSearching = false
            hasMore = false
            return
        }

        currentSearchTask = Task {
            let stream = BookSearchService.shared.searchMultiSources(sources: sources, key: key, page: 1)

            for await (source, books) in stream {
                if Task.isCancelled { return }

                await MainActor.run {
                    if books.isEmpty {
                        self.exhaustedSourceUrls.insert(source.bookSourceUrl)
                    } else {
                        self.appendDeduplicated(books)
                    }
                }
            }

            if Task.isCancelled { return }

            await MainActor.run {
                self.isSearching = false
                self.currentPage = 1
                if self.exhaustedSourceUrls.count >= sources.count || self.allResults.isEmpty {
                    self.hasMore = false
                } else {
                    self.hasMore = true
                }
            }
        }
    }

    public func shouldAutoLoadMore(for item: SearchBook) -> Bool {
        guard !isSearching, !isLoadingMore, hasMore else { return false }
        guard let index = searchResults.firstIndex(where: { $0.id == item.id }) else { return false }
        return index >= searchResults.count - 3
    }

    public func loadNextPage() {
        guard !isSearching, !isLoadingMore, hasMore else { return }

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

        currentSearchTask = Task {
            let stream = BookSearchService.shared.searchMultiSources(sources: sourcesToQuery, key: key, page: nextPage)

            for await (source, books) in stream {
                if Task.isCancelled { return }

                await MainActor.run {
                    if books.isEmpty {
                        self.exhaustedSourceUrls.insert(source.bookSourceUrl)
                    } else {
                        self.appendDeduplicated(books)
                    }
                }
            }

            if Task.isCancelled { return }

            await MainActor.run {
                self.isLoadingMore = false
                self.currentPage = nextPage
                let foundAny = self.allResults.count > countBeforeNextPage
                let remainingSources = self.targetSources.filter { !self.exhaustedSourceUrls.contains($0.bookSourceUrl) }
                if remainingSources.isEmpty || !foundAny {
                    self.hasMore = false
                }
            }
        }
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
