import Foundation
import JavaScriptCore

/// `{{ }}` 内嵌规则的求值上下文，绑定名与安卓端 AnalyzeUrl 一致。
public struct TTSTemplateContext: Equatable {
    public var speakText: String
    public var speakSpeed: Int

    public init(speakText: String, speakSpeed: Int) {
        self.speakText = speakText
        self.speakSpeed = speakSpeed
    }
}

public enum TTSTemplateError: Error, LocalizedError {
    case unbalancedBraces(String)
    case evaluationFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .unbalancedBraces(let template):
            return "{{ }} 不配对：\(template)"
        case .evaluationFailed(let expression, let reason):
            return "内嵌规则执行失败 {{\(expression)}}：\(reason)"
        }
    }
}

/// 求值语音源 URL 规则里的 `{{ }}`，绑定 `speakText` / `speakSpeed`，
/// 并提供安卓端同名的 `java.encodeURI`。
public final class TTSTemplateRenderer {
    public static let shared = TTSTemplateRenderer()

    public init() {}

    /// 逐层展开模板，先算最内层，再算外层。
    public func render(_ template: String, context: TTSTemplateContext) throws -> String {
        var result = template
        while let block = TTSTemplateRenderer.innermostBlock(in: result) {
            let value = try evaluate(block.expression, context: context)
            result.replaceSubrange(block.range, with: value)
        }
        if result.contains("{{") || result.contains("}}") {
            throw TTSTemplateError.unbalancedBraces(template)
        }
        return result
    }

    /// 求值单条表达式。结果按安卓端规则转字符串：整数不带小数点。
    public func evaluate(_ expression: String, context: TTSTemplateContext) throws -> String {
        guard let jsContext = JSContext() else {
            throw TTSTemplateError.evaluationFailed(expression, "无法创建 JS 上下文")
        }

        var thrown: String?
        jsContext.exceptionHandler = { _, exception in
            thrown = exception?.toString()
        }

        let encodeURI: @convention(block) (String) -> String = { JavaURLEncoder.encode($0) }
        jsContext.setObject(encodeURI, forKeyedSubscript: "__legadoEncodeURI" as NSString)
        jsContext.evaluateScript("var java = { encodeURI: function(s) { return __legadoEncodeURI(String(s)); } };")

        jsContext.setObject(context.speakText as NSString, forKeyedSubscript: "speakText" as NSString)
        jsContext.setObject(context.speakSpeed as NSNumber, forKeyedSubscript: "speakSpeed" as NSString)

        guard let value = jsContext.evaluateScript("(\(expression))") else {
            throw TTSTemplateError.evaluationFailed(expression, thrown ?? "无返回值")
        }
        if let thrown {
            throw TTSTemplateError.evaluationFailed(expression, thrown)
        }
        return TTSTemplateRenderer.stringify(value)
    }

    private static func stringify(_ value: JSValue) -> String {
        if value.isUndefined || value.isNull {
            return ""
        }
        if value.isString {
            return value.toString() ?? ""
        }
        if value.isNumber {
            let double = value.toDouble()
            if double.rounded() == double, abs(double) < 1e15 {
                return String(format: "%.0f", double)
            }
            return value.toString() ?? ""
        }
        if value.isBoolean {
            return value.toBool() ? "true" : "false"
        }
        return value.toString() ?? ""
    }

    private struct Block {
        let range: Range<String.Index>
        let expression: String
    }

    /// 找第一段最内层的 `{{ }}`，即内部不再包含 `{{`。
    private static func innermostBlock(in template: String) -> Block? {
        var searchStart = template.startIndex
        while let open = template.range(of: "{{", range: searchStart..<template.endIndex) {
            var index = open.upperBound
            var depth = 1
            while index < template.endIndex {
                if template[index...].hasPrefix("{{") {
                    depth += 1
                    index = template.index(index, offsetBy: 2)
                    continue
                }
                if template[index...].hasPrefix("}}") {
                    depth -= 1
                    if depth == 0 {
                        let inner = template[open.upperBound..<index]
                        if inner.contains("{{") {
                            // 外层，先去找里层
                            break
                        }
                        let end = template.index(index, offsetBy: 2)
                        return Block(range: open.lowerBound..<end, expression: String(inner))
                    }
                    index = template.index(index, offsetBy: 2)
                    continue
                }
                index = template.index(after: index)
            }
            searchStart = open.upperBound
        }
        return nil
    }
}

/// 对齐安卓端 `java.encodeURI`，也就是 Java 的 `URLEncoder.encode(s, "UTF-8")`：
/// 字母数字与 `.-*_` 不转义，空格转 `+`，其余按 UTF-8 逐字节转 `%XX`。
public enum JavaURLEncoder {
    public static func encode(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2E, 0x2D, 0x2A, 0x5F:
                out.append(Character(UnicodeScalar(byte)))
            case 0x20:
                out.append("+")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
