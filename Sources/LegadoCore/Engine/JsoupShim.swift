import Foundation
import JavaScriptCore
import SwiftSoup

/// `org.jsoup` 的 JS 兼容层。
///
/// Android 书源习惯写 `org.jsoup.Jsoup.parse(html).select("...")`，Rhino 会把它
/// 解析成 Java 包对象。iOS 没有 Java，这里用 SwiftSoup 包出同名对象，方法名和
/// 返回值对齐 Java 版（字符串 / 布尔 / 数字），选择器非法或内容为空时返回空集合，
/// 不把异常抛回脚本。
enum JsoupShim {
    /// `Jsoup.connect(...).get()` 的取数入口：返回 (body, statusCode)。
    typealias Fetcher = (_ url: String, _ headers: [String: String], _ method: String, _ body: String?) -> (String, Int)

    // MARK: - 安装

    static func install(context: JSContext, fetch: @escaping Fetcher) {
        // JSC 对自有属性 `toString` 会忽略 DontEnum，放在原型上才能既支持
        // `String(els)` 又不让 `for (i in els)` 把方法名当下标。
        context.evaluateScript("""
        var __juyueJsoupProto = Object.create(Object.prototype);
        Object.defineProperty(__juyueJsoupProto, 'toString', {
          value: function () { return this.outerHtml ? this.outerHtml() : ''; },
          enumerable: false
        });
        """)

        let jsoupClass: JSValue = JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)

        let parse: @convention(block) (JSValue, JSValue) -> JSValue = { html, baseUri in
            document(html: string(html), baseUri: string(baseUri), in: context)
        }
        jsoupClass.setValue(parse, forProperty: "parse")

        let connect: @convention(block) (JSValue) -> JSValue = { url in
            connection(
                url: string(url),
                headers: [:],
                data: [:],
                fetch: fetch,
                in: context
            )
        }
        jsoupClass.setValue(connect, forProperty: "connect")

        // 包结构要和 Rhino 一致：`org.jsoup.Jsoup` 是类，`org.jsoup` 是包。
        let jsoupPackage: JSValue = JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)
        jsoupPackage.setValue(jsoupClass, forProperty: "Jsoup")

        let org: JSValue = JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)
        org.setValue(jsoupPackage, forProperty: "jsoup")
        context.setObject(org, forKeyedSubscript: "org" as NSString)
    }

    // MARK: - 入口

    static func document(html: String, baseUri: String, in context: JSContext) -> JSValue {
        let parsed = (try? SwiftSoup.parse(html, baseUri)) ?? Document(baseUri)
        return wrapper(Elements([parsed]), in: context, indexable: false)
    }

    /// 把一段节点集合包装成 JS 对象。Document / Element / Elements 共用一套方法，
    /// `get(i)` / `first()` 继续返回同样的包装，脚本可以链式调用。
    ///
    /// 集合对象同时暴露 `length` 和数字下标，`Array.from(els)`、`for (i in els)`
    /// 这些 Android 源里的写法才能像 Java List 一样工作；方法本身设成不可枚举，
    /// `for...in` 只会拿到下标。
    static func wrapper(_ elements: Elements, in context: JSContext, indexable: Bool = true) -> JSValue {
        let object: JSValue = JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)

        let size: @convention(block) () -> Int = { elements.size() }
        let isEmpty: @convention(block) () -> Bool = { elements.isEmpty() }

        let get: @convention(block) (JSValue) -> JSValue = { index in
            let offset = Int(index.toInt32())
            guard offset >= 0, offset < elements.size() else {
                return wrapper(Elements(), in: context, indexable: false)
            }
            return wrapper(Elements([elements.get(offset)]), in: context, indexable: false)
        }

        let first: @convention(block) () -> JSValue = {
            guard let element = elements.first() else {
                return wrapper(Elements(), in: context, indexable: false)
            }
            return wrapper(Elements([element]), in: context, indexable: false)
        }

        let last: @convention(block) () -> JSValue = {
            guard let element = elements.last() else {
                return wrapper(Elements(), in: context, indexable: false)
            }
            return wrapper(Elements([element]), in: context, indexable: false)
        }

        let eq: @convention(block) (JSValue) -> JSValue = { index in
            let offset = Int(index.toInt32())
            guard offset >= 0, offset < elements.size() else {
                return wrapper(Elements(), in: context, indexable: false)
            }
            return wrapper(Elements([elements.get(offset)]), in: context, indexable: false)
        }

        let select: @convention(block) (JSValue) -> JSValue = { selector in
            let css = string(selector).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !css.isEmpty else { return wrapper(Elements(), in: context) }
            return wrapper(selectElements(css, from: elements), in: context)
        }

        let text: @convention(block) () -> String = { (try? elements.text()) ?? "" }
        let ownText: @convention(block) () -> String = {
            elements.array().compactMap { $0.ownText() }.joined(separator: " ")
        }
        let html: @convention(block) () -> String = { (try? elements.html()) ?? "" }
        let outerHtml: @convention(block) () -> String = { (try? elements.outerHtml()) ?? "" }

        let attr: @convention(block) (JSValue) -> String = { name in
            (try? elements.attr(string(name))) ?? ""
        }
        let hasAttr: @convention(block) (JSValue) -> Bool = { name in
            elements.hasAttr(string(name))
        }
        let absUrl: @convention(block) (JSValue) -> String = { name in
            guard let element = elements.first() else { return "" }
            return (try? element.absUrl(string(name))) ?? ""
        }

        let children: @convention(block) () -> JSValue = {
            let output = Elements()
            for element in elements.array() {
                for child in element.children().array() {
                    output.add(child)
                }
            }
            return wrapper(output, in: context)
        }

        let parent: @convention(block) () -> JSValue = {
            guard let node = elements.first()?.parent() else {
                return wrapper(Elements(), in: context, indexable: false)
            }
            return wrapper(Elements([node]), in: context, indexable: false)
        }

        let tagName: @convention(block) () -> String = { elements.first()?.tagName() ?? "" }
        let className: @convention(block) () -> String = {
            guard let element = elements.first() else { return "" }
            return (try? element.className()) ?? ""
        }
        let id: @convention(block) () -> String = { elements.first()?.id() ?? "" }
        let val: @convention(block) () -> String = {
            guard let element = elements.first() else { return "" }
            return (try? element.val()) ?? ""
        }

        let getElementsByTag: @convention(block) (JSValue) -> JSValue = { tag in
            wrapper(collect(string(tag), from: elements) { element, value in
                try? element.getElementsByTag(value)
            }, in: context)
        }
        let getElementsByClass: @convention(block) (JSValue) -> JSValue = { name in
            wrapper(collect(string(name), from: elements) { element, value in
                try? element.getElementsByClass(value)
            }, in: context)
        }
        let getElementsByAttribute: @convention(block) (JSValue) -> JSValue = { name in
            wrapper(collect(string(name), from: elements) { element, value in
                try? element.getElementsByAttribute(value)
            }, in: context)
        }

        let nextElementSibling: @convention(block) () -> JSValue = {
            guard let element = elements.first(),
                  let node = try? element.nextElementSibling() else {
                return wrapper(Elements(), in: context, indexable: false)
            }
            return wrapper(Elements([node]), in: context, indexable: false)
        }
        let previousElementSibling: @convention(block) () -> JSValue = {
            guard let element = elements.first(),
                  let node = try? element.previousElementSibling() else {
                return wrapper(Elements(), in: context, indexable: false)
            }
            return wrapper(Elements([node]), in: context, indexable: false)
        }

        let title: @convention(block) () -> String = {
            guard let document = elements.first() as? Document else { return "" }
            return (try? document.title()) ?? ""
        }
        let body: @convention(block) () -> JSValue = {
            guard let document = elements.first() as? Document, let node = document.body() else {
                return wrapper(Elements(), in: context, indexable: false)
            }
            return wrapper(Elements([node]), in: context, indexable: false)
        }
        let head: @convention(block) () -> JSValue = {
            guard let document = elements.first() as? Document, let node = document.head() else {
                return wrapper(Elements(), in: context, indexable: false)
            }
            return wrapper(Elements([node]), in: context, indexable: false)
        }
        let toArray: @convention(block) () -> JSValue = {
            let array: JSValue = JSValue(newArrayIn: context) ?? JSValue(undefinedIn: context)
            for (index, element) in elements.array().enumerated() {
                array.setValue(wrapper(Elements([element]), in: context, indexable: false), at: index)
            }
            return array
        }

        let remove: @convention(block) () -> Void = {
            for element in elements.array() {
                try? element.remove()
            }
        }

        // 方法不可枚举：脚本 `for (i in els)` 时只看到下标，和 Rhino 的 Java List 一致。
        setHidden(size, "size", on: object, in: context)
        setHidden(isEmpty, "isEmpty", on: object, in: context)
        setHidden(get, "get", on: object, in: context)
        setHidden(eq, "eq", on: object, in: context)
        setHidden(first, "first", on: object, in: context)
        setHidden(last, "last", on: object, in: context)
        setHidden(select, "select", on: object, in: context)
        setHidden(text, "text", on: object, in: context)
        setHidden(ownText, "ownText", on: object, in: context)
        setHidden(html, "html", on: object, in: context)
        setHidden(outerHtml, "outerHtml", on: object, in: context)
        setHidden(attr, "attr", on: object, in: context)
        setHidden(hasAttr, "hasAttr", on: object, in: context)
        setHidden(absUrl, "absUrl", on: object, in: context)
        setHidden(children, "children", on: object, in: context)
        setHidden(parent, "parent", on: object, in: context)
        setHidden(tagName, "tagName", on: object, in: context)
        setHidden(className, "className", on: object, in: context)
        setHidden(id, "id", on: object, in: context)
        setHidden(val, "val", on: object, in: context)
        setHidden(getElementsByTag, "getElementsByTag", on: object, in: context)
        setHidden(getElementsByClass, "getElementsByClass", on: object, in: context)
        setHidden(getElementsByAttribute, "getElementsByAttribute", on: object, in: context)
        setHidden(nextElementSibling, "nextElementSibling", on: object, in: context)
        setHidden(previousElementSibling, "previousElementSibling", on: object, in: context)
        setHidden(title, "title", on: object, in: context)
        setHidden(body, "body", on: object, in: context)
        setHidden(head, "head", on: object, in: context)
        setHidden(toArray, "toArray", on: object, in: context)
        setHidden(remove, "remove", on: object, in: context)

        if indexable {
            setHidden(elements.size(), "length", on: object, in: context)
            for (index, element) in elements.array().enumerated() {
                let item = wrapper(Elements([element]), in: context, indexable: false)
                setHidden(item, "\(index)", on: object, in: context, enumerable: true)
            }
        }
        attachPrototype(on: object, in: context)
        return object
    }

    // MARK: - 选择器

    private static func selectElements(_ css: String, from elements: Elements) -> Elements {
        let output = Elements()
        var seen = Set<ObjectIdentifier>()
        for element in elements.array() {
            guard let picked = try? element.select(css) else { continue }
            for item in picked.array() where seen.insert(ObjectIdentifier(item)).inserted {
                output.add(item)
            }
        }
        return output
    }

    private static func collect(
        _ argument: String,
        from elements: Elements,
        using query: (Element, String) -> Elements?
    ) -> Elements {
        let output = Elements()
        for element in elements.array() {
            guard let found = query(element, argument) else { continue }
            for item in found.array() {
                output.add(item)
            }
        }
        return output
    }

    // MARK: - Jsoup.connect

    private static func connection(
        url: String,
        headers: [String: String],
        data: [String: String],
        fetch: @escaping Fetcher,
        in context: JSContext
    ) -> JSValue {
        let object: JSValue = JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)

        let get: @convention(block) () -> JSValue = {
            let (html, _) = fetch(url, headers, "GET", nil)
            return document(html: html, baseUri: url, in: context)
        }

        let post: @convention(block) () -> JSValue = {
            var fields = headers
            var payload: String?
            if !data.isEmpty {
                payload = data.map { "\(formEncode($0.key))=\(formEncode($0.value))" }.joined(separator: "&")
                if fields["Content-Type"] == nil, fields["content-type"] == nil {
                    fields["Content-Type"] = "application/x-www-form-urlencoded"
                }
            }
            let (html, _) = fetch(url, fields, "POST", payload)
            return document(html: html, baseUri: url, in: context)
        }

        let execute: @convention(block) () -> JSValue = {
            let (html, code) = fetch(url, headers, "GET", nil)
            return response(body: html, code: code, url: url, in: context)
        }

        let chain: @convention(block) (JSValue, JSValue) -> JSValue = { name, value in
            var updated = headers
            let key = string(name)
            let raw = string(value)
            if value.isUndefined || value.isNull {
                return JSValue(object: updated[key] ?? "", in: context)
            }
            updated[key] = raw
            return connection(url: url, headers: updated, data: data, fetch: fetch, in: context)
        }

        func chained(_ key: String, _ value: JSValue) -> JSValue {
            var updated = headers
            if value.isUndefined || value.isNull {
                return JSValue(object: updated[key] ?? "", in: context)
            }
            updated[key] = string(value)
            return connection(url: url, headers: updated, data: data, fetch: fetch, in: context)
        }

        let chainUserAgent: @convention(block) (JSValue, JSValue) -> JSValue = { value, _ in
            chained("User-Agent", value)
        }
        let chainCookie: @convention(block) (JSValue, JSValue) -> JSValue = { value, _ in
            chained("Cookie", value)
        }
        let chainReferrer: @convention(block) (JSValue, JSValue) -> JSValue = { value, _ in
            chained("Referer", value)
        }

        let chainValue: @convention(block) (JSValue) -> JSValue = { value in
            connection(url: url, headers: headers, data: data, fetch: fetch, in: context)
        }

        let chainData: @convention(block) (JSValue, JSValue) -> JSValue = { name, value in
            var updated = data
            updated[string(name)] = string(value)
            return connection(url: url, headers: headers, data: updated, fetch: fetch, in: context)
        }

        object.setValue(get, forProperty: "get")
        object.setValue(post, forProperty: "post")
        object.setValue(execute, forProperty: "execute")
        object.setValue(chain, forProperty: "header")
        object.setValue(chainUserAgent, forProperty: "userAgent")
        object.setValue(chainCookie, forProperty: "cookie")
        object.setValue(chainReferrer, forProperty: "referrer")
        object.setValue(chainData, forProperty: "data")
        object.setValue(chainValue, forProperty: "timeout")
        object.setValue(chainValue, forProperty: "ignoreContentType")
        object.setValue(chainValue, forProperty: "ignoreHttpErrors")
        object.setValue(chainValue, forProperty: "followRedirects")
        object.setValue(chainValue, forProperty: "validateTLSCertificates")
        return object
    }

    private static func response(body: String, code: Int, url: String, in context: JSContext) -> JSValue {
        let object: JSValue = JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)
        let bodyFn: @convention(block) () -> String = { body }
        let codeFn: @convention(block) () -> Int = { code }
        let urlFn: @convention(block) () -> String = { url }
        let parse: @convention(block) () -> JSValue = { document(html: body, baseUri: url, in: context) }

        object.setValue(bodyFn, forProperty: "body")
        object.setValue(codeFn, forProperty: "statusCode")
        object.setValue(urlFn, forProperty: "url")
        object.setValue(parse, forProperty: "parse")
        return object
    }

    // MARK: - 小工具

    /// `JSValue.setValue` 只能设可枚举属性；这里走 C API，把方法设成不可枚举，
    /// 脚本 `for (i in els)` 才不会把 `size`、`get` 这些方法名当成下标。
    private static func setHidden(
        _ value: Any,
        _ name: String,
        on object: JSValue,
        in context: JSContext,
        enumerable: Bool = false
    ) {
        guard let jsValue = JSValue(object: value, in: context),
              let contextRef = context.jsGlobalContextRef,
              let objectRef = JSValueToObject(contextRef, object.jsValueRef, nil) else {
            return
        }
        let key = JSStringCreateWithCFString(name as CFString)
        defer { JSStringRelease(key) }
        let attributes = enumerable
            ? JSPropertyAttributes(0)
            : JSPropertyAttributes(kJSPropertyAttributeDontEnum)
        JSObjectSetProperty(contextRef, objectRef, key, jsValue.jsValueRef, attributes, nil)
    }

    private static func attachPrototype(on object: JSValue, in context: JSContext) {
        guard let contextRef = context.jsGlobalContextRef,
              let objectRef = JSValueToObject(contextRef, object.jsValueRef, nil),
              let proto = context.objectForKeyedSubscript("__juyueJsoupProto"),
              proto.isObject,
              let protoRef = JSValueToObject(contextRef, proto.jsValueRef, nil) else {
            return
        }
        JSObjectSetPrototype(contextRef, objectRef, protoRef)
    }

    private static func string(_ value: JSValue) -> String {
        guard !value.isUndefined, !value.isNull else { return "" }
        return value.toString() ?? ""
    }

    private static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
