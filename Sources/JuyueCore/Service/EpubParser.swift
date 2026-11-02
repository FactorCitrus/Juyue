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

    public func parse(epubUrl: URL, destinationDir: URL? = nil) throws -> ParsedEpub {
        let directory = try EpubWorkspace.prepare(epubUrl: epubUrl, destination: destinationDir)
        let package = try EpubPackageReader.read(
            in: directory,
            fallbackTitle: epubUrl.deletingPathExtension().lastPathComponent
        )

        var chapters = EpubNavigation.catalog(package)
        if chapters.isEmpty {
            chapters = EpubNavigation.spine(package, epubUrl: epubUrl)
        } else {
            for position in chapters.indices {
                chapters[position].index = position
                chapters[position].bookUrl = epubUrl.absoluteString
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

    public static func extractChapterContent(
        fromUrlString urlString: String,
        bookUrl: String? = nil
    ) -> String {
        let normalized = urlString.contains("%23") && !urlString.contains("#")
            ? urlString.replacingOccurrences(of: "%23", with: "#")
            : urlString

        let parts = normalized.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let pathPart = String(parts[0])
        let anchor = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil

        var fileURL = EpubFileLocator.localURL(pathPart)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = EpubFileLocator.relocated(named: fileURL.lastPathComponent, bookUrl: bookUrl) ?? fileURL
        }
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        guard let html = EpubTextDecoder.decode(data) else { return "" }
        guard let document = try? SwiftSoup.parse(html) else { return html }

        let base = fileURL.deletingLastPathComponent()
        if let anchor, let target = try? document.select("#\(anchor)").first() {
            if let slice = EpubContentRenderer.anchored(target, anchor: anchor, base: base) {
                return slice
            }
        }

        if let body = document.body() {
            let hasChapterHeadings = (try? body.select(".chaptertitle, [id^=chapter]"))?.isEmpty() == false
            if hasChapterHeadings, let intro = EpubContentRenderer.volumeIntro(body: body, base: base) {
                return intro
            }
            return EpubContentRenderer.plain(body, base: base)
        }
        return EpubContentRenderer.plain(document, base: base)
    }

    public static func extractChapterContent(from fileOrFragmentUrl: URL) -> String {
        extractChapterContent(fromUrlString: fileOrFragmentUrl.absoluteString)
    }
}

// MARK: - 解包与 OPF

private enum EpubWorkspace {
    static func prepare(epubUrl: URL, destination: URL?) throws -> URL {
        let manager = FileManager.default
        let target: URL

        if let destination {
            target = destination
        } else {
            let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fingerprint = CryptoUtils.md5(epubUrl.absoluteString)
            target = documents
                .appendingPathComponent("Books/EPUB", isDirectory: true)
                .appendingPathComponent(fingerprint, isDirectory: true)
        }

        if !manager.fileExists(atPath: target.path) {
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            try manager.unzipItem(at: epubUrl, to: target)
        }
        return target
    }
}

private struct EpubManifestItem {
    let href: String
    let mediaType: String
    let properties: String
}

private struct EpubPackageDocument {
    let opfURL: URL
    let title: String
    let author: String
    let intro: String?
    let manifest: [String: EpubManifestItem]
    let spine: [String]
    let navHref: String?
    let ncxHref: String?
}

private enum EpubPackageReader {
    static func read(in directory: URL, fallbackTitle: String) throws -> EpubPackageDocument {
        let containerURL = directory.appendingPathComponent("META-INF/container.xml")
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw error(code: 1, text: "Missing META-INF/container.xml")
        }

        let container = try SwiftSoup.parse(
            try readText(at: containerURL),
            "",
            Parser.xmlParser()
        )
        guard let rootfile = try container.select("rootfile").first() else {
            throw error(code: 2, text: "Failed to locate root OPF in container.xml")
        }

        let opfPath = try rootfile.attr("full-path")
        guard !opfPath.isEmpty else {
            throw error(code: 2, text: "Failed to locate root OPF in container.xml")
        }

        let opfURL = directory.appendingPathComponent(opfPath)
        let opf = try SwiftSoup.parse(try readText(at: opfURL), "", Parser.xmlParser())

        let title = text(in: opf, selector: "dc|title, title") ?? fallbackTitle
        let author = text(in: opf, selector: "dc|creator, creator") ?? "未知作者"
        let intro = text(in: opf, selector: "dc|description, description")

        var manifest: [String: EpubManifestItem] = [:]
        var nav: String?
        var ncx: String?

        if let items = try? opf.select("manifest > item") {
            for item in items {
                let id = (try? item.attr("id")) ?? ""
                guard !id.isEmpty else { continue }
                let href = (try? item.attr("href")) ?? ""
                let mediaType = (try? item.attr("media-type")) ?? ""
                let properties = (try? item.attr("properties")) ?? ""

                manifest[id] = EpubManifestItem(href: href, mediaType: mediaType, properties: properties)
                if properties.contains("nav") || href.hasSuffix("nav.xhtml") {
                    nav = href
                }
                if mediaType == "application/x-dtbncx+xml" || href.hasSuffix(".ncx") {
                    ncx = href
                }
            }
        }

        var readingOrder: [String] = []
        if let refs = try? opf.select("spine > itemref") {
            for ref in refs {
                let idref = (try? ref.attr("idref")) ?? ""
                if let item = manifest[idref] {
                    readingOrder.append(item.href)
                }
            }
        }

        return EpubPackageDocument(
            opfURL: opfURL,
            title: title,
            author: author,
            intro: intro,
            manifest: manifest,
            spine: readingOrder,
            navHref: nav,
            ncxHref: ncx
        )
    }

    private static func text(in document: Document, selector: String) -> String? {
        guard let node = try? document.select(selector).first() else { return nil }
        return try? node.text()
    }

    private static func readText(at url: URL) throws -> String {
        let bytes = try Data(contentsOf: url)
        return String(data: bytes, encoding: .utf8) ?? ""
    }

    private static func error(code: Int, text: String) -> NSError {
        NSError(domain: "EpubParser", code: code, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

// MARK: - 目录

private enum EpubNavigation {
    static func catalog(_ package: EpubPackageDocument) -> [BookChapter] {
        let opfDirectory = package.opfURL.deletingLastPathComponent()

        if let href = package.navHref {
            let navURL = opfDirectory.appendingPathComponent(href)
            if let html = try? readText(at: navURL) {
                let items = fromNavigation(html, base: navURL.deletingLastPathComponent())
                if !items.isEmpty { return items }
            }
        }

        if let href = package.ncxHref {
            let ncxURL = opfDirectory.appendingPathComponent(href)
            if let xml = try? readText(at: ncxURL) {
                let items = fromNCX(xml, base: ncxURL.deletingLastPathComponent())
                if !items.isEmpty { return items }
            }
        }

        return []
    }

    static func spine(_ package: EpubPackageDocument, epubUrl: URL) -> [BookChapter] {
        let base = package.opfURL.deletingLastPathComponent()
        return package.spine.enumerated().map { offset, href in
            let fileURL = base.appendingPathComponent(href)
            let rawTitle = fileURL.lastPathComponent
            let title = [".xhtml", ".html"].reduce(rawTitle) { current, suffix in
                current.hasSuffix(suffix) ? String(current.dropLast(suffix.count)) : current
            }
            return BookChapter(
                bookUrl: epubUrl.absoluteString,
                url: fileURL.absoluteString,
                title: title.isEmpty ? "第 \(offset + 1) 章" : title,
                index: offset
            )
        }
    }

    private static func fromNavigation(_ html: String, base: URL) -> [BookChapter] {
        guard let document = try? SwiftSoup.parse(html) else { return [] }

        let scope = (try? document.select("nav[epub|type=toc]").first())
            ?? (try? document.select("nav").first())
            ?? document
        guard let links = try? scope.select("a") else { return [] }

        var items: [BookChapter] = []
        for link in links {
            let href = (try? link.attr("href")) ?? ""
            let label = ((try? link.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty, !href.hasPrefix("#"), !label.isEmpty else { continue }
            items.append(BookChapter(
                bookUrl: "",
                url: join(href: href, base: base),
                title: label,
                index: items.count
            ))
        }
        return items
    }

    private static func fromNCX(_ xml: String, base: URL) -> [BookChapter] {
        guard let document = try? SwiftSoup.parse(xml, "", Parser.xmlParser()),
              let points = try? document.select("navPoint") else {
            return []
        }

        var items: [BookChapter] = []
        for point in points {
            let source = (try? point.select("content").first()?.attr("src")) ?? ""
            guard !source.isEmpty, !source.hasPrefix("#") else { continue }

            let rawLabel = ((try? point.select("navLabel > text").first()?.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(BookChapter(
                bookUrl: "",
                url: join(href: source, base: base),
                title: rawLabel.isEmpty ? "第 \(items.count + 1) 章" : rawLabel,
                index: items.count
            ))
        }
        return items
    }

    private static func join(href: String, base: URL) -> String {
        let pieces = href.components(separatedBy: "#")
        let path = pieces.first ?? ""
        let anchor = pieces.count > 1 ? pieces[1] : ""
        let file = path.isEmpty
            ? base
            : URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        return anchor.isEmpty ? file.absoluteString : "\(file.absoluteString)#\(anchor)"
    }

    private static func readText(at url: URL) throws -> String {
        let bytes = try Data(contentsOf: url)
        return String(data: bytes, encoding: .utf8) ?? ""
    }
}

// MARK: - 正文渲染

private enum EpubContentRenderer {
    static func anchored(_ target: Element, anchor: String, base: URL) -> String? {
        let direct = plain(target, base: base)
        let paragraphCount = (try? target.select("p").count) ?? 0
        if paragraphCount > 3, direct.count > 500 {
            return direct
        }

        var container = target
        while let parent = container.parent(),
              parent.tagName() != "body",
              parent.tagName() != "html" {
            container = parent
        }

        var markup = ""
        var cursor: Element? = container
        while let node = cursor {
            markup += (try? node.outerHtml()) ?? ""
            cursor = try? node.nextElementSibling()
            if let next = cursor {
                let nextIsChapter = (try? next.select("[id^=chapter]").first()) != nil
                if nextIsChapter || next.hasClass("chaptertitle") || next.hasClass("volumetitle") {
                    break
                }
            }
        }

        if !markup.isEmpty, let fragment = try? SwiftSoup.parse(markup) {
            let text = plain(fragment, base: base)
            if !text.isEmpty { return text }
        }
        return direct.isEmpty ? nil : direct
    }

    static func volumeIntro(body: Element, base: URL) -> String? {
        var markup = ""
        var cursor: Element? = body.children().first()
        while let node = cursor {
            let startsChapter = node.hasClass("chaptertitle")
                || (try? node.select("[id^=chapter]").first()) != nil
            if startsChapter { break }
            markup += (try? node.outerHtml()) ?? ""
            cursor = try? node.nextElementSibling()
        }

        guard !markup.isEmpty, let fragment = try? SwiftSoup.parse(markup) else { return nil }
        let text = plain(fragment, base: base)
        guard !text.isEmpty else { return nil }
        return text + "\n\n（本节为分卷导读，请点击“下一章”或通过目录阅读正文）"
    }

    static func plain(_ element: Element, base: URL) -> String {
        injectImageMarkers(in: element, base: base)
        injectLineBreaks(in: element)
        injectParagraphBreaks(in: element)

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

    private static func injectImageMarkers(in element: Element, base: URL) {
        guard let images = try? element.select("img, image") else { return }
        for image in images {
            var source = (try? image.attr("src")) ?? ""
            if source.isEmpty { source = (try? image.attr("xlink:href")) ?? "" }
            if source.isEmpty { source = (try? image.attr("href")) ?? "" }
            guard !source.isEmpty else { continue }

            let resolved = EpubFileLocator.isRemoteOrFile(source)
                ? source
                : URL(string: source, relativeTo: base)?.standardizedFileURL.absoluteString ?? source
            _ = try? image.before("__IMG_BLOCK__\(resolved)__IMG_BLOCK__")
        }
    }

    private static func injectLineBreaks(in element: Element) {
        guard let breaks = try? element.select("br") else { return }
        for lineBreak in breaks {
            _ = try? lineBreak.before("__BR_NEWLINE__")
        }
    }

    private static func injectParagraphBreaks(in element: Element) {
        guard let blocks = try? element.select("p, h1, h2, h3, h4, h5, h6") else { return }
        for block in blocks {
            _ = try? block.before("__P_BREAK__")
            _ = try? block.after("__P_BREAK__")
        }
    }
}

// MARK: - 路径

private enum EpubFileLocator {
    static func localURL(_ pathPart: String) -> URL {
        if let direct = URL(string: pathPart), direct.isFileURL {
            return URL(fileURLWithPath: decode(direct.path))
        }

        let escaped = pathPart.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pathPart
        if let encoded = URL(string: escaped), encoded.isFileURL {
            return URL(fileURLWithPath: decode(encoded.path))
        }

        let stripped = pathPart.hasPrefix("file://")
            ? String(pathPart.dropFirst("file://".count))
            : pathPart
        return URL(fileURLWithPath: decode(stripped))
    }

    static func relocated(named name: String, bookUrl: String?) -> URL? {
        let manager = FileManager.default
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("Books/EPUB", isDirectory: true)

        var roots: [URL] = []
        if let bookUrl, !bookUrl.isEmpty {
            roots.append(root.appendingPathComponent(CryptoUtils.md5(bookUrl), isDirectory: true))
        }
        roots.append(root)

        for candidate in roots where manager.fileExists(atPath: candidate.path) {
            guard let walker = manager.enumerator(at: candidate, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let file as URL in walker where file.lastPathComponent == name {
                return file
            }
        }
        return nil
    }

    static func isRemoteOrFile(_ source: String) -> Bool {
        source.hasPrefix("http://") || source.hasPrefix("https://") || source.hasPrefix("file://")
    }

    private static func decode(_ path: String) -> String {
        guard let decoded = path.removingPercentEncoding, !decoded.isEmpty else { return path }
        return decoded
    }
}

private enum EpubTextDecoder {
    static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .ascii)
    }
}
