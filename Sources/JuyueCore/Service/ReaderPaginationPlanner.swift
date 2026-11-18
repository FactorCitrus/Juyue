import Foundation

/// 阅读页分页的布局版本，以及「哪些章还没按当前布局排过」。
///
/// 排版参数（字号、行距、边距……）每次变化就推进一个版本号。章节分页完成后
/// 记下当时的版本；版本对不上就是脏章，等真正切到 / 预取到这一章时再重排。
/// 纯值类型，不碰 CoreText，方便单测。
public struct PaginationLayoutTracker: Equatable, Sendable {
    /// 当前布局版本。每次排版参数变化都会 +1。
    public private(set) var layoutVersion: Int
    /// 章节下标 → 这份 pages 是按哪个布局版本排出来的。
    private var paginatedVersions: [Int: Int]

    public init(layoutVersion: Int = 0, paginatedVersions: [Int: Int] = [:]) {
        self.layoutVersion = layoutVersion
        self.paginatedVersions = paginatedVersions
    }

    /// 排版参数变了：推进版本，所有旧分页自动变脏。返回新版本号。
    @discardableResult
    public mutating func advanceLayout() -> Int {
        layoutVersion += 1
        return layoutVersion
    }

    public func paginatedVersion(of chapterIndex: Int) -> Int? {
        paginatedVersions[chapterIndex]
    }

    public func isDirty(_ chapterIndex: Int) -> Bool {
        paginatedVersions[chapterIndex] != layoutVersion
    }

    /// 后台任务算完回来时先过这一关：版本已经翻篇的结果直接丢掉。
    public func acceptsResult(version: Int) -> Bool {
        version == layoutVersion
    }

    /// 记录某一章已经按 `version` 排好。旧版本的结果不能把章洗白。
    public mutating func markPaginated(_ chapterIndex: Int, version: Int) {
        guard version == layoutVersion else { return }
        paginatedVersions[chapterIndex] = version
    }

    public mutating func forget(_ chapterIndex: Int) {
        paginatedVersions.removeValue(forKey: chapterIndex)
    }

    public mutating func forgetAll() {
        paginatedVersions.removeAll()
    }

    /// 给定候选章节，按原顺序挑出还没按当前布局排过的。
    public func dirtyChapters(in candidates: [Int]) -> [Int] {
        candidates.filter { isDirty($0) }
    }

    /// 布局变化后立刻重排的章节：当前章优先，其次是预取邻居。
    /// 只保留 `available` 里真的在缓存中的章；重复的邻居只排一次。
    public func repaginationPriority(current: Int, neighbors: [Int], available: [Int]) -> [Int] {
        let availableSet = Set(available)
        var result: [Int] = []
        for index in [current] + neighbors
        where availableSet.contains(index) && !result.contains(index) {
            result.append(index)
        }
        return result
    }
}
