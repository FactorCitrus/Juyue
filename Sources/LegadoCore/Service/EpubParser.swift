import Foundation
import ZIPFoundation
import SwiftSoup

public struct ParsedEpub {
    public let book: Book
    public let chapters: [BookChapter]
    public let extractedDirectory: URL
}

public class EpubParser {
    public static let shared = EpubParser()

    public init() {}

    /// Parses an EPUB file, unzipping to cache/documents directory and extracting metadata & TOC
    public func parse(epubUrl: URL, destinationDir: URL? = nil) throws -> ParsedEpub {
        let fileManager = FileManager.default

        // Compute destination directory
        let dest: URL
        if let destinationDir = destinationDir {
            dest = destinationDir
        } else {
            let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let bookId = CryptoUtils.md5(epubUrl.absoluteString)
            dest = docsDir.appendingPathComponent("Books/EPUB/\(bookId)")
        }

        if !fileManager.fileExists(atPath: dest.path) {
            try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
            // Unzip EPUB archive
            try fileManager.unzipItem(at: epubUrl, to: dest)
        }

        // 1. Locate root OPF file via META-INF/container.xml
        let containerUrl = dest.appendingPathComponent("META-INF/container.xml")
        guard fileManager.fileExists(atPath: containerUrl.path) else {
            throw NSError(domain: "EpubParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing META-INF/container.xml"])
        }

        let containerData = try Data(contentsOf: containerUrl)
        let containerXml = String(data: containerData, encoding: .utf8) ?? ""
        let containerDoc = try SwiftSoup.parse(containerXml, "", Parser.xmlParser())
        guard let rootfile = try containerDoc.select("rootfile").first(),
              let opfRelativePath = try? rootfile.attr("full-path"), !opfRelativePath.isEmpty else {
            throw NSError(domain: "EpubParser", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to locate root OPF in container.xml"])
        }

        let opfUrl = dest.appendingPathComponent(opfRelativePath)
        let opfBaseDir = opfUrl.deletingLastPathComponent()

        // 2. Parse OPF file
        let opfData = try Data(contentsOf: opfUrl)
        let opfXml = String(data: opfData, encoding: .utf8) ?? ""
        let opfDoc = try SwiftSoup.parse(opfXml, "", Parser.xmlParser())

        // Extract metadata
        let title = (try? opfDoc.select("dc|title, title").first()?.text()) ?? epubUrl.deletingPathExtension().lastPathComponent
        let author = (try? opfDoc.select("dc|creator, creator").first()?.text()) ?? "未知作者"
        let intro = try? opfDoc.select("dc|description, description").first()?.text()

        // Manifest map: id -> href
        var manifestMap: [String: String] = [:]
        var navHref: String? = nil
        var ncxHref: String? = nil

        let items = try opfDoc.select("manifest > item")
        for item in items {
            let id = try item.attr("id")
            let href = try item.attr("href")
            let properties = try item.attr("properties")
            let mediaType = try item.attr("media-type")

            manifestMap[id] = href
            if properties.contains("nav") || href.hasSuffix("nav.xhtml") {
                navHref = href
            }
            if mediaType == "application/x-dtbncx+xml" || href.hasSuffix(".ncx") {
                ncxHref = href
            }
        }

        // Spine order
        var spineHrefs: [String] = []
        let spineItems = try opfDoc.select("spine > itemref")
        for itemref in spineItems {
            let idref = try itemref.attr("idref")
            if let href = manifestMap[idref] {
                spineHrefs.append(href)
            }
        }

        // 3. Parse Table of Contents
        var parsedChapters: [BookChapter] = []

        // Attempt A: EPUB 3 Nav Document
        if let navHref = navHref {
            let navUrl = opfBaseDir.appendingPathComponent(navHref)
            if let navData = try? Data(contentsOf: navUrl),
               let navHtml = String(data: navData, encoding: .utf8) {
                parsedChapters = parseNavDocument(navHtml: navHtml, baseDir: navUrl.deletingLastPathComponent())
            }
        }

        // Attempt B: EPUB 2 NCX Document
        if parsedChapters.isEmpty, let ncxHref = ncxHref {
            let ncxUrl = opfBaseDir.appendingPathComponent(ncxHref)
            if let ncxData = try? Data(contentsOf: ncxUrl),
               let ncxXml = String(data: ncxData, encoding: .utf8) {
                parsedChapters = parseNcxDocument(ncxXml: ncxXml, baseDir: ncxUrl.deletingLastPathComponent())
            }
        }

        // Attempt C: Fallback to spine items
        if parsedChapters.isEmpty {
            for (idx, spineHref) in spineHrefs.enumerated() {
                let fileUrl = opfBaseDir.appendingPathComponent(spineHref)
                let title = spineHref.components(separatedBy: "/").last?.replacingOccurrences(of: ".xhtml", with: "").replacingOccurrences(of: ".html", with: "") ?? "第 \(idx + 1) 章"
                parsedChapters.append(BookChapter(
                    bookUrl: epubUrl.absoluteString,
                    url: fileUrl.absoluteString,
                    title: title,
                    index: idx
                ))
            }
        } else {
            // Assign index and bookUrl to parsed chapters
            for i in 0..<parsedChapters.count {
                parsedChapters[i].index = i
                parsedChapters[i].bookUrl = epubUrl.absoluteString
            }
        }

        let book = Book(
            bookUrl: epubUrl.absoluteString,
            name: title,
            author: author,
            kind: "EPUB 本地书籍",
            coverUrl: nil,
            intro: intro,
            origin: "local",
            originName: "本地导入",
            tocUrl: opfUrl.absoluteString,
            totalChapterNum: parsedChapters.count
        )

        return ParsedEpub(book: book, chapters: parsedChapters, extractedDirectory: dest)
    }

    private func parseNavDocument(navHtml: String, baseDir: URL) -> [BookChapter] {
        var chapters: [BookChapter] = []
        guard let doc = try? SwiftSoup.parse(navHtml) else { return [] }

        // Find <nav epub:type="toc"> or any <nav>
        let nav = (try? doc.select("nav[epub|type=toc]").first()) ?? (try? doc.select("nav").first()) ?? doc
        guard let links = try? nav.select("a") else { return [] }

        for (idx, link) in links.enumerated() {
            guard let title = try? link.text(), !title.trimmingCharacters(in: .whitespaces).isEmpty,
                  let href = try? link.attr("href"), !href.isEmpty else {
                continue
            }

            // Skip internal self-links to TOC (e.g. href="#toc")
            if href.starts(with: "#") {
                continue
            }

            let fullUrlString = resolveEpubHref(href: href, baseDir: baseDir)
            chapters.append(BookChapter(
                bookUrl: "",
                url: fullUrlString,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                index: idx
            ))
        }

        return chapters
    }

    private func parseNcxDocument(ncxXml: String, baseDir: URL) -> [BookChapter] {
        var chapters: [BookChapter] = []
        guard let doc = try? SwiftSoup.parse(ncxXml, "", Parser.xmlParser()),
              let navPoints = try? doc.select("navPoint") else { return [] }

        for (idx, np) in navPoints.enumerated() {
            let label = (try? np.select("navLabel > text").first()?.text()) ?? "第 \(idx + 1) 章"
            let src = (try? np.select("content").first()?.attr("src")) ?? ""
            guard !src.isEmpty, !src.starts(with: "#") else { continue }

            let fullUrlString = resolveEpubHref(href: src, baseDir: baseDir)
            chapters.append(BookChapter(
                bookUrl: "",
                url: fullUrlString,
                title: label.trimmingCharacters(in: .whitespacesAndNewlines),
                index: idx
            ))
        }

        return chapters
    }

    private func resolveEpubHref(href: String, baseDir: URL) -> String {
        let parts = href.components(separatedBy: "#")
        let relativePath = parts[0]
        let anchor = parts.count > 1 ? parts[1] : nil

        let fileUrl: URL
        if relativePath.isEmpty {
            fileUrl = baseDir
        } else {
            fileUrl = URL(fileURLWithPath: relativePath, relativeTo: baseDir).standardizedFileURL
        }

        if let anchor = anchor, !anchor.isEmpty {
            return "\(fileUrl.absoluteString)#\(anchor)"
        } else {
            return fileUrl.absoluteString
        }
    }

    /// Extracts clean readable text from an XHTML/HTML chapter file or fragment URL
    public static func extractChapterContent(fromUrlString urlString: String, bookUrl: String? = nil) -> String {
        var cleanUrlString = urlString
        if cleanUrlString.contains("%23") && !cleanUrlString.contains("#") {
            cleanUrlString = cleanUrlString.replacingOccurrences(of: "%23", with: "#")
        }

        var pathPart = cleanUrlString
        var anchor: String? = nil

        if let hashIdx = cleanUrlString.firstIndex(of: "#") {
            pathPart = String(cleanUrlString[..<hashIdx])
            let anchorStr = String(cleanUrlString[cleanUrlString.index(after: hashIdx)...])
            if !anchorStr.isEmpty {
                anchor = anchorStr
            }
        }

        var localPath = ""
        if let u = URL(string: pathPart), u.isFileURL {
            localPath = u.path
        } else if let u = URL(string: pathPart.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pathPart), u.isFileURL {
            localPath = u.path
        } else {
            localPath = pathPart.replacingOccurrences(of: "file://", with: "")
        }

        if let unescaped = localPath.removingPercentEncoding, !unescaped.isEmpty {
            localPath = unescaped
        }

        var targetFileUrl = URL(fileURLWithPath: localPath)
        let fm = FileManager.default

        // Handle iOS sandbox container directory relocation
        if !fm.fileExists(atPath: targetFileUrl.path) {
            let fileName = targetFileUrl.lastPathComponent.removingPercentEncoding ?? targetFileUrl.lastPathComponent
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

            // 1. Check under Documents/Books/EPUB/<bookId>
            if let bookUrl = bookUrl {
                let bookId = CryptoUtils.md5(bookUrl)
                let bookDir = docs.appendingPathComponent("Books/EPUB/\(bookId)")
                if let enumerator = fm.enumerator(at: bookDir, includingPropertiesForKeys: nil) {
                    for case let file as URL in enumerator {
                        if file.lastPathComponent == fileName {
                            targetFileUrl = file
                            break
                        }
                    }
                }
            }

            // 2. Fallback: Search all of Documents/Books/EPUB
            if !fm.fileExists(atPath: targetFileUrl.path) {
                let epubRoot = docs.appendingPathComponent("Books/EPUB")
                if let enumerator = fm.enumerator(at: epubRoot, includingPropertiesForKeys: nil) {
                    for case let file as URL in enumerator {
                        if file.lastPathComponent == fileName {
                            targetFileUrl = file
                            break
                        }
                    }
                }
            }
        }

        guard let data = try? Data(contentsOf: targetFileUrl),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .ascii) else {
            return ""
        }

        guard let doc = try? SwiftSoup.parse(html) else { return html }

        let baseDir = targetFileUrl.deletingLastPathComponent()

        // If specific anchor requested, extract that element or section
        if let anchor = anchor, let targetEl = try? doc.select("#\(anchor)").first() {
            let directText = cleanHtmlText(element: targetEl, baseDir: baseDir)
            // If targetEl has extensive text AND contains paragraphs, it might be a full section container
            if (try? targetEl.select("p").count) ?? 0 > 3 && directText.count > 500 {
                return directText
            }

            // Find top-level container below body
            var rootEl: Element = targetEl
            while let parent = rootEl.parent(), parent.tagName() != "body" && parent.tagName() != "html" {
                rootEl = parent
            }

            // Collect rootEl and subsequent siblings until the next chapter heading
            var sectionHtml = ""
            var current: Element? = rootEl
            while let el = current {
                sectionHtml += (try? el.outerHtml()) ?? ""
                current = try? el.nextElementSibling()
                if let next = current {
                    let hasNextAnchor = (try? next.select("[id^=chapter]").first()) != nil
                    if hasNextAnchor || next.hasClass("chaptertitle") || next.hasClass("volumetitle") {
                        break
                    }
                }
            }

            if !sectionHtml.isEmpty, let sectionDoc = try? SwiftSoup.parse(sectionHtml) {
                let sectionText = cleanHtmlText(element: sectionDoc, baseDir: baseDir)
                if !sectionText.isEmpty {
                    return sectionText
                }
            }

            if !directText.isEmpty {
                return directText
            }
        }

        // If anchor is nil, but file contains multiple chapters/volumes (e.g. Volume_0.xhtml with multiple chapters)
        if let body = doc.body() {
            let chapterHeadings = (try? body.select(".chaptertitle, [id^=chapter]")) ?? Elements()
            if !chapterHeadings.isEmpty() {
                var introHtml = ""
                var current: Element? = body.children().first()
                while let el = current {
                    if el.hasClass("chaptertitle") || (try? el.select("[id^=chapter]").first()) != nil {
                        break
                    }
                    introHtml += (try? el.outerHtml()) ?? ""
                    current = try? el.nextElementSibling()
                }
                if let introDoc = try? SwiftSoup.parse(introHtml) {
                    let introText = cleanHtmlText(element: introDoc, baseDir: baseDir)
                    if !introText.isEmpty {
                        return "\(introText)\n\n（本节为分卷导读，请点击“下一章”或通过目录阅读正文）"
                    }
                }
            }

            return cleanHtmlText(element: body, baseDir: baseDir)
        }

        return cleanHtmlText(element: doc, baseDir: baseDir)
    }

    /// Legacy overload for compatibility with URL
    public static func extractChapterContent(from fileOrFragmentUrl: URL) -> String {
        return extractChapterContent(fromUrlString: fileOrFragmentUrl.absoluteString)
    }

    private static func cleanHtmlText(element: Element, baseDir: URL? = nil) -> String {
        // 1. Process <img> and SVG <image> elements: resolve src and insert placeholder
        if let images = try? element.select("img, image") {
            for img in images {
                var src = (try? img.attr("src")) ?? ""
                if src.isEmpty {
                    src = (try? img.attr("xlink:href")) ?? ""
                }
                if src.isEmpty {
                    src = (try? img.attr("href")) ?? ""
                }
                if !src.isEmpty {
                    var resolvedSrc = src
                    if let baseDir = baseDir, !src.starts(with: "http://") && !src.starts(with: "https://") && !src.starts(with: "file://") {
                        resolvedSrc = URL(string: src, relativeTo: baseDir)?.standardizedFileURL.absoluteString ?? src
                    }
                    _ = try? img.before("__IMG_BLOCK__\(resolvedSrc)__IMG_BLOCK__")
                }
            }
        }

        // 2. Process <br> elements: insert unique newline marker so SwiftSoup doesn't collapse them into spaces
        if let brs = try? element.select("br") {
            for br in brs {
                _ = try? br.before("__BR_NEWLINE__")
            }
        }

        // 3. Process block elements: <p>, <h1>-<h6>
        if let blocks = try? element.select("p, h1, h2, h3, h4, h5, h6") {
            for b in blocks {
                _ = try? b.before("__P_BREAK__")
                _ = try? b.after("__P_BREAK__")
            }
        }

        // 4. Extract text
        var text = (try? element.text()) ?? ""

        // 5. Restore newlines and image tags
        text = text.replacingOccurrences(of: "__BR_NEWLINE__", with: "\n")
        text = text.replacingOccurrences(of: "__P_BREAK__", with: "\n\n")

        // Replace __IMG_BLOCK__...__IMG_BLOCK__ with \n\n[image:...]\n\n
        if let regex = try? NSRegularExpression(pattern: "__IMG_BLOCK__(.*?)__IMG_BLOCK__") {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: "\n\n[image:$1]\n\n"
            )
        }

        // Clean up excessive blank lines
        text = text.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
