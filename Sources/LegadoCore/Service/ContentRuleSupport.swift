import Foundation

// MARK: - 正文图片样式

/// `ContentRule.imageStyle` 的取值。
///
/// 安卓在正文排版阶段用它决定图片的显示尺寸，而不是往正文 HTML 里塞 style：
/// - `FULL`：铺满可视宽度；
/// - `TEXT`：小图，按行内小图处理；
/// - `SINGLE`：整页一张图，垂直居中；
/// - `LEFT` / `RIGHT`：按左 / 右对齐；
/// - 空值、`"0"` 和未知值都按默认样式：不超过原尺寸，居中。
public enum ContentImageStyle: String, Equatable, CaseIterable {
    case defaultStyle = "DEFAULT"
    case full = "FULL"
    case text = "TEXT"
    case single = "SINGLE"
    case left = "LEFT"
    case right = "RIGHT"

    public init(raw: String?) {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        switch value {
        case "FULL": self = .full
        case "TEXT": self = .text
        case "SINGLE": self = .single
        case "LEFT": self = .left
        case "RIGHT": self = .right
        default: self = .defaultStyle
        }
    }

    /// 图片在正文容器里的水平对齐方式。
    public var horizontalAlignment: ContentImageAlignment {
        switch self {
        case .left: return .leading
        case .right: return .trailing
        default: return .center
        }
    }
}

/// 与 SwiftUI 的 `HorizontalAlignment` 解耦，Core 层不依赖 SwiftUI。
public enum ContentImageAlignment: Equatable {
    case leading
    case center
    case trailing
}

// MARK: - sourceRegex

/// `ContentRule.sourceRegex`：安卓在 WebView 加载正文页时嗅探资源 URL，
/// 命中后把该 URL 当作正文响应体交给 `content` 规则。
///
/// 这里只负责匹配。真正的资源 URL 列表由 App 层的无声网页在导航完成后采集。
/// 语义与 `String.matches` 一致：正则必须覆盖整个 URL，非法正则会安全跳过。
public enum SourceURLSniffer {
    public static func firstMatch(in urls: [String], pattern: String?) -> String? {
        guard let pattern = pattern?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pattern.isEmpty else {
            return nil
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            LegadoLog.log("[Content] sourceRegex 非法，跳过：\(pattern)")
            return nil
        }

        for url in urls {
            let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let range = NSRange(location: 0, length: (value as NSString).length)
            // Java 的 matches() 要求整串匹配；firstMatch 允许子串，必须再比一次范围。
            if let match = regex.firstMatch(in: value, range: range), match.range == range {
                return value
            }
        }
        return nil
    }
}

// MARK: - imageDecode

/// `ContentRule.imageDecode`：安卓把图片原始 bytes 绑定到脚本变量 `result`、
/// 图片地址绑定到 `src`，脚本返回解密后的 bytes。
///
/// iOS 的 JavaScriptCore 没有 Java 的 `InputStream`，所以 `result` 以字节数组
/// （每个元素 0...255）传入；脚本必须返回同样形式的字节数组，其他返回类型一律
/// 视为失败，由调用方回退原图。脚本异常同样回退，不影响正文。
public enum ImageDecodeRule {
    public static func decode(
        _ data: Data,
        src: String,
        script: String?,
        source: BookSource?,
        baseUrl: String? = nil
    ) -> Data? {
        guard let script = script?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty,
              !data.isEmpty else {
            return nil
        }

        let engine = JSEngine(bookSource: source, baseUrl: baseUrl ?? src)
        engine.context.setObject(src, forKeyedSubscript: "src" as NSString)
        let input = data.map { Int($0) }
        let value = engine.eval(script: JSEngine.unwrapJsScript(script), result: input)

        if let error = engine.lastError {
            LegadoLog.log("[Content] imageDecode 脚本报错：\(error)")
            return nil
        }
        guard let bytes = bytes(from: value), !bytes.isEmpty else {
            return nil
        }
        return Data(bytes)
    }

    static func bytes(from value: Any?) -> [UInt8]? {
        guard let array = value as? [Any] else { return nil }
        var output = [UInt8]()
        output.reserveCapacity(array.count)
        for item in array {
            if let number = item as? NSNumber {
                output.append(UInt8(truncatingIfNeeded: number.intValue))
            } else if let number = item as? Int {
                output.append(UInt8(truncatingIfNeeded: number))
            } else {
                return nil
            }
        }
        return output
    }
}

// MARK: - callBackJs

/// `ContentRule.callBackJs`：安卓的事件回调，不是正文后处理。
///
/// 只有 `eventListener == true` 时才会执行，脚本里的 `event` 是事件名，
/// `book` / `chapter` / `result` 是事件上下文。返回值只表示按钮类事件是否继续
/// 默认动作，正文链路不会拿它替换或追加内容。
///
/// 橘阅目前只在开始 / 结束阅读时派发回调；书架增删和按钮类事件尚未接入。
public enum SourceEventCallback {
    public static let startRead = "startRead"
    public static let endRead = "endRead"

    @discardableResult
    public static func fire(
        event: String,
        source: BookSource?,
        book: Book?,
        chapter: BookChapter?
    ) -> Bool {
        guard let source, source.eventListener == true else { return false }
        guard let script = source.ruleContent?.callBackJs?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty else {
            return false
        }

        let engine = JSEngine(
            bookSource: source,
            baseUrl: chapter?.url ?? source.bookSourceUrl,
            book: book
        )
        engine.context.setObject(event, forKeyedSubscript: "event" as NSString)
        engine.context.setObject(NSNull(), forKeyedSubscript: "result" as NSString)

        var context: [String: Any] = [:]
        if let chapter {
            context["title"] = chapter.title
            context["url"] = chapter.url
            context["index"] = chapter.index
            context["isVip"] = chapter.isVip ?? false
        }
        engine.context.setObject(context, forKeyedSubscript: "chapter" as NSString)

        let value = engine.eval(script: JSEngine.unwrapJsScript(script))
        if let error = engine.lastError {
            LegadoLog.log("[Source] [\(source.bookSourceName)] callBackJs 事件 \(event) 报错：\(error)")
            return false
        }
        return isTruthy(value)
    }

    static func isTruthy(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text.lowercased() == "true" }
        return false
    }
}
