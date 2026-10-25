/* ============================================================================
 *  JoyOS — 迷你 libc(够写编辑器用的那一小份)
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

int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *p = (const unsigned char *)a;
    const unsigned char *q = (const unsigned char *)b;
    while (n--) {
        if (*p != *q)
            return (int)*p - (int)*q;
        p++;
        q++;
    }
    return 0;
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

/* 打印堆状态(调试用) */
void heap_dump(void)
{
    blk_t *b;
    int n = 0, freecnt = 0;
    size_t freebytes = 0, maxfree = 0, usedbytes = 0;
    for (b = heap_head; b; b = b->next) {
        n++;
        if (b->used)
            usedbytes += b->size;
        else {
            freecnt++;
            freebytes += b->size;
            if (b->size > maxfree)
                maxfree = b->size;
        }
        if (n <= 8)
            printf("dbg: heap blk %d size=%lu used=%d\n", n, (unsigned long)b->size, b->used);
    }
    printf("dbg: heap_head=%p blocks=%d used=%lu free=%lu maxfree=%lu freecnt=%d\n",
           (void *)heap_head, n, (unsigned long)usedbytes, (unsigned long)freebytes,
           (unsigned long)maxfree, freecnt);
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

/* strtol:按 base 解析。end 指向"解析停止的位置"(可为 NULL) */
long strtol(const char *s, char **end, int base)
{
    long v = 0;
    int neg = 0, d, any = 0;

    while (isspace((unsigned char)*s))
        s++;
    if (*s == '-') {
        neg = 1;
        s++;
    } else if (*s == '+') {
        s++;
    }
    if ((base == 0 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        base = 16;
        s += 2;
    } else if (base == 0 && s[0] == '0') {
        base = 8;
        s++;
    } else if (base == 0) {
        base = 10;
    }
    for (;; s++) {
        if (*s >= '0' && *s <= '9')
            d = *s - '0';
        else if (*s >= 'a' && *s <= 'z')
            d = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'Z')
            d = *s - 'A' + 10;
        else
            break;
        if (d >= base)
            break;
        v = v * base + d;
        any = 1;
    }
    if (end)
        *end = (char *)(any ? s : s);
    return neg ? -v : v;
}

/* strtoul:无符号版(不处理负号,TCC 只往正数用) */
unsigned long strtoul(const char *s, char **end, int base)
{
    unsigned long v = 0;
    int d;

    while (isspace((unsigned char)*s))
        s++;
    if (*s == '+')
        s++;
    if ((base == 0 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        base = 16;
        s += 2;
    } else if (base == 0 && s[0] == '0') {
        base = 8;
        s++;
    } else if (base == 0) {
        base = 10;
    }
    for (;; s++) {
        if (*s >= '0' && *s <= '9')
            d = *s - '0';
        else if (*s >= 'a' && *s <= 'z')
            d = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'Z')
            d = *s - 'A' + 10;
        else
            break;
        if (d >= base)
            break;
        v = v * base + (unsigned long)d;
    }
    if (end)
        *end = (char *)s;
    return v;
}

long long strtoll(const char *s, char **end, int base)
{
    long long v = 0;
    int neg = 0, d, any = 0;

    while (isspace((unsigned char)*s))
        s++;
    if (*s == '-') {
        neg = 1;
        s++;
    } else if (*s == '+') {
        s++;
    }
    if ((base == 0 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        base = 16;
        s += 2;
    } else if (base == 0 && s[0] == '0') {
        base = 8;
        s++;
    } else if (base == 0) {
        base = 10;
    }
    for (;; s++) {
        if (*s >= '0' && *s <= '9')
            d = *s - '0';
        else if (*s >= 'a' && *s <= 'z')
            d = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'Z')
            d = *s - 'A' + 10;
        else
            break;
        if (d >= base)
            break;
        v = v * (long long)base + (long long)d;
        any = 1;
    }
    if (end)
        *end = (char *)s;
    return neg ? -v : v;
}

unsigned long long strtoull(const char *s, char **end, int base)
{
    unsigned long long v = 0;
    int d;

    while (isspace((unsigned char)*s))
        s++;
    if (*s == '+')
        s++;
    if ((base == 0 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        base = 16;
        s += 2;
    } else if (base == 0 && s[0] == '0') {
        base = 8;
        s++;
    } else if (base == 0) {
        base = 10;
    }
    for (;; s++) {
        if (*s >= '0' && *s <= '9')
            d = *s - '0';
        else if (*s >= 'a' && *s <= 'z')
            d = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'Z')
            d = *s - 'A' + 10;
        else
            break;
        if (d >= base)
            break;
        v = v * (unsigned long long)base + (unsigned long long)d;
    }
    if (end)
        *end = (char *)s;
    return v;
}

/* strtod:简单浮点解析(TCC 用 strtold→这里,精度 double 够 i386 目标) */
double strtod(const char *s, char **end)
{
    double v = 0.0, frac = 0.1;
    int neg = 0, any = 0, e = 0, esign = 1;

    while (isspace((unsigned char)*s))
        s++;
    if (*s == '-') {
        neg = 1;
        s++;
    } else if (*s == '+') {
        s++;
    }
    while (*s >= '0' && *s <= '9') {
        v = v * 10.0 + (double)(*s - '0');
        s++;
        any = 1;
    }
    if (*s == '.') {
        s++;
        while (*s >= '0' && *s <= '9') {
            v += (double)(*s - '0') * frac;
            frac *= 0.1;
            s++;
            any = 1;
        }
    }
    if (any && (*s == 'e' || *s == 'E')) {
        const char *p = s + 1;
        esign = 1;
        if (*p == '+')
            p++;
        else if (*p == '-') {
            esign = -1;
            p++;
        }
        if (*p >= '0' && *p <= '9') {
            s = p;
            while (*s >= '0' && *s <= '9') {
                e = e * 10 + (*s - '0');
                s++;
            }
            while (e-- > 0)
                v = (esign > 0) ? v * 10.0 : v / 10.0;
        }
    }
    if (end)
        *end = (char *)s;
    return neg ? -v : v;
}

float strtof(const char *s, char **end)
{
    return (float)strtod(s, end);
}

long double strtold(const char *s, char **end)
{
    return (long double)strtod(s, end);
}

double ldexp(double x, int e)
{
    while (e > 0) {
        x *= 2.0;
        e--;
    }
    while (e < 0) {
        x /= 2.0;
        e++;
    }
    return x;
}

/* ==========================================================================
 *  随机数:xorshift32。不播种时首次调用用 TSC 抖自动播 —— 连读几次取异或,
 *  把开机时几乎固定的低位噪声抹匀。返回 0..RAND_MAX。
 * ==========================================================================*/
static unsigned int mc_rand_state;

void srand(unsigned int seed)
{
    mc_rand_state = seed ? seed : 0x9E3779B9u;
}

unsigned int rand(void)
{
    unsigned int s = mc_rand_state;

    if (s == 0) {
        unsigned long long t = j_rdtsc();
        unsigned int mix = (unsigned int)(t ^ (t >> 32));
        mix ^= mix << 13;
        mix ^= mix >> 17;
        mix ^= mix << 5;
        s = mix ? mix : 0x9E3779B9u;
        mc_rand_state = s;
    }
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    mc_rand_state = s;
    return s & 0x7FFFFFFFu;
}

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

/* ==========================================================================
 *  计时器
 *  TSC 是 CPU 周期数,换算成真秒要 CPU 频率 —— 这里不猜频率:
 *      time()  ≈ TSC 高 32 位"翻一次"当 1 秒(粗,只适合测顺序/耗时)
 *      clock() ≈ TSC >> 12,当"微秒级 tick"用(CLOCKS_PER_SEC 只是名义值)
 *  要精确等,用 sleep() —— 它走蜂鸣器的静音等待,毫秒级由内核 PIT 保证。
 * ==========================================================================*/
time_t time(time_t *t)
{
    time_t v = (time_t)(j_rdtsc() >> 32);
    if (t)
        *t = v;
    return v;
}

int gettimeofday(struct timeval *tv, void *tz)
{
    (void)tz;
    if (tv) {
        tv->tv_sec = time(NULL);
        tv->tv_usec = 0;
    }
    return 0;
}

int mprotect(void *addr, unsigned int len, int prot)
{
    (void)addr;
    (void)len;
    (void)prot;
    return 0;   /* JoyOS 用户态没有页权限概念:假装成功 */
}

/* libgcc 的 64 位无符号除法/取模(i386 没有硬件 64 位除法指令,TCC 等程序要用) */
unsigned long long __udivdi3(unsigned long long n, unsigned long long d)
{
    unsigned long long q = 0;
    int s = 0;
    if (d == 0)
        return 0;
    while (!(d & 0x8000000000000000ULL)) {
        d <<= 1;
        s++;
    }
    for (; s >= 0; s--) {
        if (n >= d) {
            n -= d;
            q |= (1ULL << s);
        }
        d >>= 1;
    }
    return q;
}

unsigned long long __umoddi3(unsigned long long n, unsigned long long d)
{
    unsigned long long dd;
    int s = 0;

    if (d == 0)
        return 0;
    dd = d;
    while (!(dd & 0x8000000000000000ULL)) {
        dd <<= 1;
        s++;
    }
    for (; s >= 0; s--) {
        if (n >= dd)
            n -= dd;
        dd >>= 1;
    }
    return n;
}

clock_t clock(void)
{
    return (clock_t)(j_rdtsc() >> 12);
}

/* localtime:把 time_t 秒数拆成日历(近似 UTC;TCC 只用来生成 __DATE__/__TIME__) */
struct tm *localtime(const time_t *t)
{
    static struct tm tmv;
    static const int mdays[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    long secs = (long)*t;
    long days = secs / 86400;
    long rem = secs % 86400;
    int year = 1970, mon, md, leap;

    if (rem < 0) {
        rem += 86400;
        days--;
    }
    tmv.tm_hour = (int)(rem / 3600);
    tmv.tm_min = (int)((rem % 3600) / 60);
    tmv.tm_sec = (int)(rem % 60);
    tmv.tm_wday = (int)((days + 4) % 7);   /* 1970-01-01 是周四 */
    tmv.tm_isdst = 0;
    tmv.tm_yday = 0;

    for (;;) {
        leap = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
        if (days < 365 + leap)
            break;
        days -= 365 + leap;
        year++;
    }
    leap = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
    for (mon = 0; mon < 12; mon++) {
        md = mdays[mon] + (mon == 1 ? leap : 0);
        if (days < md)
            break;
        days -= md;
    }
    tmv.tm_year = year - 1900;
    tmv.tm_mon = mon;
    tmv.tm_mday = (int)days + 1;
    return &tmv;
}

char *getcwd(char *buf, unsigned int size)
{
    if (!buf) {
        if (size < 2)
            size = 2;
        buf = (char *)malloc(size);
        if (!buf)
            return NULL;
    }
    if (size < 2)
        return NULL;
    buf[0] = '/';
    buf[1] = '\0';
    return buf;
}

char *realpath(const char *path, char *resolved)
{
    size_t n = strlen(path) + 1;
    char *r = resolved;
    if (!r) {
        r = (char *)malloc(n);
        if (!r)
            return NULL;
    }
    strcpy(r, path);
    return r;
}

/* JoyOS 没有进程模型:exec 一律失败(TCC 的自举切换用,不走这里) */
int execvp(const char *file, char *const argv[])
{
    (void)file;
    (void)argv;
    errno = ENOENT;
    return -1;
}

unsigned int sleep(unsigned int seconds)
{
    if (seconds)
        j_beep(0, (int)(seconds * 1000u));
    return 0;
}

/* 环境变量:没有文件系统之外的东西,一律给 NULL(调用方该有默认值) */
char *getenv(const char *name)
{
    (void)name;
    return NULL;
}

/* JoyOS 没有环境变量:空环境表(TCC 的 tccrun 要用) */
static char *mc_envp_empty[] = { NULL };
char **environ = mc_envp_empty;

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

/* ---------------------------------------------------------------------------
 *  浮点输出:%f —— 默认 6 位小数,支持精度/宽度/左对齐/零填充
 *  说明:用 double 做整数部分 + 小数部分拆解,精度到 1e-9 够 printf 用了。
 *        (JoyOS 的 x87 由 kernel/fpu.asm 初始化)
 * -------------------------------------------------------------------------*/
static void out_double(out_t *o, double v, int prec, int width, int left,
                       int zero, int plus, int space)
{
    char intbuf[40];
    int ni = 0, i, neg = 0;
    unsigned long long ip, frac, scale = 1;
    int pad, total;

    if (v != v) {                           /* NaN */
        out_str(o, "nan", width, left, -1);
        return;
    }
    if (v > 1.0e308 || v < -1.0e308) {      /* Inf */
        out_str(o, "inf", width, left, -1);
        return;
    }
    if (v < 0.0) { neg = 1; v = -v; }
    if (prec < 0) prec = 6;
    if (prec > 9) prec = 9;
    for (i = 0; i < prec; i++)
        scale *= 10ULL;

    ip = (unsigned long long)v;             /* 整数部分(截断;小数在下面四舍五入) */
    {
        double d = (v - (double)ip) * (double)scale;
        frac = (unsigned long long)(d + 0.5);
    }
    if (frac >= scale) {                    /* 进位到整数 */
        frac -= scale;
        ip++;
    }

    do {                                    /* 整数部分(逆序) */
        intbuf[ni++] = (char)('0' + (int)(ip % 10));
        ip /= 10;
    } while (ip);

    for (i = 0; i < prec; i++) {            /* 小数部分(逆序,自动补前导 0) */
        intbuf[ni + i] = (char)('0' + (int)(frac % 10));
        frac /= 10;
    }

    total = (neg || plus || space ? 1 : 0) + ni + (prec > 0 ? 1 + prec : 0);
    pad = width - total;
    if (!left && !zero && pad > 0)
        for (i = 0; i < pad; i++) out_ch(o, ' ');
    if (neg) out_ch(o, '-');
    else if (plus) out_ch(o, '+');
    else if (space) out_ch(o, ' ');
    if (!left && zero && pad > 0)
        for (i = 0; i < pad; i++) out_ch(o, '0');
    for (i = ni - 1; i >= 0; i--)
        out_ch(o, intbuf[i]);
    if (prec > 0) {
        out_ch(o, '.');
        for (i = prec - 1; i >= 0; i--)
            out_ch(o, intbuf[ni + i]);
    }
    if (left && pad > 0)
        for (i = 0; i < pad; i++) out_ch(o, ' ');
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
        case 'f':
        case 'F': {
            double d = va_arg(ap, double);   /* float 默认提升为 double */
            out_double(&o, d, prec, width, left, zero, plus, space);
            break;
        }
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

int vsnprintf(char *buf, unsigned int size, const char *fmt, va_list ap)
{
    return mc_vformat(buf, (int)size - 1, fmt, ap);
}

/* ==========================================================================
 *  小小的 stdio:FILE 就是一块内存缓冲(见文件头)
 * ==========================================================================*/
#define FMODE_READ  1
#define FMODE_WRITE 2

static FILE mc_stdout_file = {NULL, 0, 0, 0, NULL, 1};
static FILE mc_stderr_file = {NULL, 0, 0, 0, NULL, 2};
static FILE mc_stdin_file = {NULL, 0, 0, 0, NULL, 0};
FILE *stdout = &mc_stdout_file;
FILE *stderr = &mc_stderr_file;
FILE *stdin  = &mc_stdin_file;

static FILE *mc_fd_get(int fd);  /* 前向声明:fdopen 在它前面 */

FILE *fdopen(int fd, const char *mode)
{
    (void)mode;
    if (fd == 0)
        return stdin;
    if (fd == 1)
        return stdout;
    if (fd == 2)
        return stderr;
    /* open() 已经把 FILE 挂进 fd 表,直接返回同一个 FILE,
     * 否则 TCC 的 open()+fdopen("wb") 写文件路径会拿到 NULL。 */
    return mc_fd_get(fd);
}

FILE *freopen(const char *name, const char *mode, FILE *f)
{
    (void)name;
    (void)mode;
    return f;   /* JoyOS 文件是整文件缓冲模型,原样返回 */
}

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

/* ==========================================================================
 *  unistd(POSIX 子集)
 *  内核只有"整读整写",所以这里拿 FILE 的缓冲当 fd:
 *      open("r") → 整文件读进内存;open("w") → 攒内存,close 时写回
 *      read/write/lseek 全在缓冲上操作
 *  fd 0/1/2 是控制台;文件 fd 从 3 起,上限 MC_MAXFD。
 * ==========================================================================*/
#define MC_MAXFD 16

static FILE *mc_fdt[MC_MAXFD];              /* 0/1/2 不用,留空 */

static FILE *mc_fd_get(int fd)
{
    if (fd < 3 || fd >= MC_MAXFD || !mc_fdt[fd]) {
        errno = EINVAL;
        return NULL;
    }
    return mc_fdt[fd];
}

int open(const char *name, int flags, ...)
{
    int fd;
    FILE *f;

    for (fd = 3; fd < MC_MAXFD; fd++)
        if (!mc_fdt[fd])
            break;
    if (fd >= MC_MAXFD) {
        errno = ENOMEM;
        return -1;
    }
    f = fopen(name, (flags & (O_WRONLY | O_RDWR)) ? "w" : "r");
    if (!f) {
        if (!(flags & O_CREAT))
            errno = ENOENT;
        return -1;
    }
    mc_fdt[fd] = f;
    return fd;
}

int close(int fd)
{
    FILE *f = mc_fd_get(fd);
    int r;

    if (!f)
        return -1;
    r = fclose(f);
    mc_fdt[fd] = NULL;
    return r;
}

int read(int fd, void *buf, int n)
{
    FILE *f;
    int k = 0;
    char *p = (char *)buf;

    if (fd == STDIN_FILENO) {               /* 控制台:读一行(回车结束) */
        while (k < n) {
            int c = j_getchar();
            if (c < 0)
                break;
            p[k++] = (char)c;
            if (c == '\n')
                break;
        }
        return k;
    }
    f = mc_fd_get(fd);
    if (!f)
        return -1;
    while (k < n && f->pos < f->len)
        p[k++] = f->buf[f->pos++];
    return k;
}

int write(int fd, const void *buf, int n)
{
    FILE *f;

    if (fd == STDOUT_FILENO || fd == STDERR_FILENO)
        return mc_console_write((const char *)buf, n);
    f = mc_fd_get(fd);
    if (!f)
        return -1;
    if (!(f->mode & FMODE_WRITE)) {
        errno = EACCES;
        return -1;
    }
    if (f->pos + n > MC_WRITE_MAX) {
        errno = ENOMEM;
        return -1;
    }
    memcpy(f->buf + f->pos, buf, n);
    f->pos += n;
    if (f->pos > f->len)
        f->len = f->pos;
    return n;
}

int lseek(int fd, int off, int whence)
{
    FILE *f;
    int base;

    if (fd == STDIN_FILENO || fd == STDOUT_FILENO || fd == STDERR_FILENO)
        return -1;                          /* 控制台不可 seek */
    f = mc_fd_get(fd);
    if (!f)
        return -1;
    if (whence == SEEK_SET)
        base = 0;
    else if (whence == SEEK_CUR)
        base = f->pos;
    else if (whence == SEEK_END)
        base = f->len;
    else {
        errno = EINVAL;
        return -1;
    }
    if (base + off < 0) {
        errno = EINVAL;
        return -1;
    }
    f->pos = base + off;
    return f->pos;
}

int unlink(const char *name)
{
    (void)name;
    errno = EACCES;                         /* 内核没有删除接口 */
    return -1;
}

int getpid(void)
{
    return 1;                               /* 单任务,固定 1 */
}

/* ==========================================================================
 *  第二批:stdio 的 fread/fwrite/fseek/ftell、qsort、strerror、string 加固
 * ==========================================================================*/

size_t fread(void *ptr, size_t size, size_t nmemb, FILE *f)
{
    size_t total, got = 0;
    char *p = (char *)ptr;

    if (!f || !(f->mode & FMODE_READ) || size == 0 || nmemb == 0)
        return 0;
    total = size * nmemb;
    while (got < total && f->pos < f->len)
        p[got++] = f->buf[f->pos++];
    return got / size;
}

size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *f)
{
    size_t total, put = 0;
    const char *p = (const char *)ptr;

    if (!f || size == 0 || nmemb == 0)
        return 0;
    total = size * nmemb;
    /* stdout/stderr 的 FILE 结构没有 FMODE_WRITE(控制台不是文件),
     * 必须先判它们再查 mode —— 否则 gcc 把 fputs/fprintf 字面量优化成
     * fwrite 后会在 mode 检查处静默返回,什么都不打印。 */
    if (f == stdout || f == stderr) {
        mc_console_write(p, (int)total);
        return nmemb;
    }
    if (!(f->mode & FMODE_WRITE))
        return 0;
    while (put < total && f->pos < MC_WRITE_MAX) {
        if (f->pos >= f->len)
            f->len = f->pos + 1;
        f->buf[f->pos++] = p[put++];
    }
    return put / size;
}

int fseek(FILE *f, long off, int whence)
{
    long base;

    if (!f || f == stdout || f == stderr) {
        errno = EINVAL;
        return -1;
    }
    if (whence == SEEK_SET)
        base = 0;
    else if (whence == SEEK_CUR)
        base = f->pos;
    else if (whence == SEEK_END)
        base = f->len;
    else {
        errno = EINVAL;
        return -1;
    }
    if (base + off < 0) {
        errno = EINVAL;
        return -1;
    }
    f->pos = (int)(base + off);
    return 0;
}

long ftell(FILE *f)
{
    return f ? (long)f->pos : -1;
}

void rewind(FILE *f)
{
    if (f)
        f->pos = 0;
}

int feof(FILE *f)
{
    return (f && (f->mode & FMODE_READ) && f->pos >= f->len) ? 1 : 0;
}

int ferror(FILE *f)
{
    (void)f;
    return 0;                               /* 简化:不记录错误标记 */
}

int ungetc(int c, FILE *f)
{
    if (!f || !(f->mode & FMODE_READ) || f->pos <= 0)
        return EOF;
    f->pos--;
    return c;
}

int fileno(FILE *f)
{
    int i;

    if (!f)
        return -1;
    if (f == stdout)
        return 1;
    if (f == stderr)
        return 2;
    for (i = 3; i < MC_MAXFD; i++)
        if (mc_fdt[i] == f)
            return i;
    return -1;
}

int isatty(int fd)
{
    return (fd >= 0 && fd <= 2) ? 1 : 0;
}

char *strerror(int err)
{
    switch (err) {
    case 0:      return "success";
    case EPERM:  return "operation not permitted";
    case ENOENT: return "no such file or directory";
    case EIO:    return "input/output error";
    case ENOMEM: return "out of memory";
    case EACCES: return "permission denied";
    case EEXIST: return "file exists";
    case EINVAL: return "invalid argument";
    default:     return "unknown error";
    }
}

/* qsort:教学量级用插入排序,O(n²) 但稳,元素按字节搬 */
void qsort(void *base, size_t n, size_t sz, int (*cmp)(const void *, const void *))
{
    char *b = (char *)base;
    size_t i, j, k;

    if (!b || !cmp || n < 2 || sz == 0)
        return;
    for (i = 1; i < n; i++) {
        for (j = i; j > 0; j--) {
            char *a = b + (j - 1) * sz;
            char *d = b + j * sz;
            char t;
            if (cmp(a, d) <= 0)
                break;
            for (k = 0; k < sz; k++) {
                t = a[k];
                a[k] = d[k];
                d[k] = t;
            }
        }
    }
}

/* ---- string 加固 ---- */
size_t strnlen(const char *s, size_t max)
{
    size_t n = 0;
    while (n < max && s[n])
        n++;
    return n;
}

char *strpbrk(const char *s, const char *accept)
{
    while (*s) {
        if (strchr(accept, *s))
            return (char *)s;
        s++;
    }
    return NULL;
}

int strcasecmp(const char *a, const char *b)
{
    int ca, cb;
    while (*a) {
        ca = tolower((unsigned char)*a);
        cb = tolower((unsigned char)*b);
        if (ca != cb)
            return ca - cb;
        a++;
        b++;
    }
    cb = tolower((unsigned char)*b);
    return cb ? -cb : 0;
}

int strncasecmp(const char *a, const char *b, size_t n)
{
    int ca, cb;
    while (n-- && *a) {
        ca = tolower((unsigned char)*a);
        cb = tolower((unsigned char)*b);
        if (ca != cb)
            return ca - cb;
        a++;
        b++;
    }
    return 0;
}

char *strtok_r(char *s, const char *delim, char **save)
{
    char *p;

    if (s)
        *save = s;
    if (!*save || !**save)
        return NULL;
    p = *save;
    while (*p && strchr(delim, *p))
        p++;
    if (!*p) {
        *save = p;
        return NULL;
    }
    s = p;
    while (*p && !strchr(delim, *p))
        p++;
    if (*p) {
        *p = 0;
        *save = p + 1;
    } else {
        *save = p;
    }
    return s;
}
