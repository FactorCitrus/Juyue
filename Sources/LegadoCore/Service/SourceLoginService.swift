import Foundation

public enum SourceLoginState: String {
    case notRequired
    case loggedIn
    case loggedOut
    case unknown

    public var label: String {
        switch self {
        case .notRequired: return "无需登录"
        case .loggedIn: return "已登录"
        case .loggedOut: return "未登录 / 已失效"
        case .unknown: return "无法确定"
        }
    }
}

public struct SourceLoginReport {
    public let state: SourceLoginState
    public let message: String

    public init(state: SourceLoginState, message: String = "") {
        self.state = state
        self.message = message
    }
}

public struct SourceLoginRequiredError: LocalizedError {
    public let sourceName: String

    public init(sourceName: String) {
        self.sourceName = sourceName
    }

    public var errorDescription: String? {
        "「\(sourceName)」的登录已失效，去书源详情里重新登录。"
    }
}

/// 统一登录态检测：搜索、发现、详情、正文在发请求前都走这里。
public final class SourceLoginService {
    public static let shared = SourceLoginService()

    private let lock = NSLock()
    private var cache: [String: (checkedAt: Date, report: SourceLoginReport)] = [:]
    private let cacheTTL: TimeInterval = 20

    public init() {}

    public func check(source: BookSource, force: Bool = false) async -> SourceLoginReport {
        let key = source.bookSourceUrl
        lock.lock()
        if !force, let cached = cache[key], Date().timeIntervalSince(cached.checkedAt) < cacheTTL {
            lock.unlock()
            return cached.report
        }
        lock.unlock()

        let report = evaluate(source: source)
        lock.lock()
        cache[key] = (Date(), report)
        lock.unlock()
        return report
    }

    /// 只有脚本明确返回「未登录」才拦截请求；脚本报错或无脚本时交给 HTTP 401/403 处理。
    public func requireLoginIfNeeded(source: BookSource) async throws {
        let hasScript = !(source.loginCheckJs ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasScript else { return }
        let report = await check(source: source)
        if report.state == .loggedOut {
            throw SourceLoginRequiredError(sourceName: source.bookSourceName)
        }
    }

    public func invalidate(sourceUrl: String) {
        lock.lock()
        cache.removeValue(forKey: sourceUrl)
        lock.unlock()
    }

    private func evaluate(source: BookSource) -> SourceLoginReport {
        let script = (source.loginCheckJs ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var cookie = CookieJar.shared.cookieString(for: source.bookSourceUrl)
        if cookie.isEmpty, let host = CookieJar.shared.lastWrittenHostKey, !host.isEmpty {
            cookie = CookieJar.shared.cookieString(for: host)
        }
        let hasStoredLogin = !(source.loginHeader ?? "").isEmpty || !cookie.isEmpty

        if script.isEmpty {
            let configured = !(source.loginUrl ?? "").isEmpty || !(source.loginUi ?? "").isEmpty
            if !configured {
                return SourceLoginReport(state: .notRequired, message: "这个源不用登录")
            }
            return SourceLoginReport(
                state: hasStoredLogin ? .loggedIn : .loggedOut,
                message: hasStoredLogin ? "已有登录信息" : "还没登录"
            )
        }

        let engine = JSEngine(bookSource: source, baseUrl: source.bookSourceUrl)
        let value = engine.eval(
            script: JSEngine.unwrapJsScript(script),
            result: source.loginHeader ?? ""
        )
        if let error = engine.lastError {
            return SourceLoginReport(state: .unknown, message: "登录检测出错：\(error)")
        }
        guard let value else {
            return SourceLoginReport(state: .unknown, message: "登录检测没有结果")
        }
        let loggedIn = Self.isTruthy(value)
        return SourceLoginReport(
            state: loggedIn ? .loggedIn : .loggedOut,
            message: loggedIn ? "登录检测通过" : "需要重新登录"
        )
    }

    private static func isTruthy(_ value: Any) -> Bool {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !(lower.isEmpty || lower == "false" || lower == "0"
                     || lower == "null" || lower == "undefined" || lower == "未登录")
        case let dict as [String: Any]: return !dict.isEmpty
        case let array as [Any]: return !array.isEmpty
        default: return true
        }
    }
}
