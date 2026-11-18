import Foundation

/// 极简 JSON 路径求值。
/// 规格：`$` 可选；`a.b` 取键；`a[0]` / `a[-1]` 取下标；`a[0:2]` 取切片；
/// `a[*]` 展开数组；`$..key` 递归找第一个同名键；
/// `a[?(@.key == 'v')]` 过滤数组元素，支持 `==` `!=` `>` `<` `>=` `<=`、存在性判断
/// `[?(@.key)]`、布尔与 `&&` / `||` 组合；`@` 后可按 `.key` 取嵌套字段。
/// 任何一步落空返回 nil；过滤器无命中同样返回 nil（与 `[*]` 一致）。
public enum JSONPath {

    private enum Step: Equatable {
        case key(String)
        case index(Int)
        case slice(Int?, Int?)
        case anyIndex
        case filter(Filter)
        case descend
        case invalid
    }

    /// 外层数组是 `||`，内层数组是 `&&`。
    private struct Filter: Equatable {
        let groups: [[Condition]]

        func matches(_ element: Any) -> Bool {
            groups.contains { group in group.allSatisfy { $0.matches(element) } }
        }
    }

    private struct Condition: Equatable {
        let path: [String]
        let op: Op
        let literal: Literal?

        func matches(_ element: Any) -> Bool {
            guard let value = JSONPath.resolve(path, in: element) else { return false }
            if op == .exists { return !(value is NSNull) }
            guard let literal else { return false }
            let scalar = Scalar(value)
            switch op {
            case .exists:
                return true
            case .eq:
                return scalar.equals(literal)
            case .ne:
                return !scalar.equals(literal)
            case .gt, .lt, .ge, .le:
                guard let order = scalar.compare(with: literal) else { return false }
                switch op {
                case .gt: return order > 0
                case .lt: return order < 0
                case .ge: return order >= 0
                default: return order <= 0
                }
            }
        }
    }

    private enum Op: Equatable {
        case exists, eq, ne, gt, lt, ge, le
    }

    private enum Literal: Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
    }

    private enum Scalar {
        case number(Double)
        case string(String)
        case bool(Bool)
        case null
        case other

        init(_ value: Any) {
            if value is NSNull {
                self = .null
                return
            }
            // JSONSerialization 把数字和布尔都交给 NSNumber，靠 objCType 区分。
            if let number = value as? NSNumber {
                self = String(cString: number.objCType) == "c"
                    ? .bool(number.boolValue)
                    : .number(number.doubleValue)
                return
            }
            if let bool = value as? Bool {
                self = .bool(bool)
                return
            }
            if let text = value as? String {
                self = .string(text)
                return
            }
            self = .other
        }

        func equals(_ literal: Literal) -> Bool {
            switch (self, literal) {
            case (.null, .null): return true
            case (.null, _), (_, .null): return false
            case (.bool(let lhs), .bool(let rhs)): return lhs == rhs
            default: return compare(with: literal) == 0
            }
        }

        func compare(with literal: Literal) -> Int? {
            switch (self, literal) {
            case (.number(let lhs), .number(let rhs)):
                return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
            case (.string(let lhs), .string(let rhs)):
                return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
            case (.number(let lhs), .string(let rhs)):
                guard let rhs = Double(rhs) else { return nil }
                return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
            case (.string(let lhs), .number(let rhs)):
                guard let lhs = Double(lhs) else { return nil }
                return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
            default:
                return nil
            }
        }
    }

    public static func evaluate(path: String, json: Any) -> Any? {
        let body = stripRoot(path.trimmingCharacters(in: .whitespacesAndNewlines))
        let steps = compile(body)
        guard !steps.isEmpty else { return json }
        return run(steps[...], on: json)
    }

    private static func stripRoot(_ path: String) -> Substring {
        if path.hasPrefix("$.") { return path.dropFirst(2) }
        if path.hasPrefix("$") { return path.dropFirst(1) }
        return path[...]
    }

    // MARK: - 切分

    private static func compile(_ body: Substring) -> [Step] {
        guard !body.isEmpty else { return [] }
        return splitPath(body).flatMap(steps(for:))
    }

    /// 只在方括号与引号之外按 `.` 切段，过滤器里的 `@.title`、`'a.b'` 不会被切开。
    private static func splitPath(_ body: Substring) -> [Substring] {
        var out: [Substring] = []
        var start = body.startIndex
        var depth = 0
        var quote: Character?
        var escaped = false
        var index = start

        while index < body.endIndex {
            let char = body[index]
            if escaped {
                escaped = false
            } else if char == "\\", quote != nil {
                escaped = true
            } else if let open = quote {
                if char == open { quote = nil }
            } else if char == "'" || char == "\"" {
                quote = char
            } else if char == "[" {
                depth += 1
            } else if char == "]" {
                depth = max(0, depth - 1)
            } else if char == ".", depth == 0 {
                out.append(body[start..<index])
                start = body.index(after: index)
            }
            index = body.index(after: index)
        }
        out.append(body[start...])
        return out
    }

    private static func steps(for segment: Substring) -> [Step] {
        guard !segment.isEmpty else { return [.descend] }

        var out: [Step] = []
        var rest = segment
        if let bracket = rest.firstIndex(of: "[") {
            let head = rest[..<bracket]
            if !head.isEmpty { out.append(.key(String(head))) }
            rest = rest[bracket...]
        } else {
            return [.key(String(rest))]
        }

        while rest.first == "[", let close = matchingBracket(in: rest) {
            let inside = rest[rest.index(after: rest.startIndex)..<close]
                .trimmingCharacters(in: .whitespaces)
            out.append(step(forBracket: inside))
            rest = rest[rest.index(after: close)...]
            if let next = rest.first, next != "[" {
                let tail = next == "." ? rest.dropFirst() : rest
                if !tail.isEmpty { out.append(.key(String(tail))) }
                return out
            }
        }
        return out.isEmpty ? [.invalid] : out
    }

    /// `rest` 以 `[` 开头，返回与之配对的 `]`；跳过引号内的 `]`，允许嵌套。
    private static func matchingBracket(in rest: Substring) -> Substring.Index? {
        var depth = 0
        var quote: Character?
        var escaped = false
        var index = rest.startIndex

        while index < rest.endIndex {
            let char = rest[index]
            if escaped {
                escaped = false
            } else if char == "\\", quote != nil {
                escaped = true
            } else if let open = quote {
                if char == open { quote = nil }
            } else if char == "'" || char == "\"" {
                quote = char
            } else if char == "[" {
                depth += 1
            } else if char == "]" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = rest.index(after: index)
        }
        return nil
    }

    private static func step(forBracket inside: String) -> Step {
        if inside == "*" { return .anyIndex }
        if inside.hasPrefix("?") {
            return parseFilter(inside).map(Step.filter) ?? .invalid
        }
        if inside.contains(":") {
            let parts = inside.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return .invalid }
            return .slice(parts[0].isEmpty ? nil : Int(parts[0]),
                          parts[1].isEmpty ? nil : Int(parts[1]))
        }
        if let number = Int(inside) { return .index(number) }
        return .invalid
    }

    // MARK: - 过滤器解析

    private static func parseFilter(_ inside: String) -> Filter? {
        var text = inside.dropFirst().trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("(") {
            guard text.hasSuffix(")") else { return nil }
            text = String(text.dropFirst().dropLast())
        }

        var groups: [[Condition]] = []
        for orPart in split(text, by: "||") {
            var group: [Condition] = []
            for andPart in split(orPart, by: "&&") {
                guard let condition = parseCondition(andPart) else { return nil }
                group.append(condition)
            }
            guard !group.isEmpty else { return nil }
            groups.append(group)
        }
        return groups.isEmpty ? nil : Filter(groups: groups)
    }

    /// 在引号与括号之外按分隔符切分（分隔符为 `&&` / `||`）。
    private static func split(_ text: String, by separator: String) -> [String] {
        var out: [String] = []
        var start = text.startIndex
        var depth = 0
        var quote: Character?
        var escaped = false
        var index = start

        while index < text.endIndex {
            let char = text[index]
            if escaped {
                escaped = false
            } else if char == "\\", quote != nil {
                escaped = true
            } else if let open = quote {
                if char == open { quote = nil }
            } else if char == "'" || char == "\"" {
                quote = char
            } else if char == "(" || char == "[" {
                depth += 1
            } else if char == ")" || char == "]" {
                depth = max(0, depth - 1)
            } else if depth == 0, text[index...].hasPrefix(separator) {
                out.append(String(text[start..<index]))
                index = text.index(index, offsetBy: separator.count)
                start = index
                continue
            }
            index = text.index(after: index)
        }
        out.append(String(text[start...]))
        return out
    }

    private static func parseCondition(_ raw: String) -> Condition? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let (op, range) = comparison(in: text) {
            let lhs = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rhs = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard let path = keyPath(from: lhs), let literal = parseLiteral(rhs) else { return nil }
            return Condition(path: path, op: op, literal: literal)
        }
        guard let path = keyPath(from: text) else { return nil }
        return Condition(path: path, op: .exists, literal: nil)
    }

    private static func comparison(in text: String) -> (Op, Range<String.Index>)? {
        var quote: Character?
        var escaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let char = text[index]
            if escaped {
                escaped = false
            } else if char == "\\", quote != nil {
                escaped = true
            } else if let open = quote {
                if char == open { quote = nil }
            } else if char == "'" || char == "\"" {
                quote = char
            } else if "=!<>".contains(char) {
                let next = text.index(after: index)
                let second = next < text.endIndex ? text[next] : nil
                let end = second == "=" ? text.index(after: next) : next
                switch (char, second) {
                case ("=", "="): return (.eq, index..<end)
                case ("!", "="): return (.ne, index..<end)
                case (">", "="): return (.ge, index..<end)
                case ("<", "="): return (.le, index..<end)
                case (">", _): return (.gt, index..<end)
                case ("<", _): return (.lt, index..<end)
                default: return nil
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// `@` 或 `@.a.b` → 键路径；`@` 自身返回空数组。
    private static func keyPath(from text: String) -> [String]? {
        guard text.hasPrefix("@") else { return nil }
        let rest = text.dropFirst()
        if rest.isEmpty { return [] }
        guard rest.hasPrefix(".") else { return nil }
        let keys = rest.dropFirst()
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard !keys.isEmpty, keys.allSatisfy({ !$0.isEmpty }) else { return nil }
        return keys
    }

    private static func parseLiteral(_ text: String) -> Literal? {
        guard !text.isEmpty else { return nil }
        if text.count >= 2, let first = text.first, first == "'" || first == "\"", text.last == first {
            return .string(unescape(String(text.dropFirst().dropLast())))
        }
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if text == "null" { return .null }
        if let number = Double(text) { return .number(number) }
        return .string(text)
    }

    private static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        var escaped = false
        for char in text {
            if escaped {
                out.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else {
                out.append(char)
            }
        }
        return out
    }

    private static func resolve(_ path: [String], in element: Any) -> Any? {
        var node: Any? = element
        for key in path {
            guard let object = node as? [String: Any] else { return nil }
            node = object[key]
        }
        return node
    }

    // MARK: - 求值

    private static func run(_ steps: ArraySlice<Step>, on value: Any?) -> Any? {
        guard let value else { return nil }
        guard let step = steps.first else { return value }
        let tail = steps.dropFirst()

        switch step {
        case .key(let name):
            guard let object = value as? [String: Any] else { return nil }
            return run(tail, on: object[name])

        case .index(let position):
            guard let list = value as? [Any] else { return nil }
            let resolved = position < 0 ? list.count + position : position
            guard list.indices.contains(resolved) else { return nil }
            return run(tail, on: list[resolved])

        case .slice(let lower, let upper):
            guard let list = value as? [Any] else { return nil }
            let rawStart = lower ?? 0
            let rawEnd = upper ?? list.count
            let start = max(0, min(list.count, rawStart < 0 ? list.count + rawStart : rawStart))
            let end = max(start, min(list.count, rawEnd < 0 ? list.count + rawEnd : rawEnd))
            return run(tail, on: Array(list[start..<end]))

        case .anyIndex:
            guard let list = value as? [Any] else { return nil }
            var hits: [Any] = []
            for element in list {
                guard let hit = run(tail, on: element) else { continue }
                if let group = hit as? [Any] {
                    hits.append(contentsOf: group)
                } else {
                    hits.append(hit)
                }
            }
            return hits.isEmpty ? nil : hits

        case .filter(let filter):
            guard let list = value as? [Any] else { return nil }
            let matched = list.filter { filter.matches($0) }
            guard !matched.isEmpty else { return nil }
            if tail.isEmpty { return matched }
            var hits: [Any] = []
            for element in matched {
                guard let hit = run(tail, on: element) else { continue }
                if let group = hit as? [Any] {
                    hits.append(contentsOf: group)
                } else {
                    hits.append(hit)
                }
            }
            return hits.isEmpty ? nil : hits

        case .descend:
            guard case .key(let name)? = tail.first else { return value }
            // `$..key[*]` 要展开所有同名键下的元素；`$..key` 仍取第一个命中。
            if tail.dropFirst().first == .anyIndex {
                var hits: [Any] = []
                for child in allMatches(key: name, under: value) {
                    guard let hit = run(tail.dropFirst(), on: child) else { continue }
                    if let group = hit as? [Any] {
                        hits.append(contentsOf: group)
                    } else {
                        hits.append(hit)
                    }
                }
                return hits.isEmpty ? nil : hits
            }
            guard let found = firstMatch(key: name, under: value) else { return nil }
            return run(tail.dropFirst(), on: found)

        case .invalid:
            return nil
        }
    }

    private static func firstMatch(key: String, under value: Any) -> Any? {
        if let object = value as? [String: Any] {
            if let direct = object[key] { return direct }
            for child in object.values {
                if let hit = firstMatch(key: key, under: child) { return hit }
            }
        } else if let list = value as? [Any] {
            for child in list {
                if let hit = firstMatch(key: key, under: child) { return hit }
            }
        }
        return nil
    }

    private static func allMatches(key: String, under value: Any) -> [Any] {
        if let object = value as? [String: Any] {
            var hits: [Any] = []
            if let direct = object[key] { hits.append(direct) }
            for child in object.values {
                hits.append(contentsOf: allMatches(key: key, under: child))
            }
            return hits
        }
        if let list = value as? [Any] {
            return list.flatMap { allMatches(key: key, under: $0) }
        }
        return []
    }
}
