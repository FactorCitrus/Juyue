# 重写台账

规则：每条记录写清「规格文件、测试文件、实现者、是否接触过上游源码、复核人」。

| 日期 | 文件 | 规格 | 测试 | 实现者 | 接触上游 | 复核 |
|---|---|---|---|---|---|---|
| 2026-10-25 | `Utils/CryptoUtils.swift` | `specs/CryptoUtils.md` | `CleanRoomUtilsTests` | 顾自由（AI 执行） | 是（单人为规格锚定重实现） | 待人工 |
| 2026-10-25 | `Utils/JSONPath.swift` | `specs/JSONPath.md` | `CleanRoomUtilsTests` | 顾自由（AI 执行） | 是 | 待人工 |
| 2026-10-25 | `Engine/RuleTokenizer.swift` | `specs/RuleTokenizer.md` | `CleanRoomUtilsTests` | 顾自由（AI 执行） | 是 | 待人工 |

## 说明

单开发者场景无法做到严格「双盲净室」。当前做法是**规格锚定重实现**：先写行为规格与测试，再按规格写实现；高风险文件（`JSEngine`、`BookContentService`、`ReaderView`）建议找第二个人只看规格与测试复核，台账里如实记录是否接触过上游。
