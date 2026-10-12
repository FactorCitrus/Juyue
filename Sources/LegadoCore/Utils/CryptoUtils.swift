import Foundation
import CryptoKit

public enum CryptoUtils {

    public static func md5(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else { return "" }
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func base64Encode(_ string: String) -> String {
        return Data(string.utf8).base64EncodedString()
    }

    public static func base64Decode(_ string: String) -> String {
        guard let data = Data(base64Encoded: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
