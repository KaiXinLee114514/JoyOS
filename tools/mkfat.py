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

名字以 / 结尾 = 建一个目录;名字里带 / = 放进子目录(父目录会自动建):
    python3 tools/mkfat.py build/joyos-hd.img 6144 8 DOCS/ DOCS/NOTE.TXT=progs/NOTES.TXT

FAT32(分区要 ≥ 32 MB,不然凑不够 65525 个簇):
    python3 tools/mkfat.py build/joyos-hd32.img 6144 56 --fat32 README.TXT=progs/README.TXT
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
    """'HELLO.BIN' → 11 字节的 8.3 目录项名字

    ★ "." 和 ".." 要特殊处理:按普通规则 partition('.') 会把它们拆成
      base="" + ext="" → 结果 11 个空格,名字就丢了(目录自己指不回来,
      任何工具走进去都会迷路)。FAT 里 "." 就是 ".          "、".." 是 "..         "。
    """
    name = name.upper()
    if name == ".":
        return b"." + b" " * 10
    if name == "..":
        return b".." + b" " * 9
    base, _, ext = name.partition('.')
    return base[:8].ljust(8).encode() + ext[:3].ljust(3).encode()


def main() -> int:
    argv = [a for a in sys.argv[1:] if a != "--fat32"]
    fat32 = "--fat32" in sys.argv
    if len(argv) < 4:
        print(__doc__)
        return 2
    img_path = pathlib.Path(argv[0])
    part_lba = int(argv[1])
    part_mb = int(argv[2])
    files = []
    for spec in argv[3:]:
        name, _, path = spec.partition('=')
        # 名字以 / 结尾 = 建目录(没有数据);否则读文件内容
        files.append((name, b"" if name.endswith("/") else pathlib.Path(path).read_bytes()))

    total_sectors = (part_mb * 1024 * 1024) // SECTOR
    esize = 4 if fat32 else 2                  # FAT 表项字节数
    eoc = 0x0FFFFFFF if fat32 else 0xFFFF      # 链尾(28 位 / 16 位)
    reserved = 32 if fat32 else RESERVED_SECTORS
    root_ents = 0 if fat32 else ROOT_ENTRIES
    root_dir_sectors = (root_ents * 32 + SECTOR - 1) // SECTOR

    def try_spc(spc):
        """给定每簇扇区数,算 FAT 大小和簇数(经典的两步回代)"""
        sectors_per_fat = 1
        while True:
            data = total_sectors - reserved - NUM_FATS * sectors_per_fat - root_dir_sectors
            cl = data // spc
            need = ((cl + 2) * esize + SECTOR - 1) // SECTOR
            if need <= sectors_per_fat:
                return sectors_per_fat, cl
            sectors_per_fat = need

    sectors_per_cluster = 0
    for spc in (32, 16, 8, 4, 2, 1):
        spf, cl = try_spc(spc)
        ok = (cl >= 65525) if fat32 else (4085 <= cl < 65525)
        if ok:
            sectors_per_cluster, sectors_per_fat, clusters = spc, spf, cl
            break
    else:
        if fat32:
            print(f"❌ FAT32 至少要 65525 个簇,这个分区只有 {cl} 个 —— 用 --disk-mb 把镜像开大点")
        else:
            print("❌ 这个分区大小凑不出 FAT16 的簇数范围(4085~65524),换个大点/小点的分区")
        return 1
    SECTORS_PER_CLUSTER = sectors_per_cluster

    fat_start = reserved                         # FAT32 要 32 个保留扇区,别拿 FAT16 的常量
    root_start = fat_start + NUM_FATS * sectors_per_fat
    data_start = root_start + root_dir_sectors

    volume = bytearray(total_sectors * SECTOR)

    # ---- 引导扇区(BPB)----
    bpb = bytearray(SECTOR)
    bpb[0:3] = b"\xEB\x3C\x90"                       # jmp + nop(FAT 卷标志)
    bpb[3:11] = b"JOYOS   "
    struct.pack_into("<H", bpb, 11, SECTOR)          # 每扇区字节数
    bpb[13] = SECTORS_PER_CLUSTER
    struct.pack_into("<H", bpb, 14, reserved)
    bpb[16] = NUM_FATS
    struct.pack_into("<H", bpb, 17, root_ents)
    struct.pack_into("<H", bpb, 19, total_sectors if total_sectors < 65536 else 0)
    bpb[21] = MEDIA
    struct.pack_into("<H", bpb, 22, 0 if fat32 else sectors_per_fat)   # 0 = FAT32 的标志
    struct.pack_into("<H", bpb, 24, 32)              # 每磁道扇区(软盘几何,这里无所谓)
    struct.pack_into("<H", bpb, 26, 64)              # 磁头数
    struct.pack_into("<I", bpb, 28, 0)               # 隐藏扇区
    struct.pack_into("<I", bpb, 32, total_sectors if (total_sectors >= 65536 or fat32) else 0)
    if fat32:
        struct.pack_into("<I", bpb, 36, sectors_per_fat)   # 每 FAT 扇区数(32 位)
        struct.pack_into("<H", bpb, 40, 0)                 # 扩展标志
        struct.pack_into("<H", bpb, 42, 0)                 # 版本 0.0
        struct.pack_into("<I", bpb, 44, 2)                 # 根目录首簇
        struct.pack_into("<H", bpb, 48, 1)                 # FSInfo 扇区
        struct.pack_into("<H", bpb, 50, 6)                 # 备份引导扇区
        bpb[64] = 0x80                                     # 驱动器号
        bpb[66] = 0x29                                     # 扩展引导签名
        struct.pack_into("<I", bpb, 67, 0x4A4F594F)        # 卷序列号
        bpb[71:82] = b"JOYOS FAT32"                        # 卷标
        bpb[82:90] = b"FAT32   "
    else:
        bpb[36] = 0x80                                   # 驱动器号
        bpb[38] = 0x29                                   # 扩展引导签名
        struct.pack_into("<I", bpb, 39, 0x4A4F594F)      # 卷序列号 'OYOJ'
        bpb[43:54] = b"JOYOS FONT "                      # 卷标 11 字节
        bpb[54:62] = b"FAT16   "
    bpb[510:512] = b"\x55\xAA"
    volume[0:SECTOR] = bpb
    if fat32:
        # FSInfo(扇区 1):告诉别人"还有多少空闲簇",顺便留个下次从哪找的提示
        fsinfo = bytearray(SECTOR)
        struct.pack_into("<I", fsinfo, 0, 0x41615252)
        struct.pack_into("<I", fsinfo, 484, 0x61417272)
        struct.pack_into("<I", fsinfo, 488, 0xFFFFFFFF)
        struct.pack_into("<I", fsinfo, 492, 0xFFFFFFFF)
        struct.pack_into("<I", fsinfo, 508, 0xAA550000)
        volume[SECTOR:2 * SECTOR] = fsinfo
        volume[6 * SECTOR:7 * SECTOR] = bpb               # 备份引导扇区

    # ---- FAT ----
    fat = bytearray(sectors_per_fat * SECTOR)

    def fat_set(cl, val):
        struct.pack_into("<I" if fat32 else "<H", fat, cl * esize, val)

    fat_set(0, 0x0FFFFFF8 if fat32 else 0xFFF8)      # 介质描述 + 保留
    fat_set(1, eoc)                                  # 簇 1 保留
    if fat32:
        fat_set(2, eoc)                              # FAT32:簇 2 就是根目录

    next_cluster = 3 if fat32 else 2

    # ------------------------------------------------------------------
    #  把参数拆成"目录"和"文件":名字以 / 结尾 = 建目录,
    #  "A/B/C.TXT=..." = 放到子目录里(父目录自动建)。
    #  每个目录占一个簇;簇里先写 "." 和 ".." 两个项,再写它自己的孩子。
    # ------------------------------------------------------------------
    dir_paths = []                      # 要建的目录(按父在前排序)
    file_items = []                     # (路径, 数据)
    for name, data in files:
        if name.endswith("/"):
            dir_paths.append(name.rstrip("/"))
        else:
            file_items.append((name, data))
    for name, _ in file_items:
        parts = name.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            d = "/".join(parts[:i])
            if d and d not in dir_paths:
                dir_paths.append(d)
    dir_paths.sort(key=lambda d: d.count("/"))      # 父目录先分配簇

    dir_cluster = {}                    # 目录路径 → 它的首簇
    dir_parent = {}                     # 目录路径 → 父目录路径("" = 根)
    dir_contents = []                   # [(目录路径, [项...])]  项的写法见下面
    for d in dir_paths:
        parent = d.rsplit("/", 1)[0] if "/" in d else ""
        dir_cluster[d] = next_cluster
        dir_parent[d] = parent
        fat_set(next_cluster, eoc)                              # 一个簇的目录,链尾
        next_cluster += 1

    def entry(short, attr, cluster, size):
        b = bytearray(32)
        b[0:11] = short
        b[11] = attr
        if fat32:
            struct.pack_into("<H", b, 20, (cluster >> 16) & 0xFFFF)   # 高 16 位
        struct.pack_into("<H", b, 26, cluster & 0xFFFF)
        struct.pack_into("<I", b, 28, size)
        return b

    dir_entries = {d: [] for d in dir_paths}
    root_entries = []

    # 目录自己的项:". "(自己)和 ".."(父目录;根用 0,这是 FAT 的老规矩)
    for d in dir_paths:
        dir_entries[d].append(entry(name83("."), 0x10, dir_cluster[d], 0))
        # ".." 指向父目录;父目录是根的话填 0(FAT16 的根没有簇号,0 就是"根")
        up = dir_cluster[dir_parent[d]] if dir_parent[d] else 0
        dir_entries[d].append(entry(name83(".."), 0x10, up, 0))

    # 文件:按路径放进对应目录
    for name, data in file_items:
        parts = name.split("/")
        fname, d = parts[-1], "/".join(parts[:-1])
        n_clusters = max(1, (len(data) + SECTORS_PER_CLUSTER * SECTOR - 1)
                         // (SECTORS_PER_CLUSTER * SECTOR))
        first = next_cluster
        for i in range(n_clusters):
            cur = next_cluster + i
            nxt = cur + 1 if i < n_clusters - 1 else eoc
            fat_set(cur, nxt)
            src = i * SECTORS_PER_CLUSTER * SECTOR
            chunk = data[src:src + SECTORS_PER_CLUSTER * SECTOR]
            dst = (data_start + (cur - 2) * SECTORS_PER_CLUSTER) * SECTOR
            volume[dst:dst + len(chunk)] = chunk
        next_cluster += n_clusters

        target = root_entries if d == "" else dir_entries[d]
        target.append(entry(name83(fname), 0x20, first, len(data)))
        where = f"{d}/{fname}" if d else fname
        print(f"   {where:24s} {len(data):>8} 字节  首簇 {first}  共 {n_clusters} 簇")

    # 目录:在父目录里写一个 attr=0x10 的项
    for d in dir_paths:
        parent = dir_parent[d]
        short = name83(d.rsplit("/", 1)[-1])
        e = entry(short, 0x10, dir_cluster[d], 0)
        if parent == "":
            root_entries.append(e)
        else:
            dir_entries[parent].append(e)
        print(f"   {(parent + '/') if parent else ''}{d.rsplit('/', 1)[-1] + '/':12s} "
              f"{'目录':>8}      首簇 {dir_cluster[d]}")

    # 目录的簇内容:".", "..", 然后自己的孩子;装不下就往簇链上再接一簇
    # (每簇装 SECTORS_PER_CLUSTER*16 个 32 字节目录项,超了必须链新簇 ——
    #  内核 fat_free_slot 的"扩一簇"逻辑就是为这种情况写的)
    per_cluster = SECTORS_PER_CLUSTER * 16
    for d in dir_paths:
        ents = dir_entries[d]
        cl = dir_cluster[d]
        for start in range(0, max(1, len(ents)), per_cluster):
            chunk = ents[start:start + per_cluster]
            blk = bytearray(SECTORS_PER_CLUSTER * SECTOR)
            for i, e in enumerate(chunk):
                blk[i * 32:(i + 1) * 32] = e
            off = (data_start + (cl - 2) * SECTORS_PER_CLUSTER) * SECTOR
            volume[off:off + len(blk)] = blk
            if start + per_cluster < len(ents):
                nxt = next_cluster                    # 还有下一批 → 接一簇
                next_cluster += 1
                fat_set(cl, nxt)
                fat_set(nxt, eoc)
                cl = nxt

    root = bytearray((root_dir_sectors or SECTORS_PER_CLUSTER) * SECTOR)
    for i, e in enumerate(root_entries):
        root[i * 32:(i + 1) * 32] = e

    volume[fat_start * SECTOR: (fat_start + sectors_per_fat) * SECTOR] = fat
    for i in range(1, NUM_FATS):                     # 第二份 FAT 内容一样(备份)
        off = (fat_start + i * sectors_per_fat) * SECTOR
        volume[off:off + sectors_per_fat * SECTOR] = fat
    if fat32:
        # 根目录也住在普通数据簇里(簇 2)
        off = (data_start + (2 - 2) * SECTORS_PER_CLUSTER) * SECTOR
        volume[off:off + len(root)] = root
    else:
        volume[root_start * SECTOR:(root_start + root_dir_sectors) * SECTOR] = root

    # ---- 写进镜像(分区起始处的第 0 扇区 = 卷的引导扇区)----
    img = bytearray(img_path.read_bytes())
    need = (part_lba + total_sectors) * SECTOR
    if need > len(img):
        img.extend(b"\x00" * (need - len(img)))
    img[part_lba * SECTOR: part_lba * SECTOR + len(volume)] = volume
    img_path.write_bytes(img)

    print(f"✅ {'FAT32' if fat32 else 'FAT16'} 分区: LBA {part_lba} 起, {part_mb} MB")
    if fat32:
        print(f"   每簇 {SECTORS_PER_CLUSTER} 扇区, FAT32 {sectors_per_fat} 扇区 × {NUM_FATS}, "
              f"根目录 = 簇 2, 保留 {reserved} 扇区")
    else:
        print(f"   每簇 {SECTORS_PER_CLUSTER} 扇区, FAT {sectors_per_fat} 扇区 × {NUM_FATS}, 根目录 {root_ents} 项")
    print(f"   数据区起点 LBA {part_lba + data_start}, 簇数 {clusters}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
