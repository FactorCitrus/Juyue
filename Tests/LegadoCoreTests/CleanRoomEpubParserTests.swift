import XCTest
@testable import LegadoCore

final class CleanRoomEpubParserTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - 夹具

    private func write(_ body: String, to relativePath: String) throws {
        let url = workspace.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeEPUB(nav: Bool, ncx: Bool, extraChapter: Bool = false) throws -> URL {
        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """, to: "META-INF/container.xml")

        var manifest = """
          <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
          <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
        """
        if nav {
            manifest += """
              <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            """
        }
        if ncx {
            manifest += """
              <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            """
        }
        if extraChapter {
            manifest += """
              <item id="c3" href="text/ch3.xhtml" media-type="application/xhtml+xml"/>
            """
        }

        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>测试书</dc:title>
            <dc:creator>测试作者</dc:creator>
            <dc:description>简介文本</dc:description>
          </metadata>
          <manifest>
        \(manifest)
          </manifest>
          <spine>
            <itemref idref="c1"/>
            <itemref idref="c2"/>
          </spine>
        </package>
        """, to: "OEBPS/content.opf")

        if nav {
            try write("""
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <body>
              <nav epub:type="toc"><ol>
                <li><a href="text/ch1.xhtml">第一章</a></li>
                <li><a href="text/ch2.xhtml#sec">第二章</a></li>
              </ol></nav>
            </body></html>
            """, to: "OEBPS/nav.xhtml")
        }

        if ncx {
            try write("""
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <navMap>
                <navPoint id="p1"><navLabel><text>序章</text></navLabel><content src="text/ch1.xhtml"/></navPoint>
                <navPoint id="p2"><navLabel><text>第一章</text></navLabel><content src="text/ch2.xhtml"/></navPoint>
              </navMap>
            </ncx>
            """, to: "OEBPS/toc.ncx")
        }

        try write("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
          <h1>第一章</h1>
          <p>正文第一段。</p>
          <p>第二段<br/>换行后。</p>
          <img src="../images/pic.png" alt="插图"/>
        </body></html>
        """, to: "OEBPS/text/ch1.xhtml")

        try write("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
          <div id="chapterA"><h1>第二章</h1><p id="sec">锚点内容。</p></div>
          <div id="chapterB"><p>后面的章节。</p></div>
        </body></html>
        """, to: "OEBPS/text/ch2.xhtml")

        let imageURL = workspace.appendingPathComponent("OEBPS/images/pic.png")
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        if extraChapter {
            let bulk = String(repeating: "锚点长段落。", count: 25)
            let paragraphs = (0..<5).map { _ in "<p>\(bulk)</p>" }.joined()
            try write("""
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
              <div id="bulk">\(paragraphs)</div>
              <div id="chapterZ"><p>不该出现的内容。</p></div>
            </body></html>
            """, to: "OEBPS/text/ch3.xhtml")
        }

        return workspace.appendingPathComponent("book.epub")
    }

    private func parse(_ epubURL: URL) throws -> ParsedEpub {
        try EpubParser().parse(epubUrl: epubURL, destinationDir: workspace)
    }

    // MARK: - 目录

    func testNavParsingMetadataAndURLs() throws {
        let parsed = try parse(makeEPUB(nav: true, ncx: false))

        XCTAssertEqual(parsed.book.name, "测试书")
        XCTAssertEqual(parsed.book.author, "测试作者")
        XCTAssertEqual(parsed.book.intro, "简介文本")
        XCTAssertEqual(parsed.book.kind, "EPUB 本地书籍")
        XCTAssertEqual(parsed.book.origin, "local")
        XCTAssertEqual(parsed.book.originName, "本地导入")
        XCTAssertEqual(parsed.book.totalChapterNum, 2)
        XCTAssertTrue(parsed.book.tocUrl.hasSuffix("OEBPS/content.opf"))

        XCTAssertEqual(parsed.chapters.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(parsed.chapters.map(\.index), [0, 1])
        XCTAssertTrue(parsed.chapters[0].url.hasSuffix("OEBPS/text/ch1.xhtml"))
        XCTAssertTrue(parsed.chapters[1].url.hasSuffix("OEBPS/text/ch2.xhtml#sec"))
        XCTAssertTrue(parsed.chapters.allSatisfy { $0.bookUrl == parsed.book.bookUrl })
    }

    func testNCXFallback() throws {
        let parsed = try parse(makeEPUB(nav: false, ncx: true))
        XCTAssertEqual(parsed.chapters.map(\.title), ["序章", "第一章"])
        XCTAssertTrue(parsed.chapters[0].url.hasSuffix("OEBPS/text/ch1.xhtml"))
    }

    func testSpineFallbackUsesFileNames() throws {
        let parsed = try parse(makeEPUB(nav: false, ncx: false))
        XCTAssertEqual(parsed.chapters.map(\.title), ["ch1", "ch2"])
        XCTAssertEqual(parsed.chapters.map(\.index), [0, 1])
    }

    func testMissingContainerThrowsCodeOne() throws {
        let destination = workspace.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        XCTAssertThrowsError(try EpubParser().parse(
            epubUrl: workspace.appendingPathComponent("missing.epub"),
            destinationDir: destination
        )) { error in
            XCTAssertEqual((error as NSError).code, 1)
        }
    }

    func testMissingRootfileThrowsCodeTwo() throws {
        try write("<container><rootfiles></rootfiles></container>", to: "bad/META-INF/container.xml")
        let destination = workspace.appendingPathComponent("bad", isDirectory: true)
        XCTAssertThrowsError(try EpubParser().parse(
            epubUrl: workspace.appendingPathComponent("bad.epub"),
            destinationDir: destination
        )) { error in
            XCTAssertEqual((error as NSError).code, 2)
        }
    }

    // MARK: - 正文

    func testChapterTextBreakAndImage() throws {
        let parsed = try parse(makeEPUB(nav: true, ncx: false))
        let content = EpubParser.extractChapterContent(fromUrlString: parsed.chapters[0].url)

        XCTAssertTrue(content.contains("正文第一段。"), content)
        XCTAssertTrue(content.contains("换行后。"), content)
        XCTAssertTrue(content.contains("[image:"), content)
        XCTAssertTrue(content.contains("images/pic.png"), content)
        XCTAssertFalse(content.contains("锚点内容。"), content)
    }

    func testAnchorStopsAtNextChapterSection() throws {
        let parsed = try parse(makeEPUB(nav: true, ncx: false))
        let content = EpubParser.extractChapterContent(
            fromUrlString: parsed.chapters[1].url,
            bookUrl: parsed.book.bookUrl
        )

        XCTAssertTrue(content.contains("锚点内容。"), content)
        XCTAssertFalse(content.contains("后面的章节。"), content)
    }

    func testEncodedHashStillResolvesAnchor() throws {
        let parsed = try parse(makeEPUB(nav: true, ncx: false))
        let encoded = parsed.chapters[1].url.replacingOccurrences(of: "#", with: "%23")
        let content = EpubParser.extractChapterContent(fromUrlString: encoded)
        XCTAssertTrue(content.contains("锚点内容。"), content)
    }

    func testLargeAnchorContainerReturnsDirectText() throws {
        let parsed = try parse(makeEPUB(nav: true, ncx: false, extraChapter: true))
        let url = workspace.appendingPathComponent("OEBPS/text/ch3.xhtml").absoluteString + "#bulk"
        let content = EpubParser.extractChapterContent(fromUrlString: url)

        XCTAssertTrue(content.contains("锚点长段落。"), content)
        XCTAssertFalse(content.contains("不该出现的内容。"), content)
    }

    func testVolumeIntroStopsAtChapterHeading() throws {
        try write("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
          <p>卷导读。</p>
          <div class="chaptertitle">卷标题</div>
          <div id="chapterOne"><p>正文内容。</p></div>
        </body></html>
        """, to: "text/intro.xhtml")
        let url = workspace.appendingPathComponent("text/intro.xhtml").absoluteString
        let content = EpubParser.extractChapterContent(fromUrlString: url)

        XCTAssertTrue(content.contains("卷导读。"), content)
        XCTAssertTrue(content.contains("分卷导读"), content)
        XCTAssertFalse(content.contains("正文内容。"), content)
    }

    func testMissingChapterFileReturnsEmpty() {
        XCTAssertEqual(
            EpubParser.extractChapterContent(fromUrlString: workspace.appendingPathComponent("nope.xhtml").absoluteString),
            ""
        )
    }
}
