import Foundation

/// 极简 JSON 路径求值。
/// 规格：`$` 可选；`a.b` 取键；`a[0]` / `a[-1]` 取下标；`a[0:2]` 取切片；
/// `a[*]` 展开数组；`$..key` 递归找第一个同名键。任何一步落空返回 nil。
public enum JSONPath {

    private enum Step: Equatable {
        case key(String)
        case index(Int)
        case slice(Int?, Int?)
        case anyIndex
        case descend
        case invalid
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

    private static func compile(_ body: Substring) -> [Step] {
        guard !body.isEmpty else { return [] }
        return body.split(separator: ".", omittingEmptySubsequences: false).flatMap(steps(for:))
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

        while rest.first == "[", let close = rest.firstIndex(of: "]") {
            let inside = rest[rest.index(after: rest.startIndex)..<close]
                .trimmingCharacters(in: .whitespaces)
            out.append(step(forBracket: inside))
            rest = rest[rest.index(after: close)...]
            if let next = rest.first, next != "[" {
                out.append(.key(String(rest)))
                return out
            }
        }
        return out.isEmpty ? [.invalid] : out
    }

    private static func step(forBracket inside: String) -> Step {
        if inside == "*" { return .anyIndex }
        if inside.contains(":") {
            let parts = inside.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return .invalid }
            return .slice(parts[0].isEmpty ? nil : Int(parts[0]),
                          parts[1].isEmpty ? nil : Int(parts[1]))
        }
        if let number = Int(inside) { return .index(number) }
        return .invalid
    }

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

        case .descend:
            guard case .key(let name)? = tail.first else { return value }
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
}
