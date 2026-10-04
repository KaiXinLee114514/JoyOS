#!/usr/bin/env python3
"""
从完整的 Unifont .hex 里抽出本项目要用的字形,生成 font/unifont-subset.hex。

为什么要抽子集:完整字库 8 MB(压缩 1.7 MB),而项目只用到 400 来个字形;
抽出来只有 20 多 KB,可以直接入库,`make font` 也就不用联网了。

用法: python3 tools/mkfontsubset.py <完整.hex> [输出.hex] [字符表.txt]
字符来源: font/charset.txt(文本模式实验)、font/strings.txt(界面文案)、
          font/charset-cjk.txt(常用字)、font/charset-extra.txt(替换字符/emoji)
"""
import pathlib
import sys

SOURCES = ["font/charset.txt", "font/strings.txt", "font/charset-cjk.txt", "font/charset-extra.txt"]


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    full = pathlib.Path(sys.argv[1])
    out_subset = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else pathlib.Path("font/unifont-subset.hex")
    out_chars = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else pathlib.Path("font/charset-all.txt")

    need = set(range(0x20, 0x7F))              # ASCII 可打印区
    text = ""
    for src in SOURCES:
        if not pathlib.Path(src).exists():
            continue
        data = pathlib.Path(src).read_text(encoding="utf-8")
        text += data
        for ch in data:
            if not ch.isspace():
                need.add(ord(ch))

    lines = []
    with full.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            cp = line.split(":", 1)[0]
            if cp and int(cp, 16) in need:
                lines.append(line.rstrip("\n"))
    out_subset.write_text("\n".join(lines) + "\n", encoding="utf-8")

    uniq = sorted({c for c in text if not c.isspace() and ord(c) > 0x7F}, key=ord)
    out_chars.write_text("".join(uniq), encoding="utf-8")

    have = {int(l.split(":", 1)[0], 16) for l in lines}
    missing = sorted(need - have)
    print(f"字形 {len(lines)} 个 → {out_subset}")
    if missing:
        print(f"⚠️  字库里没有这些码位: {[hex(c) for c in missing[:10]]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
