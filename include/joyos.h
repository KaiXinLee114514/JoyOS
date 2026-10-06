/* ============================================================================
 *  JoyOS (胡闹OS) — 给 C 程序用的头文件
 *
 *  程序怎么跟内核说话?还是那扇门:int 0x30(见 kernel/api.asm)。
 *  汇编里要自己搬寄存器,C 里就包成一组 static inline 函数,用起来像普通函数调用:
 *
 *      #include "joyos.h"
 *      int main(void) { j_print("hello from C\n"); return 0; }
 *
 *  ── 编译(不用找交叉编译器,普通 gcc 就行)───────────────────────────────
 *      gcc -m32 -std=gnu89 -ffreestanding -fno-pic -fno-stack-protector \
 *          -fno-asynchronous-unwind-tables -fno-builtin -nostdlib \
 *          -Iinclude -c prog.c -o prog.o
 *      ld -m elf_i386 -T lib/joyos.ld lib/crt0.o prog.o lib/minic.o -o PROG.BIN
 *
 *  (Makefile 里已经写好了,`make` 会自己编 progs 目录下的 .c)
 *
 *  ── 内存约定 ────────────────────────────────────────────────────────────
 *      0x120000            程序被读到这里(所以链接地址就是它,-T lib/joyos.ld)
 *      0x120000..0x19FFFF  程序镜像(代码 + 只读数据 + 已初始化数据)
 *      0x1A0000..0x1EFFFF  堆(malloc 从这儿切,320 KB)
 *      0x1F0000            内核临时用(读字库描述块)
 *      0x200000 起         完整字库 —— 谁都不许碰
 *      0x400000..0xFFFFFF  内核物理页池(12 MiB,页表/动态映射从这里发)—— 也别碰
 *      注:0~16 MiB 是恒等映射(虚拟地址 = 物理地址),所以指针就是物理地址
 *
 *  ── 寄存器约定(内核保证)──────────────────────────────────────────────
 *      调用后:eax / ebx / esi 是返回值,ecx / edx / edi / ebp 保证不变
 * ==========================================================================*/
#ifndef JOYOS_H
#define JOYOS_H

/* ---- 基本类型:裸机环境没有 libc 的头,自己定 ---- */
typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned int   u32;
typedef signed int     i32;

#define NULL ((void *)0)
typedef unsigned int size_t;

/* ---- 屏幕/内存布局常量(和 docs/programs.md 一致)---- */
#define JOY_HEAP_START 0x1A0000u
#define JOY_HEAP_END   0x1F0000u

/* ---- 颜色:和文本模式一个规矩(低 4 位 = 前景)---- */
#define JOY_BLACK   0x00
#define JOY_BLUE    0x01
#define JOY_GREEN   0x02
#define JOY_CYAN    0x03
#define JOY_RED     0x04
#define JOY_MAGENTA 0x05
#define JOY_BROWN   0x06
#define JOY_GREY    0x07
#define JOY_DGREY   0x08
#define JOY_LBLUE   0x09
#define JOY_LGREEN  0x0A
#define JOY_LCYAN   0x0B
#define JOY_LRED    0x0C
#define JOY_LMAGENTA 0x0D
#define JOY_YELLOW  0x0E
#define JOY_WHITE   0x0F

/* ---- 扩展键(eax=10 的返回值里 0x100 以上的部分)---- */
#define JOY_KEY_UP    0x101
#define JOY_KEY_DOWN  0x102
#define JOY_KEY_LEFT  0x103
#define JOY_KEY_RIGHT 0x104
#define JOY_KEY_HOME  0x105
#define JOY_KEY_END   0x106
#define JOY_KEY_DEL   0x107
#define JOY_KEY_PGUP  0x108
#define JOY_KEY_PGDN  0x109

/* ==========================================================================
 *  int 0x30 的包装
 *  ★ 约束里的 "b"/"S"/"D" 分别是 ebx/esi/edi。用 ebx 当寄存器得配合 -fno-pic
 *    (位置无关代码要拿 ebx 当 GOT 指针),这也是上面编译参数里 -fno-pic 的原因。
 * ==========================================================================*/
#define JOY_SYSCALL0(fn, ret) \
    __asm__ volatile("int $0x30" : "=a"(ret) : "a"(fn) : "memory")

/* 0:打印 UTF-8 字符串(0 结尾) */
static inline void j_print(const char *s)
{
    __asm__ volatile("int $0x30" : : "a"(0), "S"(s) : "memory");
}

/* 1:打印十进制 */
static inline void j_print_dec(i32 v)
{
    __asm__ volatile("int $0x30" : : "a"(1), "b"(v) : "memory");
}

/* 2:打印十六进制(自动带 0x) */
static inline void j_print_hex(u32 v)
{
    __asm__ volatile("int $0x30" : : "a"(2), "b"(v) : "memory");
}

/* 3:按 Unicode 码位打印一个字符(汉字也行) */
static inline void j_print_cp(u32 cp)
{
    __asm__ volatile("int $0x30" : : "a"(3), "b"(cp) : "memory");
}

/* 4:设颜色(参数是属性字节) */
static inline void j_color(int attr)
{
    __asm__ volatile("int $0x30" : : "a"(4), "b"(attr) : "memory");
}

/* 5:等一个按键 → ASCII(方向键会被跳过) */
static inline int j_getchar(void)
{
    int r;
    JOY_SYSCALL0(5, r);
    return r;
}

/* 6:清屏 */
static inline void j_clrscr(void)
{
    __asm__ volatile("int $0x30" : : "a"(6) : "memory");
}

/* 7:读文件 → 字节数,-1 = 打不开 */
static inline int j_readfile(const char *name, void *buf, int max)
{
    int r;
    __asm__ volatile("int $0x30" : "=a"(r)
                     : "a"(7), "S"(name), "D"(buf), "c"(max)
                     : "memory");
    return r;
}

/* 8:写文件 → 0 成功,-1 失败 */
static inline int j_writefile(const char *name, const void *data, int len)
{
    int r;
    __asm__ volatile("int $0x30" : "=a"(r)
                     : "a"(8), "S"(name), "D"(data), "c"(len)
                     : "memory");
    return r;
}

/* 9:定位光标(行/列,从 0 起) */
static inline void j_setcursor(int row, int col)
{
    __asm__ volatile("int $0x30" : : "a"(9), "b"(row), "c"(col) : "memory");
}

/* 10:等一个键事件 → ASCII,或 0x100+编号(方向键那一家) */
static inline int j_getkey(void)
{
    int r;
    JOY_SYSCALL0(10, r);
    return r;
}

/* 11:屏幕尺寸 → 列数(返回),行数写进 *rows */
static inline int j_screensize(int *rows)
{
    int cols, rws;
    __asm__ volatile("int $0x30" : "=a"(cols), "=b"(rws) : "a"(11) : "memory");
    if (rows)
        *rows = rws;
    return cols;
}

/* 12:取程序参数(run PROG 参数) */
static inline const char *j_arg(void)
{
    const char *p;
    __asm__ volatile("int $0x30" : "=S"(p) : "a"(12) : "memory");
    return p;
}

/* 13:在指定位置画一串字(不滚屏、不动光标)→ 占了几格 */
static inline int j_puts_at(const char *s, int row, int col, int maxcells)
{
    int r;
    __asm__ volatile("int $0x30" : "=a"(r)
                     : "a"(13), "S"(s), "b"(row), "c"(col), "d"(maxcells)
                     : "memory");
    return r;
}

/* 14:蜂鸣器:响 freq_hz 赫兹、持续 ms 毫秒(freq_hz <= 0 = 静音等 ms,当 sleep 用) */
static inline void j_beep(int freq_hz, int ms)
{
    __asm__ volatile("int $0x30" : : "a"(14), "b"(freq_hz), "c"(ms) : "memory");
}

/* ---- 小小工具 ---- */
static inline void j_newline(void)
{
    j_print("\n");
}

static inline void j_exit(const char *msg)
{
    j_clrscr();
    j_color(JOY_GREY);
    if (msg)
        j_print(msg);
}

#endif /* JOYOS_H */
