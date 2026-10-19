import Foundation
#if canImport(LegadoCore)
import LegadoCore
#endif

/// WebDAV 备份里的应用内设置（zip 根目录下的 `settings.json`）。
///
/// 只装「用户自己攒出来的东西」：阅读排版、书架外观、外观主题、替换净化规则、
/// 书源、朗读设置、多角色音色表。独立设置备份默认还会去掉书源登录态。
/// 不含凭据：百度语音的 appId / apiKey / secretKey 一律不写入。
/// 安卓版 Legado 读到不认识的条目会直接忽略，不影响它继续读 bookshelf.json / bookSource.json。
public struct AppSettingsPayload: Codable {
    /// 结构版本，日后加字段时靠它决定怎么迁移
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var readerLayout: ReaderConfig.LayoutSnapshot?
    public var replaceRules: [ReplaceRule]?
    public var sources: [BookSource]?
    public var ttsCastEnabled: Bool?
    public var ttsCastRoles: [TTSCastRole]?
    /// 设置 → 外观 → 外观模式（system / light / dark）
    public var appearanceMode: String?
    /// 标准 / 月面终端
    public var themeChoice: String?
    public var bookshelf: BookshelfSettingsSnapshot?
    public var tts: TTSSettingsSnapshot?

    public init(
        schemaVersion: Int = AppSettingsPayload.currentSchemaVersion,
        readerLayout: ReaderConfig.LayoutSnapshot? = nil,
        replaceRules: [ReplaceRule]? = nil,
        sources: [BookSource]? = nil,
        ttsCastEnabled: Bool? = nil,
        ttsCastRoles: [TTSCastRole]? = nil,
        appearanceMode: String? = nil,
        themeChoice: String? = nil,
        bookshelf: BookshelfSettingsSnapshot? = nil,
        tts: TTSSettingsSnapshot? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.readerLayout = readerLayout
        self.replaceRules = replaceRules
        self.sources = sources
        self.ttsCastEnabled = ttsCastEnabled
        self.ttsCastRoles = ttsCastRoles
        self.appearanceMode = appearanceMode
        self.themeChoice = themeChoice
        self.bookshelf = bookshelf
        self.tts = tts
    }
}

public struct BookshelfSettingsSnapshot: Codable, Equatable {
    public var layout: String
    public var gridColumns: Int
    public var cardScale: Double
    public var badgeStyle: String
    public var badgeCap: Int
    public var badgeColorHex: String
    public var badgeCorner: String
    public var badgeFontSize: Double
    public var badgeOutline: Bool
    public var badgeOffset: Double

    public init(
        layout: String,
        gridColumns: Int,
        cardScale: Double,
        badgeStyle: String,
        badgeCap: Int,
        badgeColorHex: String,
        badgeCorner: String,
        badgeFontSize: Double,
        badgeOutline: Bool,
        badgeOffset: Double
    ) {
        self.layout = layout
        self.gridColumns = gridColumns
        self.cardScale = cardScale
        self.badgeStyle = badgeStyle
        self.badgeCap = badgeCap
        self.badgeColorHex = badgeColorHex
        self.badgeCorner = badgeCorner
        self.badgeFontSize = badgeFontSize
        self.badgeOutline = badgeOutline
        self.badgeOffset = badgeOffset
    }
}

public struct TTSSettingsSnapshot: Codable, Equatable {
    public var speechRate: Double
    public var chunkLength: Int
    public var systemVoiceIdentifier: String?
    public var activeSourceId: Int64?
    public var castEnabled: Bool
    public var castRoles: [TTSCastRole]

    public init(
        speechRate: Double,
        chunkLength: Int,
        systemVoiceIdentifier: String?,
        activeSourceId: Int64?,
        castEnabled: Bool,
        castRoles: [TTSCastRole]
    ) {
        self.speechRate = speechRate
        self.chunkLength = chunkLength
        self.systemVoiceIdentifier = systemVoiceIdentifier
        self.activeSourceId = activeSourceId
        self.castEnabled = castEnabled
        self.castRoles = castRoles
    }
}

/// 恢复策略：合并保留现有，替换整体覆盖
public enum AppSettingsRestoreMode: Hashable {
    case merge
    case replace
}

public enum AppSettingsBackup {
    /// 当前运行时设置快照，供导出与预览共用。
    public static func makePayload(sanitizeCredentials: Bool = false) -> AppSettingsPayload {
        var sources = BookStore.shared.sources
        if sanitizeCredentials {
            sources = sources.map { source in
                var cleaned = source
                cleaned.loginHeader = nil
                cleaned.loginInfo = nil
                cleaned.variable = nil
                return cleaned
            }
        }
        return AppSettingsPayload(
            readerLayout: ReaderConfig.shared.layoutSnapshot,
            replaceRules: ReplaceRuleStore.shared.rules,
            sources: sources,
            ttsCastEnabled: TTSCastStore.shared.enabled,
            ttsCastRoles: TTSCastStore.shared.roles,
            appearanceMode: UserDefaults.standard.string(forKey: "legado_app_theme") ?? "system",
            themeChoice: AppThemeManager.shared.choice.rawValue,
            bookshelf: BookshelfSettingsSnapshot(
                layout: BookshelfConfig.shared.layout.rawValue,
                gridColumns: BookshelfConfig.shared.gridColumns,
                cardScale: Double(BookshelfConfig.shared.cardScale),
                badgeStyle: BookshelfConfig.shared.badgeStyle.rawValue,
                badgeCap: BookshelfConfig.shared.badgeCap,
                badgeColorHex: BookshelfConfig.shared.badgeColorHex,
                badgeCorner: BookshelfConfig.shared.badgeCorner.rawValue,
                badgeFontSize: Double(BookshelfConfig.shared.badgeFontSize),
                badgeOutline: BookshelfConfig.shared.badgeOutline,
                badgeOffset: Double(BookshelfConfig.shared.badgeOffset)
            ),
            tts: TTSSettingsSnapshot(
                speechRate: Double(AudioBookService.shared.speechRate),
                chunkLength: AudioBookService.shared.chunkLength,
                systemVoiceIdentifier: SystemVoiceSelection.identifier,
                activeSourceId: TTSourceSelection.activeId,
                castEnabled: TTSCastStore.shared.enabled,
                castRoles: TTSCastStore.shared.roles
            )
        )
    }

    /// 把当前设置打成 settings.json 的字节；编码失败就返回 nil（备份照常进行，只是不带设置）
    public static func makeJSON(sanitizeCredentials: Bool = false) -> Data? {
        let payload = makePayload(sanitizeCredentials: sanitizeCredentials)
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

        if let appearance = payload.appearanceMode, !appearance.isEmpty {
            UserDefaults.standard.set(appearance, forKey: "legado_app_theme")
            parts.append("外观模式")
        }
        if let themeChoice = payload.themeChoice,
           let choice = AppThemeChoice(rawValue: themeChoice) {
            AppThemeManager.shared.choice = choice
            parts.append("主题")
        }
        if let shelf = payload.bookshelf {
            let config = BookshelfConfig.shared
            if let layout = BookshelfLayoutStyle(rawValue: shelf.layout) { config.layout = layout }
            config.gridColumns = min(4, max(2, shelf.gridColumns))
            config.cardScale = min(1.40, max(0.40, CGFloat(shelf.cardScale)))
            if let style = BookshelfBadgeStyle(rawValue: shelf.badgeStyle) { config.badgeStyle = style }
            config.badgeCap = max(0, shelf.badgeCap)
            config.badgeColorHex = shelf.badgeColorHex
            if let corner = BookshelfBadgeCorner(rawValue: shelf.badgeCorner) { config.badgeCorner = corner }
            config.badgeFontSize = CGFloat(min(16, max(7, shelf.badgeFontSize)))
            config.badgeOutline = shelf.badgeOutline
            config.badgeOffset = CGFloat(min(16, max(0, shelf.badgeOffset)))
            parts.append("书架外观")
        }
        if let tts = payload.tts {
            AudioBookService.shared.speechRate = Float(tts.speechRate)
            AudioBookService.shared.chunkLength = max(1, tts.chunkLength)
            SystemVoiceSelection.identifier = tts.systemVoiceIdentifier
            TTSourceSelection.activeId = tts.activeSourceId
            TTSCastStore.shared.enabled = tts.castEnabled
            switch mode {
            case .replace:
                TTSCastStore.shared.roles = tts.castRoles
            case .merge:
                var merged = TTSCastStore.shared.roles
                for role in tts.castRoles where !merged.contains(where: { $0.id == role.id }) {
                    merged.append(role)
                }
                TTSCastStore.shared.roles = merged
            }
            parts.append("朗读设置")
        }

        return parts.isEmpty ? "备份里没有能恢复的设置" : parts.joined(separator: "、")
    }
}
