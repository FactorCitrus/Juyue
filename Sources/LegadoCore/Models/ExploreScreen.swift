import Foundation

public struct ExploreFilterOption: Identifiable, Hashable {
    public var id: String { "\(name)=\(value)" }
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// 书源 `exploreScreen` 里的一条筛选。
public struct ExploreFilter: Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    /// `select` 或 `text`
    public var type: String
    public var defaultValue: String
    public var options: [ExploreFilterOption]

    public init(name: String, type: String = "select", defaultValue: String = "", options: [ExploreFilterOption] = []) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.options = options
    }

    public var isSelect: Bool { !options.isEmpty || type.lowercased() == "select" }

    public var defaultValues: [String: String] {
        guard !name.isEmpty, !defaultValue.isEmpty else { return [:] }
        return [name: defaultValue]
    }
}

/// `exploreScreen` 解析。
public enum ExploreScreenParser {
    public static func parse(_ raw: String?) -> [ExploreFilter] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return []
        }
        guard let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { item in
            guard let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            let type = (item["type"] as? String) ?? "select"
            let value = stringValue(item["value"]) ?? ""

            var options: [ExploreFilterOption] = []
            if let rawOptions = item["options"] as? [Any] {
                for rawOption in rawOptions {
                    if let text = rawOption as? String {
                        options.append(ExploreFilterOption(name: text, value: text))
                    } else if let dict = rawOption as? [String: Any],
                              let optionName = stringValue(dict["name"]) ?? stringValue(dict["value"]) {
                        let optionValue = stringValue(dict["value"]) ?? optionName
                        options.append(ExploreFilterOption(name: optionName, value: optionValue))
                    }
                }
            }
            return ExploreFilter(name: name, type: type.lowercased(), defaultValue: value, options: options)
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let b as Bool: return b ? "true" : "false"
        default: return nil
        }
    }
}
