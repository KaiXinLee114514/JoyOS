#!/usr/bin/env python3
"""mkpinyin.py — 生成 PINYIN.BIN(输入法用的"常用字 → 单字拼音"表)

数据来源:
  · wordfreq 取中文里最常用的字(按频次排序 → 候选顺序,最常用排最前)
  · pypinyin 取每个字的读音(单字、不带声调)

★ 想要 N 个单字,得从词频表里往前翻得比 N 远得多:中文词频表里一大半是
  "中国"“可以”这种词,单字只占一小片,而且越往后越稀。所以这里先按 N×8 取,
  不够就翻倍再取(见下面的 depth)—— 固定按 N×8 取的话 want=6000 只能凑到
  3700 来个字,候选是多了,但"常用字不够"的抱怨还是没解决。

二进制格式(小端):
    0   "PIME"
    4   u32 音节个数 nsyll
    8   u32 字条目个数 nchar
    12  音节表:nsyll × 8 字节(ASCII,补 0)
    12+nsyll*8  字条目:nchar × 5 字节 = [2 字节音节号][3 字节 UTF-8 汉字]

内核侧(ime.asm)会把它读进内存,靠"音节号"把同音的常用字凑成一排候选。

当前 want=6000 → 约 33 KB(PINYIN_ADDR 到 0x3C0000 之间只有 64 KB,
内核 PINYIN_MAX = 61440)。want 再往上加之前先看生成出来的字节数。
"""
import struct
import sys

try:
    from wordfreq import top_n_list
    from pypinyin import pinyin, Style
except ImportError:
    sys.exit("需要 pypinyin 和 wordfreq:pip install pypinyin wordfreq")

want = int(sys.argv[1]) if len(sys.argv) > 1 else 6000
out = sys.argv[2] if len(sys.argv) > 2 else "build/PINYIN.BIN"

# top_n_list 里混着词(比如"中国"),这里只要单字。
# 取到够 want 个单字为止;词频表取到头了(拿不满 depth)也不再翻倍。
depth = want * 8
while True:
    pool = top_n_list("zh", depth)
    chars_all = [c for c in pool
                 if len(c) == 1 and "\u4e00" <= c <= "\u9fff"]
    if len(chars_all) >= want or len(pool) < depth:
        break
    depth *= 2

by_syl, syls = {}, []
seen = set()
for ch in chars_all:
    if sum(len(v) for v in by_syl.values()) >= want:
        break
    if ch in seen:
        continue
    try:
        syl = pinyin(ch, style=Style.NORMAL, heteronym=False)[0][0]
    except Exception:
        continue
    if not syl.isascii() or not syl.isalpha() or not (1 <= len(syl) <= 7):
        continue
    seen.add(ch)
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

# 内核把这张表整个读进 0x3B0000,上面就是 USB 结构(0x3C0000),别越界。
if len(blob) > 61440:
    sys.exit("PINYIN.BIN 有 %d 字节,超过内核 PINYIN_MAX(61440);把 want 调小"
             % len(blob))

open(out, "wb").write(blob)
max_syl = max(by_syl, key=lambda s: len(by_syl[s])) if by_syl else "-"
print("PINYIN.BIN: %d 个音节, %d 个常用字, %d 字节(每音最多 %d 个:%s)"
      % (len(syls), len(entries), len(blob),
         len(by_syl[max_syl]) if by_syl else 0, max_syl))
