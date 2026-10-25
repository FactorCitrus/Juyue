# 一种源码，两种发行版

分支 `rewrite/upstream-free` 是唯一开发线。侧载版与商店版不再各养一棵树。

| 项 | 侧载（sideload） | 商店（appstore） |
|---|---|---|
| 编译条件 | 无 | `JUYUE_APPSTORE` |
| Bundle ID | `com.factorcitrus.juyue` | `com.factorcitrus.juyue.reader` |
| 显示名 | 橘阅 | 橘阅阅读器 |
| Info.plist | `Sources/LegadoApp/Info.plist` | `Sources/LegadoApp/Info-AppStore.plist` |
| ATS | 允许任意加载 | 仅本地网络 + Web 内容 |
| 分类页签 / 换源 / 段评·本章说·热评 / 书源管理 | 有 | 隐藏，评论哨兵不解析 |
| OPDS / RSS / 本地书 / 系统语音 | 有 | 有 |
| 隐私清单 | 随包 | 随包（包根 `PrivacyInfo.xcprivacy`） |

构建：

```bash
scripts/build_edition.sh sideload archive
scripts/build_edition.sh appstore archive
```

两个包都走同一套 `Sources/`。商店版的功能裁剪只允许改 `AppEdition.isAppStoreClean` 的判定点，不再复制文件、不再开 `appstore-clean` 这类长期分支。

## 待定

- 书源解析引擎在商店包里仍是编译产物，只是入口不可达。若审核对二进制里的规则引擎敏感，下一阶段把 `LegadoCore/Engine` 与登录相关服务拆成独立 target，商店 target 不链接它；这需要改 `Package.swift` 与 Xcode target，不与当前重写并行。
- `Legado` 模块名与 `legado.*` 存储键属于最后的改名牌，等代码归零后统一做，避免每次重写都制造无意义 diff。
