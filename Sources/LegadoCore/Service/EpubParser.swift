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
