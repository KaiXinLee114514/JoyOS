#!/usr/bin/env python3
"""mkpinyin.py — 生成 PINYIN.BIN(输入法用的"常用字 → 单字拼音"表)

数据来源:
  · wordfreq 取中文里最常用的字(按频次排序 → 候选顺序,最常用排最前)
  · pypinyin 取每个字的读音(单字、不带声调)

二进制格式(小端):
    0   "PIME"
    4   u32 音节个数 nsyll
    8   u32 字条目个数 nchar
    12  音节表:nsyll × 8 字节(ASCII,补 0)
    12+nsyll*8  字条目:nchar × 5 字节 = [2 字节音节号][3 字节 UTF-8 汉字]

内核侧(ime.asm)会把它读进内存,靠"音节号"把同音的常用字凑成一排候选。
"""
import struct
import sys

try:
    from wordfreq import top_n_list
    from pypinyin import pinyin, Style
except ImportError:
    sys.exit("需要 pypinyin 和 wordfreq:pip install pypinyin wordfreq")

want = int(sys.argv[1]) if len(sys.argv) > 1 else 3500
out = sys.argv[2] if len(sys.argv) > 2 else "build/PINYIN.BIN"

# top_n_list 里混着词(比如"中国"),这里只要单字
chars_all = [c for c in top_n_list("zh", want * 8)
             if len(c) == 1 and "\u4e00" <= c <= "\u9fff"]
by_syl, syls = {}, []
for ch in chars_all:
    if len(by_syl) and sum(len(v) for v in by_syl.values()) >= want:
        break
    if any(ch in v for v in by_syl.values()):
        continue
    try:
        syl = pinyin(ch, style=Style.NORMAL, heteronym=False)[0][0]
    except Exception:
        continue
    if not syl.isascii() or not syl.isalpha() or not (1 <= len(syl) <= 7):
        continue
    if syl not in by_syl:
        by_syl[syl] = []
        syls.append(syl)
    by_syl[syl].append(ch)

syls.sort()
idx = {s: i for i, s in enumerate(syls)}
entries = []
for s in syls:
    for ch in by_syl[s]:
        entries.append((idx[s], ch.encode("utf-8")))

if len(syls) > 65535:
    sys.exit("音节太多:%d" % len(syls))

blob = b"PIME" + struct.pack("<II", len(syls), len(entries))
for s in syls:
    blob += s.encode("ascii").ljust(8, b"\0")[:8]
for si, utf8 in entries:
    if len(utf8) != 3:
        continue
    blob += struct.pack("<H", si) + utf8

open(out, "wb").write(blob)
print("PINYIN.BIN: %d 个音节, %d 个常用字, %d 字节" % (len(syls), len(entries), len(blob)))
