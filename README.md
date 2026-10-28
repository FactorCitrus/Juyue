# JueYue iOS 

[![iOS](https://img.shields.io/badge/Platform-iOS%2015.0%2B-blue.svg)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.0%2B-orange.svg)](https://swift.org)
[![Xcode](https://img.shields.io/badge/Xcode-14.0%2B-blue.svg)](https://developer.apple.com/xcode/)
[![Release](https://img.shields.io/github/v/release/FactorCitrus/Legado-iOS?label=Release&color=green)](https://github.com/FactorCitrus/Legado-iOS/releases)
[![License](https://img.shields.io/badge/License-GPLv3-lightgrey.svg)](LICENSE)

> **JueYue iOS** 是一个用 SwiftUI 和 Swift 编写的开源阅读器，兼容 Android 端 **Legado（开源阅读 3.0）** 的书源规则和 WebDAV 同步格式。

## Fork 与品牌

代码按 GPLv3 授权，允许 fork；但“橘阅”名称、官方图标和截图不随 GPL 授权。非官方分支必须改名、换标、换 Bundle ID，并标注“非官方”。详见 [TRADEMARK.md](TRADEMARK.md)。

---

## 核心功能

**书源**

- 支持 CSS 选择器、JSONPath、XPath、正则、JavaScript 和模板语法。
- 可从本地 JSON 文件、网络链接或剪贴板导入、更新书源。
- 仓库和安装包不预置书源，需要用户自行导入。
- 书源登录使用 App 内网页完成，支持需要 Cookie 的站点。
- 规则说明见 [BOOKSOURCE_GUIDE.md](BOOKSOURCE_GUIDE.md)。

**分类发现**

- 顶部分组切换书源。
- 预设分类可筛选来源、类型、分级和排序。
- 书籍列表支持下拉刷新和触底加载下一页。

**阅读器**

- 支持连续滚动、左右翻页、覆盖翻页、滑动翻页、仿真翻页和无动画。
- 滚动模式可在章节间连续阅读，切换翻页模式时保留阅读位置。
- 书籍详情和目录以全屏视图进入阅读器。
- 内置羊皮纸、暗色、纯黑和护眼绿主题，可调字号、行距、页边距和标点禁则。
- 支持正文缓存和单书清除缓存。
- 大灰狼书源支持段评、本章说和神评，评论以原生列表显示。

**WebDAV**

- 备份格式与 Android Legado 一致：`backup${yyyy-MM-dd}-${deviceName}.zip`。
- 备份包含书籍元数据和阅读进度（`durChapterIndex`、`durChapterPos`、`durChapterTime`）。
- 可设置设备名称，区分不同设备的备份。
- 可列出 WebDAV 上的历史备份并选择恢复；也能从本地文件导入 `backup*.zip`。

**主题**

- 支持跟随系统、浅色和深色模式。

---

### 0.4.5 新增

- **换源检索**：候选列表支持「书名 / 作者 / 书名+作者」三种匹配口径，可改关键词重搜，也能按书源名或分组限定范围。
- **书封来源**：详情页可手填地址、**从相册选图**（存沙盒 `Documents/Covers/`）、或**从书源挑图**（拿书名去启用的源搜一圈，封面排成网格点选）。
- **多角色朗读**：听书可按「旁白 / 对话 / 关键词」切段，逐段换音色（系统语音或百度在线发音人），角色表在听书设置里维护。
- **阅读订阅源**：兼容安卓版 Legado 的 `RssSource` 订阅源格式，可粘贴 JSON、从网址或文件导入 `rssSources.json`；没写规则的源自动按标准 RSS/Atom 解析。
- **替换净化**：正文入库前按规则替换，支持全局规则与单书规则两栏，编辑页带试跑框，正则写错只跳过那一条。
- **阅读页工具**：底部新增「刷新」（丢缓存重抓本章）与「更多」菜单（刷新本章 / 刷新目录 / 替换净化 / 听书设置 / 清缓存重抓）。

## 架构设计

项目采用轻量模块化结构，将底层业务逻辑与上层 UI 视图彻底解耦：

```text
Legado-iOS/
├── Sources/
│   ├── LegadoCore/               # 独立核心框架（跨平台纯 Swift 逻辑）
│   │   ├── Engine/               # 规则引擎（JSEngine, RuleAnalyzer, RuleTokenizer）
│   │   ├── Models/               # 数据模型（Book, BookSource, RuleModels）
│   │   ├── Service/              # 核心服务（NetworkClient, BookSearchService, WebDAVService, EpubParser...）
│   │   └── Utils/                # 工具库（CryptoUtils, JSONPath）
│   └── LegadoApp/                # SwiftUI 交互层与应用入口
│       ├── Services/             # 状态容器（BookStore, SearchViewModel, AudioBookService）
│       ├── Theme/                # 阅读主题与排版配置（ReaderConfig）
│       └── Views/                # 界面视图
│           ├── BookshelfView.swift       # 书架页（倒序排列、未读红点、下拉刷新、原生全屏阅读）
│           ├── CategoryExploreView.swift # 分类页（三级快速切换、预设分类流）
│           ├── BookDetailView.swift      # 书籍详情页（目录、简介、换源、缓存清理）
│           ├── Reader/                   # 全屏阅读器视图（滚动无缝上一章、避头尾对齐）
│           ├── SourceManagerView.swift   # 书源管理（本地文件导入、长按管理）
│           └── SettingsView.swift        # 设置页（WebDAV 同步与历史备份选择、外观主题）
├── Tests/                        # 单元测试套件（覆盖率高，持续集成）
└── Legado.xcodeproj              # Xcode 工程文件
```

---

## 编译与运行

### 系统要求
- macOS 12.0+
- Xcode 14.0+
- iOS 15.0+ 部署目标

### 本地编译
1. 克隆代码仓库：
   ```bash
   git clone https://github.com/FactorCitrus/Legado-iOS.git
   cd Legado-iOS
   ```
2. 运行单元测试（使用 Swift Package Manager）：
   ```bash
   swift test
   ```
3. 打开并运行 Xcode 工程：
   ```bash
   open Legado.xcodeproj
   ```
   在 Xcode 中选择模拟器或真机目标设备，按 `Cmd + R` 即可运行。

---

## GitHub Actions 持续集成与发布

项目配置了自动化的 GitHub Actions 工作流：
- **推送主分支 `main`** 会自动触发构建与测试，编译打包未签名 `Legado-v*.ipa`，并**自动发布到 GitHub Releases** 供侧载安装。
- **支持的侧载方式 (Sideloading)**：
  - **TrollStore**（巨魔商店，推荐，免越狱免证书签名，永久有效）
  - **AltStore / SideStore**（个人免费证书签名）
  - **Sideloadly / 爱思助手**

---

## 语音合成凭据（百度语音）

仓库**不内置**任何百度语音凭据，也不含百度离线音库与 SDK，所以公开版本里只有「系统语音」和「HTTP 语音源」两种，百度音色要自己配。

### 一、在线发音人（走网络配置最省事）

1. 登录百度智能云，进「语音技术 → 语音合成」，建一个应用，拿到 **APP ID**、**API Key**、**Secret Key**。
2. 在 App 里填：`设置 → 听书 → 百度语音授权`。

### 二、离线音库（断网可用，要多两样：序列号 + 音库文件）

1. 在同一控制台申请「离线语音合成」，绑定你的应用（Bundle ID），拿到**离线序列号**。序列号必须和 APP ID 配套，否则引擎报授权失败。
2. 下载百度离线语音合成 SDK 的 iOS 包，里面的资源目录就是音库，常见文件名 `duxiaomei.dat`、`duxiaoyu.dat`、`text_v6.dat`。
3. 把音库放进工程：
   ```
   Sources/LegadoApp/Resources/BaiduTTS/
   ```
   三个 `.dat` 都要放；缺哪个，对应音色就是哑的。
4. 自编译还得带 SDK 本体（只用 GitHub 上的 ipa 不用管这步）：
   ```
   Vendor/BaiduSpeech/
     ├── libBDSpeechTTSBaseKit.a          # 离线合成静态库
     ├── include/                          # 头文件
     └── BaiduSpeech-Bridging-Header.h     # 桥接头
   ```
   这两个目录都在 `.gitignore` 里，得自己放。
5. 在 App 里填：`设置 → 听书 → 百度语音授权` —— **APP ID（离线用）** 和 **离线序列号**（一行一条，一个 APP ID 可能配多条）。保存后重启 App 生效。
6. 首次激活要联网：SDK 拿「APP ID + 序列号」换授权文件，换到之后就能断网用。换设备或刷机后要重来一次。

### 三、常见问题

| 现象                                   | 原因                                                     |
| ------------------------------------ | ------------------------------------------------------ |
| `-100 / authorize model id is empty` | 序列号和 APP ID 不配套，或者序列号填错行                               |
| 音色列表里点不动                             | 音库 `.dat` 没放进 `Resources/BaiduTTS/`，或者装的是 CI 出的包（不含音库） |
| 在线音色鉴权失败                             | API Key / Secret Key 填错，或者精品音色没在控制台开通                  |

## 开源许可证

本项目基于 [GPLv3](LICENSE) 许可证开源。遵循与原版 Legado 相同的开源精神。

## 使用前必读 & 免责声明

1. **不内置任何书源**：仓库与安装包都不带书源，书籍解析规则完全由使用者自行导入并负责。
2. **不带百度语音**：GitHub 上的构建不含百度语音 SDK 与音库（那部分不可再分发），只有系统语音与 HTTP 语音源；需要百度音色的请自行申请凭据并在「听书设置 → 百度语音授权」里填写。
3. **只能侧载安装**：未签名 ipa，用 TrollStore / AltStore / SideStore / Sideloadly / 爱思助手之类安装，不要指望上架 App Store。
4. **授权 GPL-3.0**：本项目基于上游 `SeitoMoyi/Legado-iOS`（GPL-3.0）继续开发，分发必须附带源码并保持 GPL-3.0。
5. 本软件（橘阅）只是一个解析工具，本身并不提供任何内容，没有自己的服务器，配置和显示内容完全由用户决定，和本软件无关，您可以完全把它理解成一个定制版的浏览器。

## 反馈渠道

遇到 bug、想要新功能，或者只是想说点什么，都可以直接找我：

- **邮箱**：**Deathandfly@outlook.com** —— 本人亲收，最直接
- **QQ 群**：**1128675417**
- **GitHub Issues**：https://github.com/FactorCitrus/Legado-iOS/issues
- 装了 App 的也可以从「设置 → 关于」点进 GitHub 仓库

反馈时带上这几样，能省一半来回：**应用版本**（设置 → 关于，形如 `4.7.8.7 (4.7.8.7)`）、**机型 + iOS 版本**、**复现步骤**，再加一段**诊断日志**（设置 → 诊断日志 → 复制全部）。

## 支持项目

如果 Legado-iOS 对你有帮助，欢迎自愿赞助，支持项目持续维护与开发。

赞助完全自愿，不影响软件使用，也不影响用户依据 GPL-3.0 许可证享有的权利。
请我喝茶🍵
<table>
  <tr>
    <td align="center"><strong>微信赞赏</strong></td>
    <td align="center"><strong>支付宝赞赏</strong></td>
  </tr>
  <tr>
    <td align="center"><img src="sponsors/wechat.png" width="200" alt="微信赞赏码"></td>
  </tr>
</table>
感谢支持开源项目！
