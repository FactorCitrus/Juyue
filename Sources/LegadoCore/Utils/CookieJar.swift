import Foundation

/// 书源脚本用的 cookie 罐。
///
/// Legado 书源脚本里到处是 `cookie.getCookie(url)` / `cookie.setCookie(url, "k=v; k2=v2")`
/// / `cookie.getKey(url, name)` / `cookie.removeCookie(url)`。宿主不提供这套 API 时，
/// 脚本第一行就抛 ReferenceError，登录自然永远失败。
///
/// 存储按 host 归并成一条 cookie 串，落 UserDefaults，跟网页登录抓到的 cookie 分开管。
public final class CookieJar {
    public static let shared = CookieJar()

    private let defaultsKey = "legado.cookiejar"
    private let lock = NSLock()
    private var store: [String: String]

    /// 最近一次写入落在哪个 host 上。
    /// 有些书源（例：大灰狼聚合）的 `bookSourceUrl` 不是域名（写的是「大灰狼融合VIP5.0」），
    /// 登录脚本却把 cookie 写在真实 host 下；宿主判「登录成没成」时得知道写到哪儿去了，
    /// 否则明明登录成功、cookie 也存下来了，还是被判成「未返回有效凭据」。
    public private(set) var lastWrittenHostKey: String?

    /// 跑登录脚本前清一次，免得拿到上一次的残留。
    public func resetLastWrite() {
        lock.lock()
        defer { lock.unlock() }
        lastWrittenHostKey = nil
    }

    /// 只当 cookie 属性看，不当 cookie 名。
    private static let attributeNames: Set<String> = [
        "path", "domain", "expires", "max-age", "samesite", "secure", "httponly", "version"
    ]

    private init() {
        store = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    // MARK: - Host 归一

    /// 把 url 收敛成 host key。接受完整 URL、host、带 path 的 host。
    static func hostKey(for url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        if let range = text.range(of: "://") {
            text = String(text[range.upperBound...])
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        if let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        return text.lowercased()
    }

    // MARK: - 读写

    public func cookieString(for url: String) -> String {
        let key = Self.hostKey(for: url)
        guard !key.isEmpty else { return "" }
        lock.lock()
        defer { lock.unlock() }
        return store[key] ?? ""
    }

    /// 合并写入。带 Max-Age=0 的段按删除处理。
    public func setCookies(_ cookieString: String, for url: String) {
        let key = Self.hostKey(for: url)
        guard !key.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        lastWrittenHostKey = key

        var jar = Self.parse(store[key] ?? "")
        let incoming = cookieString.split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var expireAll = false
        for segment in incoming {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            let name = String(segment[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(segment[segment.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            if name.lowercased() == "max-age" {
                if value == "0" { expireAll = true }
                continue
            }
            if Self.attributeNames.contains(name.lowercased()) { continue }
            if value.isEmpty {
                jar.removeValue(forKey: name)
            } else {
                jar[name] = value
            }
        }
        if expireAll { jar.removeAll() }

        if jar.isEmpty {
            store.removeValue(forKey: key)
        } else {
            store[key] = Self.serialize(jar)
        }
        defaultsWrite()
    }

    public func value(for url: String, name: String) -> String? {
        let key = Self.hostKey(for: url)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return Self.parse(store[key] ?? "")[name]
    }

    public func remove(for url: String) {
        let key = Self.hostKey(for: url)
        guard !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: key)
        defaultsWrite()
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
        defaultsWrite()
    }

    // MARK: - 序列化

    static func parse(_ cookieString: String) -> [String: String] {
        var out: [String: String] = [:]
        for segment in cookieString.split(separator: ";", omittingEmptySubsequences: true) {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            if attributeNames.contains(name.lowercased()) { continue }
            out[name] = value
        }
        return out
    }

    static func serialize(_ jar: [String: String]) -> String {
        jar.keys.sorted().map { "\($0)=\(jar[$0] ?? "")" }.joined(separator: "; ")
    }

    private func defaultsWrite() {
        UserDefaults.standard.set(store, forKey: defaultsKey)
    }
}
