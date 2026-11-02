import Foundation
import CryptoKit

/// 纯工具：哈希与 Base64。行为规格见 docs/licensing/specs/CryptoUtils.md。
public enum CryptoUtils {

    public static func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        var hex = ""
        hex.reserveCapacity(32)
        for byte in digest {
            let piece = String(byte, radix: 16)
            hex += piece.count == 1 ? "0" + piece : piece
        }
        return hex
    }

    public static func base64Encode(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
    }

    public static func base64Decode(_ string: String) -> String {
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: cleaned) else { return "" }
        guard let text = String(data: raw, encoding: .utf8) else { return "" }
        return text
    }
}
