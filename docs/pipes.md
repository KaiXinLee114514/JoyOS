# 管道(pipe)

KKernel 的 shell 支持 `A | B` 形式的管道:**顺序执行**,不需要并发。
A 跑的时候屏幕输出被内核捕获进一块物理页池借来的缓冲,等 A 结束,再把缓冲里的字节
当作 B(以及后续段)的 stdin。所以它和 Linux 管道的"同一时刻两个进程在跑"不同,
是"跑完一个再跑下一个"——换来的是内核里几乎没有并发/阻塞逻辑。

```
> cat DOCS/README.TXT | run WC
54 lines 254 words 3241 bytes
> ls BIN | run GREP HELLO
HELLO.BIN 249 bytes
CHELLO.BIN 18536 bytes
> help | echo hi
hi
```

## 语法

- 命令之间用 `|` 分隔,最多 **4 段**;每段可以是 shell 内建命令(echo/cat/ls/help...)
  或者 `run 程序 参数`。
- 段首空格会跳过、段尾空格会修剪。空段(比如 `h1 | | h2`)报
  `pipe: empty command in the pipeline`;段数超过 4 报
  `pipe: too many stages (max 4)`。
- 最后一段的输出照常打到屏幕;中间段的输出被捕获、接给下一段。
- 管道里被捕获的输出超过缓冲容量时会被截断,整条管道结束打一行
  `pipe: output truncated (buffer full)`。

## 缓冲从哪来

执行管道时用 `pmem_alloc_pages` 从物理页池借缓冲:

- 2 段(1 个中间缓冲):先试 **16 页(64 KB)**,不够试 4 页(16 KB),再不够试 1 页(4 KB);
- 3 段以上需要两块缓冲轮流用(第 1 段输出给第 2 段、第 2 段输出给第 3 段),两块都按上面的
  顺序申请;
- 页池不够就报 `pipe: not enough pages for a pipe buffer`,整条管道不执行。

管道跑完立刻 `pmem_free_pages` 还回去,不会常驻占用。所以 `-m 16` 这类小内存也能用
(页池 8 MB,借 64 KB 问题不大),`-m 8` 没有页池,管道会直接报错。

## 程序怎么读 stdin

管道右边的程序用 **int 0x30 功能 17**:

```c
/* 从管道/stdin 读最多 max 字节;返回实际读到的字节数,0 = 读完了 */
static inline int j_pipe_read(void *buf, int max)
{
    int r;
    asm volatile("int $0x30" : "=a"(r)
                 : "a"(17), "D"(buf), "c"(max)
                 : "ebx", "edx", "esi", "memory");
    return r;
}
```

没有管道输入时(普通命令行直接 `run WC`)立刻返回 0,程序打印提示后正常退出。
`include/kkernel.h` 里有现成的 `j_pipe_read`。

## 自带的管道工具

四个 C 小程序,源码在 `progs/`,构建时自动打进 `/BIN`:

| 程序 | 用法 | 说明 |
|---|---|---|
| `WC` | `run WC` | 数 stdin 的行/词/字节:`54 lines 254 words 3241 bytes` |
| `UPPER` | `run UPPER` | 把 stdin 全部转成大写输出 |
| `GREP` | `run GREP <子串>` | 只输出包含子串的行(子串匹配,区分大小写) |
| `HEAD` | `run HEAD [行数]` | 输出前 N 行(默认 10) |

例子:

```
> cat DOCS/README.TXT | run UPPER | run HEAD 3
> cat DOCS/README.TXT | run GREP the | run WC
> ls BIN | run HEAD 5
```

## 实现(内核侧)

- `kernel/pipe.asm`:
  - 捕获状态 `pipe_capture_on` + `pipe_out_begin/pipe_out_end`/`pipe_in_set`/`pipe_reset`;
  - `pipe_capture_byte/pipe_capture_str/pipe_capture_cp` 把终端输出写进缓冲(不印屏);
  - `pipe_read` 给 int 0x30 功能 17 用,从"当前 stdin 缓冲"里按位置拷字节。
- `kernel/kmain.asm`: `term_putc` / `term_print` 开头检查 `pipe_capture_on`,捕获时改走内容进缓冲;
- `kernel/api.asm`: 功能 17 → `pipe_read`;API3(打印码位)也走捕获;
- `kernel/shell.asm`: `shell_execute` 入口扫当前行有没有 `|`,有则 `shell_pipe_execute`:
  拆段 → 借缓冲 → 逐段设置捕获/输入 → `call shell_execute_plain`(原命令分发逻辑)
  → 最后释放缓冲;管道里段程序的日志提示(running/space/收摊)用 `pipe_active` 静音。
- 全屏 UI 直接写显存/光标定位(`term_puts_at`、`fb_putcp_at`),不经过捕获点,
  所以 CALC/EDIT/VI 这类全屏程序不适合放在管道里。

## 和 Linux 的差距

Linux 的 pipe 是一坨"两个进程同时活着"的服务逻辑:环形缓冲页、读写阻塞/唤醒、
SIGPIPE、文件描述符生命周期、splice 之类。KKernel 目前一次只跑一个程序,
所以管道顺序化就能覆盖大部分文本过滤场景;要真并发(边读边写、流式大文件)
就得先给调度器加上多 ring3 任务/每任务地址空间/阻塞原语,那是下一步的事。

## 踩过的坑

- 执行器第一版把"段号"放在 `ebx` 里跨 `shell_execute_plain` 调用——而 shell 命令分发
  和内核打印函数会随意用寄存器,段号被改掉后循环直接退出(表现为"管道没有任何输出")。
  修法是把段号、上一段缓冲、长度全部存内存(`pipe_stage_idx` 等),每步重读。
- `term_putc`/`term_print_dec` 内部也会改 `ebx`——调试打印时不能用寄存器当状态。
- 捕获缓冲里没有自动补 `\0`,所以工具程序要按返回值读字节,不能当 C 字符串用。
