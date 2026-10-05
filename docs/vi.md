# 把 vi 搬进 JoyOS:STEVIE 移植记

`run VI NOTES.TXT` —— 这个 JoyOS 里跑的 vi,不是我们从头写的,是把一份
**公有领域**的 vi 克隆搬过来的。这一页讲清楚:搬的是哪一份、为什么挑它、
我们改了什么(以及**没**改什么)、踩了哪些坑。

---

## 1. 搬的是哪一份:STEVIE 3.68

翻 Windows XP SP1 的源码时,`NT/sdktools/vi` 底下躺着一份编辑器源码。
有意思的是它**不是微软写的**,而是 **STEVIE(STEVIE 3.68)** ——
一份公有领域的 vi 克隆,而且正是 **vim 的前身**。

它自己的 readme 是这么说的:

```
STEVIE Source Release - 3.68
This is a source release of the STEVIE editor, a public domain clone of
the UNIX editor 'vi'. The program was originally developed for the Atari ST,
but has been ported to UNIX, OS/2, DOS, and Minix-ST as well.
...
The good news about stevie is that it is extremely portable.
```

**为什么挑它**:

| | STEVIE 3.68 | vim 9.x |
|---|---|---|
| 核心代码量 | ~10 900 行 C | 557 683 行 C(`src/*.c`) |
| 需要 libc 的什么 | 字符串/内存/`printf`/`fopen` 一点点 | 一整套 POSIX:pthread、locale、iconv、termcap、signal… |
| 需要操作系统给什么 | 一个很小的"机器相关层"(见下) | `fork`/`exec`/`waitpid`/`ioctl`/`termios`/信号/mmap/目录树/交换文件 |
| 授权 | public domain | GPL 兼容,但依赖太重 |

**为什么 vim 搬不动**:vim 站在"POSIX 用户态"那一层 —— 它要 libc、要进程、
要终端控制、要目录树。JoyOS 现在有 4 000 多行内核、没有 libc、没有进程,
差的是**整整一层**,不是几个函数。STEVIE 不一样:它是 1991 年的东西,
把"和机器打交道"的部分全塞在一个文件里,换掉那个文件就能跑。

## 2. 我们只搬了公有领域的部分

```
third_party/stevie/
    alloc.c ascii.h cmdline.c edit.c env.h fileio.c help.c hexchars.c
    keymap.h linefunc.c mark.c misccmds.c normal.c ops.c ops.h param.c
    param.h ptrfunc.c regexp.c regexp.h regmagic.h regsub.c screen.c
    search.c stevie.h undo.c version.c vi.c        ← 核心(公有领域)
    joyos.c                                        ← 我们自己写的后端
```

**没有**搬: `nt.c`(微软写的 Win32 平台层)、`sources`、`vi.rc`、`makefile`
(NT 构建文件)。也就是说仓库里进的是 STEVIE 本体 + 我们自己的后端。

## 3. 移植到底改了多少:平台层 + 三行补丁

STEVIE 把机器相关的代码集中在一个文件里(`nt.c` / `tos.c` / `unix.c`),
平台层要提供的东西一共这些:

```
屏幕   windinit()                问屏幕多大(我们:int 0x30 的 11 号)
       windexit()                退出前收拾
       windgoto(row, col)        定位                (9 号)
       wchangescreen()           刷新
       outchar / outstr          画字符/字符串        (13 号,攒一行一次画)
       flushbuf()                把攒的刷出去
键盘   inchar()                  收一个键             (10 号,方向键映射成 K_UARROW…)
文件   fopenb(name, mode)        打开文件             (7/8 号,见迷你 libc 的 stdio)
       fixname(name)             收拾成 FAT 8.3 的名字
杂项   beep / delay / sleep / sig / dochdir / mysystem / doshell
       setviconsoletitle / usecmdconsole / useviconsole / StrLength
```

核心那边只动了三处:

1. `env.h`:`#define NT` → `#define JOYOS`(它还顺手替我们关掉了 termcap:
   没有 termcap 就走硬编码序列,而那些序列也全在 `nt.c` 里,本来就要重写)
2. `stevie.h`:去掉 `<excpt.h>` / `<ntdef.h>`(MSVC 的东西)
3. `vi.c`:`main(argc, argv)` → `vimain(argc, argv)`,入口换成我们自己的 `main`
   —— 因为 JoyOS 的程序没有 argv,参数要用 `int 0x30` 的 12 号功能取

**编辑器的核心(编辑、命令、搜索、正则、撤销、屏幕差分)一行没改。**
这就是"平台层收得干净"的好处:换个文件,编辑器自己认不出它换了机器。

## 4. 踩的坑(都值得记)

### 4.1 `fixname()` 的签名:参数个数不对,编译器一声不吭

NT 版里是:

```c
char *fixname(s)          /* 一个参数,返回**静态缓冲** */
char *s;
```

我第一版按直觉写成了"三个参数、写到调用方给的 buf 里"。`stevie.h` 里是老式声明
`char *fixname();`,**参数个数不对编译期完全不报错**;运行时 `fopen(fixname(fname),"w")`
传进来的第二、三个参数是垃圾,于是文件名变成空的:

* vi 照样弹 `"vitest.txt" 1 line, 14 characters`(它自己以为存好了);
* 磁盘上却多出一个**名字全是空格**的目录项,第二次打开还认不出来。

教训:移植老代码里的平台函数,**先看原实现,别按自己以为的签名单干**。

### 4.2 `Scroll()` 里多写一个字节 → 变成页错误

STEVIE 用两块字符缓冲做"屏幕差分":`Realscreen`(现在屏幕上是啥)、
`Nextscreen`(应该是啥)。我们没有"读回屏幕"的接口,所以 `Scroll()`
(插入/删除整行时的滚动)用了个偷懒但正确的办法:**把 `Realscreen` 弄脏**,
让 STEVIE 下一次重画时自己整屏重画。

问题是缓冲区大小是 `alloc.c` 里的 `malloc(Rows*Columns)` —— **没有 +1**,
而我按 `Rows*(Columns+1)` 填的:多写的那一个字节正好砸在堆里下一块的头几个字节上。
后果不是立刻出错,而是过一会儿:

```
*** KERNEL PANIC ***
EXCEPTION 0E: page fault
EIP = 0x0012068E            ← 在 vi 里
CR2 = 0x01010109            ← 0x01 填充值 + 偏移 8,一眼能看出是被 0x01 覆盖过的"指针"
```

**越界一个字节也一样是越界**;而且这种 bug 的现场(CR2 的值)其实已经把线索
写在脸上了 —— 0x01010101 就是我 `memset` 的填充值。

顺便:STEVIE 的 `Rows` 是**整屏行数**(最后一行它自己拿来显示状态/`: ` 命令行),
我第一版"贴心地"替它减了一行,结果底部空一行、状态行上移一格。

### 4.3 中文能显示,但 vi 会把它当字节

STEVIE 是 1991 年的编辑器,只认字节:文件里的 UTF-8 汉字在它眼里是三个"怪字符",
屏幕上会画成 `?`(它的字符表里没有这些码位)。所以:

* 用 vi 看中文文件 → 汉字显示成 `?`(文件本身没坏,`cat` 出来是好的);
* 想好好看中文,用 `cat`(内核的 `term_print` 会解 UTF-8,直接把汉字画出来);
* 想编辑中文,可以用我们自己的那个汇编版编辑器 `run EDIT`(它按字节存、按 UTF-8 画)。

把 vi 改成 UTF-8 是**下一步可以做**的事(STEVIE 的 `outchar` 和缓冲区都是字节流,
得让"光标列"按显示宽度算、还要保证不把一个字符劈成两半)。

## 5. 怎么自己跑一遍

```bash
make hd
# shell 里:
run VI NOTES.TXT
    i            进插入模式
    打字…        打完按 ESC
    :w           存盘(真的写进 FAT16)
    :q           退出;改了没存会拒绝 → :wq 或 :q!
```

自动化测试(`make test-hd-font`)里那几条:

* vi 屏幕上出现 `~` 空行和 `"vitest.txt"` 状态行 → 起来了;
* 插入模式打字 → 屏幕上出现打进去的那行;
* `:w` → 状态行报文件名;`:q` → 回到 shell;
* 最后**离线解析镜像**,断言 `VITEST.TXT` 的内容就是我们敲进去的字节
  (不信内核自己的"存好了",直接看磁盘)。

## 6. 想接着改的话,几个方向

1. **UTF-8 支持**(上面 4.3):让 vi 能正常显示/编辑中文;
2. **块状光标**:现在是"光标在哪儿全靠猜"(图形模式没有硬件光标),
   可以画一个反显的方块;
3. **`:!cmd`**:现在只打印一句"没有 shell escape" —— 等有了进程再说;
4. **多窗口/多文件**:STEVIE 支持多文件,`Rows/Columns` 那套不拦着;
5. 把 `help.c` 的帮助屏接上中文:文档是我们自己的,随便改。
