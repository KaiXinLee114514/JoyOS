#!/usr/bin/env python3
"""
往磁盘镜像里写一个 FAT16 分区,并把文件放进去。

为什么是 FAT16 不是 FAT12:
    FAT16 的簇号就是 16 位整数,算起来直白;FAT12 的簇号是 12 位、两个簇挤三个字节,
    读写都要拆半字节。内核里先支持 FAT16,驱动会按簇数自动判类型(规范:< 4085 簇 = FAT12)。

为什么不用子目录 / 长文件名:
    这两个都要额外处理(LFN 的校验和 + 目录簇链),对"能按名字跑程序"这个目标没必要。
    现在只支持根目录 + 8.3 文件名(HELLO.BIN 这种),够用而且好读。

用法:
    python3 tools/mkfat.py <镜像文件> <分区起始 LBA> <分区大小 MB> <名字=文件> ...
例:
    python3 tools/mkfat.py build/joyos-hd.img 6144 8 README.TXT=progs/README.TXT HELLO.BIN=build/HELLO.BIN

    分区起始 LBA 要用 6144:镜像前面的 0-5496 被引导扇区/stub/内核/磁盘字库占了,
    从 6144 开始才不打架(和 kernel/fat.asm 里的 FAT_PART_LBA 一致 —— 内核启动时
    直接去那个 LBA 找分区,没有 MBR 分区表)。
"""
import pathlib
import struct
import sys

SECTOR = 512
# 每簇扇区数不是随便定的:FAT16 要求簇数落在 [4085, 65525)。分区小的时候
# 4 扇区/簇会只有 4000 出头(差一点就不够),所以下面会自动挑一个合适的值。
RESERVED_SECTORS = 1
NUM_FATS = 2
ROOT_ENTRIES = 512
MEDIA = 0xF8


def name83(name: str):
    """'HELLO.BIN' → 11 字节的 8.3 目录项名字"""
    name = name.upper()
    base, _, ext = name.partition('.')
    return base[:8].ljust(8).encode() + ext[:3].ljust(3).encode()


def main() -> int:
    if len(sys.argv) < 5:
        print(__doc__)
        return 2
    img_path = pathlib.Path(sys.argv[1])
    part_lba = int(sys.argv[2])
    part_mb = int(sys.argv[3])
    files = []
    for spec in sys.argv[4:]:
        name, _, path = spec.partition('=')
        files.append((name, pathlib.Path(path).read_bytes()))

    total_sectors = (part_mb * 1024 * 1024) // SECTOR
    root_dir_sectors = (ROOT_ENTRIES * 32 + SECTOR - 1) // SECTOR

    def try_spc(spc):
        """给定每簇扇区数,算 FAT 大小和簇数(经典的两步回代)"""
        sectors_per_fat = 1
        while True:
            data = total_sectors - RESERVED_SECTORS - NUM_FATS * sectors_per_fat - root_dir_sectors
            cl = data // spc
            need = ((cl + 2) * 2 + SECTOR - 1) // SECTOR
            if need <= sectors_per_fat:
                return sectors_per_fat, cl
            sectors_per_fat = need

    sectors_per_cluster = 0
    for spc in (32, 16, 8, 4, 2, 1):
        spf, cl = try_spc(spc)
        if cl < 65525 and cl >= 4085:
            sectors_per_cluster, sectors_per_fat, clusters = spc, spf, cl
            break
    else:
        print("❌ 这个分区大小凑不出 FAT16 的簇数范围(4085~65524),换个大点/小点的分区")
        return 1
    SECTORS_PER_CLUSTER = sectors_per_cluster

    fat_start = RESERVED_SECTORS
    root_start = fat_start + NUM_FATS * sectors_per_fat
    data_start = root_start + root_dir_sectors

    volume = bytearray(total_sectors * SECTOR)

    # ---- 引导扇区(BPB)----
    bpb = bytearray(SECTOR)
    bpb[0:3] = b"\xEB\x3C\x90"                       # jmp + nop(FAT 卷标志)
    bpb[3:11] = b"JOYOS   "
    struct.pack_into("<H", bpb, 11, SECTOR)          # 每扇区字节数
    bpb[13] = SECTORS_PER_CLUSTER
    struct.pack_into("<H", bpb, 14, RESERVED_SECTORS)
    bpb[16] = NUM_FATS
    struct.pack_into("<H", bpb, 17, ROOT_ENTRIES)
    struct.pack_into("<H", bpb, 19, total_sectors if total_sectors < 65536 else 0)
    bpb[21] = MEDIA
    struct.pack_into("<H", bpb, 22, sectors_per_fat)
    struct.pack_into("<H", bpb, 24, 32)              # 每磁道扇区(软盘几何,这里无所谓)
    struct.pack_into("<H", bpb, 26, 64)              # 磁头数
    struct.pack_into("<I", bpb, 28, 0)               # 隐藏扇区
    struct.pack_into("<I", bpb, 32, total_sectors if total_sectors >= 65536 else 0)
    bpb[36] = 0x80                                   # 驱动器号
    bpb[38] = 0x29                                   # 扩展引导签名
    struct.pack_into("<I", bpb, 39, 0x4A4F594F)      # 卷序列号 'OYOJ'
    bpb[43:54] = b"JOYOS FONT "                      # 卷标 11 字节
    bpb[54:62] = b"FAT16   "
    bpb[510:512] = b"\x55\xAA"
    volume[0:SECTOR] = bpb

    # ---- FAT ----
    fat = bytearray(sectors_per_fat * SECTOR)
    struct.pack_into("<H", fat, 0, 0xFFF8)           # 介质描述 + 保留
    struct.pack_into("<H", fat, 2, 0xFFFF)           # 簇 1 保留

    next_cluster = 2
    root = bytearray(root_dir_sectors * SECTOR)
    entry_index = 0
    for name, data in files:
        n_clusters = max(1, (len(data) + SECTORS_PER_CLUSTER * SECTOR - 1) // (SECTORS_PER_CLUSTER * SECTOR))
        first = next_cluster
        for i in range(n_clusters):
            cur = next_cluster + i
            nxt = cur + 1 if i < n_clusters - 1 else 0xFFFF
            struct.pack_into("<H", fat, cur * 2, nxt)
            # 写数据
            src = i * SECTORS_PER_CLUSTER * SECTOR
            chunk = data[src:src + SECTORS_PER_CLUSTER * SECTOR]
            dst = (data_start + (cur - 2) * SECTORS_PER_CLUSTER) * SECTOR
            volume[dst:dst + len(chunk)] = chunk
        next_cluster += n_clusters

        e = entry_index * 32
        root[e:e + 11] = name83(name)
        root[e + 11] = 0x20                          # 普通文件
        struct.pack_into("<H", root, e + 26, first)
        struct.pack_into("<I", root, e + 28, len(data))
        entry_index += 1
        print(f"   {name:12s} {len(data):>8} 字节  首簇 {first}  共 {n_clusters} 簇")

    volume[fat_start * SECTOR: (fat_start + sectors_per_fat) * SECTOR] = fat
    for i in range(1, NUM_FATS):                     # 第二份 FAT 内容一样(备份)
        off = (fat_start + i * sectors_per_fat) * SECTOR
        volume[off:off + sectors_per_fat * SECTOR] = fat
    volume[root_start * SECTOR:(root_start + root_dir_sectors) * SECTOR] = root

    # ---- 写进镜像(分区起始处的第 0 扇区 = 卷的引导扇区)----
    img = bytearray(img_path.read_bytes())
    need = (part_lba + total_sectors) * SECTOR
    if need > len(img):
        img.extend(b"\x00" * (need - len(img)))
    img[part_lba * SECTOR: part_lba * SECTOR + len(volume)] = volume
    img_path.write_bytes(img)

    print(f"✅ FAT16 分区: LBA {part_lba} 起, {part_mb} MB")
    print(f"   每簇 {SECTORS_PER_CLUSTER} 扇区, FAT {sectors_per_fat} 扇区 × {NUM_FATS}, 根目录 {ROOT_ENTRIES} 项")
    print(f"   数据区起点 LBA {part_lba + data_start}, 簇数 {clusters}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
