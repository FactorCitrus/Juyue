import SwiftUI
import CoreText

/// 可选正文字体。
///
/// 这里只列候选，真正显示前会用系统 API 查一遍是否存在，
/// 免得在不支持的设备上列出一堆点了没反应的字体。
public struct ReaderFont: Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let postScriptName: String
    public let boldPostScriptName: String?

    public init(displayName: String, postScriptName: String, boldPostScriptName: String? = nil) {
        self.id = postScriptName
        self.displayName = displayName
        self.postScriptName = postScriptName
        self.boldPostScriptName = boldPostScriptName
    }

    /// 字体在本机是否真的存在
    public var isAvailable: Bool {
        ReaderFont.isFontAvailable(postScriptName)
    }

    public static func isFontAvailable(_ name: String) -> Bool {
        guard let font = CTFontCreateWithName(name as CFString, 16, nil) as CTFont? else { return false }
        let resolved = CTFontCopyPostScriptName(font) as String
        // 找不到的字体，CoreText 会回退到默认字体，名字就对不上了
        return resolved.caseInsensitiveCompare(name) == .orderedSame
    }
}

public extension ReaderFont {
    /// 候选清单，按常用程度排
    static let candidates: [ReaderFont] = [
        ReaderFont(displayName: "系统默认（苹方）", postScriptName: "PingFangSC-Regular", boldPostScriptName: "PingFangSC-Semibold"),
        ReaderFont(displayName: "苹方 细体", postScriptName: "PingFangSC-Light", boldPostScriptName: "PingFangSC-Medium"),
        ReaderFont(displayName: "宋体", postScriptName: "STSongti-SC-Regular", boldPostScriptName: "STSongti-SC-Bold"),
        ReaderFont(displayName: "楷体", postScriptName: "STKaitiSC-Regular", boldPostScriptName: "STKaitiSC-Bold"),
        ReaderFont(displayName: "圆体", postScriptName: "STYuanti-SC-Regular", boldPostScriptName: "STYuanti-SC-Bold"),
        ReaderFont(displayName: "冬青黑体", postScriptName: "HiraginoSansGB-W3", boldPostScriptName: "HiraginoSansGB-W6"),
        ReaderFont(displayName: "黑体", postScriptName: "STHeitiSC-Light", boldPostScriptName: "STHeitiSC-Medium"),
        ReaderFont(displayName: "报宋", postScriptName: "STBaoliSC-Regular"),
        ReaderFont(displayName: "华文新魏", postScriptName: "STXinwei", boldPostScriptName: nil),
        ReaderFont(displayName: "华文行楷", postScriptName: "STXingkai", boldPostScriptName: nil),
        ReaderFont(displayName: "Times New Roman", postScriptName: "TimesNewRomanPSMT", boldPostScriptName: "TimesNewRomanPS-BoldMT"),
        ReaderFont(displayName: "Georgia", postScriptName: "Georgia", boldPostScriptName: "Georgia-Bold"),
        ReaderFont(displayName: "Menlo", postScriptName: "Menlo-Regular", boldPostScriptName: "Menlo-Bold"),
        ReaderFont(displayName: "Courier New", postScriptName: "CourierNewPSMT", boldPostScriptName: "CourierNewPS-BoldMT")
    ]

    /// 本机装了的那些
    static var available: [ReaderFont] {
        candidates.filter { $0.isAvailable }
    }

    static var `default`: ReaderFont {
        candidates.first!
    }

    static func font(named postScriptName: String) -> ReaderFont {
        candidates.first { $0.postScriptName == postScriptName } ?? `default`
    }
}
