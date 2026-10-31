# TCC 移植版（JoyOS 系统内 C 编译器）

Tiny C Compiler 0.9.28rc (<https://github.com/TinyCC/tinycc>) 的 JoyOS 移植。

## 当前状态

- ✅ `run TCC.BIN -c t1.c -o t1.o` 能编译出**合法的 i386 ELF 目标文件**
  （已在镜像里验证：T1.O 864 字节，readelf 确认 ELF32 REL Intel i386）
- ✅ **能链接并运行**：内核已加 ELF loader（`kernel/elf.asm`），FAT16 里预置了
  `CRT_TCC.O`（TCC 专用最小 crt）和 `MINIC.O`（JoyOS libc）。系统内可以：
  ```
  > run tcc.bin -c hello.c -o hello.o
  > run tcc.bin -static -nostdlib hello.o crt_tcc.o minic.o -o hello.elf
  > run hello.elf
  hello from TCC ELF! ...
  ```
  注意 **必须加 `-static`**（默认动态链接会带 `PT_INTERP /lib/ld-tcc.so.1`，
  JoyOS 没有动态链接器）；`-nostdlib` 是因为系统里没有 libc.a/libtcc1.a。
- 限制：TCC 还不能 include 标准头（磁盘上没部署 include 头文件）；暂不支持
  动态链接、`-run`、自定义链接脚本。

## 构建

需要宿主机 gcc-multilib（`sudo apt install gcc-multilib`）：

```
make build/TCC.BIN   # 从本目录源码编译 TCC（用宿主机 gcc -m32）
make hd              # 重建硬盘镜像（TCC.BIN + T1.C 进 FAT16）
```

镜像里直接跑：

```
> run tcc.bin -c t1.c -o t1.o
> ls          # 能看到 T1.O
```

## 目录

| 路径 | 内容 |
|------|------|
| `src/` | TCC 源码（0.9.28rc，含移植改动） |
| `joyinc/` | 编译 TCC 时用的 libc 头文件（assert/fcntl/setjmp/math/signal/glob/sys/*、stdint/inttypes） |
| `src/config.h` | 手写：i386/ELF/Linux 目标、静态、关 semlock/bcheck/backtrace |
| `joymain.c` | wrapper：JoyOS crt0 不传 argc/argv，这里从 int 0x30 12 号 (`j_arg()`) 构造出 argv 再调 `tcc_real_main()` |
| `src/tccdefs_.h` | 由 `conftest` 的 `c2str` 生成（嵌入 TCC 的预定义宏字符串） |

## 移植改动（相对上游）

1. `src/config.h`：全套配置 + `TCC_TARGET_I386`
2. `src/tcc.c`：`main()` 改名 `tcc_real_main()`（wrapper 负责调用）
3. `src/tccpp.c`：`TOKSYM_TAL_SIZE`/`TOKSTR_TAL_SIZE` 256KB → 16KB
   （JoyOS 用户堆只有 320KB；池满会链式扩展，小文件不受影响）
4. `joymain.c`：构造 argv 调用 `tcc_real_main()`
5. 配套的 JoyOS libc 修复（`lib/minic.c`）：
   - `fwrite` 先判 stdout/stderr 再查 mode —— gcc builtin 优化会把
     `fputs`/`fprintf` 字面量转成 `fwrite`，否则 TCC 的 stdout/stderr 输出静默
   - `fdopen` 把 fd 映射回 `open()` 创建的 FILE —— 否则 TCC 写 .o 文件失败

## 已知限制 / 下一步

- TCC 运行时需要的 include 头文件还没部署到磁盘（`-c` 编译不 include 标准头时可用）
- `libtcc1.a`（TCC 自带运行时库）没有
- 生成的 `.o` 还不能链接成 JoyOS 可执行 BIN（需要 linker + ELF loader）
