#!/usr/bin/env python3
"""
把引导扇区和内核拼成一张软盘镜像。

两种镜像:
  · 软盘(-fda,1.44 MB):只有引导扇区 / stub / 内核,没有字库
  · 硬盘(-hda,默认 16 MB):上面那些 + **磁盘字库**
        LBA 2047        字库描述块(magic 'JFD1' + 字库 LBA + 扇区数)
        LBA 2048 起     字库本体(JOYF,内核用 ATA PIO 读进内存)
    内核因此能显示完整 Unifont(4 万字形),不受 64 KiB 内核区的限制。

布局:
    LBA 0        引导扇区(512 字节,必须在 0 扇区,末尾要有 0xAA55)
    LBA 1-4      实模式 stub(搬到 0x500;问 VBE、进保护模式)
    LBA 5 起     32 位内核(搬到 0x10000)

为什么要拼镜像而不是直接用 boot.bin?
    因为"多扇区"这件事必须有个真的磁盘:内核比 512 字节大得多,
    单靠一个扇区装不下 —— 这正是要解决的问题。
"""
import pathlib
import sys

SECTOR = 512
FLOPPY = 1474560                      # 1.44 MB
FONT_DESC_LBA = 2047                    # 字库描述块(内核先读它,才知道字库在哪、多大)
FONT_LBA = 2048                         # 字库本体
HD_SIZE = 16 * 1024 * 1024              # 硬盘镜像默认 16 MB

STUB_LBA = 1
STUB_SECTS = 4                         # 2 KB 够实模式 stub 用了
KERNEL_LBA = 5
KERNEL_SECTS = 256                     # 必须和 boot/boot.asm 里的常量一致(128 KiB,给 FAT32 留余量)


def main() -> int:
    if len(sys.argv) not in (5, 6):
        print(__doc__)
        print("用法: mkimg.py <boot.bin> <stub.bin> <kernel.bin> <out.img> [font.bin]")
        return 2

    boot = pathlib.Path(sys.argv[1]).read_bytes()
    stub = pathlib.Path(sys.argv[2]).read_bytes()
    kern = pathlib.Path(sys.argv[3]).read_bytes()
    out = pathlib.Path(sys.argv[4])
    font = pathlib.Path(sys.argv[5]).read_bytes() if len(sys.argv) > 5 else None

    if font and font[:4] != b"JOYF":
        print("❌ 字库文件不是 JOYF 格式")
        return 1

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

    stub_limit = STUB_SECTS * SECTOR
    if len(stub) > stub_limit:
        print(f"❌ stub {len(stub)} 字节超出 {stub_limit}({STUB_SECTS} 扇区)—— 改大 boot.asm 的 STUB_SECTS")
        return 1

    if font:
        total = HD_SIZE
        font_sectors = (len(font) + SECTOR - 1) // SECTOR
        need = (FONT_LBA + font_sectors) * SECTOR
        if need > total:
            total = need + 1024 * 1024          # 不够就再留 1 MB
        img = bytearray(total)
    else:
        img = bytearray(FLOPPY)

    img[0:SECTOR] = boot
    img[STUB_LBA * SECTOR: STUB_LBA * SECTOR + len(stub)] = stub
    img[KERNEL_LBA * SECTOR: KERNEL_LBA * SECTOR + len(kern)] = kern

    if font:
        desc = bytearray(SECTOR)
        desc[0:4] = b"JFD1"
        desc[4:8] = FONT_LBA.to_bytes(4, "little")
        desc[8:12] = font_sectors.to_bytes(4, "little")
        desc[12:16] = len(font).to_bytes(4, "little")
        img[FONT_DESC_LBA * SECTOR:(FONT_DESC_LBA + 1) * SECTOR] = desc
        img[FONT_LBA * SECTOR: FONT_LBA * SECTOR + len(font)] = font
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(img)

    print(f"✅ {out}")
    print(f"   LBA 0      引导扇区 {len(boot)} 字节")
    print(f"   LBA {STUB_LBA}-{STUB_LBA + STUB_SECTS - 1}  stub {len(stub)} 字节 = {(len(stub) + SECTOR - 1) // SECTOR} 扇区"
          f"(上限 {STUB_SECTS})")
    print(f"   LBA {KERNEL_LBA} 起  内核 {len(kern)} 字节 = {(len(kern) + SECTOR - 1) // SECTOR} 扇区"
          f"(上限 {KERNEL_SECTS})")
    if font:
        print(f"   LBA {FONT_DESC_LBA}     字库描述块")
        print(f"   LBA {FONT_LBA} 起  字库 {len(font)} 字节 = {(len(font) + SECTOR - 1) // SECTOR} 扇区")
        print(f"   镜像 {len(img)} 字节 (硬盘镜像 {len(img) // 1024 // 1024} MB)")
    else:
        print(f"   镜像 {len(img)} 字节 (1.44 MB 软盘,无磁盘字库)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
