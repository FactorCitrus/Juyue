#!/usr/bin/env python3
"""Create a simulator-only local TXT book with hot-review and illustration markers."""

import base64
import hashlib
import json
import plistlib
import struct
import sys
import zlib
from pathlib import Path


def png_bytes(width: int, height: int) -> bytes:
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend((30 + x * 180 // width, 70 + y * 120 // height, 190))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(
            ">I", zlib.crc32(kind + data) & 0xFFFFFFFF
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
        + chunk(b"IEND", b"")
    )


def b64(value: str) -> str:
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def marker(kind: str, fields: list[str]) -> str:
    return "\ue000" + kind + "\x1f" + "\x1f".join(fields) + "\ue001"


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: make_hot_review_test_book.py <app-data-dir>")

    app_data = Path(sys.argv[1])
    book_url = "txt://juyue-hot-review-test"
    book_id = hashlib.md5(book_url.encode("utf-8")).hexdigest()
    chapter_dir = app_data / "Books" / "TXT" / book_id
    chapter_dir.mkdir(parents=True, exist_ok=True)

    illustration = app_data / "Documents" / "hot-review-illustration.png"
    illustration.write_bytes(png_bytes(600, 300))
    chapter_illustration = app_data / "Documents" / "chapter-illustration.png"
    chapter_illustration.write_bytes(png_bytes(720, 360))

    comment_url = (
        "http://219.154.201.122:5006/get_para_review?"
        "book_id=NzE0MzAzODY5MTk0NDk1OTAxMQ&ssionid=&item_id=7178851502831141431"
        "&para=0&source=%E7%95%AA%E8%8C%84"
    )
    comment_url_1 = comment_url.replace("para=0", "para=1")
    chapter_comment_url = (
        "http://219.154.201.122:5006/fanqie_comment?mode=chapter"
        "&book_id=NzE0MzAzODY5MTk0NDk1OTAxMQ&item_id=7176601374652793396"
        "&source=%E7%95%AA%E8%8C%84&tab=%E5%B0%8F%E8%AF%B4&ssionid=&cache=1"
    )

    text_review = marker(
        "G",
        [
            b64("这条热评带插图，翻页模式都能看到。"),
            comment_url,
            b64(illustration.as_uri()),
        ],
    )
    text_review_2 = marker(
        "G",
        [
            b64("第二条热评：文字卡片。"),
            comment_url_1,
            b64(""),
        ],
    )
    comment_badge = marker("C", ["12", comment_url])
    chapter_entry = marker("H", [chapter_comment_url])

    chapter_text = "\n".join(
        [
            "热评测试",
            "这是一本模拟器专用测试书，用来检查大灰狼热评、段评和插图。",
            "第一段正文。这里有一个段评气泡。" + comment_badge,
            text_review + text_review_2,
            "第二段正文。继续翻页检查热评卡片。",
            "[image:" + chapter_illustration.as_uri() + "]",
            "第三段正文。这里挂本章说入口。" + chapter_entry,
            "第四段正文。所有翻页模式都应能显示热评卡片和插图。",
        ]
    )
    chapter_path = chapter_dir / "chapter_0.txt"
    chapter_path.write_text(chapter_text, encoding="utf-8")

    chapters = [
        {
            "bookUrl": book_url,
            "url": chapter_path.as_uri(),
            "title": "热评测试",
            "index": 0,
            "isVip": False,
        }
    ]
    (app_data / "Documents" / f"chapters_{book_id}.json").write_text(
        json.dumps(chapters, ensure_ascii=False), encoding="utf-8"
    )

    prefs_path = app_data / "Library" / "Preferences" / "com.factorcitrus.juyue.plist"
    with prefs_path.open("rb") as handle:
        prefs = plistlib.load(handle)
    books = json.loads(prefs["legado_bookshelf_v1"].decode("utf-8"))
    books = [book for book in books if book.get("bookUrl") != book_url]
    books.insert(
        0,
        {
            "bookUrl": book_url,
            "name": "热评测试",
            "author": "本地书籍",
            "kind": "TXT 本地书籍",
            "intro": "模拟器专用：热评、段评、插图",
            "origin": "local",
            "originName": "本地导入",
            "tocUrl": "",
            "totalChapterNum": 1,
            "durChapterIndex": 0,
            "durChapterPos": 0,
            "durChapterTitle": "热评测试",
        },
    )
    prefs["legado_bookshelf_v1"] = json.dumps(books, ensure_ascii=False).encode("utf-8")
    with prefs_path.open("wb") as handle:
        plistlib.dump(prefs, handle, fmt=plistlib.FMT_BINARY)

    print(f"book_url={book_url}")
    print(f"chapter={chapter_path}")
    print(f"hot_review_image={illustration}")
    print(f"chapter_image={chapter_illustration}")
    print(f"book_count={len(books)}")


if __name__ == "__main__":
    main()
