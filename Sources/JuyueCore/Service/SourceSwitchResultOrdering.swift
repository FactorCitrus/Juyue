import Foundation

/// 换源候选的展示顺序：当前书源置顶 → 匹配质量 → 书源排序（selectionOrder）→ 书名。
/// 纯函数，不碰界面状态，方便单测。
public enum SourceSwitchResultOrdering {
    /// 数字越小越靠前：书名完全一致 > 书名包含 > 作者命中 > 其它。
    public enum MatchQuality: Int {
        case exactTitle = 0
        case titleContains = 1
        case authorMatch = 2
        case fallback = 3
    }

    public static func matchQuality(of book: SearchBook, title: String, author: String) -> MatchQuality {
        let targetTitle = SourceMatchRules.normalized(title)
        let bookTitle = SourceMatchRules.normalized(book.name)

        if !targetTitle.isEmpty {
            if bookTitle == targetTitle { return .exactTitle }
            if !bookTitle.isEmpty, bookTitle.contains(targetTitle) || targetTitle.contains(bookTitle) {
                return .titleContains
            }
        }

        let targetAuthor = SourceMatchRules.normalized(author)
        let bookAuthor = SourceMatchRules.normalized(book.author)
        if !targetAuthor.isEmpty, !bookAuthor.isEmpty,
           bookAuthor.contains(targetAuthor) || targetAuthor.contains(bookAuthor) {
            return .authorMatch
        }
        return .fallback
    }

    public static func sorted(
        _ results: [(source: BookSource, book: SearchBook)],
        title: String,
        author: String,
        currentSourceUrl: String?
    ) -> [(source: BookSource, book: SearchBook)] {
        results
            .map { item in
                (
                    item: item,
                    isCurrent: isCurrent(item.source, currentSourceUrl),
                    quality: matchQuality(of: item.book, title: title, author: author)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                if lhs.quality != rhs.quality { return lhs.quality.rawValue < rhs.quality.rawValue }

                if BookSource.selectionOrder(lhs.item.source, rhs.item.source) { return true }
                if BookSource.selectionOrder(rhs.item.source, lhs.item.source) { return false }

                let nameOrder = lhs.item.book.name.localizedStandardCompare(rhs.item.book.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }

                let sourceOrder = lhs.item.source.bookSourceName
                    .localizedStandardCompare(rhs.item.source.bookSourceName)
                if sourceOrder != .orderedSame { return sourceOrder == .orderedAscending }

                return lhs.item.book.bookUrl < rhs.item.book.bookUrl
            }
            .map { $0.item }
    }

    private static func isCurrent(_ source: BookSource, _ currentSourceUrl: String?) -> Bool {
        guard let currentSourceUrl, !currentSourceUrl.isEmpty else { return false }
        return source.bookSourceUrl == currentSourceUrl
    }
}

/// 换源结果为空时该说哪句话：全部源失败 / 部分失败没找到 / 本来就没有别的源收录 / 有结果但被条件筛掉。
public enum SourceSwitchEmptyState: Equatable {
    case allSourcesFailed(failureCount: Int)
    case partialFailure(failureCount: Int, sourceCount: Int)
    case noBook
    case filteredOut(matchCount: Int)

    public static func resolve(
        rawResultCount: Int,
        failureCount: Int,
        sourceCount: Int
    ) -> SourceSwitchEmptyState {
        if rawResultCount > 0 {
            return .filteredOut(matchCount: rawResultCount)
        }
        if failureCount > 0 && failureCount >= sourceCount {
            return .allSourcesFailed(failureCount: failureCount)
        }
        if failureCount > 0 {
            return .partialFailure(failureCount: failureCount, sourceCount: sourceCount)
        }
        return .noBook
    }

    public var title: String {
        switch self {
        case .allSourcesFailed: return "ALL NODES FAILED"
        case .partialFailure: return "PARTIAL FAILURE"
        case .noBook: return "NO SIGNAL"
        case .filteredOut: return "NO MATCH"
        }
    }

    public var message: String {
        switch self {
        case .allSourcesFailed(let failureCount):
            return "\(failureCount) 个书源全部请求失败，暂时无法确认是否收录。检查网络或稍后再试。"
        case .partialFailure(let failureCount, let sourceCount):
            let succeeded = max(0, sourceCount - failureCount)
            return "\(failureCount) 个源请求失败；其余 \(succeeded) 个源没有收录这本书。可稍后重试失败的源。"
        case .noBook:
            return "没有其他书源收录这本书。换个匹配方式或关键词再试。"
        case .filteredOut(let matchCount):
            return "搜到 \(matchCount) 条，但都不符合当前条件。放宽条件或关掉精确匹配再试。"
        }
    }
}

/// 失败源汇总：按书源 URL 去重，后到的原因覆盖先到的。
public struct SourceSwitchFailureSummary: Equatable {
    public struct Entry: Equatable, Identifiable {
        public let sourceUrl: String
        public let sourceName: String
        public let reason: String

        public var id: String { sourceUrl }

        public init(sourceUrl: String, sourceName: String, reason: String) {
            self.sourceUrl = sourceUrl
            self.sourceName = sourceName
            self.reason = reason
        }
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public mutating func record(source: BookSource, failure: SearchSourceFailure) {
        record(sourceUrl: source.bookSourceUrl, sourceName: source.bookSourceName, reason: failure.message)
    }

    public mutating func record(sourceUrl: String, sourceName: String, reason: String) {
        let entry = Entry(sourceUrl: sourceUrl, sourceName: sourceName, reason: reason)
        if let index = entries.firstIndex(where: { $0.sourceUrl == sourceUrl }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    public mutating func clear(sourceUrl: String) {
        entries.removeAll { $0.sourceUrl == sourceUrl }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
