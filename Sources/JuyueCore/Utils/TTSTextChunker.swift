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
