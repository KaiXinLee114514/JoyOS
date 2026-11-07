# /DEV 设备抽象层

> 「一切皆文件」的最小学版:读时钟、写屏幕、丢垃圾,对程序来说都是
> **打开一个名字、读/写字节**。KKernel 的 FAT16 已经把「名字 → 字节」这条路铺好了,
> `/DEV` 只加一小段:文件名以 `DEV/` 开头时**不查磁盘,改查设备表**。

## 1. 有哪些设备

| 名字 | 读 | 写 | 说明 |
|---|---|---|---|
| `DEV/NULL` | 永远 0 字节 | 丢弃 | 经典 `/dev/null`:黑洞,写什么进去都没事 |
| `DEV/ZERO` | 要多少给多少 `0x00` | 丢弃 | 典型用途:把缓冲清零 |
| `DEV/RANDOM` | 伪随机字节 | 不支持 | xorshift32,种子偷 PIT 的 tick 数(每次开机不一样) |
| `DEV/RTC` | `YYYY-MM-DD HH:MM:SS`(19 字节) | 不支持 | 实时读 CMOS 时钟,不缓存 |
| `DEV/CON` | 不支持 | 当 UTF-8 文本打到屏幕上 | 不自动加换行,想换行自己写 `\n` 进去 |
| `DEV/DEVICES` | 列出所有设备名(空格分隔) | 不支持 | 设备表自己报名字,加新设备不用改这里 |

`/DEV` 目录里由 `tools/mkfat.py` 摆了**占位文件**(`ls DEV` 看得见),但它们的磁盘内容
永远不会被读到 —— 读写都走内核设备层。占位文件的内容只是一句说明
(`progs/DEV_NODE.txt`),方便别人直接看镜像时知道这些是什么。

## 2. 在 shell 里试用

```text
> ls DEV
README.TXT 673 bytes
NULL 86 bytes
ZERO 86 bytes
RANDOM 86 bytes
RTC 86 bytes
CON 86 bytes
DEVICES 86 bytes
> cat DEV/RTC
2026-11-07 03:18:41
> cat DEV/DEVICES
NULL ZERO RANDOM RTC CON DEVICES
> write DEV/CON hello, console!
hello, console!wrote DEV/CON
> write DEV/NULL 这不占地方
wrote DEV/NULL
> cat DEV/NULL
> cat DEV/CON
device is not readable
```

设备名大小写不敏感,前导 `/` 可有可无:`DEV/RTC`、`dev/rtc`、`/DEV/RTC` 都行。

## 3. 程序里怎么用

`int 0x30` 的 **7 号(读文件)** 和 **8 号(写文件)** 与 shell 共用同一套设备层,
所以程序**不用加任何新接口**就能读设备。C 程序里就是普通 `fopen/fread/fwrite`:

```c
#include <stdio.h>

int main(void)
{
    char t[32];
    FILE *f = fopen("DEV/RTC", "rb");
    if (!f) { printf("no dev\n"); return 1; }
    fread(t, 1, sizeof t - 1, f);      /* 19 字节时间串 */
    fclose(f);
    printf("现在是 %s\n", t);
    return 0;
}
```

`progs/IOTEST.c` 最后一段就是设备自检(读 `DEV/RTC`、写 `DEV/NULL`);
shell 里 `run iotest` 就能看到结果。

## 4. 实现(为什么这么写)

```
kernel/dev.asm
  dev_table      设备表:每项 12 字节(名字指针 / 读函数 / 写函数,0 = 该方向不支持)
  dev_lookup     esi = 名字 → eax = 设备表项(0 = 不是设备名)
  dev_xxx_read   读:edi = 缓冲,ecx = 上限 → eax = 字节数(-1 = 失败)
  dev_xxx_write  写:esi = 数据,ecx = 长度   → eax = 0 成功(-1 = 失败)
```

调用点只有两处:

- `kernel/api.asm` 的 7/8 号功能:进 `fat_path` **之前**先 `dev_lookup`,
  命中就直接调 handler,不碰当前目录(所以不会把 `fat_dir` 留在半路)。
- `kernel/shell.asm` 的 `cat` / `write`:同样先查设备。`cat DEV/XXX` 的结果
  打印前会补一个 `0` 结尾,防止把缓冲区里上一次的内容也打出来。

每个 handler 自己 `pushad` 保护寄存器、只把结果留在 `eax` —— 这样内核里的
两处调用点(cat/write 直接调、API 通过中断调)可以共用同一批函数。

## 5. 加一个新设备

1. 写 handler(读和/或写),遵守上面的寄存器约定;
2. 在 `kernel/dev.asm` 的 `dev_table` 里加一行,名字串放数据段;
3. 在 `Makefile` 的 `MKFAT_FILES` 里给 `DEV/` 加一个占位条目:
   `DEV/名字=progs/DEV_NODE.txt`;
4. 想让它出现在文档里,就在上表加一行。

不需要改 `ls` / `cat` / `write` / API 的任何代码 —— 名字解析和设备表会自动认。

## 6. 已知限制

- **只有 `/DEV` 一个命名空间**:`/dev` 是虚拟目录的"名字前缀",不是真的可 cd 的目录
  (`cd DEV` 还是可以进 FAT 里那个目录,只是里面的文件读出来是魔法)。
- **没有 open/close、没有 seek**:每次读都从头来;`DEV/RTC` 每次读都会重新读时钟。
- **没有权限位**:所有程序都能读所有设备(反正现在内核也没有权限模型)。
- **写方向没有返回写入字节数**:handler 只报成功/失败;`DEV/CON` 超过 255 字节会被截断。
- **`cat DEV/RANDOM` 会打出二进制乱码**:它是字节设备,不是文本;要看效果请用程序读。
- 设备占位文件在 `ls` 里会显示 86 字节(占位文本的长度),不代表设备本身的数据量。
