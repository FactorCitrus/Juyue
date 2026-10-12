import Foundation

/// 把正文切成适合逐段合成的片段。
///
/// 在线语音源一次请求塞太多字，要么被服务器截断，要么返回超时；
/// 安卓端同样按段合成，这里按句末标点切，再合并到长度上限。
public enum TTSTextChunker {

    private static let sentenceEnders: Set<Character> = ["。", "！", "？", "…", "；", "\n", ".", "!", "?", ";"]

    public static func split(_ text: String, maxLength: Int = 150) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard maxLength > 0 else { return [normalized] }

        var sentences: [String] = []
        var current = ""
        for character in normalized {
            current.append(character)
            if sentenceEnders.contains(character) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            sentences.append(current)
        }

        var chunks: [String] = []
        var buffer = ""
        for sentence in sentences {
            let piece = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }

            if piece.count > maxLength {
                if !buffer.isEmpty {
                    chunks.append(buffer)
                    buffer = ""
                }
                chunks.append(contentsOf: hardSplit(piece, maxLength: maxLength))
                continue
            }

            if buffer.isEmpty {
                buffer = piece
            } else if buffer.count + piece.count <= maxLength {
                buffer += piece
            } else {
                chunks.append(buffer)
                buffer = piece
            }
        }
        if !buffer.isEmpty {
            chunks.append(buffer)
        }
        return chunks
    }

    /// 超长句按长度硬切，避免单个请求过大。
    private static func hardSplit(_ text: String, maxLength: Int) -> [String] {
        var pieces: [String] = []
        var buffer = ""
        for character in text {
            buffer.append(character)
            if buffer.count >= maxLength {
                pieces.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty {
            pieces.append(buffer)
        }
        return pieces
    }
}
