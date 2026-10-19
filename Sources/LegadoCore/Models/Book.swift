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
    /// 书架分组（nil = 未分组）
    public var groupId: UUID?
    /// 书级变量：脚本用 `book.setVariable` 存的 JSON，聚合源拿它存这本书的自定义配置
    public var variable: String?
    /// 这本书用不用替换净化。nil = 跟随全局设置（安卓那边是 `book.readConfig.useReplaceRule`）
    public var useReplaceRule: Bool?
    /// 书架手动排序位次。nil = 仍按最近阅读时间排；拖拽换位后所有书都会写入序位。
    public var shelfOrder: Int?

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
        lastCheckTime: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        groupId: UUID? = nil,
        variable: String? = nil,
        useReplaceRule: Bool? = nil,
        shelfOrder: Int? = nil
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
        self.groupId = groupId
        self.variable = variable
        self.useReplaceRule = useReplaceRule
        self.shelfOrder = shelfOrder
    }

    enum CodingKeys: String, CodingKey {
        case bookUrl, name, author, kind, coverUrl, intro
        case origin, originName, tocUrl, wordCount, latestChapterTitle
        case durChapterTitle, durChapterIndex, durChapterPos, durChapterTime, totalChapterNum, lastCheckTime
        case groupId
        case variable, useReplaceRule, shelfOrder
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
        self.groupId = try? container.decodeIfPresent(UUID.self, forKey: .groupId)
        self.variable = try? container.decodeIfPresent(String.self, forKey: .variable)
        self.useReplaceRule = try? container.decodeIfPresent(Bool.self, forKey: .useReplaceRule)
        self.shelfOrder = try? container.decodeIfPresent(Int.self, forKey: .shelfOrder)
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


// MARK: - 书签 / 笔记
/// 一条书签：章节 + 位置 + 当时摘的句子，可以再写备注
public struct BookBookmark: Codable, Identifiable, Equatable {
    /// 标注类型：书签 / 下划线 / 底色（一条记录三种用途，复用同一份存储与列表）
    public enum Kind: String, Codable {
        case bookmark
        case underline
        case highlight
    }

    public var id: UUID
    public var bookUrl: String
    public var chapterIndex: Int
    public var chapterTitle: String
    public var charOffset: Int
    public var snippet: String
    public var note: String
    public var createdAt: Date
    /// 标注落在哪一段（阅读器的 ContentBlock.id）。书签用不上，留空。
    public var blockId: Int?
    /// 区间长度（字符数）。段落级标注就是整段长度，将来做句子级/逐字时用它。
    public var length: Int?
    /// 底色标注的颜色名（raw value 存字符串，方便跨版本）
    public var color: String?
    /// 标注范围单位："char" = 段内逐字；nil = 旧的整段（length 记行块数）
    public var rangeUnitRaw: String?
    /// nil 当书签处理，老数据不用迁移
    public var kindRaw: String?

    public var kind: Kind { Kind(rawValue: kindRaw ?? "") ?? .bookmark }

    public init(
        bookUrl: String,
        chapterIndex: Int,
        chapterTitle: String,
        charOffset: Int,
        snippet: String = "",
        note: String = "",
        blockId: Int? = nil,
        length: Int? = nil,
        color: String? = nil,
        rangeUnit: String? = nil,
        kind: Kind = .bookmark
    ) {
        self.id = UUID()
        self.bookUrl = bookUrl
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.charOffset = charOffset
        self.snippet = snippet
        self.note = note
        self.createdAt = Date()
        self.blockId = blockId
        self.length = length
        self.color = color
        self.rangeUnitRaw = rangeUnit
        self.kindRaw = kind.rawValue
    }

    /// 新增字段都按可选解，老数据（没有这些键）照样能读出来
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        self.bookUrl = (try? container.decode(String.self, forKey: .bookUrl)) ?? ""
        self.chapterIndex = (try? container.decode(Int.self, forKey: .chapterIndex)) ?? 0
        self.chapterTitle = (try? container.decode(String.self, forKey: .chapterTitle)) ?? ""
        self.charOffset = (try? container.decode(Int.self, forKey: .charOffset)) ?? 0
        self.snippet = (try? container.decode(String.self, forKey: .snippet)) ?? ""
        self.note = (try? container.decode(String.self, forKey: .note)) ?? ""
        self.createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        self.blockId = try? container.decodeIfPresent(Int.self, forKey: .blockId)
        self.length = try? container.decodeIfPresent(Int.self, forKey: .length)
        self.color = try? container.decodeIfPresent(String.self, forKey: .color)
        self.rangeUnitRaw = try? container.decodeIfPresent(String.self, forKey: .rangeUnitRaw)
        self.kindRaw = try? container.decodeIfPresent(String.self, forKey: .kindRaw)
    }
}
