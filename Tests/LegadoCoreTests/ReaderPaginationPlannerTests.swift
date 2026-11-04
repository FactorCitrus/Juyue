import XCTest
@testable import LegadoCore

/// 阅读页分页的布局版本 / 脏章选择。
final class ReaderPaginationPlannerTests: XCTestCase {

    func testLayoutAdvanceMarksPaginatedChaptersDirty() {
        var tracker = PaginationLayoutTracker()
        XCTAssertTrue(tracker.isDirty(3))

        tracker.markPaginated(3, version: tracker.layoutVersion)
        XCTAssertFalse(tracker.isDirty(3))

        let newVersion = tracker.advanceLayout()
        XCTAssertEqual(newVersion, 1)
        XCTAssertTrue(tracker.isDirty(3))
        XCTAssertEqual(tracker.paginatedVersion(of: 3), 0)
    }

    func testStaleVersionCannotMarkChapterClean() {
        var tracker = PaginationLayoutTracker()
        tracker.markPaginated(1, version: 0)
        tracker.advanceLayout()

        // 旧布局版本回来的结果不能把脏章洗白
        tracker.markPaginated(1, version: 0)
        XCTAssertTrue(tracker.isDirty(1))

        tracker.markPaginated(1, version: tracker.layoutVersion)
        XCTAssertFalse(tracker.isDirty(1))
    }

    func testDirtyChaptersKeepCandidateOrder() {
        var tracker = PaginationLayoutTracker()
        tracker.markPaginated(0, version: tracker.layoutVersion)
        tracker.markPaginated(2, version: tracker.layoutVersion)

        XCTAssertEqual(tracker.dirtyChapters(in: [0, 1, 2, 3]), [1, 3])
    }

    func testRepaginationPriorityPutsCurrentFirstAndDeduplicates() {
        let tracker = PaginationLayoutTracker()
        let plan = tracker.repaginationPriority(
            current: 5,
            neighbors: [4, 6],
            available: [1, 4, 5, 6, 7]
        )
        XCTAssertEqual(plan, [5, 4, 6])
    }

    func testRepaginationPrioritySkipsChaptersNotLoaded() {
        let tracker = PaginationLayoutTracker()
        let plan = tracker.repaginationPriority(
            current: 0,
            neighbors: [-1, 1],
            available: [0]
        )
        XCTAssertEqual(plan, [0])
    }

    func testForgetAndForgetAll() {
        var tracker = PaginationLayoutTracker()
        tracker.markPaginated(2, version: tracker.layoutVersion)
        tracker.markPaginated(3, version: tracker.layoutVersion)

        tracker.forget(2)
        XCTAssertNil(tracker.paginatedVersion(of: 2))
        XCTAssertTrue(tracker.isDirty(2))
        XCTAssertFalse(tracker.isDirty(3))

        tracker.forgetAll()
        XCTAssertTrue(tracker.isDirty(3))
    }

    func testAcceptsResultOnlyForCurrentVersion() {
        var tracker = PaginationLayoutTracker()
        XCTAssertTrue(tracker.acceptsResult(version: 0))
        tracker.advanceLayout()
        XCTAssertFalse(tracker.acceptsResult(version: 0))
        XCTAssertTrue(tracker.acceptsResult(version: 1))
    }
}
