import Foundation

/// 把正文切成适合逐段合成的片段。
///
/// 在线语音一次塞太多字会被截断或超时，按句末标点断开、再合并到长度上限。
public enum TTSTextChunker {
    private static let stops: Set<Character> = [
        "。", "！", "？", "…", "；", "\n", ".", "!", "?", ";"
    ]

    public static func split(_ text: String, maxLength limit: Int = 150) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalized.contains(where: { !$0.isWhitespace }) else { return [] }
        guard limit > 0 else { return [normalized] }

        var chunks: [String] = []
        var carry: [Character] = []

        for unit in sentenceUnits(in: normalized) {
            let body = unit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let characters = Array(body)

            if characters.count > limit {
                if !carry.isEmpty {
                    chunks.append(String(carry))
                    carry.removeAll(keepingCapacity: true)
                }
                chunks.append(contentsOf: hardCut(characters, width: limit))
                continue
            }

            if carry.count + characters.count > limit {
                chunks.append(String(carry))
                carry = characters
            } else {
                carry.append(contentsOf: characters)
            }
        }

        if !carry.isEmpty { chunks.append(String(carry)) }
        return chunks
    }

    private static func sentenceUnits(in text: String) -> [String] {
        var units: [String] = []
        var start = text.startIndex
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if stops.contains(text[cursor]) {
                let end = text.index(after: cursor)
                units.append(String(text[start..<end]))
                start = end
            }
            cursor = text.index(after: cursor)
        }
        if start < text.endIndex { units.append(String(text[start...])) }
        return units
    }

    private static func hardCut(_ characters: [Character], width: Int) -> [String] {
        stride(from: 0, to: characters.count, by: width).map { offset in
            String(characters[offset..<min(offset + width, characters.count)])
        }
    }
}

/// MultiTTS / BDeTTS 音色包的结构约定：
/// `config.yaml` + `bdetts/<编号>/text.dat` + `bdetts/<编号>/acoustic/*.voc.dat`。
public enum BaiduVoicePack {
    /// 从声学模型所在目录向上逐级找文本模型，直到包根。
    /// 优先同目录的 `text.dat`，其次名字带 text 的 `.dat`；`*.voc.dat` 不算文本模型。
    public static func textModel(for voice: URL, in packRoot: URL) -> URL? {
        let root = packRoot.standardizedFileURL
        var dir = voice.deletingLastPathComponent().standardizedFileURL
        while true {
            if let found = textFile(in: dir) { return found }
            if dir.path == root.path { return nil }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            guard parent.path != dir.path, parent.path.hasPrefix(root.path) else { return nil }
            dir = parent
        }
    }

    /// 读 `config.yaml` 里该编号对应的 `name`，例如 `wc10316` → `旁青女`。
    public static func displayName(code: String, in packRoot: URL) -> String? {
        let url = packRoot.appendingPathComponent("config.yaml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var currentCode: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("code:") {
                currentCode = scalar(line, droppingKey: "code")
            } else if line.hasPrefix("name:"), currentCode == code {
                guard let name = scalar(line, droppingKey: "name"), !name.isEmpty else { return nil }
                return name
            }
        }
        return nil
    }

    private static func textFile(in dir: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let dats = names.filter {
            let lower = $0.lowercased()
            return lower.hasSuffix(".dat") && !lower.hasSuffix(".voc.dat")
        }
        if dats.contains("text.dat") {
            return dir.appendingPathComponent("text.dat")
        }
        if let hit = dats.first(where: { $0.lowercased().contains("text") }) {
            return dir.appendingPathComponent(hit)
        }
        return nil
    }

    private static func scalar(_ line: String, droppingKey key: String) -> String? {
        var value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        } else if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
}
