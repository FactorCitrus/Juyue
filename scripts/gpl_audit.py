#!/usr/bin/env python3
"""GPL 剥离审计：逐文件比对当前树与上游基线，统计仍存活的上游代码行。

用法:
  python3 scripts/gpl_audit.py --repo app/Juyue [--baseline d21903c] [--top 30]
  python3 scripts/gpl_audit.py --repo app/Juyue --budget 4000   # 只允许 4000 行以内
  python3 scripts/gpl_audit.py --repo app/Juyue --strict         # 任何残留即失败
退出码: 0 达标；1 超标；2 环境错误。
"""
import argparse
import difflib
import json
import subprocess
import sys

DEFAULT_BASELINE = "d21903c"


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "git failed")
    return r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".")
    ap.add_argument("--baseline", default=DEFAULT_BASELINE)
    ap.add_argument("--budget", type=int, default=None,
                    help="允许存活的上游行数上限")
    ap.add_argument("--strict", action="store_true", help="要求 0 残留")
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--json", default=None, help="把逐文件结果写成 JSON（做棘轮预算用）")
    args = ap.parse_args()

    try:
        git(args.repo, "rev-parse", args.baseline)
    except RuntimeError:
        print(f"baseline '{args.baseline}' not found in {args.repo}", file=sys.stderr)
        return 2

    tracked = git(args.repo, "ls-tree", "-r", "--name-only", "HEAD").splitlines()
    candidates = [f for f in tracked if f.endswith(".swift") and f.startswith("Sources/")]
    base_set = set(git(args.repo, "ls-tree", "-r", "--name-only", args.baseline).splitlines())

    rows = []
    for path in candidates:
        if path not in base_set:
            continue
        try:
            old = git(args.repo, "show", f"{args.baseline}:{path}").splitlines()
        except RuntimeError:
            continue
        with open(f"{args.repo}/{path}", encoding="utf-8", errors="replace") as fh:
            new = fh.read().splitlines()
        matcher = difflib.SequenceMatcher(None, old, new, autojunk=False)
        same = sum(block.size for block in matcher.get_matching_blocks())
        rows.append({"path": path, "lines": len(new), "upstream": same,
                     "ratio": same / max(1, len(new))})

    rows.sort(key=lambda r: r["upstream"], reverse=True)
    total = sum(r["upstream"] for r in rows)
    untouched = [r for r in rows if r["lines"] == r["upstream"]]

    print(f"baseline {args.baseline} | files compared {len(rows)} | surviving upstream lines {total}")
    print(f"{'upstream':>9}  {'lines':>6}  {'ratio':>6}  file")
    for r in rows[: args.top]:
        print(f"{r['upstream']:9d}  {r['lines']:6d}  {r['ratio']*100:5.1f}%  {r['path']}")
    if untouched:
        print(f"\nuntouched (100% upstream): {len(untouched)}")
        for r in untouched[:10]:
            print(f"  {r['path']}")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"baseline": args.baseline, "total": total, "files": rows}, fh,
                      ensure_ascii=False, indent=2)
        print(f"\nwrote {args.json}")

    limit = 0 if args.strict else args.budget
    if limit is not None and total > limit:
        print(f"\nFAIL: {total} > budget {limit}")
        return 1
    if limit is not None:
        print(f"\nPASS: {total} <= budget {limit}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
