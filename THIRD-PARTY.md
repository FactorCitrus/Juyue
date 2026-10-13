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
  随包预置的 `Sources/LegadoApp/Resources/bookSources.json` 含 2 条书源（示例书源、示例书源），
  来源于公开分享，属第三方内容 —— 来源与再分发许可**未核实**，随包发布前请确认。

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

## 6. 来源扫描结论（2026-10-13）

- 仓库 49 个 Swift 文件、21110 行，均为自写代码；带 `Copyright` / `SPDX` / `GPL` / `MIT` 等外部版权头的 Swift 文件：0 个。
- 非 Swift 代码文件仅三类：`moveable.min.js`（第三方，MIT）、`ChapterTitleDesigner/designer.js|css`（自写）、`Vendor/BaiduSpeech/include/*.h`（百度 SDK 头文件）。
- 全仓无 Java/Kotlin 文件，即未搬入 gedoor/legado 及其分支的源码。
- 提交作者统计：`Codex` 24 / `FactorCitrus` 11 / `baseline` 1，全部为本地提交。
- **未执行**：与外部仓库的逐行相似度比对（需 `jscpd`、simian 等工具或人工抽查）。
