# 第三方来源与授权清单

本仓库（Legado iOS / 开源阅读 iOS 版）的第三方来源，按类别列出，便于发布前自查。

## 1. 上游工程

- **SeitoMoyi/Legado-iOS** — https://github.com/SeitoMoyi/Legado-iOS — Swift/SwiftUI，GPL-3.0。
  本仓库以它的 **v0.2.0 快照**为起点（见 `VERSION` 与提交 `bf42884 baseline: upstream v0.2.0 snapshot`）。
  按 GPL-3.0：本仓库继续以 GPL-3.0 发布（见 `LICENSE`），对外分发时须一并提供对应源码。
- **gedoor/legado**（安卓原版，GPL-3.0，源码仓库现已停更/撤除）与
  **Luoyacheng/legado-E**（阅读 Sigma，安卓，GPL-3.0）：只做**格式与行为对齐**，未复制其代码。

## 2. 协议与格式

- 书源规则（Legado BookSource JSON）：属**兼容实现**，未复制其规则引擎源码。
  仓库**不预置任何书源**：`Sources/LegadoApp/Resources/bookSources.json` 为空数组 `[]`。
  书源由使用者自行导入，其来源合法性与再分发许可由使用者自行确认。

## 3. 第三方代码

| 组件 | 授权 | 来源 | 位置 |
|---|---|---|---|
| Moveable 0.53.0 | MIT | https://github.com/daybrush/moveable | `Sources/LegadoApp/Resources/ChapterTitleDesigner/moveable.min.js`（文件头已保留版权与许可声明） |
| ZIPFoundation | MIT | https://github.com/weichsel/ZIPFoundation.git | SwiftPM 依赖 |
| SwiftSoup | MIT | https://github.com/scinfu/SwiftSoup.git | SwiftPM 依赖 |

## 4. 设计参考（非代码复制，待确认）

- **栖阅**：`Sources/LegadoApp/Theme/ReaderConfig.swift` 里的设置项结构与排版参数以它为参照，
  注释已逐条标明（`ReaderQuickSettingsPanelKind`、`reader.css` 的 `--reader-align`、`ReadingSettings` 的下划线参数等）。
- **待确认**：`Sources/LegadoApp/Resources/ChapterTitleDesigner/`（`index.html` / `designer.js` / `designer.css`）
  是否为栖阅产物的移植。若来自栖阅，按栖阅的授权处理；无授权则需重写。

## 5. SDK 与商用授权（与开源授权无关）

- **百度离线语音合成 SDK**：`Vendor/BaiduSpeech`（未纳入 git），商用需向百度申请授权。
- **百度音库**：`Sources/LegadoApp/Resources/BaiduTTS/`（未纳入 git），授权同上。

## 6. 上游代码相似度实测（2026-10-25）

用 `scripts/gpl_audit.py` 做逐行比对（`difflib.SequenceMatcher`，基线 `d21903c` 即上游 v0.2.0 快照），
对 `Sources/` 下与上游同名的 32 个 Swift 文件统计仍然逐行一致的行数：

```
$ python3 scripts/gpl_audit.py --repo app/Legado-iOS --top 5
baseline d21903c | files compared 32 | surviving upstream lines 8026
 upstream   lines   ratio  file
     1709    9793   17.5%  Sources/LegadoApp/Views/Reader/ReaderView.swift
      492    1227   40.1%  Sources/LegadoApp/Views/BookDetailView.swift
      469    1475   31.8%  Sources/LegadoApp/Services/BookStore.swift
      397     482   82.4%  Sources/LegadoCore/Engine/RuleAnalyzer.swift
      202     205   98.5%  Sources/LegadoApp/Views/ExploreBookListView.swift
```

**结论：本仓库仍是上游的衍生作品，不是独立实现。** 存活 8026 行，逐文件清单与清账进度见
`docs/licensing/BOARD.md`，预算闸门见 `docs/licensing/upstream-budget.txt`。

**作废的旧结论（2026-10-13）**：当时以「Swift 文件里没有 `Copyright` / `SPDX` / `GPL` 头」判定
「49 个文件、21110 行均为自写代码」。该判据不成立——GPL 工程通常不在每个源文件里放版权头，
头的缺失不能证明来源独立。此结论作废，不得再作为发布依据。

由此确定的三条约束：

- 仓库继续按 GPL-3.0 发布（见 `LICENSE`），对外分发须同时提供对应源码；
- `NOTICE` 保留上游 `SeitoMoyi/Legado-iOS` 的版权声明；
- 与上游的逐行比对**已经执行**（上面命令可复现），不再列为「未执行」。

其余事实维持：全仓无 Java/Kotlin 文件（未搬入安卓版源码）；非 Swift 代码仅
`moveable.min.js`（MIT）、`ChapterTitleDesigner/designer.js|css`（自写，来源待确认见第 4 节）、
`Vendor/BaiduSpeech/include/*.h`（百度 SDK）；提交作者统计（2026-10-13 当时）
`Codex` 24 / `FactorCitrus` 11 / `baseline` 1，全部为本地提交。
**发布前清理（2026-10-14）**：移除预置书源数据、测试中的真实账号凭据与他人本机路径，并重写 Git 历史（`git filter-repo`）。
