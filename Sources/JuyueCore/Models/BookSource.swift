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
        let box = try decoder.container(keyedBy: CodingKeys.self)

        // 书源 JSON 的字段类型经常不统一（数字写成字符串、布尔写成 0/1），
        // 统一走宽容取值：取不到就 nil，由各字段自己的默认值兜底。
        let text: (CodingKeys) -> String? = { try? box.decodeIfPresent(String.self, forKey: $0) }

        bookSourceUrl = text(.bookSourceUrl) ?? ""
        bookSourceName = text(.bookSourceName) ?? ""
        bookSourceGroup = text(.bookSourceGroup)
        bookSourceType = Self.lenientInt(box, .bookSourceType)
        bookUrlPattern = text(.bookUrlPattern)
        customOrder = Self.lenientInt(box, .customOrder)
        enabled = Self.lenientBool(box, .enabled)
        enabledExplore = Self.lenientBool(box, .enabledExplore)

        header = text(.header)
        loginUrl = text(.loginUrl)
        loginUi = text(.loginUi)
        loginCheckJs = text(.loginCheckJs)
        coverDecodeJs = text(.coverDecodeJs)
        bookSourceComment = text(.bookSourceComment)
        variableComment = text(.variableComment)

        lastUpdateTime = Self.lenientInt64(box, .lastUpdateTime)
        respondTime = Self.lenientInt64(box, .respondTime)
        weight = Self.lenientInt(box, .weight)
        exploreUrl = text(.exploreUrl)
        exploreScreen = text(.exploreScreen)
        searchUrl = text(.searchUrl)

        // 规则字段可能是对象也可能是字符串，交给 decodeRule 两种都试
        ruleExplore = decodeRule(ExploreRule.self, from: box, forKey: .ruleExplore)
        ruleSearch = decodeRule(SearchRule.self, from: box, forKey: .ruleSearch)
        ruleBookInfo = decodeRule(BookInfoRule.self, from: box, forKey: .ruleBookInfo)
        ruleToc = decodeRule(TocRule.self, from: box, forKey: .ruleToc)
        ruleContent = decodeRule(ContentRule.self, from: box, forKey: .ruleContent)
        ruleReview = decodeRule(ReviewRule.self, from: box, forKey: .ruleReview)

        loginInfo = text(.loginInfo)
        loginHeader = text(.loginHeader)
        variable = text(.variable)
        jsLib = text(.jsLib)
        eventListener = Self.lenientBool(box, .eventListener)
        customButton = Self.lenientBool(box, .customButton)
        enabledCookieJar = Self.lenientBool(box, .enabledCookieJar)
        concurrentRate = text(.concurrentRate)

        applyCompatibilityFixes()
    }

    /// 已导入书源里的已知脚本缺陷，在解码时就地修掉，避免详情页反复报
    /// `TypeError: undefined is not an object (evaluating 'abstract.split')`。
    ///
    /// 大灰狼 5.9.30 用 `String(value).length > 1` 判断简介，`undefined` 会被
    /// 转成字符串 `"undefined"`，长度 9，于是走进 `abstract.split`。
    public mutating func applyCompatibilityFixes() {
        guard var info = ruleBookInfo, var intro = info.intro else { return }
        let buggy = "let isValid = (value) => String(value).length > 1;"
        guard intro.contains(buggy) else { return }
        intro = intro.replacingOccurrences(
            of: buggy,
            with: "let isValid = (value) => value !== undefined && value !== null && String(value).length > 1;"
        )
        info.intro = intro
        ruleBookInfo = info
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
