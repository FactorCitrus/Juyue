import Foundation

public struct RuleStep: Equatable {
    public enum StepType: Equatable {
        case css(String)
        case jsonPath(String)
        case xpath(String)
        case regex(pattern: String, replacement: String)
        case js(String)
        case attribute(String)
    }

    public let type: StepType
}

/// 把阅读书源规则拆成有序步骤：选择器 → 属性 → JS → 正则替换。
/// 规格见 docs/licensing/specs/RuleTokenizer.md。
public class RuleTokenizer {

    private static let attributeNames: Set<String> = [
        "text", "textnodes", "html", "href", "src", "title", "content"
    ]

    public static func parse(_ rawRule: String) -> [RuleStep] {
        var working = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else { return [] }

        let regex = extractRegex(&working)
        let script = extractScript(&working)
        var steps = selectors(from: working)

        if let script {
            steps.append(script)
        }
        steps.append(contentsOf: regex)
        return steps
    }

    /// `rule##pattern##replacement`，取第一个 `##` 后面的两段。
    private static func extractRegex(_ rule: inout String) -> [RuleStep] {
        guard let marker = rule.range(of: "##") else { return [] }

        let payload = rule[marker.upperBound...].components(separatedBy: "##")
        let step = RuleStep(type: .regex(
            pattern: payload.first ?? "",
            replacement: payload.count > 1 ? payload[1] : ""
        ))
        rule = String(rule[..<marker.lowerBound])
        return [step]
    }

    /// `selector@js:code` 或 `selector<js>code</js>`。
    private static func extractScript(_ rule: inout String) -> RuleStep? {
        if let marker = rule.range(of: "@js:") {
            let code = String(rule[marker.upperBound...])
            rule = String(rule[..<marker.lowerBound])
            return RuleStep(type: .js(code))
        }

        guard let open = rule.range(of: "<js>") else { return nil }
        let searchRange = open.upperBound..<rule.endIndex
        guard let close = rule.range(of: "</js>", range: searchRange) else { return nil }

        let code = String(rule[open.upperBound..<close.lowerBound])
        rule = String(rule[..<open.lowerBound])
        return RuleStep(type: .js(code))
    }

    private static func selectors(from rule: String) -> [RuleStep] {
        var output: [RuleStep] = []
        for (position, part) in selectorParts(rule).enumerated() {
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }

            if isAttribute(token) {
                output.append(RuleStep(type: .attribute(token.lowercased())))
            } else if position == 0 {
                output.append(RuleStep(type: firstSelectorKind(token)))
            } else {
                output.append(RuleStep(type: .css(expandPrefix(token))))
            }
        }
        return output
    }

    /// XPath 谓词里的 `@` 不拆，只有末尾的属性提取才拆。
    private static func selectorParts(_ rule: String) -> [String] {
        guard rule.hasPrefix("/") else {
            return rule.components(separatedBy: "@")
        }
        guard let lastAt = rule.lastIndex(of: "@") else { return [rule] }

        let tail = rule[rule.index(after: lastAt)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard isAttribute(tail) else { return [rule] }
        return [String(rule[..<lastAt]), tail]
    }

    private static func firstSelectorKind(_ token: String) -> RuleStep.StepType {
        if token.hasPrefix("$.") || token.hasPrefix("$[") {
            return .jsonPath(token)
        }
        if token.hasPrefix("//") || token.hasPrefix("/") {
            return .xpath(token)
        }
        return .css(expandPrefix(token))
    }

    private static func isAttribute(_ token: String) -> Bool {
        let normalized = token.lowercased()
        return attributeNames.contains(normalized) || normalized.hasPrefix("attr(")
    }

    /// `id.x` → `#x`，`class.x` → `.x`，`tag.x` → `x`。
    private static func expandPrefix(_ token: String) -> String {
        if token.hasPrefix("id.") {
            return "#" + token.dropFirst(3)
        }
        if token.hasPrefix("class.") {
            return "." + token.dropFirst(6)
        }
        if token.hasPrefix("tag.") {
            return String(token.dropFirst(4))
        }
        return token
    }
}
