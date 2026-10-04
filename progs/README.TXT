JoyOS 磁盘说明(UTF-8 文本,用 cat README.TXT 看)
================================================

这个文件放在 FAT16 分区里,是给你改着玩的地方。

怎么加自己的程序:
  1. 写一个 asm,开头写上   [BITS 32]  [ORG 0x120000]
  2. 用 nasm 编成平铺二进制: nasm -f bin myprog.asm -o MYPROG.BIN
  3. 放进镜像: python3 tools/mkfat.py build/joyos-hd.img 6144 8 MYPROG.BIN=MYPROG.BIN
  4. 启动后在 shell 里:      run MYPROG
     (源码放 progs/ 里、加进 Makefile 的 PROGS 也行,那样 make hd 会自动带上)

程序里怎么跟内核说话:用 int 0x30
  eax=0  打印字符串(UTF-8)     esi = 地址
  eax=1  打印十进制             ebx = 数值
  eax=2  打印十六进制           ebx = 数值
  eax=3  打印一个码位           ebx = Unicode(中文也行)
  eax=4  设颜色                 bl  = 属性字节(0x0A 亮绿 / 0x0B 亮青 / 0x07 浅灰)
  eax=5  等一个按键             → al = ASCII
程序用 ret 返回 shell。

已有的例子:HELLO.BIN(最简)、COUNT.BIN(循环 + 各种打印)。

更详细的一页(中文):docs/programs.md —— 接口约定、内存布局、
以及『加载地址选在字库中间』那个坑。
磁盘和 FAT16 的事:docs/filesystem.md。
