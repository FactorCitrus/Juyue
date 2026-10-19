import Foundation

/// 单步检测记录。只存在本机，用来回答「哪一步、请求了什么、返回了什么」。
public struct SourceRequestDiagnostic: Codable, Identifiable, Equatable {
    public var id: UUID
    public var step: String
    public var url: String
    public var statusCode: Int
    public var elapsedMs: Int64
    public var responseBytes: Int
    public var responsePreview: String
    public var ruleHits: Int
    public var note: String

    public init(
        step: String,
        url: String,
        statusCode: Int = 0,
        elapsedMs: Int64 = 0,
        responseBytes: Int = 0,
        responsePreview: String = "",
        ruleHits: Int = 0,
        note: String = ""
    ) {
        self.id = UUID()
        self.step = step
        self.url = url
        self.statusCode = statusCode
        self.elapsedMs = elapsedMs
        self.responseBytes = responseBytes
        self.responsePreview = responsePreview
        self.ruleHits = ruleHits
        self.note = note
    }
}

public enum DiagnosticPreview {
    /// 响应摘要：压掉换行，最多 240 字，避免把整页 HTML 存进 UserDefaults。
    public static func make(_ text: String, limit: Int = 240) -> String {
        let flat = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
