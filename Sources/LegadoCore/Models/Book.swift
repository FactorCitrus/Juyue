import Foundation

// MARK: - Book

public struct Book: Codable, Identifiable, Equatable {
    public var id: String { bookUrl }

    public var bookUrl: String
    public var name: String
    public var author: String
    public var kind: String?
    public var coverUrl: String?
    public var intro: String?
    public var origin: String
    public var originName: String
    public var tocUrl: String
    public var wordCount: String?
    public var latestChapterTitle: String?

    // Reading progress
    public var durChapterTitle: String?
    public var durChapterIndex: Int
    public var durChapterPos: Int
    public var durChapterTime: Int64
    public var totalChapterNum: Int
    public var lastCheckTime: Int64

    public init(
        bookUrl: String,
        name: String,
        author: String,
        kind: String? = nil,
        coverUrl: String? = nil,
        intro: String? = nil,
        origin: String = "local",
        originName: String = "",
        tocUrl: String = "",
        wordCount: String? = nil,
        latestChapterTitle: String? = nil,
        durChapterTitle: String? = nil,
        durChapterIndex: Int = 0,
        durChapterPos: Int = 0,
        durChapterTime: Int64 = 0,
        totalChapterNum: Int = 0,
        lastCheckTime: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.bookUrl = bookUrl
        self.name = name
        self.author = author
        self.kind = kind
        self.coverUrl = coverUrl
        self.intro = intro
        self.origin = origin
        self.originName = originName
        self.tocUrl = tocUrl
        self.wordCount = wordCount
        self.latestChapterTitle = latestChapterTitle
        self.durChapterTitle = durChapterTitle
        self.durChapterIndex = durChapterIndex
        self.durChapterPos = durChapterPos
        self.durChapterTime = durChapterTime
        self.totalChapterNum = totalChapterNum
        self.lastCheckTime = lastCheckTime
    }

    enum CodingKeys: String, CodingKey {
        case bookUrl, name, author, kind, coverUrl, intro
        case origin, originName, tocUrl, wordCount, latestChapterTitle
        case durChapterTitle, durChapterIndex, durChapterPos, durChapterTime, totalChapterNum, lastCheckTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bookUrl = (try? container.decode(String.self, forKey: .bookUrl)) ?? ""
        self.name = (try? container.decode(String.self, forKey: .name)) ?? "未知书名"
        self.author = (try? container.decode(String.self, forKey: .author)) ?? "未知作者"
        self.kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        self.coverUrl = try? container.decodeIfPresent(String.self, forKey: .coverUrl)
        self.intro = try? container.decodeIfPresent(String.self, forKey: .intro)
        self.origin = (try? container.decode(String.self, forKey: .origin)) ?? "local"
        self.originName = (try? container.decode(String.self, forKey: .originName)) ?? ""
        self.tocUrl = (try? container.decode(String.self, forKey: .tocUrl)) ?? ""
        self.wordCount = try? container.decodeIfPresent(String.self, forKey: .wordCount)
        self.latestChapterTitle = try? container.decodeIfPresent(String.self, forKey: .latestChapterTitle)
        self.durChapterTitle = try? container.decodeIfPresent(String.self, forKey: .durChapterTitle)
        self.durChapterIndex = (try? container.decode(Int.self, forKey: .durChapterIndex)) ?? 0
        self.durChapterPos = (try? container.decode(Int.self, forKey: .durChapterPos)) ?? 0
        self.durChapterTime = (try? container.decode(Int64.self, forKey: .durChapterTime)) ?? 0
        self.totalChapterNum = (try? container.decode(Int.self, forKey: .totalChapterNum)) ?? 0
        self.lastCheckTime = (try? container.decode(Int64.self, forKey: .lastCheckTime)) ?? Int64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - BookProgress (Android Legado WebDAV Progress File)

public struct BookProgress: Codable, Equatable {
    public var name: String
    public var author: String
    public var durChapterIndex: Int
    public var durChapterPos: Int
    public var durChapterTime: Int64?
    public var durChapterTitle: String?

    public init(
        name: String,
        author: String,
        durChapterIndex: Int,
        durChapterPos: Int,
        durChapterTime: Int64? = nil,
        durChapterTitle: String? = nil
    ) {
        self.name = name
        self.author = author
        self.durChapterIndex = durChapterIndex
        self.durChapterPos = durChapterPos
        self.durChapterTime = durChapterTime
        self.durChapterTitle = durChapterTitle
    }
}

// MARK: - BookChapter

public struct BookChapter: Codable, Identifiable, Equatable {
    public var id: String { "\(bookUrl)_\(index)" }

    public var bookUrl: String
    public var url: String
    public var title: String
    public var index: Int
    public var isVip: Bool?
    public var tag: String?
    public var content: String?

    public init(
        bookUrl: String,
        url: String,
        title: String,
        index: Int,
        isVip: Bool? = false,
        tag: String? = nil,
        content: String? = nil
    ) {
        self.bookUrl = bookUrl
        self.url = url
        self.title = title
        self.index = index
        self.isVip = isVip
        self.tag = tag
        self.content = content
    }
}

// MARK: - SearchBook

public struct SearchBook: Codable, Identifiable, Equatable {
    public var id: String { "\(origin)_\(bookUrl)" }

    public var name: String
    public var author: String
    public var kind: String?
    public var bookUrl: String
    public var coverUrl: String?
    public var intro: String?
    public var latestChapterTitle: String?
    public var origin: String
    public var originName: String
    public var wordCount: String?

    public init(
        name: String,
        author: String,
        kind: String? = nil,
        bookUrl: String,
        coverUrl: String? = nil,
        intro: String? = nil,
        latestChapterTitle: String? = nil,
        origin: String,
        originName: String,
        wordCount: String? = nil
    ) {
        self.name = name
        self.author = author
        self.kind = kind
        self.bookUrl = bookUrl
        self.coverUrl = coverUrl
        self.intro = intro
        self.latestChapterTitle = latestChapterTitle
        self.origin = origin
        self.originName = originName
        self.wordCount = wordCount
    }
}
