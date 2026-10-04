# JoyOS 的磁盘:ATA PIO、磁盘字库、FAT16

这一页讲清楚**磁盘上有什么、内核怎么读它、怎么往里写**。涉及三个文件:

| 文件 | 干什么 |
|---|---|
| `kernel/ata.asm` | ATA(IDE)硬盘 PIO 驱动,读/写裸扇区 |
| `kernel/fontdisk.asm` | 启动时把完整字库从磁盘搬进内存 |
| `kernel/fat.asm` | FAT16:找文件、读文件、写文件、列目录 |

配套的 Python 工具是 `tools/mkimg.py`(拼镜像 + 放字库)和 `tools/mkfat.py`(造分区 + 放文件)。

---

## 1. 整张镜像长什么样

`build/joyos-hd.img` 是 16 MB,按 LBA(逻辑扇区号,1 扇区 = 512 字节)排:

```
LBA 0            引导扇区(512 字节,BIOS 读到 0x7C00)
LBA 1 - 4        实模式 stub(搬到 0x500;问 VBE、进保护模式)
LBA 5 起         32 位内核(正好 128 扇区 = 64 KiB,搬到 0x10000)
LBA 2047         字库描述块:magic 'JFD1' + 字库 LBA + 扇区数 + 字节数
LBA 2048 起      字库本体(JOYF 格式,1 765 648 字节 = 3449 扇区)
LBA 6144 起      FAT16 分区(8 MB;这里是唯一能被"文件"操作的地方)
```

为什么 FAT16 分区要从 **6144** 开始:字库到 5496 扇区才结束,后面留了点空。
分区起点**写死**在两个地方,改的时候两边都得改:

* `kernel/fat.asm` 里的 `FAT_PART_LBA equ 6144`(内核去这个 LBA 找"引导扇区")
* `Makefile` 里 `mkfat.py $(HDIMG) 6144 8 ...`

> 没有 MBR 分区表 —— `fat_mount` 不是"解析分区表",而是**直接去固定 LBA** 读那个 FAT 引导扇区。
> 一个玩具系统这么干最省事,代价是分区不能搬家。

软盘镜像(`build/joyos.img`,1.44 MB)只有前三项,没有字库也没有文件系统 ——
BIOS 的软盘读盘路径是另一条测试路线(`make test-fda`)。

## 2. 为什么不用 BIOS 读盘了

开机时用 `int 0x13` 读盘没问题(引导扇区就是那么干的),但那之后:

* BIOS 只有"读第 N 个扇区"这一种操作,**它不知道什么是文件**;
* `int 0x13` 是实模式的中断,进了保护模式还得来回切,麻烦;
* 我们要用硬盘上的字库(1.7 MB),BIOS 一次读的那点量也不合适。

所以进保护模式之后直接操作 **ATA 控制器端口**(0x1F0~0x1F7),这条路子叫 PIO
(Programmed I/O:CPU 一个一个字地把数据搬进来,不用 DMA)。

## 3. ATA PIO 驱动(`kernel/ata.asm`)

一个扇区的读,寄存器顺序是固定的:

```
0x1F6 ← 0xE0 | (LBA >> 24 & 0x0F)   选主盘 + LBA 高 4 位
0x1F2 ← 扇区数
0x1F3 ← LBA & 0xFF                  低 24 位,三个端口分着放
0x1F4 ← (LBA >> 8) & 0xFF
0x1F5 ← (LBA >> 16) & 0xFF
0x1F7 ← 0x20(读)/ 0x30(写)          命令寄存器:发命令
等 0x1F7:BSY(bit7) 变 0 且 DRQ(bit3) 变 1
从 0x1F0 读 256 次(16 位)= 512 字节
```

对外就两个函数(都在 `kernel/ata.asm`):

```asm
; eax = 起始 LBA,ecx = 扇区数,edi = 目标地址;返回 eax = 0 成功
call ata_read_sectors

; eax = 起始 LBA,ecx = 扇区数,esi = 源地址;返回 eax = 0 成功
call ata_write_sectors
```

写盘还有两个额外动作,少一个都可能丢数据:

1. **每写一个端口前等 ~400 ns**(`ata_delay400`,读四次状态口就算等了)—— 老硬盘吃不下这么快的写;
2. 写完发 **0xE7 = FLUSH CACHE**,让驱动器把内部缓存真的落盘(不然 QEMU 一退,数据可能还在缓存里)。

### 坑 1:一次要 255 个扇区,结果只回来一个

读字库的时候最开始是"一口气发 255 个扇区的读命令",状态也显示成功,
但读回来的内存里**只有第一个扇区是对的,后面全是 0**。

原因是 ATA 规范允许驱动器**只传一部分**(它想传多少传多少),而 PIO 模式下
每传一个扇区就得等一次 DRQ。修法是分块 + 每块每扇区都等:

```asm
ATA_MAX_CHUNK equ 16          ; 块大小:255 是硬件上限,16(=8 KB)实测最稳
```

`ata_wait_drq` 在每搬 512 字节之前等 `DRQ=1`,这才把 3449 个扇区完整读进来。

### 坑 2:`mov al, 0xE0` 会把 LBA 弄丢

`ata_setup_lba` 里的 LBA 存在 `eax` 里,而中间有一步要 `mov al, 0xE0`(选盘字节)——
`al` 就是 `eax` 的低 8 位,LBA 的低字节当场被改成 0xE0。

于是"读 LBA 0x1E0"变成了"读 LBA 0x00",字库全读成 0 → 屏幕上每个字都是 **missing glyph 方框**。
修法:把所有参数列完之后再从内存里把 LBA 读回 `eax`。这类 bug 的教训是
**看内存里的字节,别信"函数返回成功"**。

## 4. 磁盘字库(`kernel/fontdisk.asm`)

内核区只有 64 KiB(`KERNEL_SECTS = 128`),而完整字库是 **1.7 MB / 40 208 个字形**,
不可能 `incbin` 进去。所以:

* `font/font-joyf.bin`(416 字形,约 12 KB)**编进内核**,是保底方案;
* `font/full-joyf.bin`(40 208 字形)**放在磁盘上**,启动时读进内存。

启动流程(`font_load_from_disk`):

```
读 BOOTINFO+72 的启动盘号 → 不是 0x80 起(硬盘)就干脆不试,直接用内建子集
读 LBA 2047 的描述块 → 头 4 字节不是 'JFD1' 就放弃
按描述块里的 LBA/扇区数,把字库读进 0x200000
校验 0x200000 处是不是 'JOYF' → 是就切过去(读字形数填 font_glyphs)
```

三点说明:

* **地址为什么是 0x200000**:分页只恒等映射了前 4 MiB,2 MB 在里面,
  读进去就能当普通指针用(不用再建映射);
* **为什么读失败也不慌**:任何一步不对就退回内建子集,系统照常启动 ——
  字库是增强,不是必需品。软盘启动时走的就是这条路;
* 屏幕上那行 `font: loaded from disk (ATA), 40208 glyphs` 就是证据
  (`font: built-in subset, 416 glyphs` 说明它退回去了)。

## 5. FAT16(`kernel/fat.asm`)

只做"够用"的那一小块:根目录 + 8.3 短名。**没有**长文件名、**没有**子目录、**没有**删除。

引导扇区里用到的字段(偏移都是相对分区起点,`fat_mount` 逐个读出来):

| 偏移 | 含义 | 代码里的变量 |
|---|---|---|
| 11 | 每扇区字节数(必须是 512,不然直接放弃) | `fat_bps` |
| 13 | 每簇扇区数 | `fat_spc` |
| 14 | 保留扇区数(FAT 表从这后面开始) | `fat_reserved` |
| 16 | FAT 份数(通常 2) | `fat_nfats` |
| 17 | 根目录项数(每项 32 字节) | `fat_root_ents` |
| 22 | 每份 FAT 占几扇区 | `fat_size` |
| 510 | 0xAA55 签名(对不上就不是引导扇区) | — |

算出来的三个位置:`fat_fat_lba`(FAT 表)、`fat_root_lba`(根目录)、`fat_data_lba`(数据区起点),
加上 `fat_spc` 就能把"簇号"翻译成"扇区号":`LBA = fat_data_lba + (簇 - 2) * fat_spc`。
(簇 0 和 1 是 FAT 表自己用的保留值,所以数据簇从 2 开始。)

函数一览:

| 函数 | 干什么 |
|---|---|
| `fat_mount` | 读引导扇区,算好上面那些位置;`fat_ok` = 1 表示挂上了 |
| `fat_name83` | 把 `"hello.bin"` 变成目录项里的 11 字节 `HELLO   BIN` |
| `fat_find` | 在根目录里线性找这个名字,找到就记下**目录项所在的扇区和偏移** |
| `fat_next_cluster` | 查 FAT 表里的下一簇(带一扇区的 FAT 缓存 `fat_cache_lba`) |
| `fat_read_file` | 顺着簇链把文件读进内存,返回字节数(找不到返回 -1) |
| `fat_set_entry` | 改一个 FAT 项,**两份 FAT 都写** |
| `fat_alloc_cluster` | 找一个空闲簇,标记成链尾 |
| `fat_write_file` | 写文件:有就覆盖,没有就新建(占一个目录项) |
| `fat_list` | 列根目录(名字 + 字节数),`ls` 用的 |

### 写文件的完整流程

```
1. fat_find 找同名文件 → 找到就沿簇链把它标成空闲(相当于删掉旧内容)
2. 重新从第一个空闲簇开始,一个簇一个簇地写:写数据 → fat_set_entry 串上链
3. 新建的情况下,在根目录里占一个空目录项,填首簇号和文件大小
4. 发 FLUSH CACHE
```

第 2 步里的 `fat_set_entry` 会**把两份 FAT 都改掉** —— FAT16 故意存两份就是防这个,
只改一份的话文件系统在别的系统上看着就是坏的。测试里专门有一项离线断言盯着这点。

### 限制(想扩展就从这里挑)

* 只能根目录、只能 8.3 名字(长文件名需要 LFN 的校验和 + 目录簇链);
* 没有 `del`、没有子目录、没有时间戳(目录项里那几字节留着 0);
* 写文件不做"磁盘满"以外的错误恢复,也不检查簇是不是真的空闲(`fat_alloc_cluster` 只看
  FAT 项是不是 0)。

## 6. 往镜像里放文件:`tools/mkfat.py`

```bash
python3 tools/mkfat.py build/joyos-hd.img 6144 8 \
    README.TXT=progs/README.TXT \
    HELLO.BIN=build/HELLO.BIN
```

* 第 2 个参数是分区起始 LBA(必须和 `FAT_PART_LBA` 一致),第 3 个是分区大小(MB);
* 后面全是 `镜像里的名字=宿主机上的文件`;
* 每簇几个扇区是**自动挑**的:`mkfat.py` 会算一遍让簇数落在 FAT16 要求的
  `[4085, 65525)` 里(8 MB 时是 2 扇区/簇,数据区起点 LBA 6241,8143 个簇)。

`make hd` 会自动跑这一步(`Makefile` 里 `$(HDIMG)` 规则),所以平时只要:

```bash
make hd          # 构建 + 直接启动完整硬盘镜像
# 或者
./tools/run.sh --hd
```

## 7. 怎么验证它是真的(不是"看起来对")

磁盘相关的测试都在 `tests/qemu_test.py` 的 `--fontdisk` 档案里(`make test-hd-font`),
它用**两条互不相干的信道**:

**信道一:屏幕像素。** QEMU 无头跑,`monitor` 抓 `screendump`,把期望的文字用
`font/full-joyf.bin` 在 Python 里渲染成"有墨/无墨"网格,再去截图里找这个图案。
这条证明"内核认为自己显示出来了"。

**信道二:离线解析镜像。** 测试跑完先把 QEMU 关掉(让它落盘),然后**不看内核**,
用 `qemu_test.py` 里那个 70 行的 `Fat16` 类(纯 Python,自己算引导扇区字段、
自己走簇链)把 `build/joyos-hd.img` 当块设备读一遍,断言:

* `TEST.TXT` 真的出现在根目录里,内容真的是 `hello-from-fat16`(这是 shell 里
  `write test.txt hello-from-fat16` 写进去的);
* 两份 FAT 里那个簇项都是"链尾",也就是**两份 FAT 都被更新了**;
* 镜像里原来的 `README.TXT` / `HELLO.BIN` / `COUNT.BIN` 字节和仓库里的源文件**一模一样**;
* LBA 2047 的字库描述块 + LBA 2048 起的字库和 `font/full-joyf.bin` 字节一致。

这条证明"字节真的落在磁盘上了" —— 内核自己打印的 `wrote test.txt` 不算证据。
