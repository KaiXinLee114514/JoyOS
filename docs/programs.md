# 给 JoyOS 写程序(`int 0x30` 接口)

想改这个系统?**最快见效的办法是别碰内核,写个程序丢到磁盘上跑。**
程序是平铺二进制,用 `nasm -f bin` 编出来,放进 FAT16 分区,shell 里 `run` 一下就起来了。

现成的例子在 `progs/`:`HELLO.asm`(最简)、`COUNT.asm`(循环 + 各种打印)。

---

## 1. 三行 hello

```asm
[BITS 32]
[ORG 0x120000]          ; ← 必须写,和内核的加载地址一致

start:
    mov eax, 0          ; 功能 0:打印字符串
    mov esi, msg
    int 0x30
    ret                 ; 返回 shell

msg db 'hello from a program', 10, 0
```

编译、放进镜像、运行:

```bash
nasm -f bin progs/HELLO.asm -o build/HELLO.BIN        # 1. 汇编(平铺二进制)
python3 tools/mkfat.py build/joyos-hd.img 6144 8 \    # 2. 塞进 FAT16 分区
    HELLO.BIN=build/HELLO.BIN
make hd                                               # 3. 启动(或 ./tools/run.sh --hd)

> run HELLO                                           # 4. 在 shell 里跑(名字大小写都行)
running HELLO.BIN
hello from a program
program returned to the shell
```

`make` 已经认识 `progs/*.asm`(`$(BUILD)/%.BIN` 规则),所以自己加一个程序只要
把 `MYPROG.asm` 放进 `progs/`、把 `MYPROG.BIN` 加进 `Makefile` 的 `PROGS` 变量、
再在 `$(HDIMG)` 规则的 `mkfat.py` 那行补一个 `MYPROG.BIN=build/MYPROG.BIN` 就行。

> 文件名用**大写**:ISO/FAT 的 8.3 名字惯例是大写,`nasm` 出来的文件名也得对上。
> 顺带一提,`Makefile` 的规则 `$(BUILD)/%.BIN: progs/%.asm` 是大小写敏感的 ——
> 源文件必须叫 `progs/MYPROG.asm`。

## 2. 接口只有六件事

| eax | 干什么 | 参数 | 返回 |
|---|---|---|---|
| 0 | 打印 UTF-8 字符串(0 结尾) | esi = 地址 | — |
| 1 | 打印十进制 | ebx = 数值 | — |
| 2 | 打印十六进制(自动补 `0x`) | ebx = 数值 | — |
| 3 | 打印一个 Unicode 码位(汉字也行) | ebx = 码位 | — |
| 4 | 设颜色 | bl = 属性字节 | — |
| 5 | 等一个按键 | — | al = ASCII |

别的功能号会被忽略(分发器最后直接 `ret`)。

颜色字节和老的 VGA 文本模式一个规矩:`0x0A` 亮绿、`0x0B` 亮青、`0x0E` 亮黄、
`0x07` 浅灰、`0x0C` 亮红。图形模式下内核会把它换算成 RGB。

其它寄存器(eax / ebx / esi 之外)不保证被保留,想留就自己 `push`。

## 3. 为什么用中断而不是 `call` 内核函数

内核里的函数是**绝对地址**(整个内核是一个平铺二进制,加载到 0x10000)。
如果程序里写死 `call 0x012345`,那么内核一改代码、函数挪了位置,程序就当场炸。

所以中间隔了一层中断门:`int 0x30` 走 IDT(向量号 0x30 是内核启动时用
`idt_install` 装上的,见 `kernel/api.asm`)。程序只认功能号,内核想怎么改都行 ——
这就是最小的"系统调用"概念。

顺便说清楚几个约定:

* 程序被**读进 0x120000**(`PROG_ADDR`),所以 `[ORG 0x120000]`;
* 栈还是**内核栈**(`0x90000` 往下长),程序不用自己建栈;
* shell 用 `call 0x120000` 进去,所以程序用 `ret` 就回到 shell —— 这是最简单的返回方式;
* 加载地址往上到**磁盘字库(0x200000)之前**是空的,所以程序最大 896 KB
  (`PROG_MAX_SIZE`),超了会被 `run` 直接拒绝 —— 别小看这一步,见下面的坑;
* 现在**没有**参数传递(还不能 `run PROG arg1`),也**没有**隔离 ——
  程序能改内核的内存,写崩了整个系统就跟着崩(这是下一步想做的事)。

## 4. 一个稍复杂点的例子:`COUNT.asm`

```asm
start:
    mov eax, 4
    mov ebx, 0x0E           ; 亮黄
    int 0x30

    mov ebx, 1
.loop:
    push ebx                ; ★ 每次调用前把 ebx 存起来
    mov eax, 1              ; 打印十进制
    int 0x30
    mov eax, 0
    mov esi, msg_space
    int 0x30
    pop ebx
    inc ebx
    cmp ebx, 10
    jbe .loop
```

`push ebx` / `pop ebx` 是必须的:接口只承诺自己那点事,不承诺"调用前后 ebx 不变"。

`COUNT.asm` 里还有按码位打印汉字的玩法:

```asm
    mov ebx, 0x4F60         ; U+4F60 就是"你"
    mov eax, 3
    int 0x30
```

只要字库里有这个码位就能画出来。内建字库只有 416 个字形(大约够 ASCII + 常用字),
**硬盘镜像里的完整字库有 40 208 个**(CJK 基本区、扩展 A、假名、谚文、全角标点、部分 emoji)。
软盘启动就退回内建子集 —— 那时汉字会显示成 missing glyph 的方框。

## 5. 程序里怎么用中文

直接写 UTF-8 字节就行,内核的 `term_print` 会自己解码:

```asm
msg db '你好,世界!', 10, 0
```

不用管码位,也不用管编码表。唯一的坑是**编辑器和工具链**:文件本身要存成 UTF-8
(这个仓库里所有中文文件都是),`nasm` 只管把字节抄进去,不管它是什么编码。

## 6. 一个真实的坑:加载地址选在了字库中间

程序一开始是加载到 **0x300000** 的 —— 看着挺顺眼(3 MB,离内核很远),但**它是错的**:
完整字库在 0x200000,1.7 MB 一直铺到 0x3AF110,0x300000 正好落在**点阵数据中间**。

后果:程序一载入就把几个字的点阵改掉了。实测 249 字节的 `HELLO.BIN` 踩掉的是
**U+782A~U+7832 九个汉字**(砪砫砬砭砮砯砰砱砲),屏幕上那几个字会画成花屏 ——
而错误只在显示**那几个字**时出现,很容易被当成"字库本身有问题"去查半天。

顺便记一下算法(踩坑时算清楚过):字库里每个字形记录的是**相对数据区**的偏移
(`data_off` 之后),所以一个字形在内存里的地址是

```
字库基址(0x200000) + data_off(full-joyf.bin 里是 0x75CD0) + 该字形的 off
```

而不是"基址 + off"。第一次算的时候漏了 `data_off`,算出来差 0x75CD0 ≈ 482 KB,
结论全错 —— 这一点值得记下来:**偏移量属于哪个基准,比偏移量本身重要。**

这类"两个东西各占一块内存,谁也没告诉谁"的 bug 特别阴:两个功能单独测都是对的。
现在的做法:

* 加载地址挪到 **0x120000**(上面是 `FILE_BUF`,下面是字库,中间 896 KB 都是空的);
* `run` 先用 `fat_stat` 看目录项里的大小,**超过 `PROG_MAX_SIZE`(896 KB)就直接拒绝**,
  不让它读进来把字库盖掉;
* 测试里有一项哨兵:`run HELLO` 之后屏幕必须能正确画出 **U+7830 砰**
  (`font still intact: 砰`)—— 这个字就在"以前会被踩掉"的那段区域里;
* 测试里还有一项**静态检查**:从源码里读出 `PROG_ADDR` / `FONT_LOAD_ADDR`,
  算出程序区 `[PROG_ADDR, PROG_ADDR+PROG_MAX_SIZE)` 和字库区
  `[FONT_LOAD_ADDR, FONT_LOAD_ADDR+字库字节数)` 有没有重叠 —— 只要有人把加载地址
  改回字库中间,这条立刻红。

想在屏幕上验证自己没踩到别的东西?用 `find_text` 那种"把期望的字渲染成图案再去截图里找"
的办法(见 `tests/qemu_test.py`),比肉眼看可靠。

## 7. 调试建议

* 程序里乱来(比如访问没映射的地址)会触发内核的 panic 屏,上面有 EIP ——
  不过 EIP 是内核的地址空间视角,得自己对着 `build/kernel.lst` 或
  `nasm -l build/HELLO.lst` 反查;
* 想单步/打断点就 `./tools/run.sh --gdb`(`-s -S`,然后 gdb `target remote :1234`);
* 程序返回后 shell 会打 `program returned to the shell` ——
  看不见这行就说明它没返回(死循环或者炸了)。

## 8. 想扩展接口?

加一个功能只要三处,都在 `kernel/api.asm`:

```asm
api_dispatch:
    cmp eax, 6
    je .new_thing           ; 1) 加一个分支
    ...
.new_thing:
    ...
    ret

api_usage:                  ; 2) 补一句说明(裸敲 run 就能看到)
    db '  eax=6  ...', 10
```

3) 记得把 `api_usage` 里的话和 `progs/README.TXT`、这一页同步 ——
三处说法不一致的话,下一个改的人(可能是三个月后的你自己)会骂人。

还有一个上面提过的注意点,写在这里当警告:**`api_stub` 里改段寄存器会顺手改掉 `eax`**
(`mov ax, 0x10` 会把功能号冲掉)。所以功能号是先存到 `ebp` 再恢复的。
你自己往里加代码时,别在恢复之前碰 `eax`。
