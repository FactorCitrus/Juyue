import Foundation
import Security
import ZIPFoundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - 配置

/// WebDAV 同步配置。密码不落 UserDefaults：真实值在钥匙串，配置里只留空串。
public struct WebDAVConfig: Codable, Equatable {
    public var url: String
    public var username: String
    public var password: String
    public var remotePath: String
    public var deviceName: String
    public var lastSyncTime: Date?

    public static let defaultServer = "https://dav.jianguoyun.com/dav/"

    public static var defaultDeviceName: String {
        #if canImport(UIKit)
        let label = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "iOS" : label
        #elseif os(macOS)
        if let label = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        return "Mac"
        #else
        return "Device"
        #endif
    }

    /// 备份文件名沿用安卓端约定：backupYYYY-MM-DD-设备名.zip。
    public static func generateBackupFileName(date: Date = Date(), deviceName: String?) -> String {
        let day = Self.dayStamp(date)
        let mapped: [Character: Character] = ["/": "-", "\\": "-", ":": "-"]
        let dropped: Set<Character> = ["*", "?", "\"", "<", ">", "|"]
        let characters = (deviceName ?? "").compactMap { character -> Character? in
            if let replacement = mapped[character] { return replacement }
            return dropped.contains(character) ? nil : character
        }
        var cleaned = String(characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let edgeTrim: Set<Character> = ["-", "_", " "]
        while let head = cleaned.first, edgeTrim.contains(head) {
            cleaned.removeFirst()
        }
        while let tail = cleaned.last, edgeTrim.contains(tail) {
            cleaned.removeLast()
        }
        return cleaned.isEmpty ? "backup\(day).zip" : "backup\(day)-\(cleaned).zip"
    }

    public init(
        url: String = WebDAVConfig.defaultServer,
        username: String = "",
        password: String = "",
        remotePath: String = "juyue",
        deviceName: String = WebDAVConfig.defaultDeviceName,
        lastSyncTime: Date? = nil
    ) {
        self.url = url
        self.username = username
        self.password = password
        self.remotePath = remotePath
        self.deviceName = deviceName.isEmpty ? Self.defaultDeviceName : deviceName
        self.lastSyncTime = lastSyncTime
    }

    enum CodingKeys: String, CodingKey {
        case url, username, password, remotePath, deviceName, lastSyncTime
    }

    /// 逐字段容错：缺字段的旧配置不该整份失效。
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)

        func field(_ key: CodingKeys, fallback: String) throws -> String {
            try box.decodeIfPresent(String.self, forKey: key) ?? fallback
        }

        self.url = try field(.url, fallback: Self.defaultServer)
        self.username = try field(.username, fallback: "")
        self.password = try field(.password, fallback: "")
        self.remotePath = try field(.remotePath, fallback: "juyue")
        self.deviceName = try field(.deviceName, fallback: Self.defaultDeviceName)
        self.lastSyncTime = try box.decodeIfPresent(Date.self, forKey: .lastSyncTime)
    }

    private static func dayStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private var normalizedServer: String? {
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let hasScheme = raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://")
        var root = hasScheme ? raw : "https://" + raw
        if !root.hasSuffix("/") {
            root.append("/")
        }
        return root
    }

    /// 同步根目录：服务器地址 + remotePath，两级都补尾斜杠。
    public var directoryURL: URL? {
        guard let root = normalizedServer else { return nil }
        let subpath = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let address = subpath.isEmpty ? root : root + subpath + "/"
        return URL(string: address)
    }

    /// 地址、账号、密码三样齐了才算配好。
    public var isConfigured: Bool {
        [url, username, password].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public var serverRootURL: URL? {
        guard let root = normalizedServer else { return nil }
        return URL(string: root)
    }

    /// 明文 HTTP 下 Basic 等于裸传密码；这种情况不带凭据，让服务端 401。
    public var sendCredentialsInClear: Bool {
        normalizedServer?.lowercased().hasPrefix("http://") == true
    }

    public var basicAuthHeader: String {
        guard !sendCredentialsInClear,
              let bytes = "\(username):\(password)".data(using: .utf8) else {
            return ""
        }
        return "Basic " + bytes.base64EncodedString()
    }
}

// MARK: - 远端备份条目

public struct RemoteBackupInfo: Identifiable, Equatable {
    public var id: String { fileName }
    public var fileName: String
    public var url: URL
    public var lastModified: Date?
    public var size: Int64?

    public init(fileName: String, url: URL, lastModified: Date? = nil, size: Int64? = nil) {
        self.fileName = fileName
        self.url = url
        self.lastModified = lastModified
        self.size = size
    }
}

// MARK: - 错误

public enum WebDAVError: LocalizedError {
    case invalidURL
    case unauthorized
    case serverError(Int, String)
    case backupNotFound
    case decodingFailed(String)
    case custom(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "WebDAV 服务器地址无效，请检查配置"
        case .unauthorized:
            return "WebDAV 认证失败：用户名或密码错误 (401)"
        case .serverError(let code, let message):
            return "WebDAV 服务器错误 (HTTP \(code)): \(message)"
        case .backupNotFound:
            return "未在远程目录找到备份文件 (bookshelf.json 或 bookSource.json)"
        case .decodingFailed(let detail):
            return "备份数据解析失败: \(detail)"
        case .custom(let message):
            return message
        }
    }
}

// MARK: - 服务

public final class WebDAVService {
    public static let shared = WebDAVService()

    private enum Storage {
        static let configKey = "juyue_webdav_config_v1"
        static let passwordAccount = "webdav_password"
    }

    private let transport: WebDAVTransport

    public init(session: URLSession = .shared) {
        self.transport = WebDAVTransport(session: session)
    }

    // MARK: 配置存取

    public func loadConfig() -> WebDAVConfig {
        JuyueStorageMigration.runIfNeeded()
        guard let data = UserDefaults.standard.data(forKey: Storage.configKey),
              var config = try? JSONDecoder().decode(WebDAVConfig.self, from: data) else {
            return WebDAVConfig()
        }

        if config.password.isEmpty {
            config.password = KeychainStore.read(account: Storage.passwordAccount) ?? ""
        } else if KeychainStore.write(config.password, account: Storage.passwordAccount) {
            // 旧版本把明文写在配置里：迁移成功才抹掉，失败就维持原样。
            config.password = ""
            persistRaw(config)
        }
        return config
    }

    public func saveConfig(_ config: WebDAVConfig) {
        var stored = config
        if config.password.isEmpty {
            KeychainStore.delete(account: Storage.passwordAccount)
        } else if KeychainStore.write(config.password, account: Storage.passwordAccount) {
            stored.password = ""
        }
        persistRaw(stored)
    }

    private func persistRaw(_ config: WebDAVConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Storage.configKey)
    }

    // MARK: 连接与目录

    public func testConnection(config: WebDAVConfig) async throws -> String {
        guard let directory = config.directoryURL else { throw WebDAVError.invalidURL }

        let probe = try await transport.execute(WebDAVCall(method: "PROPFIND", url: directory, config: config, depth: "0"))
        if probe.isAuthFailure { throw WebDAVError.unauthorized }

        if probe.status == 404 {
            try await createDirectoryIfNeeded(url: directory, config: config)
            return "连接成功，已自动创建远程同步目录：\(config.remotePath)"
        }
        if probe.isSuccess {
            return "连接成功！WebDAV 服务器已就绪。"
        }
        if probe.status == 405 {
            let fallback = try await transport.execute(WebDAVCall(method: "GET", url: directory, config: config))
            if fallback.isAuthFailure { throw WebDAVError.unauthorized }
            if fallback.isSuccess || fallback.status == 301 || fallback.status == 302 {
                return "连接成功！"
            }
        }
        throw WebDAVError.custom("服务器返回 HTTP \(probe.status)，连接未通过")
    }

    public func createDirectoryIfNeeded(config: WebDAVConfig) async throws {
        guard let directory = config.directoryURL else { throw WebDAVError.invalidURL }
        try await createDirectoryIfNeeded(url: directory, config: config)
    }

    /// 201 新建、204 无内容、405 已存在都算成；5xx 必须报错。
    public func createDirectoryIfNeeded(url: URL, config: WebDAVConfig) async throws {
        let reply = try await transport.execute(WebDAVCall(method: "MKCOL", url: url, config: config))
        if reply.isAuthFailure { throw WebDAVError.unauthorized }
        guard [200, 201, 204, 405].contains(reply.status) else {
            throw WebDAVError.custom("创建目录失败：HTTP \(reply.status)")
        }
    }

    public func sanitizeFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return name.components(separatedBy: illegal).joined(separator: "_")
    }

    // MARK: 进度

    /// 单本进度落到 bookProgress/书名_作者.json，与安卓端一致。
    public func uploadBookProgress(book: Book, config: WebDAVConfig) async throws {
        guard let directory = config.directoryURL else { return }
        let progressDirectory = directory.appendingPathComponent("bookProgress")
        try? await createDirectoryIfNeeded(url: progressDirectory, config: config)

        let stamp = book.durChapterTime > 0
            ? book.durChapterTime
            : Int64(Date().timeIntervalSince1970 * 1000)
        let progress = BookProgress(book: book, timestamp: stamp)

        let payload = try PrettyJSON.encode(progress)

        let fileName = sanitizeFileName("\(book.name)_\(book.author).json")
        let reply = try await transport.execute(WebDAVCall(
            method: "PUT",
            url: progressDirectory.appendingPathComponent(fileName),
            config: config,
            body: payload,
            mime: "application/json; charset=utf-8"
        ))
        if reply.isAuthFailure { throw WebDAVError.unauthorized }
    }

    // MARK: 备份

    public func createBackupZip(
        books: [Book],
        sources: [BookSource],
        deviceName: String = WebDAVConfig.defaultDeviceName,
        date: Date = Date(),
        settingsJSON: Data? = nil
    ) throws -> (data: Data, fileName: String) {
        try BackupArchiveBuilder.build(
            books: books,
            sources: sources,
            deviceName: deviceName,
            date: date,
            settingsJSON: settingsJSON
        )
    }

    public func backup(
        books: [Book],
        sources: [BookSource],
        config: WebDAVConfig,
        settingsJSON: Data? = nil
    ) async throws -> (booksCount: Int, sourcesCount: Int, backupFileName: String) {
        guard let directory = config.directoryURL else { throw WebDAVError.invalidURL }
        try? await createDirectoryIfNeeded(config: config)

        let archive = try createBackupZip(
            books: books,
            sources: sources,
            deviceName: config.deviceName,
            settingsJSON: settingsJSON
        )

        let upload = try await transport.execute(WebDAVCall(
            method: "PUT",
            url: directory.appendingPathComponent(archive.fileName),
            config: config,
            body: archive.data,
            mime: "application/zip"
        ))
        if upload.isAuthFailure { throw WebDAVError.unauthorized }
        guard upload.isSuccess else {
            throw WebDAVError.serverError(upload.status, "上传备份文件失败")
        }

        let sidecars: [(String, Data)] = [
            ("bookshelf.json", try PrettyJSON.encode(books)),
            ("bookSource.json", try PrettyJSON.encode(sources))
        ]
        for (name, payload) in sidecars {
            _ = try? await transport.execute(WebDAVCall(
                method: "PUT",
                url: directory.appendingPathComponent(name),
                config: config,
                body: payload,
                mime: "application/json; charset=utf-8"
            ))
        }

        var updated = config
        updated.lastSyncTime = Date()
        saveConfig(updated)

        return (books.count, sources.count, archive.fileName)
    }

    // MARK: 远端列表

    public func listRemoteBackups(config: WebDAVConfig) async throws -> [RemoteBackupInfo] {
        guard let directory = config.directoryURL else { throw WebDAVError.invalidURL }

        let reply = try await transport.execute(WebDAVCall(method: "PROPFIND", url: directory, config: config, depth: "1"))
        if reply.isAuthFailure { throw WebDAVError.unauthorized }
        guard reply.isSuccess, let xml = String(data: reply.body, encoding: .utf8) else { return [] }

        return PropfindParser.backups(xml: xml, baseURL: directory)
    }

    public func parseBackupsFromPropfindXML(_ xml: String, baseURL: URL) -> [RemoteBackupInfo] {
        PropfindParser.backups(xml: xml, baseURL: baseURL)
    }

    // MARK: 恢复

    public func restore(
        config: WebDAVConfig,
        backupFileName: String? = nil
    ) async throws -> (books: [Book]?, sources: [BookSource]?, backupName: String?, settingsJSON: Data?) {
        guard let directory = config.directoryURL else { throw WebDAVError.invalidURL }

        var books: [Book]?
        var sources: [BookSource]?
        var settings: Data?
        var usedName: String?

        if let remote = try? await listRemoteBackups(config: config), !remote.isEmpty {
            let chosen = backupFileName.flatMap { wanted in
                remote.first { $0.fileName == wanted }
            } ?? remote[0]

            if let download = try? await transport.execute(WebDAVCall(method: "GET", url: chosen.url, config: config)),
               download.isSuccess {
                let parsed = try? restoreFromZip(data: download.body)
                books = parsed?.books
                sources = parsed?.sources
                settings = extractSettingsJSON(fromZip: download.body)
                usedName = chosen.fileName
            }
        }

        if books == nil {
            books = try await fetchBookshelf(from: directory, config: config, usedName: &usedName)
        }
        if sources == nil {
            sources = try await fetchBookSources(from: directory, config: config)
        }

        if var restored = books {
            restored = await mergeRemoteProgress(into: restored, directory: directory, config: config)
            books = restored
        }

        guard books != nil || sources != nil else { throw WebDAVError.backupNotFound }

        var updated = config
        updated.lastSyncTime = Date()
        saveConfig(updated)

        return (books, sources, usedName, settings)
    }

    private func fetchBookshelf(
        from directory: URL,
        config: WebDAVConfig,
        usedName: inout String?
    ) async throws -> [Book]? {
        guard let reply = try? await transport.execute(WebDAVCall(
            method: "GET",
            url: directory.appendingPathComponent("bookshelf.json"),
            config: config
        )) else {
            return nil
        }
        if reply.isAuthFailure { throw WebDAVError.unauthorized }
        guard reply.isSuccess,
              let decoded = try? JSONDecoder().decode([Book].self, from: reply.body) else {
            return nil
        }
        usedName = usedName ?? "bookshelf.json"
        return decoded
    }

    private func fetchBookSources(
        from directory: URL,
        config: WebDAVConfig
    ) async throws -> [BookSource]? {
        guard let reply = try? await transport.execute(WebDAVCall(
            method: "GET",
            url: directory.appendingPathComponent("bookSource.json"),
            config: config
        )) else {
            return nil
        }
        if reply.isAuthFailure { throw WebDAVError.unauthorized }
        guard reply.isSuccess,
              let decoded = try? JSONDecoder().decode([BookSource].self, from: reply.body) else {
            return nil
        }
        return decoded
    }

    /// 一次 PROPFIND 拿到 bookProgress 目录清单，再并发拉取命中当前书架的那几份。
    private func mergeRemoteProgress(
        into books: [Book],
        directory: URL,
        config: WebDAVConfig
    ) async -> [Book] {
        let progressDirectory = directory.appendingPathComponent("bookProgress")
        guard let listing = try? await transport.execute(WebDAVCall(
            method: "PROPFIND",
            url: progressDirectory,
            config: config,
            depth: "1"
        )), listing.isSuccess,
           let xml = String(data: listing.body, encoding: .utf8) else {
            return books
        }

        let files = PropfindParser.jsonLinks(xml: xml, baseURL: progressDirectory)
        guard !files.isEmpty else { return books }

        let jobs = books.indices.compactMap { index -> (Int, URL)? in
            let name = sanitizeFileName("\(books[index].name)_\(books[index].author).json")
            guard let url = files[name] else { return nil }
            return (index, url)
        }
        guard !jobs.isEmpty else { return books }

        var merged = books
        let transport = self.transport
        await withTaskGroup(of: (Int, BookProgress?).self) { group in
            for (index, url) in jobs {
                group.addTask {
                    guard let reply = try? await transport.execute(WebDAVCall(method: "GET", url: url, config: config)),
                          reply.isSuccess,
                          let progress = try? JSONDecoder().decode(BookProgress.self, from: reply.body) else {
                        return (index, nil)
                    }
                    return (index, progress)
                }
            }
            for await (index, progress) in group {
                guard let progress, index < merged.count else { continue }
                BookProgressMerger.apply(progress, to: &merged[index], requireNotBehind: true)
            }
        }
        return merged
    }

    // MARK: 解包

    public func restoreFromZip(data: Data) throws -> (books: [Book]?, sources: [BookSource]?) {
        try parseArchive(try openArchive(data: data))
    }

    public func restoreFromZip(fileUrl: URL) throws -> (books: [Book]?, sources: [BookSource]?) {
        var result = try parseArchive(try openArchive(fileURL: fileUrl))

        let adjacent = fileUrl.deletingLastPathComponent().appendingPathComponent("bookProgress")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: adjacent.path, isDirectory: &isDirectory),
           isDirectory.boolValue, var books = result.books {
            applyBookProgress(books: &books, fromDirectory: adjacent)
            result.books = books
        }
        return result
    }

    public func extractSettingsJSON(fromZip data: Data) -> Data? {
        (try? openArchive(data: data)).flatMap { extractSettingsJSON(from: $0) }
    }

    public func extractSettingsJSON(fromZipFileUrl url: URL) -> Data? {
        (try? openArchive(fileURL: url)).flatMap { extractSettingsJSON(from: $0) }
    }

    private func openArchive(data: Data) throws -> Archive {
        if let archive = try? Archive(data: data, accessMode: .read, pathEncoding: nil) {
            return archive
        }
        throw WebDAVError.decodingFailed("无法解析 Zip 压缩包数据")
    }

    private func openArchive(fileURL: URL) throws -> Archive {
        if let archive = try? Archive(url: fileURL, accessMode: .read, pathEncoding: nil) {
            return archive
        }
        throw WebDAVError.decodingFailed("无法读取 Zip 备份文件: \(fileURL.lastPathComponent)")
    }

    public func extractSettingsJSON(from archive: Archive) -> Data? {
        ArchiveInspector.settings(from: archive)
    }

    public func parseArchive(_ archive: Archive) throws -> (books: [Book]?, sources: [BookSource]?) {
        let contents = ArchiveInspector.contents(from: archive)
        var books = contents.books
        let sources = contents.sources

        if var restored = books, !contents.progress.isEmpty {
            for index in restored.indices {
                let key = BookProgressMerger.key(name: restored[index].name, author: restored[index].author)
                if let progress = contents.progress[key],
                   progress.durChapterIndex >= restored[index].durChapterIndex {
                    BookProgressMerger.apply(progress, to: &restored[index], requireNotBehind: false)
                }
            }
            books = restored
        }

        guard books != nil || sources != nil else { throw WebDAVError.backupNotFound }
        return (books, sources)
    }

    public func applyBookProgress(books: inout [Book], fromDirectory dirUrl: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dirUrl,
            includingPropertiesForKeys: nil
        )) ?? []

        var progressByKey: [String: BookProgress] = [:]
        for file in files where file.pathExtension.lowercased() == "json" {
            if let data = try? Data(contentsOf: file),
               let progress = try? JSONDecoder().decode(BookProgress.self, from: data) {
                progressByKey[BookProgressMerger.key(name: progress.name, author: progress.author)] = progress
            }
        }

        if !progressByKey.isEmpty {
            for index in books.indices {
                let key = BookProgressMerger.key(name: books[index].name, author: books[index].author)
                if let progress = progressByKey[key],
                   progress.durChapterIndex >= books[index].durChapterIndex {
                    BookProgressMerger.apply(progress, to: &books[index], requireNotBehind: false)
                }
            }
        }
    }
}

// MARK: - 传输层

private struct WebDAVCall {
    var method: String
    var url: URL
    var config: WebDAVConfig
    var body: Data? = nil
    var mime: String? = nil
    var depth: String? = nil
}

private struct WebDAVTransport {
    let session: URLSession
    static let userAgent = "Juyue/1.0"

    struct Reply {
        let status: Int
        let body: Data

        var isSuccess: Bool { (200...299).contains(status) }
        var isAuthFailure: Bool { status == 401 || status == 403 }
    }

    func execute(_ call: WebDAVCall) async throws -> Reply {
        var request = URLRequest(url: call.url)
        request.httpMethod = call.method
        request.httpBody = call.body
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let credential = call.config.basicAuthHeader
        if !credential.isEmpty {
            request.setValue(credential, forHTTPHeaderField: "Authorization")
        }
        if let mime = call.mime {
            request.setValue(mime, forHTTPHeaderField: "Content-Type")
        }
        if let depth = call.depth {
            request.setValue(depth, forHTTPHeaderField: "Depth")
        }

        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.custom("服务器未返回 HTTP 响应")
        }
        return Reply(status: http.statusCode, body: bytes)
    }
}

// MARK: - PROPFIND

private enum PropfindParser {
    private static let responsePattern = #"(?is)<(?:[a-zA-Z0-9_-]+:)?response\b[^>]*>(.*?)</(?:[a-zA-Z0-9_-]+:)?response>"#
    private static let hrefPattern = #"(?i)<(?:[a-zA-Z0-9_-]+:)?href\b[^>]*>([^<]+)</(?:[a-zA-Z0-9_-]+:)?href>"#

    static func backups(xml: String, baseURL: URL) -> [RemoteBackupInfo] {
        let rows = captures(in: xml, pattern: responsePattern)
        guard !rows.isEmpty else { return [] }

        let timestamp = serverDateParser()
        return rows.compactMap { row -> RemoteBackupInfo? in
            guard let href = captures(in: row, pattern: hrefPattern).first else { return nil }

            let link = decodedHref(href)
            let name = URL(fileURLWithPath: link.address).lastPathComponent
            let lowered = name.lowercased()
            guard lowered.hasPrefix("backup"), lowered.hasSuffix(".zip"),
                  let remote = URL(string: link.raw, relativeTo: baseURL)?.absoluteURL else {
                return nil
            }

            let size = tagValue("getcontentlength", in: row).flatMap(Int64.init)
            let modified = tagValue("getlastmodified", in: row).flatMap {
                timestamp.date(from: $0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return RemoteBackupInfo(fileName: name, url: remote, lastModified: modified, size: size)
        }
        .sorted(by: newestFirst)
    }

    static func jsonLinks(xml: String, baseURL: URL) -> [String: URL] {
        var table: [String: URL] = [:]
        for href in captures(in: xml, pattern: hrefPattern) where href.lowercased().hasSuffix(".json") {
            let link = decodedHref(href)
            let name = URL(fileURLWithPath: link.address).lastPathComponent
            if let url = URL(string: link.raw, relativeTo: baseURL)?.absoluteURL {
                table[name] = url
            }
        }
        return table
    }

    private struct HrefParts {
        let raw: String
        let address: String
    }

    private static func decodedHref(_ href: String) -> HrefParts {
        let raw = href.trimmingCharacters(in: .whitespacesAndNewlines)
        return HrefParts(raw: raw, address: raw.removingPercentEncoding ?? raw)
    }

    private static func tagValue(_ tag: String, in block: String) -> String? {
        let pattern = #"(?i)<(?:[a-zA-Z0-9_-]+:)?\#(tag)\b[^>]*>([^<]+)</(?:[a-zA-Z0-9_-]+:)?\#(tag)>"#
        return captures(in: block, pattern: pattern).first
    }

    private static func newestFirst(_ left: RemoteBackupInfo, _ right: RemoteBackupInfo) -> Bool {
        if let a = left.lastModified, let b = right.lastModified, abs(a.timeIntervalSince(b)) > 1 {
            return a > b
        }
        return left.fileName > right.fileName
    }

    private static func serverDateParser() -> DateFormatter {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "GMT")
        parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return parser
    }

    private static func captures(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }
}

// MARK: - 备份包

private enum BackupArchiveBuilder {
    static func build(
        books: [Book],
        sources: [BookSource],
        deviceName: String,
        date: Date,
        settingsJSON: Data?
    ) throws -> (data: Data, fileName: String) {
        let fileName = WebDAVConfig.generateBackupFileName(date: date, deviceName: deviceName)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var members: [(name: String, bytes: Data)] = [
            ("bookshelf.json", try PrettyJSON.encode(books)),
            ("bookSource.json", try PrettyJSON.encode(sources))
        ]
        if let settingsJSON {
            members.append(("settings.json", settingsJSON))
        }

        for member in members {
            try member.bytes.write(to: scratch.appendingPathComponent(member.name))
        }

        let zipURL = scratch.appendingPathComponent(fileName)
        let zip = try Archive(url: zipURL, accessMode: .create)
        for member in members {
            try zip.addEntry(with: member.name, relativeTo: scratch, compressionMethod: .deflate)
        }
        return (try Data(contentsOf: zipURL), fileName)
    }
}

private enum ArchiveInspector {
    private static let payloadNames = ["bookshelf.json", "bookSource.json", "settings.json"]

    static func contents(from archive: Archive) -> (
        books: [Book]?,
        sources: [BookSource]?,
        progress: [String: BookProgress]
    ) {
        let payloads = payloadData(in: archive)
        let books = payloads["bookshelf.json"]
            .flatMap { try? JSONDecoder().decode([Book].self, from: $0) }
        let sources = payloads["bookSource.json"]
            .flatMap { try? JSONDecoder().decode([BookSource].self, from: $0) }
        return (books, sources, progressData(in: archive))
    }

    static func settings(from archive: Archive) -> Data? {
        payloadData(in: archive)["settings.json"]
    }

    private static func payloadData(in archive: Archive) -> [String: Data] {
        var payloads: [String: Data] = [:]
        for name in payloadNames {
            guard let entry = archive[name]
                ?? archive.first(where: { $0.path.hasSuffix(name) }) else {
                continue
            }
            var bytes = Data()
            _ = try? archive.extract(entry) { bytes.append($0) }
            if !bytes.isEmpty {
                payloads[name] = bytes
            }
        }
        return payloads
    }

    private static func progressData(in archive: Archive) -> [String: BookProgress] {
        var table: [String: BookProgress] = [:]
        for entry in archive where isProgressFile(entry.path) {
            var bytes = Data()
            _ = try? archive.extract(entry) { bytes.append($0) }
            if let progress = try? JSONDecoder().decode(BookProgress.self, from: bytes) {
                table[BookProgressMerger.key(name: progress.name, author: progress.author)] = progress
            }
        }
        return table
    }

    private static func isProgressFile(_ path: String) -> Bool {
        guard path.hasSuffix(".json") else { return false }
        return path.hasPrefix("bookProgress/") || path.contains("/bookProgress/")
    }
}

private enum BookProgressMerger {
    static func key(name: String, author: String) -> String {
        name + "_" + author
    }

    /// requireNotBehind 为真时，同章但位置更小的进度不覆盖。
    static func apply(_ incoming: BookProgress, to book: inout Book, requireNotBehind: Bool) {
        guard shouldApply(incoming, to: book, requireNotBehind: requireNotBehind) else { return }

        book.durChapterIndex = incoming.durChapterIndex
        book.durChapterPos = incoming.durChapterPos
        if let title = incoming.durChapterTitle, !title.isEmpty {
            book.durChapterTitle = title
        }
        if let stamp = incoming.durChapterTime {
            book.durChapterTime = stamp
            book.lastCheckTime = stamp
        }
    }

    private static func shouldApply(
        _ incoming: BookProgress,
        to book: Book,
        requireNotBehind: Bool
    ) -> Bool {
        if incoming.durChapterIndex != book.durChapterIndex {
            return incoming.durChapterIndex > book.durChapterIndex
        }
        return requireNotBehind ? incoming.durChapterPos >= book.durChapterPos : true
    }
}

private enum PrettyJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        return try encoder.encode(value)
    }
}

private extension BookProgress {
    init(book: Book, timestamp: Int64) {
        self.name = book.name
        self.author = book.author
        self.durChapterIndex = book.durChapterIndex
        self.durChapterPos = book.durChapterPos
        self.durChapterTime = timestamp
        self.durChapterTitle = book.durChapterTitle
    }
}

// MARK: - 钥匙串

/// 只放 WebDAV 密码这一个值，不落 UserDefaults。
enum KeychainStore {
    private static let service = "com.factorcitrus.juyue.webdav"
    private static let legacyService = "io.legado.ios.webdav"

    private static func query(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        SecItemDelete(query(account: account, service: service) as CFDictionary)
        var item = query(account: account, service: service)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func read(account: String) -> String? {
        if let value = read(account: account, service: service) {
            return value
        }
        guard let legacy = read(account: account, service: legacyService) else { return nil }
        _ = write(legacy, account: account)
        return legacy
    }

    private static func read(account: String, service: String) -> String? {
        var item = query(account: account, service: service)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account, service: service) as CFDictionary)
        SecItemDelete(query(account: account, service: legacyService) as CFDictionary)
    }
}
