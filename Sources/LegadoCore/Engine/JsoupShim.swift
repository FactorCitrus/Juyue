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

        // `new org.jsoup.nodes.Element("div")` 这类 DOM 构造在 Rhino 里走构造函数。
        // JS 构造函数返回对象时会直接采用返回值，所以这里包一层转给 Swift。
        let makeElement: @convention(block) (JSValue, JSValue) -> JSValue = { tag, baseUri in
            element(tag: string(tag), baseUri: string(baseUri), in: context)
        }
        context.setObject(makeElement, forKeyedSubscript: "__juyueNewElement" as NSString)
        let makeElements: @convention(block) () -> JSValue = { wrapper(Elements(), in: context) }
        context.setObject(makeElements, forKeyedSubscript: "__juyueNewElements" as NSString)
        context.evaluateScript("""
        function __juyueElementCtor(tag, baseUri) { return __juyueNewElement(tag, baseUri); }
        function __juyueElementsCtor() {
          var out = __juyueNewElements();
          for (var i = 0; i < arguments.length; i++) { out.add(arguments[i]); }
          return out;
        }
        """)

        // 包结构要和 Rhino 一致：`org.jsoup.Jsoup` 是类，`org.jsoup` 是包。
        let jsoupPackage: JSValue = JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)
        jsoupPackage.setValue(jsoupClass, forProperty: "Jsoup")

        // `org.jsoup.Connection.Method.HEAD` 这类枚举在测速脚本里很常见。
        let methodEnum: JSValue = JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)
        for name in ["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"] {
            methodEnum.setValue(name, forProperty: name)
        }
        let connectionClass: JSValue = JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)
        connectionClass.setValue(methodEnum, forProperty: "Method")
        jsoupPackage.setValue(connectionClass, forProperty: "Connection")

        let nodes: JSValue = JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)
        nodes.setValue(context.objectForKeyedSubscript("__juyueElementCtor"), forProperty: "Element")
        nodes.setValue(context.objectForKeyedSubscript("__juyueElementsCtor"), forProperty: "Elements")
        jsoupPackage.setValue(nodes, forProperty: "nodes")

        let org: JSValue = JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)
        org.setValue(jsoupPackage, forProperty: "jsoup")
        context.setObject(org, forKeyedSubscript: "org" as NSString)
    }

    // MARK: - 入口

    static func document(html: String, baseUri: String, in context: JSContext) -> JSValue {
        let parsed = (try? SwiftSoup.parse(html, baseUri)) ?? Document(baseUri)
        return wrapper(Elements([parsed]), in: context, indexable: false)
    }

    /// 建一个空标签节点。标签名只放行常规字符，其余按 div 处理，避免拼出奇怪的 HTML。
    static func element(tag: String, baseUri: String, in context: JSContext) -> JSValue {
        let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = name.isEmpty || !name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            ? "div"
            : name
        let parsed = (try? SwiftSoup.parse("<\(safe)></\(safe)>", baseUri)) ?? Document(baseUri)
        guard let node = parsed.body()?.children().first() else {
            return wrapper(Elements(), in: context, indexable: false)
        }
        return wrapper(Elements([node]), in: context, indexable: false)
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

        let text: @convention(block) (JSValue, JSValue) -> JSValue = { value, _ in
            if value.isUndefined {
                return JSValue(object: (try? elements.text()) ?? "", in: context)
            }
            let newText = string(value)
            for element in elements.array() {
                _ = try? element.text(newText)
            }
            return object
        }
        let ownText: @convention(block) () -> String = {
            elements.array().compactMap { $0.ownText() }.joined(separator: " ")
        }
        let html: @convention(block) (JSValue, JSValue) -> JSValue = { value, _ in
            if value.isUndefined {
                return JSValue(object: (try? elements.html()) ?? "", in: context)
            }
            _ = try? elements.html(string(value))
            return object
        }
        let outerHtml: @convention(block) () -> String = { (try? elements.outerHtml()) ?? "" }

        let attr: @convention(block) (JSValue, JSValue) -> JSValue = { name, value in
            let key = string(name)
            if value.isUndefined {
                return JSValue(object: (try? elements.attr(key)) ?? "", in: context)
            }
            if value.isNull {
                for element in elements.array() {
                    _ = try? element.removeAttr(key)
                }
                return object
            }
            let newValue = string(value)
            for element in elements.array() {
                _ = try? element.attr(key, newValue)
            }
            return object
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

        // DOM 构造与改写：脚本会先 new Element(...) 拼节点，再 append/attr 改内容。
        let hasClassFn: @convention(block) (JSValue) -> Bool = { name in
            elements.first()?.hasClass(string(name)) ?? false
        }
        let addClassFn: @convention(block) (JSValue) -> JSValue = { name in
            let value = string(name)
            for element in elements.array() {
                _ = try? element.addClass(value)
            }
            return object
        }
        let removeClassFn: @convention(block) (JSValue) -> JSValue = { name in
            let value = string(name)
            for element in elements.array() {
                _ = try? element.removeClass(value)
            }
            return object
        }
        let removeAttrFn: @convention(block) (JSValue) -> JSValue = { name in
            let key = string(name)
            for element in elements.array() {
                _ = try? element.removeAttr(key)
            }
            return object
        }
        let appendFn: @convention(block) (JSValue) -> JSValue = { value in
            let markup = string(value)
            for element in elements.array() {
                _ = try? element.append(markup)
            }
            return object
        }
        let prependFn: @convention(block) (JSValue) -> JSValue = { value in
            let markup = string(value)
            for element in elements.array() {
                _ = try? element.prepend(markup)
            }
            return object
        }
        let appendChildFn: @convention(block) (JSValue) -> JSValue = { child in
            guard let node = nodeElements(child)?.first() else { return object }
            for element in elements.array() {
                _ = try? element.appendChild(node)
            }
            return object
        }
        let prependChildFn: @convention(block) (JSValue) -> JSValue = { child in
            guard let node = nodeElements(child)?.first() else { return object }
            for element in elements.array() {
                _ = try? element.prependChild(node)
            }
            return object
        }
        let addFn: @convention(block) (JSValue) -> Bool = { item in
            guard let incoming = nodeElements(item) else { return false }
            for element in incoming.array() {
                elements.add(element)
            }
            return !incoming.isEmpty()
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
        setHidden(hasClassFn, "hasClass", on: object, in: context)
        setHidden(addClassFn, "addClass", on: object, in: context)
        setHidden(removeClassFn, "removeClass", on: object, in: context)
        setHidden(removeAttrFn, "removeAttr", on: object, in: context)
        setHidden(appendFn, "append", on: object, in: context)
        setHidden(prependFn, "prepend", on: object, in: context)
        setHidden(appendChildFn, "appendChild", on: object, in: context)
        setHidden(prependChildFn, "prependChild", on: object, in: context)
        setHidden(addFn, "add", on: object, in: context)
        // 包装对象带着原始节点，脚本把节点传回来时（appendChild / add）还能接上
        setHidden(NodeBox(elements), "__juyueNode", on: object, in: context)

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

    /// 脚本直接 `return java.getElements(...)` 时，把包装对象还原成节点数组。
    /// 包装对象是普通 JS 对象，`JSValue.toDictionary()` 只拿到数字下标，
    /// iOS 的规则求值器拿不到 SwiftSoup 节点，列表规则就会「命中 0」。
    static func elements(from value: JSValue) -> [Element]? {
        guard value.isObject,
              let box = value.objectForKeyedSubscript("__juyueNode")?.toObject() as? NodeBox,
              box.elements.size() > 0 else {
            return nil
        }
        return box.elements.array()
    }

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
        method: String = "GET",
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
            let (html, code) = fetch(url, headers, method, nil)
            // Java 版 execute() 网络失败抛 IOException，源的测速脚本靠 try/catch 剔除死线路。
            // 这里以前静默返回 code=0，死线路也计为可用，反倒因为失败得快排在第一位。
            if code == 0 {
                context.exception = JSValue(newErrorFromMessage: "connect failed: \(url)", in: context)
                return JSValue(undefinedIn: context)
            }
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
            return connection(url: url, headers: updated, data: data, method: method, fetch: fetch, in: context)
        }

        let chainValue: @convention(block) (JSValue) -> JSValue = { _ in
            connection(url: url, headers: headers, data: data, method: method, fetch: fetch, in: context)
        }

        func chained(_ key: String, _ value: JSValue) -> JSValue {
            var updated = headers
            if value.isUndefined || value.isNull {
                return JSValue(object: updated[key] ?? "", in: context)
            }
            updated[key] = string(value)
            return connection(url: url, headers: updated, data: data, method: method, fetch: fetch, in: context)
        }

        let chainMethod: @convention(block) (JSValue, JSValue) -> JSValue = { value, _ in
            let raw = string(value).uppercased()
            let resolved = ["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"].contains(raw)
                ? raw
                : method
            return connection(url: url, headers: headers, data: data, method: resolved, fetch: fetch, in: context)
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

        let chainData: @convention(block) (JSValue, JSValue) -> JSValue = { name, value in
            var updated = data
            updated[string(name)] = string(value)
            return connection(url: url, headers: headers, data: updated, method: method, fetch: fetch, in: context)
        }

        object.setValue(get, forProperty: "get")
        object.setValue(post, forProperty: "post")
        object.setValue(execute, forProperty: "execute")
        object.setValue(chainMethod, forProperty: "method")
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

    /// 从包装对象上取回原始节点，脚本把节点当参数传回来时用。
    private static func nodeElements(_ value: JSValue) -> Elements? {
        guard value.isObject else { return nil }
        // 参数通常是 wrapper 生成的 JS 对象，节点挂在它的 `__juyueNode` 上
        if let box = value.objectForKeyedSubscript("__juyueNode")?.toObject() as? NodeBox {
            return box.elements
        }
        return (value.toObject() as? NodeBox)?.elements
    }

    private static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

@objc private protocol NodeBoxExport: JSExport {}

/// 把 Swift 侧的节点集合挂在 JS 包装对象上。脚本会先 `new Element(...)` 拼节点，
/// 再把它传给 `appendChild` / `Elements.add`，这时要能拿回真正的节点对象。
private final class NodeBox: NSObject, NodeBoxExport {
    let elements: Elements

    init(_ elements: Elements) {
        self.elements = elements
    }
}
