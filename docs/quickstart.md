# 5 分钟上手:用纯 C 给 JoyOS 写个程序

**你不会碰到一行汇编。** `main()` 里想写什么写什么,`printf`、`argv`、文件读写都有。

## 0. 先准备(一次性)

```bash
sudo apt install gcc-multilib nasm qemu-system-x86 python3   # Debian/Ubuntu
git clone https://github.com/KaiXinLee114514/JoyOS.git && cd JoyOS
make            # 编出内核和镜像(第一次要一会儿)
```

## 1. 写个 C 文件

`sdk/examples/hello.c` 就是现成模板,复制一份改:

```c
#include <stdio.h>
#include <joyos.h>

int main(void)
{
    j_color(JOY_LCYAN);
    printf("hello from C!\n");
    j_color(JOY_GREY);
    printf("你给我的参数是:%s\n", j_arg());
    return 0;
}
```

## 2. 编 + 跑(两条命令)

```bash
bin/joyos-cc myprog.c -o MYPROG.BIN     # 纯 C → JoyOS 的平铺二进制
bin/joyos-run MYPROG.BIN                # 造镜像 + 开 QEMU
```

窗口里敲 `run MYPROG` —— 你的程序就在自己写的系统里跑了。
`bin/joyos-run myprog.c` 一步到位(它自己会先调 `joyos-cc`)。

## 3. 能用的东西

| 头文件 | 里面有什么 |
|---|---|
| `<joyos.h>` | 屏幕/键盘/文件/参数的包装:`j_print` `j_color` `j_clear` `j_goto` `j_key` `j_event` `j_read_file` `j_write_file` `j_screensize` `j_arg` `j_puts_at`,调色板 `JOY_RED` 这类,方向键码 `JOY_KEY_UP` 这类 |
| `<stdio.h>` | `printf` `puts` `putchar` `getchar`(迷你实现,支持 `%d %x %s %c %u`,**没有** `%f`) |
| `<string.h>` `<stdlib.h>` `<ctype.h>` | `memcpy` `strlen` `strcmp` `malloc` `free` `atoi` … |
| `<malloc.h>` | `malloc/free`(堆在 0x1A0000–0x1EFFFF) |

文件接口**支持路径**,而且相对"当前目录":`j_read_file("DOCS/NOTE.TXT", buf, sizeof buf)`。

## 4. 几个必须知道的边界(没权限模型,内核信任你)

* 程序加载在 **0x120000**,入口就是第一个字节(链接脚本已经管好了);
* 你的代码/数据、参数块、堆区随便用;**别去写** 0x10000–0x30000(内核)、0x100000/0x110000(内核缓冲)、0x200000(字库);
* `ret` 回 shell = 程序结束;别关中断(`cli`),不然系统会失去时钟;
* 程序写坏了别人的内存没人拦得住 —— 这是"胡闹 OS",不是 Linux。

## 5. 常见问题

| 现象 | 原因 |
|---|---|
| `file not found` | 文件名在系统里是 8.3 大写形式(`MYPROG.BIN`),`run myprog` 也行(会自动补 `.BIN`) |
| 编译报 `-m32` 相关错 | 没装 `gcc-multilib` |
| 屏幕上中文是 `?` | 你按 Alt 看的是 ASCII 区;中文能显示(得字库在盘上,`make hd` 的镜像里有) |
| 想跑扩展(比如 vi) | `make ext-img && make run-ext`,那是可选玩具,不在默认镜像里 |

## 6. 别人怎么加"扩展"

源码丢进 `extensions/<名字>/`,Makefile 的 `EXT_BINS` 加一行,`make ext` 就编它。
规矩见 `extensions/README.md`:**扩展不许拖累主线**,挂了也不能影响 `make test`。

## 7. 用键盘打中文(Alt 码位输入)

键盘只认 ASCII?按住 **左 Alt**,在小键盘/主键盘上敲**十进制码位**,松开 Alt ——
那个字符就作为 UTF-8 打进当前程序(编辑器、`write`、shell 都吃):

| 想打 | 敲 |
|---|---|
| 中 | 按 Alt + `20013`,松开 |
| 好 | 按 Alt + `22909`,松开 |
| 😀 | 按 Alt + `128512`,松开(4 字节 UTF-8,能画出来就画) |

* 码位就是 Unicode 编号(十进制):`中` = U+4E2D = 20013;
* 松开 Alt 之前敲了别的键 = 取消那一次输入;
* Alt 期间的数字**不会**回显,松开就出字;
* 前提是字库在盘上(`make hd` 的镜像有,4 万个字形)—— 不然只能显示内置的 ASCII
  子集,中文会变成方块。
