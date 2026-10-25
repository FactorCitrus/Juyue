# EpubParser 行为规格

## 解析入口

`parse(epubUrl:destinationDir:)`：

1. 目标目录：传入值优先；否则 `Documents/Books/EPUB/<md5(bookUrl)>`。目录不存在时创建并解压 EPUB；已存在则直接复用。
2. 从 `META-INF/container.xml` 取第一个 `rootfile@full-path`，找不到分别抛 code 1 / code 2。
3. OPF 元数据：`dc:title`（缺省用文件名）、`dc:creator`（缺省「未知作者」）、`dc:description`。
4. manifest：`id → href`，记录 `properties` 含 `nav` 或 href 以 `nav.xhtml` 结尾的导航文档，记录 `application/x-dtbncx+xml` 或 `.ncx` 的 NCX。
5. 目录优先级：EPUB3 nav → NCX → spine。nav 取 `nav[epub|type=toc]`，没有就取第一个 `nav`；跳过 `#` 开头的自链接。NCX 取 `navPoint`，标题缺省「第 N 章」。
6. 相对 href 以导航/NCX 文件所在目录为基准解析成绝对 `file://` URL；保留 `#anchor`。
7. 全部章节写入 `bookUrl = epubUrl.absoluteString`，`index` 从 0 连续编号。
8. `Book` 固定 `kind = "EPUB 本地书籍"`、`origin = "local"`、`originName = "本地导入"`、`tocUrl = OPF 绝对 URL`、`totalChapterNum = 章节数`。

## 正文提取

`extractChapterContent(fromUrlString:bookUrl:)`：

1. `%23` 先还原成 `#`；拆路径与锚点；路径可以是 `file://` URL、百分号编码路径或裸路径。
2. 目标文件不存在时，先按 `Documents/Books/EPUB/<md5(bookUrl)>` 递归找同名文件，再在整个 `Documents/Books/EPUB` 找。
3. 读取字节按 UTF-8 → UTF-16 → ASCII 依次解码；失败返回空串。
4. 有锚点：先取锚点元素文本；若该元素含 3 个以上 `<p>` 且文本超过 500 字，直接返回。否则向上找到 body/html 之下的顶层容器，向后收集兄弟节点，遇到下一个 `[id^=chapter]`、`.chaptertitle` 或 `.volumetitle` 停止；清理这段 HTML，空则退回锚点文本。
5. 无锚点且 body 内有 `.chaptertitle` 或 `[id^=chapter]`：只取第一个标题之前的导读段落，非空时追加 `\n\n（本节为分卷导读，请点击“下一章”或通过目录阅读正文）`；否则清理整个 body。
6. 清理规则：`img/image` 的 `src`/`xlink:href`/`href` 相对路径按文件目录解析，输出 `\n\n[image:<绝对URL>]\n\n`；`<br>` 转单换行；`p`/`h1`–`h6` 前后加双换行；连续三个以上换行压成两个；去首尾空白。

`extractChapterContent(from:)` 只是把 URL 转字符串后调用上面的入口。
