import Foundation

// 百度语音凭据 · 侧载版内置值
// APP ID 124589494 / 包名 com.factorcitrus.juyue.app（文字识别 + 语音技术）
// 序列号写死在下面，运行时可被设置页覆盖。

/// 百度语音的四件套凭据。
///
/// 运行顺序：先看设置里填的（UserDefaults），没填才用这里的本地默认值。
/// 本机侧载版：APP ID 与序列号已写在 LocalDefaults 里，别把这份文件推到公开仓库。
enum BaiduCredentials {
    /// 本地默认凭据。公开版本保持为空，凭据在设置页里填。
    ///
    /// 不要在这里提交真实值，凭据会留在 Git 历史里。
    enum LocalDefaults {
        static let appId = "124589494"
        static let apiKey = "Knj0wxLjA1EyblnEbPi1X8Db"
        static let secretKey = "aAjnZ5LnIDXBddlHkgUjNDqwHHFXePU"
        static let serials: [String] = [
            "a375da77-825f866a-2f94-022b-a665e-00",
            "81b18ed3-68ea6767-2f94-022c-a665f-00",
        ]
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
            .filter { !$0.isEmpty }
        return list.isEmpty ? LocalDefaults.serials : list
    }

    /// 后台设置页写回的入口
    static func store(appId: String, apiKey: String, secretKey: String, serials: String) {
        defaults.set(appId.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "baidu_app_id")
        defaults.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "baidu_api_key")
        defaults.set(secretKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "baidu_secret_key")
        defaults.set(serials.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "baidu_serials")
    }

    static var hasCustomValues: Bool {
        !(defaults.string(forKey: "baidu_app_id") ?? "").isEmpty
            || !(defaults.string(forKey: "baidu_api_key") ?? "").isEmpty
    }

    /// 清掉设置里填过的那套，回到包内写死的值。
    /// 装机时从旧备份恢复过一份别的 APP ID（124571480 那种），授权会一直对不上。
    static func resetToBuiltin() {
        for key in ["baidu_app_id", "baidu_api_key", "baidu_secret_key", "baidu_serials"] {
            defaults.removeObject(forKey: key)
        }
    }
}

/// 多角色朗读里的一条「角色 → 音色」规则
