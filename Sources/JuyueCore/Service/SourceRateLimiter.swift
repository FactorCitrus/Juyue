import Foundation

/// 书源并发率，例如 `1/1000`：在 1000 毫秒窗口里最多发起 1 次请求。
public struct SourceRateLimit: Equatable {
    public let count: Int
    public let windowMs: Int

    public init(count: Int, windowMs: Int) {
        self.count = max(1, count)
        self.windowMs = max(1, windowMs)
    }

    /// 解析失败或格式不合法时返回 nil，调用方按不限速处理。
    public static func parse(_ raw: String?) -> SourceRateLimit? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let count = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let window = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              count > 0, window > 0 else {
            return nil
        }
        return SourceRateLimit(count: count, windowMs: window)
    }
}

/// 按书源维度的滑动窗口限速器。
///
/// 只限制「发起时刻」：窗口内最多启动 count 次请求。已经在途的请求不占窗口，
/// 这样长请求不会把后来的短请求永久堵死。
public final class SourceRateLimiter {
    public static let shared = SourceRateLimiter()

    private let lock = NSLock()
    private var starts: [String: [TimeInterval]] = [:]

    public init() {}

    public func acquire(key: String, limit: SourceRateLimit?) async {
        guard let limit else { return }
        while !Task.isCancelled {
            let wait = reserve(key: key, limit: limit)
            if wait <= 0 { return }
            try? await Task.sleep(nanoseconds: UInt64(max(wait, 0.005) * 1_000_000_000))
        }
    }

    /// JS 规则里的同步 ajax 走这里。不能 await，只能阻塞当前脚本线程。
    public func acquireSync(key: String, limit: SourceRateLimit?) {
        guard let limit else { return }
        while true {
            let wait = reserve(key: key, limit: limit)
            if wait <= 0 { return }
            Thread.sleep(forTimeInterval: max(wait, 0.005))
        }
    }

    /// 返回 0 表示已占位成功；返回正数表示需要等待的秒数。
    private func reserve(key: String, limit: SourceRateLimit) -> TimeInterval {
        let now = Date().timeIntervalSinceReferenceDate
        let window = Double(limit.windowMs) / 1000.0

        lock.lock()
        defer { lock.unlock() }

        var records = starts[key] ?? []
        records.removeAll { now - $0 >= window }
        if records.count < limit.count {
            records.append(now)
            starts[key] = records
            return 0
        }
        starts[key] = records
        guard let oldest = records.first else { return 0 }
        return window - (now - oldest)
    }

    /// 清空限速记录。测试与「重置书源」用。
    public func reset() {
        lock.lock()
        starts.removeAll()
        lock.unlock()
    }
}
