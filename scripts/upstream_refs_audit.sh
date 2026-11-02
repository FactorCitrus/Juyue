#!/usr/bin/env bash
# 上游残留审计：代码之外还要断历史、断远程、断品牌。
# 用法: scripts/upstream_refs_audit.sh [repo] [report|strict]
set -uo pipefail

REPO="${1:-.}"
MODE="${2:-report}"
FAIL=0

say() { printf '%-8s %s\n' "$1" "$2"; }
bad() { say "FAIL" "$1"; FAIL=$((FAIL+1)); }
warn() { say "WARN" "$1"; }
ok() { say "PASS" "$1"; }

echo "== repo: $REPO ($MODE)"

# 1. 远程
remotes=$(git -C "$REPO" remote -v 2>/dev/null)
if printf '%s' "$remotes" | grep -qi 'SeitoMoyi\|/Legado-iOS'; then
  bad "remote 仍指向上游/旧仓库"
elif [ -n "$remotes" ]; then
  ok "remote 只有自有仓库"
else
  warn "没有 remote（新仓库尚未接远程）"
fi

# 2. 历史
if git -C "$REPO" cat-file -e 'd21903c^{commit}' 2>/dev/null; then
  warn "历史里仍能到上游基线 d21903c（最终仓库必须换新历史）"
  [ "$MODE" = strict ] && FAIL=$((FAIL+1))
else
  ok "历史里没有上游基线"
fi

# 3. 源码里的上游标识
if git -C "$REPO" grep -InE 'SeitoMoyi|gedoor|github\.com/[^ ]*/Legado-iOS' -- Sources Tests Package.swift 2>/dev/null | head -20; then
  bad "源码里存在上游作者/仓库字样"
else
  ok "源码无上游作者/仓库字样"
fi

# 4. 模块与产品名
if git -C "$REPO" grep -InE 'LegadoCore|LegadoApp|name: "Legado"' -- Sources Tests Package.swift 2>/dev/null | head -10; then
  warn "仍有 Legado 模块/产品名（最终阶段要改名）"
  [ "$MODE" = strict ] && FAIL=$((FAIL+1))
else
  ok "无 Legado 模块/产品名"
fi

# 5. 存储键
if git -C "$REPO" grep -In 'legado\.' -- Sources 2>/dev/null | head -10; then
  warn "仍有 legado.* 存储键（改名要带迁移）"
  [ "$MODE" = strict ] && FAIL=$((FAIL+1))
else
  ok "无 legado.* 存储键"
fi

# 6. 许可证
if [ -f "$REPO/LICENSE" ] && grep -qE 'GNU GENERAL PUBLIC LICENSE|gedoor|Legado  Copyright' "$REPO/LICENSE"; then
  warn "LICENSE 仍是上游 GPL 文本"
  [ "$MODE" = strict ] && FAIL=$((FAIL+1))
else
  ok "LICENSE 不是上游 GPL 文本"
fi

# 7. README / 用户可见文案
if [ -f "$REPO/README.md" ] && grep -qE 'SeitoMoyi|上游|GPL|Legado iOS' "$REPO/README.md"; then
  warn "README 仍写着上游/旧品牌/GPL"
  [ "$MODE" = strict ] && FAIL=$((FAIL+1))
else
  ok "README 无上游残留"
fi

# 8. 第三方依赖（只列，不判）
echo "== dependencies"
grep -nE '\.package\(url:' "$REPO/Package.swift" 2>/dev/null || true

echo
if [ "$MODE" = strict ] && [ "$FAIL" -gt 0 ]; then
  echo "STRICT FAIL: $FAIL 项未清"
  exit 1
fi
echo "report complete: $FAIL 项阻断（report 模式不退出失败）"
