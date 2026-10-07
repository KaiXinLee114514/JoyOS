# 用 C 写 JoyOS 程序

**不用交叉编译器,普通 `gcc` 就行。** 程序编成平铺二进制,放进 FAT16 分区,
shell 里 `run XXX` 跑起来 —— 和 `progs/*.asm` 那套完全一样,只是语言换了。

```c
#include <stdio.h>
#include <joyos.h>

int main(void)
{
    j_color(JOY_LCYAN);
    printf("hello from C, screen is %d cols\n", j_screensize(NULL));
    return 0;
}
```

```bash
make                 # 自动编译 progs/*.c(需要 gcc 的 32 位支持)
make cc-check        # 看一眼 C 工具链在不在
make hd              # 起来之后: run CHELLO
```

`make` 在**没有 32 位支持**的机器上会**跳过** C 程序并提示 `sudo apt install gcc-multilib`,
汇编那部分照常构建 —— clone 下来的人不会被卡住。

---

## 1. 这一套是怎么拼起来的

| 文件 | 干什么 |
|---|---|
| `include/joyos.h` | 14 个 `int 0x30` 功能的 C 包装(static inline 内联汇编)+ 颜色/键值常量 |
| `lib/crt0.asm` | 入口:`_start` → 清 BSS → `main()` → `ret` 回 shell;还有 `exit()` 用的跳板 |
| `lib/minic.c` | 迷你 libc:string / ctype / malloc / printf / 一点点 stdio(约 600 行) |
| `lib/minic.h` | 上面那些的声明(也是我们自己的 `<stdio.h>` 等的真正内容) |
| `include/*.h` | 薄壳:让 `#include <stdio.h>` 这种老写法命中我们的实现 |
| `lib/joyos.ld` | 链接脚本:摆到 0x120000,输出平铺二进制,顺手给出 BSS 边界符号 |
| `progs/*.c` | 你的 C 程序 |

编译命令(Makefile 里已经写好了,这里只是让人看懂):

```bash
gcc -m32 -std=gnu89 -ffreestanding -fno-pic -fno-stack-protector \
    -fno-asynchronous-unwind-tables -fno-builtin -nostdlib -O2 \
    -Iinclude -Ilib -c progs/Foo.c -o build/Foo.o
ld -m elf_i386 -T lib/joyos.ld build/crt0.o build/Foo.o build/minic.o -o build/Foo.BIN
```

每个参数都有理由:

* `-m32`:JoyOS 是 32 位 x86,程序必须是 32 位代码;
* `-ffreestanding -nostdlib`:裸机上没有 libc,别去链接 glibc(链了也起不来);
* `-fno-pic`:`int 0x30` 要用 `ebx` 传参数,而位置无关代码拿 `ebx` 当 GOT 指针;
* `-fno-stack-protector -fno-asynchronous-unwind-tables`:`__stack_chk_*` 和 `.eh_frame`
  都是 libc/运行时才有的东西,带上就链接不过;
* `-fno-builtin`:别把 `memcpy` 之类换成编译器内联版本(我们自己实现的更简单);
* `-std=gnu89`:老 C 代码(STEVIE 那种)默认 gcc 14 编不过,gnu89 最省事。

## 2. 程序的约定

```
0x120000            程序被 shell 读到这里(链接地址就是它)   ← 虚拟地址
0x120000..0x19FFFF  程序镜像(代码 + 只读数据 + 已初始化数据)
0x1A0000..0x1EFFFF  堆(malloc 从这儿切,320 KB)
0x1F0000            内核临时用(读字库描述块)
0x200000 起         完整字库 —— 谁都不许碰
```

* **这两块现在是"每程序私有页",而且按需才给**:内核建好页表,但这 208 页
  (镜像 512 KiB + 堆 320 KiB)一页都不预先映射 —— 你的代码/数据第一次碰到哪一页,
  缺页处理才从物理页池现拿一页、清零、填表(然后把那条指令重执行一遍,你感觉不到)。
  程序退出后把这些页连页表一起还给页池。所以虚拟地址和你写代码时一样,
  物理落在哪儿每次都不一样(想知道自己碰了多少页,跑一次 `run TOUCH`,或看 `run FOO`
  最后那行 `demand paging: N page(s) faulted in (image x + heap y)`);
* 超过 512 KiB 的镜像会被 `run` 拒绝(私有镜像窗口就这么大)。

* **入口**:`lib/crt0.asm` 里的 `_start`(由链接脚本 `ENTRY(_start)` 指定)。
  它清完 BSS 就调 `main()`,所以程序里写 `int main(void)` 就行,**不要**自己写 `_start`;
* **返回**:`main` 返回(或 `exit()`)就回到 shell。没有进程、没有返回值语义,
  退出码只有调试意义;
* **参数**:`int main(int argc, char **argv)` **不行** —— 没有 argv。
  用 `const char *arg = j_arg();` 取(`run FOO 参数` 里那串);
* **BSS**:平铺二进制不存"全是 0 的段",所以 crt0 会清一遍;而现在按需补进来的页
  本身就是干净的零页(镜像文件之外的部分连拷都不拷) —— 双保险,
  "全局数组默认是 0"稳了。

## 3. 迷你 libc 有什么、没有什么

**有**:`strlen/strcpy/strncpy/strcat/strcmp/strncmp/strchr/strrchr/strcspn/memcpy/memmove/memset`、
`is*/to*`、`malloc/calloc/realloc/free`(首次适配 + 相邻合并)、
`printf/fprintf/sprintf/snprintf`(`%d %i %u %x %X %o %c %s %p %%`,带宽度/精度/`-`/`0`/`+`/`#`)、
`fopen/fclose/fgets/fgetc/fputc/fputs/puts/fflush`、`remove/rename/access`、`atoi/abs/exit/system/getenv`。

**没有**:浮点格式化(`%f`)、`scanf`、目录遍历、`time`、信号、线程、
`qsort`、locale/宽字符。

**和 POSIX 不一样的地方**(重要):

* 文件的模型是"**整读整写**":`fopen("r")` 会把整个文件读进内存(最多 64 KB),
  `fopen("w")` 先在内存里攒着,`fclose` 时才一次写盘。没有 seek 回写、没有追加;
* `remove()` 永远返回 -1:内核的接口里**没有删除文件**(见 [known-issues.md](known-issues.md));
* `rename()` 是"读出来 + 写到新名字",旧文件还在;
* `system()` 只打印一句"没有 shell escape" —— 这个系统里没有进程;
* `getenv()` 永远返回 NULL(老代码得自己有默认值)。

## 4. 例子:`progs/CHELLO.c`

它把能用的都试了一遍:printf 各种格式、malloc/free 看堆还剩多少、16 种颜色、
取参数、用参数当文件名打开并统计行数/字节数。跑:

```
> run CHELLO
> run CHELLO README.TXT
```

`ls` 里能看到它:`CHELLO.BIN` 8888 字节 —— 其中大约 6 KB 是迷你 libc 和 crt0,
所以"每个 C 程序自己带一份 libc"也不算浪费(反正是从磁盘读的)。

## 5. 现成的例子:`progs/` 里的 C 程序和 STEVIE

* `progs/CHELLO.c`:printf / malloc / 参数 / 读文件,把能用的都试一遍;
* `third_party/stevie/`:**STEVIE 3.68 —— 公有领域的 vi 克隆(vim 的前身)**,整个移植过来了:

```bash
make hd
> run vi NOTES.TXT      # 打开编辑器(:w 存盘、:q 退出、i 进插入模式、ESC 回普通模式)
```

它的"机器相关层"本来叫 `nt.c`(Windows NT 版),现在换成我们自己写的
`third_party/stevie/joyos.c`:屏幕走 `int 0x30` 的 9/13 号(定位 + 在指定位置画字),
键盘走 10 号(方向键直接映到 STEVIE 的 `K_UARROW` 那套键值),文件走 7/8 号。
编辑器核心(约 10 900 行)一行没改 —— 这正说明"平台层收得干净"的代码有多好移植。

平台层要提供的东西一共就这些:

```
windinit / windexit / windgoto(row,col) / wchangescreen   屏幕
outchar / outstr / flushbuf                                画字符
inchar                                                     收键
fopenb / fixname                                           文件和文件名
beep / delay / sleep / sig / dochdir / mysystem / doshell   杂项(多数是空实现)
```

**真人实测的坑**:`fixname` 在 NT 版里是 `fixname(char *s)` —— 一个参数、返回静态缓冲,
而我第一版按"三个参数、写到调用方缓冲"写了。`stevie.h` 里是老式声明 `char *fixname();`,
**参数个数不对编译器不吭声**,于是存盘时文件名变成空的:vi 报"存盘成功",磁盘上却多了
一个名字全是空格的目录项。教训:移植老代码里的平台函数,先看原实现,别按自己以为的签名单干。
