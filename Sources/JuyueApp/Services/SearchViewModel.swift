import Foundation
#if canImport(JuyueCore)
import JuyueCore
#endif

public class SearchViewModel: ObservableObject {
    public static let shared = SearchViewModel()

    @Published public var searchQuery = ""
    @Published public var isSearching = false
    @Published public var isLoadingMore = false
    @Published public var isPaused = false
    @Published public var currentPage = 1
    @Published public var hasMore = true
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
    @Published public var exactMatch = false {
        didSet { persistOptions() }
    }

    @Published private var ledger = ResultLedger()
    private var lastQuery = ""
    private var pauseSnapshot: PauseSnapshot?
    private var currentSearchTask: Task<Void, Never>?
    private let preferences = SearchPreferences()

    private struct PauseSnapshot {
        let wasInitial: Bool
        let page: Int
        let countBefore: Int
    }

    private var allResults: [SearchBook] { ledger.books }

    public init() {
        history = preferences.history()
        guard let stored = preferences.options() else { return }
        selectedSourceUrls = Set(stored.sources ?? [])
        groupFilter = stored.group
        matchField = SourceMatchRules.SearchField(rawValue: stored.field) ?? .either
        exactMatch = stored.exact
    }

    // MARK: - 结果

    public var searchResults: [SearchBook] {
        let keyword = lastQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = keyword.isEmpty
            ? allResults
            : allResults.filter {
                SourceMatchRules.matchesKeyword($0, keyword: keyword, field: matchField, exact: exactMatch)
            }
        return SourceRanking(sources: BookStore.shared.sources).sorted(visible)
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
        preferences.saveOptions(SearchPreferences.Options(
            sources: Array(selectedSourceUrls),
            group: groupFilter,
            field: matchField.rawValue,
            exact: exactMatch
        ))
    }

    public func rememberQuery(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        var updated = history.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        updated.insert(query, at: 0)
        history = Array(updated.prefix(SearchPreferences.historyLimit))
        preferences.saveHistory(history)
    }

    public func clearHistory() {
        history = []
        preferences.clearHistory()
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
        stopCurrentTask()
        resetSearchState()
    }

    private func stopCurrentTask() {
        guard let task = currentSearchTask else { return }
        task.cancel()
        currentSearchTask = nil
    }

    private func resetSearchState() {
        ledger = ResultLedger()
        pauseSnapshot = nil
        setRunState(searching: false, loading: false, paused: false)
        currentPage = 1
        hasMore = true
    }

    private func setRunState(searching: Bool, loading: Bool, paused: Bool? = nil) {
        isSearching = searching
        isLoadingMore = loading
        if let paused { isPaused = paused }
    }

    public func startSearch() {
        let keyword = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }

        rememberQuery(keyword)
        cancelAndReset()
        lastQuery = keyword
        setRunState(searching: true, loading: false)

        let targets = targetSources
        if targets.isEmpty {
            AppLog.write("[搜索] 没有可用书源")
            setRunState(searching: false, loading: false)
            hasMore = false
            return
        }

        AppLog.write("[搜索] 开始 源=\(targets.count) 个")
        ledger.resetReported()
        run(SearchRun(sources: targets, keyword: keyword, page: 1, initial: true, existingCount: 0))
    }

    public func pauseSearch() {
        guard isSearching || isLoadingMore else { return }

        pauseSnapshot = PauseSnapshot(
            wasInitial: isSearching,
            page: isSearching ? 1 : currentPage + 1,
            countBefore: ledger.books.count
        )
        currentSearchTask?.cancel()
        currentSearchTask = nil
        isPaused = true
        isSearching = false
        isLoadingMore = false

        AppLog.write("[搜索] 已暂停 · 结果=\(ledger.books.count) 本 · 已完成源=\(ledger.reported.count)")
    }

    public func resumeSearch() {
        guard isPaused, let snapshot = pauseSnapshot else { return }

        let keyword = lastQuery.trimmingCharacters(in: .whitespaces)
        let remaining = targetSources.filter { !ledger.reported.contains($0.bookSourceUrl) }
        isPaused = false
        pauseSnapshot = nil

        guard !keyword.isEmpty, !remaining.isEmpty else {
            hasMore = false
            AppLog.write("[搜索] 继续时没有剩余书源")
            return
        }

        if snapshot.wasInitial {
            isSearching = true
        } else {
            isLoadingMore = true
        }

        AppLog.write("[搜索] 继续 · 第 \(snapshot.page) 页 · 剩余 \(remaining.count) 个源")
        run(SearchRun(
            sources: remaining,
            keyword: keyword,
            page: snapshot.page,
            initial: snapshot.wasInitial,
            existingCount: snapshot.countBefore
        ))
    }

    public func shouldAutoLoadMore(for item: SearchBook) -> Bool {
        guard !isSearching, !isLoadingMore, !isPaused, hasMore else { return false }
        let position = searchResults.firstIndex { $0.id == item.id }
        return position.map { $0 >= searchResults.count - 3 } ?? false
    }

    public func loadNextPage() {
        guard !isSearching, !isLoadingMore, !isPaused, hasMore else { return }

        let keyword = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }

        let sources = targetSources.filter { !ledger.exhausted.contains($0.bookSourceUrl) }
        guard !sources.isEmpty else {
            hasMore = false
            return
        }

        isLoadingMore = true
        let page = currentPage + 1
        let existingCount = ledger.books.count
        ledger.resetReported()
        AppLog.write("[搜索] 加载第 \(page) 页")
        run(SearchRun(
            sources: sources,
            keyword: keyword,
            page: page,
            initial: false,
            existingCount: existingCount
        ))
    }

    // MARK: - 单轮执行

    private struct SearchRun {
        let sources: [BookSource]
        let keyword: String
        let page: Int
        let initial: Bool
        let existingCount: Int
    }

    private func run(_ job: SearchRun) {
        let task = Task {
            let stream = BookSearchService.shared.searchMultiSources(
                sources: job.sources,
                key: job.keyword,
                page: job.page
            )
            await consume(stream, job: job)
        }
        currentSearchTask = task
    }

    private func consume(
        _ stream: AsyncStream<(source: BookSource, books: [SearchBook])>,
        job: SearchRun
    ) async {
        for await (source, books) in stream {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.apply(source: source, books: books)
            }
        }

        guard !Task.isCancelled else { return }
        await MainActor.run {
            self.finish(job)
        }
    }

    private func apply(source: BookSource, books: [SearchBook]) {
        ledger.noteReported(source.bookSourceUrl)
        if !books.isEmpty {
            ledger.absorb(books)
        } else {
            ledger.noteEmpty(source.bookSourceUrl)
        }
    }

    private func finish(_ job: SearchRun) {
        currentSearchTask = nil

        if job.initial {
            isSearching = false
            currentPage = 1
            hasMore = ledger.reported.count < targetSources.count && !ledger.books.isEmpty
        } else {
            isLoadingMore = false
            currentPage = job.page
            let grew = ledger.books.count > job.existingCount
            let remaining = targetSources.filter { !ledger.exhausted.contains($0.bookSourceUrl) }
            hasMore = !remaining.isEmpty && grew
        }

        AppLog.write("[搜索] 第 \(job.page) 页完成 结果=\(ledger.books.count) 本，无结果源=\(ledger.exhausted.count) 个")
    }
}

// MARK: - 结果账本

private struct ResultLedger {
    private(set) var books: [SearchBook] = []
    private(set) var exhausted: Set<String> = []
    private(set) var reported: Set<String> = []
    private var seen: Set<String> = []

    mutating func noteReported(_ sourceURL: String) {
        reported.insert(sourceURL)
    }

    mutating func noteEmpty(_ sourceURL: String) {
        exhausted.insert(sourceURL)
    }

    mutating func resetReported() {
        reported.removeAll()
    }

    mutating func absorb(_ incoming: [SearchBook]) {
        for book in incoming {
            guard seen.insert(book.id).inserted else { continue }
            books.append(book)
        }
    }
}

// MARK: - 源排序

private struct SourceRanking {
    private struct Rank {
        let weight: Int
        let latency: Int64
        let position: Int
    }

    private let table: [String: Rank]

    init(sources: [BookSource]) {
        var rows: [String: Rank] = [:]
        for (position, source) in sources.enumerated() {
            let rank = Rank(
                weight: source.weight ?? 0,
                latency: source.respondTime ?? Int64.max,
                position: position
            )
            rows[source.bookSourceUrl] = rank
            rows[source.bookSourceName] = rank
        }
        table = rows
    }

    func sorted(_ books: [SearchBook]) -> [SearchBook] {
        books.enumerated()
            .sorted { left, right in
                let a = rank(for: left.element, fallback: left.offset)
                let b = rank(for: right.element, fallback: right.offset)
                if a.weight != b.weight { return a.weight > b.weight }
                if a.latency != b.latency { return a.latency < b.latency }
                return a.position < b.position
            }
            .map(\.element)
    }

    private func rank(for book: SearchBook, fallback: Int) -> Rank {
        table[book.origin]
            ?? table[book.originName]
            ?? Rank(weight: 0, latency: Int64.max, position: fallback)
    }
}

// MARK: - 偏好

private struct SearchPreferences {
    static let historyLimit = 20

    private enum Key {
        static let history = "search_history_v1"
        static let options = "search_options_v1"
    }

    struct Options: Codable {
        var sources: [String]?
        var group: String?
        var field: String = SourceMatchRules.SearchField.either.rawValue
        var exact: Bool = false
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func history() -> [String] {
        defaults.stringArray(forKey: Key.history) ?? []
    }

    func saveHistory(_ values: [String]) {
        defaults.set(values, forKey: Key.history)
    }

    func clearHistory() {
        defaults.removeObject(forKey: Key.history)
    }

    func options() -> Options? {
        guard let data = defaults.data(forKey: Key.options) else { return nil }
        return try? JSONDecoder().decode(Options.self, from: data)
    }

    func saveOptions(_ options: Options) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        defaults.set(data, forKey: Key.options)
    }
}
