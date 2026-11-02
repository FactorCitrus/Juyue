# 完全剥离上游：出口闸门

“剥离”按四层算，缺一层都不算完：代码行、Git 历史、品牌/模块名、许可证与文档。数据格式兼容（书源规则、WebDAV 备份、RSS JSON）是接口约定，不算上游依赖。

## Gate 1 · 代码归零

```bash
python3 scripts/gpl_audit.py --repo . --strict
swift test
swift build
swift build -Xswiftc -DJUYUE_APPSTORE
```

验收：审计 0 行、全套测试 0 失败、两种编译条件都通过。当前进度见 `BOARD.md`，预算只许下调。

## Gate 2 · 改名

规模（2026-10-25 实测）：62 个文件、199 处 `Legado/Core/App` 标识、6 处 `legado.*` 存储键。

1. 目录与 target：`Sources/LegadoCore` → `Sources/JuyueCore`，`Sources/LegadoApp` → `Sources/JuyueApp`，`Legado.xcodeproj` → `Juyue.xcodeproj`。
2. 代码标识：`LegadoCore` → `JuyueCore`，`LegadoApp` → `JuyueApp`，`LegadoPackageTests` → `JuyuePackageTests`，`name: "Legado"` → `name: "Juyue"`。
3. 存储键：`legado.*` → `juyue.*`，每个键配一次读取旧键的迁移；不能只改字面量。
4. 用户可见字符串：`Legado`/`开源阅读 iOS 版` 从界面、Info.plist、隐私政策、支持页里清掉。
5. 改名后重跑 Gate 1 的全部命令，并额外跑 `scripts/upstream_refs_audit.sh . strict`。

改名是一刀切，不和功能改动混在同一次提交里。

## Gate 3 · 换历史

```bash
# 前提：工作树干净、Gate 1/2 通过
git archive --format=tar HEAD | tar -x -C /path/to/Juyue-iOS-clean
cd /path/to/Juyue-iOS-clean
git init
git add -A
git commit -m "initial: 橘阅 iOS"
git remote add origin <新仓库地址>
```

新仓库不得包含 `d21903c` 及任何上游提交；旧仓库先转 private，确认新仓库两版包都发得出来后再归档。

## Gate 4 · 换许可证与文档

- `LICENSE` 换成自有许可证（商店分发需与 GPL 不冲突；具体选 MIT / Apache-2.0 / 专有由你定）。
- `NOTICE` 只保留第三方库：SwiftSoup（MIT）、ZIPFoundation（MIT）。
- 删除 GPL 全文与上游版权行；不再声称“基于上游继续开发”。
- README 只保留“兼容 Legado/阅读 3.0 数据格式”的接口说明，不出现上游仓库、作者、GPL 授权叙述。
- 隐私政策、支持页、App Store 审核备注同步改写。

## Gate 5 · 出包

```bash
scripts/build_edition.sh sideload archive
scripts/build_edition.sh appstore archive
scripts/appstore_preflight.sh build/Juyue-appstore.xcarchive/Products/Applications/JuyueReader.app
```

两版都从同一提交出包；商店版预检必须全 PASS。

## 回滚

旧仓库保留 tag `v5.0.5` 与 `appstore-clean` 的最后提交，不删除。新仓库任一 Gate 失败，回到旧 tag 出包，不把半成品推上线。
