#!/usr/bin/env python3
"""GPL 残留定位：把每个文件里与上游基线连续相同的段落切成可重写的工单。

与 gpl_audit.py 的区别：审计按「逐行相同」计数，`}`、`import Foundation` 这类
单行碎片会污染指标；本脚本按连续长度过滤，>=3 行才算实质残留，并给出我方行号
区间，方便按函数重写。

用法:
  python3 scripts/gpl_regions.py                     # 打印摘要 + 前 N 个文件
  python3 scripts/gpl_regions.py --file <path>        # 打印单文件工单
  python3 scripts/gpl_regions.py --md <out.md>        # 写整份工单
  python3 scripts/gpl_regions.py --check --budget 0   # 实质残留超标则退出 1
"""
import argparse
import difflib
import subprocess
import sys

DEFAULT_BASELINE = "d21903c"
MIN_RUN = 3


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "git failed")
    return r.stdout


def hunks_for(repo, baseline, path):
    old = git(repo, "show", f"{baseline}:{path}").splitlines()
    new = open(f"{repo}/{path}", encoding="utf-8", errors="replace").read().splitlines()
    sm = difflib.SequenceMatcher(None, old, new, autojunk=False)
    out = []
    for block in sm.get_matching_blocks():
        if block.size >= MIN_RUN:
            start = block.b + 1
            out.append({
                "start": start,
                "end": block.b + block.size,
                "size": block.size,
                "upstream_start": block.a + 1,
                "preview": new[block.b].strip()[:100],
            })
    return out, len(new)


def collect(repo, baseline):
    tracked = [f for f in git(repo, "ls-tree", "-r", "--name-only", "HEAD").splitlines()
               if f.endswith(".swift") and f.startswith("Sources/")]
    base_set = set(git(repo, "ls-tree", "-r", "--name-only", baseline).splitlines())
    rows = []
    for path in tracked:
        if path not in base_set:
            continue
        hunks, total = hunks_for(repo, baseline, path)
        if hunks:
            rows.append({"path": path, "lines": total,
                         "residue": sum(h["size"] for h in hunks), "hunks": hunks})
    rows.sort(key=lambda r: r["residue"], reverse=True)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".")
    ap.add_argument("--baseline", default=DEFAULT_BASELINE)
    ap.add_argument("--file", default=None)
    ap.add_argument("--md", default=None)
    ap.add_argument("--top", type=int, default=20)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--budget", type=int, default=0)
    args = ap.parse_args()
    try:
        git(args.repo, "rev-parse", args.baseline)
    except RuntimeError:
        print(f"baseline '{args.baseline}' not found", file=sys.stderr)
        return 2

    rows = collect(args.repo, args.baseline)
    total = sum(r["residue"] for r in rows)
    hunks_total = sum(len(r["hunks"]) for r in rows)

    if args.file:
        row = next((r for r in rows if r["path"] == args.file), None)
        if not row:
            print(f"{args.file}: no substantive residue")
            return 0
        print(f"{row['path']} | lines {row['lines']} | residue {row['residue']} | hunks {len(row['hunks'])}")
        for h in row["hunks"]:
            print(f"  {h['start']:5d}-{h['end']:5d} ({h['size']:3d})  upstream:{h['upstream_start']:5d}  {h['preview']}")
        return 0

    if args.check:
        print(f"substantive residue (runs>={MIN_RUN}): {total} lines / {hunks_total} hunks / {len(rows)} files")
        print(("PASS" if total <= args.budget else "FAIL") + f": {total} <= budget {args.budget}")
        return 0 if total <= args.budget else 1

    print(f"substantive residue (runs>={MIN_RUN}): {total} lines | {hunks_total} hunks | {len(rows)} files")
    print(f"{'residue':>8}  {'lines':>6}  {'hunks':>5}  file")
    for r in rows[: args.top]:
        print(f"{r['residue']:8d}  {r['lines']:6d}  {len(r['hunks']):5d}  {r['path']}")

    if args.md:
        with open(args.md, "w", encoding="utf-8") as fh:
            fh.write("# GPL 重写工单（实质残留 >=3 行连续相同）\n\n")
            fh.write(f"基线 `{args.baseline}`｜实质残留 **{total}** 行｜{hunks_total} 段｜{len(rows)} 文件\n\n")
            for r in rows:
                fh.write(f"## {r['path']}（{r['residue']} / {r['lines']} 行，{len(r['hunks'])} 段）\n\n")
                fh.write("| 我方行号 | 行数 | 上游起始 | 首行 |\n|---|---|---|---|\n")
                for h in r["hunks"]:
                    pv = h["preview"].replace("|", "\\|")
                    fh.write(f"| {h['start']}–{h['end']} | {h['size']} | {h['upstream_start']} | `{pv}` |\n")
                fh.write("\n")
        print(f"wrote {args.md}")
    return 0


sys.exit(main())
