import XCTest
@testable import LegadoCore

/// 真实聚合源：搜一本，再抓它的目录，看失败在哪一步。
final class RealSourceTocProbe: XCTestCase {

    func testRealSourceToc() async throws {
        let path = ProcessInfo.processInfo.environment["BS_AGG"] ?? ""
        guard !path.isEmpty else { throw XCTSkip("no BS_AGG") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let source = try XCTUnwrap(try JSONDecoder().decode([BookSource].self, from: data).first)
        print("书源:", source.bookSourceName, "| 有目录规则:", source.ruleToc != nil)

        let books = (try? await BookSearchService.shared.search(source: source, key: "凡人修仙传", page: 1)) ?? []
        print("搜索结果:", books.count, "条")
        guard let first = books.first else {
            print("没有搜索结果，目录就无从谈起")
            return
        }
        print("第一本:", first.name, "|", first.bookUrl)

        let book = Book(bookUrl: first.bookUrl, name: first.name, author: first.author,
                        origin: first.origin, originName: first.originName)
        do {
            let detail = try await BookContentService.shared.fetchBookDetail(book: book, source: source)
            print("目录章节数:", detail.chapters.count)
            if let head = detail.chapters.first {
                print("首章:", head.title, "| 章节网址:", head.url.prefix(60), "...")
                let text = try await BookContentService.shared.fetchChapterContent(chapter: head, source: source)
                print("正文长度:", text.count, "| 前 80:", text.prefix(80))
            }
        } catch {
            print("目录失败:", error)
        }
    }
}
