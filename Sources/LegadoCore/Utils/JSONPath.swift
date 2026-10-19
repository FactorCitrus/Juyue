import Foundation

public enum JSONPath {

    public static func evaluate(path: String, json: Any) -> Any? {
        var cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanPath.starts(with: "$.") {
            cleanPath = String(cleanPath.dropFirst(2))
        } else if cleanPath.starts(with: "$") {
            cleanPath = String(cleanPath.dropFirst(1))
        }
        if cleanPath.isEmpty { return json }

        // Fast path for recursive descent such as `$..items[*]` (cleanPath is `.items[*]`).
        if cleanPath.hasPrefix(".") {
            let remainder = String(cleanPath.dropFirst())
            let key = String(remainder.prefix { $0 != "[" && $0 != "." })
            if !key.isEmpty, let found = findKeyRecursively(key: key, current: json) {
                let suffix = String(remainder.dropFirst(key.count))
                let suffixTokens = tokenize(suffix)
                return traverse(tokens: suffixTokens, current: found)
            }
        }

        // Tokenize path into keys and array indices: e.g. "content.items[0].title" or "list[*]"
        let tokens = tokenize(cleanPath)
        return traverse(tokens: tokens, current: json)
    }

    private static func tokenize(_ path: String) -> [String] {
        var tokens: [String] = []
        let parts = path.components(separatedBy: ".")
        for part in parts {
            var current = part
            while let openBracket = current.firstIndex(of: "["),
                  let closeBracket = current.firstIndex(of: "]"),
                  openBracket < closeBracket {
                let key = String(current[..<openBracket])
                if !key.isEmpty {
                    tokens.append(key)
                }
                let indexPart = String(current[current.index(after: openBracket)..<closeBracket])
                tokens.append("[\(indexPart)]")
                current = String(current[current.index(after: closeBracket)...])
            }
            if !current.isEmpty {
                tokens.append(current)
            }
        }
        return tokens
    }

    private static func traverse(tokens: [String], current: Any?) -> Any? {
        guard let current = current else { return nil }
        if tokens.isEmpty { return current }

        let token = tokens[0]
        let remaining = Array(tokens.dropFirst())

        // Handle recursive descent: $..key (token is empty)
        if token.isEmpty {
            guard let nextToken = remaining.first else { return current }
            let restAfterNext = Array(remaining.dropFirst())
            let nextTokens = tokenize(nextToken)
            guard let key = nextTokens.first else { return nil }
            if let found = findKeyRecursively(key: key, current: current) {
                return traverse(tokens: Array(nextTokens.dropFirst()) + restAfterNext, current: found)
            }
            return nil
        }

        if token.starts(with: "[") && token.hasSuffix("]") {
            let indexContent = String(token.dropFirst().dropLast())
            if indexContent == "*" {
                // Wildcard match across array
                if let array = current as? [Any] {
                    var collected: [Any] = []
                    for item in array {
                        if let subResult = traverse(tokens: remaining, current: item) {
                            if let subArray = subResult as? [Any] {
                                collected.append(contentsOf: subArray)
                            } else {
                                collected.append(subResult)
                            }
                        }
                    }
                    return collected.isEmpty ? nil : collected
                }
            } else if indexContent.contains(":") {
                let parts = indexContent.split(separator: ":", omittingEmptySubsequences: false)
                if parts.count == 2, let array = current as? [Any] {
                    let lower = parts[0].isEmpty ? 0 : (Int(parts[0]) ?? 0)
                    let upper = parts[1].isEmpty ? array.count : (Int(parts[1]) ?? array.count)
                    let start = max(0, min(array.count, lower < 0 ? array.count + lower : lower))
                    let end = max(start, min(array.count, upper < 0 ? array.count + upper : upper))
                    let slice = Array(array[start..<end])
                    return traverse(tokens: remaining, current: slice)
                }
            } else if let index = Int(indexContent) {
                if let array = current as? [Any] {
                    let actualIndex = index < 0 ? array.count + index : index
                    if actualIndex >= 0 && actualIndex < array.count {
                        return traverse(tokens: remaining, current: array[actualIndex])
                    }
                }
            }
            return nil
        }

        if let dict = current as? [String: Any] {
            return traverse(tokens: remaining, current: dict[token])
        }

        return nil
    }

    private static func findKeyRecursively(key: String, current: Any?) -> Any? {
        guard let current = current else { return nil }
        if let dict = current as? [String: Any] {
            if let val = dict[key] {
                return val
            }
            for (_, v) in dict {
                if let found = findKeyRecursively(key: key, current: v) {
                    return found
                }
            }
        } else if let array = current as? [Any] {
            for item in array {
                if let found = findKeyRecursively(key: key, current: item) {
                    return found
                }
            }
        }
        return nil
    }
}
