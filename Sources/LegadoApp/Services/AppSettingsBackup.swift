import Foundation

/// WebDAV 备份里的应用内设置（zip 根目录下的 `settings.json`）。
///
/// 只装「用户自己攒出来的东西」：阅读排版、替换净化规则、订阅源、多角色音色表。
/// 不带任何凭据——百度语音的 appId / apiKey / secretKey 一律不写进去。
/// 安卓版 Legado 读到不认识的条目会直接忽略，不影响它继续读 bookshelf.json / bookSource.json。
public struct AppSettingsPayload: Codable {
    /// 结构版本，日后加字段时靠它决定怎么迁移
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var readerLayout: ReaderConfig.LayoutSnapshot?
    public var replaceRules: [ReplaceRule]?
    public var sources: [BookSource]?
    public var ttsCastEnabled: Bool?
    public var ttsCastRoles: [TTSCastRole]?

    public init(
        schemaVersion: Int = AppSettingsPayload.currentSchemaVersion,
        readerLayout: ReaderConfig.LayoutSnapshot? = nil,
        replaceRules: [ReplaceRule]? = nil,
        sources: [BookSource]? = nil,
        ttsCastEnabled: Bool? = nil,
        ttsCastRoles: [TTSCastRole]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.readerLayout = readerLayout
        self.replaceRules = replaceRules
        self.sources = sources
        self.ttsCastEnabled = ttsCastEnabled
        self.ttsCastRoles = ttsCastRoles
    }
}

/// 恢复策略：合并保留现有，替换整体覆盖
public enum AppSettingsRestoreMode {
    case merge
    case replace
}

public enum AppSettingsBackup {
    /// 把当前设置打成 settings.json 的字节；编码失败就返回 nil（备份照常进行，只是不带设置）
    public static func makeJSON() -> Data? {
        let payload = AppSettingsPayload(
            readerLayout: ReaderConfig.shared.layoutSnapshot,
            replaceRules: ReplaceRuleStore.shared.rules,
            sources: BookStore.shared.sources,
            ttsCastEnabled: TTSCastStore.shared.enabled,
            ttsCastRoles: TTSCastStore.shared.roles
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        return try? encoder.encode(payload)
    }

    /// 解析 settings.json。schemaVersion 比当前新、或者结构对不上，都当读不出来处理
    public static func decode(_ data: Data) -> AppSettingsPayload? {
        guard let payload = try? JSONDecoder().decode(AppSettingsPayload.self, from: data) else { return nil }
        guard payload.schemaVersion <= AppSettingsPayload.currentSchemaVersion else { return nil }
        return payload
    }

    /// 应用一份设置，返回一句能直接显示给用户的摘要
    @discardableResult
    public static func apply(_ payload: AppSettingsPayload, mode: AppSettingsRestoreMode) -> String {
        var parts: [String] = []

        if let layout = payload.readerLayout {
            ReaderConfig.shared.apply(layout)
            parts.append("阅读排版")
        }

        if let rules = payload.replaceRules {
            switch mode {
            case .replace:
                ReplaceRuleStore.shared.rules = rules
            case .merge:
                var merged = ReplaceRuleStore.shared.rules
                for rule in rules where !merged.contains(where: { $0.id == rule.id }) {
                    merged.append(rule)
                }
                ReplaceRuleStore.shared.rules = merged
            }
            parts.append("替换规则 \(rules.count) 条")
        }

        if let sources = payload.sources {
            switch mode {
            case .replace:
                BookStore.shared.sources = sources
            case .merge:
                var merged = BookStore.shared.sources
                for source in sources where !merged.contains(where: { $0.bookSourceUrl == source.bookSourceUrl }) {
                    merged.append(source)
                }
                BookStore.shared.sources = merged
            }
            BookStore.shared.saveSources()
            parts.append("订阅源 \(sources.count) 个")
        }

        if let enabled = payload.ttsCastEnabled {
            TTSCastStore.shared.enabled = enabled
        }
        if let roles = payload.ttsCastRoles {
            switch mode {
            case .replace:
                TTSCastStore.shared.roles = roles
            case .merge:
                var merged = TTSCastStore.shared.roles
                for role in roles where !merged.contains(where: { $0.id == role.id }) {
                    merged.append(role)
                }
                TTSCastStore.shared.roles = merged
            }
            parts.append("多角色音色 \(roles.count) 个")
        }

        return parts.isEmpty ? "备份里没有可恢复的应用设置" : parts.joined(separator: "、")
    }
}
