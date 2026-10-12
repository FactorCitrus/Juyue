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
            if let found = findKeyRecursively(key: nextToken, current: current) {
                return traverse(tokens: restAfterNext, current: found)
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
