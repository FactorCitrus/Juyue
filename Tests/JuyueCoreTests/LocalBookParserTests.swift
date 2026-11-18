import XCTest
@testable import JuyueCore

/// MOBI / FB2 / UMD 导入的最小样例。
/// 夹具都是手搓的最小合法结构，只验证拆章、元数据和落盘，不追求格式全覆盖。
final class LocalBookParserTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-book-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - FB2

    func testFB2SplitsSectionsAndReadsMetadata() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"
                     xmlns:l="http://www.w3.org/1999/xlink">
          <description>
            <title-info>
              <book-title>测试书</book-title>
              <author><first-name>张</first-name><last-name>三</last-name></author>
              <annotation><p>简介一段</p></annotation>
            </title-info>
          </description>
          <body>
            <section>
              <title><p>第一章</p></title>
              <p>正文一</p>
            </section>
            <section>
              <title><p>第二章</p></title>
              <p>正文二</p>
            </section>
          </body>
        </FictionBook>
        """
        let url = workspace.appendingPathComponent("sample.fb2")
        try xml.write(to: url, atomically: true, encoding: .utf8)

        let parsed = try LocalBookParser.shared.parse(
            url: url, destinationDir: workspace.appendingPathComponent("out-fb2")
        )

        XCTAssertEqual(parsed.book.name, "测试书")
        XCTAssertEqual(parsed.book.author, "张三")
        XCTAssertEqual(parsed.book.intro, "简介一段")
        XCTAssertEqual(parsed.book.kind, "FB2 本地书籍")
        XCTAssertEqual(parsed.chapters.count, 2)
        XCTAssertEqual(parsed.chapters[0].title, "第一章")

        let first = try String(contentsOf: URL(string: parsed.chapters[0].url)!, encoding: .utf8)
        XCTAssertTrue(first.contains("正文一"))
    }

    // MARK: - UMD

    func testUMDFallsBackToHeadingSplit() throws {
        let body = "第一章 起\n正文一\n第二章 承\n正文二\n"
        let url = try makeUMD(title: "测试", author: "张三", body: body)

        let parsed = try LocalBookParser.shared.parse(
            url: url, destinationDir: workspace.appendingPathComponent("out-umd")
        )

        XCTAssertEqual(parsed.book.name, "测试")
        XCTAssertEqual(parsed.book.author, "张三")
        XCTAssertEqual(parsed.book.kind, "UMD 本地书籍")
        XCTAssertEqual(parsed.chapters.count, 2)
        XCTAssertEqual(parsed.chapters[0].title, "第一章 起")
        XCTAssertTrue(parsed.chapters[1].title.contains("第二章"))

        let second = try String(contentsOf: URL(string: parsed.chapters[1].url)!, encoding: .utf8)
        XCTAssertTrue(second.contains("正文二"))
    }

    // MARK: - MOBI

    func testMOBISplitsOnPagebreak() throws {
        let text = "<html><body><h1>第一章</h1><p>正文一</p>"
            + "<mbp:pagebreak/><h1>第二章</h1><p>正文二</p></body></html>"
        let url = try makeMOBI(text: text)

        let parsed = try LocalBookParser.shared.parse(
            url: url, destinationDir: workspace.appendingPathComponent("out-mobi")
        )

        XCTAssertEqual(parsed.book.name, "Testing Book")
        XCTAssertEqual(parsed.book.kind, "MOBI 本地书籍")
        XCTAssertEqual(parsed.chapters.count, 2)
        XCTAssertEqual(parsed.chapters[0].title, "第一章")
        XCTAssertEqual(parsed.chapters[1].title, "第二章")

        let html = try String(contentsOf: URL(string: parsed.chapters[1].url)!, encoding: .utf8)
        XCTAssertTrue(html.contains("正文二"))
        XCTAssertFalse(html.contains("mbp:pagebreak"))
    }

    // MARK: - 扩展名识别

    func testImportSnifferKnowsNewBookExtensions() {
        for ext in ["mobi", "azw", "azw3", "prc", "fb2", "umd"] {
            XCTAssertTrue(ImportSniffer.bookExtensions.contains(ext), ext)
            XCTAssertTrue(DownloadLinkClassifier.downloadExtensions.contains(ext), ext)
        }
    }

    // MARK: - 夹具

    private func makeUMD(title: String, author: String, body: String) throws -> URL {
        let titleBytes = utf16LE(title)
        let authorBytes = utf16LE(author)
        let bodyBytes = utf16LE(body)

        let headerSize = 40
        let authorOffset = headerSize
        let titleOffset = authorOffset + authorBytes.count
        let contentOffset = titleOffset + titleBytes.count

        var file = [UInt8](repeating: 0, count: headerSize)
        file[0] = 0x55
        file[1] = 0xAA
        putLE32(&file, 4, authorOffset)
        file[8] = UInt8(authorBytes.count & 0xFF)
        putLE32(&file, 9, titleOffset)
        file[13] = UInt8(titleBytes.count & 0xFF)
        putLE32(&file, 14, contentOffset)
        putLE32(&file, 18, bodyBytes.count)
        // 章节偏移表留空，走标题正则回退
        putLE32(&file, 22, 0)
        putLE32(&file, 26, 0)

        file += authorBytes
        file += titleBytes
        file += bodyBytes

        let url = workspace.appendingPathComponent("sample.umd")
        try Data(file).write(to: url)
        return url
    }

    private func makeMOBI(text: String) throws -> URL {
        let textBytes = Array(text.utf8)

        // PalmDOC 16 字节 + MOBI 头 232 字节 + 书名
        var record0 = [UInt8](repeating: 0, count: 16 + 232)
        putBE16(&record0, 0, 1)              // compression: 无压缩
        putBE32(&record0, 4, textBytes.count)
        putBE16(&record0, 8, 1)              // 文本记录数
        putBE16(&record0, 10, 4096)
        putASCII(&record0, 16, "MOBI")
        putBE32(&record0, 20, 232)           // MOBI 头长度
        putBE32(&record0, 24, 2)             // type: book
        putBE32(&record0, 28, 65001)         // 编码 UTF-8
        putBE32(&record0, 32, 12345)         // unique id
        putBE32(&record0, 36, 6)             // 版本

        let nameBytes = Array("Testing Book".utf8)
        let nameOffset = record0.count
        putBE32(&record0, 100, nameOffset)
        putBE32(&record0, 104, nameBytes.count)
        putBE32(&record0, 124, 0)            // first image index
        putBE32(&record0, 144, 0)            // EXTH flags
        record0 += nameBytes

        let recordCount = 2
        let headerSize = 78 + recordCount * 8
        let record0Offset = headerSize
        let record1Offset = record0Offset + record0.count

        var file = [UInt8](repeating: 0, count: headerSize)
        putASCII(&file, 0, "testing")
        putASCII(&file, 60, "BOOKMOBI")
        putBE16(&file, 76, recordCount)
        putBE32(&file, 78, record0Offset)
        putBE32(&file, 86, record1Offset)

        file += record0
        file += textBytes

        let url = workspace.appendingPathComponent("sample.mobi")
        try Data(file).write(to: url)
        return url
    }

    private func utf16LE(_ text: String) -> [UInt8] {
        var result: [UInt8] = []
        for unit in text.utf16 {
            result.append(UInt8(unit & 0xFF))
            result.append(UInt8((unit >> 8) & 0xFF))
        }
        return result
    }

    private func putBE16(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        bytes[offset] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 1] = UInt8(value & 0xFF)
    }

    private func putBE32(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }

    private func putLE32(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func putASCII(_ bytes: inout [UInt8], _ offset: Int, _ text: String) {
        for (index, byte) in text.utf8.enumerated() {
            bytes[offset + index] = byte
        }
    }
}
