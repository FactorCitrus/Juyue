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
