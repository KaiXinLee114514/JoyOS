#!/usr/bin/env python3
"""
把引导扇区和内核拼成一张软盘镜像。

布局(1.44 MB 软盘,1474560 字节):
    LBA 0        引导扇区(512 字节,必须在 0 扇区,末尾要有 0xAA55)
    LBA 1 起     内核(引导扇区用 int 0x13 AH=42h 多扇区读进来)

为什么要拼镜像而不是直接用 boot.bin?
    因为"多扇区"这件事必须有个真的磁盘:内核比 512 字节大得多,
    单靠一个扇区装不下 —— 这正是要解决的问题。
"""
import pathlib
import sys

SECTOR = 512
FLOPPY = 1474560                      # 1.44 MB
KERNEL_LBA = 1
KERNEL_SECTS = 64                     # 必须和 boot/boot.asm 里的常量一致


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__)
        print("用法: mkimg.py <boot.bin> <kernel.bin> <out.img>")
        return 2

    boot = pathlib.Path(sys.argv[1]).read_bytes()
    kern = pathlib.Path(sys.argv[2]).read_bytes()
    out = pathlib.Path(sys.argv[3])

    if len(boot) != SECTOR:
        print(f"❌ 引导扇区必须正好 {SECTOR} 字节,实际 {len(boot)}")
        return 1
    if boot[-2:] != b"\x55\xaa":
        print("❌ 引导扇区结尾没有 0xAA55 魔数")
        return 1

    limit = KERNEL_SECTS * SECTOR
    if len(kern) > limit:
        print(f"❌ 内核 {len(kern)} 字节超出 {limit}({KERNEL_SECTS} 扇区)—— 改大 boot.asm 的 KERNEL_SECTS")
        return 1

    img = bytearray(FLOPPY)
    img[0:SECTOR] = boot
    img[KERNEL_LBA * SECTOR: KERNEL_LBA * SECTOR + len(kern)] = kern
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(img)

    print(f"✅ {out}")
    print(f"   LBA 0      引导扇区 {len(boot)} 字节")
    print(f"   LBA {KERNEL_LBA} 起    内核 {len(kern)} 字节 = {(len(kern) + SECTOR - 1) // SECTOR} 扇区"
          f"(上限 {KERNEL_SECTS})")
    print(f"   镜像 {len(img)} 字节 (1.44 MB 软盘)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
