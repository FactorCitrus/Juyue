import Foundation

/// 书源脚本可见的 Cookie 容器。
///
/// JS 桥接只依赖四个动作：按 URL 取串、写串、按名字取值、删除。
/// 内部按 host 保存键值对并编码成 JSON；旧版按 host 存字符串的格式会在启动时迁移一次。
public final class CookieJar {
    public static let shared = CookieJar()

    /// 最近一次写入落在哪个 host。
    /// 有的书源地址写的是别名而不是域名，登录脚本却把 cookie 写在真实 host 下，
    /// 调用方要能回查这次写入的位置。
    public private(set) var lastWrittenHostKey: String?

    private let defaults: UserDefaults
    private let storageKey: String
    private let legacyKey: String?
    private let lock = NSLock()
    private var hosts: [String: [String: String]]

    /// 这些名字是 Set-Cookie 的属性，不是 cookie 名。
    private static let attributeNames: Set<String> = [
        "path", "domain", "expires", "max-age", "samesite",
        "secure", "httponly", "version", "priority"
    ]

    private convenience init() {
        self.init(
            defaults: .standard,
            storageKey: "juyue.cookiejar.v2",
            legacyKey: "legado.cookiejar"
        )
    }

    /// 测试与迁移用入口。正式代码走 `shared`。
    init(defaults: UserDefaults, storageKey: String, legacyKey: String? = nil) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.legacyKey = legacyKey
        self.hosts = Self.load(defaults: defaults, storageKey: storageKey, legacyKey: legacyKey)
    }

    // MARK: - 写入与读取

    public func resetLastWrite() {
        lock.lock()
        lastWrittenHostKey = nil
        lock.unlock()
    }

    public func cookieString(for url: String) -> String {
        let host = Self.hostKey(for: url)
        guard !host.isEmpty else { return "" }
        lock.lock()
        let jar = hosts[host] ?? [:]
        lock.unlock()
        return Self.encode(jar)
    }

    public func setCookies(_ cookieString: String, for url: String) {
        let host = Self.hostKey(for: url)
        guard !host.isEmpty else { return }

        enum Change { case set(String), delete }
        var changes: [String: Change] = [:]
        var expiresEverything = false
        for raw in cookieString.split(separator: ";", omittingEmptySubsequences: true) {
            let segment = raw.trimmingCharacters(in: .whitespaces)
            guard let separator = segment.firstIndex(of: "=") else { continue }
            let name = String(segment[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(segment[segment.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            let lowered = name.lowercased()
            if lowered == "max-age" {
                if value == "0" { expiresEverything = true }
                continue
            }
            guard !Self.attributeNames.contains(lowered) else { continue }
            changes[name] = value.isEmpty ? .delete : .set(value)
        }

        lock.lock()
        defer { lock.unlock() }
        lastWrittenHostKey = host

        if expiresEverything {
            hosts.removeValue(forKey: host)
            persistLocked()
            return
        }
        guard !changes.isEmpty else { return }

        var jar = hosts[host] ?? [:]
        for (name, change) in changes {
            switch change {
            case .set(let value): jar[name] = value
            case .delete: jar.removeValue(forKey: name)
            }
        }
        if jar.isEmpty {
            hosts.removeValue(forKey: host)
        } else {
            hosts[host] = jar
        }
        persistLocked()
    }

    public func value(for url: String, name: String) -> String? {
        let host = Self.hostKey(for: url)
        guard !host.isEmpty else { return nil }
        lock.lock()
        let value = hosts[host]?[name]
        lock.unlock()
        return value
    }

    public func remove(for url: String) {
        let host = Self.hostKey(for: url)
        guard !host.isEmpty else { return }
        lock.lock()
        hosts.removeValue(forKey: host)
        persistLocked()
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        hosts.removeAll(keepingCapacity: false)
        lastWrittenHostKey = nil
        persistLocked()
        lock.unlock()
    }

    // MARK: - Host 归一

    /// 完整 URL、host、带端口的 host 都收敛成同一个 key。
    static func hostKey(for url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        }
        if let stop = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            text = String(text[..<stop])
        }
        if let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: text.startIndex)..<close])
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.lastIndex(of: ":") {
            text = String(text[..<colon])
        }
        return text.lowercased()
    }

    // MARK: - 编解码

    private static func encode(_ jar: [String: String]) -> String {
        jar.keys.sorted()
            .compactMap { name in jar[name].map { "\(name)=\($0)" } }
            .joined(separator: "; ")
    }

    private static func decode(_ raw: String) -> [String: String] {
        var jar: [String: String] = [:]
        for part in raw.split(separator: ";", omittingEmptySubsequences: true) {
            let segment = part.trimmingCharacters(in: .whitespaces)
            guard let separator = segment.firstIndex(of: "=") else { continue }
            let name = String(segment[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(segment[segment.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            guard !attributeNames.contains(name.lowercased()) else { continue }
            jar[name] = value
        }
        return jar
    }

    private static func load(defaults: UserDefaults,
                             storageKey: String,
                             legacyKey: String?) -> [String: [String: String]] {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            return decoded
        }
        guard let legacyKey,
              let legacy = defaults.dictionary(forKey: legacyKey) as? [String: String] else {
            return [:]
        }
        var migrated: [String: [String: String]] = [:]
        for (host, raw) in legacy {
            let jar = decode(raw)
            if !jar.isEmpty { migrated[host] = jar }
        }
        if !migrated.isEmpty, let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: storageKey)
        }
        defaults.removeObject(forKey: legacyKey)
        return migrated
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
