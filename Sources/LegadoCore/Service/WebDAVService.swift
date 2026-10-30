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
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "iOS" : name
        #elseif os(macOS)
        if let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return "Mac"
        #else
        return "Device"
        #endif
    }

    /// 备份文件名沿用安卓端约定：backupYYYY-MM-DD-设备名.zip，设备名里的保留字符会破坏路径。
    public static func generateBackupFileName(date: Date = Date(), deviceName: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)

        let cleaned = (deviceName ?? "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "|", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))

        return cleaned.isEmpty ? "backup\(day).zip" : "backup\(day)-\(cleaned).zip"
    }

    public init(
        url: String = WebDAVConfig.defaultServer,
        username: String = "",
        password: String = "",
        remotePath: String = "legado",
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
        self.url = try box.decodeIfPresent(String.self, forKey: .url) ?? Self.defaultServer
        self.username = try box.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.password = try box.decodeIfPresent(String.self, forKey: .password) ?? ""
        self.remotePath = try box.decodeIfPresent(String.self, forKey: .remotePath) ?? "legado"
        self.deviceName = try box.decodeIfPresent(String.self, forKey: .deviceName) ?? Self.defaultDeviceName
        self.lastSyncTime = try box.decodeIfPresent(Date.self, forKey: .lastSyncTime)
    }

    private var baseComponents: (scheme: String, rest: String)? {
        var raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") {
            raw = "https://" + raw
        }
        if !raw.hasSuffix("/") {
            raw += "/"
        }
        return (raw.hasPrefix("http://") ? "http" : "https", raw)
    }

    /// 同步根目录：服务器地址 + remotePath，两级都补尾斜杠。
    public var directoryURL: URL? {
        guard var raw = baseComponents?.rest else { return nil }
        let path = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !path.isEmpty {
            raw += path + "/"
        }
        return URL(string: raw)
    }

    /// 真配好了才算配好：地址、账号、密码三样齐了才可能同步成功。
    /// 之前只看地址——默认服务器地址本身非空，于是没填账号也显示「已配置」。
    public var isConfigured: Bool {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password.trimmingCharacters(in: .whitespacesAndNewlines)
        return !address.isEmpty && !account.isEmpty && !secret.isEmpty
    }

    /// 服务器根，不含 remotePath。
    public var serverRootURL: URL? {
        guard let raw = baseComponents?.rest else { return nil }
        return URL(string: raw)
    }

    /// 明文 HTTP 下 Basic 等于裸传密码；这种情况宁可不带凭据，让服务端 401。
    public var sendCredentialsInClear: Bool {
        baseComponents?.scheme == "http"
    }

    public var basicAuthHeader: String {
        guard !sendCredentialsInClear else { return "" }
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
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
        static let configKey = "legado_webdav_config_v1"
        static let passwordAccount = "webdav_password"
    }

    private static let userAgent = "Juyue/1.0"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: 配置存取

    public func loadConfig() -> WebDAVConfig {
        guard let data = UserDefaults.standard.data(forKey: Storage.configKey),
              var config = try? JSONDecoder().decode(WebDAVConfig.self, from: data) else {
            return WebDAVConfig()
        }
        if config.password.isEmpty {
            config.password = KeychainStore.read(account: Storage.passwordAccount) ?? ""
        } else if KeychainStore.write(config.password, account: Storage.passwordAccount) {
            // 旧版本把明文写在配置里：迁移成功才抹掉，失败就维持原样，别让同步直接断。
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

    // MARK: 请求层

    private struct Response {
        let status: Int
        let body: Data

        var isSuccess: Bool { (200...299).contains(status) }
        var isAuthFailure: Bool { status == 401 || status == 403 }
    }

    private func send(
        _ method: String,
        to url: URL,
        config: WebDAVConfig,
        body: Data? = nil,
        contentType: String? = nil,
        depth: String? = nil
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let authorization = config.basicAuthHeader
        if !authorization.isEmpty {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let depth {
            request.setValue(depth, forHTTPHeaderField: "Depth")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.custom("服务器未返回 HTTP 响应")
        }
        return Response(status: http.statusCode, body: data)
    }

    // MARK: 连接与目录

    /// PROPFIND 探活；目录不存在就 MKCOL 建出来。405 的服务器退回 GET 探一下。
    public func testConnection(config: WebDAVConfig) async throws -> String {
        guard let directory = config.directoryURL else { throw WebDAVError.invalidURL }

        let probe = try await send("PROPFIND", to: directory, config: config, depth: "0")
        if probe.isAuthFailure { throw WebDAVError.unauthorized }
        if probe.status == 404 {
            try await createDirectoryIfNeeded(url: directory, config: config)
            return "连接成功，已自动创建远程同步目录：\(config.remotePath)"
        }
        if probe.isSuccess {
            return "连接成功！WebDAV 服务器已就绪。"
        }
        if probe.status == 405 {
            let fallback = try await send("GET", to: directory, config: config)
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

    /// 201 新建、204 无内容、405 已存在都算成；5xx 必须报错，否则后续上传会静默全挂。
    public func createDirectoryIfNeeded(url: URL, config: WebDAVConfig) async throws {
        let response = try await send("MKCOL", to: url, config: config)
        if response.isAuthFailure { throw WebDAVError.unauthorized }
        if ![200, 201, 204, 405].contains(response.status) {
            throw WebDAVError.custom("创建目录失败：HTTP \(response.status)")
        }
    }

    public func sanitizeFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return name.components(separatedBy: forbidden).joined(separator: "_")
    }

    // MARK: 进度

    /// 单本进度落到 bookProgress/书名_作者.json，与安卓端一致。
    public func uploadBookProgress(book: Book, config: WebDAVConfig) async throws {
        guard let directory = config.directoryURL else { return }
        let progressDirectory = directory.appendingPathComponent("bookProgress")
        try? await createDirectoryIfNeeded(url: progressDirectory, config: config)

        let progress = BookProgress(
            name: book.name,
            author: book.author,
            durChapterIndex: book.durChapterIndex,
            durChapterPos: book.durChapterPos,
            durChapterTime: book.durChapterTime > 0
                ? book.durChapterTime
                : Int64(Date().timeIntervalSince1970 * 1000),
            durChapterTitle: book.durChapterTitle
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let payload = try encoder.encode(progress)

        let fileName = sanitizeFileName("\(book.name)_\(book.author).json")
        let target = progressDirectory.appendingPathComponent(fileName)
        let response = try await send(
            "PUT", to: target, config: config,
            body: payload, contentType: "application/json; charset=utf-8"
        )
        if response.isAuthFailure { throw WebDAVError.unauthorized }
    }

    // MARK: 备份

    /// 安卓能读的备份包：bookshelf.json + bookSource.json，应用内设置作为第三个条目。
    public func createBackupZip(
        books: [Book],
        sources: [BookSource],
        deviceName: String = WebDAVConfig.defaultDeviceName,
        date: Date = Date(),
        settingsJSON: Data? = nil
    ) throws -> (data: Data, fileName: String) {
        let fileName = WebDAVConfig.generateBackupFileName(date: date, deviceName: deviceName)
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]

        try encoder.encode(books).write(to: workspace.appendingPathComponent("bookshelf.json"))
        try encoder.encode(sources).write(to: workspace.appendingPathComponent("bookSource.json"))
        if let settingsJSON {
            try settingsJSON.write(to: workspace.appendingPathComponent("settings.json"))
        }

        let archiveURL = workspace.appendingPathComponent(fileName)
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "bookshelf.json", relativeTo: workspace, compressionMethod: .deflate)
        try archive.addEntry(with: "bookSource.json", relativeTo: workspace, compressionMethod: .deflate)
        if settingsJSON != nil {
            try archive.addEntry(with: "settings.json", relativeTo: workspace, compressionMethod: .deflate)
        }

        return (try Data(contentsOf: archiveURL), fileName)
    }

    /// 上传备份包，再补两份散 JSON 方便老版本与手工排查。
    public func backup(
        books: [Book],
        sources: [BookSource],
        config: WebDAVConfig,
        settingsJSON: Data? = nil
    ) async throws -> (booksCount: Int, sourcesCount: Int, backupFileName: String) {
        guard let directory = config.directoryURL else { throw WebDAVError.invalidURL }
        try? await createDirectoryIfNeeded(config: config)

        let (payload, fileName) = try createBackupZip(
            books: books,
            sources: sources,
            deviceName: config.deviceName,
            settingsJSON: settingsJSON
        )
        let upload = try await send(
            "PUT", to: directory.appendingPathComponent(fileName), config: config,
            body: payload, contentType: "application/zip"
        )
        if upload.isAuthFailure { throw WebDAVError.unauthorized }
        guard upload.isSuccess else {
            throw WebDAVError.serverError(upload.status, "上传备份文件失败")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        for (name, data) in [
            ("bookshelf.json", try encoder.encode(books)),
            ("bookSource.json", try encoder.encode(sources))
        ] {
            _ = try? await send(
                "PUT", to: directory.appendingPathComponent(name), config: config,
                body: data, contentType: "application/json; charset=utf-8"
            )
        }

        // 逐本进度不在这里推：bookshelf.json 已经带着章节下标，翻页时再按需上传。
        var updated = config
        updated.lastSyncTime = Date()
        saveConfig(updated)

        return (books.count, sources.count, fileName)
    }

    // MARK: 远端列表

    public func listRemoteBackups(config: WebDAVConfig) async throws -> [RemoteBackupInfo] {
        guard let directory = config.directoryURL else { throw WebDAVError.invalidURL }

        let response = try await send("PROPFIND", to: directory, config: config, depth: "1")
        if response.isAuthFailure { throw WebDAVError.unauthorized }
        guard response.isSuccess else { return [] }
        guard let xml = String(data: response.body, encoding: .utf8) else { return [] }

        return parseBackupsFromPropfindXML(xml, baseURL: directory)
    }

    /// 解析 multistatus：按 <response> 切块，逐块取 href / getcontentlength / getlastmodified。
    /// 命名空间前缀不固定（D:、d:、无前缀都见过），正则统一放宽。
    public func parseBackupsFromPropfindXML(_ xml: String, baseURL: URL) -> [RemoteBackupInfo] {
        let blocks = Self.matches(
            in: xml,
            pattern: #"(?is)<(?:[a-zA-Z0-9_-]+:)?response\b[^>]*>(.*?)</(?:[a-zA-Z0-9_-]+:)?response>"#
        )
        guard !blocks.isEmpty else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        var found: [RemoteBackupInfo] = []
        for block in blocks {
            guard let href = Self.firstMatch(
                in: block,
                pattern: #"(?i)<(?:[a-zA-Z0-9_-]+:)?href\b[^>]*>([^<]+)</(?:[a-zA-Z0-9_-]+:)?href>"#
            ) else { continue }

            let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
            let decoded = trimmed.removingPercentEncoding ?? trimmed
            let fileName = URL(fileURLWithPath: decoded).lastPathComponent

            guard fileName.lowercased().hasPrefix("backup"), fileName.lowercased().hasSuffix(".zip") else {
                continue
            }
            guard let remoteURL = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else { continue }

            let size = Self.firstMatch(
                in: block,
                pattern: #"(?i)<(?:[a-zA-Z0-9_-]+:)?getcontentlength\b[^>]*>([0-9]+)</(?:[a-zA-Z0-9_-]+:)?getcontentlength>"#
            ).flatMap(Int64.init)

            let modified = Self.firstMatch(
                in: block,
                pattern: #"(?i)<(?:[a-zA-Z0-9_-]+:)?getlastmodified\b[^>]*>([^<]+)</(?:[a-zA-Z0-9_-]+:)?getlastmodified>"#
            ).flatMap { formatter.date(from: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }

            found.append(RemoteBackupInfo(
                fileName: fileName,
                url: remoteURL,
                lastModified: modified,
                size: size
            ))
        }

        return found.sorted { lhs, rhs in
            if let a = lhs.lastModified, let b = rhs.lastModified, abs(a.timeIntervalSince(b)) > 1 {
                return a > b
            }
            return lhs.fileName > rhs.fileName
        }
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        matches(in: text, pattern: pattern).first
    }

    // MARK: 恢复

    /// 三条路依次试：备份 zip → 散装 bookshelf.json / bookSource.json → bookProgress/ 补进度。
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
            let chosen = backupFileName.flatMap { name in remote.first { $0.fileName == name } } ?? remote[0]
            let download = try? await send("GET", to: chosen.url, config: config)
            if let download, download.isSuccess {
                let parsed = try? restoreFromZip(data: download.body)
                books = parsed?.books
                sources = parsed?.sources
                settings = extractSettingsJSON(fromZip: download.body)
                usedName = chosen.fileName
            }
        }

        if books == nil {
            let response = try? await send(
                "GET", to: directory.appendingPathComponent("bookshelf.json"), config: config
            )
            if let response {
                if response.isAuthFailure { throw WebDAVError.unauthorized }
                if response.isSuccess, let decoded = try? JSONDecoder().decode([Book].self, from: response.body) {
                    books = decoded
                    usedName = usedName ?? "bookshelf.json"
                }
            }
        }

        if sources == nil {
            let response = try? await send(
                "GET", to: directory.appendingPathComponent("bookSource.json"), config: config
            )
            if let response {
                if response.isAuthFailure { throw WebDAVError.unauthorized }
                if response.isSuccess,
                   let decoded = try? JSONDecoder().decode([BookSource].self, from: response.body) {
                    sources = decoded
                }
            }
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

    /// 一次 PROPFIND 拿到 bookProgress 目录清单，再并发拉取命中当前书架的那几份。
    /// 合并规则：章节下标更大者胜；同章则位置更大者胜。
    private func mergeRemoteProgress(
        into books: [Book],
        directory: URL,
        config: WebDAVConfig
    ) async -> [Book] {
        let progressDirectory = directory.appendingPathComponent("bookProgress")
        guard let listing = try? await send(
            "PROPFIND", to: progressDirectory, config: config, depth: "1"
        ), listing.isSuccess, let xml = String(data: listing.body, encoding: .utf8) else {
            return books
        }

        let hrefs = Self.matches(
            in: xml,
            pattern: #"(?i)<(?:[a-zA-Z0-9_-]+:)?href\b[^>]*>([^<]+\.json)</(?:[a-zA-Z0-9_-]+:)?href>"#
        )
        var remoteFiles: [String: URL] = [:]
        for raw in hrefs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let decoded = trimmed.removingPercentEncoding ?? trimmed
            let name = URL(fileURLWithPath: decoded).lastPathComponent
            if let url = URL(string: trimmed, relativeTo: progressDirectory)?.absoluteURL {
                remoteFiles[name] = url
            }
        }
        guard !remoteFiles.isEmpty else { return books }

        let jobs: [(index: Int, url: URL)] = books.indices.compactMap { index in
            let name = sanitizeFileName("\(books[index].name)_\(books[index].author).json")
            guard let url = remoteFiles[name] else { return nil }
            return (index, url)
        }
        guard !jobs.isEmpty else { return books }

        var merged = books
        await withTaskGroup(of: (Int, BookProgress?).self) { group in
            for job in jobs {
                group.addTask {
                    guard let response = try? await self.send("GET", to: job.url, config: config),
                          response.isSuccess,
                          let progress = try? JSONDecoder().decode(BookProgress.self, from: response.body) else {
                        return (job.index, nil)
                    }
                    return (job.index, progress)
                }
            }
            for await (index, progress) in group {
                guard let progress, index < merged.count else { continue }
                Self.apply(progress, to: &merged[index], requireNotBehind: true)
            }
        }
        return merged
    }

    // MARK: 解包

    public func restoreFromZip(data: Data) throws -> (books: [Book]?, sources: [BookSource]?) {
        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: nil) else {
            throw WebDAVError.decodingFailed("无法解析 Zip 压缩包数据")
        }
        return try parseArchive(archive)
    }

    public func restoreFromZip(fileUrl: URL) throws -> (books: [Book]?, sources: [BookSource]?) {
        guard let archive = try? Archive(url: fileUrl, accessMode: .read, pathEncoding: nil) else {
            throw WebDAVError.decodingFailed("无法读取 Zip 备份文件: \(fileUrl.lastPathComponent)")
        }
        var result = try parseArchive(archive)

        // 用户把 zip 和 bookProgress 目录一起下载下来时，顺带合并一次。
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
        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: nil) else { return nil }
        return extractSettingsJSON(from: archive)
    }

    public func extractSettingsJSON(fromZipFileUrl url: URL) -> Data? {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else { return nil }
        return extractSettingsJSON(from: archive)
    }

    public func extractSettingsJSON(from archive: Archive) -> Data? {
        guard let entry = archive["settings.json"]
            ?? archive.first(where: { $0.path.hasSuffix("settings.json") }) else {
            return nil
        }
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return data.isEmpty ? nil : data
    }

    /// 包内三个来源：bookshelf.json、bookSource.json、bookProgress/*.json（可能带一层目录）。
    public func parseArchive(_ archive: Archive) throws -> (books: [Book]?, sources: [BookSource]?) {
        var books: [Book]?
        var sources: [BookSource]?

        if let entry = archive["bookshelf.json"]
            ?? archive.first(where: { $0.path.hasSuffix("bookshelf.json") }) {
            var data = Data()
            _ = try? archive.extract(entry) { data.append($0) }
            books = try? JSONDecoder().decode([Book].self, from: data)
        }

        if let entry = archive["bookSource.json"]
            ?? archive.first(where: { $0.path.hasSuffix("bookSource.json") }) {
            var data = Data()
            _ = try? archive.extract(entry) { data.append($0) }
            sources = try? JSONDecoder().decode([BookSource].self, from: data)
        }

        var progressByKey: [String: BookProgress] = [:]
        for entry in archive {
            let path = entry.path
            guard path.hasSuffix(".json"),
                  path.hasPrefix("bookProgress/") || path.contains("/bookProgress/") else { continue }
            var data = Data()
            _ = try? archive.extract(entry) { data.append($0) }
            if let progress = try? JSONDecoder().decode(BookProgress.self, from: data) {
                progressByKey[Self.progressKey(name: progress.name, author: progress.author)] = progress
            }
        }

        if var restored = books, !progressByKey.isEmpty {
            for index in restored.indices {
                let key = Self.progressKey(name: restored[index].name, author: restored[index].author)
                // 包内进度与书架同源，只要下标不倒退就采用（位置相等也算新）。
                if let progress = progressByKey[key],
                   progress.durChapterIndex >= restored[index].durChapterIndex {
                    Self.apply(progress, to: &restored[index], requireNotBehind: false)
                }
            }
            books = restored
        }

        guard books != nil || sources != nil else { throw WebDAVError.backupNotFound }
        return (books, sources)
    }

    /// 读取磁盘上的 bookProgress 目录，合并进书架。
    public func applyBookProgress(books: inout [Book], fromDirectory dirUrl: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dirUrl, includingPropertiesForKeys: nil
        ) else { return }

        var progressByKey: [String: BookProgress] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let progress = try? JSONDecoder().decode(BookProgress.self, from: data) else { continue }
            progressByKey[Self.progressKey(name: progress.name, author: progress.author)] = progress
        }
        guard !progressByKey.isEmpty else { return }

        for index in books.indices {
            let key = Self.progressKey(name: books[index].name, author: books[index].author)
            if let progress = progressByKey[key], progress.durChapterIndex >= books[index].durChapterIndex {
                Self.apply(progress, to: &books[index], requireNotBehind: false)
            }
        }
    }

    private static func progressKey(name: String, author: String) -> String {
        "\(name)_\(author)"
    }

    /// requireNotBehind 为真时，同章但位置更小的进度不覆盖（远端旧数据不该把本地往后拖）。
    private static func apply(_ progress: BookProgress, to book: inout Book, requireNotBehind: Bool) {
        let ahead = progress.durChapterIndex > book.durChapterIndex
        let sameChapterFurther = progress.durChapterIndex == book.durChapterIndex
            && (!requireNotBehind || progress.durChapterPos >= book.durChapterPos)
        guard ahead || sameChapterFurther else { return }

        book.durChapterIndex = progress.durChapterIndex
        book.durChapterPos = progress.durChapterPos
        if let title = progress.durChapterTitle, !title.isEmpty {
            book.durChapterTitle = title
        }
        if let time = progress.durChapterTime {
            book.durChapterTime = time
            book.lastCheckTime = time
        }
    }
}

// MARK: - 钥匙串

/// 只放 WebDAV 密码这一个值，不落 UserDefaults。
enum KeychainStore {
    private static let service = "io.legado.ios.webdav"

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        SecItemDelete(query(account: account) as CFDictionary)
        var item = query(account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func read(account: String) -> String? {
        var item = query(account: account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
