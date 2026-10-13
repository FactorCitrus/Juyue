import SwiftUI
import CoreText
import CoreGraphics

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
        candidates.filter { $0.isAvailable } + CustomFontService.shared.registered
    }

    static var `default`: ReaderFont {
        candidates.first!
    }

    static func font(named postScriptName: String) -> ReaderFont {
        (candidates.first { $0.postScriptName == postScriptName }
            ?? CustomFontService.shared.registered.first { $0.postScriptName == postScriptName })
            ?? `default`
    }

    /// 用户自己导进来的字体
    static var custom: [ReaderFont] {
        CustomFontService.shared.registered
    }
}

/// 自定义字体：导入的 ttf/otf 拷进 App 的 Documents/CustomFonts，
/// 启动时注册到进程，再从字体文件里读真实 PostScript 名。
///
/// 必须走 CFURL 注册这条路——只把文件放进目录是不会被 CoreText 认出来的。
public final class CustomFontService: ObservableObject {
    public static let shared = CustomFontService()

    @Published public private(set) var registered: [ReaderFont] = []
    /// 最近一次导入失败的原因，界面上要能看到，不然只知道「加不进去」
    @Published public private(set) var lastError: String?

    private let folderName = "CustomFonts"
    private let supportedExtensions: Set<String> = ["ttf", "otf", "ttc"]

    private var folderURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(folderName, isDirectory: true)
    }

    public init() {}

    /// 启动时调用：把目录里已有的字体全部注册一遍
    public func loadAll() {
        guard let folder = folderURL, let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ) else {
            registered = []
            return
        }
        var found: [ReaderFont] = []
        for file in files where supportedExtensions.contains(file.pathExtension.lowercased()) {
            if let font = register(file) { found.append(font) }
        }
        registered = found.sorted { $0.displayName < $1.displayName }
    }

    /// 导入一个字体文件，成功后返回可用字体
    @discardableResult
    public func importFont(from url: URL) -> ReaderFont? {
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        guard let folder = folderURL else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // 文件选择器给的 URL 出沙箱就失效，先取访问权再拷
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let dest = folder.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        var copied = (try? FileManager.default.copyItem(at: url, to: dest)) != nil
        if !copied {
            // 有些文件提供方（iCloud、第三方网盘）不支持跨域 copyItem，
            // 退回读字节再写一遍
            if let data = try? Data(contentsOf: url) {
                copied = (try? data.write(to: dest)) != nil
            }
        }
        guard copied else { return nil }
        guard let font = register(dest) else {
            // 没注册成功就把拷进来的文件删掉，免得每次启动都拿它再试一遍
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        if !registered.contains(where: { $0.postScriptName == font.postScriptName }) {
            registered.append(font)
            registered.sort { $0.displayName < $1.displayName }
        }
        return font
    }

    public func remove(_ font: ReaderFont) {
        guard let folder = folderURL else { return }
        registered.removeAll { $0.postScriptName == font.postScriptName }
        // 进程内注册过的字体没法反注册，删文件即可，下次启动就不会再加载
        if let file = font.sourceFileURL(inFolder: folder) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 注册单个字体文件并读出真实的 PostScript 名与显示名
    private func register(_ url: URL) -> ReaderFont? {
        var cfError: Unmanaged<CFError>?
        var ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError)
        if !ok {
            // 有些字体（CFF/变量字体/带集合的容器）走 URL 那条路注册不上，
            // 再用「图形字体」注册一次，iOS 上这条通常能过
            if let data = try? Data(contentsOf: url),
               let provider = CGDataProvider(data: data as CFData),
               let cgFont = CGFont(provider) {
                var gError: Unmanaged<CFError>?
                ok = CTFontManagerRegisterGraphicsFont(cgFont, &gError)
                if !ok { lastError = describe(gError ?? cfError) }
            } else {
                lastError = describe(cfError)
            }
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else {
            lastError = lastError ?? "读不出字体信息，可能不是有效的 ttf / otf / ttc"
            return nil
        }
        let font = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
        let postScriptName = CTFontCopyPostScriptName(font) as String
        let fullName = CTFontCopyFullName(font) as String
        let family = CTFontCopyFamilyName(font) as String
        guard !postScriptName.isEmpty else { return nil }
        // 注册成功与否不看返回值，看系统现在能不能按名字找到它；
        // 找不到的话后面渲染会静默回退成系统字体，用户只会觉得「字体没生效」
        guard ReaderFont.isFontAvailable(postScriptName) else {
            lastError = lastError ?? "字体没能注册进进程（\(postScriptName)）"
            return nil
        }
        // 和系统/内置清单里的字体同名的，导进来也不会有任何视觉变化，
        // 直接说清楚，别让用户以为导入成功了却没反应
        if let dup = ReaderFont.candidates.first(where: {
            $0.postScriptName.caseInsensitiveCompare(postScriptName) == .orderedSame && $0.isAvailable
        }) {
            lastError = "这个字体系统里本来就有（\(dup.displayName) / \(postScriptName)），导入不会改变显示"
            return nil
        }
        lastError = nil
        let display = fullName.isEmpty ? (family.isEmpty ? postScriptName : family) : fullName
        return ReaderFont(displayName: display, postScriptName: postScriptName)
    }

    private func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "系统没给原因" }
        let cf = error.takeRetainedValue() as Error
        return cf.localizedDescription
    }
}

private extension ReaderFont {
    /// 用 PostScript 名反查目录里的源文件，删字体时要用
    func sourceFileURL(inFolder folder: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return nil
        }
        for file in files {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first else { continue }
            let candidate = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
            if (CTFontCopyPostScriptName(candidate) as String) == postScriptName { return file }
        }
        return nil
    }
}
