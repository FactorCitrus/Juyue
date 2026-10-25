# 重写台账

规则：每条记录写清「规格文件、测试文件、实现者、是否接触过上游源码、复核人」。

| 日期 | 文件 | 规格 | 测试 | 实现者 | 接触上游 | 复核 |
|---|---|---|---|---|---|---|
| 2026-10-25 | `Utils/CryptoUtils.swift` | `specs/CryptoUtils.md` | `CleanRoomUtilsTests` | 顾自由（AI 执行） | 是（单人为规格锚定重实现） | 待人工 |
| 2026-10-25 | `Utils/JSONPath.swift` | `specs/JSONPath.md` | `CleanRoomUtilsTests` | 顾自由（AI 执行） | 是 | 待人工 |
| 2026-10-25 | `Engine/RuleTokenizer.swift` | `specs/RuleTokenizer.md` | `CleanRoomUtilsTests` | 顾自由（AI 执行） | 是 | 待人工 |

## 说明

单开发者场景无法做到严格「双盲净室」。当前做法是**规格锚定重实现**：先写行为规格与测试，再按规格写实现；高风险文件（`JSEngine`、`BookContentService`、`ReaderView`）建议找第二个人只看规格与测试复核，台账里如实记录是否接触过上游。

## 2026-10-25 · 批次 2

- `EpubParser`：427 → 64 行（-363）。nav / NCX / spine 三条目录路径、锚点分节、分卷导读、插图块全部按规格重写；新增 11 条自造 EPUB 测试。
- `CookieJar` / `TTSTextChunker`：重写并补 16 条测试。两者在基线 `d21903c` 中不存在，不计入预算，但保留重写后的实现。
- 双版本合并：新增 `AppEdition` 编译开关、`Info-AppStore.plist`、`PrivacyInfo.xcprivacy`、`scripts/build_edition.sh`；商店版不再靠独立分支删代码。
- 全套 `swift test`：154 通过 / 13 跳过 / 0 失败；`swift build` 与 `-DJUYUE_APPSTORE` 均通过。
- 审计：9315 → 8948 行。预算棘轮同步下调。
- 新增 `scripts/upstream_refs_audit.sh` 与 `docs/licensing/EXIT-PLAN.md`，把历史、品牌、许可证三层出口写成闸门。

## 2026-10-25 · 批次 3（构建基础设施）

- `Legado.xcodeproj` 增加 `AppStore` 配置与 `JuyueReader` scheme：同一 target、同一份源码，靠 `JUYUE_APPSTORE` / `NO_BAIDU_TTS` 编译条件与 `Info-AppStore.plist` 分流。
- 工程是**显式文件列表**（非 SPM glob）：新增源文件漏挂会在引用处报 `cannot find ... in scope`。补 `scripts/sync_xcode_sources.py`（`--check` 可进 CI，非零退出即缺文件）。
- `build_edition.sh` 修三处：`overrides` 未初始化（`set -u` 下带版本号必炸）、`common` 与 WARN 块重复、新增 `ARCHS` 透传。
- 验证记录：

| 目标 | 命令 | 结果 |
|---|---|---|
| 商店模拟器 | `DESTINATION='generic/platform=iOS Simulator' NO_SIGN=1 scripts/build_edition.sh appstore build` | BUILD SUCCEEDED |
| 商店真机 | `DESTINATION='generic/platform=iOS' NO_SIGN=1 scripts/build_edition.sh appstore archive` | ARCHIVE SUCCEEDED |
| 商店预检 | `appstore_preflight.sh build/Juyue-appstore.xcarchive/Products/Applications/JuyueReader.app` | PASS (0 fail)，3 WARN 为未签名与两条人工项 |
| 侧载真机 | `DESTINATION='generic/platform=iOS' NO_SIGN=1 scripts/build_edition.sh sideload build` | BUILD SUCCEEDED |

- 侧载**不能**走模拟器：`libBDSpeechTTSBaseKit.a` 只有 iOS arm64 切片，模拟器目标链接必失败（脚本已加提示）。`Vendor/BaiduSpeech`（259MB）与 `Resources/BaiduTTS`（37MB）留在 `.gitignore`，商店包不依赖。

## 2026-10-25 · 批次 4

- `WebDAVService`：750 → 182 行存活（文件 876 → 801）。协议层按 `specs/WebDAVService.md` 重写：统一请求层收掉十处重复的 401 判断，PROPFIND 解析抽成 `matches/firstMatch`，进度合并收敛到 `apply(_:to:requireNotBehind:)` 一个入口。
- 行为保持：明文 HTTP 不发凭据、MKCOL 白名单 200/201/204/405、zip 优先于散 JSON、远端旧进度不回拖、备份包三个条目与安卓端一致。
- 新增 `Tests/LegadoCoreTests/WebDAVServiceCleanRoomTests.swift` 16 条（URL 拼接 / 凭据 / 命名 / PROPFIND / zip 往返 / 进度合并）。
- 全套 `swift test`：170 通过 / 13 跳过 / 0 失败。审计 8948 → 8380（-568）。

## 2026-10-25 · 批次 5

- `WebDAVSyncView`：491 → 余量见 BOARD（文件 609 → 577）。四个忙碌布尔收成 `Activity` 枚举，两处 alert 收成一个 `Notice?`，五个同构输入行抽成 `field(_:placeholder:text:)`，四个操作按钮抽成 `actionRow`。
- 行为保持：禁用条件（URL / 账号）、双恢复模式确认、安全作用域资源成对释放、所有提示文案逐字保留。
- 修掉一个自造 bug：列表成功开 sheet 时不得再弹空提示（`perform` 返回 `Notice?`）。
- 验证：`swift build`、商店模拟器构建、侧载真机构建均 BUILD SUCCEEDED，0 error。
