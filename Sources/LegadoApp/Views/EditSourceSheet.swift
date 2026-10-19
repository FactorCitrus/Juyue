import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

// MARK: - 通用小工具

/// 空串按 nil 存，导出 JSON 里不会留一堆空字段
func optionalText(_ value: Binding<String?>) -> Binding<String> {
    Binding(
        get: { value.wrappedValue ?? "" },
        set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
    )
}

/// 规则结构里的字符串字段全空就当没配，保存时省掉整个块
func ruleIsBlank(_ value: Any) -> Bool {
    for child in Mirror(reflecting: value).children {
        if let text = child.value as? String {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        } else if let nested = child.value as? InlineHotReview {
            if !ruleIsBlank(nested) { return false }
        }
    }
    return true
}

/// 编辑器里的一行：安卓的中文名 + 导出键名 + 绑到规则结构的哪个字段
struct RuleFieldSpec<Rule> {
    let key: String
    let label: String
    let hint: String?
    let multiline: Bool
    let path: WritableKeyPath<Rule, String?>

    init(_ label: String, _ key: String, hint: String? = nil, multiline: Bool = false,
         _ path: WritableKeyPath<Rule, String?>) {
        self.label = label
        self.key = key
        self.hint = hint
        self.multiline = multiline
        self.path = path
    }
}

/// 一行规则的输入框：上行中文名 + 右侧键名，下面是输入框
struct RuleFieldRow: View {
    @Environment(\.appTheme) private var theme
    let label: String
    let key: String
    let hint: String?
    let multiline: Bool
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(key)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.palette.secondaryInk)
            }

            if multiline {
                TextEditor(text: $value)
                    .frame(minHeight: 90)
                    .font(.system(.caption, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.palette.divider.opacity(0.25))
                    )
            } else {
                TextField(hint ?? key, text: $value)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
            }
        }
        .padding(.vertical, 2)
    }
}

/// 一组规则页：按 specs 顺序画输入框
struct RuleEditorPage<Rule>: View {
    let title: String
    @Binding var rule: Rule
    let specs: [RuleFieldSpec<Rule>]
    var footer: String?

    var body: some View {
        Form {
            Section {
                ForEach(specs, id: \.key) { spec in
                    RuleFieldRow(
                        label: spec.label,
                        key: spec.key,
                        hint: spec.hint,
                        multiline: spec.multiline,
                        value: Binding(
                            get: { rule[keyPath: spec.path] ?? "" },
                            set: { rule[keyPath: spec.path] = $0.isEmpty ? nil : $0 }
                        )
                    )
                }
            } footer: {
                if let footer {
                    Text(footer).font(.caption2)
                }
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 编辑书源

public struct EditSourceSheet: View {
    @ObservedObject var bookStore = BookStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    let originalSource: BookSource
    @State private var draft: BookSource
    @State private var rawJSON: String
    @State private var rawError: String?
    @State private var copiedHint = false
    @State private var saveError: String?

    public init(source: BookSource) {
        self.originalSource = source
        self._draft = State(initialValue: source)
        self._rawJSON = State(initialValue: Self.prettyJSON(of: source))
    }

    /// 书源对象转成好看的 JSON：键排序、斜杠不转义，方便直接看和改
    private static func prettyJSON(of source: BookSource) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(source),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    public var body: some View {
        NavigationView {
            List {
                Section(header: Text("基本信息")) {
                    NavigationLink("源信息与开关") { BasicInfoEditor(source: $draft) }
                    NavigationLink("登录配置") { LoginEditor(source: $draft) }
                }
                .appThemedRows()

                Section(header: Text("规则")) {
                    NavigationLink("搜索规则") { SearchRuleEditor(source: $draft) }
                    NavigationLink("发现规则") { ExploreRuleEditor(source: $draft) }
                    NavigationLink("详情规则") { BookInfoRuleEditor(source: $draft) }
                    NavigationLink("目录规则") { TocRuleEditor(source: $draft) }
                    NavigationLink("正文规则") { ContentRuleEditor(source: $draft) }
                    NavigationLink("书评规则") { ReviewRuleEditor(source: $draft) }
                }
                .appThemedRows()

                Section {
                    NavigationLink("配置测试") { SourceTestView(source: draft) }
                } footer: {
                    Text("用当前编辑中的规则跑一遍搜索 / 详情 / 目录 / 正文，不用先保存。")
                        .font(.caption2)
                }
                .appThemedRows()

                Section(header: Text("整段 JSON")) {
                    NavigationLink("源码编辑") { rawJSONEditor }
                }
                .appThemedRows()

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.caption)
                            .foregroundColor(theme.palette.danger)
                    }
                    .appThemedRows()
                }
            }
            .appThemedList()
            .navigationTitle("编辑书源")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(draft.bookSourceUrl.trimmingCharacters(in: .whitespaces).isEmpty
                                  || draft.bookSourceName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var rawJSONEditor: some View {
        Form {
            Section {
                TextEditor(text: $rawJSON)
                    .frame(minHeight: 380)
                    .font(.system(.caption, design: .monospaced))
                    #if os(iOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
            } footer: {
                Text("导入 JSON 后，会覆盖上面的表单。").font(.caption2)
            }
            .appThemedRows()

            if let rawError {
                Section {
                    Text(rawError).font(.caption).foregroundColor(theme.palette.danger)
                }
                .appThemedRows()
            }

            Section {
                Button {
                    if applyRawJSON() { copiedHint = true }
                } label: {
                    Label("把源码套用到表单", systemImage: "arrow.down.doc")
                }

                Button {
                    copyRawJSON()
                    copiedHint = true
                } label: {
                    Label(copiedHint ? "已复制" : "复制源码", systemImage: "doc.on.doc")
                }

                Button {
                    rawJSON = Self.prettyJSON(of: draft)
                    rawError = nil
                } label: {
                    Label("按当前表单重写源码", systemImage: "arrow.uturn.backward")
                }
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle("书源源码")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func save() {
        saveError = nil
        var updated = draft
        updated.bookSourceName = draft.bookSourceName.trimmingCharacters(in: .whitespaces)
        updated.bookSourceUrl = draft.bookSourceUrl.trimmingCharacters(in: .whitespaces)
        if updated.bookSourceGroup?.isEmpty == true { updated.bookSourceGroup = nil }

        // 全空的规则块不写进 JSON
        if let rule = updated.ruleSearch, ruleIsBlank(rule) { updated.ruleSearch = nil }
        if let rule = updated.ruleExplore, ruleIsBlank(rule) { updated.ruleExplore = nil }
        if let rule = updated.ruleBookInfo, ruleIsBlank(rule) { updated.ruleBookInfo = nil }
        if let rule = updated.ruleToc, ruleIsBlank(rule) { updated.ruleToc = nil }
        if let rule = updated.ruleContent, ruleIsBlank(rule) { updated.ruleContent = nil }
        if let rule = updated.ruleReview, ruleIsBlank(rule) { updated.ruleReview = nil }

        bookStore.updateSource(originalSource: originalSource, newSource: updated)
        dismiss()
    }

    /// 源码模式：按 JSON 解回书源对象；解不出来就留在页面上报错，不关面板
    private func applyRawJSON() -> Bool {
        rawError = nil
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            rawError = "文本编码失败，检查有没有不支持的字符。"
            return false
        }
        do {
            let parsed = try JSONDecoder().decode(BookSource.self, from: data)
            guard !parsed.bookSourceUrl.trimmingCharacters(in: .whitespaces).isEmpty else {
                rawError = "bookSourceUrl 不能为空。"
                return false
            }
            draft = parsed
            return true
        } catch {
            rawError = "JSON 解析失败：\(error.localizedDescription)"
            return false
        }
    }

    private func copyRawJSON() {
        #if os(iOS)
        UIPasteboard.general.string = rawJSON
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawJSON, forType: .string)
        #endif
    }
}

// MARK: - 基本信息

struct BasicInfoEditor: View {
    @Binding var source: BookSource

    private static let types: [(Int, String)] = [(0, "文本"), (1, "音频"), (2, "图片"), (3, "文件")]

    var body: some View {
        Form {
            Section(header: Text("配置")) {
                RuleFieldRow(label: "配置文件 URL", key: "bookSourceUrl", hint: "https://…", multiline: false,
                             value: $source.bookSourceUrl)
                RuleFieldRow(label: "配置名称", key: "bookSourceName", hint: "书源名称", multiline: false,
                             value: $source.bookSourceName)
                RuleFieldRow(label: "配置分组", key: "bookSourceGroup", hint: "多个用英文逗号分隔", multiline: false,
                             value: optionalText($source.bookSourceGroup))
                RuleFieldRow(label: "配置注释", key: "bookSourceComment", hint: "备注", multiline: false,
                             value: optionalText($source.bookSourceComment))
                RuleFieldRow(label: "书籍 URL 正则", key: "bookUrlPattern", hint: "校验书籍链接", multiline: false,
                             value: optionalText($source.bookUrlPattern))
                RuleFieldRow(label: "并发率", key: "concurrentRate", hint: "如 1/1000", multiline: false,
                             value: optionalText($source.concurrentRate))
                RuleFieldRow(label: "变量说明", key: "variableComment", hint: "源变量说明", multiline: false,
                             value: optionalText($source.variableComment))

                Toggle("启用配置", isOn: Binding(
                    get: { source.enabled ?? true },
                    set: { source.enabled = $0 }
                ))

                Picker("配置类型", selection: Binding(
                    get: { source.bookSourceType ?? 0 },
                    set: { source.bookSourceType = $0 }
                )) {
                    ForEach(Self.types, id: \.0) { item in
                        Text(item.1).tag(item.0)
                    }
                }

                Toggle("启用发现", isOn: Binding(
                    get: { source.enabledExplore ?? true },
                    set: { source.enabledExplore = $0 }
                ))
                Toggle("启用 Cookie", isOn: Binding(
                    get: { source.enabledCookieJar ?? false },
                    set: { source.enabledCookieJar = $0 }
                ))
                Toggle("事件监听", isOn: Binding(
                    get: { source.eventListener ?? false },
                    set: { source.eventListener = $0 }
                ))
                Toggle("自定义按钮", isOn: Binding(
                    get: { source.customButton ?? false },
                    set: { source.customButton = $0 }
                ))
            }
            .appThemedRows()

            Section(header: Text("请求")) {
                RuleFieldRow(label: "请求头", key: "header", hint: "JSON 格式的自定义请求头", multiline: true,
                             value: optionalText($source.header))
            }
            .appThemedRows()

            Section(header: Text("脚本")) {
                RuleFieldRow(label: "JS 库", key: "jsLib", hint: "书源自带的助手函数", multiline: true,
                             value: optionalText($source.jsLib))
                RuleFieldRow(label: "封面解码 JS", key: "coverDecodeJs", hint: "封面解码", multiline: true,
                             value: optionalText($source.coverDecodeJs))
                RuleFieldRow(label: "源变量", key: "variable", hint: "JSON 格式的源变量", multiline: true,
                             value: optionalText($source.variable))
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle("基本信息")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 登录配置

struct LoginEditor: View {
    @Binding var source: BookSource

    var body: some View {
        Form {
            Section {
                RuleFieldRow(label: "登录 URL / 脚本", key: "loginUrl", hint: "http 地址或 <js> 脚本", multiline: true,
                             value: optionalText($source.loginUrl))
                RuleFieldRow(label: "登录界面", key: "loginUi", hint: "JSON 数组，安卓那边是一排按钮", multiline: true,
                             value: optionalText($source.loginUi))
                RuleFieldRow(label: "登录检测 JS", key: "loginCheckJs", hint: "判断是否登录成功", multiline: true,
                             value: optionalText($source.loginCheckJs))
            } footer: {
                Text("保存后，书源登录面板里的脚本按钮就是跑这里的 loginUi。")
                    .font(.caption2)
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle("登录配置")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 各规则页

struct SearchRuleEditor: View {
    @Binding var source: BookSource

    private var rule: Binding<SearchRule> {
        Binding(get: { source.ruleSearch ?? SearchRule() },
                set: { source.ruleSearch = ruleIsBlank($0) ? nil : $0 })
    }

    var body: some View {
        RuleEditorPage(title: "搜索规则", rule: rule, specs: [
            RuleFieldSpec("搜书列表", "bookList", hint: "整页书籍列表的规则", multiline: true, \.bookList),
            RuleFieldSpec("书名", "name", hint: "a@text", multiline: false, \.name),
            RuleFieldSpec("作者", "author", hint: "作者提取规则", multiline: false, \.author),
            RuleFieldSpec("书籍 URL", "bookUrl", hint: "a@href", multiline: false, \.bookUrl),
            RuleFieldSpec("封面 URL", "coverUrl", hint: "img@src", multiline: false, \.coverUrl),
            RuleFieldSpec("简介", "intro", hint: "简介提取规则", multiline: false, \.intro),
            RuleFieldSpec("分类", "kind", hint: "分类提取规则", multiline: false, \.kind),
            RuleFieldSpec("最新章节", "lastChapter", hint: "最新章节提取规则", multiline: false, \.lastChapter),
            RuleFieldSpec("字数", "wordCount", hint: "字数提取规则", multiline: false, \.wordCount),
            RuleFieldSpec("更新时间", "updateTime", hint: "更新时间规则", multiline: false, \.updateTime),
            RuleFieldSpec("检验关键词", "checkKeyWord", hint: "用于测试搜索的关键词", multiline: false, \.checkKeyWord)
        ], footer: "搜索地址在顶部那条。")
        .safeAreaInset(edge: .top) {
            urlBar(title: "搜索 URL", key: "searchUrl", text: optionalText($source.searchUrl), multi: true)
        }
    }
}

struct ExploreRuleEditor: View {
    @Binding var source: BookSource

    private var rule: Binding<ExploreRule> {
        Binding(get: { source.ruleExplore ?? ExploreRule() },
                set: { source.ruleExplore = ruleIsBlank($0) ? nil : $0 })
    }

    var body: some View {
        RuleEditorPage(title: "发现规则", rule: rule, specs: [
            RuleFieldSpec("书籍列表", "bookList", hint: "列表规则", multiline: true, \.bookList),
            RuleFieldSpec("书名", "name", hint: "h2@text", multiline: false, \.name),
            RuleFieldSpec("作者", "author", hint: "作者提取规则", multiline: false, \.author),
            RuleFieldSpec("书籍 URL", "bookUrl", hint: "a@href", multiline: false, \.bookUrl),
            RuleFieldSpec("封面 URL", "coverUrl", hint: "img@src", multiline: false, \.coverUrl),
            RuleFieldSpec("简介", "intro", hint: "简介提取规则", multiline: false, \.intro),
            RuleFieldSpec("分类", "kind", hint: "分类提取规则", multiline: false, \.kind),
            RuleFieldSpec("最新章节", "lastChapter", hint: "最新章节提取规则", multiline: false, \.lastChapter),
            RuleFieldSpec("字数", "wordCount", hint: "字数提取规则", multiline: false, \.wordCount),
            RuleFieldSpec("更新时间", "updateTime", hint: "更新时间规则", multiline: false, \.updateTime)
        ], footer: "发现地址是顶部那段脚本，跑完得到分类列表。")
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                urlBar(title: "发现 URL", key: "exploreUrl", text: optionalText($source.exploreUrl), multi: true)
                urlBar(title: "发现筛选", key: "exploreScreen", text: optionalText($source.exploreScreen), multi: true)
            }
        }
    }
}

struct BookInfoRuleEditor: View {
    @Binding var source: BookSource

    private var rule: Binding<BookInfoRule> {
        Binding(get: { source.ruleBookInfo ?? BookInfoRule() },
                set: { source.ruleBookInfo = ruleIsBlank($0) ? nil : $0 })
    }

    var body: some View {
        RuleEditorPage(title: "详情规则", rule: rule, specs: [
            RuleFieldSpec("预处理", "init", hint: "详情页预处理", multiline: true, \.initRule),
            RuleFieldSpec("书名", "name", hint: "h1@text", multiline: false, \.name),
            RuleFieldSpec("作者", "author", hint: "作者提取规则", multiline: false, \.author),
            RuleFieldSpec("封面 URL", "coverUrl", hint: "img@src", multiline: false, \.coverUrl),
            RuleFieldSpec("简介", "intro", hint: "简介提取规则", multiline: false, \.intro),
            RuleFieldSpec("分类", "kind", hint: "分类提取规则", multiline: false, \.kind),
            RuleFieldSpec("最新章节", "lastChapter", hint: "最新章节提取规则", multiline: false, \.lastChapter),
            RuleFieldSpec("目录 URL", "tocUrl", hint: "目录地址，不填就用书籍地址", multiline: false, \.tocUrl),
            RuleFieldSpec("字数", "wordCount", hint: "字数提取规则", multiline: false, \.wordCount),
            RuleFieldSpec("更新时间", "updateTime", hint: "更新时间规则", multiline: false, \.updateTime),
            RuleFieldSpec("允许改名", "canReName", hint: "文本替换规则", multiline: true, \.canReName)
        ])
    }
}

struct TocRuleEditor: View {
    @Binding var source: BookSource

    private var rule: Binding<TocRule> {
        Binding(get: { source.ruleToc ?? TocRule() },
                set: { source.ruleToc = ruleIsBlank($0) ? nil : $0 })
    }

    var body: some View {
        RuleEditorPage(title: "目录规则", rule: rule, specs: [
            RuleFieldSpec("章节列表", "chapterList", hint: "id.list@dd@a", multiline: true, \.chapterList),
            RuleFieldSpec("章节名称", "chapterName", hint: "text", multiline: false, \.chapterName),
            RuleFieldSpec("章节 URL", "chapterUrl", hint: "href", multiline: false, \.chapterUrl),
            RuleFieldSpec("预处理 JS", "preUpdateJs", hint: "目录预处理", multiline: true, \.preUpdateJs),
            RuleFieldSpec("格式化 JS", "formatJs", hint: "章节名格式化", multiline: true, \.formatJs),
            RuleFieldSpec("卷标题", "isVolume", hint: "卷标题判断规则", multiline: false, \.isVolume),
            RuleFieldSpec("VIP 标记", "isVip", hint: "VIP 判断规则", multiline: false, \.isVip),
            RuleFieldSpec("付费标记", "isPay", hint: "付费判断规则", multiline: false, \.isPay),
            RuleFieldSpec("更新时间", "updateTime", hint: "更新时间规则", multiline: false, \.updateTime),
            RuleFieldSpec("下一页目录", "nextTocUrl", hint: "翻页 URL", multiline: false, \.nextTocUrl)
        ])
    }
}

struct ContentRuleEditor: View {
    @Binding var source: BookSource

    private var rule: Binding<ContentRule> {
        Binding(get: { source.ruleContent ?? ContentRule() },
                set: { source.ruleContent = ruleIsBlank($0) ? nil : $0 })
    }

    var body: some View {
        RuleEditorPage(title: "正文规则", rule: rule, specs: [
            RuleFieldSpec("正文内容", "content", hint: "id.content@textNodes", multiline: true, \.content),
            RuleFieldSpec("章节标题", "title", hint: "从正文提取标题", multiline: false, \.title),
            RuleFieldSpec("副文规则", "subContent", hint: "拼接在正文后，或抓歌词", multiline: true, \.subContent),
            RuleFieldSpec("下一页 URL", "nextContentUrl", hint: "翻页 URL 规则", multiline: false, \.nextContentUrl),
            RuleFieldSpec("替换正则", "replaceRegex", hint: "正文净化", multiline: true, \.replaceRegex),
            RuleFieldSpec("Web JS", "webJs", hint: "抓不到正文时用 WebView 跑", multiline: true, \.webJs),
            RuleFieldSpec("源正则", "sourceRegex", hint: "源 URL 正则", multiline: false, \.sourceRegex),
            RuleFieldSpec("图片样式", "imageStyle", hint: "DEFAULT / FULL", multiline: false, \.imageStyle),
            RuleFieldSpec("图片解码 JS", "imageDecode", hint: "图片解码", multiline: true, \.imageDecode),
            RuleFieldSpec("付费操作", "payAction", hint: "付费章节动作", multiline: true, \.payAction),
            RuleFieldSpec("回调 JS", "callBackJs", hint: "正文加载完成后的回调", multiline: true, \.callBackJs)
        ])
    }
}

struct ReviewRuleEditor: View {
    @Environment(\.appTheme) private var theme
    @Binding var source: BookSource

    private var rule: Binding<ReviewRule> {
        Binding(get: { source.ruleReview ?? ReviewRule() },
                set: { source.ruleReview = ruleIsBlank($0) ? nil : $0 })
    }

    private var hot: Binding<InlineHotReview> {
        Binding(get: { (source.ruleReview ?? ReviewRule()).inlineHotReview ?? InlineHotReview() },
                set: { hotReview in
                    var review = source.ruleReview ?? ReviewRule()
                    review.inlineHotReview = ruleIsBlank(hotReview) ? nil : hotReview
                    source.ruleReview = review
                })
    }

    var body: some View {
        RuleEditorPage(title: "书评规则", rule: rule, specs: [
            RuleFieldSpec("书评 URL", "reviewUrl", hint: "书评列表地址", multiline: true, \.reviewUrl),
            RuleFieldSpec("头像", "avatarRule", hint: "头像提取规则", multiline: false, \.avatarRule),
            RuleFieldSpec("内容", "contentRule", hint: "评论内容规则", multiline: true, \.contentRule),
            RuleFieldSpec("发布时间", "postTimeRule", hint: "发布时间规则", multiline: false, \.postTimeRule),
            RuleFieldSpec("引用 URL", "reviewQuoteUrl", hint: "引用评论地址", multiline: false, \.reviewQuoteUrl),
            RuleFieldSpec("点赞 URL", "voteUpUrl", hint: "点赞地址", multiline: false, \.voteUpUrl),
            RuleFieldSpec("点踩 URL", "voteDownUrl", hint: "点踩地址", multiline: false, \.voteDownUrl),
            RuleFieldSpec("发评论 URL", "postReviewUrl", hint: "发布评论地址", multiline: false, \.postReviewUrl),
            RuleFieldSpec("发引用 URL", "postQuoteUrl", hint: "发布引用评论地址", multiline: false, \.postQuoteUrl),
            RuleFieldSpec("删除 URL", "deleteUrl", hint: "删除评论地址", multiline: false, \.deleteUrl)
        ], footer: "内联热评是段评里的热评，规则单独一组，在顶部。")
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("内联热评")
                    .font(.caption.bold())
                    .foregroundColor(theme.palette.secondaryInk)
                RuleFieldRow(label: "热评 URL", key: "inlineHotReview.urlRule", hint: "从段评 URL 派生热评请求", multiline: false,
                             value: optionalText(hot.urlRule))
                RuleFieldRow(label: "热评列表", key: "inlineHotReview.listRule", hint: "热评列表提取规则", multiline: false,
                             value: optionalText(hot.listRule))
                RuleFieldRow(label: "热评内容", key: "inlineHotReview.contentRule", hint: "单条热评正文规则", multiline: false,
                             value: optionalText(hot.contentRule))
            }
            .padding(12)
            .background(theme.palette.divider.opacity(0.08))
        }
    }
}

/// 规则页顶上那条「搜索 URL / 发现 URL」输入区
@ViewBuilder
func urlBar(title: String, key: String, text: Binding<String>, multi: Bool) -> some View {
    RuleFieldRow(label: title, key: key, hint: title, multiline: multi, value: text)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppThemeManager.shared.theme.palette.divider.opacity(0.08))
}

// MARK: - 配置测试

struct SourceTestView: View {
    @Environment(\.appTheme) private var theme
    let source: BookSource

    enum Mode: String, CaseIterable, Identifiable {
        case search = "搜索"
        case explore = "发现"
        case detail = "详情"
        case toc = "目录"
        case content = "正文"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .search
    @State private var input: String = ""
    @State private var running = false
    @State private var log: String = ""

    private var placeholder: String {
        switch mode {
        case .search, .explore: return "关键词或分类 URL"
        case .detail: return "书籍详情页 URL"
        case .toc: return "目录页 URL"
        case .content: return "书籍详情页 URL，取第一章正文"
        }
    }

    private var chain: String {
        switch mode {
        case .search: return "搜索"
        case .explore: return "发现"
        case .detail: return "详情"
        case .toc: return "详情 → 目录"
        case .content: return "详情 → 目录 → 正文"
        }
    }

    var body: some View {
        Form {
            Section(header: Text("模式")) {
                Picker("模式", selection: $mode) {
                    ForEach(Mode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                Text("测试链路：\(chain)")
                    .font(.caption2)
                    .foregroundColor(theme.palette.secondaryInk)
            }
            .appThemedRows()

            Section(header: Text("关键词 / URL")) {
                TextField(placeholder, text: $input)
                    .font(.system(.caption, design: .monospaced))
                    #if os(iOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif

                HStack {
                    Button("填搜索示例") { fillSearchSample() }
                        .font(.caption)
                    Button("填发现示例") { fillExploreSample() }
                        .font(.caption)
                    Spacer()
                    Button(running ? "测试中…" : "开始测试") { run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .appThemedRows()

            Section(header: Text("结果")) {
                Text(log.isEmpty ? "还没开始测。" : log)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
            .appThemedRows()
        }
        .appThemedList()
        .navigationTitle("配置测试")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func fillSearchSample() {
        let sample = source.ruleSearch?.checkKeyWord?.trimmingCharacters(in: .whitespaces)
        input = (sample?.isEmpty == false ? sample : "我的") ?? "我的"
    }

    private func fillExploreSample() {
        Task.detached(priority: .userInitiated) {
            let categories = BookExploreService.shared.parseExploreCategories(source: source)
            let target = categories.first { !$0.isAction && !($0.url ?? "").isEmpty }?.url
            await MainActor.run {
                input = target ?? ""
                if input.isEmpty { log = "这个源没有可直接抓取的发现分类。" }
            }
        }
    }

    private func run() {
        running = true
        log = ""
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                switch mode {
                case .search:
                    let books = try await BookSearchService.shared.search(source: source, key: key, page: 1)
                    await append("搜索「\(key)」：\(books.count) 条")
                    for book in books.prefix(5) {
                        await append("· \(book.name) / \(book.author)\n  \(shortUrl(book.bookUrl))")
                    }

                case .explore:
                    let books = try await BookExploreService.shared.fetchExploreBooks(source: source, categoryUrl: key)
                    await append("发现分类：\(books.count) 条")
                    for book in books.prefix(5) {
                        await append("· \(book.name) / \(book.author)\n  \(shortUrl(book.bookUrl))")
                    }

                case .detail:
                    let result = try await BookContentService.shared.fetchBookDetail(book: makeBook(url: key), source: source)
                    await append("书名：\(result.book.name)\n作者：\(result.book.author)\n分类：\(result.book.kind ?? "-")\n最新章节：\(result.book.latestChapterTitle ?? "-")\n简介：\(String((result.book.intro ?? "").prefix(80)))\n目录条数：\(result.chapters.count)")

                case .toc:
                    let chapters = try await BookContentService.shared.fetchChapterList(book: makeBook(url: key), source: source)
                    await append("目录：\(chapters.count) 章")
                    for chapter in chapters.prefix(8) {
                        await append("· [\(chapter.index)] \(chapter.title)\n  \(shortUrl(chapter.url))")
                    }

                case .content:
                    let chapters = try await BookContentService.shared.fetchChapterList(book: makeBook(url: key), source: source)
                    guard let first = chapters.first else {
                        await append("目录是空的，抓不到正文。")
                        break
                    }
                    let content = try await BookContentService.shared.fetchChapterContent(chapter: first, source: source)
                    await append("第一章：\(first.title)")
                    await append("正文 \(content.count) 字：\n\(String(content.prefix(300)))")
                }
            } catch {
                await append("失败：\(error.localizedDescription)")
            }
            await MainActor.run { running = false }
        }
    }

    private func makeBook(url: String) -> Book {
        Book(bookUrl: url, name: "测试书籍", author: "未知", origin: source.bookSourceUrl, originName: source.bookSourceName)
    }

    /// data: base64 的跳转地址能占满整屏，列表里只留前一段
    private func shortUrl(_ url: String) -> String {
        url.count > 90 ? String(url.prefix(90)) + "…" : url
    }

    @MainActor
    private func append(_ text: String) {
        log += log.isEmpty ? text : "\n\n\(text)"
    }
}
