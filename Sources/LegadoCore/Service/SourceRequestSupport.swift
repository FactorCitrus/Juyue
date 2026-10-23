import Foundation

/// 书源里的图片地址经常带两层包装：
/// - 后端或脚本重复拼了 `data:`（`data:data:image/...`）；
/// - 聚合源在图片后面追加 `,{"click":"showCmt(...)"}` 点击元数据。
///
/// 这两层都不能交给 `URLSession` / `Data(base64Encoded:)`，否则就是
/// `kCFErrorDomainCFNetwork -10` 或 base64 解码失败。
public enum ImageSourceNormalizer {
    /// 去掉点击元数据，修正重复的 data 前缀，并把协议相对地址补成 https。
    public static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }

        // HTML 属性里可能还残留实体，先还原再判断。
        value = value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")

        value = stripMetadata(value)

        // 有些聚合源把完整 data URI 再套一层 `data:`。
        while value.lowercased().hasPrefix("data:data:") {
            value.removeFirst("data:".count)
        }

        if value.hasPrefix("//") {
            value = "https:" + value
        }
        return value
    }

    /// 只取图片本体，丢掉 `,{...}` / `,%7B...` / `,&quot;{...}` 这类点击元数据。
    public static func stripMetadata(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = [",%7B", ",%7b", ",&quot;{", ",{"]

        for marker in markers {
            guard let range = value.range(of: marker) else { continue }
            let head = String(value[..<range.lowerBound])
            let lower = head.lowercased()
            guard lower.hasPrefix("data:")
                    || lower.hasPrefix("http://")
                    || lower.hasPrefix("https://")
                    || head.hasPrefix("//") else { continue }
            return head
        }
        return value
    }

    /// `data:image/...;base64,<payload>,<metadata>` 里的 base64 载荷。
    /// base64 字母表不含逗号，所以第二个逗号之前就是图片本体。
    public static func dataURIPayload(_ value: String) -> String? {
        guard let comma = value.firstIndex(of: ",") else { return nil }
        let body = value[value.index(after: comma)...]
        let payload = body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 书源请求共用的准备逻辑。
public enum SourceRequestSupport {

    /// `header` / `loginHeader` 里可以嵌 `<js>...</js>` 或 `@js:`，先跑脚本再当 header 用。
    /// 脚本报错或返回空时保留原值，不把请求打瘫。
    public static func resolvedHeader(for source: BookSource) -> String? {
        guard let raw = source.loginHeader ?? source.header,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard raw.contains("<js>") || raw.hasPrefix("@js:") else { return raw }

        let engine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
        let script = JSEngine.unwrapJsScript(raw)
        if let evaluated = engine.eval(script: script) as? String,
           !evaluated.isEmpty, evaluated != "undefined", evaluated != "null" {
            return evaluated
        }
        return raw
    }

    /// 把书源 header 拆成请求头字典，供图片加载与 AVPlayer 使用。
    public static func headerDictionary(for source: BookSource) -> [String: String] {
        guard let raw = resolvedHeader(for: source) else { return [:] }
        if let parsed = NetworkClient.parseLegadoUrl("https://legado.local", defaultHeader: raw) {
            var headers = parsed.headers
            headers.removeValue(forKey: "User-Agent")
            return headers
        }
        return [:]
    }
}

/// 封面解码：`coverDecodeJs` 的 `result` 是规则取到的原始封面地址。
public enum CoverURLResolver {
    public static func resolve(_ raw: String, source: BookSource, baseUrl: String? = nil) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var decoded = trimmed
        let script = (source.coverDecodeJs ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !script.isEmpty {
            let engine = JSEngine(bookSource: source, baseUrl: baseUrl ?? source.bookSourceUrl)
            if let value = engine.eval(script: JSEngine.unwrapJsScript(script), result: trimmed),
               let text = value as? String,
               !text.isEmpty, text != "undefined", text != "null" {
                decoded = text
            } else if let error = engine.lastError {
                LegadoLog.log("[Cover] ⚠️ [\(source.bookSourceName)] coverDecodeJs 报错：\(error)")
            }
        }

        return resolveRelative(decoded, baseUrl: baseUrl)
    }

    private static func resolveRelative(_ raw: String, baseUrl: String?) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("data:") {
            return value
        }
        if value.hasPrefix("//") { return "https:" + value }
        guard let baseUrl, let base = URL(string: baseUrl) else { return value }
        return URL(string: value, relativeTo: base)?.absoluteString ?? value
    }
}

/// 音频 / 图片 / 视频 / 文件源的章节内容解析。
public enum MediaContentParser {
    private static let imageMarker = try? NSRegularExpression(pattern: "\\[image:(.*?)\\]")

    /// `[image:url]` 标记里的图片地址，按出现顺序。
    public static func imageURLs(from content: String) -> [String] {
        guard let regex = imageMarker else { return [] }
        let ns = content as NSString
        return regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                guard match.numberOfRanges > 1 else { return nil }
                let value = ImageSourceNormalizer.normalize(
                    ns.substring(with: match.range(at: 1))
                )
                return value.isEmpty ? nil : value
            }
    }

    /// 从正文规则结果里找可播放 / 可下载的地址：
    /// 1. 明确的 JSON 字段（url / src / playUrl / audio / video / contentUrl）
    /// 2. 任意 http(s) 地址
    /// 标记里的图片也按顺序收进来。
    public static func mediaURLs(from content: String) -> [String] {
        var found: [String] = imageURLs(from: content)
        var seen = Set(found)

        func append(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return }
            if seen.insert(trimmed).inserted { found.append(trimmed) }
        }

        // JSON 优先，能避开正文里的无关链接
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var jsonFound: [String] = []
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) && trimmed.data(using: .utf8) != nil,
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            collectJSONURLs(json, into: &jsonFound, seen: &seen)
            found.append(contentsOf: jsonFound)
        }

        if !jsonFound.isEmpty {
            return found
        }

        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>\\]+"#) {
            let ns = content as NSString
            for match in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
                var value = ns.substring(with: match.range)
                while let last = value.last, ",，;；)]}）】".contains(last) {
                    value.removeLast()
                }
                append(value)
            }
        }
        return found
    }

    public static func isMediaURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return [".mp3", ".m4a", ".aac", ".flac", ".wav", ".ogg",
                ".mp4", ".m3u8", ".ts", ".mov", ".webm"].contains { lower.contains($0) }
    }

    private static func collectJSONURLs(_ value: Any, into found: inout [String], seen: inout Set<String>) {
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                let lower = key.lowercased()
                let isURLKey = ["url", "src", "playurl", "audio", "video", "contenturl",
                                "download", "file", "link"].contains(lower)
                if isURLKey, let text = child as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")),
                       seen.insert(trimmed).inserted {
                        found.append(trimmed)
                    }
                } else {
                    collectJSONURLs(child, into: &found, seen: &seen)
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let text = child as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")),
                       seen.insert(trimmed).inserted {
                        found.append(trimmed)
                    }
                } else {
                    collectJSONURLs(child, into: &found, seen: &seen)
                }
            }
        }
    }
}

/// 非文本源的章节解析结果。
public struct MediaChapterPayload {
    public let kind: BookSource.Kind
    public let urls: [String]
    public let headers: [String: String]
    public let rawContent: String
    public let rateKey: String
    public let rateLimit: SourceRateLimit?

    public init(
        kind: BookSource.Kind,
        urls: [String],
        headers: [String: String],
        rawContent: String,
        rateKey: String = "",
        rateLimit: SourceRateLimit? = nil
    ) {
        self.kind = kind
        self.urls = urls
        self.headers = headers
        self.rawContent = rawContent
        self.rateKey = rateKey
        self.rateLimit = rateLimit
    }
}

public final class BookMediaService {
    public static let shared = BookMediaService()

    public init() {}

    /// 抓一章并解析成图片列表 / 音视频地址 / 文件地址。
    public func resolveChapter(
        chapter: BookChapter,
        book: Book,
        source: BookSource
    ) async throws -> MediaChapterPayload {
        let kind = source.kind
        let headers = SourceRequestSupport.headerDictionary(for: source)
        var rawContent = ""

        // 章节本身就是媒体直链时不用再抓页面
        let direct = chapter.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContentRule = !(source.ruleContent?.content ?? "").isEmpty
        if kind != .image || hasContentRule {
            rawContent = (try? await BookContentService.shared.fetchChapterContent(
                chapter: chapter,
                source: source,
                book: book
            )) ?? ""
        }

        var urls: [String]
        switch kind {
        case .image:
            urls = MediaContentParser.imageURLs(from: rawContent)
            if urls.isEmpty {
                urls = MediaContentParser.mediaURLs(from: rawContent)
            }
            if urls.isEmpty, direct.hasPrefix("http") {
                urls = [direct]
            }
        case .audio, .video:
            urls = MediaContentParser.mediaURLs(from: rawContent)
            if urls.isEmpty, direct.hasPrefix("http") {
                urls = [direct]
            }
        case .file:
            urls = MediaContentParser.mediaURLs(from: rawContent)
            if urls.isEmpty, direct.hasPrefix("http") {
                urls = [direct]
            }
        case .text:
            urls = []
        }

        return MediaChapterPayload(
            kind: kind,
            urls: urls,
            headers: headers,
            rawContent: rawContent,
            rateKey: source.bookSourceUrl,
            rateLimit: source.rateLimit
        )
    }
}
