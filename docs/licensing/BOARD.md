# 重写看板（upstream-free）

基线 `d21903c`；当前存活上游 **8085** 行 / 32 个文件。目标 0，命令：`python3 scripts/gpl_audit.py --strict`。

## 用户指定待办

- [x] **侧载版主题在商店版可用**（2026-10-25 核实）：统一源码后主题从未被 `isAppStoreClean` 拦截。`Sources/LegadoApp/Views/NieRTheme.swift`（252 行）与 `Sources/LegadoApp/Theme/ReaderConfig.swift`（1578 行）全量编入商店包；`JuyueReader` 二进制内含 `NieRBackdrop / NieRBadge / NieRDivider / NieRPalette / NieRPanel / NieRScanBar / NieRSectionTitle / NieRSheetHeader` 八个组件符号与「复古羊皮纸 / 护眼绿 / 夜间暗黑」三个主题名，而「换源」出现 0 次（gate 生效）。旧 `appstore-clean` 树删掉的 `NieRTheme.swift` + ReaderConfig 558 行，在单一源码方案下自动回归。**余项**：真机 UI 走查确认视觉与侧载版一致。
- [ ] **段评 UI 入口 gate**：`BookshelfView:244/335`、`ReaderView:1157/1174/2781/2831/5486`。目前只拦截解析层（`extractReviewMarkers`），商店二进制里仍能搜到「段评」文案，属于审核面残留。

| 阶段 | 文件 | 行数 | 存活上游 | 占比 | 状态 |
|---|---|---:|---:|---:|---|
| P2 内核 | `Sources/LegadoCore/Engine/RuleAnalyzer.swift` | 482 | 397 | 82% | 待做 |
| P2 内核 | `Sources/LegadoCore/Engine/JSEngine.swift` | 924 | 295 | 32% | 待做 |
| P2 内核 | `Sources/LegadoCore/Models/RuleModels.swift` | 288 | 207 | 72% | 待做 |
| P2 内核 | `Sources/LegadoCore/Models/Book.swift` | 293 | 191 | 65% | 待做 |
| P2 内核 | `Sources/LegadoCore/Models/BookSource.swift` | 302 | 157 | 52% | 待做 |
| P2 内核 | `Sources/LegadoCore/Engine/RuleTokenizer.swift` | 119 | 23 | 19% | 已重写（余 23） |
| P3 核心服务 | `Sources/LegadoCore/Service/WebDAVService.swift` | 801 | 182 | 23% | 已重写（余 182） |
| P3 核心服务 | `Sources/LegadoCore/Service/BookContentService.swift` | 1708 | 356 | 21% | 待做 |
| P3 核心服务 | `Sources/LegadoCore/Service/BookSearchService.swift` | 339 | 175 | 52% | 待做 |
| P3 核心服务 | `Sources/LegadoCore/Service/BookExploreService.swift` | 300 | 172 | 57% | 待做 |
| P3 核心服务 | `Sources/LegadoCore/Service/NetworkClient.swift` | 226 | 167 | 74% | 待做 |
| P3 核心服务 | `Sources/LegadoCore/Service/EpubParser.swift` | 449 | 64 | 14% | 已重写（余 64） |
| P4 应用服务 | `Sources/LegadoApp/Services/BookStore.swift` | 1475 | 470 | 32% | 待做 |
| P4 应用服务 | `Sources/LegadoApp/Services/SearchViewModel.swift` | 283 | 143 | 51% | 待做 |
| P4 应用服务 | `Sources/LegadoApp/Services/AudioBookService.swift` | 668 | 124 | 19% | 待做 |
| P5 界面 | `Sources/LegadoApp/Views/Reader/ReaderView.swift` | 9795 | 1709 | 17% | 待做 |
| P5 界面 | `Sources/LegadoApp/Views/BookDetailView.swift` | 1190 | 541 | 45% | 待做 |
| P5 界面 | `Sources/LegadoApp/Views/WebDAVSyncView.swift` | 577 | 196 | 34% | 已重写（余 196） |
| P5 界面 | `Sources/LegadoApp/Views/CategoryExploreView.swift` | 1011 | 444 | 44% | 待做 |
| P5 界面 | `Sources/LegadoApp/Views/SourceManagerView.swift` | 1390 | 431 | 31% | 待做 |
| P5 界面 | `Sources/LegadoApp/Views/SourceWebLoginView.swift` | 511 | 380 | 74% | 待做 |
| P5 界面 | `Sources/LegadoApp/Views/SourceDetailView.swift` | 617 | 333 | 54% | 待做 |
| P5 界面 | `Sources/LegadoApp/Views/SearchBookView.swift` | 569 | 270 | 47% | 待做 |
| P5 界面 | `Sources/LegadoApp/Views/BookshelfView.swift` | 1667 | 217 | 13% | 待做 |
| P5 界面 | `Sources/LegadoApp/Views/ExploreBookListView.swift` | 205 | 202 | 99% | 待做 |
| P5 界面 | `Sources/LegadoApp/Views/SettingsView.swift` | 4955 | 58 | 1% | 待做 |
| P5 界面 | `Sources/LegadoApp/Views/EditSourceSheet.swift` | 800 | 39 | 5% | 待做 |
| 收尾 | `Sources/LegadoApp/LegadoApp.swift` | 532 | 55 | 10% | 待做 |
| 收尾 | `Sources/LegadoApp/Theme/ReaderConfig.swift` | 1578 | 44 | 3% | 待做 |
| 收尾 | `Sources/LegadoCore/Utils/JSONPath.swift` | 133 | 23 | 17% | 已重写（余 23） |
| 收尾 | `Sources/LegadoCore/Utils/CryptoUtils.swift` | 28 | 14 | 50% | 已重写（余 14） |
| 收尾 | `Sources/LegadoCore/LegadoCore.swift` | 22 | 6 | 27% | 待做 |

预算只许下调；每批提交前跑 `swift test` 与两种编译条件。
