import Foundation
import SwiftSoup
import ZIPFoundation

public struct ParsedEpub {
    public let book: Book
    public let chapters: [BookChapter]
    public let extractedDirectory: URL

    public init(book: Book, chapters: [BookChapter], extractedDirectory: URL) {
        self.book = book
        self.chapters = chapters
        self.extractedDirectory = extractedDirectory
    }
}

/// EPUB 2/3 的最小解析器：定位 OPF、读元数据、按 nav/NCX/spine 取目录、抽正文。
public final class EpubParser {
    public static let shared = EpubParser()

    public init() {}

    private struct ManifestEntry {
        let href: String
        let mediaType: String
        let properties: String
    }

    private struct PackageDocument {
        let opfURL: URL
        let title: String
        let author: String
        let intro: String?
        let manifest: [String: ManifestEntry]
        let spine: [String]
        let navHref: String?
        let ncxHref: String?
    }

    // MARK: - 入口

    public func parse(epubUrl: URL, destinationDir: URL? = nil) throws -> ParsedEpub {
        let directory = try prepare(epubUrl: epubUrl, destination: destinationDir)
        let package = try loadPackage(in: directory, fallbackTitle: epubUrl.deletingPathExtension().lastPathComponent)

        var chapters = navigationChapters(package)
        if chapters.isEmpty {
            chapters = spineChapters(package, epubUrl: epubUrl)
        } else {
            for index in chapters.indices {
                chapters[index].index = index
                chapters[index].bookUrl = epubUrl.absoluteString
            }
        }

        let book = Book(
            bookUrl: epubUrl.absoluteString,
            name: package.title,
            author: package.author,
            kind: "EPUB 本地书籍",
            coverUrl: nil,
            intro: package.intro,
            origin: "local",
            originName: "本地导入",
            tocUrl: package.opfURL.absoluteString,
            totalChapterNum: chapters.count
        )
        return ParsedEpub(book: book, chapters: chapters, extractedDirectory: directory)
    }

    // MARK: - 解包与 OPF

    private func prepare(epubUrl: URL, destination: URL?) throws -> URL {
        let manager = FileManager.default
        let target: URL
        if let destination {
            target = destination
        } else {
            let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let identifier = CryptoUtils.md5(epubUrl.absoluteString)
            target = documents
                .appendingPathComponent("Books/EPUB", isDirectory: true)
                .appendingPathComponent(identifier, isDirectory: true)
        }

        if !manager.fileExists(atPath: target.path) {
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            try manager.unzipItem(at: epubUrl, to: target)
        }
        return target
    }

    private func loadPackage(in directory: URL, fallbackTitle: String) throws -> PackageDocument {
        let containerURL = directory.appendingPathComponent("META-INF/container.xml")
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw epubError(code: 1, message: "Missing META-INF/container.xml")
        }
        let container = try SwiftSoup.parse(
            text(at: containerURL), "", Parser.xmlParser()
        )
        guard let rootfile = try container.select("rootfile").first() else {
            throw epubError(code: 2, message: "Failed to locate root OPF in container.xml")
        }
        let relativeOPF = try rootfile.attr("full-path")
        guard !relativeOPF.isEmpty else {
            throw epubError(code: 2, message: "Failed to locate root OPF in container.xml")
        }

        let opfURL = directory.appendingPathComponent(relativeOPF)
        let opf = try SwiftSoup.parse(text(at: opfURL), "", Parser.xmlParser())

        let title = elementText(opf, "dc|title, title") ?? fallbackTitle
        let author = elementText(opf, "dc|creator, creator") ?? "未知作者"
        let intro = elementText(opf, "dc|description, description")

        var manifest: [String: ManifestEntry] = [:]
        var navHref: String?
        var ncxHref: String?
        if let items = try? opf.select("manifest > item") {
            for item in items {
                let identifier = (try? item.attr("id")) ?? ""
                guard !identifier.isEmpty else { continue }
                let href = (try? item.attr("href")) ?? ""
                let mediaType = (try? item.attr("media-type")) ?? ""
                let properties = (try? item.attr("properties")) ?? ""
                manifest[identifier] = ManifestEntry(
                    href: href, mediaType: mediaType, properties: properties
                )
                if properties.contains("nav") || href.hasSuffix("nav.xhtml") {
                    navHref = href
                }
                if mediaType == "application/x-dtbncx+xml" || href.hasSuffix(".ncx") {
                    ncxHref = href
                }
            }
        }

        var spine: [String] = []
        if let refs = try? opf.select("spine > itemref") {
            for ref in refs {
                let identifier = (try? ref.attr("idref")) ?? ""
                if let entry = manifest[identifier] {
                    spine.append(entry.href)
                }
            }
        }

        return PackageDocument(
            opfURL: opfURL,
            title: title,
            author: author,
            intro: intro,
            manifest: manifest,
            spine: spine,
            navHref: navHref,
            ncxHref: ncxHref
        )
    }

    // MARK: - 目录

    private func navigationChapters(_ package: PackageDocument) -> [BookChapter] {
        let opfDirectory = package.opfURL.deletingLastPathComponent()

        if let navHref = package.navHref {
            let navURL = opfDirectory.appendingPathComponent(navHref)
            if let html = try? text(at: navURL) {
                let chapters = chaptersFromNav(html, baseDirectory: navURL.deletingLastPathComponent())
                if !chapters.isEmpty { return chapters }
            }
        }

        if let ncxHref = package.ncxHref {
            let ncxURL = opfDirectory.appendingPathComponent(ncxHref)
            if let xml = try? text(at: ncxURL) {
                let chapters = chaptersFromNCX(xml, baseDirectory: ncxURL.deletingLastPathComponent())
                if !chapters.isEmpty { return chapters }
            }
        }

        return []
    }

    private func chaptersFromNav(_ html: String, baseDirectory: URL) -> [BookChapter] {
        guard let document = try? SwiftSoup.parse(html) else { return [] }
        let navigation = (try? document.select("nav[epub|type=toc]").first())
            ?? (try? document.select("nav").first())
            ?? document
        guard let links = try? navigation.select("a") else { return [] }

        var chapters: [BookChapter] = []
        for link in links {
            let href = (try? link.attr("href")) ?? ""
            let title = ((try? link.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty, !href.hasPrefix("#"), !title.isEmpty else { continue }
            chapters.append(BookChapter(
                bookUrl: "",
                url: resolve(href: href, against: baseDirectory),
                title: title,
                index: chapters.count
            ))
        }
        return chapters
    }

    private func chaptersFromNCX(_ xml: String, baseDirectory: URL) -> [BookChapter] {
        guard let document = try? SwiftSoup.parse(xml, "", Parser.xmlParser()),
              let points = try? document.select("navPoint") else { return [] }

        var chapters: [BookChapter] = []
        for point in points {
            let source = (try? point.select("content").first()?.attr("src")) ?? ""
            guard !source.isEmpty, !source.hasPrefix("#") else { continue }
            let label = ((try? point.select("navLabel > text").first()?.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(BookChapter(
                bookUrl: "",
                url: resolve(href: source, against: baseDirectory),
                title: label.isEmpty ? "第 \(chapters.count + 1) 章" : label,
                index: chapters.count
            ))
        }
        return chapters
    }

    private func spineChapters(_ package: PackageDocument, epubUrl: URL) -> [BookChapter] {
        let base = package.opfURL.deletingLastPathComponent()
        return package.spine.enumerated().map { offset, href in
            let fileURL = base.appendingPathComponent(href)
            var title = fileURL.lastPathComponent
            for suffix in [".xhtml", ".html"] where title.hasSuffix(suffix) {
                title.removeLast(suffix.count)
            }
            return BookChapter(
                bookUrl: epubUrl.absoluteString,
                url: fileURL.absoluteString,
                title: title.isEmpty ? "第 \(offset + 1) 章" : title,
                index: offset
            )
        }
    }

    private func resolve(href: String, against directory: URL) -> String {
        let pieces = href.components(separatedBy: "#")
        let path = pieces.first ?? ""
        let anchor = pieces.count > 1 ? pieces[1] : ""
        let fileURL = path.isEmpty
            ? directory
            : URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        return anchor.isEmpty ? fileURL.absoluteString : "\(fileURL.absoluteString)#\(anchor)"
    }

    // MARK: - 正文

    public static func extractChapterContent(fromUrlString urlString: String, bookUrl: String? = nil) -> String {
        let normalized = urlString.contains("%23") && !urlString.contains("#")
            ? urlString.replacingOccurrences(of: "%23", with: "#")
            : urlString

        let pieces = normalized.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let pathPart = String(pieces[0])
        let anchor = pieces.count > 1 && !pieces[1].isEmpty ? String(pieces[1]) : nil

        var fileURL = localFileURL(pathPart)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = relocatedFile(named: fileURL.lastPathComponent, bookUrl: bookUrl) ?? fileURL
        }
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        guard let html = decode(data) else { return "" }
        guard let document = try? SwiftSoup.parse(html) else { return html }

        let baseDirectory = fileURL.deletingLastPathComponent()
        if let anchor, let target = try? document.select("#\(anchor)").first() {
            if let text = anchoredText(target, anchor: anchor, baseDirectory: baseDirectory) {
                return text
            }
        }

        if let body = document.body() {
            if let headings = try? body.select(".chaptertitle, [id^=chapter]"), !headings.isEmpty() {
                if let intro = volumeIntro(body: body, baseDirectory: baseDirectory) {
                    return intro
                }
            }
            return plainText(from: body, baseDirectory: baseDirectory)
        }
        return plainText(from: document, baseDirectory: baseDirectory)
    }

    public static func extractChapterContent(from fileOrFragmentUrl: URL) -> String {
        extractChapterContent(fromUrlString: fileOrFragmentUrl.absoluteString)
    }

    private static func anchoredText(_ target: Element, anchor: String, baseDirectory: URL) -> String? {
        let direct = plainText(from: target, baseDirectory: baseDirectory)
        let paragraphs = (try? target.select("p").count) ?? 0
        if paragraphs > 3, direct.count > 500 { return direct }

        var container: Element = target
        while let parent = container.parent(), parent.tagName() != "body", parent.tagName() != "html" {
            container = parent
        }

        var html = ""
        var cursor: Element? = container
        while let element = cursor {
            html += (try? element.outerHtml()) ?? ""
            cursor = try? element.nextElementSibling()
            if let next = cursor {
                let nextChapter = (try? next.select("[id^=chapter]").first()) != nil
                if nextChapter || next.hasClass("chaptertitle") || next.hasClass("volumetitle") {
                    break
                }
            }
        }

        if !html.isEmpty, let section = try? SwiftSoup.parse(html) {
            let text = plainText(from: section, baseDirectory: baseDirectory)
            if !text.isEmpty { return text }
        }
        return direct.isEmpty ? nil : direct
    }

    private static func volumeIntro(body: Element, baseDirectory: URL) -> String? {
        var html = ""
        var cursor: Element? = body.children().first()
        while let element = cursor {
            if element.hasClass("chaptertitle")
                || (try? element.select("[id^=chapter]").first()) != nil {
                break
            }
            html += (try? element.outerHtml()) ?? ""
            cursor = try? element.nextElementSibling()
        }
        guard !html.isEmpty, let intro = try? SwiftSoup.parse(html) else { return nil }
        let text = plainText(from: intro, baseDirectory: baseDirectory)
        guard !text.isEmpty else { return nil }
        return text + "\n\n（本节为分卷导读，请点击“下一章”或通过目录阅读正文）"
    }

    private static func plainText(from element: Element, baseDirectory: URL) -> String {
        if let images = try? element.select("img, image") {
            for image in images {
                var source = (try? image.attr("src")) ?? ""
                if source.isEmpty { source = (try? image.attr("xlink:href")) ?? "" }
                if source.isEmpty { source = (try? image.attr("href")) ?? "" }
                guard !source.isEmpty else { continue }
                let resolved = isRemoteOrFile(source)
                    ? source
                    : URL(string: source, relativeTo: baseDirectory)?.standardizedFileURL.absoluteString ?? source
                _ = try? image.before("__IMG_BLOCK__\(resolved)__IMG_BLOCK__")
                if let figure = image.parents().first(where: { $0.tagName() == "figure" }),
                   let caption = try? figure.select("figcaption").first(),
                   let rawCaption = try? caption.text() {
                    let cleaned = rawCaption.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        _ = try? image.after("__CAPTION_BLOCK__\(cleaned)__CAPTION_BLOCK__")
                        try? caption.remove()
                    }
                }
            }
        }
        if let breaks = try? element.select("br") {
            for lineBreak in breaks {
                _ = try? lineBreak.before("__BR_NEWLINE__")
            }
        }
        if let blocks = try? element.select("p, h1, h2, h3, h4, h5, h6") {
            for block in blocks {
                _ = try? block.before("__P_BREAK__")
                _ = try? block.after("__P_BREAK__")
            }
        }

        var text = (try? element.text()) ?? ""
        text = text.replacingOccurrences(of: "__BR_NEWLINE__", with: "\n")
        text = text.replacingOccurrences(of: "__P_BREAK__", with: "\n\n")

        if let marker = try? NSRegularExpression(pattern: "__IMG_BLOCK__(.*?)__IMG_BLOCK__") {
            text = marker.stringByReplacingMatches(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: "\n\n[image:$1]\n\n"
            )
        }
        if let captionMarker = try? NSRegularExpression(pattern: "__CAPTION_BLOCK__(.*?)__CAPTION_BLOCK__") {
            text = captionMarker.stringByReplacingMatches(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: "\n[caption:$1]\n"
            )
        }
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 路径与解码

    private static func localFileURL(_ pathPart: String) -> URL {
        if let direct = URL(string: pathPart), direct.isFileURL {
            return URL(fileURLWithPath: percentDecoded(direct.path))
        }
        let escaped = pathPart.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pathPart
        if let encoded = URL(string: escaped), encoded.isFileURL {
            return URL(fileURLWithPath: percentDecoded(encoded.path))
        }
        let stripped = pathPart.hasPrefix("file://")
            ? String(pathPart.dropFirst("file://".count))
            : pathPart
        return URL(fileURLWithPath: percentDecoded(stripped))
    }

    private static func percentDecoded(_ path: String) -> String {
        guard let decoded = path.removingPercentEncoding, !decoded.isEmpty else { return path }
        return decoded
    }

    private static func relocatedFile(named name: String, bookUrl: String?) -> URL? {
        let manager = FileManager.default
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("Books/EPUB", isDirectory: true)

        var candidates: [URL] = []
        if let bookUrl, !bookUrl.isEmpty {
            candidates.append(root.appendingPathComponent(CryptoUtils.md5(bookUrl), isDirectory: true))
        }
        candidates.append(root)

        for candidate in candidates where manager.fileExists(atPath: candidate.path) {
            guard let walker = manager.enumerator(at: candidate, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.lastPathComponent == name {
                return file
            }
        }
        return nil
    }

    private static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .ascii)
    }

    private static func isRemoteOrFile(_ source: String) -> Bool {
        source.hasPrefix("http://") || source.hasPrefix("https://") || source.hasPrefix("file://")
    }

    // MARK: - 小工具

    private func text(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func elementText(_ document: Document, _ selector: String) -> String? {
        guard let element = try? document.select(selector).first() else { return nil }
        return try? element.text()
    }

    private func epubError(code: Int, message: String) -> NSError {
        NSError(domain: "EpubParser", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - MOBI / AZW3 / FB2 / UMD

/// 本地电子书导入：MOBI（含 KF8）、FB2、UMD。
/// 一律先落成「一章一个 HTML + images 目录」，正文渲染交给已有的本地 HTML 链路，
/// 不另开一套阅读器。
public final class LocalBookParser {
    public static let shared = LocalBookParser()

    /// 解析出来的中间结果，还没写盘。
    struct Draft {
        var title: String
        var author: String
        var intro: String?
        var chapters: [(title: String, html: String)]
    }

    public init() {}

    public func parse(url: URL, destinationDir: URL? = nil) throws -> ParsedEpub {
        let ext = url.pathExtension.lowercased()
        let format: String
        switch ext {
        case "mobi", "azw", "prc": format = "MOBI"
        case "azw3": format = "AZW3"
        case "fb2": format = "FB2"
        case "umd": format = "UMD"
        default: throw localBookError("不支持的文件格式：\(ext)")
        }

        let directory: URL
        if let destinationDir {
            directory = destinationDir
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            directory = documents
                .appendingPathComponent("Books/\(format)", isDirectory: true)
                .appendingPathComponent(CryptoUtils.md5(url.absoluteString), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let draft: Draft
        switch ext {
        case "mobi", "azw", "azw3", "prc":
            draft = try MobiFileParser(url: url, directory: directory, fallbackTitle: fallbackTitle).parse()
        case "fb2":
            draft = try FB2FileParser(url: url, directory: directory, fallbackTitle: fallbackTitle).parse()
        default:
            draft = try UMDFileParser(url: url, directory: directory, fallbackTitle: fallbackTitle).parse()
        }
        return try write(draft: draft, format: format, sourceURL: url, directory: directory)
    }

    private func write(draft: Draft, format: String, sourceURL: URL, directory: URL) throws -> ParsedEpub {
        let bookUrl = sourceURL.absoluteString
        let textDir = directory.appendingPathComponent("Text", isDirectory: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)

        var chapters: [BookChapter] = []
        for (index, item) in draft.chapters.enumerated() {
            let document = """
            <html><head><meta charset="utf-8"/></head><body>
            \(item.html)
            </body></html>
            """
            let file = textDir.appendingPathComponent("chapter_\(index).html")
            try document.write(to: file, atomically: true, encoding: .utf8)
            chapters.append(BookChapter(
                bookUrl: bookUrl,
                url: file.absoluteString,
                title: item.title.isEmpty ? "第 \(index + 1) 章" : item.title,
                index: index
            ))
        }
        guard !chapters.isEmpty else { throw localBookError("没有解析到正文") }

        let book = Book(
            bookUrl: bookUrl,
            name: draft.title,
            author: draft.author,
            kind: "\(format) 本地书籍",
            coverUrl: nil,
            intro: draft.intro,
            origin: "local",
            originName: "本地导入",
            tocUrl: "",
            totalChapterNum: chapters.count
        )
        return ParsedEpub(book: book, chapters: chapters, extractedDirectory: directory)
    }
}

// MARK: - 共用小工具

private func localBookError(_ message: String) -> NSError {
    NSError(domain: "LocalBookParser", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func beUInt16(_ data: Data, _ offset: Int) -> Int {
    guard offset >= 0, offset + 2 <= data.count else { return 0 }
    let base = data.startIndex + offset
    return Int(data[base]) << 8 | Int(data[base + 1])
}

private func beUInt32(_ data: Data, _ offset: Int) -> Int {
    guard offset >= 0, offset + 4 <= data.count else { return 0 }
    let base = data.startIndex + offset
    return Int(data[base]) << 24 | Int(data[base + 1]) << 16
        | Int(data[base + 2]) << 8 | Int(data[base + 3])
}

private func leUInt16(_ data: Data, _ offset: Int) -> Int {
    guard offset >= 0, offset + 2 <= data.count else { return 0 }
    let base = data.startIndex + offset
    return Int(data[base]) | Int(data[base + 1]) << 8
}

private func leUInt32(_ data: Data, _ offset: Int) -> Int {
    guard offset >= 0, offset + 4 <= data.count else { return 0 }
    let base = data.startIndex + offset
    return Int(data[base]) | Int(data[base + 1]) << 8
        | Int(data[base + 2]) << 16 | Int(data[base + 3]) << 24
}

private func umdByte(_ data: Data, _ offset: Int) -> Int {
    guard offset >= 0, offset < data.count else { return 0 }
    return Int(data[data.startIndex + offset])
}

private func firstRegexCapture(_ pattern: String, in text: String, group: Int = 1) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = text as NSString
    guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
          group < match.numberOfRanges,
          match.range(at: group).location != NSNotFound else { return nil }
    return ns.substring(with: match.range(at: group))
}

private func escapeHTMLEntities(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func decodeBasicEntities(_ text: String) -> String {
    var result = text
    let pairs = [
        ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
        ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")
    ]
    for (key, value) in pairs { result = result.replacingOccurrences(of: key, with: value) }
    return result
}

private func stripHTMLTags(_ html: String) -> String {
    let noTags = html.replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
    return decodeBasicEntities(noTags)
}

private func hasVisibleContent(_ html: String) -> Bool {
    if html.contains("<img") { return true }
    return !stripHTMLTags(html).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// 纯文本按行切段，空行丢掉。
private func paragraphsHTML(from text: String) -> String {
    text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map { "<p>" + escapeHTMLEntities($0) + "</p>" }
        .joined(separator: "\n")
}

/// 在 XML 里按选择器取一段文字，取不到返回 nil。
private func elementText(of root: Element?, _ selector: String) -> String? {
    guard let root, let element = try? root.select(selector).first() else { return nil }
    let value = ((try? element.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

// MARK: - MOBI / AZW3

/// PDB 容器 + PalmDOC 压缩 + MOBI/KF8 头。
/// 只支持无 DRM、compression 1/2；Huffman（17480）直接报错。
private final class MobiFileParser {
    private let url: URL
    private let directory: URL
    private let fallbackTitle: String
    private let data: Data
    private var records: [Data] = []
    private var firstImageIndex = 0
    private var imageFiles: [Int: String] = [:]

    private struct MobiHeader {
        var compression = 0
        var textLength = 0
        var textRecordCount = 0
        var textEncoding = 65001
        var headerLength = 0
        var firstImageIndex = 0
        var fullName = ""
        var author: String?
    }

    init(url: URL, directory: URL, fallbackTitle: String) throws {
        self.url = url
        self.directory = directory
        self.fallbackTitle = fallbackTitle
        self.data = try Data(contentsOf: url)
    }

    func parse() throws -> LocalBookParser.Draft {
        records = try loadRecords()
        guard !records.isEmpty else { throw localBookError("MOBI 记录表是空的") }

        var header = try readHeader(from: records[0])
        var textStart = 1
        if let boundary = exthIntValue(121, in: records[0], headerLength: header.headerLength),
           boundary + 1 < records.count,
           let kf8 = try? readHeader(from: records[boundary + 1]) {
            // 双格式 MOBI：前一半是旧 MOBI，boundary 之后才是 KF8
            header = kf8
            textStart = boundary + 2
        }
        firstImageIndex = header.firstImageIndex

        var textBytes = Data()
        var index = textStart
        let hardStop = textStart + max(1, header.textRecordCount)
        while index < records.count {
            if header.textLength > 0 {
                if textBytes.count >= header.textLength { break }
            } else if index >= hardStop {
                break
            }
            let record = records[index]
            if recordTag(record) != nil { break }
            let chunk: Data
            switch header.compression {
            case 1: chunk = record
            case 2: chunk = palmDocDecompress(record)
            case 17480: throw localBookError("暂不支持 Huffman 压缩的 MOBI")
            default: throw localBookError("不支持的 MOBI 压缩方式：\(header.compression)")
            }
            textBytes.append(chunk)
            index += 1
        }
        if header.textLength > 0, textBytes.count > header.textLength {
            textBytes = textBytes.prefix(header.textLength)
        }
        guard !textBytes.isEmpty else { throw localBookError("MOBI 正文是空的") }

        let rawText = decodeText(textBytes, encoding: header.textEncoding)
        var chapters: [(String, String)] = []
        for fragment in splitChapters(rawText) {
            let html = cleanFragment(fragment)
            guard hasVisibleContent(html) else { continue }
            let title = headingTitle(of: fragment) ?? fallbackTitle
            chapters.append((title, html))
        }
        guard !chapters.isEmpty else { throw localBookError("MOBI 正文解析不出来") }

        return LocalBookParser.Draft(
            title: header.fullName.isEmpty ? fallbackTitle : header.fullName,
            author: header.author.flatMap { $0.isEmpty ? nil : $0 } ?? "未知作者",
            intro: nil,
            chapters: chapters
        )
    }

    // MARK: PDB

    private func loadRecords() throws -> [Data] {
        guard data.count > 78 else { throw localBookError("文件太小，不是有效的 MOBI") }
        let signature = String(decoding: data.subdata(in: 60..<68), as: UTF8.self)
        guard signature == "BOOKMOBI" else { throw localBookError("文件头不是 MOBI，导入不了") }
        let count = beUInt16(data, 76)
        guard count > 0 else { throw localBookError("MOBI 记录表是空的") }

        var offsets: [Int] = []
        for i in 0..<count {
            let at = 78 + i * 8
            guard at + 4 <= data.count else { break }
            offsets.append(beUInt32(data, at))
        }
        var list: [Data] = []
        for (i, start) in offsets.enumerated() {
            let end = i + 1 < offsets.count ? offsets[i + 1] : data.count
            if start >= 0, start < end, end <= data.count {
                list.append(data.subdata(in: start..<end))
            } else {
                list.append(Data())
            }
        }
        return list
    }

    private func readHeader(from record: Data) throws -> MobiHeader {
        guard record.count > 132 else { throw localBookError("MOBI 头不完整") }
        guard beUInt16(record, 12) == 0 else { throw localBookError("这本 MOBI 带 DRM，导入不了") }
        guard String(decoding: record.subdata(in: 16..<20), as: UTF8.self) == "MOBI" else {
            throw localBookError("MOBI 头损坏")
        }

        var header = MobiHeader()
        header.compression = beUInt16(record, 0)
        header.textLength = beUInt32(record, 4)
        header.textRecordCount = beUInt16(record, 8)
        header.textEncoding = beUInt32(record, 28)
        header.headerLength = beUInt32(record, 20)
        header.firstImageIndex = beUInt32(record, 16 + 0x6C)

        let nameOffset = beUInt32(record, 16 + 0x54)
        let nameLength = beUInt32(record, 16 + 0x58)
        if nameOffset > 0, nameLength > 0, nameOffset + nameLength <= record.count {
            let raw = record.subdata(in: nameOffset..<(nameOffset + nameLength))
            header.fullName = decodeText(raw, encoding: header.textEncoding)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let exthFlags = beUInt32(record, 16 + 0x80)
        if exthFlags & 0x40 != 0 {
            let author = exthString(100, in: record, headerLength: header.headerLength, encoding: header.textEncoding)
            header.author = author.flatMap { $0.isEmpty ? nil : $0 }
        }
        return header
    }

    private func exthItems(in record: Data, headerLength: Int) -> [(type: Int, payload: Data)] {
        let start = 16 + headerLength
        guard start >= 0, start + 12 <= record.count,
              String(decoding: record.subdata(in: start..<(start + 4)), as: UTF8.self) == "EXTH" else {
            return []
        }
        let count = beUInt32(record, start + 8)
        var items: [(Int, Data)] = []
        var cursor = start + 12
        for _ in 0..<count {
            guard cursor + 8 <= record.count else { break }
            let type = beUInt32(record, cursor)
            let length = beUInt32(record, cursor + 4)
            guard length >= 8, cursor + length <= record.count else { break }
            items.append((type, record.subdata(in: (cursor + 8)..<(cursor + length))))
            cursor += length
        }
        return items
    }

    private func exthString(_ type: Int, in record: Data, headerLength: Int, encoding: Int) -> String? {
        for item in exthItems(in: record, headerLength: headerLength) where item.type == type {
            return decodeText(item.payload, encoding: encoding)
        }
        return nil
    }

    private func exthIntValue(_ type: Int, in record: Data, headerLength: Int) -> Int? {
        for item in exthItems(in: record, headerLength: headerLength) where item.type == type {
            guard item.payload.count >= 4 else { continue }
            return beUInt32(item.payload, 0)
        }
        return nil
    }

    private func recordTag(_ record: Data) -> String? {
        guard record.count >= 4 else { return nil }
        let tag = String(decoding: record.subdata(in: 0..<4), as: UTF8.self)
        return ["FDST", "INDX", "TAGX", "IDXT", "FLIS", "FCIS"].contains(tag) ? tag : nil
    }

    // MARK: 文本

    private func palmDocDecompress(_ record: Data) -> Data {
        let input = [UInt8](record)
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 4)
        var i = 0
        while i < input.count {
            let byte = input[i]
            i += 1
            switch byte {
            case 0x00:
                output.append(0)
            case 0x01...0x08:
                for _ in 0..<Int(byte) where i < input.count {
                    output.append(input[i])
                    i += 1
                }
            case 0x09...0x7F:
                output.append(byte)
            case 0x80...0xBF:
                guard i < input.count else { break }
                let pair = Int(byte) << 8 | Int(input[i])
                i += 1
                let distance = (pair >> 3) & 0x7FF
                let length = (pair & 0x07) + 3
                guard distance > 0, distance <= output.count else { break }
                var source = output.count - distance
                for _ in 0..<length {
                    guard source < output.count else { break }
                    output.append(output[source])
                    source += 1
                }
            default:
                output.append(0x20)
                output.append(byte ^ 0x80)
            }
        }
        return Data(output)
    }

    private func decodeText(_ data: Data, encoding: Int) -> String {
        if encoding == 65001, let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    private func splitChapters(_ html: String) -> [String] {
        let byPagebreak = html
            .replacingOccurrences(of: "(?i)<mbp:pagebreak\\b[^>]*>", with: "\u{01}", options: .regularExpression)
            .components(separatedBy: "\u{01}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let byHeading = splitByHeadings(html)
        return byPagebreak.count >= byHeading.count ? byPagebreak : byHeading
    }

    private func splitByHeadings(_ html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(?i)<h[1-3]\\b") else { return [html] }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard matches.count > 1 else { return [html] }
        var result: [String] = []
        var cursor = 0
        for match in matches.dropFirst() {
            let location = match.range.location
            guard location > cursor else { continue }
            result.append(ns.substring(with: NSRange(location: cursor, length: location - cursor)))
            cursor = location
        }
        if cursor < ns.length {
            result.append(ns.substring(from: cursor))
        }
        return result
    }

    private func headingTitle(of fragment: String) -> String? {
        guard let inner = firstRegexCapture("(?is)<h[1-3]\\b[^>]*>(.*?)</h[1-3]\\s*>", in: fragment) else { return nil }
        let title = stripHTMLTags(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func cleanFragment(_ raw: String) -> String {
        var html = raw
        html = html.replacingOccurrences(of: "(?i)</?mbp:[^>]*>", with: "", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?is)<!\\[CDATA\\[|\\]\\]>", with: "", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?is)</?o:p\\b[^>]*>", with: "", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?is)<a\\b[^>]*>", with: "", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?is)</a\\s*>", with: "", options: .regularExpression)
        html = rewriteImages(html)
        return html.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rewriteImages(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<img\\b[^>]*>") else { return html }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        var result = html
        for match in matches.reversed() {
            let tag = ns.substring(with: match.range)
            let replacement = imageTag(from: tag)
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    /// `<img recindex="00001">` 对应图片区第 firstImageIndex + recindex - 1 条记录。
    private func imageTag(from tag: String) -> String {
        let raw = firstRegexCapture("(?i)recindex\\s*=\\s*[\"']?(\\d+)", in: tag)
            ?? firstRegexCapture("(?i)src\\s*=\\s*[\"']kindle:embed:(\\d+)", in: tag)
        guard let raw, let recindex = Int(raw), recindex > 0 else { return "" }
        if let existing = imageFiles[recindex] {
            return "<img src=\"\(existing)\"/>"
        }
        let recordIndex = firstImageIndex + recindex - 1
        guard recordIndex >= 0, recordIndex < records.count else { return "" }
        let imageData = records[recordIndex]
        guard let ext = imageExtension(of: imageData) else { return "" }

        let relative = "images/img_\(recindex).\(ext)"
        let file = directory.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? imageData.write(to: file)
        imageFiles[recindex] = relative
        return "<img src=\"\(relative)\"/>"
    }

    private func imageExtension(of data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(4))
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "jpg" }
        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "png" }
        if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "gif" }
        return nil
    }
}

// MARK: - FB2

/// FB2 是单文件 XML：元数据在 title-info，正文按 section 递归分章，
/// 图片在 `<binary>` 里是 base64。
private final class FB2FileParser {
    private let url: URL
    private let directory: URL
    private let fallbackTitle: String

    init(url: URL, directory: URL, fallbackTitle: String) {
        self.url = url
        self.directory = directory
        self.fallbackTitle = fallbackTitle
    }

    func parse() throws -> LocalBookParser.Draft {
        let data = try Data(contentsOf: url)
        guard let xml = decodeXML(data),
              let document = try? SwiftSoup.parse(xml, "", Parser.xmlParser()) else {
            throw localBookError("FB2 解析失败")
        }

        let titleInfo: Element? = try? document.select("title-info").first()
        let title = elementText(of: titleInfo, "book-title") ?? fallbackTitle
        let authorParts = ["first-name", "middle-name", "last-name"]
            .compactMap { elementText(of: titleInfo, "author > \($0)") }
        let cjkOnly = authorParts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy {
                (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
            }
        }
        let author = authorParts.isEmpty
            ? (elementText(of: titleInfo, "author") ?? "未知作者")
            : authorParts.joined(separator: cjkOnly ? "" : " ")
        let intro = elementText(of: titleInfo, "annotation")

        let imageMap = try extractImages(from: document)

        var chapters: [(title: String, html: String)] = []
        var currentTitle = ""
        var currentHTML = ""
        var started = false

        let bodies = (try? document.select("body")) ?? Elements()
        for body in bodies {
            for child in body.children() {
                let tag = child.tagName().lowercased()
                if tag == "title" {
                    if started || !currentHTML.isEmpty {
                        chapters.append((currentTitle, currentHTML))
                        currentHTML = ""
                    }
                    currentTitle = ((try? child.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    started = !currentTitle.isEmpty
                } else if tag == "section" {
                    handleSection(
                        child, imageMap: imageMap, chapters: &chapters,
                        currentTitle: &currentTitle, currentHTML: &currentHTML, started: &started
                    )
                } else {
                    render(child, imageMap: imageMap, html: &currentHTML)
                }
            }
        }
        if started || !currentHTML.isEmpty {
            chapters.append((currentTitle, currentHTML))
        }
        chapters = chapters.filter { hasVisibleContent($0.html) }
        guard !chapters.isEmpty else { throw localBookError("FB2 里没有正文") }

        return LocalBookParser.Draft(title: title, author: author, intro: intro, chapters: chapters)
    }

    private func extractImages(from document: Element) throws -> [String: String] {
        let imageDir = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

        var map: [String: String] = [:]
        let binaries = (try? document.select("binary")) ?? Elements()
        for (offset, binary) in binaries.enumerated() {
            let id = ((try? binary.attr("id")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let contentType = (try? binary.attr("content-type")) ?? ""
            let base64 = ((try? binary.text()) ?? "")
                .replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
            guard !base64.isEmpty,
                  let raw = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { continue }
            let ext = imageExtension(id: id, contentType: contentType)
            let name = "img_\(offset).\(ext)"
            try? raw.write(to: imageDir.appendingPathComponent(name))
            map[id] = "images/\(name)"
        }
        return map
    }

    private func imageExtension(id: String, contentType: String) -> String {
        let type = contentType.lowercased()
        if type.contains("jpeg") || type.contains("jpg") { return "jpg" }
        if type.contains("png") { return "png" }
        if type.contains("gif") { return "gif" }
        if type.contains("svg") { return "svg" }
        if type.contains("webp") { return "webp" }
        let ext = (id as NSString).pathExtension.lowercased()
        if ext == "jpeg" || ext == "jpg" { return "jpg" }
        return ["png", "gif", "svg", "webp"].contains(ext) ? ext : "jpg"
    }

    private func handleSection(
        _ section: Element,
        imageMap: [String: String],
        chapters: inout [(title: String, html: String)],
        currentTitle: inout String,
        currentHTML: inout String,
        started: inout Bool
    ) {
        if let titleElement = section.children().first(where: { $0.tagName().lowercased() == "title" }) {
            if started || !currentHTML.isEmpty {
                chapters.append((currentTitle, currentHTML))
                currentHTML = ""
            }
            currentTitle = ((try? titleElement.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            started = !currentTitle.isEmpty
        }
        for child in section.children() {
            let tag = child.tagName().lowercased()
            if tag == "title" { continue }
            if tag == "section" {
                handleSection(
                    child, imageMap: imageMap, chapters: &chapters,
                    currentTitle: &currentTitle, currentHTML: &currentHTML, started: &started
                )
            } else {
                render(child, imageMap: imageMap, html: &currentHTML)
            }
        }
    }

    private func render(_ element: Element, imageMap: [String: String], html: inout String) {
        let text = ((try? element.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch element.tagName().lowercased() {
        case "p":
            if !text.isEmpty { html += "<p>\(escapeHTMLEntities(text))</p>\n" }
        case "subtitle":
            if !text.isEmpty { html += "<p><b>\(escapeHTMLEntities(text))</b></p>\n" }
        case "empty-line":
            html += "<p>&nbsp;</p>\n"
        case "image":
            if let id = imageReference(element), let src = imageMap[id] {
                html += "<img src=\"\(src)\"/>\n"
            }
        case "poem", "stanza", "v", "cite", "epigraph", "text-author", "date", "table", "tr", "td", "th":
            for child in element.children() {
                render(child, imageMap: imageMap, html: &html)
            }
        default:
            if !text.isEmpty { html += "<p>\(escapeHTMLEntities(text))</p>\n" }
        }
    }

    private func imageReference(_ element: Element) -> String? {
        for name in ["l:href", "xlink:href", "href"] {
            if let value = try? element.attr(name), !value.isEmpty {
                return value.hasPrefix("#") ? String(value.dropFirst()) : value
            }
        }
        return nil
    }

    private func decodeXML(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(400), as: UTF8.self).lowercased()
        if head.contains("windows-1251") || head.contains("cp1251") {
            let encoding = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue))
            return String(data: data, encoding: String.Encoding(rawValue: encoding))
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let gbRaw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gbRaw))
            ?? String(decoding: data, as: UTF8.self)
    }
}

// MARK: - UMD

/// UMD：小端头 + 可选的章节偏移表，正文多为 UTF-16LE，可能套一层 zlib。
private final class UMDFileParser {
    private let url: URL
    private let directory: URL
    private let fallbackTitle: String

    init(url: URL, directory: URL, fallbackTitle: String) {
        self.url = url
        self.directory = directory
        self.fallbackTitle = fallbackTitle
    }

    func parse() throws -> LocalBookParser.Draft {
        let data = try Data(contentsOf: url)
        guard data.count > 40, umdByte(data, 0) == 0x55, umdByte(data, 1) == 0xAA else {
            throw localBookError("不是 UMD 文件")
        }

        let authorOffset = leUInt32(data, 4)
        let authorLength = umdByte(data, 8)
        let titleOffset = leUInt32(data, 9)
        let titleLength = umdByte(data, 13)
        let contentOffset = leUInt32(data, 14)
        let contentLength = leUInt32(data, 18)
        let chapterOffset = leUInt32(data, 22)
        let chapterLength = leUInt32(data, 26)

        guard contentOffset > 0, contentLength > 0,
              contentOffset + contentLength <= data.count else {
            throw localBookError("UMD 正文区损坏")
        }

        let title = umdString(data, offset: titleOffset, length: titleLength) ?? fallbackTitle
        let author = umdString(data, offset: authorOffset, length: authorLength) ?? "未知作者"

        var raw = data.subdata(in: contentOffset..<(contentOffset + contentLength))
        raw = inflateIfNeeded(raw)
        let fullText = decodeUMDText(raw)
        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw localBookError("UMD 正文是空的")
        }

        var entries: [(title: String, start: Int)] = []
        if chapterOffset > 0, chapterLength > 0, chapterOffset + chapterLength <= data.count {
            entries = parseChapterTable(data, offset: chapterOffset, length: chapterLength)
        }

        var scale = 1
        if let last = entries.last, last.start > 0 {
            if last.start >= raw.count {
                scale = 2
            } else if last.start * 2 <= raw.count, last.start * 2 > raw.count * 3 / 4 {
                scale = 2
            }
        }

        var chapters: [(title: String, html: String)] = []
        for (index, entry) in entries.enumerated() {
            let start = min(entry.start * scale, raw.count)
            let end = index + 1 < entries.count
                ? min(entries[index + 1].start * scale, raw.count)
                : raw.count
            guard end > start else { continue }
            let body = decodeUMDText(raw.subdata(in: start..<end))
            let html = paragraphsHTML(from: body)
            guard hasVisibleContent(html) else { continue }
            chapters.append((entry.title.isEmpty ? fallbackTitle : entry.title, html))
        }

        if chapters.isEmpty {
            chapters = splitByHeadingPatterns(fullText)
        }
        guard !chapters.isEmpty else { throw localBookError("UMD 正文解析不出来") }

        return LocalBookParser.Draft(title: title, author: author, intro: nil, chapters: chapters)
    }

    private func parseChapterTable(_ data: Data, offset: Int, length: Int) -> [(title: String, start: Int)] {
        var entries: [(title: String, start: Int)] = []
        var cursor = offset
        let limit = offset + length
        while cursor + 6 <= limit {
            let nameLength = leUInt16(data, cursor)
            guard nameLength > 0, nameLength <= 2048, nameLength % 2 == 0,
                  cursor + 2 + nameLength + 4 <= limit else { break }
            let nameData = data.subdata(in: (cursor + 2)..<(cursor + 2 + nameLength))
            let name = (String(data: nameData, encoding: .utf16LittleEndian) ?? "")
                .replacingOccurrences(of: "\u{0000}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let start = leUInt32(data, cursor + 2 + nameLength)
            guard !name.isEmpty, !name.contains("\u{FFFD}") else { break }
            entries.append((name, start))
            cursor += 2 + nameLength + 4
        }

        var previous = -1
        for entry in entries {
            if entry.start < previous { return [] }
            previous = entry.start
        }
        return entries
    }

    private func inflateIfNeeded(_ data: Data) -> Data {
        if data.first == 0x01 {
            if let inflated = try? (data.dropFirst() as NSData).decompressed(using: .zlib) {
                return inflated as Data
            }
        }
        if data.first == 0x78 {
            if let inflated = try? (data as NSData).decompressed(using: .zlib) {
                return inflated as Data
            }
        }
        return data
    }

    private func decodeUMDText(_ data: Data) -> String {
        var text: String?
        if let utf16 = String(data: data, encoding: .utf16LittleEndian) {
            let broken = utf16.reduce(0) { $1 == "\u{FFFD}" ? $0 + 1 : $0 }
            if broken * 20 < max(1, utf16.count) { text = utf16 }
        }
        if text == nil { text = String(data: data, encoding: .utf8) }
        let result = text ?? String(decoding: data, as: UTF8.self)
        return result
            .replacingOccurrences(of: "\u{0000}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func umdString(_ data: Data, offset: Int, length: Int) -> String? {
        guard length > 0, offset > 0, offset + length <= data.count else { return nil }
        let value = String(data: data.subdata(in: offset..<(offset + length)), encoding: .utf16LittleEndian)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func splitByHeadingPatterns(_ text: String) -> [(title: String, html: String)] {
        let pattern = "(?m)^[ \\t]*(第[0-9一二三四五六七八九十百千零〇两]{1,8}[章回节卷][^\\n]{0,40})$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [(fallbackTitle, paragraphsHTML(from: text))]
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [(fallbackTitle, paragraphsHTML(from: text))] }

        var result: [(title: String, html: String)] = []
        for (index, match) in matches.enumerated() {
            let start = match.range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            guard end > start else { continue }
            let title = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let segment = ns.substring(with: NSRange(location: start, length: end - start))
            let html = paragraphsHTML(from: segment)
            guard hasVisibleContent(html) else { continue }
            result.append((title, html))
        }
        return result
    }
}
