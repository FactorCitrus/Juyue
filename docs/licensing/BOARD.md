# 重写看板（upstream-free）

基线 `d21903c`；当前存活上游 **6737** 行 / 32 个文件；逻辑残留 **831** 行 / 202 段 / 15 个文件（2026-10-25 实测）。

- **棘轮闸门**：`python3 scripts/gpl_audit.py --budget "$(cat docs/licensing/upstream-budget.txt)"`。
  预算当前 `6737`，只许下调；任何一批改动让存活行数上涨即 FAIL。
- **逻辑闸门**：`python3 scripts/gpl_regions.py --logic --check --budget "$(cat docs/licensing/logic-budget.txt)"`，
  预算当前 `831`。
- **下一道闸门 6500**：再清 237 行后把预算改成 `6500`，之后 6300 / 6000 / 5500……逐档下压。
- **终局**：`--budget 0`。`gpl_audit.py --strict` 等价于 `--budget 0`（`limit = 0 if args.strict else args.budget`），
  和 `--budget` 一起给会被覆盖成 0，别叠着用。

## 用户指定待办

- [x] **侧载版主题在商店版可用**（2026-10-25 核实）：统一源码后主题从未被 `isAppStoreClean` 拦截。`NieRTheme.swift`（252 行）与 `ReaderConfig.swift`（1578 行）全量编入商店包。**更正**：商店二进制里「换源」出现 **1** 次（`ReaderView.swift:3866` 的 `Text("换源")`），早先记的「0 次」是错的；商店版允许用户自带书源（`AppEdition.allowsBookSources = true`），换源入口属正常功能，不构成残留阻断。
- [x] **段评**（2026-10-25 用户拍板「段评可以带」）：商店二进制里「段评」7 处文案保留，解析层仍受 gate 控制。
- [x] **商店包百度 TTS 死界面**（2026-10-25 已修）：`TTSSettingsSheet` 三段 Section 改 `#if os(iOS) && !NO_BAIDU_TTS`，角色引擎选项过滤 `.baiduOnline`；商店二进制里「管理自备音色 / 加载 / 激活引擎 / 取 token / 诊断音库文件」全为 0。产物 `artifacts/store-tts-2026-10-25/`。
- [ ] **真机 UI 走查**：商店条件包在模拟器启动正常（书架 214 本），真机视觉待验收。

## 文件清单（存活上游 / 逻辑残留均为实测）

| 文件 | 行数 | 存活上游 | 逻辑残留 | 状态 |
|---|---:|---:|---:|---|
| `Sources/LegadoApp/Views/Reader/ReaderView.swift` | 9793 | 1709 | 279 | 待做（279） |
| `Sources/LegadoApp/Views/BookDetailView.swift` | 1227 | 492 | 136 | 待做（136） |
| `Sources/LegadoApp/Views/CategoryExploreView.swift` | 1011 | 444 | 81 | 待做（81） |
| `Sources/LegadoApp/Views/SourceManagerView.swift` | 1407 | 427 | 77 | 待做（77） |
| `Sources/LegadoApp/Views/SourceWebLoginView.swift` | 511 | 380 | 49 | 待做（49） |
| `Sources/LegadoApp/Views/SourceDetailView.swift` | 617 | 333 | 73 | 待做（73） |
| `Sources/LegadoCore/Service/BookContentService.swift` | 1721 | 321 | 0 | 已清零逻辑 |
| `Sources/LegadoApp/Services/BookStore.swift` | 1533 | 289 | 0 | 已清零逻辑 |
| `Sources/LegadoApp/Views/BookshelfView.swift` | 1744 | 218 | 72 | 待做（72） |
| `Sources/LegadoCore/Engine/JSEngine.swift` | 920 | 213 | 0 | 已清零逻辑 |
| `Sources/LegadoApp/Views/WebDAVSyncView.swift` | 728 | 184 | 15 | 待做（15） |
| `Sources/LegadoCore/Service/WebDAVService.swift` | 801 | 182 | 9 | 待做（9） |
| `Sources/LegadoCore/Service/BookSearchService.swift` | 347 | 172 | 14 | 待做（14） |
| `Sources/LegadoCore/Service/BookExploreService.swift` | 300 | 169 | 6 | 待做（6） |
| `Sources/LegadoApp/Services/SearchViewModel.swift` | 283 | 143 | 11 | 待做（11） |
| `Sources/LegadoCore/Models/Book.swift` | 337 | 142 | 0 | 已清零逻辑 |
| `Sources/LegadoCore/Models/BookSource.swift` | 311 | 134 | 0 | 已清零逻辑 |
| `Sources/LegadoApp/Views/SearchBookView.swift` | 600 | 130 | 0 | 已清零逻辑 |
| `Sources/LegadoApp/Services/AudioBookService.swift` | 668 | 124 | 3 | 待做（3） |
| `Sources/LegadoCore/Engine/RuleAnalyzer.swift` | 488 | 86 | 0 | 已清零逻辑 |
| `Sources/LegadoCore/Service/EpubParser.swift` | 449 | 64 | 3 | 待做（3） |
| `Sources/LegadoApp/LegadoApp.swift` | 530 | 58 | 0 | 已清零逻辑 |
| `Sources/LegadoApp/Views/SettingsView.swift` | 5167 | 58 | 3 | 待做（3） |
| `Sources/LegadoCore/Service/NetworkClient.swift` | 223 | 55 | 0 | 已清零逻辑 |
| `Sources/LegadoApp/Theme/ReaderConfig.swift` | 1578 | 44 | 0 | 已清零逻辑 |
| `Sources/LegadoApp/Views/EditSourceSheet.swift` | 800 | 39 | 0 | 已清零逻辑 |
| `Sources/LegadoApp/Views/ExploreBookListView.swift` | 258 | 38 | 0 | 已清零逻辑 |
| `Sources/LegadoCore/Engine/RuleTokenizer.swift` | 119 | 23 | 0 | 已清零逻辑 |
| `Sources/LegadoCore/Models/RuleModels.swift` | 157 | 23 | 0 | 已清零逻辑 |
| `Sources/LegadoCore/Utils/JSONPath.swift` | 133 | 23 | 0 | 已清零逻辑 |
| `Sources/LegadoCore/Utils/CryptoUtils.swift` | 28 | 14 | 0 | 已清零逻辑 |
| `Sources/LegadoCore/LegadoCore.swift` | 22 | 6 | 0 | 已清零逻辑 |

逻辑残留口径：`gpl_regions.py --logic`，连续 ≥3 行与上游相同且剔除声明、赋值、括号、`import`、注释、函数签名、`#if` 系列。
字段名与构造参数表属于数据格式契约，不改。

预算只许下调；每批提交前跑 `swift test` 与两种编译条件（`legado.sh check` / `legado.sh store`）。
