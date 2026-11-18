import Foundation

/// `bookSourceUrl` / 渲染后请求地址的协议归类。
///
/// 阅读书源里有三种「不是普通网址」的写法，处理方式完全不同：
/// - `data:`：聚合源在本机打包参数，已经由 `NetworkClient.dataURLPayload` 消费；
/// - 纯标识（`书山聚合`、`光遇聚合`、`番茄，书旗`）：只是书源 id，真实地址由 jsLib 拼出；
/// - 自定义协议（`moyue://rapid`）：代表外部 App / 服务的协议，iOS 不能直接请求。
public enum BookSourceScheme: Equatable {
    case http
    case https
    case data
    /// 没有 scheme，但也不是空串。视为书源标识，不单独判错。
    case identifier
    /// 未知自定义 scheme，例如 `moyue://rapid`。
    case custom(String)
    /// 空串或只有空白。
    case invalid

    public var customName: String? {
        if case .custom(let name) = self { return name }
        return nil
    }
}

public enum BookSourceSchemeClassifier {
    private static let schemePattern = try? NSRegularExpression(
        pattern: "^([A-Za-z][A-Za-z0-9+.\\-]*):"
    )

    public static func classify(_ raw: String?) -> BookSourceScheme {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .invalid }
        if text.lowercased().hasPrefix("data:") { return .data }

        guard let regex = schemePattern,
              let match = regex.firstMatch(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length)
              ),
              match.numberOfRanges > 1 else {
            // 含空白的字符串不可能是网址，也不该被当成书源标识。
            return text.contains(where: \.isWhitespace) ? .invalid : .identifier
        }

        let name = (text as NSString).substring(with: match.range(at: 1)).lowercased()
        switch name {
        case "http": return .http
        case "https": return .https
        case "data": return .data
        default: return .custom(name)
        }
    }

    /// 渲染后的请求地址若用了自定义协议，返回协议名；http(s) / data / 普通标识返回 nil。
    public static func unsupportedRequestScheme(in address: String?) -> String? {
        classify(address).customName
    }

    /// 单行原因，给失败列表和诊断记录用。源名由调用方另行展示时不重复。
    public static func reason(for scheme: String) -> String {
        switch scheme.lowercased() {
        case "moyue":
            return "该源使用 moyue 协议，依赖墨阅聚合服务（局域网或外部 App），iOS 暂不支持"
        default:
            return "该源使用 \(scheme) 协议，iOS 暂不支持"
        }
    }

    public static func unsupportedMessage(scheme: String, sourceName: String) -> String {
        "「\(sourceName)」\(reason(for: scheme))"
    }

    /// 书源管理页的角标；只有真正不能直接请求的自定义协议才需要提示。
    public static func unsupportedBadge(for source: BookSource) -> String? {
        guard let scheme = unsupportedRequestScheme(in: source.bookSourceUrl) else { return nil }
        return "\(scheme) · iOS 不支持"
    }
}

/// 请求地址带自定义协议时抛出的可读错误。
/// 搜索换源会转成 `SearchSourceFailure.unsupportedScheme`，详情/正文直接展示 `errorDescription`。
public struct UnsupportedBookSourceSchemeError: LocalizedError, Equatable {
    public let scheme: String
    public let sourceName: String

    public init(scheme: String, sourceName: String) {
        self.scheme = scheme
        self.sourceName = sourceName
    }

    public var errorDescription: String? {
        BookSourceSchemeClassifier.unsupportedMessage(scheme: scheme, sourceName: sourceName)
    }
}
