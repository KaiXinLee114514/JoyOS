# font/ — 点阵字库(中文显示的实验)

这个目录里的东西**不是 JoyOS 自己的代码**,是 GNU Unifont 的字形数据 + 用它生成的
VGA 文本模式字模表。授权见下面的"授权"一节(和仓库根目录的 MIT 是两回事)。

## 文件

| 文件 | 说明 |
|---|---|
| `unifont-subset.hex` | **源数据**:从 Unifont 里抽出的 134 个字形(ASCII 0x20-0x7E + 本项目用到的汉字),6.3 KB |
| `charset.txt` | 要放进字模表的汉字(每个汉字占两个字模号,上限 63 个) |
| `strings.txt` | 要在屏幕上打的中文文案(一行一条) |
| `vga-font.bin` | **生成物**:8192 字节的 VGA 文本模式字模表(256 字符 × 32 字节) |
| `vga-zh-map.asm` | **生成物**:汉字 → 字模号 映射表(给汇编用) |
| `vga-zh-strings.asm` | **生成物**:中文文案的码位数组(给汇编用) |

重新生成(不需要联网,源就在本目录):

```bash
python3 tools/unifont2bin.py --hex font/unifont-subset.hex \
    --vga-font font/vga-font.bin --vga-map font/vga-zh-map.asm --vga-chars-file font/charset.txt \
    --zh-strings-in font/strings.txt --zh-strings-out font/vga-zh-strings.asm
# 或者: make font
```

想用完整的 Unifont(不是子集),去 USTC 镜像下(见下),然后
`make font UNIFONT_HEX=/path/to/unifont_all-18.0.01.hex`。

## 源数据从哪来

* 版本:GNU Unifont **18.0.01**
* 下载:`https://mirrors.ustc.edu.cn/gnu/unifont/unifont-18.0.01/unifont_all-18.0.01.hex.gz`(1.7 MB)
  * 这台机器上 `unifoundry.com`、`ftp.gnu.org` 都不通,USTC 镜像通;Debian 源里也有
    (`apt-get download unifont`,版本旧一些)
* `.hex` 格式(实测确认):`码位:点阵数据`;数据 32 个十六进制字符 = 8×16 半宽(每行 1 字节),
  64 个 = 16×16 全宽(每行 2 字节);从上到下逐行,每 2 个字符 = 8 像素,最高位在最左。

## 授权

**GPL-2+**(完整文本见本目录 `LICENSE`)。依据:Debian 的 `unifont` 包 copyright 里
`Files: *`(即那些 .hex 字库文件)写的是 `GPL-2+`,版权人包括 Roman Czyborra、Paul Hardy 等。

注意两点:
* 上游新版通常还提供"GPL+字体嵌入例外"或 OFL 双授权,但**这台机器下不到上游的包**
  (下载到的是个反爬 HTML 页面),所以我只按读到的 Debian copyright 来标注。
* 这里的 `vga-font.bin` 等文件是**该数据的派生作品**,同样受 GPL-2+ 约束;
  仓库根目录的 MIT **不覆盖**这个目录。要发布的话把本目录单独标注即可。

## VGA 文本模式字模:实测出来的寄存器公式

下面这些**不是抄来的**,一半是从 QEMU 的 `hw/display/vga.c` 读出来的,一半是在 QEMU 里
一格一格量出来的。踩这些坑花了不少时间,记下来免得重修:

```c
/* QEMU hw/display/vga.c, vga_draw_text() */
v = sr(s, VGA_SEQ_CHARACTER_MAP);                       /* Sequencer 0x03 */
offset    = (((v >> 4) & 1) | ((v << 1) & 6)) * 8192 * 4 + 2;   /* 表 A 基址 */
font_base[1] = (((v >> 5) & 1) | ((v >> 1) & 6)) * 8192 * 4 + 2; /* 表 B 基址 */
font_ptr = font_base[(cattr >> 3) & 1];                 /* 用哪张表 = 属性字节 bit3 */
font_ptr += 32 * 4 * ch;                                /* 每字符 32 字节! */
/* 每行的取址在 vga_draw_glyph8 里:font_ptr += 4 → 平面 2 里就是 +1 字节/行 */
```

结论:

1. **每字符 32 字节步长**(不是 16)。按 16 字节排表,每个字都会被读成"上一个字的后半 +
   下一个字的前半",整屏错位。
2. **表 A / 表 B 由属性字节的 bit3 决定,和字符码无关**。BIOS 默认 `Sequencer 0x03 = 0x03`
   时算出:表 A 基址 = 0xC000,表 B 基址 = 0x0000。终端里普通文本用颜色 0x07(bit3=0 → 表 A),
   亮色 0x0B/0x0A/0x0C(bit3=1 → 表 B)→ 于是"有的行是新字模、有的行还是 BIOS 字模"。
   把 `Sequencer 0x03` 设成 0,两张表都指向偏移 0 就统一了。
3. **文本模式下 GC 0x06 的内存映射位默认是 3**(只映射 B8000-BFFFF 32 KB)。
   这时往 A0000 写字模**全写进空气**,屏幕上一点反应都没有。必须先清 bit3-2 → 0
   (A0000-BFFFF 128 KB)。这条是实测出来的:把整块 plane 2 全填 0xFF,清了这位之后
   屏幕立刻变成满屏方块,不清则纹丝不动。
4. **Sequencer 0x01 的 bit0 置 1 才是每字符 8 点**(`vga.c`:`if (!(sr & CHAR_CLK_8DOTS)) cwidth = 9;`)。
   不改的话汉字左右两半中间会多一道竖缝。

## 还没解决的(下一步的入口)

按上面的公式做了 8192 字节的表(32 字节/字符)、把 `Sequencer 0x03` 清零、打开了显存窗口:

* ✅ **上传确实生效**:把"空格"字模改成实心方块后,整屏墨迹从 ~3% 涨到 44%(空格全变方块)
* ❌ 但把某个具体字符(试过 `'J'` = 0x4A、以及槽 0x80)改成方块时,**屏幕上并没有出现对应方块**;
  正常字形看起来像是**横向被压扁/错位一列**。

也就是说:字模数据进去了、字符码映射也对(空格那一条证明了),但**渲染出来的像素和表里的字节
不是 1:1**。怀疑和"9 点时钟 → 8 点时钟"切换后 QEMU 的文本表面尺寸/取址有关,还没定论。

另外提醒:**文本模式这条路的上限就是 63 个汉字**(一个汉字要占两个 8 像素宽的字符格)。
想要正经中文,下一步应该直接上**图形模式**(VBE + 线性帧缓冲),自己往显存里 blit 16×16
点阵 —— 那样就没有字符发生器、字体表、map A/B 这一堆寄存器了。
