import Foundation

// MARK: - Helper for Flexible Object-or-String Decoding

public func decodeRule<T: Decodable>(_ type: T.Type, from container: KeyedDecodingContainer<BookSource.CodingKeys>, forKey key: BookSource.CodingKeys) -> T? {
    if let object = try? container.decodeIfPresent(T.self, forKey: key) {
        return object
    }
    if let jsonString = try? container.decodeIfPresent(String.self, forKey: key),
       let data = jsonString.data(using: .utf8) {
        return try? JSONDecoder().decode(T.self, from: data)
    }
    return nil
}

// MARK: - SearchRule

public struct SearchRule: Codable, Equatable {
    public var checkKeyWord: String?
    public var bookList: String?
    public var name: String?
    public var author: String?
    public var intro: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var bookUrl: String?
    public var coverUrl: String?
    public var wordCount: String?

    public init(
        checkKeyWord: String? = nil,
        bookList: String? = nil,
        name: String? = nil,
        author: String? = nil,
        intro: String? = nil,
        kind: String? = nil,
        lastChapter: String? = nil,
        updateTime: String? = nil,
        bookUrl: String? = nil,
        coverUrl: String? = nil,
        wordCount: String? = nil
    ) {
        self.checkKeyWord = checkKeyWord
        self.bookList = bookList
        self.name = name
        self.author = author
        self.intro = intro
        self.kind = kind
        self.lastChapter = lastChapter
        self.updateTime = updateTime
        self.bookUrl = bookUrl
        self.coverUrl = coverUrl
        self.wordCount = wordCount
    }
}

// MARK: - ExploreRule

public struct ExploreRule: Codable, Equatable {
    public var bookList: String?
    public var name: String?
    public var author: String?
    public var intro: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var bookUrl: String?
    public var coverUrl: String?
    public var wordCount: String?

    public init(
        bookList: String? = nil,
        name: String? = nil,
        author: String? = nil,
        intro: String? = nil,
        kind: String? = nil,
        lastChapter: String? = nil,
        updateTime: String? = nil,
        bookUrl: String? = nil,
        coverUrl: String? = nil,
        wordCount: String? = nil
    ) {
        self.bookList = bookList
        self.name = name
        self.author = author
        self.intro = intro
        self.kind = kind
        self.lastChapter = lastChapter
        self.updateTime = updateTime
        self.bookUrl = bookUrl
        self.coverUrl = coverUrl
        self.wordCount = wordCount
    }
}

// MARK: - TocRule

public struct TocRule: Codable, Equatable {
    public var preUpdateJs: String?
    public var chapterList: String?
    public var chapterName: String?
    public var chapterUrl: String?
    public var formatJs: String?
    public var isVolume: String?
    public var isVip: String?
    public var isPay: String?
    public var updateTime: String?
    public var nextTocUrl: String?

    public init(
        preUpdateJs: String? = nil,
        chapterList: String? = nil,
        chapterName: String? = nil,
        chapterUrl: String? = nil,
        formatJs: String? = nil,
        isVolume: String? = nil,
        isVip: String? = nil,
        isPay: String? = nil,
        updateTime: String? = nil,
        nextTocUrl: String? = nil
    ) {
        self.preUpdateJs = preUpdateJs
        self.chapterList = chapterList
        self.chapterName = chapterName
        self.chapterUrl = chapterUrl
        self.formatJs = formatJs
        self.isVolume = isVolume
        self.isVip = isVip
        self.isPay = isPay
        self.updateTime = updateTime
        self.nextTocUrl = nextTocUrl
    }
}

// MARK: - ContentRule

public struct ContentRule: Codable, Equatable {
    public var content: String?
    public var title: String?
    public var subContent: String?
    public var nextContentUrl: String?
    public var webJs: String?
    public var sourceRegex: String?
    public var replaceRegex: String?
    public var imageStyle: String?
    public var imageDecode: String?
    public var payAction: String?
    public var callBackJs: String?

    public init(
        content: String? = nil,
        title: String? = nil,
        subContent: String? = nil,
        nextContentUrl: String? = nil,
        webJs: String? = nil,
        sourceRegex: String? = nil,
        replaceRegex: String? = nil,
        imageStyle: String? = nil,
        imageDecode: String? = nil,
        payAction: String? = nil,
        callBackJs: String? = nil
    ) {
        self.content = content
        self.title = title
        self.subContent = subContent
        self.nextContentUrl = nextContentUrl
        self.webJs = webJs
        self.sourceRegex = sourceRegex
        self.replaceRegex = replaceRegex
        self.imageStyle = imageStyle
        self.imageDecode = imageDecode
        self.payAction = payAction
        self.callBackJs = callBackJs
    }
}

// MARK: - BookInfoRule

public struct BookInfoRule: Codable, Equatable {
    public var initRule: String?
    public var name: String?
    public var author: String?
    public var intro: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var coverUrl: String?
    public var tocUrl: String?
    public var wordCount: String?
    /// 允许改名
    public var canReName: String?

    // 安卓导出的键是 `init`，不映射的话这条预处理规则会被整个丢掉
    enum CodingKeys: String, CodingKey {
        case initRule = "init"
        case name
        case author
        case intro
        case kind
        case lastChapter
        case updateTime
        case coverUrl
        case tocUrl
        case wordCount
        case canReName
    }

    public init(
        initRule: String? = nil,
        name: String? = nil,
        author: String? = nil,
        intro: String? = nil,
        kind: String? = nil,
        lastChapter: String? = nil,
        updateTime: String? = nil,
        coverUrl: String? = nil,
        tocUrl: String? = nil,
        wordCount: String? = nil,
        canReName: String? = nil
    ) {
        self.initRule = initRule
        self.name = name
        self.author = author
        self.intro = intro
        self.kind = kind
        self.lastChapter = lastChapter
        self.updateTime = updateTime
        self.coverUrl = coverUrl
        self.tocUrl = tocUrl
        self.wordCount = wordCount
        self.canReName = canReName
    }
}

// MARK: - ReviewRule（书评规则）

public struct InlineHotReview: Codable, Equatable {
    public var urlRule: String?
    public var listRule: String?
    public var contentRule: String?

    public init(urlRule: String? = nil, listRule: String? = nil, contentRule: String? = nil) {
        self.urlRule = urlRule
        self.listRule = listRule
        self.contentRule = contentRule
    }
}

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

    public init(
        reviewUrl: String? = nil,
        avatarRule: String? = nil,
        contentRule: String? = nil,
        postTimeRule: String? = nil,
        inlineHotReview: InlineHotReview? = nil,
        reviewQuoteUrl: String? = nil,
        voteUpUrl: String? = nil,
        voteDownUrl: String? = nil,
        postReviewUrl: String? = nil,
        postQuoteUrl: String? = nil,
        deleteUrl: String? = nil
    ) {
        self.reviewUrl = reviewUrl
        self.avatarRule = avatarRule
        self.contentRule = contentRule
        self.postTimeRule = postTimeRule
        self.inlineHotReview = inlineHotReview
        self.reviewQuoteUrl = reviewQuoteUrl
        self.voteUpUrl = voteUpUrl
        self.voteDownUrl = voteDownUrl
        self.postReviewUrl = postReviewUrl
        self.postQuoteUrl = postQuoteUrl
        self.deleteUrl = deleteUrl
    }
}
