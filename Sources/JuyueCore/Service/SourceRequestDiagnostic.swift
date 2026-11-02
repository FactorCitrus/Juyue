import Foundation

/// 单步检测记录。只存在本机，用来回答「哪一步、请求了什么、返回了什么」。
///
/// 记录是结构化的：`headersSummary` / `failureKind` / `ruleEvalMs` 只在能真实测量时才填，
/// 填不了就留空，不用猜出来的值冒充事实。
public struct SourceRequestDiagnostic: Codable, Identifiable, Equatable {
    public var id: UUID
    /// 记录时刻。旧数据没有这个字段时按 1970 处理。
    public var at: Date
    public var step: String
    public var sourceName: String
    public var url: String
    public var statusCode: Int
    public var elapsedMs: Int64
    public var responseBytes: Int
    public var responsePreview: String
    public var ruleHits: Int
    /// 规则求值耗时。跟 `elapsedMs` 分开，才分得清慢在网络还是慢在规则。
    public var ruleEvalMs: Int64
    /// 请求头存在性摘要，例如 `ua=1 referer=1 cookie=0`。值一律不落盘。
    public var headersSummary: String
    /// dns / tls / timeout / offline / cancelled / network(n) / other，空串表示没失败。
    public var failureKind: String
    public var note: String

    public init(
        step: String,
        sourceName: String = "",
        url: String,
        statusCode: Int = 0,
        elapsedMs: Int64 = 0,
        responseBytes: Int = 0,
        responsePreview: String = "",
        ruleHits: Int = 0,
        ruleEvalMs: Int64 = 0,
        headersSummary: String = "",
        failureKind: String = "",
        note: String = ""
    ) {
        self.id = UUID()
        self.at = Date()
        self.step = step
        self.sourceName = sourceName
        // URL 入库前就脱敏，免得 UI 展示和复制出去的是带 token 的原串
        self.url = LogRedaction.redact(url)
        self.statusCode = statusCode
        self.elapsedMs = elapsedMs
        self.responseBytes = responseBytes
        self.responsePreview = responsePreview
        self.ruleHits = ruleHits
        self.ruleEvalMs = ruleEvalMs
        self.headersSummary = headersSummary
        self.failureKind = failureKind
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, at, step, sourceName, url, statusCode, elapsedMs, responseBytes
        case responsePreview, ruleHits, ruleEvalMs, headersSummary, failureKind, note
    }

    /// 手写解码：旧版本存在 UserDefaults 里的记录没有新增字段，缺了就取默认值，
    /// 不能因为多了几个字段就把用户已有的检测历史整段丢掉。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        at = (try? c.decodeIfPresent(Date.self, forKey: .at)) ?? Date(timeIntervalSince1970: 0)
        step = (try? c.decodeIfPresent(String.self, forKey: .step)) ?? ""
        sourceName = (try? c.decodeIfPresent(String.self, forKey: .sourceName)) ?? ""
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        statusCode = (try? c.decodeIfPresent(Int.self, forKey: .statusCode)) ?? 0
        elapsedMs = (try? c.decodeIfPresent(Int64.self, forKey: .elapsedMs)) ?? 0
        responseBytes = (try? c.decodeIfPresent(Int.self, forKey: .responseBytes)) ?? 0
        responsePreview = (try? c.decodeIfPresent(String.self, forKey: .responsePreview)) ?? ""
        ruleHits = (try? c.decodeIfPresent(Int.self, forKey: .ruleHits)) ?? 0
        ruleEvalMs = (try? c.decodeIfPresent(Int64.self, forKey: .ruleEvalMs)) ?? 0
        headersSummary = (try? c.decodeIfPresent(String.self, forKey: .headersSummary)) ?? ""
        failureKind = (try? c.decodeIfPresent(String.self, forKey: .failureKind)) ?? ""
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
    }
}

public enum DiagnosticPreview {
    /// 响应摘要：压掉换行，最多 240 字，避免把整页 HTML 存进 UserDefaults。
    /// 落库前过一遍脱敏，正文片段里也常带手机号、邮箱、内联 token。
    public static func make(_ text: String, limit: Int = 240) -> String {
        let flat = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
        return LogRedaction.redact(clipped)
    }
}

/// 日志脱敏：替换敏感值，不再整行丢弃。
///
/// 旧实现是黑名单整行丢弃：源名里带 `token` / `serial` 的书源，它的日志一条都留不下来，
/// 而那几条恰恰是最该看的。改成逐值替换以后，行的前缀照旧保留。
public enum LogRedaction {
    /// 名字命中就算敏感，值整段替换。比较时忽略大小写与 `[]`。
    private static let sensitiveKeys: Set<String> = [
        "token", "access_token", "refresh_token", "id_token",
        "key", "apikey", "api_key", "appkey", "app_key", "secret", "client_secret",
        "password", "passwd", "pwd", "pass",
        "sign", "signature", "sig", "auth", "authorization", "bearer",
        "cookie", "set-cookie", "session", "sessionid", "jsessionid", "sid",
        "serial", "card", "cardno", "imei", "idfa", "deviceid", "device_id",
        "phone", "mobile", "tel", "email", "mail", "uid", "userid", "user_id",
        "code", "verify", "captcha", "sms"
    ]

    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = redactPairs(in: text)
        out = replace(out, pattern: "(?i)\\b(cookie|authorization|set-cookie|x-[a-z0-9-]*token)\\s*:\\s*[^\\n\\r]*", template: "$1: <redacted>")
        out = replace(out, pattern: "(?i)\\b(bearer)\\s+[A-Za-z0-9._~+/=-]{8,}", template: "$1 <redacted>")
        out = replace(out, pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", template: "<email>")
        out = replace(out, pattern: "(?<![0-9])1[3-9][0-9]{9}(?![0-9])", template: "<phone>")
        out = replace(out, pattern: "(?:/Users/|/var/|/private/)[^\\s\"'<>)]*", template: "<path>")
        return out
    }

    /// `?a=1&token=xxx&b=2` → `?a=1&token=<redacted>&b=2`，键名与其它参数原样保留。
    private static func redactPairs(in text: String) -> String {
        let pattern = "([?&;])([^=&\\s#\"']+)=([^&\\s#\"']*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = text
        // 倒序替换，前面的 range 才不会因为长度变化而失效
        for match in matches.reversed() where match.numberOfRanges >= 4 {
            let keyRange = match.range(at: 2)
            let valueRange = match.range(at: 3)
            guard keyRange.location != NSNotFound, valueRange.location != NSNotFound else { continue }
            let key = ns.substring(with: keyRange)
                .lowercased()
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
            guard sensitiveKeys.contains(key) else { continue }
            guard let swiftRange = Range(valueRange, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: "<redacted>")
        }
        return result
    }

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

/// 失败归因：只做能从错误对象里读出来的分类，读不出就 `other`。
public enum DiagnosticFailure {
    public static func classify(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                return "dns"
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return "tls"
            case .timedOut:
                return "timeout"
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "offline"
            case .cancelled:
                return "cancelled"
            default:
                return "network(\(urlError.code.rawValue))"
            }
        }
        return "other"
    }

    /// 只记「带没带」，值一个字不记。书源问题大半是 UA / Referer / Cookie 缺了。
    public static func summarize(_ headers: [String: String]) -> String {
        let lowered = Set(headers.keys.map { $0.lowercased() })
        func flag(_ name: String) -> String { lowered.contains(name) ? "1" : "0" }
        return "ua=\(flag("user-agent")) referer=\(flag("referer")) cookie=\(flag("cookie")) accept=\(flag("accept"))"
    }
}

/// 真实搜索 / 阅读路径的请求记录。检测页之外的调用方不传闭包，也能留下现场。
///
/// 环形缓冲 + 防抖落盘：内存里最多 `capacity` 条，写盘只在空闲时做一次，
/// 不进 UserDefaults，也不在调用者线程上做 I/O。
public final class DiagnosticHub {
    public static let shared = DiagnosticHub()

    /// 关掉记录与写盘。默认开着：一条记录几十字节，比丢掉现场便宜。
    public static var isEnabled = true

    public var capacity = 200

    /// 测试里关掉：不往真实的 Documents 目录写文件。
    public var persistsToDisk = true

    private let lock = NSLock()
    private var records: [SourceRequestDiagnostic] = []
    private let ioQueue = DispatchQueue(label: "com.factorcitrus.juyue.diagnostics", qos: .utility)
    private var saveWork: DispatchWorkItem?

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("AppLogs", isDirectory: true)
            .appendingPathComponent("diagnostics.json")
    }

    public init() {}

    /// 同时喂给检测页的闭包和本机环形缓冲。闭包可以没有，记录总要留。
    public static func emit(
        _ item: SourceRequestDiagnostic,
        to closure: ((SourceRequestDiagnostic) -> Void)?
    ) {
        closure?(item)
        shared.record(item)
    }

    public func record(_ item: SourceRequestDiagnostic) {
        guard DiagnosticHub.isEnabled else { return }
        lock.lock()
        records.append(item)
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
        lock.unlock()
        scheduleSave()
    }

    public func snapshot() -> [SourceRequestDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public func clear() {
        lock.lock()
        records.removeAll()
        lock.unlock()
        saveWork?.cancel()
        let url = Self.fileURL
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 冷启动后把上次的记录读回来，只在内存为空时读，不覆盖正在写的新记录。
    public func loadFromDiskIfNeeded() {
        lock.lock()
        let isEmpty = records.isEmpty
        lock.unlock()
        guard isEmpty else { return }
        let url = Self.fileURL
        ioQueue.async { [weak self] in
            guard let self,
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([SourceRequestDiagnostic].self, from: data)
            else { return }
            self.lock.lock()
            if self.records.isEmpty {
                self.records = Array(decoded.suffix(self.capacity))
            }
            self.lock.unlock()
        }
    }

    private func scheduleSave() {
        guard persistsToDisk else { return }
        saveWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWork = item
        ioQueue.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func save() {
        let snapshot = self.snapshot()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
