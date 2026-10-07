# JoyOS(胡闹OS)

![JoyOS 硬盘模式:字库从磁盘读、FAT16 列目录、跑磁盘上的程序](docs/screenshot-fat.png)

上图是完整硬盘镜像的实拍:字库从磁盘读进来(40 208 个字形)、FAT16 挂上了,
`ls` 列目录、`run HELLO` 跑磁盘上的程序、`write` / `cat` 读写文件。

两个"用 int 0x30 写出来的组件":**计算器**(`run CALC`,定点小数、加减乘除、平方)
和**全屏文本编辑器**(`run EDIT`,方向键、存盘、打开):

![计算器](docs/screenshot-calc.png)
![文本编辑器](docs/screenshot-edit.png)

**vi 也搬进来了** —— 不是从头写的,是公有领域的 STEVIE(vim 的前身):

![vi 跑在 JoyOS 上](docs/screenshot-vi.png)

还有图形模式(800×600 VBE)里敲 `info` 和 `zh` 的样子:

![JoyOS shell](docs/screenshot.png) ![中文显示](docs/screenshot-zh.png)

一个**从头写的、4000 多行的 x86 操作系统**,能启动、能分页、能读硬盘、
有自己的文件系统和 shell,还能**跑你写的小程序**。
没有引用任何现成内核 —— 引导扇区是手写的机器码级汇编,VGA 输出、中断、页表、ATA 驱动全靠自己填。

写它的目的不是"做个能用的系统",而是**把 计算机启动到底发生了什么 一层层摊开给你看**:
从 BIOS 把 512 字节读进 0x7C00,到 GDT/保护模式/IDT/分页/键盘中断/ATA 读盘/FAT16,
每一段都在源码注释里讲清楚,包括**踩过的坑**(下面有专门一节)。

> 你可以随便改。改坏了 `make test` 会告诉你哪一项坏了。
>
> 想最快见效?**别碰内核,写个程序丢到磁盘上跑** —— 见 [docs/programs.md](docs/programs.md)。

---

## 键盘打中文/日文/韩文:Alt 码位输入

键盘只认 ASCII?**按住左 Alt,敲十进制码位,松开 Alt** —— 就打出那个字符:
`Alt+20013` = 中、`Alt+22909` = 好、`Alt+128512` = 😀。
原理见 [docs/quickstart.md](docs/quickstart.md) 第 7 节(内核里把码位编成 UTF-8 塞进按键缓冲)。

因为是"码位直通",**日文/韩文/emoji 一样能打**(磁盘字库里有全平假名、全片假名、
全部谚文音节、CJK 基本区两万多字)。手敲数字太累,有个转换脚本:

```bash
python3 tools/text2alt.py "日本語 한국어"        # 每个字 = Alt+多少,顺便查字库有没有这个字形
python3 tools/text2alt.py --line "你好,世界"     # 只要一行数字
python3 tools/text2alt.py --decode 26085 26412   # 反着来:码位 → 字
python3 tools/text2alt.py --send build/qmp.sock "こんにちは"
                                # ↑ 直接打进正在跑的虚拟机(make hd 已经把 QMP 开在 build/qmp.sock)
```

大小写:**Shift 和 Caps Lock 都管用**(字母是 `Shift XOR Caps Lock`,和真键盘一样 ——
两个都开反而是小写),Caps Lock 按一下还会给键盘发 `0xED` 把灯点对。

## 用纯 C 写程序(SDK)

不想碰汇编?`bin/joyos-cc` 一条命令把你的 `.c` 编成 JoyOS 能跑的 `.BIN`,
`bin/joyos-run` 直接造镜像开机看结果 —— 见 [docs/quickstart.md](docs/quickstart.md)。

**vi 已经不是主线了**:STEVIE 移植搬去了 `extensions/vi/`,默认镜像里没有它,
`make ext-img` / `make run-ext` 才构建和启动(规矩见 [extensions/README.md](extensions/README.md))。

## 1. 现在能干什么

| 功能 | 说明 |
|---|---|
| 启动 | 512 字节引导扇区,BIOS 传统 MBR 方式加载到 `0x7C00` |
| **多扇区读盘** | 一次读多个扇区把 64 KiB 内核搬进内存;**LBA(EDD)和 CHS 两条路径都有**,自动探测 |
| 保护模式 | GDT(代码段 + 数据段,平坦 4 GiB)、`CR0.PE`、32 位段寄存器全部就位 |
| IDT | 256 个中断门,0~31 号 CPU 异常都有处理程序,出错就红屏报**异常名 / 错误码 / EIP / CS / EFLAGS**(页错误还会报 CR2) |
| 分页 | 页目录 + 页表,**恒等映射 0~16 MiB**(所以指针就是物理地址)+ VBE 帧缓冲高地址窗口;运行期能**动态建表**(`pmap`),物理页池 = 位图分配器 12 MiB(`pmem` / `ptest`);**跑程序时进按需分页**:每个程序一套空地址空间,碰到哪页才补哪页(见第 5 节) |
| 键盘 | 8259A 重映射到 `0x20`,IRQ1 中断方式收键,扫描码翻译表(含 Shift)、**Caps Lock**(顺带给键盘发 `0xED` 点灯)、方向键/PgUp 等扩展键、64 字节环形缓冲 |
| **ATA 驱动** | 直接操作 `0x1F0~0x1F7` 的 PIO 读写硬盘(分块 + 每扇区等 DRQ + FLUSH CACHE),见 [docs/filesystem.md](docs/filesystem.md) |
| **FAT16 / FAT32 文件系统** | 按 BPB 自动认 FAT16 还是 FAT32(`make test-hd32` 跑 88 MB 的 FAT32 镜像);挂载 / 找文件 / 读 / **写**(建目录项、分配簇、更新两份 FAT)/ `ls` 列目录 |
| **子目录** | `ls DOCS`、`cat DOCS/NOTE.TXT`、`cd` / `mkdir` / `rmdir`、路径里 `/` 和 `\` 都认;子目录里的程序 `run DOCS/HELLO.BIN` 和 `int 0x30` 的读写接口都跟着当前目录走;子目录满了会自动往簇链上接新簇 |
| **跑磁盘上的程序** | `run HELLO`:从磁盘读进来 → 给这个程序**建一套自己的页目录**(私有页,见下) → 切 CR3 → 执行(镜像超 512 KB 直接拒绝),程序用 `int 0x30` 调用内核(见 [docs/programs.md](docs/programs.md)) |
| **程序接口 15 个功能** | 打印/颜色/收键 + 清屏、读写文件、定位光标、读键事件(方向键)、屏幕尺寸、程序参数、定位画字、**蜂鸣器(14 号 `beep`)** —— 够写全屏程序,还够唱一首 |
| **组件:计算器** | `run CALC`:`+ - * /`、小数点、平方,自己实现定点小数(6 位小数),除零/溢出都会报错 |
| **组件:文本编辑器** | `run EDIT [文件名]`:全屏编辑,可见光标(亮绿 `_`)、方向键/Home/End/Delete/PgUp/PgDn、`Ctrl-S` 存盘、`Ctrl-F` 查找(大小写不敏感、找完自动绕回开头,再按一次找下一个)、`Ctrl-Q` 退出 |
| **组件:蜂鸣器 + 文本谱播放器(不含示例谱,自备谱文件)** | `run PLAY MYSONG.TXT`:PC 喇叭按 FAT 上的**纯文本谱**唱歌(注释、音名 `C4`~`B5` 带 `#`、时值、tempo 都能改);`run PLAY --list` 只解析不出声、把谱子打到屏幕上(可测);内核那头就是 14 号 `beep`,忙等标定见 [kernel/speaker.asm](kernel/speaker.asm)(见 [docs/quickstart.md](docs/quickstart.md)) |
| **键盘扩展键** | `0xE0` 前缀的方向键/Home/End/Del/PgUp/PgDn,还有 Ctrl 组合键(Ctrl-S / Ctrl-Q / Ctrl-F) |
| **vi(STEVIE 移植)** | `run VI NOTES.TXT`:公有领域的 vi 克隆(STEVIE 3.68,vim 的前身),约 10 900 行 C 一行没改,只把平台层换成 `int 0x30` —— 插入模式、方向键、`:w` 存盘、`:q` 退出(移植记在 [docs/vi.md](docs/vi.md)) |
| **C 语言支持** | 普通 `gcc -m32` 就能编(`make cc-check`);自带 crt0 + 迷你 libc(malloc/printf/stdio)+ `joyos.h`,程序照样是平铺二进制丢进 FAT16 跑(见 [docs/c-programs.md](docs/c-programs.md)) |
| **图形模式** | 实模式 stub 里用 VBE 问出 **800×600×32 线性帧缓冲**模式,页表把帧缓冲映射进来,终端直接往显存画像素 |
| **点阵字库** | GNU Unifont:内核里编了 416 字形保底,硬盘镜像上放**完整 40 208 个字形**(1.7 MB),启动时用 ATA 读进内存 |
| 中文显示 | ✅ 一个汉字 16×16 直接画在帧缓冲上;文本是标准 **UTF-8**(四字节 emoji、坏字节替换符都处理了) |
| 终端 | 会滚屏的终端(文本模式走 VGA 文本缓冲,图形模式走帧缓冲),支持 `\n` `\r` `\b` |
| shell | `help` `echo` `zh` `clear` `info` `page` `fault` `reboot` `ls` `cat` `write` `run`,带退格的行编辑 |

## 2. 快速开始

需要 `nasm`、`qemu-system-i386`、`python3`:

```bash
# Debian/Ubuntu
sudo apt install nasm qemu-system-x86 python3

make                    # 构建两个镜像:build/joyos.img(软盘)+ build/joyos-hd.img(硬盘)
make run                # 软盘镜像,开窗口在 QEMU 里跑(自己敲键盘玩)
make hd                 # 完整硬盘镜像:字库 + FAT16 + 示例程序
make test               # 无头自动化测试:7 组,全过会打 ✅
make clean              # 清掉 build/

./tools/run.sh          # 启动脚本:自动构建 + 选"怎么挂盘"
./tools/run.sh --hdd    #   把软盘镜像当硬盘挂 → 会走 LBA/EDD 那条路
./tools/run.sh --hd     #   完整硬盘镜像(推荐:能 ls / cat / run)
./tools/run.sh --div    #   开机就除零 → 直接看 panic 屏
./tools/run.sh --gdb    #   开 gdb 调试端口(-s -S)
./tools/run.sh --monitor #  把 QEMU monitor 接到终端(能 sendkey / xp 读显存)
./tools/run.sh --dry-run #  只打印 qemu 命令行,不启动(排错用)
QEMU_DISPLAY=none ./tools/run.sh   # 无窗口跑
```

在硬盘模式里值得敲一遍的:

```
> ls                    ← 列 FAT16 根目录
> cat README.TXT        ← 读一个 UTF-8 文本文件(里面有中文)
> run HELLO             ← 跑磁盘上的程序
> write MY.TXT hello    ← 写文件(真的落到磁盘上)
> cat MY.TXT            ← 再读回来
> run                   ← 裸敲 run 会打印程序接口说明书
> run CALC              ← 计算器:12.5*4=  7s(平方)  c(清零)  q(退出)
> run EDIT              ← 编辑器:改 NOTES.TXT,方向键移动,Ctrl-S 存盘,Ctrl-F 查找,Ctrl-Q 退出
> run EDIT MY.TXT       ← 也可以指定文件(不存在就是新文件)
> run VI NOTES.TXT      ← vi(STEVIE 移植):i 进插入模式,ESC 回普通模式,:w 存盘,:q 退出
> run PLAY MYSONG.TXT   ← 蜂鸣器按文本谱唱歌(谱子自己写,音名/时值/tempo 都在 txt 里)
> run PLAY --list MYSONG.TXT ← 只解析:把谱子打到屏幕上(不出声,改谱时拿它对答案)
> ls DOCS               ← 列子目录(目录显示成 <DIR>)
> cat DOCS/NOTE.TXT     ← 路径里带目录也行(斜杠/反斜杠都认)
> cd DOCS               ← 进目录,提示符变成 DOCS>
> mkdir SUB              ← 建目录(自动写好 . 和 ..)
> rmdir SUB              ← 删空目录(非空的会拒绝,不会把文件弄丢)
> cd ..                  ← 回上一层;cd / 回根目录
> run DOCS/HELLO.BIN    ← 子目录里的程序照样能跑
```

QEMU 窗口里的常用键:`Ctrl+Alt+g` 放开鼠标键盘抓取,`Ctrl+Alt+2` 切到 monitor 控制台(`Ctrl+Alt+1` 切回来)。

**想听 `run PLAY` 出声**,`make hd` 那条 QEMU 命令不够:QEMU 7 以后 PC 蜂鸣器要显式接一个音频后端才响,
用这一条(要 PC 扬声器仿真 + 一个 audiodev,PA/pipewire 宿主用 `pa`;方波**没有音量控制**,想小声就在宿主
混音器里把这条流单独调小 —— 下面命令里的 `out.stream-name=JoyOS` 就是给它起个认得出的名字。
注意 `-audiodev` 里**没有** `out.volume=` 这种参数,QEMU 会拒绝启动):

```bash
qemu-system-i386 -machine pcspk-audiodev=snd0 -audiodev pa,id=snd0,out.stream-name=JoyOS \
    -drive file=build/joyos-hd.img,format=raw,if=ide,index=0 -boot c
```

没声音先试 `-audiodev none,id=snd0`(不出声但至少不报错)或者 `pulseaudio`/`pipewire` 的 `pa` 后端;
VirtualBox 不仿真 PC 扬声器,那里是听不见的(记在 [docs/known-issues.md](docs/known-issues.md))。
谱子怎么写、怎么改自己的歌:[docs/quickstart.md](docs/quickstart.md)。

`make test` 的 7 组(每组都真的启动 QEMU、抓屏、断言屏幕内容):

| 目标 | 测什么 |
|---|---|
| `test-fda` | 当**软盘**启动 → 走 CHS 退回路径 |
| `test-hda` | 当**硬盘**启动 → 走 LBA/EDD 路径 |
| `test-div` | 故意除零 → 0 号异常,panic 屏要出现 |
| `test-pgfault` | shell 里敲 `fault` → 14 号页错误,CR2 要等于出错地址 |
| `test-kbd` | 用 QEMU monitor 的 `sendkey` **真按键**,验证回显、Shift、回车、退格 |
| `test-shell` | 敲 `help`/`info`/`page`/`echo`/`clear`,验证命令、滚屏、清屏、中文、UTF-8 边界 |
| `test-hd-font` | 硬盘镜像:字库从磁盘读、`ls`/`cat`/`write`/`run`、**计算器的八组算式**、**编辑器的敲字/存盘/退出**,最后**离线解析镜像**证明字节真落盘 |

最后那一项有两套独立的验证手段:一套看屏幕像素(把期望的文字用字库渲染成图案再去截图里找),
一套在 QEMU 关掉之后**直接解析镜像文件的 FAT 分区**(FAT16/FAT32 都认,不信内核自己打印的"写成功了")。

```bash
make test-hd-font  # 单独跑某一组
make div           # 构建"开机就除零"的镜像,自己开着 QEMU 看 panic 屏
python3 tests/qemu_test.py build/joyos-hd.img --hda --dump   # 只把屏幕打出来,不做断言
```

## 3. 源码地图

```
boot/boot.asm          引导扇区(512 字节内):探 LBA/CHS 读盘 → 跳 stub
kernel/stub.asm        实模式 stub(搬到 0x500):问 VBE 要图形模式 → GDT → 保护模式
kernel/start.asm       内核镜像入口:拼装 stub 之后的 32 位部分(顺序有讲究,见注释)
kernel/kmain.asm       内核入口 + 终端驱动(滚屏、光标、十六进制/十进制打印)
kernel/utf8.asm        UTF-8 解码(坏字节 → U+FFFD,防溢出/代理区都拦了)
kernel/idt.asm         IDT、32 个异常入口、panic 屏,idt_install 负责装门
kernel/paging.asm      页目录 + 页表 + 开分页 + 按需分页(缺页补页、程序私有空间)
kernel/keyboard.asm    8259A 重映射、IRQ1 键盘中断、扫描码翻译、环形缓冲
kernel/fbterm.asm      帧缓冲终端:自己画字(光标/换行/滚屏/颜色)
kernel/vgafont.asm     文本模式终端分支 + 码位分发(图形模式走 fbterm)
kernel/ata.asm         ATA(IDE)PIO 驱动:读扇区 + 写扇区 + FLUSH CACHE
kernel/fontdisk.asm    启动时把完整字库从磁盘读进 0x200000(读不到就用内建子集)
kernel/fat.asm         FAT16/FAT32:挂载(BPB 自动判)/找文件/读/写/列目录/子目录(cd/mkdir/rmdir)
kernel/api.asm         int 0x30 程序接口(打印字符串/数字/码位、设颜色、等按键)
kernel/speaker.asm     PC 蜂鸣器:14 号 beep(PIT 通道 2 定音高 + 0x61 开关扬声器,毫秒是忙等估的)
kernel/shell.asm       shell:行编辑、命令解析、各命令实现
progs/HELLO.asm        示例程序(最简)      —— 编译成 HELLO.BIN 放进镜像
progs/COUNT.asm        示例程序(打印/颜色/码位)
progs/CALC.asm         组件:计算器(定点小数,自己算 ±2147.483647)
progs/EDIT.asm         组件:全屏文本编辑器(方向键 + 存盘 + 打开)
progs/TOUCH.asm        示例程序(按需分页演示:一页页碰内存再验证)
progs/NOTES.TXT        放进镜像的示例文本(编辑器默认打开它)
progs/CHELLO.c         C 写的示例程序(printf / malloc / 参数 / 读文件)
progs/PLAY.C           组件:文本谱播放器(读 FAT 上的谱子 → int 0x30 的 beep;--list 只解析;不含示例谱)
include/joyos.h        C 程序用的头:15 个 int 0x30 包装 + 颜色/键值常量
lib/minic.c            迷你 libc(约 600 行:字符串/内存/printf/一点点 stdio)
lib/crt0.asm           C 程序入口:清 BSS → main() → ret 回 shell
lib/joyos.ld           链接脚本:0x120000 + 平铺二进制 + BSS 边界符号
third_party/stevie/    公版 STEVIE(vi 克隆)的源码 + 我们写的 joyos.c 后端(替换 nt.c)
progs/README.TXT       也放进镜像,shell 里 cat README.TXT 能看(UTF-8 中文)
tools/mkimg.py         拼镜像:boot(第 0 扇区)+ stub + kernel + 磁盘字库
tools/mkfat.py         在镜像里造 FAT16 或 FAT32 分区(--fat32),并把文件/目录放进去
tools/unifont2bin.py   Unifont .hex → JOYF 二进制字库 / VGA 字模 / 中文文案
tools/mkfontsubset.py  从完整 .hex 里抽出要用的字形(生成入库的小子集)
tools/text2alt.py      文字 → Alt 码位序列(查字库 / 直接打进 QEMU),见上面的"日文/韩文"
tools/run.sh           QEMU 启动脚本(软盘/硬盘/完整硬盘/panic 演示/gdb/monitor/dry-run)
tests/qemu_test.py     无头测试:HMP 抓屏 + sendkey 注入按键 + QMP 打码位 + 离线解析镜像
tests/probe_disk.asm   探针:实测"软盘到底支不支持 LBA 读"(见第 6 节)
```

内核是**平坦二进制 + `%include`**,没有用链接器 —— 所有 `.asm` 在同一个翻译单元里,
所以 `kernel/*.asm` 之间可以直接互相调用。这样简单,代价是符号名不能重复,
而且**第一个被 include 的文件决定入口地址**(`kernel/start.asm` 里有注释说明)。

内存布局(写死在代码里):

```
0x000000 - 0x0004FF   中断向量表 / BIOS 数据区
0x001000              页目录                  (paging.asm,PD_ADDR)
0x002000              页表:恒等 0-4 MiB        (PT_LOW)
0x003000              页表:恒等 4-8 MiB        (PT_ID1)
0x004000              页表:VBE 线性帧缓冲      (PT_LFB,按帧缓冲物理地址对齐)
0x005000              页表:恒等 8-12 MiB       (PT_ID2)
0x006000              页池位图(384 字节)      (pmem.asm,PMEM_BITMAP)
0x007000              页表:恒等 12-16 MiB      (PT_ID3)
0x007C00              引导扇区(512 字节)
0x010000 - 0x02FFFF   内核区(128 KiB = 256 扇区,实到约 48 KiB)
0x090000              内核栈(往下长)
0x0B8000              VGA 文本缓冲(80×25,每格 2 字节:字符 + 颜色)
0x100000              FAT 扇区缓冲           (fat.asm 的 FAT_BUF)
0x110000              cat 的文件缓冲         (shell.asm 的 FILE_BUF)
0x120000 - 0x19FFFF   程序镜像(虚拟地址)    (shell.asm 的 PROG_ADDR;物理页每次运行都换,按需才给)
0x1A0000 - 0x1EFFFF   堆(malloc,320 KB,虚拟) (include/joyos.h;同样是每程序私有页,按需才给)
0x1F0000              读磁盘描述块的临时缓冲 (fontdisk.asm)
0x200000 - 0x3AF110   完整字库(从磁盘读进来,1.7 MB)
0x400000 - 0xFFFFFF   物理页池(12 MiB)       (pmem.asm,3072 页 × 4 KiB,位图记账)
0xFD000000            VBE 线性帧缓冲(单独挂一张页表,映射到它所在的 4 MiB 窗口)
```

0~16 MiB 全是**恒等映射**(虚拟地址 = 物理地址),所以内核里指针就是物理地址,
写代码不用想 MMU;16 MiB 以上没映射(踩了就吃 14 号页错误)。页池只从 0x400000
往上发,因为低 4 MiB 被上表这些固定区域占满了 —— 与其一条条列"这些不许用",
不如整段划出去。

**唯一的例外是跑程序的时候**:0x120000~0x1EFFFF 那 208 页在内核里照旧是恒等映射
(所以 shell 能读能写),但在程序那套页表里它们是"不存在"的 —— 程序碰到哪页,
缺页处理才从页池现拿一页(见第 5 节的按需分页)。

## 4. 图形模式(VBE + 帧缓冲)

文本模式那条路只能放 63 个汉字(一个汉字要占两个 8 像素宽的字符格),所以正经中文
得进图形模式 —— 屏幕就是一块显存,画什么全由自己决定。

```
实模式 stub    int 0x10 AX=4F00/4F01 列模式 → AX=4F02 设成 800×600×32(带线性帧缓冲)
               → 把 帧缓冲物理地址/宽/高/pitch/色深 写进 BOOTINFO(0x8000)
分页           帧缓冲在 0xFD000000,不在恒等映射的 0~16 MiB 里
               → 按 4 MiB 对齐算页目录项,挂一张页表把它映射进来(不映射第一次写像素就吃页错误)
帧缓冲终端     kernel/fbterm.asm:码位 → 二分查找字库 → 逐行取位 → 往显存写 4 字节像素
               (颜色从文本模式的属性字节换算成 RGB;滚屏就是 memmove 整块显存往上 16 行)
```

坑:16×16 的汉字一行是**两个字节**,低地址那个才是左半边 —— 一开始我用 bit15 开始往左画,
结果**汉字左右两半反了**(每个字看着像"对折过"的样子)。修法是 `rol ax, 8` 把两个字节换回来。

## 5. 磁盘:字库、FAT16、跑程序

这一块单独写了一页:**[docs/filesystem.md](docs/filesystem.md)** —— 镜像的 LBA 地图、
ATA PIO 的寄存器顺序和两个坑、磁盘字库怎么加载、FAT16 的字段和写文件流程、
`mkfat.py` 怎么用、测试怎么用两条信道证明"字节真的落盘了"。

想写程序的话看另一页:**[docs/programs.md](docs/programs.md)** —— `int 0x30` 的六个功能、
为什么用中断而不是 `call` 内核函数、程序的内存/栈约定、怎么加进镜像。

一句话版:

```
run HELLO      → fat_stat 看大小 → fat_read_file 先读进 0x120000(暂存)
               → space_create 建一套空地址空间(页目录 + 页表两页,窗口里的页一页都不给)
               → 切 CR3 → call 0x120000 → 程序碰到哪页,页错误才从暂存区补哪页
               → 程序 ret 回 shell → 切回 CR3 → 补出来的页连页表一起还给页池
程序里:         mov eax, 0 / mov esi, 字符串 / int 0x30   ← 打印一行
```

### 每个程序有自己的地址空间(而且是按需给的)

跑程序之前,内核给它现搭一套页表(**见 [kernel/paging.asm](kernel/paging.asm)
的 `space_create`**):

```
页目录   = 内核页目录的副本        (内核、IDT、VGA、字库、帧缓冲都还在)
页表[0]  = PT_LOW 的副本,但 0x120000~0x1EFFFF 的 208 项**清成"不存在"**
私有页   = 一页都不预先给 —— 程序碰到哪一页,14 号页错误才现补哪一页
```

所以:程序的**虚拟地址不变**(还是链接到 `0x120000`,程序自己不用改),
**物理页每次运行都是新的一批**,而且**只有它真正走过的页才会拿到内存**:

```
> run HELLO.BIN
running HELLO.BIN
address space: CR3 = 0x00400000  (own page directory + demand paging)
Hello from HELLO.BIN - I was loaded from the FAT16 disk!
program returned to the shell
address space destroyed: 3 page(s) back to the pool
demand paging: 1 page(s) faulted in (image 1 + heap 0), first page 0x00402000
```

249 字节的程序**只要 1 页**(以前是把 208 页全给它)。主动去踩内存的是
[progs/TOUCH.asm](progs/TOUCH.asm),`run TOUCH` 会一页一页碰 32 页堆 + 一页 `.bss`,
然后回头检查每一页都还是自己写进去的标记:

```
> run TOUCH.BIN
  heap: touched 32 pages (4 KiB each), wrote 0xA5 into every one of them
  pages that were NOT zero before my write: 0     ← 现给的页必须是干净零页
  pages that did not read back what I wrote: 0     ← 每页都真的归自己
  page beyond the file (bss at 0x184000): was zero, as it should be
demand paging: 34 page(s) faulted in (image 2 + heap 32), first page 0x00425000
```

补页的流程(都在 [kernel/paging.asm](kernel/paging.asm) 的 `page_fault_try_handle`
和 [kernel/idt.asm](kernel/idt.asm) 的 `isr_common` 里):CR2 是出错地址 → 判断它
落在镜像窗口还是堆窗口(窗口外就照旧红屏 panic)→ 从页池拿一页、清零 →
镜像窗口里"文件之内"的部分从暂存区拷过来("文件之外"就是 `.bss`,留零页)→
填页表 + `invlpg` → `iret` 回去**重执行那条指令**。程序完全感觉不到。

几个老实交代的地方:

- 没有 swap、没有页置换、没有写时复制:页一旦补进来就留到程序结束;
- 窗口里的**空洞也会给页**(程序只是读一下 0x1A0000 附近的地址,也会拿到一页零页);
- 暂时**不给程序自己长栈**:栈还是 shell 的栈(内核那套页表里);
- 内核窗口继续恒等映射,所以 `int 0x30` 照旧能用 —— **不需要 ring 3**,
  程序传给内核的指针也照旧解得开(那会儿用的就是程序这套页表)。

## 6. 踩过的坑(这部分才是精华)

### 6.1 软盘的 BIOS 不支持 LBA 扩展读

最开始只写了 `int 0x13 AH=42h`(LBA 扩展读,一次读 8 个扇区),结果 QEMU 里直接 `DISK READ FAILED`。

用 `tests/probe_disk.asm` 探针实测了三种读法(同一个镜像,分别当软盘和硬盘挂):

| 读法 | 软盘 `-fda` | 硬盘 `-hda` |
|---|---|---|
| `AH=42h` LBA 读 8 扇区 | ❌ `CF=1 AH=01`(功能无效) | ✅ 成功,数据正确 |
| `AH=02h` CHS 读 1 扇区 | ✅ 成功,数据正确 | ❌ `CF=1 AH=20`(几何不对) |
| `AH=41h` EDD 支持探测 | `CF=1`(老实说"不支持") | `CF=0` |

**结论**:软盘的 BIOS 压根不认 LBA 扩展读,只有硬盘认。所以正确做法是:

1. 先问 `AH=41h` 支不支持(检查 `CF`、`BX=0xAA55`、`CX` 的 bit0)
2. 支持 → 走 LBA,一次读 8 扇区
3. 不支持 → 退回 CHS,**而且每次都要截断到"本磁道还剩几扇区"**(CHS 读不能跨磁道)

`boot/boot.asm` 现在两条路都有,`make test-fda` / `make test-hda` 各测一条。
这个探针留在 `tests/probe_disk.asm` 里 —— 你要是换个 BIOS 环境,先跑它。

### 6.2 一次要 255 个扇区,只有第一个是真的

读磁盘字库时,命令发出去状态也正常,但内存里**只有第一个扇区是数据,后面全是 0** ——
屏幕上每个字都成了 missing glyph 的方框。

原因:ATA 规范允许驱动器**只传一部分**,PIO 模式下每传一个扇区都得等一次 `DRQ`。
改成分块(16 扇区一块)+ 每扇区都 `ata_wait_drq` 才读全。

### 6.3 `mov al, 0xE0` 把 LBA 弄丢了

选盘的字节要写进 `al`,而 LBA 正好在 `eax` 里 —— 低 8 位当场被覆盖,
"读 LBA 0x1E0"变成"读 LBA 0x00"。教训是**看内存里的字节,别信"函数返回成功"**。

### 6.4 `mov ax, 0x10` 把系统调用号冲掉了

`int 0x30` 的入口要先把自己换到内核数据段(`mov ax, 0x10`)—— 而功能号正好在 `eax` 里。
于是分发器看到的永远是 `0x10`,所有功能都匹配不上。修法是先把功能号存到 `ebp`。

这类"低 16 位被顺手写掉"的坑出现了两次(6.3 和 6.4),都是同一个原因:
**保护模式里段寄存器只有 16 位,而 `eax` 的低半截在别处有用。**

### 6.5 程序加载地址选在了字库中间(最阴的一个)

程序本来是加载到 `0x300000` 的 —— 离内核很远,看着挺顺眼。但完整字库是读到 `0x200000` 的,
1.7 MB 一直铺到 `0x3AF110`,**`0x300000` 正好落在点阵数据中间**:
程序一载入就把几个汉字的点阵覆盖掉了(249 字节的 `HELLO.BIN` 踩掉 U+782A~U+7832 九个汉字,
"砰"会画成花屏)。

阴在哪:**两个功能单独测都是对的** —— `run HELLO` 正常、中文也正常显示,
只有"跑完程序之后再显示那几个特定的字"才看得出来,我一开始甚至怀疑是字库文件坏了。

修法三件事:

1. 加载地址挪到 `0x120000`(上面是 `FILE_BUF`,下面是字库,中间 896 KB 全是空的);
2. `run` 先用 `fat_stat` 看目录项里的文件大小,太大直接拒绝,不让它读进来把字库盖掉
   (当时按 `PROG_MAX_SIZE` = 896 KB 判;后来程序改用"私有镜像窗口",
   实际上限变成 512 KiB —— 见第 5 节);
3. 测试里加了两道锁:一道**哨兵**(`run HELLO` 之后屏幕必须能正确画出 U+7830 砰,
   它的点阵就在以前会被踩掉的那段里),一道**静态检查**(从源码里读出 `PROG_ADDR` /
   `FONT_LOAD_ADDR` 和字库文件大小,算程序区和字库区有没有重叠)。
   两道锁都实测过"改回旧地址就会红"。

顺带记一个算错过的地方:字形记录的是**相对数据区**的偏移,所以字形地址是
`字库基址 + data_off + off`,不是 `基址 + off` —— 漏掉 `data_off` 差了 482 KB,
"哪几个字被踩掉"的结论会全错。**偏移量属于哪个基准,比偏移量本身重要。**

### 6.6 panic 屏里 EFLAGS 多了个 bit16,不是 bug

除零的 panic 屏打出 `EFLAGS = 0x00010046`,而开机时明明是 `0x00000046`,多出来的 `0x10000` 是 bit16(RF,Resume Flag)。
这是 CPU 自己加的:**故障类异常会把 RF 压进异常帧**,这样 `iret` 回去重试那条指令时不会立刻又炸一次。
我为了这个 `0x10046` 查了一轮(还先把它错看成了 bit8 的 TF),最后在 `idt.asm` 里写清楚了。

### 6.7 同一行连续打印会被自己盖掉 / `div` 会冲掉颜色寄存器

- 早期 VGA 驱动每次打印都"回到行首",导致同一行第二次 `print` 把第一次的内容盖了 ——
  后来改成**只有换行才重新定位**。
- 打印十进制时用 `div`,而 `div` 会把 `edx` 当余数输出 —— 而颜色正好存在 `dl` 里,
  结果数字颜色全乱。改成**颜色存内存**,不放在寄存器里。

### 6.8 VGA 文本模式只有 ASCII 字形

屏幕上写中文会变成乱码(BIOS 自带字模只有 ASCII)。

别想着"换个字模就能显示中文":VGA 文本模式一个字符格**只有 8 像素宽**
(字模是 8×N 的点阵,高度可以用 CRTC 的 Maximum Scan Line 调到 16 甚至 32),
而标准汉字是 **16×16** —— 8 像素宽的格子根本塞不下一个汉字,换字模也救不了。
真要显示中文只有进图形模式自己画点阵(见第 4 节)。
(文本模式那条路我也试到底了:字模塞进 VGA plane 2、汉字劈成两个字符格,
寄存器细节写在 [font/README.md](font/README.md) 里,但上限只有 63 个字,所以默认走图形模式,
那个实验仍可用 `make run-font` 跑。)

### 6.9 `not` 不改标志位(页池分配器跳过了一整段空闲页)

位图分配器找空闲页,第一版我这么写:

```asm
    mov eax, [esi + edx*4]
    not eax                ; 0 位(空闲页)取反变成 1
    jnz .found             ; ✗ 这个 ZF 是**上一条**指令留下的
```

`not` 和 `mov` 一样**不影响标志位**。于是 `jnz` 判断的是别人剩下的标志,
结果全看运气:页池明明 3072 页全空,`ptest` 第一次分配却拿到第 33 页(`0x00420000`),
前面 32 页像"已被占用"一样被跳过。换成真正会设标志的指令就好:

```asm
    cmp eax, -1            ; 全 1 = 这个 dword 全占满
    jne .found
```

坑点:`not` / `mov` / `lea` 不动标志位,后面别紧跟条件跳转。
(`inc`/`dec` 只是**不改 CF**,ZF/SF 照改,所以 `inc edx` + `cmp` 那套是安全的。)

### 6.10 "建空间"把"镜像多大"一起清了(程序跑的是 208 页零字节)

按需分页第一版:CPU 一碰 0x120000 就红屏,报的却是

```
EXCEPTION 0E: page fault
EIP = 0x00200008   CS = 0x00000008   EFLAGS = 0x00010203
CR2 (faulting address) = 0x5CD90000
```

CR2 是个野地址(不是 0x120000),说明**第一次补页其实成功了**,程序跑起来了 ——
只是跑的内容不对。把物理内存 dump 下来读 `space_*` 变量才看清:

```
space_img_bytes = 0x00000000     ← ✗ 镜像大小是 0
space_pf_run    = 0x000000d0     ← 补了 208 页 = 整个窗口一页不落
pf_off          = 0x0007f000
pf_len          = 0x00000000     ← 每页都算"文件之外",一句都没拷
```

`space_img_bytes` = 0 时,补页逻辑认为**整个窗口都是 `.bss`**,于是每一页都给零页:
程序执行的是 208 页的 0 字节(`add [eax], al` 一路乱跳),最后跳到 0x00200008 那种
野地方 → 二次页错误 → 红屏。

根因不是补页逻辑,是**调用顺序**:`cmd_run` 里先 `space_set_image`(写大小)、
后 `space_create`(建空间),而 `space_create` 开头会把自己那堆状态清零 ——
顺手把刚写进去的大小也清了。修法两条:create 里**不许清输入参数**
`space_img_bytes`,调用顺序改成 create → set_image。教训:初始化函数"重置自己的状态"时,
别把**别人刚给你的输入**一起重置 —— 这类症状(数据全是 0)和"逻辑写错"长得一模一样,
最省事的查法是 dump 内存看变量,而不是盯着代码猜。

## 7. shell 命令

```
help          列出命令
echo <text>   把文字打回来
zh            显示中文(点阵字库,直接 blit 到帧缓冲)
clear         清屏
info          CR0/CR2/CR3/CR4、IDT 基址与限长、段寄存器、读盘方式
page <hex>    逐级走页表,查虚拟地址映射到哪(例:page 0x400000 / page 0x8000000)
pmem          物理页池:总页数、已用、空闲、位图地址
pmap <va>     从页池拿一页,动态建页表映到虚拟地址(玩分页最直接的一条)
pumap <va>    解掉映射并把页还回池子(页表空了会一起回收)
ptest         自测:分配→建表→虚拟地址写/物理地址读→解映射→归还,查有没有泄漏
fault         故意踩没映射的地址,看页错误 panic 屏
reboot        重启(通过 8042 键盘控制器)
ls            列 FAT16 根目录(名字 + 字节数;硬盘模式才有)
cat <file>    把文件(UTF-8 文本)打出来,中文能直接看
write <f> <t> 写文件(创建或覆盖,真的落到磁盘上)
run <file>    给程序建一套独立地址空间(按需分页)再跑(名字不带点会自动补 .BIN;
              裸敲 run 打印接口说明;跑完会报补了多少页:run TOUCH 最能看出来)
```

`page` / `pmap` 的输出示例(这就是分页在干的事):

```
> page 0x400000          ← 恒等映射:虚拟地址 = 物理地址
virtual      = 0x00400000
PDE index    = 0x00000001 [1] = 0x00003003  present + writable
PTE index    = 0x00000000 [0] = 0x00400003  present
physical     = 0x00400000
> page 0x2000000         ← 16 MiB 以外没映射
virtual      = 0x02000000
PDE index    = 0x00000008 [8] = 0x00000000  PDE not present -> would page-fault
> pmap 0x8000000         ← 现建一张页表,拿页池里的物理页映上去
mapped 0x08000000 -> physical 0x00400000  (page table created on demand; check with: page <va>)
> page 0x8000000
virtual      = 0x08000000
PDE index    = 0x00000020 [32] = 0x00401003  present + writable
PTE index    = 0x00000000 [0] = 0x00400003  present
physical     = 0x00400000
> pumap 0x8000000
unmapped, gave back 0x00400000  (page returned to the pool; empty page table recycled)
```

键盘直接给字节、**没有输入法**,所以命令行本身只能打 ASCII;
想看中文就用 `cat`(文件里是 UTF-8),或者让程序自己打。

## 8. 怎么改

改完 `make` 一下,`./tools/run.sh --hd` 就能看到效果。

### 8.1 加一个自己的程序(最推荐)

```bash
cp progs/HELLO.asm progs/MYPROG.asm     # 改吧
make                                    # Makefile 会自动编 progs/*.asm
python3 tools/mkfat.py build/joyos-hd.img 6144 8 MYPROG.BIN=build/MYPROG.BIN
make hd                                 # 或者在 Makefile 的 PROGS 里加一行,让 make hd 自动带上
> run MYPROG
```

接口、约定、例子都在 **[docs/programs.md](docs/programs.md)**。

### 8.2 写个全屏程序(计算器/编辑器就是这么来的)

想要"自己清屏、自己排版"的程序,用第 6/9/10/11/12/13 号功能:
清屏、定位、读键事件(方向键)、问屏幕尺寸、取参数、在指定位置画字。
`progs/CALC.asm`(300 行)和 `progs/EDIT.asm`(400 行)就是照这个套路写的,
三条踩过的经验写在 [docs/programs.md 第 6 节](docs/programs.md)。

### 8.3 改开机那句话

`kernel/kmain.asm` 最下面的数据区,`msg_title` 就是第一行:

```asm
msg_title   db 'JoyOS - stage 5', 10, 0     ; 10 = 换行,0 = 字符串结束
```

中文也直接写(字符串是 UTF-8,图形模式下能显示;文本模式会成乱码,见 6.8)。

### 8.4 加一条 shell 命令

三处,都在 `kernel/shell.asm`:

```asm
; 1) 写处理函数(想打印就用 term_print,想读参数用 [cmd_arg])
cmd_hi:
    mov esi, msg_hi
    call term_print
    ret

msg_hi db 'hi there', 10, 0                 ; 2) 加字符串

; 3) 在命令表里登记(名字 + 处理函数)
n_hi db 'hi', 0
cmd_table:
    dd n_hi, cmd_hi
    ...
```

命令名匹配是**整词**比较(`str_eq`),所以 `page` 不会被 `pa` 之类误命中。

### 8.5 往镜像里放个文件

```bash
python3 tools/mkfat.py build/joyos-hd.img 6144 8 \
    NOTES.TXT=my-notes.txt HELLO.BIN=build/HELLO.BIN
make hd
> cat NOTES.TXT
```

参数含义、为什么是 6144、每簇几个扇区怎么选的,见
[docs/filesystem.md 第 6 节](docs/filesystem.md)。

### 8.6 改分页怎么映射

`kernel/paging.asm` 顶部那几张页表是**开机用**的,恒等映射 0~16 MiB:

```asm
PD_ADDR     equ 0x1000     ; 页目录
PT_LOW      equ 0x2000     ; 恒等 0-4 MiB
PT_ID1      equ 0x3000     ; 恒等 4-8 MiB   (往上:PT_ID2 = 0x5000,PT_ID3 = 0x7000)
PT_LFB      equ 0x4000     ; VBE 帧缓冲窗口
```

想玩"虚拟地址 ≠ 物理地址"不用改代码,shell 里现成有:

```
> pmap 0x8000000     ← 从页池拿一页(4 MiB 以上),现建页表映到 128 MiB 那个虚拟地址
> page 0x8000000     ← 看 PDE/PTE:虚拟 0x08000000、物理 0x00400000
> pumap 0x8000000    ← 解映射并把页还回去
> ptest              ← 一个命令跑完整个流程(分配→建表→读写→归还),还会检查页池有没有泄漏
```

要加一个"固定的自定义映射",在 `paging_init` 末尾照 LFB 那段写就行;
`paging_map(va, pa, flags)` 和 `paging_unmap(va)` 是内核里的动态接口
(`kernel/paging.asm`,页表不够会自己找 `pmem_alloc` 要页)。想让它"映了但不许写",
把 flags 里的 `PAGE_RW` 去掉,写它就会吃 13 号通用保护异常。

想改"程序能用多大内存"看 `paging.asm` 顶部的 `SPACE_IMG_PAGES` / `SPACE_HEAP_PAGES`
—— 现在这两个数字**只表示窗口大小**(镜像 512 KiB + 堆 320 KiB),建空间时一页都不给,
是程序碰到才补。想知道它是怎么补的,从 `page_fault_try_handle` 看起;
想关掉按需分页回到"一次给满",在 `space_create` 里把清页表那几行换成
`paging_map` 逐页映上去就行(老版本就是这么写的,git 历史里能翻到)。
`cmd_run` 里那几步一眼能认出来:建空间 → 写镜像大小 → 切 CR3 跑 → `space_destroy` 归还。

### 8.7 让 panic 屏显示更多

`kernel/idt.asm` 里 `isr_common` 就是那个"红屏 + 停机"。异常帧里的东西都在栈上:

```
[ebp+32]=向量号  [ebp+36]=错误码  [ebp+40]=EIP  [ebp+44]=CS  [ebp+48]=EFLAGS
```

想再打 `CR3`、`DS`、或者页表项,照着 `mov eax, cr2 / call term_print_hex` 那样加一行就行。

### 8.8 用 C 写程序

`make cc-check` 看看工具链在不在,然后往 `progs/` 里丢一个 `.c`,把名字加进
`Makefile` 的 `C_PROGS`,再 `make hd`。接口、内存布局、迷你 libc 有什么没有什么,
都在 [docs/c-programs.md](docs/c-programs.md);`progs/CHELLO.c` 是现成例子。

### 8.9 想看汇编到底编成了什么

```bash
make lst        # 生成 build/boot.lst 和 build/kernel.lst(带机器码的反汇编)
qemu ... -s -S  # 配合 gdb:target remote :1234(或 ./tools/run.sh --gdb)
```

## 9. 中文与字库(详见 font/README.md)

中文**能正常显示**:图形模式下把 16×16 点阵直接 blit 到帧缓冲,shell 里敲 `zh` 就能看到。

数据来源与生成方式见 [font/README.md](font/README.md):`font/` 目录里是 GNU Unifont 抽出的字形
(入库的是 416 字形的 23 KB `.hex` 子集 + 二进制;完整 40 208 字形的 1.7 MB 字库**放在磁盘镜像里**,
由 `tools/mkfontsubset.py` 生成)。**授权按 GPL-2+ 单独标注**(不并入仓库的 MIT)。

**编码现状**:字符编号是标准 Unicode 码位,**内核文本也已经是标准 UTF-8** ——
`term_print` 会先把 UTF-8 解成码位再画(见 `kernel/utf8.asm`),所以中文文案可以像普通字符串一样
`db '你好,世界!', 0` 写进内核,程序里也一样;坏字节会画成替换字符 `�` 而不是卡死。
细节(包括之前那套"码位数组"的历史)见 [docs/encoding.md](docs/encoding.md)。

## 10. 正在做:子目录 + FAT32

用户点名的接下来两件事(计划写在 [docs/fat-plan.md](docs/fat-plan.md)):

1. **子目录**:把"根目录 = 固定区域"这个写死的地方抽成"目录游标"(根区和簇链都当目录),
   再加路径解析(`a/b/c.txt`)、`cd` / `mkdir` / `rmdir`、在子目录里读写文件;
   vi 和编辑器跟着就能编辑任意路径的文件。
2. **FAT32**:按 BPB 自动识别(FAT 表 32 位项、根目录变成簇链、FSInfo/EBPB),
   `tools/mkfat.py --fat32` 能造 FAT32 分区,并用 `fsck.fat`/`mcopy` 交叉验证
   —— 拿别的系统认得的结果来证明我们写对了。

## 11. 还没做的(想练手就从这里挑)

- **删文件 / 建子目录 / 长文件名**:现在只有根目录 + 8.3 短名(`rm` 会是最短的一步:
  目录项首字节写 `0xE5` + 把簇链标回空闲)
- **程序带参数**:`run PROG arg` 需要定义一个"启动信息块"(参数放哪、栈怎么给)
- **保护程序搞坏内核**:现在程序和内核平起平坐,能直接改内核内存 ——
  真正的下一步是 ring 3 + TSS + 系统调用门,把"内核窗口"从程序地址空间里挪走
- **虚拟内存的下一层**:按需分页已经有了(碰到哪页才给哪页),但还没有
  **页置换 / swap / 写时复制**,也**不给程序自己长栈**(栈还是内核那套);
  窗口里的空洞也会给页(按访问给,不是按"真的要用"给)
- **PIT 定时器(IRQ0)**:有了它才能做 `uptime`、闪烁光标、`sleep`
- **光标键 / Home / End**:要处理扫描码的 `0xE0` 前缀
- **ELF 加载 / 内存分配**:现在程序是平铺二进制读到固定地址,`malloc` 也没有
- **鼠标(IRQ12)**:PS/2 鼠标比键盘多几个坑(要发命令、读 3 字节包)
- **从磁盘读内核**:现在内核还是引导扇区按固定 LBA 读的,没有"从文件系统加载内核"

## 12. 许可

MIT —— 随便用、随便改、随便抄(见 [LICENSE](LICENSE))。
`font/` 目录里的字形数据来自 GNU Unifont,按 **GPL-2+** 单独授权(见 [font/LICENSE](font/LICENSE))。

要是这个仓库帮你搞懂了保护模式、分页或者文件系统,那就够了。
