import XCTest
import ZIPFoundation
@testable import LegadoCore

final class WebDAVServiceCleanRoomTests: XCTestCase {

    // MARK: URL 拼接

    func testDirectoryURLAcceptsBareHostAndNormalizesPath() {
        let config = WebDAVConfig(url: "dav.example.com/dav", remotePath: "/sync/")
        XCTAssertEqual(config.directoryURL?.absoluteString, "https://dav.example.com/dav/sync/")
    }

    func testDirectoryURLKeepsExistingSchemeAndRootPath() {
        let config = WebDAVConfig(url: "http://192.168.1.9:5005/", remotePath: "")
        XCTAssertEqual(config.directoryURL?.absoluteString, "http://192.168.1.9:5005/")
        XCTAssertEqual(config.serverRootURL?.absoluteString, "http://192.168.1.9:5005/")
    }

    func testDirectoryURLIsNilForBlankURL() {
        XCTAssertNil(WebDAVConfig(url: "   ", remotePath: "x").directoryURL)
    }

    // MARK: 凭据策略

    func testPlainHTTPWithholdsCredentials() {
        let config = WebDAVConfig(url: "http://nas.local/dav/", username: "u", password: "p")
        XCTAssertTrue(config.sendCredentialsInClear)
        XCTAssertEqual(config.basicAuthHeader, "")
    }

    func testHTTPSBuildsBasicHeader() {
        let config = WebDAVConfig(url: "https://nas.local/dav/", username: "u", password: "p")
        XCTAssertEqual(config.basicAuthHeader, "Basic dTpw")
    }

    // MARK: 文件名

    func testBackupFileNameStripsForbiddenCharacters() {
        let name = WebDAVConfig.generateBackupFileName(deviceName: "顾的 iPhone/测试:1")
        XCTAssertTrue(name.hasPrefix("backup"), name)
        XCTAssertTrue(name.hasSuffix("-顾的 iPhone-测试-1.zip"), name)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    func testBackupFileNameFallsBackWhenDeviceNameIsBlank() {
        let name = WebDAVConfig.generateBackupFileName(deviceName: " -_ ")
        XCTAssertTrue(name.hasPrefix("backup"), name)
        XCTAssertTrue(name.hasSuffix(".zip"), name)
        XCTAssertFalse(name.contains("-."), name)
    }

    func testSanitizeFileNameReplacesForbiddenCharacters() {
        let service = WebDAVService()
        XCTAssertEqual(service.sanitizeFileName("a/b:c*d"), "a_b_c_d")
        XCTAssertEqual(service.sanitizeFileName("正常名字"), "正常名字")
    }

    // MARK: PROPFIND 解析

    private let propfindSample = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
      <D:response>
        <D:href>/dav/legado/</D:href>
        <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
      </D:response>
      <D:response>
        <D:href>/dav/legado/backup2026-10-20-iPhone.zip</D:href>
        <D:propstat><D:prop>
          <D:getcontentlength>1234</D:getcontentlength>
          <D:getlastmodified>Mon, 20 Oct 2026 08:00:00 GMT</D:getlastmodified>
        </D:prop></D:propstat>
      </D:response>
      <D:response>
        <D:href>/dav/legado/backup2026-10-24-iPad.zip</D:href>
        <D:propstat><D:prop>
          <D:getcontentlength>2048</D:getcontentlength>
          <D:getlastmodified>Sat, 24 Oct 2026 09:30:00 GMT</D:getlastmodified>
        </D:prop></D:propstat>
      </D:response>
      <D:response>
        <D:href>/dav/legado/bookshelf.json</D:href>
      </D:response>
    </D:multistatus>
    """

    func testPropfindParsesBackupsAndSortsNewestFirst() throws {
        let base = try XCTUnwrap(URL(string: "https://dav.example.com/dav/legado/"))
        let items = WebDAVService().parseBackupsFromPropfindXML(propfindSample, baseURL: base)

        XCTAssertEqual(items.map(\.fileName), ["backup2026-10-24-iPad.zip", "backup2026-10-20-iPhone.zip"])
        XCTAssertEqual(items[0].size, 2048)
        XCTAssertNotNil(items[0].lastModified)
        XCTAssertEqual(items[0].url.absoluteString, "https://dav.example.com/dav/legado/backup2026-10-24-iPad.zip")
    }

    func testPropfindDecodesPercentEscapedHref() throws {
        let xml = """
        <multistatus xmlns="DAV:">
          <response>
            <href>/dav/legado/backup2026-10-24-%E6%A1%8C%E9%9D%A2.zip</href>
          </response>
        </multistatus>
        """
        let base = try XCTUnwrap(URL(string: "https://dav.example.com/dav/legado/"))
        let items = WebDAVService().parseBackupsFromPropfindXML(xml, baseURL: base)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].fileName, "backup2026-10-24-桌面.zip")
    }

    func testPropfindIgnoresNonBackupEntries() throws {
        let base = try XCTUnwrap(URL(string: "https://dav.example.com/"))
        let items = WebDAVService().parseBackupsFromPropfindXML(propfindSample, baseURL: base)
        XCTAssertFalse(items.contains { $0.fileName.hasSuffix(".json") })
    }

    // MARK: zip 往返

    private func sampleBook(index: Int, position: Int) -> Book {
        Book(
            bookUrl: "https://example.com/book",
            name: "测试书",
            author: "作者甲",
            durChapterIndex: index,
            durChapterPos: position
        )
    }

    func testBackupZipRoundTripsThroughParser() throws {
        let service = WebDAVService()
        let settings = Data(#"{"theme":"dark"}"#.utf8)
        let produced = try service.createBackupZip(
            books: [sampleBook(index: 3, position: 120)],
            sources: [],
            deviceName: "iPhone",
            settingsJSON: settings
        )

        XCTAssertTrue(produced.fileName.hasSuffix("-iPhone.zip"), produced.fileName)

        let parsed = try service.parseArchive(
            try XCTUnwrap(Archive(data: produced.data, accessMode: .read, pathEncoding: nil))
        )
        XCTAssertEqual(parsed.books?.count, 1)
        XCTAssertEqual(parsed.books?.first?.name, "测试书")
        XCTAssertEqual(parsed.books?.first?.durChapterIndex, 3)
        XCTAssertEqual(parsed.sources?.isEmpty, true)
        XCTAssertEqual(service.extractSettingsJSON(fromZip: produced.data), settings)
    }

    func testBackupZipOmitsSettingsWhenNotProvided() throws {
        let service = WebDAVService()
        let produced = try service.createBackupZip(books: [], sources: [], deviceName: "iPad")
        XCTAssertNil(service.extractSettingsJSON(fromZip: produced.data))
    }

    func testParserRejectsZipWithoutKnownEntries() throws {
        let service = WebDAVService()
        let bogus = Data("not a zip".utf8)
        XCTAssertThrowsError(try service.restoreFromZip(data: bogus))
    }

    // MARK: 进度合并

    func testProgressDirectoryMovesReadingForward() throws {
        let service = WebDAVService()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let progress = BookProgress(
            name: "测试书", author: "作者甲",
            durChapterIndex: 9, durChapterPos: 42,
            durChapterTime: 1_700_000_000_000,
            durChapterTitle: "第九章"
        )
        try JSONEncoder().encode(progress).write(to: dir.appendingPathComponent("any.json"))

        var books = [sampleBook(index: 2, position: 10)]
        service.applyBookProgress(books: &books, fromDirectory: dir)

        XCTAssertEqual(books[0].durChapterIndex, 9)
        XCTAssertEqual(books[0].durChapterPos, 42)
        XCTAssertEqual(books[0].durChapterTitle, "第九章")
        XCTAssertEqual(books[0].lastCheckTime, 1_700_000_000_000)
    }

    func testProgressDirectoryNeverRewindsReading() throws {
        let service = WebDAVService()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stale = BookProgress(name: "测试书", author: "作者甲", durChapterIndex: 1, durChapterPos: 0)
        try JSONEncoder().encode(stale).write(to: dir.appendingPathComponent("stale.json"))

        var books = [sampleBook(index: 10, position: 5)]
        service.applyBookProgress(books: &books, fromDirectory: dir)

        XCTAssertEqual(books[0].durChapterIndex, 10)
    }
}
