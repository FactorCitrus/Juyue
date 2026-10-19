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
    public var ruleReview: ReviewRule?

    public var loginInfo: String?
    public var loginHeader: String?
    public var variable: String?

    /// 书源自带的 JS 助手库。聚合源把 `getArguments`、`setArgument`、加解密函数写在这里，
    /// 正文、搜索、登录脚本直接调，模型缺这个字段会导致脚本 ReferenceError。
    public var jsLib: String?
    /// 事件监听 / 自定义按钮 / 启用 CookieJar，对应安卓编辑器里的开关
    public var eventListener: Bool?
    public var customButton: Bool?
    public var enabledCookieJar: Bool?
    /// 并发率，形如 "1/1000"
    public var concurrentRate: String?

    public var isLogged: Bool {
        guard let h = loginHeader, !h.isEmpty else { return false }
        return true
    }

    /// 安卓 BookSourceType：0 文本、1 音频、2 图片、3 文件、4 视频。
    public enum Kind: Int, CaseIterable {
        case text = 0
        case audio = 1
        case image = 2
        case file = 3
        case video = 4

        public var label: String {
            switch self {
            case .text: return "文本"
            case .audio: return "音频"
            case .image: return "图片"
            case .file: return "文件"
            case .video: return "视频"
            }
        }
    }

    public var kind: Kind {
        Kind(rawValue: bookSourceType ?? 0) ?? .text
    }

    /// 选源排序：权重高的先试，权重相同按已知响应时间短的先试。
    /// 未测过响应时间的源排在已测过的后面，但仍可被选中。
    public static func selectionOrder(_ lhs: BookSource, _ rhs: BookSource) -> Bool {
        let lw = lhs.weight ?? 0
        let rw = rhs.weight ?? 0
        if lw != rw { return lw > rw }

        let lt = lhs.respondTime ?? Int64.max
        let rt = rhs.respondTime ?? Int64.max
        if lt != rt { return lt < rt }

        let lo = lhs.customOrder ?? 0
        let ro = rhs.customOrder ?? 0
        if lo != ro { return lo > ro }
        return lhs.bookSourceName.localizedStandardCompare(rhs.bookSourceName) == .orderedAscending
    }

    /// `bookUrlPattern` 是正则，安卓宿主用它判断某个网址是否属于这个书源。
    public func matchesBookUrl(_ url: String) -> Bool {
        let pattern = (bookUrlPattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty, !url.isEmpty else { return false }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: (url as NSString).length)
        return regex.firstMatch(in: url, range: range) != nil
    }

    /// `concurrentRate` 的 `n/windowMs` 形式。返回 nil 表示不限制。
    public var rateLimit: SourceRateLimit? {
        SourceRateLimit.parse(concurrentRate)
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
        case ruleReview
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
        ruleReview: ReviewRule? = nil,
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
        self.ruleReview = ruleReview
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
        self.ruleReview = decodeRule(ReviewRule.self, from: container, forKey: .ruleReview)

        self.loginInfo = try container.decodeIfPresent(String.self, forKey: .loginInfo)
        self.loginHeader = try container.decodeIfPresent(String.self, forKey: .loginHeader)
        self.variable = try container.decodeIfPresent(String.self, forKey: .variable)
        self.jsLib = try container.decodeIfPresent(String.self, forKey: .jsLib)
        self.eventListener = Self.lenientBool(container, .eventListener)
        self.customButton = Self.lenientBool(container, .customButton)
        self.enabledCookieJar = Self.lenientBool(container, .enabledCookieJar)
        self.concurrentRate = try container.decodeIfPresent(String.self, forKey: .concurrentRate)
    }

    /// 宽松取数。安卓导出的书源里同一字段类型会变：`lastUpdateTime` 有
    /// `1760000000000`、`"1760000000000"`、`"2026-10-11"` 三种，`enabled` 有
    /// `true`、`1`、`"true"`。严格 decode 撞上一条就整份解析失败，所以按宽松处理。
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
