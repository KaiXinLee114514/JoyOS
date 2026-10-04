#!/usr/bin/env python3
"""
把 GNU Unifont 的 .hex 点阵字库转成 JoyOS 能直接用的二进制。

── .hex 格式(实测确认,不是猜的) ─────────────────────────────────────
    4E2D:01000100010001003FF8210821082108210821083FF821080100010001000100
    ^^^^  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    码位    点阵数据(十六进制)

  · 数据长度 **32 个字符 = 8×16 半宽**(每行 1 字节),**64 个 = 16×16 全宽**(每行 2 字节)
  · 从上到下逐行,每 2 个十六进制字符 = 8 像素,最高位在最左边
  · bit=1 是"有墨",0 是空

── 转出来的二进制格式(JoyOS 内核直接用) ──────────────────────────────
    +0   'J' 'O' 'Y' 'F'   magic
    +4   u32 version = 1
    +8   u32 字形数 count
    +12  u32 数据区起始(相对文件头)
    +16  count × 12 字节的表项(按码位升序,方便二分查找):
             +0 u32 码位(codepoint)
             +4 u8  宽(8 或 16)
             +5 u8  高(=16)
             +6 u16 保留 0
             +8 u32 该字形数据相对"数据区起始"的偏移
    数据区:每个字形 高×宽/8 字节(8 宽 → 16 字节;16 宽 → 32 字节)

用法:
    # 把 ASCII + 一串汉字导出来
    python3 tools/unifont2bin.py --hex unifont_all.hex --ascii --chars "胡闹OS你好世界" --out build/font.bin

    # 顺便生成一张预览图(用和汇编写法一样的位运算,先看清楚再动汇编)
    python3 tools/unifont2bin.py --hex unifont_all.hex --ascii --chars "胡闹OS" \
            --preview build/font-preview.png --preview-text "胡闹OS 你好,世界"

    # 把一个字打成点阵看(核对用)
    python3 tools/unifont2bin.py --hex unifont_all.hex --show 中

    # 自己检查:二进制里的点阵和解码出来的是否逐位一致
    python3 tools/unifont2bin.py --hex unifont_all.hex --ascii --chars "胡闹OS" --selftest

    # 生成 VGA 文本模式字模表(4 KB,256 个 8×16 字模)+ 汉字映射表
    python3 tools/unifont2bin.py --hex unifont_all.hex --vga-font font/vga-font.bin \
            --vga-map font/vga-zh-map.asm --vga-chars-file font/charset.txt

── VGA 文本模式字模表是怎么回事 ────────────────────────────────────────
  文本模式每个字符格是 8×16 像素,显卡从 plane 2 取字模。**注意每字符占 32 字节**,
  也就是"字符码 × 32"才是一个字模的起点(字符高度最大 32 行,所以硬件按 32 字节一格
  排;实际只用前 16 行,后面补 0)。这一条是从 QEMU 的 vga.c 里读出来的:

      font_ptr = font_base[(cattr >> 3) & 1];   // 表 A/B 由属性字节 bit3 选
      font_ptr += 32 * 4 * ch;                  // 32 行 × 4 个平面 → 平面地址 32*ch

  踩过的坑:按 16 字节步长排表 → 每个字符都被读成"上一个字符的后半 + 下一个字符的前半",
  整屏错位乱码。

  一共 256 × 32 = 8192 字节。我们这样分配:

      0x00-0x1F  空
      0x20-0x7E  Unifont 的 ASCII 8×16 字模(比 BIOS 自带的好看)
      0x80-0xFE  汉字:一个字占**两个字符码**(左半边 + 右半边),
                 打印时连着写两个字符码,屏幕上就拼成一个 16×16 的汉字
      0xFF       空

  所以汉字数量上限 = (0xFE - 0x80 + 1) / 2 = 63 个。这是文本模式的硬限制
  (字格只有 8 像素宽),要更多汉字就得上图形模式(见 README)。
"""
import argparse
import gzip
import os
import struct
import sys

MAGIC = b'JOYF'
VERSION = 1


def open_hex(path):
    if path.endswith('.gz'):
        return gzip.open(path, 'rt', encoding='utf-8', errors='replace')
    return open(path, encoding='utf-8', errors='replace')


def parse_hex(path):
    """→ {码位: (宽, 高, bytes 点阵)}"""
    glyphs = {}
    bad = 0
    with open_hex(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip('\n')
            if not line or ':' not in line:
                continue
            cp_str, data = line.split(':', 1)
            try:
                cp = int(cp_str, 16)
            except ValueError:
                bad += 1
                continue
            try:
                raw = bytes.fromhex(data)
            except ValueError:
                bad += 1
                continue
            if len(data) == 32:                    # 8×16 半宽:每行 1 字节
                width, height = 8, 16
            elif len(data) == 64:                  # 16×16 全宽:每行 2 字节
                width, height = 16, 16
            else:
                bad += 1
                continue
            if len(raw) != (width // 8) * height:
                bad += 1
                continue
            glyphs[cp] = (width, height, raw)
    if bad:
        print(f"  (跳过了 {bad} 行无法解析的)", file=sys.stderr)
    return glyphs


def glyph_rows(width, height, raw):
    """把点阵拆成逐行的位串(左→右,最高位在最左)"""
    stride = width // 8
    for y in range(height):
        row = raw[y * stride:(y + 1) * stride]
        yield ''.join(format(b, '08b') for b in row)


def ascii_art(width, height, raw, ink='█', blank='·'):
    return '\n'.join('   ' + ''.join(ink if c == '1' else blank for c in r)
                     for r in glyph_rows(width, height, raw))


def build_blob(glyphs, codepoints):
    entries = []
    data = bytearray()
    for cp in sorted(set(codepoints)):
        if cp not in glyphs:
            print(f"  ⚠️  字库里没有 U+{cp:04X},跳过", file=sys.stderr)
            continue
        width, height, raw = glyphs[cp]
        entries.append((cp, width, height, len(data)))
        data += raw
    header_size = 16 + len(entries) * 12
    out = bytearray()
    out += MAGIC
    out += struct.pack('<III', VERSION, len(entries), header_size)
    for cp, width, height, off in entries:
        out += struct.pack('<IBBHI', cp, width, height, 0, off)
    out += data
    return bytes(out), entries, bytes(data)


def parse_blob(blob):
    """把生成的二进制再解析回来(自检用)"""
    if blob[:4] != MAGIC:
        raise ValueError('magic 不对')
    version, count, data_off = struct.unpack_from('<III', blob, 4)
    assert version == VERSION
    out = {}
    for i in range(count):
        cp, width, height, _pad, off = struct.unpack_from('<IBBHI', blob, 16 + i * 12)
        size = (width // 8) * height
        out[cp] = (width, height, blob[data_off + off: data_off + off + size])
    return out


def preview(text, glyphs, path, scale=2, margin=8, ink=(255, 255, 255), bg=(0, 0, 0)):
    """用和内核一样的位运算画字,先看清楚对不对"""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print('  没装 PIL,跳过预览图', file=sys.stderr)
        return False

    cw, ch = 16, 16
    width = margin * 2 + cw * len(text) * scale
    height = margin * 2 + ch * scale
    img = Image.new('RGB', (width, height), bg)
    d = ImageDraw.Draw(img)
    x = margin
    for chr_ in text:
        cp = ord(chr_)
        if cp not in glyphs:
            x += 8 * scale
            continue
        w, h, raw = glyphs[cp]
        for y, row in enumerate(glyph_rows(w, h, raw)):
            for bx, bit in enumerate(row):
                if bit == '1':
                    d.rectangle([x + bx * scale, margin + y * scale,
                                 x + (bx + 1) * scale - 1, margin + (y + 1) * scale - 1], fill=ink)
        x += w * scale                              # 半宽走 8,全宽走 16
    img.save(path)
    return True


def build_vga_font(glyphs, zh_chars, verbose=True):
    """→ (8192 字节的 VGA 字模表, [(码位, 左半边字符码), ...])

    每字符 32 字节:前 16 字节是 8×16 的 16 行,后 16 字节补 0。
    """
    CELL = 32
    font = bytearray(256 * CELL)

    # ---- ASCII 0x20-0x7E:Unifont 的半宽字形就是 8×16,直接抄 ----
    ascii_used = 0
    for code in range(0x20, 0x7F):
        if code in glyphs:
            w, h, raw = glyphs[code]
            if w == 8 and h == 16:
                font[code * CELL:code * CELL + 16] = raw
                ascii_used += 1

    # ---- 汉字:从 0x80 开始,每个字占两个字模号 ----
    mapping = []
    slot = 0x80
    for ch in zh_chars:
        cp = ord(ch)
        if cp < 0x80:                                # ASCII 已经在 0x20-0x7E 里,不该占汉字字模号
            continue
        if cp in [m[0] for m in mapping]:
            continue
        if cp not in glyphs:
            if verbose:
                print(f'  ⚠️  字库里没有 "{ch}"(U+{cp:04X}),跳过', file=sys.stderr)
            continue
        if slot + 1 > 0xFE:
            if verbose:
                print(f'  ⚠️  字模号用完了(上限 63 个汉字),"{ch}" 及之后的都没放进去', file=sys.stderr)
            break
        w, h, raw = glyphs[cp]
        left = bytearray(16)
        right = bytearray(16)
        if w == 16:
            for y in range(16):                     # 16×16 每行 2 字节,正好左右各一
                left[y] = raw[y * 2]
                right[y] = raw[y * 2 + 1]
        else:                                       # 半宽字(比如全角标点)左对齐,右半边留空
            left[:] = raw
            if verbose:
                print(f'  注意:"{ch}" 是 8×16 半宽,右半边会空着', file=sys.stderr)
        font[slot * CELL:slot * CELL + 16] = left
        font[(slot + 1) * CELL:(slot + 1) * CELL + 16] = right
        mapping.append((cp, slot))
        slot += 2

    if verbose:
        print(f'  字模表: {len(font)} 字节(256 × 32);ASCII {ascii_used} 个 + 汉字 {len(mapping)} 个'
              f'(用掉 0x80-0x{slot - 1:02X} 共 {slot - 0x80} 个字符码)')
    return bytes(font), mapping


def write_vga_map(path, mapping):
    """给 NASM 用的映射表:每条 5 字节 = dd 码位 + db 左半边字符码"""
    lines = [
        '; ============================================================',
        ';  汉字 → VGA 字模号 映射表   **自动生成,别手改**',
        ';  生成: python3 tools/unifont2bin.py --hex ... --vga-font ... --vga-map 本文件',
        ';  每个汉字占两个相连的字符码(左半边 = 表里的号,右半边 = 号+1)',
        '; ============================================================',
        f'vga_zh_count equ {len(mapping)}',
        '',
        'vga_zh_map:',
    ]
    for cp, slot in mapping:
        ch = chr(cp)
        lines.append(f'    dd 0x{cp:08X}        ; {ch}')
        lines.append(f'    db 0x{slot:02X}')
    lines.append('')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))


def write_zh_strings(path, strings):
    """把中文文案转成"码位数组"(每个 dword 一个码位,0 结尾),给汇编用"""
    lines = [
        '; ============================================================',
        ';  中文文案(码位数组,**0 结尾**)  **自动生成,别手改**',
        ';  来源: font/strings.txt',
        '; ============================================================',
        '',
    ]
    labels = []
    for i, txt in enumerate(strings):
        label = f'zh_str_{i + 1}'
        labels.append(label)
        cps = ', '.join(f'0x{ord(c):08X}' for c in txt)
        lines.append(f'{label}:')
        lines.append(f'    dd {cps}, 0        ; {txt}')
        lines.append('')
    lines.append(f'zh_str_count equ {len(strings)}')
    lines.append('')
    lines.append('; 按序号取用: zh_str_table[i] 就是第 i 条(从 0 数)')
    lines.append('zh_str_table:')
    for label in labels:
        lines.append(f'    dd {label}')
    lines.append('')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))


def main():
    ap = argparse.ArgumentParser(description='Unifont .hex → JoyOS 点阵二进制')
    ap.add_argument('--hex', required=True, help='unifont .hex(也可以是 .hex.gz)')
    ap.add_argument('--chars', default='', help='要导出的字符(直接写,比如 "胡闹OS")')
    ap.add_argument('--ascii', action='store_true', help='顺便把 0x20~0x7E 的可打印 ASCII 都导进去')
    ap.add_argument('--out', help='输出二进制路径')
    ap.add_argument('--preview', help='生成预览 PNG')
    ap.add_argument('--preview-text', help='预览图里画什么字(默认用 --chars;两个参数分开才不会互相覆盖)')
    ap.add_argument('--show', nargs='*', help='把某些字打成点阵打印出来')
    ap.add_argument('--selftest', action='store_true', help='自检:二进制里的点阵和解码的是否逐位一致')
    ap.add_argument('--vga-font', help='生成 VGA 文本模式字模表(4096 字节 = 256 个 8×16 字模)')
    ap.add_argument('--vga-map', help='生成给汇编用的"汉字→字模号"映射表')
    ap.add_argument('--vga-chars', default='', help='放进 0x80 起的汉字')
    ap.add_argument('--vga-chars-file', help='从文本文件读汉字(一行一个或直接一长串都行)')
    ap.add_argument('--zh-strings-in', help='中文文案文件(一行一条)')
    ap.add_argument('--zh-strings-out', help='生成为汇编的"码位数组"文件')
    args = ap.parse_args()

    print(f'读字库 {args.hex} ...')
    glyphs = parse_hex(args.hex)
    half = sum(1 for w, _, _ in glyphs.values() if w == 8)
    print(f'  共 {len(glyphs)} 个字形(8×16 半宽 {half},16×16 全宽 {len(glyphs) - half})')

    if args.show:
        for item in args.show:
            cp = int(item[2:], 16) if item.lower().startswith('u+') else ord(item[0])
            if cp not in glyphs:
                print(f'U+{cp:04X} 字库里没有')
                continue
            w, h, raw = glyphs[cp]
            print(f'\nU+{cp:04X} "{chr(cp)}"  {w}×{h}')
            print(ascii_art(w, h, raw))
        return 0

    # ---------------- VGA 文本模式字模表 ----------------
    if args.vga_font or args.vga_map:
        zh = args.vga_chars
        if args.vga_chars_file:
            with open(args.vga_chars_file, encoding='utf-8') as f:
                zh += ''.join(c for c in f.read() if not c.isspace())
        if not args.vga_font:
            print('--vga-map 要和 --vga-font 一起用', file=sys.stderr)
            return 2
        font, mapping = build_vga_font(glyphs, zh)
        os.makedirs(os.path.dirname(os.path.abspath(args.vga_font)), exist_ok=True)
        with open(args.vga_font, 'wb') as f:
            f.write(font)
        print(f'  写出 {args.vga_font}({len(font)} 字节 = 256 字模 × 16 字节)')
        if args.vga_map:
            write_vga_map(args.vga_map, mapping)
            print(f'  写出 {args.vga_map}({len(mapping)} 条映射)')
        if args.zh_strings_in and args.zh_strings_out:
            with open(args.zh_strings_in, encoding='utf-8') as f:
                strings = [ln.strip() for ln in f if ln.strip()]
            need = set(c for t in strings for c in t)
            have = set(chr(cp) for cp, _ in mapping) | set(chr(c) for c in range(0x20, 0x7F))
            missing = sorted(need - have)
            if missing:
                print(f'  ⚠️  文案里有 {len(missing)} 个字没放进字模表: {"".join(missing)}', file=sys.stderr)
            write_zh_strings(args.zh_strings_out, strings)
            print(f'  写出 {args.zh_strings_out}({len(strings)} 条文案)')
        print(f'  NASM 里:  vga_font_blob: incbin "{args.vga_font}"')
        return 0

    wanted = []
    if args.ascii:
        wanted += list(range(0x20, 0x7F))
    wanted += [ord(c) for c in args.chars if c not in '\n\r']

    if not wanted:
        print('没指定要导出什么字(--chars / --ascii / --show)', file=sys.stderr)
        return 2

    blob, entries, _data = build_blob(glyphs, wanted)
    missing = sorted(set(wanted) - set(glyphs))
    print(f'  导出 {len(entries)} 个字形,{len(blob)} 字节')
    if missing:
        print(f'  (字库里没有这些,已跳过: {" ".join(f"U+{c:04X}" for c in missing[:10])}'
              f'{" ..." if len(missing) > 10 else ""})')

    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, 'wb') as f:
            f.write(blob)
        print(f'  写出 {args.out}(magic={MAGIC.decode()}, {len(entries)} 项,数据区偏移 {16 + len(entries) * 12})')
        print(f'  NASM 里直接:  font_blob: incbin "{os.path.relpath(args.out)}"')

    if args.preview:
        text = args.preview_text or args.chars or 'JoyOS 你好'
        if preview(text, glyphs, args.preview):
            print(f'  预览图 {args.preview}(内容: {text!r})')

    exit_code = 0
    if args.selftest:
        back = parse_blob(blob)
        bad = [cp for cp in back if back[cp] != glyphs[cp]]
        print(f'  自检: {len(back) - len(bad)}/{len(back)} 个字形逐位一致' +
              (f',❌ 不一致: {bad[:5]}' if bad else ' ✅'))
        if bad:
            exit_code = 1
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
