import Foundation

/// 高频内存更新 → 合并落盘。
///
/// 调用方在内存里改完就 `schedule`，连续改动只会在静默 `delay` 秒后写一次。
/// 所有编码和写入都走同一条串行队列；generation 保证旧快照不会覆盖新快照：
/// 队列里任何一个待执行的任务都只写「当前最新的值」，而且旧 generation 直接跳过。
public final class DebouncedPersistenceWriter<Value> {
    public typealias Encoder = (Value) -> Data?
    public typealias Sink = (Data) -> Void

    private let queue: DispatchQueue
    private let encode: Encoder
    private let sink: Sink
    private let lock = NSLock()

    private var pendingItem: DispatchWorkItem?
    private var latestValue: Value?
    private var latestGeneration = 0
    private var writtenGeneration = 0
    private var writeCountStorage = 0

    /// - Parameters:
    ///   - queue: 必须是串行队列，写入顺序由它保证。
    ///   - encode: 在队列上执行，可以放心做 JSON 编码。
    ///   - sink: 拿到编码结果后真正落盘（例如 UserDefaults）。
    public init(queue: DispatchQueue = DispatchQueue(label: "debounced.persistence", qos: .utility),
                encode: @escaping Encoder,
                sink: @escaping Sink) {
        self.queue = queue
        self.encode = encode
        self.sink = sink
    }

    /// 实际写入磁盘的次数，测试用。
    public var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeCountStorage
    }

    /// 记下最新值。`delay` 秒内没有新的 schedule 才真正写盘。
    public func schedule(_ value: Value, delay: TimeInterval = 0.8) {
        lock.lock()
        latestValue = value
        latestGeneration += 1
        lock.unlock()

        pendingItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.drainIfNeeded()
        }
        pendingItem = item
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: item)
    }

    /// 立刻把最新值写盘。退出阅读、进后台时调用，保证不丢最后一次进度。
    public func flush() {
        pendingItem?.cancel()
        pendingItem = nil
        queue.sync {
            self.drainIfNeeded()
        }
    }

    /// 结构性修改（增删书、换源、导入、恢复）用这个：立刻落盘，
    /// 并作废之前挂起的旧快照，避免后台的旧值晚一步盖掉新结构。
    public func writeNow(_ value: Value) {
        lock.lock()
        latestValue = value
        latestGeneration += 1
        lock.unlock()

        pendingItem?.cancel()
        pendingItem = nil
        queue.sync {
            self.drainIfNeeded()
        }
    }

    private func drainIfNeeded() {
        lock.lock()
        guard let value = latestValue, latestGeneration > writtenGeneration else {
            lock.unlock()
            return
        }
        let generation = latestGeneration
        lock.unlock()

        guard let data = encode(value) else { return }
        sink(data)

        lock.lock()
        writtenGeneration = max(writtenGeneration, generation)
        writeCountStorage += 1
        lock.unlock()
    }
}
