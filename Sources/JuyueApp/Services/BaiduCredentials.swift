import Foundation

#if !NO_BAIDU_TTS

// 百度语音凭据 · 公开版内置值为空
// APP ID / API Key / Secret Key / 离线序列号都在设置页里填。
// 不要把真实值提交到这个文件，凭据会留在 Git 历史里。

/// 百度语音的四件套凭据。
///
/// 运行顺序：先看设置里填的（UserDefaults），没填才用这里的本地默认值。
/// 公开版本保持为空，凭据在设置页里填。
enum BaiduCredentials {
    /// 本地默认凭据。公开版本保持为空，凭据在设置页里填。
    ///
    /// 不要在这里提交真实值，凭据会留在 Git 历史里。
    enum LocalDefaults {
        static let appId = ""
        static let apiKey = ""
        static let secretKey = ""
        static let serials: [String] = []
    }

    private static var defaults: UserDefaults { .standard }

    static var appId: String {
        let stored = defaults.string(forKey: "baidu_app_id") ?? ""
        return stored.isEmpty ? LocalDefaults.appId : stored
    }

    static var apiKey: String {
        let stored = defaults.string(forKey: "baidu_api_key") ?? ""
        return stored.isEmpty ? LocalDefaults.apiKey : stored
    }

    static var secretKey: String {
        let stored = defaults.string(forKey: "baidu_secret_key") ?? ""
        return stored.isEmpty ? LocalDefaults.secretKey : stored
    }

    /// 离线序列号，一行一条
    static var serials: [String] {
        let stored = defaults.string(forKey: "baidu_serials") ?? ""
        let list = stored
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 128 }
        return list.isEmpty ? LocalDefaults.serials : Array(list.prefix(10))
    }

    /// 后台设置页写回的入口
    static func store(appId: String, apiKey: String, secretKey: String, serials: String) {
        func clipped(_ value: String, _ limit: Int) -> String {
            String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        defaults.set(clipped(appId, 64), forKey: "baidu_app_id")
        defaults.set(clipped(apiKey, 128), forKey: "baidu_api_key")
        defaults.set(clipped(secretKey, 128), forKey: "baidu_secret_key")
        // 误粘贴整段文本时别把几千行都存进去，自检会逐条换授权。
        let cleaned = serials
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 128 }
        defaults.set(cleaned.prefix(10).joined(separator: "\n"), forKey: "baidu_serials")
    }

    static var hasCustomValues: Bool {
        !(defaults.string(forKey: "baidu_app_id") ?? "").isEmpty
            || !(defaults.string(forKey: "baidu_api_key") ?? "").isEmpty
            || !(defaults.string(forKey: "baidu_secret_key") ?? "").isEmpty
            || !(defaults.string(forKey: "baidu_serials") ?? "").isEmpty
    }

    /// 清掉设置里填过的那套，回到包内写死的值。
    /// 装机时从旧备份恢复过一份别的 APP ID（124571480 那种），授权会一直对不上。
    static func resetToBuiltin() {
        for key in ["baidu_app_id", "baidu_api_key", "baidu_secret_key", "baidu_serials"] {
            defaults.removeObject(forKey: key)
        }
    }
}

#else

// 商店包与模拟器构建不带百度凭据：保持同一套 API，值全空。
// 这样密钥不会因为设置页引用而被编进二进制。
enum BaiduCredentials {
    enum LocalDefaults {
        static let appId = ""
        static let apiKey = ""
        static let secretKey = ""
        static let serials: [String] = []
    }

    static var appId: String { "" }
    static var apiKey: String { "" }
    static var secretKey: String { "" }
    static var serials: [String] { [] }
    static var hasCustomValues: Bool { false }

    static func store(appId: String, apiKey: String, secretKey: String, serials: String) {}
    static func resetToBuiltin() {}
}

#endif