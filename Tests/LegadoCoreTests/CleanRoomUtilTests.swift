import XCTest
@testable import LegadoCore

final class CleanRoomCookieJarTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "cookie-jar-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeJar(legacyKey: String? = nil) -> CookieJar {
        CookieJar(defaults: defaults, storageKey: "jar.v2", legacyKey: legacyKey)
    }

    func testHostKeyNormalizes() {
        XCTAssertEqual(CookieJar.hostKey(for: " https://User:Pw@Example.COM:8443/a/b?q=1 "), "example.com")
        XCTAssertEqual(CookieJar.hostKey(for: "example.com/path"), "example.com")
        XCTAssertEqual(CookieJar.hostKey(for: "大灰狼融合VIP5.0"), "大灰狼融合vip5.0")
        XCTAssertEqual(CookieJar.hostKey(for: "https://[::1]:8080/x"), "::1")
        XCTAssertEqual(CookieJar.hostKey(for: "   "), "")
    }

    func testWriteReadAndLastHost() {
        let jar = makeJar()
        jar.setCookies("sid=abc; theme=dark; Path=/; HttpOnly; Secure", for: "https://example.com/ch/1")
        XCTAssertEqual(jar.cookieString(for: "https://example.com/other"), "sid=abc; theme=dark")
        XCTAssertEqual(jar.value(for: "example.com", name: "theme"), "dark")
        XCTAssertEqual(jar.lastWrittenHostKey, "example.com")

        jar.resetLastWrite()
        XCTAssertNil(jar.lastWrittenHostKey)
    }

    func testMergeAndDeleteSingleCookie() {
        let jar = makeJar()
        jar.setCookies("a=1; b=2", for: "https://a.test")
        jar.setCookies("a=3; c=4", for: "https://a.test/x")
        XCTAssertEqual(jar.cookieString(for: "a.test"), "a=3; b=2; c=4")

        jar.setCookies("b=", for: "https://a.test")
        XCTAssertEqual(jar.cookieString(for: "a.test"), "a=3; c=4")
        XCTAssertNil(jar.value(for: "a.test", name: "b"))
    }

    func testMaxAgeZeroClearsHost() {
        let jar = makeJar()
        jar.setCookies("x=1; y=2", for: "https://a.test")
        jar.setCookies("z=3; Max-Age=0", for: "https://a.test")
        XCTAssertEqual(jar.cookieString(for: "https://a.test"), "")
        XCTAssertEqual(jar.lastWrittenHostKey, "a.test")
    }

    func testRemoveAndRemoveAll() {
        let jar = makeJar()
        jar.setCookies("a=1", for: "https://a.test")
        jar.setCookies("b=2", for: "https://b.test")
        jar.remove(for: "https://a.test")
        XCTAssertEqual(jar.cookieString(for: "https://a.test"), "")
        XCTAssertEqual(jar.cookieString(for: "https://b.test"), "b=2")

        jar.removeAll()
        XCTAssertEqual(jar.cookieString(for: "https://b.test"), "")
        XCTAssertNil(jar.lastWrittenHostKey)
    }

    func testPersistsAcrossInstances() {
        let first = makeJar()
        first.setCookies("sid=abc", for: "https://a.test")

        let second = makeJar()
        XCTAssertEqual(second.cookieString(for: "https://a.test"), "sid=abc")
        XCTAssertNil(second.lastWrittenHostKey)
    }

    func testMigratesLegacyStringStore() {
        defaults.set(["example.com": "sid=old; theme=light"], forKey: "old.jar")
        let jar = makeJar(legacyKey: "old.jar")

        XCTAssertEqual(jar.cookieString(for: "https://example.com"), "sid=old; theme=light")
        XCTAssertNotNil(defaults.data(forKey: "jar.v2"))
        XCTAssertNil(defaults.object(forKey: "old.jar"))
    }
}

final class CleanRoomTTSTextChunkerTests: XCTestCase {
    func testMergesSentencesWithinLimit() {
        XCTAssertEqual(
            TTSTextChunker.split("第一句。第二句。第三句。", maxLength: 8),
            ["第一句。第二句。", "第三句。"]
        )
    }

    func testHardCutsOverlongSentence() {
        let chunks = TTSTextChunker.split(String(repeating: "长", count: 25), maxLength: 10)
        XCTAssertEqual(chunks.map(\.count), [10, 10, 5])
    }

    func testBlankInputReturnsEmpty() {
        XCTAssertTrue(TTSTextChunker.split(" \n\t ").isEmpty)
    }

    func testNewlineIsABoundary() {
        XCTAssertEqual(
            TTSTextChunker.split("第一段\n第二段", maxLength: 3),
            ["第一段", "第二段"]
        )
    }

    func testCRLFIsNormalized() {
        XCTAssertEqual(
            TTSTextChunker.split("a。\r\nb。", maxLength: 2),
            ["a。", "b。"]
        )
    }

    func testMixedShortAndOverlongUnits() {
        let text = "短。" + String(repeating: "长", count: 25)
        let chunks = TTSTextChunker.split(text, maxLength: 10)
        XCTAssertEqual(chunks.first, "短。")
        XCTAssertEqual(chunks.dropFirst().map(\.count), [10, 10, 5])
    }

    func testNonPositiveLimitKeepsWholeText() {
        XCTAssertEqual(TTSTextChunker.split("a\r\nb", maxLength: 0), ["a\nb"])
    }

    func testCountsCharactersNotScalars() {
        XCTAssertEqual(TTSTextChunker.split("😀😀😀", maxLength: 2), ["😀😀", "😀"])
    }

    func testUnpunctuatedTextStaysTogether() {
        XCTAssertEqual(TTSTextChunker.split("abc", maxLength: 10), ["abc"])
    }
}
