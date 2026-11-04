import XCTest
import ZIPFoundation
@testable import LegadoCore

final class ImportDownloadSupportTests: XCTestCase {
    private let bookSourceJSON = #"{"bookSourceUrl":"https://a.example","bookSourceName":"A","searchUrl":"https://a.example/s?q={{key}}"}"#
    private let secondBookSourceJSON = #"{"bookSourceUrl":"https://b.example","bookSourceName":"B"}"#
    private let ruleJSON = #"{"name":"去广告","pattern":"广告","replacement":""}"#
    private let secondRuleJSON = #"{"pattern":"推广","replacement":"","isRegex":true}"#
    private let rssJSON = #"{"sourceUrl":"https://rss.example","sourceName":"RSS","ruleArticles":"class.list@li","ruleLink":"tag.a@href"}"#

    // MARK: - 导入嗅探

    func testMixedArraySniffing() throws {
        let json = "[\(bookSourceJSON),\(ruleJSON),\(rssJSON)]"
        let result = ImportSniffer.scanJSON(data: Data(json.utf8))

        XCTAssertEqual(result[.bookSource]?.count, 1)
        XCTAssertEqual(result[.purifier]?.count, 1)
        XCTAssertEqual(result[.subscribeSource]?.count, 1)
    }

    func testWrappedKeysSniffing() throws {
        let json = """
        {
          "bookSources": [\(bookSourceJSON), \(secondBookSourceJSON)],
          "replaceRules": [\(ruleJSON), \(secondRuleJSON)],
          "rssSources": [\(rssJSON)]
        }
        """
        let result = ImportSniffer.scanJSON(data: Data(json.utf8))

        XCTAssertEqual(result[.bookSource]?.count, 2)
        XCTAssertEqual(result[.purifier]?.count, 2)
        XCTAssertEqual(result[.subscribeSource]?.count, 1)
    }

    func testSingleObjectSniffing() throws {
        let result = ImportSniffer.scanJSON(data: Data(bookSourceJSON.utf8))
        XCTAssertEqual(result[.bookSource]?.count, 1)
        XCTAssertNil(result[.subscribeSource])

        let rss = ImportSniffer.scanJSON(data: Data(rssJSON.utf8))
        XCTAssertEqual(rss[.subscribeSource]?.count, 1)
    }

    func testUnrecognisedJSONProducesNothing() {
        let result = ImportSniffer.scanJSON(data: Data(#"{"hello":"world"}"#.utf8))
        XCTAssertTrue(result.isEmpty)
    }

    func testZipExtractionAndSniffing() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let zipURL = temp.appendingPathComponent("bundle.zip")

        try makeZip(at: zipURL, entries: [
            ("book-sources.json", Data("[\(bookSourceJSON)]".utf8)),
            ("rules.json", Data("{\"replaceRules\":[\(ruleJSON),\(secondRuleJSON)]}".utf8)),
            ("rss.json", Data(rssJSON.utf8)),
            ("cover.epub", Data([0x50, 0x4B, 0x03, 0x04])),
            ("__MACOSX/._book-sources.json", Data("junk".utf8)),
            (".hidden.json", Data("junk".utf8))
        ])

        let result = ImportSniffer.scan(fileURL: zipURL)
        XCTAssertEqual(result.count(for: .bookSource), 1)
        XCTAssertEqual(result.count(for: .purifier), 2)
        XCTAssertEqual(result.count(for: .subscribeSource), 1)
        XCTAssertEqual(result.count(for: .book), 1)
        XCTAssertEqual(result.count(for: .backup), 1)

        let extraction = try XCTUnwrap(result.extractionDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.appendingPathComponent("._book-sources.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.appendingPathComponent(".hidden.json").path))
        try? FileManager.default.removeItem(at: extraction)
    }

    func testZipExtractionCannotEscapeDirectory() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let zipURL = temp.appendingPathComponent("evil.zip")
        let outside = temp.appendingPathComponent("evil.json")

        try makeZip(at: zipURL, entries: [("../evil.json", Data("{\"pattern\":\"x\"}".utf8))])
        let extraction = temp.appendingPathComponent("out", isDirectory: true)
        let files = try ImportSniffer.extractArchive(url: zipURL, to: extraction)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].deletingLastPathComponent().path, extraction.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        try? FileManager.default.removeItem(at: extraction)
    }

    // MARK: - 链接分类

    func testSchemeClassification() throws {
        XCTAssertEqual(DownloadLinkClassifier.schemeKind(try url("https://x.example/a.zip")), .downloadable)
        XCTAssertEqual(DownloadLinkClassifier.schemeKind(try url("https://x.example/a.json?token=1")), .downloadable)
        XCTAssertEqual(DownloadLinkClassifier.schemeKind(try url("https://x.example/post")), .web)
        XCTAssertEqual(DownloadLinkClassifier.schemeKind(try url("legado://import/rssSource?src=x")), .importDeepLink)
        XCTAssertEqual(DownloadLinkClassifier.schemeKind(try url("juyue://import/bookSource?src=x")), .importDeepLink)
        XCTAssertEqual(DownloadLinkClassifier.schemeKind(try url("data:text/plain,hi")), .data)
        XCTAssertEqual(DownloadLinkClassifier.schemeKind(try url("blob:https://x.example/1")), .blob)
        XCTAssertEqual(DownloadLinkClassifier.schemeKind(try url("ftp://x.example/a.zip")), .externalDeepLink)
        XCTAssertEqual(DownloadLinkClassifier.schemeKind(try url("about:blank")), .externalDeepLink)
    }

    func testContentDispositionAndMIMEHelpers() throws {
        let quoted = DownloadLinkClassifier.contentDisposition(#"attachment; filename="sources.json""#)
        XCTAssertTrue(quoted.isAttachment)
        XCTAssertEqual(quoted.filename, "sources.json")

        let encoded = DownloadLinkClassifier.contentDisposition(
            "inline; filename*=UTF-8''%E4%B9%A6%E6%BA%90.zip"
        )
        XCTAssertFalse(encoded.isAttachment)
        XCTAssertEqual(encoded.filename, "书源.zip")

        XCTAssertTrue(DownloadLinkClassifier.isBinaryMIME("application/json; charset=utf-8"))
        XCTAssertTrue(DownloadLinkClassifier.isBinaryMIME("application/octet-stream"))
        XCTAssertFalse(DownloadLinkClassifier.isBinaryMIME("text/html; charset=utf-8"))

        XCTAssertTrue(DownloadLinkClassifier.shouldPerformDownload(
            navigationActionPrefersDownload: false,
            url: try url("https://x.example/download"),
            contentDisposition: "attachment",
            mimeType: nil
        ))
        XCTAssertTrue(DownloadLinkClassifier.shouldPerformDownload(
            navigationActionPrefersDownload: true,
            url: try url("https://x.example/post"),
            contentDisposition: nil,
            mimeType: "text/html"
        ))
    }

    func testSuggestedFileName() throws {
        XCTAssertEqual(
            DownloadLinkClassifier.suggestedFileName(
                url: try url("https://x.example/download"),
                contentDisposition: nil,
                mimeType: "application/json"
            ),
            "download.json"
        )
        XCTAssertEqual(
            DownloadLinkClassifier.suggestedFileName(
                url: try url("https://x.example/download"),
                contentDisposition: #"attachment; filename="sources.json""#,
                mimeType: "application/json"
            ),
            "sources.json"
        )
        XCTAssertEqual(DownloadLinkClassifier.sanitizedFileName("../../evil.json"), "evil.json")
        XCTAssertEqual(DownloadLinkClassifier.sanitizedFileName(".hidden"), "hidden")
    }

    // MARK: - 正文链接

    func testArticleLinkExtractionAndRelativeResolution() throws {
        let text = "下载 https://cdn.example.com/a.json，备份 /files/b.zip 和书源。普通链接 https://example.com/post 保留。"
        let base = try url("https://site.example/post/1")
        let links = ArticleLinkExtractor.links(in: text, baseURL: base)

        let urls = Set(links.map(\.url.absoluteString))
        XCTAssertTrue(urls.contains("https://cdn.example.com/a.json"))
        XCTAssertTrue(urls.contains("https://site.example/files/b.zip"))
        XCTAssertTrue(urls.contains("https://example.com/post"))

        let jsonLink = try XCTUnwrap(links.first { $0.url.absoluteString == "https://cdn.example.com/a.json" })
        XCTAssertEqual(jsonLink.text, "https://cdn.example.com/a.json")
    }

    func testArticleLinkResolve() throws {
        let base = try url("https://site.example/post/1")
        XCTAssertEqual(
            ArticleLinkExtractor.resolve("../a.zip", baseURL: base)?.absoluteString,
            "https://site.example/a.zip"
        )
        XCTAssertEqual(
            ArticleLinkExtractor.resolve("/files/a.txt", baseURL: base)?.absoluteString,
            "https://site.example/files/a.txt"
        )
        XCTAssertEqual(
            ArticleLinkExtractor.resolve("//cdn.example.com/a.json", baseURL: base)?.absoluteString,
            "https://cdn.example.com/a.json"
        )
    }

    // MARK: - 辅助

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeZip(at url: URL, entries: [(String, Data)]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in entries {
            try archive.addEntry(
                with: name,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    let start = Int(position)
                    let end = min(start + size, data.count)
                    return data.subdata(in: start..<end)
                }
            )
        }
    }
}
