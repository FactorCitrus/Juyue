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
        ruleContent: ContentRule? = nil
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
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bookSourceUrl = try container.decodeIfPresent(String.self, forKey: .bookSourceUrl) ?? ""
        self.bookSourceName = try container.decodeIfPresent(String.self, forKey: .bookSourceName) ?? ""
        self.bookSourceGroup = try container.decodeIfPresent(String.self, forKey: .bookSourceGroup)
        self.bookSourceType = try container.decodeIfPresent(Int.self, forKey: .bookSourceType)
        self.bookUrlPattern = try container.decodeIfPresent(String.self, forKey: .bookUrlPattern)
        self.customOrder = try container.decodeIfPresent(Int.self, forKey: .customOrder)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        self.enabledExplore = try container.decodeIfPresent(Bool.self, forKey: .enabledExplore)
        self.header = try container.decodeIfPresent(String.self, forKey: .header)
        self.loginUrl = try container.decodeIfPresent(String.self, forKey: .loginUrl)
        self.loginUi = try container.decodeIfPresent(String.self, forKey: .loginUi)
        self.loginCheckJs = try container.decodeIfPresent(String.self, forKey: .loginCheckJs)
        self.coverDecodeJs = try container.decodeIfPresent(String.self, forKey: .coverDecodeJs)
        self.bookSourceComment = try container.decodeIfPresent(String.self, forKey: .bookSourceComment)
        self.variableComment = try container.decodeIfPresent(String.self, forKey: .variableComment)
        self.lastUpdateTime = try container.decodeIfPresent(Int64.self, forKey: .lastUpdateTime)
        self.respondTime = try container.decodeIfPresent(Int64.self, forKey: .respondTime)
        self.weight = try container.decodeIfPresent(Int.self, forKey: .weight)
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
    }
}
