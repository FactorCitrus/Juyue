import Foundation
import Combine
#if canImport(JuyueCore)
import JuyueCore
#endif

/// 每本书离线目录里的清单：书籍快照 + 目录 + 书评文件列表
public struct OfflineBookMeta: Codable {
    public var book: Book
    public var chapters: [BookChapter]
    public var reviewFiles: [String]
    public var updatedAt: Date

    public init(book: Book, chapters: [BookChapter], reviewFiles: [String], updatedAt: Date = Date()) {
        self.book = book
        self.chapters = chapters
        self.reviewFiles = reviewFiles
        self.updatedAt = updatedAt
    }
}

public struct OfflineBookEntry: Identifiable, Equatable {
    public var bookUrl: String
    public var name: String
    public var author: String
    public var cachedChapters: Int
    public var totalChapters: Int
    public var reviewCount: Int
    public var bytes: Int64
    public var updatedAt: Date

    public var id: String { bookUrl }
}

/// 离线书库：Documents/OfflineBooks 下每本书一个目录，这里负责目录、清单与统计
public final class OfflineBookStore: ObservableObject {
    public static let shared = OfflineBookStore()

    @Published public private(set) var entries: [OfflineBookEntry] = []

    private let scanQueue = DispatchQueue(label: "juyue.offlinebooks.scan", qos: .utility)

    public init() {}

    /// App 启动时调用：把旧版 Caches 里的正文挪进离线目录，再刷新列表
    public func bootstrap() {
        migrateLegacyChapterCache()
        refresh()
    }

    // MARK: 目录

    public func directory(for bookUrl: String) -> URL {
        OfflineBookPaths.directory(forBookUrl: bookUrl)
    }

    public func meta(for bookUrl: String) -> OfflineBookMeta? {
        let file = OfflineBookPaths.metaFile(forBookUrl: bookUrl)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(OfflineBookMeta.self, from: data)
    }

    public func save(meta: OfflineBookMeta, for bookUrl: String) {
        var updated = meta
        updated.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(updated) else { return }
        try? data.write(to: OfflineBookPaths.metaFile(forBookUrl: bookUrl), options: .atomic)
    }

    public func cachedIndices(for bookUrl: String) -> [Int] {
        let folder = OfflineBookPaths.directory(forBookUrl: bookUrl)
            .appendingPathComponent("chapters", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return files.compactMap { name in
            name.hasSuffix(".txt") ? Int(name.dropLast(4)) : nil
        }.sorted()
    }

    public func reviewFiles(for bookUrl: String) -> [String] {
        let folder = OfflineBookPaths.directory(forBookUrl: bookUrl)
            .appendingPathComponent("reviews", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return files.filter { $0.hasSuffix(".json") }.sorted()
    }

    public func size(for bookUrl: String) -> Int64 {
        Self.directorySize(OfflineBookPaths.directory(forBookUrl: bookUrl))
    }

    public func removeCache(for bookUrl: String) {
        try? FileManager.default.removeItem(at: OfflineBookPaths.directory(forBookUrl: bookUrl))
        refresh()
    }

    public var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.bytes }
    }

    // MARK: 刷新列表

    public func refresh() {
        let shelf = BookStore.shared.bookshelf
        scanQueue.async { [weak self] in
            let fm = FileManager.default
            guard let folders = try? fm.contentsOfDirectory(
                at: OfflineBookPaths.root,
                includingPropertiesForKeys: nil
            ) else {
                DispatchQueue.main.async { self?.entries = [] }
                return
            }

            let shelfByKey = Dictionary(uniqueKeysWithValues: shelf.map { (CryptoUtils.md5($0.bookUrl), $0) })
            var list: [OfflineBookEntry] = []
            for folder in folders where folder.hasDirectoryPath {
                let key = folder.lastPathComponent
                let metaFile = folder.appendingPathComponent("meta.json")
                let meta = (try? Data(contentsOf: metaFile)).flatMap {
                    try? JSONDecoder().decode(OfflineBookMeta.self, from: $0)
                }
                let shelfBook = shelfByKey[key]
                guard let bookURL = meta?.book.bookUrl ?? shelfBook?.bookUrl else { continue }

                let chaptersFolder = folder.appendingPathComponent("chapters", isDirectory: true)
                let reviewsFolder = folder.appendingPathComponent("reviews", isDirectory: true)
                let cached = (try? fm.contentsOfDirectory(atPath: chaptersFolder.path))?
                    .filter { $0.hasSuffix(".txt") }.count ?? 0
                let reviews = (try? fm.contentsOfDirectory(atPath: reviewsFolder.path))?
                    .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".reply.json") }.count ?? 0
                guard cached > 0 || reviews > 0 else { continue }

                let name = meta?.book.name ?? shelfBook?.name ?? "未知书籍"
                list.append(
                    OfflineBookEntry(
                        bookUrl: bookURL,
                        name: name,
                        author: meta?.book.author ?? shelfBook?.author ?? "",
                        cachedChapters: cached,
                        totalChapters: meta?.chapters.count ?? shelfBook?.totalChapterNum ?? cached,
                        reviewCount: reviews,
                        bytes: Self.directorySize(folder),
                        updatedAt: meta?.updatedAt ?? (try? metaFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    )
                )
            }
            list.sort { $0.updatedAt > $1.updatedAt }
            DispatchQueue.main.async { self?.entries = list }
        }
    }

    // MARK: 旧缓存迁移

    private func migrateLegacyChapterCache() {
        let fm = FileManager.default
        let legacy = OfflineBookPaths.legacyChapterRoot
        guard let folders = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) else { return }
        for folder in folders where folder.hasDirectoryPath {
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            let texts = files.filter { $0.pathExtension == "txt" }
            if texts.isEmpty {
                if files.isEmpty { try? fm.removeItem(at: folder) }
                continue
            }
            let target = OfflineBookPaths.root
                .appendingPathComponent(folder.lastPathComponent, isDirectory: true)
                .appendingPathComponent("chapters", isDirectory: true)
            if !fm.fileExists(atPath: target.path) {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            }
            for file in texts {
                let destination = target.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: destination.path) { continue }
                try? fm.moveItem(at: file, to: destination)
            }
            // 目录空了才删，避免误删还没搬走的文件
            if let left = try? fm.contentsOfDirectory(atPath: folder.path), left.isEmpty {
                try? fm.removeItem(at: folder)
            }
        }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
