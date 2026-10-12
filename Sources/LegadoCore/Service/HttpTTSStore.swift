import Foundation

/// 语音源的本地存档，对应安卓端 `httpTTS` 表。
public final class HttpTTSStore {
    public static let shared = HttpTTSStore()

    public private(set) var sources: [HttpTTS] = []

    private let fileURL: URL

    public init(directory: URL? = nil, fileName: String = "httpTTS.json") {
        let base = directory ?? HttpTTSStore.defaultDirectory()
        self.fileURL = base.appendingPathComponent(fileName)
    }

    public var filePath: String { fileURL.path }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Legado", isDirectory: true)
    }

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            sources = []
            return
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            sources = []
            return
        }
        sources = try JSONDecoder().decode([HttpTTS].self, from: data)
    }

    public func save() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sources)
        try data.write(to: fileURL, options: .atomic)
    }

    /// 导入一份语音源 JSON，`replace` 为真时清空原有列表。
    @discardableResult
    public func importJSON(_ json: String, replace: Bool = false) throws -> [HttpTTS] {
        let imported = try HttpTTS.parse(json: json)
        if replace {
            sources = imported
        } else {
            var merged = sources
            for source in imported {
                if let index = merged.firstIndex(where: { $0.id == source.id }) {
                    merged[index] = source
                } else {
                    merged.append(source)
                }
            }
            sources = merged
        }
        try save()
        return imported
    }

    public func remove(id: Int64) throws {
        sources.removeAll { $0.id == id }
        try save()
    }

    public func source(id: Int64?) -> HttpTTS? {
        guard let id else { return nil }
        return sources.first { $0.id == id }
    }
}
