import Foundation
import ZIPFoundation

#if canImport(UIKit)
import UIKit
#endif

public struct WebDAVConfig: Codable, Equatable {
    public var url: String
    public var username: String
    public var password: String
    public var remotePath: String
    public var deviceName: String
    public var lastSyncTime: Date?

    public static var defaultDeviceName: String {
        #if canImport(UIKit)
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return "iOS"
        #elseif os(macOS)
        if let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "Mac"
        #else
        return "Device"
        #endif
    }

    public static func generateBackupFileName(date: Date = Date(), deviceName: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: date)

        let rawDevice = (deviceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDevice = rawDevice
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "|", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))

        if !cleanDevice.isEmpty {
            return "backup\(dateStr)-\(cleanDevice).zip"
        } else {
            return "backup\(dateStr).zip"
        }
    }

    public init(
        url: String = "https://dav.jianguoyun.com/dav/",
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decodeIfPresent(String.self, forKey: .url) ?? "https://dav.jianguoyun.com/dav/"
        self.username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        self.remotePath = try container.decodeIfPresent(String.self, forKey: .remotePath) ?? "legado"
        self.deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? Self.defaultDeviceName
        self.lastSyncTime = try container.decodeIfPresent(Date.self, forKey: .lastSyncTime)
    }

    /// Computes the base URL for syncing (ensures trailing slash and appends remotePath)
    public var directoryURL: URL? {
        var rawUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawUrl.isEmpty else { return nil }
        if !rawUrl.hasPrefix("http://") && !rawUrl.hasPrefix("https://") {
            rawUrl = "https://" + rawUrl
        }
        if !rawUrl.hasSuffix("/") {
            rawUrl += "/"
        }
        let cleanPath = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !cleanPath.isEmpty {
            rawUrl += cleanPath + "/"
        }
        return URL(string: rawUrl)
    }

    public var serverRootURL: URL? {
        var rawUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawUrl.isEmpty else { return nil }
        if !rawUrl.hasPrefix("http://") && !rawUrl.hasPrefix("https://") {
            rawUrl = "https://" + rawUrl
        }
        if !rawUrl.hasSuffix("/") {
            rawUrl += "/"
        }
        return URL(string: rawUrl)
    }

    public var basicAuthHeader: String {
        let credentials = "\(username):\(password)"
        let encoded = credentials.data(using: .utf8)?.base64EncodedString() ?? ""
        return "Basic \(encoded)"
    }
}

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
        case .serverError(let code, let msg):
            return "WebDAV 服务器错误 (HTTP \(code)): \(msg)"
        case .backupNotFound:
            return "未在远程目录找到备份文件 (bookshelf.json 或 bookSource.json)"
        case .decodingFailed(let detail):
            return "备份数据解析失败: \(detail)"
        case .custom(let msg):
            return msg
        }
    }
}

public class WebDAVService {
    public static let shared = WebDAVService()
    private let configKey = "legado_webdav_config_v1"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func loadConfig() -> WebDAVConfig {
        if let data = UserDefaults.standard.data(forKey: configKey),
           let config = try? JSONDecoder().decode(WebDAVConfig.self, from: data) {
            return config
        }
        return WebDAVConfig()
    }

    public func saveConfig(_ config: WebDAVConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    /// Creates an authenticated URLRequest with WebDAV headers
    private func makeRequest(url: URL, method: String, config: WebDAVConfig, body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(config.basicAuthHeader, forHTTPHeaderField: "Authorization")
        req.setValue("Legado-iOS/1.0", forHTTPHeaderField: "User-Agent")
        if let contentType = contentType {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// Tests the connection to the WebDAV server. If the remote directory does not exist, attempts to create it via MKCOL.
    public func testConnection(config: WebDAVConfig) async throws -> String {
        guard let dirUrl = config.directoryURL else {
            throw WebDAVError.invalidURL
        }

        // Try PROPFIND on the directory
        var req = makeRequest(url: dirUrl, method: "PROPFIND", config: config)
        req.setValue("0", forHTTPHeaderField: "Depth")

        let (_, response) = try await session.data(for: req)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.custom("无法连接到服务器")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw WebDAVError.unauthorized
        }

        if httpResponse.statusCode == 404 {
            // Directory does not exist yet, try to create it with MKCOL
            try await createDirectoryIfNeeded(config: config)
            return "连接成功，已自动创建远程同步目录：\(config.remotePath)"
        }

        if httpResponse.statusCode == 200 || httpResponse.statusCode == 207 {
            return "连接成功！WebDAV 服务器已就绪。"
        }

        // In case PROPFIND is not supported (HTTP 405), fallback to GET / HEAD
        if httpResponse.statusCode == 405 {
            let getReq = makeRequest(url: dirUrl, method: "GET", config: config)
            let (_, getResponse) = try await session.data(for: getReq)
            if let gRes = getResponse as? HTTPURLResponse {
                if gRes.statusCode == 401 || gRes.statusCode == 403 {
                    throw WebDAVError.unauthorized
                }
                if (200...299).contains(gRes.statusCode) || gRes.statusCode == 301 || gRes.statusCode == 302 {
                    return "连接成功！"
                }
            }
        }

        return "连接成功 (HTTP \(httpResponse.statusCode))"
    }

    /// Creates the directory via MKCOL if it doesn't exist
    /// Creates the directory via MKCOL if it doesn't exist
    public func createDirectoryIfNeeded(config: WebDAVConfig) async throws {
        guard let dirUrl = config.directoryURL else { throw WebDAVError.invalidURL }
        try await createDirectoryIfNeeded(url: dirUrl, config: config)
    }

    public func createDirectoryIfNeeded(url: URL, config: WebDAVConfig) async throws {
        let req = makeRequest(url: url, method: "MKCOL", config: config)
        let (_, response) = try await session.data(for: req)
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw WebDAVError.unauthorized
            }
            // 201 Created or 405 Method Not Allowed (already exists) are fine
        }
    }

    public func sanitizeFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return name.components(separatedBy: invalidCharacters).joined(separator: "_")
    }

    /// Uploads reading progress for a single book to WebDAV (e.g. legado/bookProgress/name_author.json)
    public func uploadBookProgress(book: Book, config: WebDAVConfig) async throws {
        guard let dirUrl = config.directoryURL else { return }
        let progressDirUrl = dirUrl.appendingPathComponent("bookProgress")
        try? await createDirectoryIfNeeded(url: progressDirUrl, config: config)

        let prog = BookProgress(
            name: book.name,
            author: book.author,
            durChapterIndex: book.durChapterIndex,
            durChapterPos: book.durChapterPos,
            durChapterTime: book.durChapterTime > 0 ? book.durChapterTime : Int64(Date().timeIntervalSince1970 * 1000),
            durChapterTitle: book.durChapterTitle
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let progData = try encoder.encode(prog)
        let cleanFileName = sanitizeFileName("\(book.name)_\(book.author).json")
        let progFileUrl = progressDirUrl.appendingPathComponent(cleanFileName)
        let progReq = makeRequest(url: progFileUrl, method: "PUT", config: config, body: progData, contentType: "application/json; charset=utf-8")
        let (_, response) = try await session.data(for: progReq)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw WebDAVError.unauthorized
        }
    }

    /// Creates an Android-compatible backup ZIP archive containing bookshelf.json and bookSource.json
    public func createBackupZip(
        books: [Book],
        sources: [BookSource],
        deviceName: String = WebDAVConfig.defaultDeviceName,
        date: Date = Date()
    ) throws -> (data: Data, fileName: String) {
        let fileName = WebDAVConfig.generateBackupFileName(date: date, deviceName: deviceName)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]

        let booksData = try encoder.encode(books)
        let sourcesData = try encoder.encode(sources)

        let booksFile = tempDir.appendingPathComponent("bookshelf.json")
        let sourcesFile = tempDir.appendingPathComponent("bookSource.json")

        try booksData.write(to: booksFile)
        try sourcesData.write(to: sourcesFile)

        let zipFile = tempDir.appendingPathComponent(fileName)
        try {
            let archive = try Archive(url: zipFile, accessMode: .create)
            try archive.addEntry(with: "bookshelf.json", relativeTo: tempDir, compressionMethod: .deflate)
            try archive.addEntry(with: "bookSource.json", relativeTo: tempDir, compressionMethod: .deflate)
        }()

        let zipData = try Data(contentsOf: zipFile)
        return (zipData, fileName)
    }

    /// Backs up bookshelf and sources to WebDAV server in Android Legado format (backupYYYY-MM-DD-deviceName.zip)
    public func backup(books: [Book], sources: [BookSource], config: WebDAVConfig) async throws -> (booksCount: Int, sourcesCount: Int, backupFileName: String) {
        guard let dirUrl = config.directoryURL else {
            throw WebDAVError.invalidURL
        }

        // Try ensuring directory exists
        try? await createDirectoryIfNeeded(config: config)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]

        // 1. Create and upload Android Legado compatible ZIP archive: backupYYYY-MM-DD-deviceName.zip
        let (zipData, zipFileName) = try createBackupZip(books: books, sources: sources, deviceName: config.deviceName)
        let zipUrl = dirUrl.appendingPathComponent(zipFileName)
        let zipReq = makeRequest(url: zipUrl, method: "PUT", config: config, body: zipData, contentType: "application/zip")
        let (_, zipResponse) = try await session.data(for: zipReq)
        guard let httpZip = zipResponse as? HTTPURLResponse else {
            throw WebDAVError.custom("上传备份压缩包无响应")
        }
        if httpZip.statusCode == 401 || httpZip.statusCode == 403 {
            throw WebDAVError.unauthorized
        }
        guard (200...299).contains(httpZip.statusCode) else {
            throw WebDAVError.serverError(httpZip.statusCode, "上传备份文件失败")
        }

        // 2. Also upload standalone bookshelf.json & bookSource.json for convenience and backwards compatibility
        let booksData = try encoder.encode(books)
        let booksUrl = dirUrl.appendingPathComponent("bookshelf.json")
        let booksReq = makeRequest(url: booksUrl, method: "PUT", config: config, body: booksData, contentType: "application/json; charset=utf-8")
        _ = try? await session.data(for: booksReq)

        let sourcesData = try encoder.encode(sources)
        let sourcesUrl = dirUrl.appendingPathComponent("bookSource.json")
        let sourcesReq = makeRequest(url: sourcesUrl, method: "PUT", config: config, body: sourcesData, contentType: "application/json; charset=utf-8")
        _ = try? await session.data(for: sourcesReq)

        // Note: We do NOT perform 40+ sequential blocking HTTP PUT requests to bookProgress/ here!
        // All books' durChapterIndex & durChapterPos are already completely preserved inside bookshelf.json in the zip archive.
        // Individual bookProgress/ files are automatically synced on demand when reading.

        // Update last sync time
        var updatedConfig = config
        updatedConfig.lastSyncTime = Date()
        saveConfig(updatedConfig)

        return (books.count, sources.count, zipFileName)
    }

    /// Lists all backup*.zip archives in the WebDAV directory, sorted descending (latest first)
    public func listRemoteBackups(config: WebDAVConfig) async throws -> [RemoteBackupInfo] {
        guard let dirUrl = config.directoryURL else {
            throw WebDAVError.invalidURL
        }

        var propReq = makeRequest(url: dirUrl, method: "PROPFIND", config: config)
        propReq.setValue("1", forHTTPHeaderField: "Depth")
        let (data, response) = try await session.data(for: propReq)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.custom("无法连接到 WebDAV 服务器")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw WebDAVError.unauthorized
        }
        guard (200...299).contains(http.statusCode) || http.statusCode == 207 else {
            return []
        }

        guard let xml = String(data: data, encoding: .utf8) else {
            return []
        }

        return parseBackupsFromPropfindXML(xml, baseURL: dirUrl)
    }

    public func parseBackupsFromPropfindXML(_ xml: String, baseURL: URL) -> [RemoteBackupInfo] {
        var results: [RemoteBackupInfo] = []

        let responsePattern = #"(?is)<(?:[a-zA-Z0-9_-]+:)?response\b[^>]*>(.*?)</(?:[a-zA-Z0-9_-]+:)?response>"#
        guard let responseRegex = try? NSRegularExpression(pattern: responsePattern) else {
            return []
        }

        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let matches = responseRegex.matches(in: xml, options: [], range: range)

        let hrefPattern = #"(?i)<(?:[a-zA-Z0-9_-]+:)?href\b[^>]*>([^<]+)</(?:[a-zA-Z0-9_-]+:)?href>"#
        let hrefRegex = try? NSRegularExpression(pattern: hrefPattern)

        let lengthPattern = #"(?i)<(?:[a-zA-Z0-9_-]+:)?getcontentlength\b[^>]*>([0-9]+)</(?:[a-zA-Z0-9_-]+:)?getcontentlength>"#
        let lengthRegex = try? NSRegularExpression(pattern: lengthPattern)

        let modPattern = #"(?i)<(?:[a-zA-Z0-9_-]+:)?getlastmodified\b[^>]*>([^<]+)</(?:[a-zA-Z0-9_-]+:)?getlastmodified>"#
        let modRegex = try? NSRegularExpression(pattern: modPattern)

        let rfc822Formatter = DateFormatter()
        rfc822Formatter.locale = Locale(identifier: "en_US_POSIX")
        rfc822Formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        for match in matches {
            guard let responseRange = Range(match.range(at: 1), in: xml) else { continue }
            let responseChunk = String(xml[responseRange])

            guard let hrefMatch = hrefRegex?.firstMatch(in: responseChunk, range: NSRange(responseChunk.startIndex..<responseChunk.endIndex, in: responseChunk)),
                  let hrefR = Range(hrefMatch.range(at: 1), in: responseChunk) else { continue }
            let rawHref = String(responseChunk[hrefR]).trimmingCharacters(in: .whitespacesAndNewlines)
            let decodedHref = rawHref.removingPercentEncoding ?? rawHref
            let fileName = URL(fileURLWithPath: decodedHref).lastPathComponent

            guard fileName.lowercased().hasPrefix("backup") && fileName.lowercased().hasSuffix(".zip") else {
                continue
            }

            guard let fullUrl = URL(string: rawHref, relativeTo: baseURL)?.absoluteURL else {
                continue
            }

            var size: Int64? = nil
            if let lenMatch = lengthRegex?.firstMatch(in: responseChunk, range: NSRange(responseChunk.startIndex..<responseChunk.endIndex, in: responseChunk)),
               let lenR = Range(lenMatch.range(at: 1), in: responseChunk) {
                size = Int64(String(responseChunk[lenR]))
            }

            var lastModified: Date? = nil
            if let modMatch = modRegex?.firstMatch(in: responseChunk, range: NSRange(responseChunk.startIndex..<responseChunk.endIndex, in: responseChunk)),
               let modR = Range(modMatch.range(at: 1), in: responseChunk) {
                let modStr = String(responseChunk[modR]).trimmingCharacters(in: .whitespacesAndNewlines)
                lastModified = rfc822Formatter.date(from: modStr)
            }

            results.append(RemoteBackupInfo(
                fileName: fileName,
                url: fullUrl,
                lastModified: lastModified,
                size: size
            ))
        }

        return results.sorted { a, b in
            if let d1 = a.lastModified, let d2 = b.lastModified, abs(d1.timeIntervalSince(d2)) > 1.0 {
                return d1 > d2
            }
            return a.fileName > b.fileName
        }
    }

    /// Restores bookshelf and sources from WebDAV server (supports both Android backup*.zip and direct JSON files)
    public func restore(config: WebDAVConfig, backupFileName: String? = nil) async throws -> (books: [Book]?, sources: [BookSource]?, backupName: String?) {
        guard let dirUrl = config.directoryURL else {
            throw WebDAVError.invalidURL
        }

        var restoredBooks: [Book]? = nil
        var restoredSources: [BookSource]? = nil
        var usedBackupName: String? = nil

        // 1. Try finding and downloading Android-compatible backup*.zip files first
        if let remoteBackups = try? await listRemoteBackups(config: config), !remoteBackups.isEmpty {
            let targetBackup: RemoteBackupInfo
            if let specificName = backupFileName, let found = remoteBackups.first(where: { $0.fileName == specificName }) {
                targetBackup = found
            } else {
                targetBackup = remoteBackups[0]
            }

            let zipReq = makeRequest(url: targetBackup.url, method: "GET", config: config)
            if let (zipData, zipResp) = try? await session.data(for: zipReq),
               let httpZip = zipResp as? HTTPURLResponse, (200...299).contains(httpZip.statusCode) {
                let zipResult = try? restoreFromZip(data: zipData)
                restoredBooks = zipResult?.books
                restoredSources = zipResult?.sources
                usedBackupName = targetBackup.fileName
            }
        }

        // 2. If no zip was restored, try loose bookshelf.json and bookSource.json
        if restoredBooks == nil {
            let booksUrl = dirUrl.appendingPathComponent("bookshelf.json")
            let booksReq = makeRequest(url: booksUrl, method: "GET", config: config)
            if let (booksData, booksResponse) = try? await session.data(for: booksReq),
               let httpBooks = booksResponse as? HTTPURLResponse {
                if httpBooks.statusCode == 401 || httpBooks.statusCode == 403 {
                    throw WebDAVError.unauthorized
                }
                if (200...299).contains(httpBooks.statusCode) {
                    if let decodedBooks = try? JSONDecoder().decode([Book].self, from: booksData) {
                        restoredBooks = decodedBooks
                        if usedBackupName == nil { usedBackupName = "bookshelf.json" }
                    }
                }
            }
        }

        if restoredSources == nil {
            let sourcesUrl = dirUrl.appendingPathComponent("bookSource.json")
            let sourcesReq = makeRequest(url: sourcesUrl, method: "GET", config: config)
            if let (sourcesData, sourcesResponse) = try? await session.data(for: sourcesReq),
               let httpSources = sourcesResponse as? HTTPURLResponse {
                if httpSources.statusCode == 401 || httpSources.statusCode == 403 {
                    throw WebDAVError.unauthorized
                }
                if (200...299).contains(httpSources.statusCode) {
                    if let decodedSources = try? JSONDecoder().decode([BookSource].self, from: sourcesData) {
                        restoredSources = decodedSources
                    }
                }
            }
        }

        // 3. Sync any latest progress from remote bookProgress/ folder using single PROPFIND + concurrent batch fetch
        if var books = restoredBooks {
            let progressDirUrl = dirUrl.appendingPathComponent("bookProgress")
            var propReq = makeRequest(url: progressDirUrl, method: "PROPFIND", config: config)
            propReq.setValue("1", forHTTPHeaderField: "Depth")
            if let (propData, propResp) = try? await session.data(for: propReq),
               let httpProp = propResp as? HTTPURLResponse, (200...299).contains(httpProp.statusCode) || httpProp.statusCode == 207,
               let propXml = String(data: propData, encoding: .utf8) {

                let hrefPattern = #"(?i)<(?:[a-zA-Z0-9_-]+:)?href\b[^>]*>([^<]+\.json)</(?:[a-zA-Z0-9_-]+:)?href>"#
                if let regex = try? NSRegularExpression(pattern: hrefPattern) {
                    let range = NSRange(propXml.startIndex..<propXml.endIndex, in: propXml)
                    let matches = regex.matches(in: propXml, options: [], range: range)
                    var remoteFiles: [String: URL] = [:]
                    for match in matches {
                        if let r = Range(match.range(at: 1), in: propXml) {
                            let rawPath = String(propXml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                            let decoded = rawPath.removingPercentEncoding ?? rawPath
                            let fn = URL(fileURLWithPath: decoded).lastPathComponent
                            if let full = URL(string: rawPath, relativeTo: progressDirUrl)?.absoluteURL {
                                remoteFiles[fn] = full
                            }
                        }
                    }

                    if !remoteFiles.isEmpty {
                        var tasks: [(index: Int, url: URL)] = []
                        for i in 0..<books.count {
                            let expectedName = sanitizeFileName("\(books[i].name)_\(books[i].author).json")
                            if let fUrl = remoteFiles[expectedName] {
                                tasks.append((i, fUrl))
                            }
                        }

                        if !tasks.isEmpty {
                            await withTaskGroup(of: (Int, BookProgress?).self) { group in
                                for item in tasks {
                                    group.addTask {
                                        let pReq = self.makeRequest(url: item.url, method: "GET", config: config)
                                        if let (pData, pResp) = try? await self.session.data(for: pReq),
                                           let httpP = pResp as? HTTPURLResponse, (200...299).contains(httpP.statusCode),
                                           let prog = try? JSONDecoder().decode(BookProgress.self, from: pData) {
                                            return (item.index, prog)
                                        }
                                        return (item.index, nil)
                                    }
                                }

                                for await (idx, progOpt) in group {
                                    if let prog = progOpt, idx < books.count {
                                        if prog.durChapterIndex > books[idx].durChapterIndex ||
                                            (prog.durChapterIndex == books[idx].durChapterIndex && prog.durChapterPos >= books[idx].durChapterPos) {
                                            books[idx].durChapterIndex = prog.durChapterIndex
                                            books[idx].durChapterPos = prog.durChapterPos
                                            if let title = prog.durChapterTitle, !title.isEmpty {
                                                books[idx].durChapterTitle = title
                                            }
                                            if let time = prog.durChapterTime {
                                                books[idx].durChapterTime = time
                                                books[idx].lastCheckTime = time
                                            }
                                        }
                                    }
                                }
                            }
                            restoredBooks = books
                        }
                    }
                }
            }
        }

        if restoredBooks == nil && restoredSources == nil {
            throw WebDAVError.backupNotFound
        }

        // Update last sync time
        var updatedConfig = config
        updatedConfig.lastSyncTime = Date()
        saveConfig(updatedConfig)

        return (restoredBooks, restoredSources, usedBackupName)
    }

    // MARK: - Zip Archive Restoration (Android Legado Compatible)

    /// Restores books and sources from a ZIP archive data (e.g. backup*.zip)
    public func restoreFromZip(data: Data) throws -> (books: [Book]?, sources: [BookSource]?) {
        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: nil) else {
            throw WebDAVError.decodingFailed("无法解析 Zip 压缩包数据")
        }
        return try parseArchive(archive)
    }

    /// Restores books and sources from a local ZIP file URL, and merges adjacent bookProgress if found
    public func restoreFromZip(fileUrl: URL) throws -> (books: [Book]?, sources: [BookSource]?) {
        guard let archive = try? Archive(url: fileUrl, accessMode: .read, pathEncoding: nil) else {
            throw WebDAVError.decodingFailed("无法读取 Zip 备份文件: \(fileUrl.lastPathComponent)")
        }
        var result = try parseArchive(archive)

        // Also check if an adjacent bookProgress directory exists (e.g. in user's Downloads directory)
        let parentDir = fileUrl.deletingLastPathComponent()
        let progressDir = parentDir.appendingPathComponent("bookProgress")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: progressDir.path, isDirectory: &isDir), isDir.boolValue {
            if var books = result.books {
                applyBookProgress(books: &books, fromDirectory: progressDir)
                result.books = books
            }
        }

        return result
    }

    /// Parses bookshelf.json, bookSource.json, and internal bookProgress from a ZIP archive
    public func parseArchive(_ archive: Archive) throws -> (books: [Book]?, sources: [BookSource]?) {
        var restoredBooks: [Book]? = nil
        var restoredSources: [BookSource]? = nil

        // 1. Locate and extract bookshelf.json
        if let entry = archive["bookshelf.json"] ?? archive.first(where: { $0.path.hasSuffix("bookshelf.json") }) {
            var data = Data()
            _ = try archive.extract(entry) { chunk in
                data.append(chunk)
            }
            if let decoded = try? JSONDecoder().decode([Book].self, from: data) {
                restoredBooks = decoded
            }
        }

        // 2. Locate and extract bookSource.json
        if let entry = archive["bookSource.json"] ?? archive.first(where: { $0.path.hasSuffix("bookSource.json") }) {
            var data = Data()
            _ = try archive.extract(entry) { chunk in
                data.append(chunk)
            }
            if let decoded = try? JSONDecoder().decode([BookSource].self, from: data) {
                restoredSources = decoded
            }
        }

        // 3. Extract any internal bookProgress/*.json
        var progressMap: [String: BookProgress] = [:]
        for entry in archive {
            let path = entry.path
            if (path.hasPrefix("bookProgress/") || path.contains("/bookProgress/")) && path.hasSuffix(".json") {
                var pData = Data()
                _ = try? archive.extract(entry) { chunk in
                    pData.append(chunk)
                }
                if let prog = try? JSONDecoder().decode(BookProgress.self, from: pData) {
                    let key = "\(prog.name)_\(prog.author)"
                    progressMap[key] = prog
                }
            }
        }

        // Apply progress updates to books
        if var books = restoredBooks, !progressMap.isEmpty {
            for i in 0..<books.count {
                let key = "\(books[i].name)_\(books[i].author)"
                if let prog = progressMap[key] {
                    if prog.durChapterIndex >= books[i].durChapterIndex {
                        books[i].durChapterIndex = prog.durChapterIndex
                        books[i].durChapterPos = prog.durChapterPos
                        if let title = prog.durChapterTitle, !title.isEmpty {
                            books[i].durChapterTitle = title
                        }
                        if let time = prog.durChapterTime {
                            books[i].durChapterTime = time
                            books[i].lastCheckTime = time
                        }
                    }
                }
            }
            restoredBooks = books
        }

        if restoredBooks == nil && restoredSources == nil {
            throw WebDAVError.backupNotFound
        }

        return (restoredBooks, restoredSources)
    }

    /// Reads an external bookProgress directory and updates reading progress for matching books
    public func applyBookProgress(books: inout [Book], fromDirectory dirUrl: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dirUrl, includingPropertiesForKeys: nil) else {
            return
        }

        var progressMap: [String: BookProgress] = [:]
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let prog = try? JSONDecoder().decode(BookProgress.self, from: data) {
                let key = "\(prog.name)_\(prog.author)"
                progressMap[key] = prog
            }
        }

        guard !progressMap.isEmpty else { return }

        for i in 0..<books.count {
            let key = "\(books[i].name)_\(books[i].author)"
            if let prog = progressMap[key] {
                if prog.durChapterIndex >= books[i].durChapterIndex {
                    books[i].durChapterIndex = prog.durChapterIndex
                    books[i].durChapterPos = prog.durChapterPos
                    if let title = prog.durChapterTitle, !title.isEmpty {
                        books[i].durChapterTitle = title
                    }
                    if let time = prog.durChapterTime {
                        books[i].durChapterTime = time
                        books[i].lastCheckTime = time
                    }
                }
            }
        }
    }
}
