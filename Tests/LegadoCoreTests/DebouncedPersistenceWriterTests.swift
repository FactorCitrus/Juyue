import XCTest
@testable import LegadoCore

/// 书架落盘防抖：连续更新合并、flush 必落盘、旧快照不覆盖新快照。
final class DebouncedPersistenceWriterTests: XCTestCase {

    private final class Recorder {
        private let lock = NSLock()
        private(set) var values: [Int] = []

        func append(_ value: Int) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var all: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }

        var last: Int? { all.last }
    }

    private func makeWriter(delay: TimeInterval = 0.05) -> (DebouncedPersistenceWriter<Int>, Recorder, DispatchQueue) {
        let queue = DispatchQueue(label: "test.debounced.\(UUID().uuidString)")
        let recorder = Recorder()
        let writer = DebouncedPersistenceWriter<Int>(
            queue: queue,
            encode: { Data("\($0)".utf8) },
            sink: { data in
                if let value = Int(String(data: data, encoding: .utf8) ?? "") {
                    recorder.append(value)
                }
            }
        )
        return (writer, recorder, queue)
    }

    func testRapidSchedulesCoalesceIntoOneWrite() {
        let (writer, recorder, queue) = makeWriter()

        for value in 0..<5 {
            writer.schedule(value, delay: 0.05)
        }

        let done = expectation(description: "settled")
        queue.asyncAfter(deadline: .now() + 0.35) {
            XCTAssertEqual(writer.writeCount, 1)
            XCTAssertEqual(recorder.last, 4)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testFlushWritesPendingValueImmediately() {
        let (writer, recorder, _) = makeWriter()

        writer.schedule(7, delay: 30)
        XCTAssertEqual(writer.writeCount, 0)

        writer.flush()
        XCTAssertEqual(writer.writeCount, 1)
        XCTAssertEqual(recorder.last, 7)

        // 已经写过，再 flush 不重复落盘
        writer.flush()
        XCTAssertEqual(writer.writeCount, 1)
    }

    func testWriteNowSupersedesPendingSnapshot() {
        let (writer, recorder, queue) = makeWriter()

        writer.schedule(1, delay: 0.02)
        writer.writeNow(2)

        XCTAssertEqual(recorder.last, 2)
        XCTAssertEqual(writer.writeCount, 1)

        // 挂起的旧快照即使计时器已经触发，也不能反过来覆盖新值
        let done = expectation(description: "stale skipped")
        queue.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(writer.writeCount, 1)
            XCTAssertEqual(recorder.last, 2)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testStructuralWritesAlwaysLand() {
        let (writer, recorder, _) = makeWriter()

        writer.writeNow(10)
        writer.writeNow(11)
        writer.writeNow(12)

        XCTAssertEqual(recorder.all, [10, 11, 12])
        XCTAssertEqual(writer.writeCount, 3)
    }

    func testFailedEncodeDoesNotAdvanceWrittenGeneration() {
        let queue = DispatchQueue(label: "test.debounced.encode")
        var attempts = 0
        let writer = DebouncedPersistenceWriter<Int>(
            queue: queue,
            encode: { value in
                attempts += 1
                return value == 0 ? nil : Data("\(value)".utf8)
            },
            sink: { _ in }
        )

        writer.writeNow(0)
        XCTAssertEqual(writer.writeCount, 0)

        writer.writeNow(1)
        XCTAssertEqual(writer.writeCount, 1)
        XCTAssertEqual(attempts, 2)
    }
}
