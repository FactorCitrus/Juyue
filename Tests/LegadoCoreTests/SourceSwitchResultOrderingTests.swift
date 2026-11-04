import XCTest
@testable import LegadoCore

/// 换源结果的排序、失败归因和空状态文案。
final class SourceSwitchResultOrderingTests: XCTestCase {

    // MARK: - 排序

    func testCurrentSourceSortsFirst() {
        let current = source("当前源", weight: 0)
        let other = source("热门源", weight: 99)
        let results = [
            (source: other, book: book("凡人修仙传", url: "b")),
            (source: current, book: book("凡人修仙传", url: "a"))
        ]

        let sorted = SourceSwitchResultOrdering.sorted(
            results,
            title: "凡人修仙传",
            author: "忘语",
            currentSourceUrl: current.bookSourceUrl
        )

        XCTAssertEqual(sorted.map { $0.source.bookSourceName }, ["当前源", "热门源"])
    }

    func testExactTitleBeatsContainsBeatsAuthorMatch() {
        let exact = source("S1")
        let contains = source("S2")
        let authorOnly = source("S3")
        let results = [
            (source: authorOnly, book: book("别的小说", author: "忘语", url: "c")),
            (source: contains, book: book("凡人修仙传（精校版）", author: "忘语", url: "b")),
            (source: exact, book: book("凡人修仙传", author: "忘语", url: "a"))
        ]

        let sorted = SourceSwitchResultOrdering.sorted(
            results,
            title: "凡人修仙传",
            author: "忘语",
            currentSourceUrl: nil
        )

        XCTAssertEqual(sorted.map { $0.book.bookUrl }, ["a", "b", "c"])
    }

    func testSelectionOrderBreaksMatchQualityTie() {
        let good = source("好评源", weight: 10)
        let slow = source("低权源", weight: 1)
        let results = [
            (source: slow, book: book("凡人修仙传", url: "slow")),
            (source: good, book: book("凡人修仙传", url: "good"))
        ]

        let sorted = SourceSwitchResultOrdering.sorted(
            results,
            title: "凡人修仙传",
            author: "忘语",
            currentSourceUrl: nil
        )

        XCTAssertEqual(sorted.map { $0.book.bookUrl }, ["good", "slow"])
    }

    func testSameQualityAndSourceFallsBackToBookName() {
        let only = source("唯一源")
        let results = [
            (source: only, book: book("Book B", url: "b")),
            (source: only, book: book("Book A", url: "a"))
        ]

        let sorted = SourceSwitchResultOrdering.sorted(
            results,
            title: "Book",
            author: "",
            currentSourceUrl: nil
        )

        XCTAssertEqual(sorted.map { $0.book.name }, ["Book A", "Book B"])
    }

    // MARK: - 失败归因

    func testFailureReasonClassification() {
        XCTAssertEqual(SearchSourceFailure.from(error: URLError(.timedOut)).message, "请求超时")
        XCTAssertEqual(
            SearchSourceFailure.from(error: URLError(.secureConnectionFailed)).message,
            "SSL / 证书校验失败"
        )
        XCTAssertEqual(
            SearchSourceFailure.from(error: SourceLoginRequiredError(sourceName: "某源")).message,
            "登录已失效，去书源详情重新登录"
        )
        XCTAssertEqual(SearchSourceFailure.httpStatus(502).message, "服务器返回 HTTP 502")
        XCTAssertEqual(
            SearchSourceFailure.from(error: URLError(.cannotFindHost)).message,
            "域名解析失败"
        )
    }

    func testFailureReasonNeverExposesFullURL() {
        struct RawError: LocalizedError {
            var errorDescription: String? { "failed to load https://secret.example/search?q=凡人" }
        }

        let reason = SearchSourceFailure.from(error: RawError()).message
        XCTAssertFalse(reason.contains("https://"))
        XCTAssertFalse(reason.contains("secret.example"))
    }

    func testZeroBooksWithoutFailureIsSuccess() {
        let outcome = SearchSourceOutcome(source: source("S"), books: [])
        XCTAssertFalse(outcome.didFail)
        XCTAssertNil(outcome.failure)
    }

    func testFailureSummaryDeduplicatesBySource() {
        var summary = SourceSwitchFailureSummary()
        let a = source("A")

        summary.record(source: a, failure: .network("请求超时"))
        summary.record(source: a, failure: .httpStatus(500))

        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary.entries.first?.reason, "服务器返回 HTTP 500")

        summary.record(source: source("B"), failure: .urlParseFailed(host: "b.example"))
        XCTAssertEqual(summary.count, 2)

        summary.clear(sourceUrl: a.bookSourceUrl)
        XCTAssertEqual(summary.entries.map(\.sourceName), ["B"])
    }

    // MARK: - 空状态文案

    func testEmptyStateSelection() {
        XCTAssertEqual(
            SourceSwitchEmptyState.resolve(rawResultCount: 0, failureCount: 3, sourceCount: 3),
            .allSourcesFailed(failureCount: 3)
        )
        XCTAssertEqual(
            SourceSwitchEmptyState.resolve(rawResultCount: 0, failureCount: 2, sourceCount: 5),
            .partialFailure(failureCount: 2, sourceCount: 5)
        )
        XCTAssertEqual(
            SourceSwitchEmptyState.resolve(rawResultCount: 0, failureCount: 0, sourceCount: 5),
            .noBook
        )
        XCTAssertEqual(
            SourceSwitchEmptyState.resolve(rawResultCount: 4, failureCount: 1, sourceCount: 5),
            .filteredOut(matchCount: 4)
        )
    }

    func testEmptyStateMessagesAreDistinct() {
        let allFailed = SourceSwitchEmptyState.allSourcesFailed(failureCount: 3).message
        let partial = SourceSwitchEmptyState.partialFailure(failureCount: 1, sourceCount: 3).message
        let noBook = SourceSwitchEmptyState.noBook.message

        XCTAssertNotEqual(allFailed, partial)
        XCTAssertNotEqual(partial, noBook)
        XCTAssertNotEqual(allFailed, noBook)
        XCTAssertTrue(partial.contains("1 个源请求失败"))
    }

    // MARK: - 工具

    private func source(
        _ name: String,
        weight: Int = 0,
        respondTime: Int64? = nil
    ) -> BookSource {
        BookSource(
            bookSourceUrl: "https://\(name).example",
            bookSourceName: name,
            customOrder: 0,
            respondTime: respondTime,
            weight: weight
        )
    }

    private func book(_ name: String, author: String = "忘语", url: String = "u") -> SearchBook {
        SearchBook(
            name: name,
            author: author,
            bookUrl: url,
            origin: "https://origin.example",
            originName: "测试源"
        )
    }
}
