import Foundation

public struct RuleStep: Equatable {
    public enum StepType: Equatable {
        case css(String)
        case jsonPath(String)
        case xpath(String)
        case regex(pattern: String, replacement: String)
        case js(String)
        case attribute(String) // text, html, href, src, ...
    }

    public let type: StepType
}

/// 把 Legado 书源规则拆成有序步骤：选择器 → 属性 → JS → 正则替换。
/// 规格见 docs/licensing/specs/RuleTokenizer.md。
public class RuleTokenizer {

    private static let attributeWords: Set<String> = [
        "text", "textnodes", "html", "href", "src", "title", "content"
    ]

    public static func parse(_ rawRule: String) -> [RuleStep] {
        var rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty else { return [] }

        let regexSteps = takeRegexReplacement(&rule)
        let jsStep = takeJavaScript(&rule)
        var steps = selectorSteps(in: rule)

        if let jsStep { steps.append(jsStep) }
        steps.append(contentsOf: regexSteps)
        return steps
    }

    /// `rule##pattern##replacement`，只认第一个 `##` 之后的两段。
    private static func takeRegexReplacement(_ rule: inout String) -> [RuleStep] {
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
    private static func takeJavaScript(_ rule: inout String) -> RuleStep? {
        if let marker = rule.range(of: "@js:") {
            let code = String(rule[marker.upperBound...])
            rule = String(rule[..<marker.lowerBound])
            return RuleStep(type: .js(code))
        }
        if let open = rule.range(of: "<js>"),
           let close = rule.range(of: "</js>", range: open.upperBound..<rule.endIndex) {
            let code = String(rule[open.upperBound..<close.lowerBound])
            rule = String(rule[..<open.lowerBound])
            return RuleStep(type: .js(code))
        }
        return nil
    }

    private static func selectorSteps(in rule: String) -> [RuleStep] {
        let chunks = splitSelectors(rule)
        var steps: [RuleStep] = []

        for (position, chunk) in chunks.enumerated() {
            let token = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }

            if isAttribute(token) {
                steps.append(RuleStep(type: .attribute(token.lowercased())))
            } else if position == 0 {
                steps.append(RuleStep(type: rootKind(of: token)))
            } else {
                steps.append(RuleStep(type: .css(expandLegacyPrefix(token))))
            }
        }
        return steps
    }

    /// XPath 里的 `@` 属于谓词（`//div[@id="x"]`），只有尾部属性提取才拆。
    private static func splitSelectors(_ rule: String) -> [String] {
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

    private static func rootKind(of token: String) -> RuleStep.StepType {
        if token.hasPrefix("$.") || token.hasPrefix("$[") {
            return .jsonPath(token)
        }
        if token.hasPrefix("//") || token.hasPrefix("/") {
            return .xpath(token)
        }
        return .css(expandLegacyPrefix(token))
    }

    private static func isAttribute(_ token: String) -> Bool {
        let lowered = token.lowercased()
        return attributeWords.contains(lowered) || lowered.hasPrefix("attr(")
    }

    /// `id.x` → `#x`，`class.x` → `.x`，`tag.x` → `x`。
    private static func expandLegacyPrefix(_ token: String) -> String {
        if token.hasPrefix("id.") { return "#" + token.dropFirst(3) }
        if token.hasPrefix("class.") { return "." + token.dropFirst(6) }
        if token.hasPrefix("tag.") { return String(token.dropFirst(4)) }
        return token
    }
}
