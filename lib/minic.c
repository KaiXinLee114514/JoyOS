/* ============================================================================
 *  JoyOS (胡闹OS) — 迷你 libc(够写编辑器用的那一小份)
 *
 *  裸机程序没有 libc(没操作系统给你)。但只要凑齐"字符串 + 内存分配 + 格式化输出 +
 *  一点点文件读写",1990 年代那种正经 C 程序就能直接编过来跑 ——
 *  这份文件就是那个"一点点":约 600 行,顶替掉 glibc 里被用到的那些函数。
 *
 *  文件模型说明(和 POSIX 的差别):
 *      内核的接口是"读一整个文件 / 写一整个文件"(int 0x30 的 7、8 号),
 *      所以这里的 FILE 其实是一块内存缓冲:
 *          "r" → 打开时就把整个文件读进来,fgets/getc 在这块内存上走
 *          "w" → 先攒在内存里,fclose/fflush 时一次性写盘
 *      没有 seek 之后回写、没有追加、没有流式大文件 —— 够用,而且好懂。
 * ==========================================================================*/
#include "minic.h"

/* ---- 内核那边的小工具(joyos.h 里的 static inline)---- */
#include "joyos.h"

/* ==========================================================================
 *  errno
 * ==========================================================================*/
int errno;

/* ==========================================================================
 *  字符串
 * ==========================================================================*/
size_t strlen(const char *s)
{
    const char *p = s;
    while (*p)
        p++;
    return (size_t)(p - s);
}

char *strcpy(char *d, const char *s)
{
    char *r = d;
    while ((*d++ = *s++) != 0)
        ;
    return r;
}

char *strncpy(char *d, const char *s, size_t n)
{
    char *r = d;
    while (n && *s) {
        *d++ = *s++;
        n--;
    }
    while (n--)                             /* 经典行为:不够就用 0 补齐 */
        *d++ = 0;
    return r;
}

char *strcat(char *d, const char *s)
{
    char *r = d;
    while (*d)
        d++;
    while ((*d++ = *s++) != 0)
        ;
    return r;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return (unsigned char)*a - (unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n)
{
    while (n && *a && *a == *b) {
        a++;
        b++;
        n--;
    }
    if (n == 0)
        return 0;
    return (unsigned char)*a - (unsigned char)*b;
}

char *strchr(const char *s, int c)
{
    for (; *s; s++)
        if (*s == (char)c)
            return (char *)s;
    return (c == 0) ? (char *)s : NULL;
}

char *strrchr(const char *s, int c)
{
    const char *last = NULL;
    for (; *s; s++)
        if (*s == (char)c)
            last = s;
    if (c == 0)
        return (char *)s;
    return (char *)last;
}

char *index(const char *s, int c) { return strchr(s, c); }
char *rindex(const char *s, int c) { return strrchr(s, c); }

size_t strcspn(const char *s, const char *reject)
{
    size_t n = 0;
    for (; *s; s++, n++) {
        const char *r;
        for (r = reject; *r; r++)
            if (*s == *r)
                return n;
    }
    return n;
}

void *memcpy(void *d, const void *s, size_t n)
{
    char *dd = (char *)d;
    const char *ss = (const char *)s;
    while (n--)
        *dd++ = *ss++;
    return d;
}

void *memmove(void *d, const void *s, size_t n)
{
    char *dd = (char *)d;
    const char *ss = (const char *)s;
    if (dd < ss) {
        while (n--)
            *dd++ = *ss++;
    } else {
        dd += n;
        ss += n;
        while (n--)
            *--dd = *--ss;
    }
    return d;
}

void *memset(void *d, int c, size_t n)
{
    char *dd = (char *)d;
    while (n--)
        *dd++ = (char)c;
    return d;
}

/* ==========================================================================
 *  ctype(老代码里 isXXX 就是普通函数,不搞宏)
 * ==========================================================================*/
static const char *ct_toupper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
static const char *ct_tolower = "abcdefghijklmnopqrstuvwxyz";

int isalpha(int c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'); }
int isdigit(int c) { return c >= '0' && c <= '9'; }
int isalnum(int c) { return isalpha(c) || isdigit(c); }
int isspace(int c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'; }
int isupper(int c) { return c >= 'A' && c <= 'Z'; }
int islower(int c) { return c >= 'a' && c <= 'z'; }
int ispunct(int c) { return c > 32 && c < 127 && !isalnum(c); }
int isprint(int c) { return c >= 32 && c < 127; }
int iscntrl(int c) { return c < 32 || c == 127; }
int isxdigit(int c) { return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
int isascii(int c) { return (unsigned)c < 128; }
int toupper(int c) { return islower(c) ? ct_toupper[c - 'a'] : c; }
int tolower(int c) { return isupper(c) ? ct_tolower[c - 'A'] : c; }

/* ==========================================================================
 *  内存分配:一条带头结点的空闲链,首次适配 + 相邻合并
 *  堆就是 0x1A0000..0x1EFFFF 那 320 KB(见 joyos.h 的内存约定)
 * ==========================================================================*/
typedef struct blk {
    size_t size;                            /* 可用字节数(不含节点头) */
    struct blk *next;
    int used;
} blk_t;

static blk_t *heap_head;
static void heap_merge_back(void);

static void heap_init(void)
{
    heap_head = (blk_t *)JOY_HEAP_START;
    heap_head->size = (size_t)(JOY_HEAP_END - JOY_HEAP_START) - sizeof(blk_t);
    heap_head->next = NULL;
    heap_head->used = 0;
}

void *malloc(size_t n)
{
    blk_t *b;
    if (!heap_head)
        heap_init();
    if (n == 0)
        n = 1;
    n = (n + 7) & ~7u;                      /* 8 字节对齐 */

    for (b = heap_head; b; b = b->next) {
        if (b->used || b->size < n)
            continue;
        if (b->size >= n + sizeof(blk_t) + 16) {  /* 够大就切一块出来 */
            blk_t *nb = (blk_t *)((char *)b + sizeof(blk_t) + n);
            nb->size = b->size - n - sizeof(blk_t);
            nb->used = 0;
            nb->next = b->next;
            b->next = nb;
            b->size = n;
        }
        b->used = 1;
        return (char *)b + sizeof(blk_t);
    }
    errno = ENOMEM;
    return NULL;
}

void free(void *p)
{
    blk_t *b, *n;
    if (!p)
        return;
    b = (blk_t *)((char *)p - sizeof(blk_t));
    b->used = 0;
    /* 和后面的空闲块合并(后面的块在内存里紧跟其后) */
    while ((n = b->next) != NULL && !n->used
           && (char *)b + sizeof(blk_t) + b->size == (char *)n) {
        b->size += sizeof(blk_t) + n->size;
        b->next = n->next;
    }
    heap_merge_back();
}

/* 把整条链扫一遍,顺手合并所有相邻空闲块(简单、够快) */
static void heap_merge_back(void)
{
    blk_t *b;
    for (b = heap_head; b && b->next; ) {
        blk_t *n = b->next;
        if (!b->used && !n->used
            && (char *)b + sizeof(blk_t) + b->size == (char *)n) {
            b->size += sizeof(blk_t) + n->size;
            b->next = n->next;
        } else {
            b = n;
        }
    }
}

void *calloc(size_t n, size_t sz)
{
    size_t total = n * sz;
    void *p = malloc(total);
    if (p)
        memset(p, 0, total);
    return p;
}

void *realloc(void *p, size_t n)
{
    blk_t *b;
    void *np;
    if (!p)
        return malloc(n);
    b = (blk_t *)((char *)p - sizeof(blk_t));
    if (b->size >= n)
        return p;
    np = malloc(n);
    if (!np)
        return NULL;
    memcpy(np, p, b->size);
    free(p);
    return np;
}

/* 还剩多少堆(调试用) */
size_t heap_free_bytes(void)
{
    blk_t *b;
    size_t total = 0;
    for (b = heap_head; b; b = b->next)
        if (!b->used)
            total += b->size;
    return total;
}

int atoi(const char *s)
{
    int v = 0, neg = 0;
    while (isspace((unsigned char)*s))
        s++;
    if (*s == '-') {
        neg = 1;
        s++;
    } else if (*s == '+') {
        s++;
    }
    while (isdigit((unsigned char)*s))
        v = v * 10 + (*s++ - '0');
    return neg ? -v : v;
}

long atol(const char *s) { return (long)atoi(s); }
int abs(int v) { return v < 0 ? -v : v; }
long labs(long v) { return v < 0 ? -v : v; }

/* ==========================================================================
 *  退出:跳回 crt0 的跳板,再 ret 回 shell
 *  (本来想直接 spin,那会把整台机器挂住 —— 编辑器报个错就得重启,太过分了)
 * ==========================================================================*/
jmp_buf mc_exitbuf;
int mc_exit_code;

void exit(int code)
{
    mc_exit_code = code;
    mc_longjmp(mc_exitbuf, 1);             /* 不返回 */
    for (;;)                                /* 理论上到不了 */
        ;
}

/* 环境变量:没有文件系统之外的东西,一律给 NULL(调用方该有默认值) */
char *getenv(const char *name)
{
    (void)name;
    return NULL;
}

/* 执行外部命令:没有进程这回事,告诉用户一声 */
int system(const char *cmd)
{
    j_print("\n[JoyOS: no shell escape] ");
    if (cmd)
        j_print(cmd);
    j_print("\n");
    return -1;
}

/* ==========================================================================
 *  格式化输出:sprintf / printf / fprintf 共用这一份
 *  支持的:%% %c %s %d %i %u %x %X %o %p,带 - + 空格 0 # 标志和宽度/精度
 *  (照 stevie 用到的来,别的不折腾)
 * ==========================================================================*/
typedef struct {
    char *buf;
    int len;                                /* 已经写了多少(不含结尾 0) */
    int max;                                /* 最多写多少(-1 = 不限) */
} out_t;

static void out_ch(out_t *o, char c)
{
    if (o->max < 0 || o->len < o->max)
        o->buf[o->len] = c;
    o->len++;
}

static void out_str(out_t *o, const char *s, int width, int left, int prec)
{
    int n = 0, i;
    const char *p = s;
    if (!s)
        s = "(null)";
    while (s[n] && (prec < 0 || n < prec))
        n++;
    if (!left)
        for (i = n; i < width; i++)
            out_ch(o, ' ');
    for (i = 0; i < n; i++)
        out_ch(o, *(p + i));
    if (left)
        for (i = n; i < width; i++)
            out_ch(o, ' ');
}

static void out_num(out_t *o, unsigned long v, int base, int upper,
                    int width, int left, int zero, int plus, int space, int alt)
{
    char digs[40];                          /* 逆序的"数字部分"(不含符号/前缀) */
    char pre[4];                            /* 符号 + 0x 前缀 */
    int nd = 0, np = 0, i;
    const char *ds = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    int neg = 0;

    if (base == 10 && (long)v < 0) {
        neg = 1;
        v = (unsigned long)(-(long)v);
    }
    do {
        digs[nd++] = ds[v % (unsigned)base];
        v /= (unsigned)base;
    } while (v);

    if (neg)
        pre[np++] = '-';
    else if (base == 10 && plus)
        pre[np++] = '+';
    else if (base == 10 && space)
        pre[np++] = ' ';
    if (alt && base == 16) {
        pre[np++] = '0';
        pre[np++] = upper ? 'X' : 'x';
    }

    if (!left && !zero)                     /* 空格填充在左边 */
        for (i = np + nd; i < width; i++)
            out_ch(o, ' ');
    for (i = 0; i < np; i++)
        out_ch(o, pre[i]);
    if (!left && zero)                      /* 零填充:在符号/前缀之后 */
        for (i = np + nd; i < width; i++)
            out_ch(o, '0');
    while (nd > 0)
        out_ch(o, digs[--nd]);
    if (left)
        for (i = np + nd; i < width; i++)
            out_ch(o, ' ');
}

int mc_vformat(char *buf, int max, const char *fmt, va_list ap)
{
    out_t o;
    o.buf = buf;
    o.len = 0;
    o.max = max;

    for (; *fmt; fmt++) {
        int left = 0, zero = 0, plus = 0, space = 0, alt = 0;
        int width = 0, prec = -1, longflag = 0;
        if (*fmt != '%') {
            out_ch(&o, *fmt);
            continue;
        }
        fmt++;
        /* ---- 标志 ---- */
        for (;; fmt++) {
            if (*fmt == '-') left = 1;
            else if (*fmt == '0') zero = 1;
            else if (*fmt == '+') plus = 1;
            else if (*fmt == ' ') space = 1;
            else if (*fmt == '#') alt = 1;
            else break;
        }
        /* ---- 宽度 ---- */
        if (*fmt == '*') {
            width = va_arg(ap, int);
            fmt++;
        } else {
            while (isdigit((unsigned char)*fmt))
                width = width * 10 + (*fmt++ - '0');
        }
        /* ---- 精度 ---- */
        if (*fmt == '.') {
            fmt++;
            prec = 0;
            if (*fmt == '*') {
                prec = va_arg(ap, int);
                fmt++;
            } else {
                while (isdigit((unsigned char)*fmt))
                    prec = prec * 10 + (*fmt++ - '0');
            }
        }
        /* ---- 长度修饰 ---- */
        while (*fmt == 'h' || *fmt == 'l' || *fmt == 'L' || *fmt == 'z') {
            if (*fmt == 'l')
                longflag = 1;
            fmt++;
        }
        switch (*fmt) {
        case 'd':
        case 'i': {
            long v = longflag ? va_arg(ap, long) : (long)va_arg(ap, int);
            out_num(&o, (unsigned long)v, 10, 0, width, left, zero, plus, space, 0);
            break;
        }
        case 'u':
            out_num(&o, longflag ? va_arg(ap, unsigned long)
                                 : (unsigned long)va_arg(ap, unsigned),
                    10, 0, width, left, zero, 0, 0, 0);
            break;
        case 'x':
            out_num(&o, longflag ? va_arg(ap, unsigned long)
                                 : (unsigned long)va_arg(ap, unsigned),
                    16, 0, width, left, zero, 0, 0, alt);
            break;
        case 'X':
            out_num(&o, longflag ? va_arg(ap, unsigned long)
                                 : (unsigned long)va_arg(ap, unsigned),
                    16, 1, width, left, zero, 0, 0, alt);
            break;
        case 'o':
            out_num(&o, longflag ? va_arg(ap, unsigned long)
                                 : (unsigned long)va_arg(ap, unsigned),
                    8, 0, width, left, zero, 0, 0, 0);
            break;
        case 'p':
            out_str(&o, "0x", 0, 0, -1);
            out_num(&o, (unsigned long)va_arg(ap, void *), 16, 0, 0, 0, 0, 0, 0, 0);
            break;
        case 'c':
            out_ch(&o, (char)va_arg(ap, int));
            break;
        case 's':
            out_str(&o, va_arg(ap, const char *), width, left, prec);
            break;
        case '%':
            out_ch(&o, '%');
            break;
        case 0:
            fmt--;                          /* 末尾一个孤零零的 % */
            break;
        default:                            /* 不认识的:原样吐出来 */
            out_ch(&o, '%');
            out_ch(&o, *fmt);
            break;
        }
    }
    if (o.max < 0 || o.len < o.max)
        o.buf[o.len] = 0;
    else if (o.max > 0)
        o.buf[o.max - 1] = 0;
    return o.len;
}

int sprintf(char *buf, const char *fmt, ...)
{
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = mc_vformat(buf, -1, fmt, ap);
    va_end(ap);
    return n;
}

int snprintf(char *buf, size_t n, const char *fmt, ...)
{
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = mc_vformat(buf, (int)n - 1, fmt, ap);
    va_end(ap);
    return r;
}

int vsprintf(char *buf, const char *fmt, va_list ap)
{
    return mc_vformat(buf, -1, fmt, ap);
}

/* ==========================================================================
 *  小小的 stdio:FILE 就是一块内存缓冲(见文件头)
 * ==========================================================================*/
#define FMODE_READ  1
#define FMODE_WRITE 2

static FILE mc_stdout_file = {NULL, 0, 0, 0, NULL, 1};
static FILE mc_stderr_file = {NULL, 0, 0, 0, NULL, 2};
FILE *stdout = &mc_stdout_file;
FILE *stderr = &mc_stderr_file;

int mc_console_write(const char *s, int n)
{
    char tmp[256];
    int i = 0;
    while (i < n) {                         /* 分段打,免得要一块大缓冲 */
        int k = 0;
        while (i < n && k < (int)sizeof(tmp) - 1)
            tmp[k++] = s[i++];
        tmp[k] = 0;
        j_print(tmp);
    }
    return n;
}

FILE *fopen(const char *name, const char *mode)
{
    FILE *f;
    int n;

    if (mode[0] == 'w' || mode[0] == 'a') {
        f = (FILE *)malloc(sizeof(FILE));
        if (!f)
            return NULL;
        f->buf = (char *)malloc(MC_WRITE_MAX);
        if (!f->buf) {
            free(f);
            return NULL;
        }
        f->name = name;
        f->len = 0;
        f->pos = 0;
        f->mode = FMODE_WRITE;
        return f;
    }

    /* 读:整个读进来 */
    f = (FILE *)malloc(sizeof(FILE));
    if (!f)
        return NULL;
    f->buf = (char *)malloc(MC_READ_MAX);
    if (!f->buf) {
        free(f);
        return NULL;
    }
    n = j_readfile(name, f->buf, MC_READ_MAX);
    if (n < 0) {
        free(f->buf);
        free(f);
        errno = ENOENT;
        return NULL;
    }
    f->name = name;
    f->len = n;
    f->pos = 0;
    f->mode = FMODE_READ;
    return f;
}

int fclose(FILE *f)
{
    int r = 0;
    if (!f)
        return EOF;
    if (f == &mc_stdout_file || f == &mc_stderr_file)
        return 0;
    if (f->mode & FMODE_WRITE)
        r = j_writefile(f->name, f->buf, f->len);
    free(f->buf);
    free(f);
    return (r == 0) ? 0 : EOF;
}

int fflush(FILE *f)
{
    if (f && (f->mode & FMODE_WRITE) && f != &mc_stdout_file)
        return (j_writefile(f->name, f->buf, f->len) == 0) ? 0 : EOF;
    return 0;
}

int fgetc(FILE *f)
{
    if (!f || !(f->mode & FMODE_READ) || f->pos >= f->len)
        return EOF;
    return (unsigned char)f->buf[f->pos++];
}

int getc(FILE *f) { return fgetc(f); }

int fputc(int c, FILE *f)
{
    if (!f)
        return EOF;
    if (f->mode & FMODE_WRITE) {
        if (f->len >= MC_WRITE_MAX)
            return EOF;
        f->buf[f->len++] = (char)c;
        return (unsigned char)c;
    }
    return EOF;
}

int putc(int c, FILE *f) { return fputc(c, f); }

char *fgets(char *s, int n, FILE *f)
{
    int i = 0, c;
    if (!f || n <= 1)
        return NULL;
    while (i < n - 1) {
        c = fgetc(f);
        if (c == EOF)
            break;
        s[i++] = (char)c;
        if (c == '\n')
            break;
    }
    if (i == 0)
        return NULL;
    s[i] = 0;
    return s;
}

int fputs(const char *s, FILE *f)
{
    int n = 0;
    if (!f)
        return EOF;
    if (f == &mc_stdout_file || f == &mc_stderr_file) {
        int len = (int)strlen(s);
        mc_console_write(s, len);
        return len;
    }
    while (*s) {
        if (fputc(*s++, f) == EOF)
            return EOF;
        n++;
    }
    return n;
}

int putchar(int c)
{
    return fputc(c, stdout);
}

int puts(const char *s)
{
    fputs(s, stdout);
    return fputc('\n', stdout);
}

int printf(const char *fmt, ...)
{
    char buf[MC_PRINT_BUF];
    va_list ap;
    va_start(ap, fmt);
    mc_vformat(buf, (int)sizeof(buf) - 1, fmt, ap);
    va_end(ap);
    return fputs(buf, stdout);
}

int fprintf(FILE *f, const char *fmt, ...)
{
    char buf[MC_PRINT_BUF];
    va_list ap;
    va_start(ap, fmt);
    mc_vformat(buf, (int)sizeof(buf) - 1, fmt, ap);
    va_end(ap);
    return fputs(buf, f);
}

int vfprintf(FILE *f, const char *fmt, va_list ap)
{
    char buf[MC_PRINT_BUF];
    mc_vformat(buf, (int)sizeof(buf) - 1, fmt, ap);
    return fputs(buf, f);
}

void perror(const char *s)
{
    if (s) {
        fputs(s, stderr);
        fputs(": ", stderr);
    }
    fputs("JoyOS error\n", stderr);
}

/* ---- 文件管理:内核接口只有"整读整写",所以删除做不到、改名是拷贝 ---- */
int remove(const char *name)
{
    (void)name;
    errno = EACCES;
    return -1;                              /* 没有删除接口,老实说做不到 */
}

int rename(const char *oldname, const char *newname)
{
    char *buf = (char *)malloc(MC_READ_MAX);
    int n, r;
    if (!buf)
        return -1;
    n = j_readfile(oldname, buf, MC_READ_MAX);
    if (n < 0) {
        free(buf);
        errno = ENOENT;
        return -1;
    }
    r = j_writefile(newname, buf, n);
    free(buf);
    return r;
}

int access(const char *name, int mode)
{
    char *buf;
    int n;
    (void)mode;
    buf = (char *)malloc(MC_READ_MAX);
    if (!buf)
        return -1;
    n = j_readfile(name, buf, MC_READ_MAX);
    free(buf);
    return (n < 0) ? -1 : 0;
}
