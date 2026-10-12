import Foundation

public struct RuleStep: Equatable {
    public enum StepType: Equatable {
        case css(String)
        case jsonPath(String)
        case xpath(String)
        case regex(pattern: String, replacement: String)
        case js(String)
        case attribute(String) // e.g. text, html, href, src
    }

    public let type: StepType
}

public class RuleTokenizer {

    public static func parse(_ rawRule: String) -> [RuleStep] {
        var trimmed = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        // Check for regex replacement at the end: e.g. rule##regex##replacement
        var regexReplacements: [RuleStep] = []
        if let hashRange = trimmed.range(of: "##") {
            let rulePart = String(trimmed[..<hashRange.lowerBound])
            let regexPart = String(trimmed[hashRange.upperBound...])
            let regexSegments = regexPart.components(separatedBy: "##")
            if !regexSegments.isEmpty {
                let pattern = regexSegments[0]
                let replacement = regexSegments.count > 1 ? regexSegments[1] : ""
                regexReplacements.append(RuleStep(type: .regex(pattern: pattern, replacement: replacement)))
                trimmed = rulePart
            }
        }

        // Split by '@js:' or '<js>'
        var jsStep: RuleStep? = nil
        if let jsRange = trimmed.range(of: "@js:") {
            let rulePart = String(trimmed[..<jsRange.lowerBound])
            let script = String(trimmed[jsRange.upperBound...])
            jsStep = RuleStep(type: .js(script))
            trimmed = rulePart
        } else if let openTag = trimmed.range(of: "<js>"),
                  let closeTag = trimmed.range(of: "</js>") {
            let script = String(trimmed[openTag.upperBound..<closeTag.lowerBound])
            jsStep = RuleStep(type: .js(script))
            let beforeTag = String(trimmed[..<openTag.lowerBound])
            trimmed = beforeTag
        }

        // Split by '@'
        // XPath 规则里 @ 是属性谓词的一部分（例如 //div[@id="x"]），
        // 不能按 @ 拆。只有形如 "...@text" 的尾部属性提取才拆。
        var parts: [String]
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/") {
            if let lastAt = trimmed.lastIndex(of: "@") {
                let tail = String(trimmed[trimmed.index(after: lastAt)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let attrNames: Set<String> = ["text", "textnodes", "html", "href", "src", "title", "content"]
                if attrNames.contains(tail) || tail.hasPrefix("attr(") {
                    parts = [String(trimmed[..<lastAt]), tail]
                } else {
                    parts = [trimmed]
                }
            } else {
                parts = [trimmed]
            }
        } else {
            parts = trimmed.components(separatedBy: "@")
        }
        var steps: [RuleStep] = []

        for (index, part) in parts.enumerated() {
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }

            let lower = token.lowercased()
            let knownAttributes: Set<String> = ["text", "textnodes", "html", "href", "src", "title", "content"]
            let isAttr = knownAttributes.contains(lower) || lower.starts(with: "attr(")

            if index == 0 {
                // Determine root type
                if isAttr {
                    steps.append(RuleStep(type: .attribute(lower)))
                } else if token.starts(with: "$.") || token.starts(with: "$[") {
                    steps.append(RuleStep(type: .jsonPath(token)))
                } else if token.starts(with: "//") || token.starts(with: "/") {
                    steps.append(RuleStep(type: .xpath(token)))
                } else {
                    steps.append(RuleStep(type: .css(normalizeSelector(token))))
                }
            } else {
                // Secondary steps can be attributes or sub-selectors
                if isAttr {
                    steps.append(RuleStep(type: .attribute(lower)))
                } else {
                    steps.append(RuleStep(type: .css(normalizeSelector(token))))
                }
            }
        }

        if let js = jsStep {
            steps.append(js)
        }
        steps.append(contentsOf: regexReplacements)

        return steps
    }

    /// Converts Legado's legacy selector prefixes into CSS selectors:
    /// `id.list` -> `#list`, `class.list` -> `.list`.
    private static func normalizeSelector(_ token: String) -> String {
        if token.hasPrefix("id.") { return "#" + token.dropFirst(3) }
        if token.hasPrefix("class.") { return "." + token.dropFirst(6) }
        if token.hasPrefix("tag.") { return String(token.dropFirst(4)) }
        return token
    }
}
