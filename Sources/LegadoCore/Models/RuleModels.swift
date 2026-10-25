import Foundation

// 书源规则 DTO。
//
// 这些结构体只干一件事：把书源 JSON 里的 `ruleSearch` / `ruleToc` 这类规则字段原样接住。
// 字段名由 legado 书源格式定义（`ruleSearch.name` 这种是落盘的键），换名字就读不出来，
// 所以字段集属于格式契约；能改的是组织方式、初始化方式和注释。

/// 规则字段可能是对象，也可能是「对象序列化成的字符串」——安卓导出的书源两种都有。
/// 两种都接不住就返回 nil，由调用方决定回落什么。
public func decodeRule<T: Decodable>(
    _ type: T.Type,
    from container: KeyedDecodingContainer<BookSource.CodingKeys>,
    forKey key: BookSource.CodingKeys
) -> T? {
    if let typed = try? container.decodeIfPresent(T.self, forKey: key) {
        return typed
    }
    let raw = try? container.decodeIfPresent(String.self, forKey: key)
    guard let text = raw, let blob = text.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: blob)
}

/// 搜索页：先取列表容器 `bookList`，再按字段各取一条表达式。
public struct SearchRule: Codable, Equatable {
    public var bookList: String?
    public var checkKeyWord: String?
    public var bookUrl: String?

    // 书目信息；解码与编码都按名字走，声明顺序随便
    public var name: String?
    public var author: String?
    public var coverUrl: String?
    public var intro: String?
    public var kind: String?
    public var wordCount: String?

    // 更新状态
    public var updateTime: String?
    public var lastChapter: String?

    public init() {}
}

/// 发现页：没有搜索关键词，其余字段跟搜索页同构。
public struct ExploreRule: Codable, Equatable {
    public var bookList: String?
    public var bookUrl: String?

    // 与搜索页同构，少一个关键词字段
    public var name: String?
    public var author: String?
    public var coverUrl: String?
    public var wordCount: String?
    public var intro: String?
    public var kind: String?
    public var updateTime: String?
    public var lastChapter: String?

    public init() {}
}

/// 目录页：分页、卷名、VIP 判定都在这里。
public struct TocRule: Codable, Equatable {
    // 章节条目：容器、标题、链接，`nextTocUrl` 管翻页
    public var chapterList: String?
    public var chapterName: String?
    public var nextTocUrl: String?
    public var chapterUrl: String?

    // 卷名、VIP、付费与更新时间；`preUpdateJs` 抓目录前先跑
    public var isVolume: String?
    public var isVip: String?
    public var formatJs: String?
    public var isPay: String?
    public var updateTime: String?
    public var preUpdateJs: String?

    public init() {}
}

/// 正文页：抓正文、清洗、翻页、图片处理、付费动作都在这里。
public struct ContentRule: Codable, Equatable {
    // 有的源把分页正文塞在 subContent，标题也可能落在正文页
    public var content: String?
    public var subContent: String?
    public var title: String?

    // 翻页与后处理：webJs 在 WebView 里跑，sourceRegex/replaceRegex 做清洗
    public var nextContentUrl: String?
    public var imageStyle: String?
    public var webJs: String?
    public var sourceRegex: String?
    public var imageDecode: String?
    public var replaceRegex: String?
    public var payAction: String?
    public var callBackJs: String?

    public init() {}
}

/// 详情页：一条预处理脚本加各字段的取值规则。
public struct BookInfoRule: Codable, Equatable {
    // 请求详情页之前先跑的预处理脚本（落盘的键名是 `init`）
    public var initRule: String?

    // 详情页字段规则
    public var name: String?
    public var author: String?

    // 封面与目录地址；有的源详情页不给，得从搜索结果回填
    public var coverUrl: String?
    public var intro: String?
    public var kind: String?
    public var tocUrl: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var wordCount: String?
    /// 允许详情页改名
    public var canReName: String?

    // 安卓导出的键是 `init`；不映射的话这条预处理规则会被整条丢掉。
    enum CodingKeys: String, CodingKey {
        case initRule = "init"
        case name, author, intro, kind
        case lastChapter, updateTime
        case coverUrl, tocUrl, wordCount, canReName
    }

    public init() {}
}

/// 本章说/段评里的热评：列表 + 单条内容两条规则就够。
public struct InlineHotReview: Codable, Equatable {
    public var urlRule: String?
    public var listRule: String?
    public var contentRule: String?

    public init() {}
}

/// 书评区：读、发、投票、删除四类动作，各有自己的网址规则。
public struct ReviewRule: Codable, Equatable {
    public var reviewUrl: String?
    public var avatarRule: String?
    public var contentRule: String?
    public var postTimeRule: String?
    public var inlineHotReview: InlineHotReview?
    public var reviewQuoteUrl: String?
    public var voteUpUrl: String?
    public var voteDownUrl: String?
    public var postReviewUrl: String?
    public var postQuoteUrl: String?
    public var deleteUrl: String?

    public init() {}
}
