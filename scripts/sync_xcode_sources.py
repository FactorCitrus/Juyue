#!/usr/bin/env python3
"""把 Sources/**/*.swift 同步进 Legado.xcodeproj 的 LegadoApp target。

工程用的是显式文件列表（PBXFileReference + PBXBuildFile + PBXSourcesBuildPhase），
不是 SPM 的 glob，所以新增源文件必须同时挂四处，否则编译到引用处才报
"cannot find ... in scope"。

用法：
  scripts/sync_xcode_sources.py            # 补齐缺失
  scripts/sync_xcode_sources.py --check    # 只报缺口，非零退出
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PBX = ROOT / "Legado.xcodeproj" / "project.pbxproj"
ANCHOR_FILE_REF = "7560F3034B738FD64AA2D8E9"  # Sources/LegadoApp/LegadoApp.swift


def stable_id(seed: str, taken: set) -> str:
    n = 0
    while True:
        raw = hashlib.md5(f"{seed}#{n}".encode()).hexdigest().upper()[:24]
        if raw not in taken:
            return raw
        n += 1


def main() -> int:
    check = "--check" in sys.argv
    text = PBX.read_text()
    disk = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "Sources").rglob("*.swift"))
    present = set(re.findall(r"<string>(Sources/[^<]+\.swift)</string>", text))
    missing = [p for p in disk if p not in present]
    if not missing:
        print("in sync: %d swift files" % len(disk))
        return 0
    print("missing %d file(s):" % len(missing))
    for p in missing:
        print("  " + p)
    if check:
        return 1

    taken = set(re.findall(r"<key>([0-9A-F]{24})</key>", text))
    refs, builds = [], []          # (id, obj_text)
    for path in missing:
        ref = stable_id("ref:" + path, taken); taken.add(ref)
        bld = stable_id("build:" + path, taken); taken.add(bld)
        refs.append((ref, (
            f"\t\t<key>{ref}</key>\n\t\t<dict>\n"
            f"\t\t\t<key>isa</key>\n\t\t\t<string>PBXFileReference</string>\n"
            f"\t\t\t<key>lastKnownFileType</key>\n\t\t\t<string>sourcecode.swift</string>\n"
            f"\t\t\t<key>path</key>\n\t\t\t<string>{path}</string>\n"
            f"\t\t\t<key>sourceTree</key>\n\t\t\t<string>&lt;group&gt;</string>\n\t\t</dict>")))
        builds.append((bld, (
            f"\t\t<key>{bld}</key>\n\t\t<dict>\n"
            f"\t\t\t<key>fileRef</key>\n\t\t\t<string>{ref}</string>\n"
            f"\t\t\t<key>isa</key>\n\t\t\t<string>PBXBuildFile</string>\n\t\t</dict>")))

    # 1. objects 段开头插入对象定义（plist 顺序无关）
    m0 = list(re.finditer(r"^\t<key>objects</key>\n\t<dict>\n", text, re.M))
    assert len(m0) == 1, "objects anchor not unique"
    blob = "\n".join([t for _, t in refs] + [t for _, t in builds])
    text = text[: m0[0].end()] + blob + "\n" + text[m0[0].end():]

    # 2. Sources 阶段 files 数组末尾追加 buildFile id
    pat = re.compile(r"(<key>files</key>\n\t\t\t<array>\n)((?:[^\n]*\n)*?)(\t\t\t</array>\n\t\t\t<key>isa</key>\n\t\t\t<string>PBXSourcesBuildPhase</string>)")
    m = pat.search(text)
    assert m, "PBXSourcesBuildPhase files array not found"
    text = text[: m.end(2)] + "".join(f"\t\t\t\t<string>{i}</string>\n" for i, _ in builds) + text[m.end(2):]

    # 3. 主 group children：只改含 LegadoApp.swift 的那个数组
    gpat = re.compile(r"(<key>children</key>\n\t\t\t<array>\n)((?:[^\n]*\n)*?)(\t\t\t</array>)")
    done = False
    for gm in gpat.finditer(text):
        if ANCHOR_FILE_REF in gm.group(2):
            text = text[: gm.end(2)] + "".join(f"\t\t\t\t<string>{i}</string>\n" for i, _ in refs) + text[gm.end(2):]
            done = True
            break
    if not done:
        print("warn: main group children not found, skipped (compile unaffected)")

    PBX.write_text(text)
    print("patched: %d file(s)" % len(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
