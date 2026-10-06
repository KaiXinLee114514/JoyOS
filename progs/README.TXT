JoyOS 磁盘说明(UTF-8 文本,用 cat README.TXT 看)
================================================

这个文件放在 FAT16 分区里,是给你改着玩的地方。

怎么加自己的程序:
  1. 写一个 asm,开头写上   [BITS 32]  [ORG 0x120000]
  2. 用 nasm 编成平铺二进制: nasm -f bin myprog.asm -o MYPROG.BIN
  3. 放进镜像: python3 tools/mkfat.py build/joyos-hd.img 6144 8 MYPROG.BIN=MYPROG.BIN
  4. 启动后在 shell 里:      run MYPROG
     (源码放 progs/ 里、加进 Makefile 的 PROGS 也行,那样 make hd 会自动带上)

蜂鸣器(主板小喇叭)+ 文本谱:
  run PLAY MYSONG.TXT       让 JoyOS 按 FAT 上的文本谱唱歌(镜像里不带示例谱,自己写)
  run PLAY --list MYSONG.TXT  只解析、把谱子打到屏幕上(不出声,改谱时对答案用)
  谱子是纯文本:自己 run EDIT MYSONG.TXT 写几行,格式见 docs/quickstart.md(Ctrl-S 存盘/Ctrl-Q 退出)
  方波没有音量控制(全音量很吵):在宿主混音器/系统音量里把它调小;-audiodev 没有 out.volume 参数
  ★ QEMU 7 以后不给 PC 喇叭接音频后端就是静音,要听声音得这么起:
      qemu-system-i386 -machine pcspk-audiodev=snd0 -audiodev pa,id=snd0,out.stream-name=JoyOS \
          -drive file=build/joyos-hd.img,format=raw,if=ide,index=0 -boot c
  程序接口是 14 号 beep(ebx=频率 Hz,ecx=毫秒):音高准,时值是忙等估的

程序里怎么跟内核说话:用 int 0x30
  基本款:
    eax=0  打印字符串(UTF-8)   esi = 地址
    eax=1  打印十进制           ebx = 数值
    eax=2  打印十六进制         ebx = 数值
    eax=3  打印一个码位         ebx = Unicode(中文也行)
    eax=4  设颜色               bl  = 属性字节(0x0A 亮绿 / 0x0B 亮青 / 0x07 浅灰)
    eax=5  等一个按键           → al = ASCII(方向键会被跳过)
  写全屏程序要用的:
    eax=6  清屏
    eax=7  读文件   esi=名字 edi=缓冲 ecx=上限      → eax = 字节数 / -1
    eax=8  写文件   esi=名字 edi=数据 ecx=字节数    → eax = 0 / -1
    eax=9  定位光标 ebx=行 ecx=列
    eax=10 等键事件 → eax = ASCII,方向键是 0x100+编号(1上 2下 3左 4右 5Home 6End 7Del 8PgUp 9PgDn)
    eax=11 屏幕尺寸 → eax = 列数,ebx = 行数
    eax=12 取参数   → esi = `run 程序名 参数` 里的参数
    eax=13 定位画字 esi=串 ebx=行 ecx=列 edx=最多几格(不滚屏)
    eax=14 蜂鸣器   ebx=频率 Hz ecx=持续毫秒(频率<=0 = 静音等这么久,谱子的休止符用它)
  返回后:eax/ebx/esi 是返回值,ecx/edx/edi/ebp 保证不变。
程序用 ret 返回 shell。

已有的例子:
  HELLO.BIN  最简(英文 + 中文 + 一个汉字)
  COUNT.BIN  循环、十进制/十六进制、按码位连打汉字
  CALC.BIN   计算器:12.5*4= 的小数点、加减乘除、7s 平方、c 清零、q 退出
  EDIT.BIN   全屏文本编辑器:run EDIT [文件名],方向键移动,Ctrl-S 存盘,Ctrl-Q 退出

更详细的一页(中文):docs/programs.md —— 接口约定、内存布局、
以及『加载地址选在字库中间』那个坑。
磁盘和 FAT16 的事:docs/filesystem.md。
