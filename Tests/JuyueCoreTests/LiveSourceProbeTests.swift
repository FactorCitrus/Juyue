import XCTest
@testable import JuyueCore

/// 临时探针：用橘阅真实引擎验证 yuancang 候选书源。
final class LiveSourceProbeTests: XCTestCase {
    func testProbeCandidates() async throws {
        let dir = ProcessInfo.processInfo.environment["SOURCE_DIR"] ?? "/tmp/yc-norm"
        // 本地探针，CI 与干净的机器上没有这个目录，跳过而不是判失败。
        guard FileManager.default.fileExists(atPath: dir) else {
            throw XCTSkip("探针目录不存在：\(dir)")
        }
        let keys = (ProcessInfo.processInfo.environment["PROBE_KEYS"] ?? "斗破苍穹,凡人修仙传,诡秘之主")
            .split(separator: ",").map(String.init)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".json") }
            .sorted()

        var report: [[String: Any]] = []
        for file in files {
            let path = (dir as NSString).appendingPathComponent(file)
            guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: raw),
                  let json = Self.sourceJSON(from: object),
                  let data = json.data(using: .utf8),
                  let sources = try? JSONDecoder().decode([BookSource].self, from: data) else {
                report.append(["file": file, "error": "decode"])
                continue
            }
            for source in sources {
                var entry: [String: Any] = [
                    "file": file,
                    "name": source.bookSourceName,
                    "url": source.bookSourceUrl,
                ]
                var allNames: [String] = []
                var chosen: SearchBook?
                var chosenKey = ""
                for key in keys {
                    let started = Date()
                    do {
                        let books = try await BookSearchService.shared.search(source: source, key: key, page: 1)
                        entry["searchCount"] = max(entry["searchCount"] as? Int ?? 0, books.count)
                        entry["searchMs"] = Int(Date().timeIntervalSince(started) * 1000)
                        let names = books.prefix(10).map { "\($0.name) / \($0.author)" }
                        if !names.isEmpty { allNames.append("[\(key)] " + names.joined(separator: " ; ")) }
                        if chosen == nil, let hit = books.first(where: { $0.name.trimmingCharacters(in: .whitespaces) == key && ($0.author.contains("天蚕土豆") || key == "诡秘之主") })
                            ?? books.first(where: { $0.name.contains(key) }) {
                            chosen = hit
                            chosenKey = key
                        }
                        if chosen != nil { break }
                    } catch {
                        entry["error"] = error.localizedDescription
                        break
                    }
                }
                entry["names"] = allNames
                if let first = chosen {
                    entry["chosenKey"] = chosenKey
                    entry["chosen"] = "\(first.name) / \(first.author) / \(first.bookUrl)"
                    let book = Book(
                        bookUrl: first.bookUrl, name: first.name, author: first.author,
                        origin: first.origin, originName: first.originName
                    )
                    if let detail = try? await BookContentService.shared.fetchBookDetail(
                        book: book, source: source, includeChapters: true
                    ) {
                        entry["chapters"] = detail.chapters.count
                        let probeIndex = detail.chapters.count > 2 ? detail.chapters.count / 3 : 0
                        if detail.chapters.indices.contains(probeIndex) {
                            let chapter = detail.chapters[probeIndex]
                            entry["firstChapter"] = chapter.title
                            if let text = try? await BookContentService.shared.fetchChapterContent(
                                chapter: chapter, source: source, book: detail.book
                            ) {
                                entry["contentLength"] = text.count
                                entry["contentSample"] = String(text.prefix(80))
                            }
                        }
                    }
                }
                report.append(entry)
                print("PROBE \(entry)")
            }
        }

        let out = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROBE_OUT"] ?? "/tmp/yc-probe-report3.json"))
    }

    /// 临时：复现「正文里出现 JS 解码脚本」的书源。
    func testProbeAntiScrapeContent() async throws {
        let path = "/Volumes/APFS/legado-baidu/book-sources/橘阅精选书源-免费可读-2026-11-03.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let sources = try JSONDecoder().decode([BookSource].self, from: data)
        let key = ProcessInfo.processInfo.environment["PROBE_BOOK"] ?? "带着MC系统到中土"

        for source in sources {
            guard let books = try? await BookSearchService.shared.search(source: source, key: key, page: 1),
                  let hit = books.first(where: { $0.name.contains(key) }) ?? books.first else {
                print("PROBE \(source.bookSourceName): 无结果")
                continue
            }
            let book = Book(
                bookUrl: hit.bookUrl, name: hit.name, author: hit.author,
                origin: hit.origin, originName: hit.originName
            )
            guard let detail = try? await BookContentService.shared.fetchBookDetail(
                book: book, source: source, includeChapters: true
            ), !detail.chapters.isEmpty else {
                print("PROBE \(source.bookSourceName): 详情失败")
                continue
            }
            let chapter = detail.chapters[min(85, detail.chapters.count - 1)]
            let text = (try? await BookContentService.shared.fetchChapterContent(
                chapter: chapter, source: source, book: detail.book
            )) ?? ""
            print("PROBE \(source.bookSourceName) 章=\(chapter.title) 长度=\(text.count) url=\(chapter.url)")
            print("PROBE 正文头=\(String(text.prefix(1200)))")
            print("PROBE 正文尾=\(String(text.suffix(200)))")
        }
    }

    private static func sourceJSON(from object: Any) -> String? {        if let array = object as? [[String: Any]] {
            return (try? JSONSerialization.data(withJSONObject: array)).flatMap { String(data: $0, encoding: .utf8) }
        }
        if let envelope = object as? [String: Any],
           let content = envelope["data"] as? [String: Any],
           let json = content["content"] as? String {
            return json
        }
        return nil
    }
}
