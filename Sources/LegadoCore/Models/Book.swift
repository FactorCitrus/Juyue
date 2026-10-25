import Foundation

/// 宽容取值：键缺失、类型不符、值是 null，一律当没给，由调用点回落默认值。
/// 书架数据是跨版本迁过来的，个别字段读不出来不该让整本书消失。
private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, for key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}

/// 书架上的一本书。`bookUrl` 是主键，本地书的 scheme 是 `local://`。
public struct Book: Codable, Identifiable, Equatable {
    public var id: String { bookUrl }

    // 身份与来源
    public var bookUrl: String
    public var name: String
    public var author: String

    // 来源：书源 id / 名称，本地书是 local
    public var origin: String
    public var originName: String
    public var tocUrl: String

    // 书目信息；tocUrl 归到这里，跟封面一样是可选抓取项
    public var coverUrl: String?
    public var intro: String?
    public var kind: String?
    public var wordCount: String?
    public var latestChapterTitle: String?

    // 阅读进度
    public var durChapterIndex: Int
    public var durChapterPos: Int
    public var durChapterTime: Int64
    public var durChapterTitle: String?
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
        // 书目信息，缺省留空
        kind: String? = nil,
        coverUrl: String? = nil,
        // 简介单独一行，长文本调试时好定位
        intro: String? = nil,

        // 来源：缺省当作本地书
        origin: String = "local",
        originName: String = "",
        // 目录地址；空串表示还没抓过
        tocUrl: String = "",
        wordCount: String? = nil,
        latestChapterTitle: String? = nil,
        // 进度：章节序号、段内位置、时间戳（毫秒）
        durChapterTitle: String? = nil,
        durChapterIndex: Int = 0,
        // 段内字符位置
        durChapterPos: Int = 0,
        // 最后一次阅读的墙钟时间
        durChapterTime: Int64 = 0,
        totalChapterNum: Int = 0,
        lastCheckTime: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        // 书架层配置
        groupId: UUID? = nil,
        variable: String? = nil,
        useReplaceRule: Bool? = nil,
        shelfOrder: Int? = nil
    ) {
        // 身份
        self.bookUrl = bookUrl
        self.name = name
        self.author = author
        // 来源
        self.origin = origin
        self.originName = originName
        self.tocUrl = tocUrl
        // 书目
        self.coverUrl = coverUrl
        self.intro = intro
        self.kind = kind
        self.wordCount = wordCount
        self.latestChapterTitle = latestChapterTitle
        // 进度
        self.durChapterIndex = durChapterIndex
        self.durChapterPos = durChapterPos
        self.durChapterTime = durChapterTime
        self.durChapterTitle = durChapterTitle
        self.totalChapterNum = totalChapterNum
        self.lastCheckTime = lastCheckTime
        // 书架层
        self.groupId = groupId
        self.variable = variable
        self.useReplaceRule = useReplaceRule
        self.shelfOrder = shelfOrder
    }

    enum CodingKeys: String, CodingKey {
        case bookUrl, name, author, origin, originName, tocUrl
        case coverUrl, intro, kind, wordCount, latestChapterTitle
        case durChapterIndex, durChapterPos, durChapterTime, durChapterTitle
        case totalChapterNum, lastCheckTime
        case groupId, variable, useReplaceRule, shelfOrder
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        bookUrl = box.lenient(String.self, for: .bookUrl) ?? ""
        name = box.lenient(String.self, for: .name) ?? "未知书名"
        author = box.lenient(String.self, for: .author) ?? "未知作者"
        origin = box.lenient(String.self, for: .origin) ?? "local"
        originName = box.lenient(String.self, for: .originName) ?? ""
        tocUrl = box.lenient(String.self, for: .tocUrl) ?? ""

        coverUrl = box.lenient(String.self, for: .coverUrl)
        intro = box.lenient(String.self, for: .intro)
        kind = box.lenient(String.self, for: .kind)
        wordCount = box.lenient(String.self, for: .wordCount)
        latestChapterTitle = box.lenient(String.self, for: .latestChapterTitle)

        durChapterIndex = box.lenient(Int.self, for: .durChapterIndex) ?? 0
        durChapterPos = box.lenient(Int.self, for: .durChapterPos) ?? 0
        durChapterTime = box.lenient(Int64.self, for: .durChapterTime) ?? 0
        durChapterTitle = box.lenient(String.self, for: .durChapterTitle)
        totalChapterNum = box.lenient(Int.self, for: .totalChapterNum) ?? 0
        lastCheckTime = box.lenient(Int64.self, for: .lastCheckTime)
            ?? Int64(Date().timeIntervalSince1970 * 1000)

        groupId = box.lenient(UUID.self, for: .groupId)
        variable = box.lenient(String.self, for: .variable)
        useReplaceRule = box.lenient(Bool.self, for: .useReplaceRule)
        shelfOrder = box.lenient(Int.self, for: .shelfOrder)
    }
}

/// WebDAV 同步用的进度文件格式，字段跟安卓版 legado 对齐。
public struct BookProgress: Codable, Equatable {
    public var name: String
    public var author: String

    // 进度：章节序号、段内位置、时间戳、章节标题
    public var durChapterIndex: Int
    public var durChapterPos: Int
    public var durChapterTime: Int64?
    public var durChapterTitle: String?

    public init(
        name: String,
        author: String,
        // 章节序号与段内位置都是必需字段，缺失按 0 处理由调用方决定
        durChapterIndex: Int,
        durChapterPos: Int,
        // 时间戳与章节标题是后加的，老进度文件里没有
        durChapterTime: Int64? = nil,
        durChapterTitle: String? = nil
    ) {
        self.durChapterIndex = durChapterIndex
        self.durChapterPos = durChapterPos
        self.name = name
        self.author = author
        self.durChapterTime = durChapterTime
        self.durChapterTitle = durChapterTitle
    }
}

/// 目录里的一章。`id` 由书 + 序号拼出来，换源后不会撞。
public struct BookChapter: Codable, Identifiable, Equatable {
    public var id: String { "\(bookUrl)_\(index)" }

    public var bookUrl: String
    public var url: String
    public var index: Int
    public var title: String

    // VIP 与卷标签；content 只在缓存回填时出现
    public var isVip: Bool?
    public var tag: String?
    public var content: String?

    public init(
        bookUrl: String,
        url: String,
        title: String,
        index: Int,

        // VIP 与卷标签由书源规则判定，缺省按普通章处理
        isVip: Bool? = false,
        tag: String? = nil,
        // 正文缓存回填时才有
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

/// 搜索结果里的一条，带来源标记，跟书架同名的书靠 `origin` 区分。
public struct SearchBook: Codable, Identifiable, Equatable {
    public var id: String { "\(origin)_\(bookUrl)" }

    public var name: String
    public var author: String
    public var bookUrl: String
    public var origin: String
    public var originName: String

    // 书目信息
    public var kind: String?
    public var coverUrl: String?
    public var intro: String?
    public var latestChapterTitle: String?

    // 字数，源里常带「万字」后缀，按原样存
    public var wordCount: String?

    public init(
        name: String,
        author: String,
        bookUrl: String,
        origin: String,
        originName: String,

        // 书目信息
        kind: String? = nil,
        coverUrl: String? = nil,
        intro: String? = nil,
        latestChapterTitle: String? = nil,

        // 字数，原样存
        wordCount: String? = nil
    ) {
        self.name = name
        self.author = author
        self.bookUrl = bookUrl
        self.origin = origin
        self.originName = originName
        self.kind = kind
        self.coverUrl = coverUrl
        self.intro = intro
        self.latestChapterTitle = latestChapterTitle
        self.wordCount = wordCount
    }
}

// MARK: - 书签 / 笔记

/// 一条标注：书签、下划线、底色三种用途共用一份存储与列表。
public struct BookBookmark: Codable, Identifiable, Equatable {
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

    /// 后加的字段一律按可选解，老数据没有这些键也能读
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = box.lenient(UUID.self, for: .id) ?? UUID()
        bookUrl = box.lenient(String.self, for: .bookUrl) ?? ""
        chapterIndex = box.lenient(Int.self, for: .chapterIndex) ?? 0
        chapterTitle = box.lenient(String.self, for: .chapterTitle) ?? ""
        charOffset = box.lenient(Int.self, for: .charOffset) ?? 0
        snippet = box.lenient(String.self, for: .snippet) ?? ""
        note = box.lenient(String.self, for: .note) ?? ""
        createdAt = box.lenient(Date.self, for: .createdAt) ?? Date()
        blockId = box.lenient(Int.self, for: .blockId)
        length = box.lenient(Int.self, for: .length)
        color = box.lenient(String.self, for: .color)
        rangeUnitRaw = box.lenient(String.self, for: .rangeUnitRaw)
        kindRaw = box.lenient(String.self, for: .kindRaw)
    }
}
