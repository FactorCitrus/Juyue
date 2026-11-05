import Foundation
import ZIPFoundation

// MARK: - 下载链接识别

/// 正文/网页里一条链接该走哪条路。
public enum DownloadedLinkKind: Equatable, Sendable {
    case importDeepLink     // legado:// / juyue://
    case externalDeepLink   // 其它 App 的 scheme
    case downloadable       // http(s) 且看起来是文件
    case data
    case blob
    case web                // 普通网页
    case other
}

public enum DownloadLinkClassifier {
    public static let downloadExtensions: Set<String> = [
        "txt", "json", "ttf", "otf", "ttc", "zip", "epub", "pdf",
        "mobi", "azw3", "cbz", "cb7"
    ]

    public static let binaryMIMETypes: Set<String> = [
        "application/json",
        "application/octet-stream",
        "application/zip",
        "application/x-zip-compressed",
        "application/pdf",
        "application/epub+zip",
        "application/epub",
        "application/x-mobipocket-ebook",
        "application/vnd.amazon.ebook",
        "application/x-cbz",
        "application/x-cb7",
        "application/gzip",
        "application/x-gzip",
        "font/ttf", "font/otf", "font/collection",
        "application/font-sfnt",
        "application/x-font-ttf",
        "application/x-font-otf",
        "application/vnd.ms-opentype"
    ]

    public static func schemeKind(_ url: URL) -> DownloadedLinkKind {
        switch (url.scheme ?? "").lowercased() {
        case "juyue", "legado":
            return .importDeepLink
        case "data":
            return .data
        case "blob":
            return .blob
        case "http", "https":
            return isDownloadable(url) ? .downloadable : .web
        case "":
            return .other
        default:
            return .externalDeepLink
        }
    }

    public static func fileExtension(of url: URL) -> String {
        url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func isDownloadable(_ url: URL) -> Bool {
        downloadExtensions.contains(fileExtension(of: url))
    }

    public static func normalizedMIME(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let base = raw.split(separator: ";", maxSplits: 1).first.map(String.init) ?? raw
        return base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func isBinaryMIME(_ mime: String?) -> Bool {
        binaryMIMETypes.contains(normalizedMIME(mime))
    }

    public static func contentDisposition(_ header: String?) -> (isAttachment: Bool, filename: String?) {
        guard let header, !header.isEmpty else { return (false, nil) }
        let ns = header as NSString

        let attachmentPattern = #"(?i)^\s*attachment\b"#
        let isAttachment = (try? NSRegularExpression(pattern: attachmentPattern))?
            .firstMatch(in: header, range: NSRange(location: 0, length: ns.length)) != nil

        let patterns = [
            #"(?i)filename\*\s*=\s*(?:utf-8)?''([^;]+)"#,
            #"(?i)filename\s*=\s*"([^"]+)""#,
            #"(?i)filename\s*=\s*([^;]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            guard let match = regex.firstMatch(in: header, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges > 1 else { continue }
            var value = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !value.isEmpty else { continue }
            return (isAttachment, value.removingPercentEncoding ?? value)
        }
        return (isAttachment, nil)
    }

    public static func isAttachment(_ header: String?) -> Bool {
        contentDisposition(header).isAttachment
    }

    /// 导航代理的合并判断：`<a download>`、`Content-Disposition: attachment`、
    /// 二进制 MIME 或已知文件扩展名，任一命中都该交给下载器。
    public static func shouldPerformDownload(
        navigationActionPrefersDownload: Bool,
        url: URL,
        contentDisposition: String? = nil,
        mimeType: String? = nil
    ) -> Bool {
        if navigationActionPrefersDownload { return true }
        if isAttachment(contentDisposition) { return true }
        if isBinaryMIME(mimeType) { return true }
        return isDownloadable(url)
    }

    public static func fileExtension(forMIME mime: String?) -> String? {
        switch normalizedMIME(mime) {
        case "application/json": return "json"
        case "application/zip", "application/x-zip-compressed": return "zip"
        case "application/pdf": return "pdf"
        case "application/epub+zip", "application/epub": return "epub"
        case "application/x-mobipocket-ebook": return "mobi"
        case "application/vnd.amazon.ebook": return "azw3"
        case "application/x-cbz": return "cbz"
        case "application/x-cb7": return "cb7"
        case "font/ttf", "application/x-font-ttf", "application/font-sfnt": return "ttf"
        case "font/otf", "application/x-font-otf", "application/vnd.ms-opentype": return "otf"
        case "font/collection": return "ttc"
        default: return nil
        }
    }

    public static func suggestedFileName(
        url: URL,
        contentDisposition: String? = nil,
        mimeType: String? = nil,
        fallback: String = "download"
    ) -> String {
        if let name = self.contentDisposition(contentDisposition).filename, !name.isEmpty {
            return sanitizedFileName(name, fallback: fallback)
        }
        let last = (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty, last != "/", last != "." {
            if (last as NSString).pathExtension.isEmpty,
               let ext = fileExtension(forMIME: mimeType) {
                return sanitizedFileName("\(last).\(ext)", fallback: fallback)
            }
            return sanitizedFileName(last, fallback: fallback)
        }
        if let ext = fileExtension(forMIME: mimeType) {
            return "\(fallback).\(ext)"
        }
        return fallback
    }

    public static func sanitizedFileName(_ raw: String, fallback: String = "download") -> String {
        var name = raw.replacingOccurrences(of: "\\", with: "/")
        name = (name as NSString).lastPathComponent
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty || name == "." || name == ".." { return fallback }
        if name.count > 120 {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            let room = max(1, 110 - ext.count)
            name = String(stem.prefix(room)) + (ext.isEmpty ? "" : ".\(ext)")
        }
        return name
    }
}

// MARK: - 正文链接提取

public struct ArticleTextLink: Equatable, Sendable {
    public let range: NSRange
    public let url: URL
    public let text: String

    public init(range: NSRange, url: URL, text: String) {
        self.range = range
        self.url = url
        self.text = text
    }
}

public enum ArticleLinkExtractor {
    /// 抓正文里的绝对链接，并补上数据探测器不认的相对下载地址。
    public static func links(in text: String, baseURL: URL? = nil) -> [ArticleTextLink] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [(NSRange, URL, String)] = []

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, options: [], range: full) {
                guard let url = match.url else { continue }
                let range = trimTrailingPunctuation(match.range, in: ns)
                guard range.length > 0 else { continue }
                found.append((range, url, ns.substring(with: range)))
            }
        }

        // 数据探测器不认相对地址；按空白/中文标点切词，补上带下载扩展名的片段。
        let stop = tokenStopCharacters
        var location = 0
        while location < ns.length {
            while location < ns.length, isStop(ns.character(at: location), stop) {
                location += 1
            }
            let start = location
            while location < ns.length, !isStop(ns.character(at: location), stop) {
                location += 1
            }
            guard location > start else { break }
            let range = trimTrailingPunctuation(
                NSRange(location: start, length: location - start),
                in: ns
            )
            guard range.length > 0 else { continue }
            guard !found.contains(where: { NSIntersectionRange($0.0, range).length > 0 }) else { continue }
            let raw = ns.substring(with: range)
            guard let url = resolve(raw, baseURL: baseURL),
                  DownloadLinkClassifier.isDownloadable(url) else { continue }
            found.append((range, url, raw))
        }

        found.sort { $0.0.location < $1.0.location }
        var result: [ArticleTextLink] = []
        var lastEnd = -1
        for item in found where item.0.location >= lastEnd {
            lastEnd = item.0.location + item.0.length
            result.append(ArticleTextLink(range: item.0, url: item.1, text: item.2))
        }
        return result
    }

    public static func resolve(_ raw: String, baseURL: URL?) -> URL? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        if token.hasPrefix("//"), let scheme = baseURL?.scheme, !scheme.isEmpty {
            return URL(string: "\(scheme):\(token)")
        }
        if token.lowercased().hasPrefix("www.") {
            return URL(string: "https://\(token)")
        }
        if let url = URL(string: token), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }
        guard let baseURL else { return nil }
        return URL(string: token, relativeTo: baseURL)?.absoluteURL
    }

    private static let tokenStopCharacters: CharacterSet = {
        CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "<>\"'“”‘’（）()[]{}，。；：、！？")
        )
    }()

    private static func isStop(_ code: unichar, _ set: CharacterSet) -> Bool {
        guard let scalar = UnicodeScalar(code) else { return false }
        return set.contains(scalar)
    }

    private static func trimTrailingPunctuation(_ range: NSRange, in ns: NSString) -> NSRange {
        let trailing = CharacterSet(charactersIn: ".,;:!?，。；：！？、）》】>\"'”’")
        var end = range.location + range.length
        while end > range.location {
            guard let scalar = UnicodeScalar(ns.character(at: end - 1)), trailing.contains(scalar) else { break }
            end -= 1
        }
        return NSRange(location: range.location, length: end - range.location)
    }
}

// MARK: - 导入文件嗅探

public enum ImportAssetKind: String, CaseIterable, Identifiable, Sendable {
    case bookSource
    case subscribeSource
    case purifier
    case book
    case font
    case backup

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bookSource: return "书源"
        case .subscribeSource: return "订阅源"
        case .purifier: return "净化规则"
        case .book: return "书籍文件"
        case .font: return "字体"
        case .backup: return "备份包"
        }
    }

    public var symbol: String {
        switch self {
        case .bookSource: return "square.stack.3d.up"
        case .subscribeSource: return "dot.radiowaves.left.and.right"
        case .purifier: return "wand.and.stars"
        case .book: return "book.closed"
        case .font: return "textformat"
        case .backup: return "externaldrive"
        }
    }
}

public struct ImportAsset: Equatable, Identifiable, Sendable {
    public var kind: ImportAssetKind
    /// 逐条识别出的 JSON 对象（书源/订阅源/净化规则）。
    public var items: [Data]
    /// 文件型资源（书籍、字体、备份包）。
    public var files: [URL]
    /// 数量未知（例如纯文本按行拆的净化规则）时只显示类型。
    public var isApproximate: Bool

    public var id: ImportAssetKind { kind }
    public var count: Int { items.isEmpty ? files.count : items.count }

    public init(kind: ImportAssetKind, items: [Data] = [], files: [URL] = [], isApproximate: Bool = false) {
        self.kind = kind
        self.items = items
        self.files = files
        self.isApproximate = isApproximate
    }
}

public struct ImportScanResult: Sendable {
    public internal(set) var assets: [ImportAssetKind: ImportAsset] = [:]
    public internal(set) var extractionDirectory: URL?
    public internal(set) var notes: [String] = []

    public init() {}

    public var isEmpty: Bool {
        assets.values.allSatisfy { $0.count == 0 }
    }

    public var orderedAssets: [ImportAsset] {
        ImportAssetKind.allCases.compactMap { assets[$0] }.filter { $0.count > 0 }
    }

    public func count(for kind: ImportAssetKind) -> Int {
        assets[kind]?.count ?? 0
    }

    public mutating func add(
        _ kind: ImportAssetKind,
        items: [Data] = [],
        files: [URL] = [],
        isApproximate: Bool = false
    ) {
        var asset = assets[kind] ?? ImportAsset(kind: kind)
        asset.items.append(contentsOf: items)
        asset.files.append(contentsOf: files)
        asset.isApproximate = asset.isApproximate || isApproximate
        assets[kind] = asset
    }

    public mutating func merge(_ other: ImportScanResult) {
        for (kind, asset) in other.assets {
            add(kind, items: asset.items, files: asset.files, isApproximate: asset.isApproximate)
        }
        if extractionDirectory == nil { extractionDirectory = other.extractionDirectory }
        notes.append(contentsOf: other.notes)
    }
}

public enum ImportSnifferError: LocalizedError {
    case invalidArchive
    case tooManyEntries
    case archiveTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidArchive: return "压缩包打不开"
        case .tooManyEntries: return "压缩包条目太多"
        case .archiveTooLarge: return "压缩包解压后体积过大"
        }
    }
}

public enum ImportSniffer {
    public static let maxArchiveEntries = 500
    public static let maxTotalUncompressedBytes = 200 * 1024 * 1024
    public static let maxItemsPerKind = 5000
    public static let bookExtensions: Set<String> = ["epub", "pdf", "mobi", "azw3", "cbz", "cb7"]
    public static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]

    /// 扫一个下载文件：按扩展名分流；zip 安全解压后逐个文件识别。
    public static func scan(fileURL: URL) -> ImportScanResult {
        var result = ImportScanResult()
        let ext = fileURL.pathExtension.lowercased()

        if fontExtensions.contains(ext) {
            result.add(.font, files: [fileURL])
            return result
        }
        if bookExtensions.contains(ext) {
            result.add(.book, files: [fileURL])
            return result
        }
        if ext == "zip" {
            return scanArchive(fileURL)
        }
        if ext == "json" || ext == "txt" {
            if let data = try? Data(contentsOf: fileURL) {
                for (kind, items) in scanJSON(data: data) {
                    result.add(kind, items: items)
                }
            }
            if ext == "txt" {
                // 纯文本小说：仍给“书籍”和按行拆的净化规则两个候选。
                result.add(.book, files: [fileURL])
                if result.count(for: .purifier) == 0 {
                    result.add(.purifier, files: [fileURL], isApproximate: true)
                }
            }
        }
        return result
    }

    public static func scanArchive(_ fileURL: URL) -> ImportScanResult {
        var result = ImportScanResult()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportScan-\(UUID().uuidString)", isDirectory: true)
        do {
            let files = try extractArchive(url: fileURL, to: directory)
            result.add(.backup, files: [fileURL])
            for file in files {
                result.merge(scanExtractedFile(file))
            }
            result.extractionDirectory = directory
        } catch {
            result.add(.backup, files: [fileURL])
            result.extractionDirectory = directory
            result.notes.append("压缩包解析失败：\(error.localizedDescription)")
        }
        return result
    }

    public static func scanJSON(data: Data) -> [ImportAssetKind: [Data]] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return [:]
        }
        var result: [ImportAssetKind: [Data]] = [:]
        collectJSON(root, into: &result)
        return result
    }

    /// 安全解压：只取 basename，跳过 `__MACOSX`、隐藏文件和目录；限制条目数与总解压体积。
    public static func extractArchive(url: URL, to directory: URL) throws -> [URL] {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw ImportSnifferError.invalidArchive
        }

        var usedNames = Set<String>()
        var totalBytes = 0
        var entryCount = 0
        var files: [URL] = []

        for entry in archive {
            entryCount += 1
            guard entryCount <= maxArchiveEntries else { throw ImportSnifferError.tooManyEntries }
            guard entry.type == .file else { continue }
            guard !entry.path.contains("__MACOSX") else { continue }
            let base = (entry.path as NSString).lastPathComponent
            guard !base.isEmpty, !base.hasPrefix(".") else { continue }

            // 中央目录声明的体积可以被伪造，真正写盘时按实际解压字节再计一次。
            totalBytes += Int(clamping: entry.uncompressedSize)
            guard totalBytes <= maxTotalUncompressedBytes else { throw ImportSnifferError.archiveTooLarge }

            var name = DownloadLinkClassifier.sanitizedFileName(base)
            if usedNames.contains(name) {
                let ext = (name as NSString).pathExtension
                let stem = (name as NSString).deletingPathExtension
                var index = 2
                while usedNames.contains(name) {
                    name = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
                    index += 1
                }
            }
            usedNames.insert(name)

            let destination = directory.appendingPathComponent(name)
            manager.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            var written = 0
            do {
                _ = try archive.extract(entry, consumer: { chunk in
                    written += chunk.count
                    guard written <= maxTotalUncompressedBytes else {
                        throw ImportSnifferError.archiveTooLarge
                    }
                    try handle.write(contentsOf: chunk)
                })
                try handle.close()
            } catch {
                try? handle.close()
                try? manager.removeItem(at: destination)
                throw error
            }
            files.append(destination)
        }
        return files
    }

    // MARK: 内部

    private static func scanExtractedFile(_ fileURL: URL) -> ImportScanResult {
        var result = ImportScanResult()
        let ext = fileURL.pathExtension.lowercased()
        if fontExtensions.contains(ext) {
            result.add(.font, files: [fileURL])
            return result
        }
        if bookExtensions.contains(ext) {
            result.add(.book, files: [fileURL])
            return result
        }
        guard ext == "json" || ext == "txt", let data = try? Data(contentsOf: fileURL) else {
            return result
        }
        for (kind, items) in scanJSON(data: data) {
            result.add(kind, items: items)
        }
        if ext == "txt", result.isEmpty {
            result.add(.book, files: [fileURL])
            result.add(.purifier, files: [fileURL], isApproximate: true)
        }
        return result
    }

    private static func collectJSON(_ node: Any, into result: inout [ImportAssetKind: [Data]]) {
        if let array = node as? [Any] {
            for item in array { collectJSON(item, into: &result) }
            return
        }
        guard let dict = node as? [String: Any] else { return }
        if collectWrapped(dict, into: &result) { return }
        guard let (kind, data) = classify(dict) else { return }
        append(data, kind: kind, into: &result)
    }

    private static func collectWrapped(_ dict: [String: Any], into result: inout [ImportAssetKind: [Data]]) -> Bool {
        let wrappers: [(keys: [String], kind: ImportAssetKind)] = [
            (["bookSources", "booksources"], .bookSource),
            (["replaceRules", "replacerules", "rules"], .purifier),
            (["rssSources", "rsssources", "subscribeSources", "subscribesources"], .subscribeSource)
        ]
        var matched = false
        for wrapper in wrappers {
            for key in wrapper.keys {
                guard let value = dict[key] else { continue }
                matched = true
                let objects: [[String: Any]]
                if let array = value as? [Any] {
                    objects = array.compactMap { $0 as? [String: Any] }
                } else if let single = value as? [String: Any] {
                    objects = [single]
                } else {
                    objects = []
                }
                for object in objects {
                    guard let data = try? JSONSerialization.data(withJSONObject: object) else { continue }
                    append(data, kind: wrapper.kind, into: &result)
                }
            }
        }
        return matched
    }

    private static func classify(_ dict: [String: Any]) -> (ImportAssetKind, Data)? {
        let hasBookSourceURL = nonEmptyString(dict["bookSourceUrl"]) != nil
        let hasSubscribeURL = nonEmptyString(dict["sourceUrl"]) != nil
        let looksLikeBookSource = hasBookSourceURL
            || dict["bookSourceName"] != nil
            || dict["ruleSearch"] != nil
            || dict["ruleToc"] != nil
            || dict["searchUrl"] != nil
        let looksLikeSubscribeSource = hasSubscribeURL
            || dict["ruleArticles"] != nil
            || dict["sortUrl"] != nil
        let looksLikePurifier = dict["pattern"] != nil || dict["regex"] != nil

        let kind: ImportAssetKind?
        if hasBookSourceURL {
            kind = .bookSource
        } else if hasSubscribeURL {
            kind = .subscribeSource
        } else if looksLikeBookSource {
            kind = .bookSource
        } else if looksLikeSubscribeSource {
            kind = .subscribeSource
        } else if looksLikePurifier {
            kind = .purifier
        } else {
            kind = nil
        }

        guard let kind, let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return (kind, data)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func append(_ data: Data, kind: ImportAssetKind, into result: inout [ImportAssetKind: [Data]]) {
        guard (result[kind]?.count ?? 0) < maxItemsPerKind else { return }
        result[kind, default: []].append(data)
    }
}
