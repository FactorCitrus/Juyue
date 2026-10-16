import Foundation

public struct BookSource: Codable, Identifiable, Equatable {
    public var id: String { bookSourceUrl }

    public var bookSourceUrl: String
    public var bookSourceName: String
    public var bookSourceGroup: String?
    public var bookSourceType: Int?
    public var bookUrlPattern: String?
    public var customOrder: Int?
    public var enabled: Bool?
    public var enabledExplore: Bool?
    public var header: String?
    public var loginUrl: String?
    public var loginUi: String?
    public var loginCheckJs: String?
    public var coverDecodeJs: String?
    public var bookSourceComment: String?
    public var variableComment: String?
    public var lastUpdateTime: Int64?
    public var respondTime: Int64?
    public var weight: Int?
    public var exploreUrl: String?
    public var exploreScreen: String?
    public var searchUrl: String?

    public var ruleExplore: ExploreRule?
    public var ruleSearch: SearchRule?
    public var ruleBookInfo: BookInfoRule?
    public var ruleToc: TocRule?
    public var ruleContent: ContentRule?

    public var loginInfo: String?
    public var loginHeader: String?
    public var variable: String?

    /// 书源自带的 JS 助手库。
    ///
    /// 聚合源（大灰狼那一类）把 `getArguments` / `setArgument` / 一堆加解密函数全写在这里，
    /// 正文、搜索、登录脚本直接调。宿主不接这个字段的话，脚本第一行就
    /// `ReferenceError: Can't find variable: getArguments` —— 整份源等于废掉。
    public var jsLib: String?
    /// 事件监听 / 自定义按钮 / 启用 CookieJar：安卓编辑器里的开关，先收进来别丢
    public var eventListener: Bool?
    public var customButton: Bool?
    public var enabledCookieJar: Bool?
    /// 并发率，形如 "1/1000"
    public var concurrentRate: String?

    public var isLogged: Bool {
        guard let h = loginHeader, !h.isEmpty else { return false }
        return true
    }

    public enum CodingKeys: String, CodingKey {
        case bookSourceUrl
        case bookSourceName
        case bookSourceGroup
        case bookSourceType
        case bookUrlPattern
        case customOrder
        case enabled
        case enabledExplore
        case header
        case loginUrl
        case loginUi
        case loginCheckJs
        case coverDecodeJs
        case bookSourceComment
        case variableComment
        case lastUpdateTime
        case respondTime
        case weight
        case exploreUrl
        case exploreScreen
        case searchUrl
        case ruleExplore
        case ruleSearch
        case ruleBookInfo
        case ruleToc
        case ruleContent
        case loginInfo
        case loginHeader
        case variable
        case jsLib
        case eventListener
        case customButton
        case enabledCookieJar
        case concurrentRate
    }

    public init(
        bookSourceUrl: String,
        bookSourceName: String,
        bookSourceGroup: String? = nil,
        bookSourceType: Int? = 0,
        bookUrlPattern: String? = nil,
        customOrder: Int? = 0,
        enabled: Bool? = true,
        enabledExplore: Bool? = true,
        header: String? = nil,
        loginUrl: String? = nil,
        loginUi: String? = nil,
        loginCheckJs: String? = nil,
        coverDecodeJs: String? = nil,
        bookSourceComment: String? = nil,
        variableComment: String? = nil,
        lastUpdateTime: Int64? = nil,
        respondTime: Int64? = nil,
        weight: Int? = 0,
        exploreUrl: String? = nil,
        exploreScreen: String? = nil,
        searchUrl: String? = nil,
        ruleExplore: ExploreRule? = nil,
        ruleSearch: SearchRule? = nil,
        ruleBookInfo: BookInfoRule? = nil,
        ruleToc: TocRule? = nil,
        ruleContent: ContentRule? = nil,
        jsLib: String? = nil,
        eventListener: Bool? = nil,
        customButton: Bool? = nil,
        enabledCookieJar: Bool? = nil,
        concurrentRate: String? = nil
    ) {
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceName = bookSourceName
        self.bookSourceGroup = bookSourceGroup
        self.bookSourceType = bookSourceType
        self.bookUrlPattern = bookUrlPattern
        self.customOrder = customOrder
        self.enabled = enabled
        self.enabledExplore = enabledExplore
        self.header = header
        self.loginUrl = loginUrl
        self.loginUi = loginUi
        self.loginCheckJs = loginCheckJs
        self.coverDecodeJs = coverDecodeJs
        self.bookSourceComment = bookSourceComment
        self.variableComment = variableComment
        self.lastUpdateTime = lastUpdateTime
        self.respondTime = respondTime
        self.weight = weight
        self.exploreUrl = exploreUrl
        self.exploreScreen = exploreScreen
        self.searchUrl = searchUrl
        self.ruleExplore = ruleExplore
        self.ruleSearch = ruleSearch
        self.ruleBookInfo = ruleBookInfo
        self.ruleToc = ruleToc
        self.ruleContent = ruleContent
        self.jsLib = jsLib
        self.eventListener = eventListener
        self.customButton = customButton
        self.enabledCookieJar = enabledCookieJar
        self.concurrentRate = concurrentRate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bookSourceUrl = try container.decodeIfPresent(String.self, forKey: .bookSourceUrl) ?? ""
        self.bookSourceName = try container.decodeIfPresent(String.self, forKey: .bookSourceName) ?? ""
        self.bookSourceGroup = try container.decodeIfPresent(String.self, forKey: .bookSourceGroup)
        self.bookSourceType = Self.lenientInt(container, .bookSourceType)
        self.bookUrlPattern = try container.decodeIfPresent(String.self, forKey: .bookUrlPattern)
        self.customOrder = Self.lenientInt(container, .customOrder)
        self.enabled = Self.lenientBool(container, .enabled)
        self.enabledExplore = Self.lenientBool(container, .enabledExplore)
        self.header = try container.decodeIfPresent(String.self, forKey: .header)
        self.loginUrl = try container.decodeIfPresent(String.self, forKey: .loginUrl)
        self.loginUi = try container.decodeIfPresent(String.self, forKey: .loginUi)
        self.loginCheckJs = try container.decodeIfPresent(String.self, forKey: .loginCheckJs)
        self.coverDecodeJs = try container.decodeIfPresent(String.self, forKey: .coverDecodeJs)
        self.bookSourceComment = try container.decodeIfPresent(String.self, forKey: .bookSourceComment)
        self.variableComment = try container.decodeIfPresent(String.self, forKey: .variableComment)
        self.lastUpdateTime = Self.lenientInt64(container, .lastUpdateTime)
        self.respondTime = Self.lenientInt64(container, .respondTime)
        self.weight = Self.lenientInt(container, .weight)
        self.exploreUrl = try container.decodeIfPresent(String.self, forKey: .exploreUrl)
        self.exploreScreen = try container.decodeIfPresent(String.self, forKey: .exploreScreen)
        self.searchUrl = try container.decodeIfPresent(String.self, forKey: .searchUrl)

        self.ruleExplore = decodeRule(ExploreRule.self, from: container, forKey: .ruleExplore)
        self.ruleSearch = decodeRule(SearchRule.self, from: container, forKey: .ruleSearch)
        self.ruleBookInfo = decodeRule(BookInfoRule.self, from: container, forKey: .ruleBookInfo)
        self.ruleToc = decodeRule(TocRule.self, from: container, forKey: .ruleToc)
        self.ruleContent = decodeRule(ContentRule.self, from: container, forKey: .ruleContent)

        self.loginInfo = try container.decodeIfPresent(String.self, forKey: .loginInfo)
        self.loginHeader = try container.decodeIfPresent(String.self, forKey: .loginHeader)
        self.variable = try container.decodeIfPresent(String.self, forKey: .variable)
        self.jsLib = try container.decodeIfPresent(String.self, forKey: .jsLib)
        self.eventListener = Self.lenientBool(container, .eventListener)
        self.customButton = Self.lenientBool(container, .customButton)
        self.enabledCookieJar = Self.lenientBool(container, .enabledCookieJar)
        self.concurrentRate = try container.decodeIfPresent(String.self, forKey: .concurrentRate)
    }

    /// 宽松取数。
    ///
    /// 安卓导出的书源里，同一个字段在不同来源下类型会变：`lastUpdateTime` 有时是
    /// `1760000000000`，有时是 `"1760000000000"`，也有写 `"2026-10-11"` 的；
    /// `enabled` 有 `true`、`1`、`"true"` 三种写法。
    /// 严格 decode 只要撞上一条就把**整份文件**判成解析失败（558 条全废），所以这里全按宽松处理。
    private static func lenientInt64(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> Int64? {
        if let v = try? c.decode(Int64.self, forKey: k) { return v }
        if let d = try? c.decode(Double.self, forKey: k) { return Int64(d) }
        if let s = try? c.decode(String.self, forKey: k) { return Int64(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func lenientInt(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> Int? {
        if let v = try? c.decode(Int.self, forKey: k) { return v }
        if let d = try? c.decode(Double.self, forKey: k) { return Int(d) }
        if let s = try? c.decode(String.self, forKey: k) { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func lenientBool(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> Bool? {
        if let v = try? c.decode(Bool.self, forKey: k) { return v }
        if let i = try? c.decode(Int.self, forKey: k) { return i != 0 }
        if let s = try? c.decode(String.self, forKey: k) {
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }
}
