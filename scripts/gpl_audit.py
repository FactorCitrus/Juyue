#!/usr/bin/env python3
"""GPL 剥离审计：逐文件比对当前树与上游基线，统计仍存活的上游代码行。

默认统计逐行重合；加 --substantive 时忽略空行、纯括号、import 与
#if/#endif 这类无法体现表达重合的样板行。

用法:
  python3 scripts/gpl_audit.py --repo app/Juyue [--baseline d21903c] [--top 30]
  python3 scripts/gpl_audit.py --repo app/Juyue --substantive --budget 0
  python3 scripts/gpl_audit.py --repo app/Juyue --substantive --strict
退出码: 0 达标；1 超标；2 环境错误。
"""
import argparse
import difflib
import json
import re
import subprocess
import sys

DEFAULT_BASELINE = "d21903c"
TRIVIAL_LINES = {"{", "}", "};", "});", ")]", "},", ")", "]", "#endif", "#else", "#"}
# 数据模型字段、CodingKeys 与初始化签名属于书源/备份/JSON 格式契约，
# 按 docs/licensing/EXIT-PLAN.md 的定义不算上游代码依赖。
CONTRACT_PREFIX = "Sources/JuyueCore/Models/"


def is_trivial(line):
    text = line.strip()
    if not text:
        return True
    if text in TRIVIAL_LINES:
        return True
    if text.startswith("import ") or text.startswith("#if "):
        return True
    return bool(re.fullmatch(r"[{}()\[\],;:.]+", text))


def is_public_api(line):
    text = line.strip()
    return text.startswith((
        "public ", "@Published public", "open ", "@objc public",
        "public static", "public init", "public func", "public var",
        "public let", "public struct", "public class", "public enum",
        "public protocol", "public typealias", "public extension",
    ))


def current_path(path):
    """上游基线路径 → 改名后的工作树路径。"""
    return (path
            .replace("Sources/LegadoApp/LegadoApp.swift", "Sources/JuyueApp/JuyueApp.swift")
            .replace("Sources/LegadoCore/LegadoCore.swift", "Sources/JuyueCore/JuyueCore.swift")
            .replace("Sources/LegadoApp/", "Sources/JuyueApp/")
            .replace("Sources/LegadoCore/", "Sources/JuyueCore/")
            .replace("Tests/LegadoCoreTests/", "Tests/JuyueCoreTests/"))


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
    ap.add_argument("--substantive", action="store_true",
                    help="只统计非样板行（空行/括号/import/#if 不计）")
    ap.add_argument("--logic", action="store_true",
                    help="在 substantive 基础上排除 Models/ 下的数据格式契约")
    ap.add_argument("--logic-only", action="store_true",
                    help="在 logic 基础上再排除 public API 声明")
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--json", default=None, help="把逐文件结果写成 JSON（做棘轮预算用）")
    args = ap.parse_args()

    try:
        git(args.repo, "rev-parse", args.baseline)
    except RuntimeError:
        print(f"baseline '{args.baseline}' not found in {args.repo}", file=sys.stderr)
        return 2

    tracked = set(git(args.repo, "ls-files").splitlines())
    base_set = set(git(args.repo, "ls-tree", "-r", "--name-only", args.baseline).splitlines())

    rows = []
    for old_path in sorted(base_set):
        if not old_path.endswith(".swift") or not old_path.startswith("Sources/"):
            continue
        path = current_path(old_path)
        if path not in tracked:
            continue
        try:
            old = git(args.repo, "show", f"{args.baseline}:{old_path}").splitlines()
        except RuntimeError:
            continue
        with open(f"{args.repo}/{path}", encoding="utf-8", errors="replace") as fh:
            new = fh.read().splitlines()
        matcher = difflib.SequenceMatcher(None, old, new, autojunk=False)
        same = sum(block.size for block in matcher.get_matching_blocks())
        substantive = sum(
            1
            for block in matcher.get_matching_blocks()
            for line in new[block.b:block.b + block.size]
            if not is_trivial(line)
        )
        api = sum(
            1
            for block in matcher.get_matching_blocks()
            for line in new[block.b:block.b + block.size]
            if not is_trivial(line) and is_public_api(line)
        )
        rows.append({"path": path, "lines": len(new), "upstream": same,
                     "substantive": substantive, "api": api,
                     "logicOnly": substantive - api,
                     "contract": path.startswith(CONTRACT_PREFIX),
                     "ratio": same / max(1, len(new))})

    logic_rows = [r for r in rows if not r["contract"]]
    total_logic = sum(r["substantive"] for r in logic_rows)
    total_logic_only = sum(r["logicOnly"] for r in logic_rows)
    total_api = sum(r["api"] for r in logic_rows)
    if args.logic_only:
        rows = logic_rows
        metric = "logicOnly"
    elif args.logic:
        rows = logic_rows
        metric = "substantive"
    else:
        metric = "substantive" if args.substantive else "upstream"
    rows.sort(key=lambda r: r[metric], reverse=True)
    total_raw = sum(r["upstream"] for r in rows)
    total_substantive = sum(r["substantive"] for r in rows)
    if args.logic_only:
        total = total_logic_only
    elif args.logic:
        total = total_logic
    elif args.substantive:
        total = total_substantive
    else:
        total = total_raw
    untouched = [r for r in rows if r["lines"] == r["upstream"]]

    print(f"baseline {args.baseline} | files compared {len(rows)} | "
          f"surviving upstream lines {total_raw} (substantive {total_substantive}, "
          f"logic {total_logic}, logic-only {total_logic_only}, api {total_api})")
    print(f"{'upstream':>9}  {'subst':>6}  {'lines':>6}  {'ratio':>6}  file")
    for r in rows[: args.top]:
        print(f"{r['upstream']:9d}  {r['substantive']:6d}  {r['lines']:6d}  "
              f"{r['ratio']*100:5.1f}%  {r['path']}")
    if untouched:
        print(f"\nuntouched (100% upstream): {len(untouched)}")
        for r in untouched[:10]:
            print(f"  {r['path']}")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"baseline": args.baseline, "total": total_raw,
                       "substantive": total_substantive, "files": rows}, fh,
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
