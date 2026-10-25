import Foundation
import SwiftSoup

/// 书源规则的求值器：一个实例绑定一份内容（HTML 字符串 / 根元素 / JSON 对象），
/// 同一份内容可以被不同规则反复求值，省掉重复解析。
///
/// 求值管线分四段，顺序不能换：
/// 1. `@json:` 显式 JSONPath；2. `{{…}}` 模板；3. JS（`<js>` / `@js:`，可带前缀与尾巴）；
/// 4. 兜底链（`||` 取第一个非空、`&&` 逐段取再拼行）→ 最后交给 tokenizer 拆步骤求值。
public final class RuleAnalyzer {
    public let content: Any
    public let baseUrl: String?
    public let jsEngine: JSEngine

    /// init 时判定的内容形态。之后所有取数都按这个分支走，不再每次试探类型。
    private enum Payload {
        case json(Any)
        case html(Document?)
        case element(Element)
        case opaque
    }

    private let payload: Payload

    public init(
        content: Any,
        baseUrl: String? = nil,
        bookSource: BookSource? = nil,
        jsEngine: JSEngine? = nil
    ) {
        self.content = content
        self.baseUrl = baseUrl
        self.jsEngine = jsEngine ?? JSEngine(bookSource: bookSource, baseUrl: baseUrl)

        if let text = content as? String {
            self.payload = RuleAnalyzer.payload(forText: text, baseUrl: baseUrl ?? "")
        } else if let element = content as? Element {
            self.payload = .element(element)
        } else if let json = content as? [String: Any] {
            self.payload = .json(json)
        } else if let json = content as? [Any] {
            self.payload = .json(json)
        } else {
            self.payload = .opaque
        }
    }

    /// 只看首尾字符判 JSON，避免把整页 HTML 丢给 `JSONSerialization` 白跑一遍。
    private static func payload(forText text: String, baseUrl: String) -> Payload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bracketed = (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
        if bracketed,
           let data = trimmed.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            return .json(parsed)
        }
        return .html(try? SwiftSoup.parse(text, baseUrl))
    }

    // MARK: - 内容形态

    private var jsonRoot: Any? {
        if case .json(let value) = payload { return value }
        return nil
    }

    private var htmlRoot: Element? {
        switch payload {
        case .html(let document): return document
        case .element(let element): return element
        default: return nil
        }
    }

    // MARK: - 地址与模板

    /// 把相对地址按 `baseUrl` 补全；已经是绝对地址或没有 base 时原样返回。
    public func resolveUrl(_ urlString: String) -> String {
        guard let base = baseUrl, let baseObject = URL(string: base) else {
            return urlString
        }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        guard let resolved = URL(string: trimmed, relativeTo: baseObject) else {
            return trimmed
        }
        return resolved.absoluteString
    }

    /// 展开 `{{…}}`。从后往前替换，前面的字符位置才不会因为长度变化而错位。
    public func evaluateTemplate(_ template: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"\{\{(.*?)\}\}"#) else {
            return template
        }
        let source = template as NSString
        let matches = pattern.matches(in: template, range: NSRange(location: 0, length: source.length))
        guard matches.isEmpty == false else { return template }

        var output = template
        for match in matches.reversed() {
            let expression = source
                .substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            output = (output as NSString).replacingCharacters(
                in: match.range,
                with: render(expression: expression)
            )
        }
        return output
    }

    private func render(expression: String) -> String {
        if expression.count >= 2,
           (expression.hasPrefix("'") && expression.hasSuffix("'"))
            || (expression.hasPrefix("\"") && expression.hasSuffix("\"")) {
            return String(expression.dropFirst().dropLast())
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
        }

        let jsNamespaces = ["java.", "source.", "book."]
        if jsNamespaces.contains(where: { expression.hasPrefix($0) }) {
            guard let value = jsEngine.evalRule(script: expression, result: content) else { return "" }
            return "\(value)"
        }

        return getString(expression)
    }

    // MARK: - JS 规则拆解

    /// `<js>…</js>` 或 `@js:…` 的三段式拆法：标记前的规则、脚本本身、标记后的残留规则。
    ///
    /// 尾巴不是装饰：聚合源正文脚本回 `{"content":"…"}`，后面挂 `$.content` 才能把
    /// JSON 壳剥掉，不然正文字典里会带着 `\n` 和花括号整段上屏。
    private struct JavaScriptRule {
        let prefix: String
        let script: String
        let suffix: String?
    }

    private func javascriptRule(in rule: String) -> JavaScriptRule? {
        if let open = rule.range(of: "<js>"),
           let close = rule.range(of: "</js>"),
           open.upperBound <= close.lowerBound {
            return JavaScriptRule(
                prefix: String(rule[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                script: String(rule[open.upperBound..<close.lowerBound]),
                suffix: String(rule[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        if rule.hasPrefix("@js:") {
            return JavaScriptRule(prefix: "", script: String(rule.dropFirst(4)), suffix: nil)
        }
        return nil
    }

    // MARK: - 单值求值

    public func getString(_ rule: String?, isUrl: Bool = false) -> String {
        guard let raw = rule?.trimmingCharacters(in: .whitespacesAndNewlines), raw.isEmpty == false else {
            return ""
        }

        // `@json:` 是显式声明，优先于 `$` 前缀推断；命中解析器就只走这一条，不再往下兜。
        if raw.hasPrefix("@json:"), let json = jsonRoot {
            let path = String(raw.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard let value = JSONPath.evaluate(path: path, json: json) else { return "" }
            let text = (value as? String) ?? "\(value)"
            return isUrl ? resolveUrl(text) : text
        }

        if raw.contains("{{"), raw.contains("}}") {
            let expanded = evaluateTemplate(raw)
            return isUrl ? resolveUrl(expanded) : expanded
        }

        if let javascript = javascriptRule(in: raw) {
            let target: Any
            if javascript.prefix.isEmpty {
                target = content
            } else {
                let prefixed = getString(javascript.prefix)
                target = prefixed.isEmpty ? content : prefixed
            }
            let evaluated = jsEngine.evalRule(script: javascript.script, result: target)

            if let suffix = javascript.suffix, suffix.isEmpty == false {
                let nested = RuleAnalyzer(content: evaluated ?? "", baseUrl: baseUrl, jsEngine: jsEngine)
                return nested.getString(suffix, isUrl: isUrl)
            }

            let text = evaluated.map { "\($0)" } ?? ""
            return isUrl ? resolveUrl(text) : text
        }

        if raw.contains("||") {
            for option in raw.components(separatedBy: "||") {
                let candidate = getString(option.trimmingCharacters(in: .whitespacesAndNewlines), isUrl: isUrl)
                if candidate.isEmpty == false { return candidate }
            }
            return ""
        }

        if raw.contains("&&") {
            let parts = raw.components(separatedBy: "&&").map {
                getString($0.trimmingCharacters(in: .whitespacesAndNewlines), isUrl: isUrl)
            }
            return parts.filter { $0.isEmpty == false }.joined(separator: "\n")
        }

        return getStringList(raw, isUrl: isUrl).first ?? ""
    }

    // MARK: - 列表求值

    public func getStringList(_ rule: String?, isUrl: Bool = false) -> [String] {
        guard let raw = rule?.trimmingCharacters(in: .whitespacesAndNewlines), raw.isEmpty == false else {
            return []
        }

        // 列表规则里的 JS 只认脚本本身：`<js>` 之前的前缀在这条路径上不参与求值，
        // 与上游 `getString` 的前缀语义不同，调用方依赖这个差异。
        if raw.hasPrefix("@js:") || (raw.contains("<js>") && raw.contains("</js>")) {
            return javascriptStrings(in: raw, isUrl: isUrl)
        }

        let steps = RuleTokenizer.parse(raw)
        var values: [Any] = []

        if let json = jsonRoot {
            values = rootValues(from: raw, json: json)
            if values.isEmpty {
                values = jsonStepValues(steps: steps, json: json)
            }
            // 聚合源习惯把书信息包一层 `{"code":0,"data":{…}}`，规则却直接写 `$.title`。
            // 根路径空的时候往 data / result 里再探一层，别让封面、简介整批丢掉。
            if values.isEmpty, let dict = json as? [String: Any] {
                values = wrappedValues(from: raw, container: dict)
            }
        } else if let root = htmlRoot {
            values = htmlStepValues(steps: steps, element: root)
        }

        return values.map { value in
            let text = applyTrailingSteps(steps: steps, to: "\(value)")
            return isUrl ? resolveUrl(text) : text
        }
    }

    private func javascriptStrings(in rule: String, isUrl: Bool) -> [String] {
        let script: String
        if rule.hasPrefix("@js:") {
            script = String(rule.dropFirst(4))
        } else {
            let start = rule.range(of: "<js>")?.upperBound ?? rule.startIndex
            let end = rule.range(of: "</js>")?.lowerBound ?? rule.endIndex
            guard start <= end else { return [] }
            script = String(rule[start..<end])
        }

        let evaluated = jsEngine.evalRule(script: script, result: content)
        if let array = evaluated as? [Any] {
            return array.map { isUrl ? resolveUrl("\($0)") : "\($0)" }
        }
        if let single = evaluated {
            return [isUrl ? resolveUrl("\(single)") : "\(single)"]
        }
        return []
    }

    private func rootValues(from rule: String, json: Any) -> [Any] {
        for candidate in [rule, "$." + rule] {
            guard let hit = JSONPath.evaluate(path: candidate, json: json) else { continue }
            return hit as? [Any] ?? [hit]
        }
        return []
    }

    private func wrappedValues(from rule: String, container: [String: Any]) -> [Any] {
        for key in ["data", "result"] {
            guard let inner = container[key] as? [String: Any],
                  let hit = JSONPath.evaluate(path: rule, json: inner) else { continue }
            return hit as? [Any] ?? [hit]
        }
        return []
    }

    private func jsonStepValues(steps: [RuleStep], json: Any) -> [Any] {
        guard let first = steps.first, case .jsonPath(let path) = first.type else { return [] }
        guard let hit = JSONPath.evaluate(path: path, json: json) else { return [] }
        return hit as? [Any] ?? [hit]
    }

    /// 规则尾巴上的 `##正则##替换` 与 `@js` 是后处理，逐条套在同一批结果上。
    private func applyTrailingSteps(steps: [RuleStep], to input: String) -> String {
        var text = input
        for step in steps {
            switch step.type {
            case .regex(let pattern, let replacement):
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                text = regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(location: 0, length: (text as NSString).length),
                    withTemplate: replacement
                )
            case .js(let script):
                if let output = jsEngine.evalRule(script: script, result: text) {
                    text = "\(output)"
                }
            default:
                continue
            }
        }
        return text
    }

    // MARK: - 多元素求值

    /// 脚本回一串 JSON 时，把里面的元素数组取出来。
    ///
    /// 聚合源的章节列表惯例是回 `{"code":0,…,"data":[…]}`，条目字段再逐条用 `$.title`
    /// 这类规则取；把整串当一个元素或者干脆丢掉，目录就空了。
    static func elementsFromJSONText(_ text: String) -> [Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }

        if let array = parsed as? [Any], array.isEmpty == false { return array }
        guard let dict = parsed as? [String: Any] else { return nil }

        for key in ["data", "list", "chapters", "items", "result"] {
            if let array = dict[key] as? [Any], array.isEmpty == false { return array }
        }
        let arrays = dict.values.compactMap { $0 as? [Any] }.filter { $0.isEmpty == false }
        return arrays.count == 1 ? arrays[0] : nil
    }

    public func getElements(_ rule: String?) -> [Any] {
        guard let raw = rule?.trimmingCharacters(in: .whitespacesAndNewlines), raw.isEmpty == false else {
            return []
        }

        if raw.hasPrefix("@json:"), let json = jsonRoot {
            let path = String(raw.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard let hit = JSONPath.evaluate(path: path, json: json) else { return [] }
            return elements(from: hit)
        }

        if let javascript = javascriptRule(in: raw) {
            let target: Any
            if javascript.prefix.isEmpty {
                target = content
            } else {
                // 前缀先选出父级元素，脚本拿到的是元素数组而不是整页内容。
                let prefixed = RuleAnalyzer(
                    content: content,
                    baseUrl: baseUrl,
                    jsEngine: jsEngine
                ).getElements(javascript.prefix)
                target = prefixed.isEmpty ? content : prefixed
            }

            guard let evaluated = jsEngine.evalRule(script: javascript.script, result: target) else {
                return []
            }
            if let text = evaluated as? String, let array = RuleAnalyzer.elementsFromJSONText(text) {
                // 脚本直接把新页面的 JSON 吐出来时，这是「新内容」不是「一个元素」。
                return array
            }
            return elements(from: evaluated)
        }

        if let json = jsonRoot {
            for candidate in [raw, "$." + raw] {
                guard let hit = JSONPath.evaluate(path: candidate, json: json) else { continue }
                if let array = hit as? [Any] { return array }
                if let dict = hit as? [String: Any] { return [dict] }
            }
        }

        let steps = RuleTokenizer.parse(raw)
        guard let first = steps.first else { return [] }

        if case .jsonPath(let path) = first.type,
           let json = jsonRoot,
           let hit = JSONPath.evaluate(path: path, json: json) {
            if let array = hit as? [Any] { return array }
            if let dict = hit as? [String: Any] { return [dict] }
        }

        guard let root = htmlRoot else { return [] }
        var current: [Element] = [root]
        for step in steps {
            let selector: String?
            switch step.type {
            case .css(let css):
                selector = css
            case .xpath(let xpath):
                // 引擎只有 CSS，XPath 先翻译；翻不动的返回 nil，这一步整体跳过。
                selector = XPathToCSS.css(from: xpath)
            default:
                selector = nil
            }
            guard let selector else { continue }
            current = current.flatMap { select(from: $0, selector: selector) }
        }
        return current.isEmpty ? [] : current
    }

    private func elements(from value: Any) -> [Any] {
        if let array = value as? [Any] { return array }
        if let dict = value as? [String: Any] { return [dict] }
        return []
    }

    // MARK: - HTML 选择

    /// 支持 Legado 的 `tag.index` 写法（`li.1`、`a.-1`），负数是倒数第几个。
    private func select(from element: Element, selector: String) -> [Element] {
        let query = selector.trimmingCharacters(in: .whitespacesAndNewlines)

        if let indexed = indexedSelector(query),
           let picked = try? element.select(indexed.tag) {
            let all = picked.array()
            let offset = indexed.index < 0 ? all.count + indexed.index : indexed.index
            guard all.indices.contains(offset) else { return [] }
            return [all[offset]]
        }

        return (try? element.select(query))?.array() ?? []
    }

    private func indexedSelector(_ text: String) -> (tag: String, index: Int)? {
        guard let pattern = try? NSRegularExpression(pattern: #"^([a-zA-Z0-9_\-\*]+)\.(-?\d+)$"#) else {
            return nil
        }
        let full = NSRange(location: 0, length: text.utf16.count)
        guard let match = pattern.firstMatch(in: text, range: full),
              let tagRange = Range(match.range(at: 1), in: text),
              let indexRange = Range(match.range(at: 2), in: text),
              let index = Int(text[indexRange]) else { return nil }
        return (String(text[tagRange]), index)
    }

    /// 逐级套 CSS。命中空集时再看节点自己是否匹配——站点常把列表容器本身写成
    /// `div.list`，容器就是唯一的条目，丢掉了整页就空。
    private func htmlStepValues(steps: [RuleStep], element: Element) -> [Any] {
        var current: [Element] = [element]

        for step in steps {
            guard case .css(let selector) = step.type else { continue }
            current = current.flatMap { node -> [Element] in
                let found = select(from: node, selector: selector)
                if found.isEmpty == false { return found }
                return (try? node.iS(selector)) == true ? [node] : []
            }
        }

        for step in steps {
            guard case .attribute(let attribute) = step.type else { continue }
            return current.compactMap { attributeValue(attribute, of: $0) }
        }

        return current.compactMap { try? $0.text() }
    }

    private func attributeValue(_ attribute: String, of element: Element) -> String? {
        switch attribute {
        case "text", "textnodes":
            return (try? element.text()) ?? ""
        case "html":
            return (try? element.html()) ?? ""
        case "href", "src":
            return try? element.attr(attribute)
        default:
            if attribute.hasPrefix("attr("), attribute.hasSuffix(")"), attribute.count > 6 {
                return try? element.attr(String(attribute.dropFirst(5).dropLast()))
            }
            return try? element.attr(attribute)
        }
    }
}
