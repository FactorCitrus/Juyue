
## 模拟器验收

每次完成代码修改后，必须构建并安装到当前已启动的 iOS 模拟器，再启动 App，交给用户手动测试。完成后报告版本号、Bundle ID 和模拟器名称。

## 发布快线（2026-10-23 落地，省时间用）

工作区根目录 `/Volumes/APFS/legado-build` 的 `scripts/legado.sh` 是唯一入口：

| 场景 | 命令 |
|---|---|
| 改完代码 | `scripts/legado.sh check`（编模拟器，自动换/还原百度库） |
| 想验某一块 | `scripts/legado.sh test ScriptBrowser`（`--filter`，只跑匹配的） |
| 出测试包 | `scripts/legado.sh pkg 5.0.3` → `outputs/` + `.sha256` |
| 推 git | `scripts/legado.sh push`（pull --rebase + push + 打印 run id） |
| 全套 | `scripts/legado.sh release 5.0.3` |

纪律：

- 本地**不跑全量 `swift test`**，全量由 CI（Xcode 15.4 / macos-14）跑；本地要跑就带 `--filter`。
- 本地编不过先看是不是缺文件登记（新 `.swift` 必须进 `project.pbxproj`），别先怀疑代码。
- push 后只报 `databaseId + status`，不要 `gh run watch` 干等；CI 红了再 `gh run view <id> --log-failed`。
- 两个 `xcodebuild` 不能并发（共用 DerivedData）；`legado.sh` 已加 `/tmp/legado-legado.lock` 互斥。
- 测试报「函数体字符串 != 正文」这类断言差异，先看被测接口的契约（例：`body` 是 `/Volumes/APFS/legado-build/app/Juyue/Sources/LegadoCore/Engine/JSEngine.swift` 里的方法，不是属性），改测试别改实现。

## 技术查证

优先查阅 Apple 官方文档、Xcode Release Notes 和 WWDC 资料，再看开源实现与社区文章。
