import Foundation
import SwiftSoup

public class RuleAnalyzer {
    public let content: Any
    public let baseUrl: String?
    public let jsEngine: JSEngine

    private var parsedDocument: Document?
    private var parsedJson: Any?

    public init(content: Any, baseUrl: String? = nil, bookSource: BookSource? = nil, jsEngine: JSEngine? = nil) {
        self.content = content
        self.baseUrl = baseUrl
        self.jsEngine = jsEngine ?? JSEngine(bookSource: bookSource, baseUrl: baseUrl)

        if let stringContent = content as? String {
            let trimmed = stringContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmed.starts(with: "{") && trimmed.hasSuffix("}")) ||
               (trimmed.starts(with: "[") && trimmed.hasSuffix("]")),
               let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                self.parsedJson = json
            } else {
                self.parsedDocument = try? SwiftSoup.parse(stringContent, baseUrl ?? "")
            }
        } else if let dict = content as? [String: Any] {
            self.parsedJson = dict
        } else if let array = content as? [Any] {
            self.parsedJson = array
        }
    }

    /// Resolves relative URLs using baseUrl
    public func resolveUrl(_ urlString: String) -> String {
        guard let base = baseUrl, let baseUrlObj = URL(string: base) else {
            return urlString
        }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.starts(with: "http://") || trimmed.starts(with: "https://") {
            return trimmed
        }
        return URL(string: trimmed, relativeTo: baseUrlObj)?.absoluteString ?? trimmed
    }

    /// Evaluates template expressions with {{...}} placeholders
    public func evaluateTemplate(_ template: String) -> String {
        var result = template
        let pattern = "\\{\\{(.*?)\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return template }
        let matches = regex.matches(in: template, range: NSRange(location: 0, length: (template as NSString).length))

        for match in matches.reversed() {
            let fullRange = match.range
            let innerRange = match.range(at: 1)
            let innerExpr = (template as NSString).substring(with: innerRange).trimmingCharacters(in: .whitespacesAndNewlines)

            var evaluatedValue = ""
            if (innerExpr.starts(with: "'") && innerExpr.hasSuffix("'")) || (innerExpr.starts(with: "\"") && innerExpr.hasSuffix("\"")) {
                evaluatedValue = String(innerExpr.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\t", with: "\t")
            } else if innerExpr.starts(with: "java.") || innerExpr.starts(with: "source.") || innerExpr.starts(with: "book.") {
                let jsRes = jsEngine.eval(script: innerExpr, result: content)
                evaluatedValue = jsRes != nil ? "\(jsRes!)" : ""
            } else {
                evaluatedValue = getString(innerExpr)
            }

            result = (result as NSString).replacingCharacters(in: fullRange, with: evaluatedValue)
        }
        return result
    }

    /// Evaluates a rule string and returns a single string result
    public func getString(_ rule: String?, isUrl: Bool = false) -> String {
        guard let rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty else {
            return ""
        }

        // Handle template expressions {{...}}
        if rule.contains("{{") && rule.contains("}}") {
            let expanded = evaluateTemplate(rule)
            return isUrl ? resolveUrl(expanded) : expanded
        }

        // Handle JS scripts: with or without rule prefix
        var rulePrefix = ""
        var jsScript: String? = nil

        if let jsStart = rule.range(of: "<js>"), let jsEnd = rule.range(of: "</js>") {
            rulePrefix = String(rule[..<jsStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            jsScript = String(rule[jsStart.upperBound..<jsEnd.lowerBound])
        } else if rule.starts(with: "@js:") {
            jsScript = String(rule.dropFirst(4))
        }

        if let script = jsScript {
            var targetContent: Any? = content
            if !rulePrefix.isEmpty {
                let prefixVal = getString(rulePrefix, isUrl: false)
                if !prefixVal.isEmpty {
                    targetContent = prefixVal
                }
            }
            let evalResult = jsEngine.eval(script: script, result: targetContent)
            let resStr = evalResult != nil ? "\(evalResult!)" : ""
            return isUrl ? resolveUrl(resStr) : resStr
        }

        // Handle fallback operator: rule1 || rule2
        if rule.contains("||") {
            let options = rule.components(separatedBy: "||")
            for option in options {
                let res = getString(option.trimmingCharacters(in: .whitespacesAndNewlines), isUrl: isUrl)
                if !res.isEmpty {
                    return res
                }
            }
            return ""
        }

        // Handle concatenation operator: rule1 && rule2
        if rule.contains("&&") {
            let segments = rule.components(separatedBy: "&&")
            let combined = segments.map { getString($0.trimmingCharacters(in: .whitespacesAndNewlines), isUrl: isUrl) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return combined
        }

        let list = getStringList(rule, isUrl: isUrl)
        return list.first ?? ""
    }

    /// Evaluates a rule string and returns a list of string results
    public func getStringList(_ rule: String?, isUrl: Bool = false) -> [String] {
        guard let rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty else {
            return []
        }

        // If pure JS: @js:script or <js>...</js>
        if rule.starts(with: "@js:") {
            let script = String(rule.dropFirst(4))
            let evalResult = jsEngine.eval(script: script, result: content)
            if let arr = evalResult as? [Any] {
                return arr.map { "\(isUrl ? resolveUrl("\($0)") : "\($0)")" }
            } else if let single = evalResult {
                let str = "\(single)"
                return [isUrl ? resolveUrl(str) : str]
            }
            return []
        } else if rule.contains("<js>") && rule.contains("</js>") {
            let start = rule.range(of: "<js>")?.upperBound ?? rule.startIndex
            let end = rule.range(of: "</js>")?.lowerBound ?? rule.endIndex
            let script = String(rule[start..<end])
            let evalResult = jsEngine.eval(script: script, result: content)
            if let arr = evalResult as? [Any] {
                return arr.map { "\(isUrl ? resolveUrl("\($0)") : "\($0)")" }
            } else if let single = evalResult {
                let str = "\(single)"
                return [isUrl ? resolveUrl(str) : str]
            }
            return []
        }

        let steps = RuleTokenizer.parse(rule)
        var currentValues: [Any] = []

        // Root evaluation
        let jsonTarget: Any? = parsedJson ?? (content as? [String: Any])
        if let json = jsonTarget {
            let candidatePaths = [rule, "$.\(rule)"]
            for p in candidatePaths {
                if let val = JSONPath.evaluate(path: p, json: json) {
                    if let arr = val as? [Any] {
                        currentValues = arr
                    } else {
                        currentValues = [val]
                    }
                    break
                }
            }
            if currentValues.isEmpty {
                currentValues = evaluateJsonSteps(steps: steps, json: json)
            }
        } else if let doc = parsedDocument {
            currentValues = evaluateHtmlSteps(steps: steps, element: doc)
        } else if let element = content as? Element {
            currentValues = evaluateHtmlSteps(steps: steps, element: element)
        }

        // Apply remaining steps: JS, regex, attribute
        return currentValues.map { val in
            var text = "\(val)"
            for step in steps {
                switch step.type {
                case .regex(let pattern, let replacement):
                    if let rx = try? NSRegularExpression(pattern: pattern) {
                        text = rx.stringByReplacingMatches(
                            in: text,
                            range: NSRange(location: 0, length: (text as NSString).length),
                            withTemplate: replacement
                        )
                    }
                case .js(let script):
                    let res = jsEngine.eval(script: script, result: text)
                    if let res = res {
                        text = "\(res)"
                    }
                default:
                    break
                }
            }
            return isUrl ? resolveUrl(text) : text
        }
    }

    /// Evaluates a rule that returns multiple elements/objects (e.g. book list, chapter list)
    public func getElements(_ rule: String?) -> [Any] {
        guard let rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty else {
            return []
        }

        var rulePrefix = ""
        var jsScript: String? = nil

        if let jsStart = rule.range(of: "<js>"), let jsEnd = rule.range(of: "</js>") {
            rulePrefix = String(rule[..<jsStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            jsScript = String(rule[jsStart.upperBound..<jsEnd.lowerBound])
        } else if rule.starts(with: "@js:") {
            jsScript = String(rule.dropFirst(4))
        }

        if let script = jsScript {
            var targetContent: Any? = content
            if !rulePrefix.isEmpty {
                let prefixAnalyzer = RuleAnalyzer(content: content, baseUrl: baseUrl, jsEngine: jsEngine)
                let prefixElements = prefixAnalyzer.getElements(rulePrefix)
                if !prefixElements.isEmpty {
                    targetContent = prefixElements
                }
            }
            if let evalResult = jsEngine.eval(script: script, result: targetContent) {
                if let array = evalResult as? [Any] {
                    return array
                } else if let dict = evalResult as? [String: Any] {
                    return [dict]
                }
            }
            return []
        }

        // If JSON content, prioritize JSONPath / JSON key lookup
        let jsonTarget: Any? = parsedJson ?? (content as? [String: Any]) ?? (content as? [Any])
        if let json = jsonTarget {
            let candidatePaths = [rule, "$.\(rule)"]
            for p in candidatePaths {
                if let evaluated = JSONPath.evaluate(path: p, json: json) {
                    if let array = evaluated as? [Any] {
                        return array
                    } else if let dict = evaluated as? [String: Any] {
                        return [dict]
                    }
                }
            }
        }

        let steps = RuleTokenizer.parse(rule)
        guard let firstStep = steps.first else { return [] }

        switch firstStep.type {
        case .jsonPath(let path):
            if let json = jsonTarget {
                let evaluated = JSONPath.evaluate(path: path, json: json)
                if let array = evaluated as? [Any] {
                    return array
                } else if let dict = evaluated as? [String: Any] {
                    return [dict]
                }
            }
        default:
            break
        }

        // HTML multi-step chained CSS selection
        if parsedDocument != nil || content is Element {
            var currentElements: [Element] = []
            if let doc = parsedDocument {
                currentElements = [doc]
            } else if let el = content as? Element {
                currentElements = [el]
            }

            for step in steps {
                if case .css(let selector) = step.type {
                    var next: [Element] = []
                    for el in currentElements {
                        next.append(contentsOf: selectElements(from: el, selector: selector))
                    }
                    currentElements = next
                }
            }
            if !currentElements.isEmpty {
                return currentElements
            }
        }

        return []
    }

    /// Selects elements from a parent element given a selector, supporting Legado's `tag.index` syntax (e.g. `li.1`, `a.-1`)
    private func selectElements(from element: Element, selector: String) -> [Element] {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^([a-zA-Z0-9_\-\*]+)\.(-?\d+)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) {
            if let tagRange = Range(match.range(at: 1), in: trimmed),
               let indexRange = Range(match.range(at: 2), in: trimmed),
               let index = Int(trimmed[indexRange]) {
                let tag = String(trimmed[tagRange])
                if let selected = try? element.select(tag) {
                    let all = selected.array()
                    if index >= 0 && index < all.count {
                        return [all[index]]
                    } else if index < 0 && (all.count + index) >= 0 {
                        return [all[all.count + index]]
                    } else {
                        return []
                    }
                }
            }
        }

        if let selected = try? element.select(trimmed) {
            return selected.array()
        }
        return []
    }

    private func evaluateJsonSteps(steps: [RuleStep], json: Any) -> [Any] {
        guard let first = steps.first else { return [] }
        var resultList: [Any] = []

        if case .jsonPath(let path) = first.type {
            if let evalResult = JSONPath.evaluate(path: path, json: json) {
                if let array = evalResult as? [Any] {
                    resultList = array
                } else {
                    resultList = [evalResult]
                }
            }
        }

        return resultList
    }

    private func evaluateHtmlSteps(steps: [RuleStep], element: Element) -> [Any] {
        var elements: [Element] = [element]

        for step in steps {
            if case .css(let selector) = step.type {
                var next: [Element] = []
                for el in elements {
                    let found = selectElements(from: el, selector: selector)
                    if found.isEmpty {
                        if (try? el.iS(selector)) == true {
                            next.append(el)
                        }
                    } else {
                        next.append(contentsOf: found)
                    }
                }
                elements = next
            }
        }

        // Check if an attribute is requested
        for step in steps {
            if case .attribute(let attr) = step.type {
                return elements.compactMap { el in
                    switch attr {
                    case "text", "textnodes":
                        return (try? el.text()) ?? ""
                    case "html":
                        return (try? el.html()) ?? ""
                    case "href":
                        return (try? el.attr("href")) ?? ""
                    case "src":
                        return (try? el.attr("src")) ?? ""
                    default:
                        if attr.starts(with: "attr(") && attr.hasSuffix(")") {
                            let attrName = String(attr.dropFirst(5).dropLast())
                            return try? el.attr(attrName)
                        }
                        return try? el.attr(attr)
                    }
                }
            }
        }

        return elements.compactMap { try? $0.text() }
    }
}
