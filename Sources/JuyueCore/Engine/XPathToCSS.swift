import Foundation

/// 把常见写法的 XPath 转成 CSS 选择器，交给 SwiftSoup 执行。
///
/// 国内书源的目录规则大量写成 XPath，而 SwiftSoup 只有 CSS 引擎，
/// 这类规则以前静默返回空数组，目录会显示为空。
/// 这里只覆盖书源里高频的那几种写法，遇到不认识的谓词返回 nil，
/// 让调用方保持原来的行为，不会猜错。
public enum XPathToCSS {

    public static func css(from xpath: String) -> String? {
        let trimmed = xpath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("//") || trimmed.hasPrefix("/") else { return nil }

        var body = trimmed
        var descendant = trimmed.hasPrefix("//")
        if descendant {
            body.removeFirst(2)
        } else {
            body.removeFirst(1)
        }

        var selectorParts: [String] = []
        var buffer = ""
        var index = body.startIndex
        var pendingDescendant = descendant

        while index < body.endIndex {
            let character = body[index]

            if character == "/" {
                // 连续的 // 表示后代，单个 / 表示直接子级
                var lookahead = body.index(after: index)
                var isDouble = false
                if lookahead < body.endIndex, body[lookahead] == "/" {
                    isDouble = true
                    lookahead = body.index(after: lookahead)
                }
                guard let part = convertStep(buffer, descendant: pendingDescendant) else { return nil }
                selectorParts.append(part)
                buffer = ""
                pendingDescendant = isDouble
                index = lookahead
                continue
            }

            buffer.append(character)
            index = body.index(after: index)
        }

        guard let last = convertStep(buffer, descendant: pendingDescendant) else { return nil }
        selectorParts.append(last)
        return selectorParts.joined()
    }

    /// 单个 XPath 步：tag、*、带谓词的 tag。
    private static func convertStep(_ rawStep: String, descendant: Bool) -> String? {
        let step = rawStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !step.isEmpty else { return nil }

        let separator = descendant ? " " : " > "

        // 取标签名和后面的谓词
        guard let predicateStart = step.firstIndex(of: "[") else {
            let tag = step == "*" ? "*" : step
            guard isValidTag(tag) else { return nil }
            return separator + tag
        }

        let tag = String(step[step.startIndex..<predicateStart])
        guard !tag.isEmpty, tag == "*" || isValidTag(tag) else { return nil }

        // 只处理单个谓词，多个谓词后面还有别的规则，不硬猜
        let predicateEnd = step.index(before: step.endIndex)
        guard step[predicateEnd] == "]" else { return nil }
        let predicate = String(step[step.index(after: predicateStart)..<predicateEnd])
        guard !predicate.contains("["), !predicate.contains("]") else { return nil }

        guard let attribute = convertPredicate(predicate) else { return nil }
        return separator + tag + attribute
    }

    private static func isValidTag(_ tag: String) -> Bool {
        guard !tag.isEmpty else { return false }
        return tag.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ":" }
    }

    /// 谓词：@attr、@attr='v'、contains(@attr,'v')、位置 [n]
    private static func convertPredicate(_ predicate: String) -> String? {
        let trimmed = predicate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // 位置谓词：[1] [last()]
        if let position = Int(trimmed), position > 0 {
            return ":nth-child(\(position))"
        }

        // contains(@attr, 'value')
        if trimmed.lowercased().hasPrefix("contains("), trimmed.hasSuffix(")") {
            let inner = trimmed.dropFirst("contains(".count).dropLast()
            let pieces = inner.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pieces.count == 2 else { return nil }
            let attribute = pieces[0].hasPrefix("@") ? String(pieces[0].dropFirst()) : pieces[0]
            guard isValidTag(attribute) else { return nil }
            let value = unquote(pieces[1])
            guard let value else { return nil }
            return "[\(attribute)*=\(cssQuote(value))]"
        }

        // @attr 或 @attr='value'
        guard trimmed.hasPrefix("@") else { return nil }
        let withoutAt = String(trimmed.dropFirst())
        if let equalsIndex = withoutAt.firstIndex(of: "=") {
            let attribute = String(withoutAt[withoutAt.startIndex..<equalsIndex])
                .trimmingCharacters(in: .whitespaces)
            guard isValidTag(attribute) else { return nil }
            let rawValue = String(withoutAt[withoutAt.index(after: equalsIndex)...])
            guard let value = unquote(rawValue) else { return nil }
            if attribute == "id" {
                return "#\(cssIdentifier(value))"
            }
            if attribute == "class" {
                // class 里有空格时只能用属性选择器，逐字匹配会失效
                if value.contains(" ") {
                    return "[class*=\(cssQuote(value))]"
                }
                return ".\(cssIdentifier(value))"
            }
            return "[\(attribute)=\(cssQuote(value))]"
        }

        guard isValidTag(withoutAt) else { return nil }
        return "[\(withoutAt)]"
    }

    private static func unquote(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return nil }
        let first = trimmed.first
        let last = trimmed.last
        guard (first == "'" && last == "'") || (first == "\"" && last == "\"") else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func cssQuote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    /// 用 #id 或 .class 写法时，值里出现特殊字符就退回属性选择器。
    private static func cssIdentifier(_ value: String) -> String {
        let isSimple = !value.isEmpty && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
        }
        if isSimple {
            return value
        }
        return value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}
