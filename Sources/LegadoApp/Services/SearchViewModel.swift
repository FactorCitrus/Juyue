import Foundation
#if canImport(LegadoCore)
import LegadoCore
#endif

public class SearchViewModel: ObservableObject {
    public static let shared = SearchViewModel()

    @Published public var searchQuery: String = ""
    @Published public var searchResults: [SearchBook] = []
    @Published public var isSearching: Bool = false
    @Published public var isLoadingMore: Bool = false
    @Published public var currentPage: Int = 1
    @Published public var hasMore: Bool = true
    @Published public var selectedSourceUrl: String? = nil

    private var exhaustedSourceUrls: Set<String> = []
    private var seenBookIds: Set<String> = []
    private var currentSearchTask: Task<Void, Never>? = nil

    public init() {}

    public var availableSources: [BookSource] {
        BookStore.shared.sources.filter { $0.enabled != false && $0.searchUrl != nil }
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
        searchResults.removeAll()
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

        cancelAndReset()
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
                if self.exhaustedSourceUrls.count >= sources.count || self.searchResults.isEmpty {
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
        let countBeforeNextPage = searchResults.count

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
                let foundAny = self.searchResults.count > countBeforeNextPage
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
        self.searchResults.append(contentsOf: added)
    }
}
