# Legado iOS 书源制作与兼容性规范指南 (Book Source Guide)

本文档详细说明了 **Legado iOS (开源阅读 iOS 版)** 所支持的书源规范、解析引擎语法以及制作高兼容性书源的准则。Legado iOS 深度兼容 Android 版 **Legado (阅读 3.0)** 的书源生态。

---

## 📋 1. 书源基本属性规范

一个标准的书源必须是一个合法的 JSON 对象，包含以下核心元数据：

| 字段名称 | 类型 | 说明 | 示例 |
| :--- | :--- | :--- | :--- |
| `bookSourceName` | String | 书源名称（展示在书源列表、分类栏及搜索结果中） | `"示例书源"` / `"示例书源"` |
| `bookSourceUrl` | String | 书源主域名或基准 URL（作为相对路径的解析基准） | `"https://example.com"` |
| `bookSourceGroup` | String? | 书源分类分组 | `"日轻"` / `"网络小说"` |
| `bookSourceType` | Int? | 书源类型：`0` 文本小说（默认），`1` 音频，`2` 图片漫画 | `0` |
| `enabled` | Bool? | 是否启用该书源（默认为 `true`） | `true` |
| `header` | String? | 全局 HTTP 请求头（标准 JSON 字符串） | `{"User-Agent": "Mozilla/5.0..."}` |
| `loginUrl` | String? | 账号登录接口或网页登录交互 URL | `"https://example.com/my/profile.html"` |
| `loginUi` | String? | 交互式登录界面配置（JSON 字符串） | `"[{\"name\":\"账号\",\"type\":\"text\"}]"` |

---

## 🔍 2. 搜索规则 (`ruleSearch` & `searchUrl`)

### 2.1 搜索请求配置 (`searchUrl`)
支持 GET 与 POST 请求，可使用模版变量：
- `{{key}}`: 搜索关键词（支持自动 URL 编码）
- `{{page}}`: 分页页码（从 1 开始自动递增）

**常见示例：**
- **GET 请求 (带查询参数)**:
  ```text
  https://example.com/api/novel?page={{page - 1}}&pageSize=20&query={{key}}&translate=1
  ```
- **POST 请求 (JSON Body)**:
  ```text
  https://example.com/api/search,{"method":"POST","body":{"keyword":"{{key}}","page":{{page}}}}
  ```

### 2.2 搜索列表解析 (`ruleSearch`)
- **`bookList`** (必需): 提取书籍条目列表的选择器。
  - JSONPath: `$.data.list[*]` 或 `$.novels[*]`
  - CSS 选择器: `div.book-item` 或 `ul.novel-list > li`
- **`name`** (必需): 书名规则。例如 `$.title` 或 `h3.title@text`
- **`author`**: 作者名规则。例如 `$.author` 或 `.author@text`
- **`bookUrl`** (必需): 书籍详情页或目录页 URL。例如 `$.id`、`https://example.com/book/{{$.id}}` 或 `a@href`
- **`coverUrl`**: 封面图片 URL。例如 `$.cover` 或 `img@src`
- **`intro`**: 内容简介预览。例如 `$.description` 或 `.intro@text`
- **`kind`**: 分类标签。例如 `$.category` 或 `.tag@text`
- **`lastChapter`**: 最新章节标题。例如 `$.latestChapter` 或 `.last-chapter@text`
- **`wordCount`**: 字数。例如 `$.words`

---

## 📑 3. 详情与目录规则 (`ruleBookInfo` & `ruleToc`)

### 3.1 详情信息规则 (`ruleBookInfo`)
用于打开书籍详情页时补充完整的元数据：
- `init`: 初始定位选择器
- `name` / `author` / `intro` / `coverUrl` / `kind` / `wordCount`
- `tocUrl`: 若目录与详情页分离，配置获取目录的 URL

### 3.2 目录解析规则 (`ruleToc`)
- **`chapterList`** (必需): 章节列表选择器。
  - JSON: `$.chapters[*]`
  - HTML: `div.chapter-list a` 或 `ul.ep-list > li > a`
- **`chapterName`** (必需): 章节标题。例如 `$.title` 或 `text`
- **`chapterUrl`** (必需): 章节正文请求地址。例如 `$.url` 或 `href`
- **`nextTocUrl`**: 分页目录下一页地址（若目录存在分页）

---

## 📖 4. 正文规则 (`ruleContent`)

### 4.1 正文提取 (`content`)
- **JSON API 响应**:
  ```text
  $.data.content
  ```
- **HTML 页面**:
  ```text
  div.forum-content@html
  ```
  > **插图渲染支持**：在 HTML 正文规则中使用 `@html` 时，Legado iOS 会自动提取正文中的 `<img src="...">`、`<img data-src="...">` 标签，解析并渲染为全屏阅读器中的原画插图块，并自动携带 Referer 防盗链请求头。

### 4.2 正文清洗与替换 (`replaceRegex`)
支持使用 `##` 分隔的正则表达式对正文进行批量清洗过滤：
- 语法格式：`正则表达式##替换文本`
- 示例：
  ```text
  (?i)<br\s*/?>##\n
  本章未完，请点击下一页继续阅读##
  ```

---

## 🧭 5. 发现分类规则 (`exploreUrl`)

在底部的**“分类”**标签页中，Legado iOS 会自动解析书源的 `exploreUrl`，为用户呈现多级快速切换界面。支持以下 3 种格式：

### 5.1 标准 JSON 数组格式（最推荐）
```json
[
  {"title": "来源", "url": "", "style": {"layout_flexGrow": 1}},
  {"title": "全部", "url": "https://example.com/api/novel?provider=all&page={{page}}", "style": {"layout_flexGrow": 0.25}},
  {"title": "kakuyomu", "url": "https://example.com/api/novel?provider=kakuyomu&page={{page}}", "style": {"layout_flexGrow": 0.25}},
  {"title": "类型", "url": "", "style": {"layout_flexGrow": 1}},
  {"title": "连载中", "url": "https://example.com/api/novel?type=1&page={{page}}", "style": {"layout_flexGrow": 0.25}},
  {"title": "已完结", "url": "https://example.com/api/novel?type=2&page={{page}}", "style": {"layout_flexGrow": 0.25}}
]
```
> **提示**：`url` 为空或含标题属性的条目会被自动识别为分组标题；带有有效 `url` 的条目会提取到顶部的横向快捷筛选栏与完整分类矩阵抽屉中。

### 5.2 换行文本格式
```text
连载中::https://example.com/category/1?page={{page}}
已完结::https://example.com/category/2?page={{page}}
短篇::https://example.com/category/3?page={{page}}
```

### 5.3 动态 JavaScript 脚本格式
```javascript
<js>
(() => {
  return JSON.stringify([
    { title: "最热排行榜", url: "/rank/hot/{{page}}" },
    { title: "最新入库", url: "/rank/new/{{page}}" }
  ]);
})()
</js>
```

---

## 🔐 6. 登录与 Cookie 凭据管理

对于需要登录访问 VIP 章节、书架或通过 Cloudflare / 反爬验证的站点：
1. **API 登录**:
   - 书源配置 `loginUrl` 搭配 JS 脚本，在登录成功后通过 `java.put("loginHeader", ...)` 自动捕获鉴权 Header。
2. **交互式网页登录 (Web Cookie)**:
   - 若 `loginUrl` 为纯网页地址（例如 `https://example.com/my/profile.html`），长按书源选择「登录」时，App 会直接启动内置 WebKit 浏览器。
   - 用户在页面完成登录或人机验证后，系统会自动抓取会话 Cookie（如 `ews_token`, `PHPSESSID` 等）并持久化保存。

---

## 💡 7. 常见问题与兼容性检查清单

- [x] **是否包含合法 JSON 格式**：文件顶层可为单个书源对象，或由书源对象组成的 JSON 数组 `[...]`。
- [x] **域名协议完整**：`bookSourceUrl` 建议写完整 `https://` 协议。
- [x] **相对路径自动补全**：若 `bookUrl`、`coverUrl` 或 `chapterUrl` 返回相对路径（如 `/detail/123.html`），引擎会自动拼接 `bookSourceUrl`。
- [x] **支持本地直接导入**：在「书源管理」页面右上角点击 `+`，选择「从本地文件导入 (.json)」，无需复杂的网络复制。
