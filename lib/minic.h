/* ============================================================================
 *  JoyOS — 迷你 libc 的声明(minic.c 的头)
 *
 *  用法:程序里照常 `#include <stdio.h>`,而 include/ 下那几个头文件都是
 *  薄薄一层 —— 内容就是 `#include "minic.h"`。编译时 -Iinclude 排在系统目录前面,
 *  于是拿到的是我们这份,而不是 glibc 的(不然 glibc 的头会把我们拖进它的世界)。
 * ==========================================================================*/
#ifndef MINIC_H
#define MINIC_H

#include "joyos.h"                          /* 类型 + int 0x30 包装 */
#include <stdarg.h>                         /* 编译器自带的,不用我们写 */

/* ---- 错误码(errno 只用来给调用方一个"为什么失败")---- */
#define EPERM   1
#define ENOENT  2
#define EIO     5
#define ENOMEM 12
#define EACCES 13
#define EEXIST 17
#define EINVAL 22
extern int errno;

/* ---- stdio ---- */
#define EOF     (-1)
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

#define MC_READ_MAX   65536                 /* 读文件时一次性读这么多 */
#define MC_WRITE_MAX  65536                 /* 写文件时最多攒这么多 */
#define MC_PRINT_BUF  1024                  /* printf 一行最长这么点 */

typedef struct {
    char *buf;                              /* 文件内容(读进来/攒着等写) */
    int len;                                /* 有效字节数 */
    int pos;                                /* 读到哪了 */
    int mode;                               /* 1 = 读,2 = 写 */
    const char *name;                       /* 写回时用的文件名 */
    int fd;                                 /* 留给以后(0/1 表示控制台) */
} FILE;

extern FILE *stdout;
extern FILE *stderr;

FILE *fopen(const char *name, const char *mode);
int   fclose(FILE *f);
int   fflush(FILE *f);
int   fgetc(FILE *f);
int   getc(FILE *f);
int   fputc(int c, FILE *f);
int   putc(int c, FILE *f);
char *fgets(char *s, int n, FILE *f);
int   fputs(const char *s, FILE *f);
int   putchar(int c);
int   puts(const char *s);
size_t fread(void *ptr, size_t size, size_t nmemb, FILE *f);
size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *f);
int    fseek(FILE *f, long off, int whence);
long   ftell(FILE *f);
void   rewind(FILE *f);
int    feof(FILE *f);
int    ferror(FILE *f);
int    fileno(FILE *f);
int    ungetc(int c, FILE *f);
int   printf(const char *fmt, ...);
int   fprintf(FILE *f, const char *fmt, ...);
int   vfprintf(FILE *f, const char *fmt, va_list ap);
int   sprintf(char *buf, const char *fmt, ...);
int   snprintf(char *buf, size_t n, const char *fmt, ...);
int   vsprintf(char *buf, const char *fmt, va_list ap);
int   mc_vformat(char *buf, int max, const char *fmt, va_list ap);
void  perror(const char *s);
int   remove(const char *name);
int   rename(const char *oldname, const char *newname);
int   access(const char *name, int mode);
int   mc_console_write(const char *s, int n);

/* ---- string ---- */
size_t strlen(const char *s);
char  *strcpy(char *d, const char *s);
char  *strncpy(char *d, const char *s, size_t n);
char  *strcat(char *d, const char *s);
char  *strncat(char *d, const char *s, size_t n);
int    strcmp(const char *a, const char *b);
int    strncmp(const char *a, const char *b, size_t n);
char  *strchr(const char *s, int c);
char  *strrchr(const char *s, int c);
char  *strstr(const char *hay, const char *needle);
char  *strtok(char *s, const char *delim);
char  *strdup(const char *s);
size_t strspn(const char *s, const char *accept);
size_t strnlen(const char *s, size_t max);
char  *strpbrk(const char *s, const char *accept);
int    strcasecmp(const char *a, const char *b);
int    strncasecmp(const char *a, const char *b, size_t n);
char  *strtok_r(char *s, const char *delim, char **save);
char  *index(const char *s, int c);
char  *rindex(const char *s, int c);
size_t strcspn(const char *s, const char *reject);
void  *memcpy(void *d, const void *s, size_t n);
void  *memmove(void *d, const void *s, size_t n);
void  *memset(void *d, int c, size_t n);
int    memcmp(const void *a, const void *b, size_t n);
void  *memchr(const void *s, int c, size_t n);

/* ---- ctype ---- */
int isalpha(int c);
int isdigit(int c);
int isalnum(int c);
int isspace(int c);
int isupper(int c);
int islower(int c);
int ispunct(int c);
int isprint(int c);
int iscntrl(int c);
int isxdigit(int c);
int isascii(int c);
int toupper(int c);
int tolower(int c);

/* ---- stdlib ---- */
void  *malloc(size_t n);
void  *calloc(size_t n, size_t sz);
void  *realloc(void *p, size_t n);
void   free(void *p);
size_t heap_free_bytes(void);
int    atoi(const char *s);
long   atol(const char *s);
long   strtol(const char *s, char **end, int base);
int    abs(int v);
long   labs(long v);
void   exit(int code);
char  *getenv(const char *name);
int    system(const char *cmd);

/* 随机数:xorshift32,种子来自 TSC 抖动;不播种时首次调用自动播 */
#define RAND_MAX 0x7FFFFFFF
unsigned int rand(void);
void         srand(unsigned int seed);
void         qsort(void *base, size_t n, size_t sz,
                   int (*cmp)(const void *, const void *));

/* ---- time(计时器)---- */
typedef long time_t;
typedef unsigned int clock_t;
#define CLOCKS_PER_SEC 1000000u             /* TSC 当 tick,绝对值只作参考 */
time_t  time(time_t *t);
clock_t clock(void);

/* ---- unistd(POSIX 子集)----
 * 文件模型沿用 minic.c 的"整文件缓冲":open 时读进内存/攒着,c l o s e 时写回。
 * stdin/stdout/stderr 是 0/1/2,文件 fd 从 3 起。 */
#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR   2
#define O_CREAT  0x40
#define O_TRUNC  0x200

int  open(const char *name, int flags, ...);
int  close(int fd);
int  read(int fd, void *buf, int n);
int  write(int fd, const void *buf, int n);
int  lseek(int fd, int off, int whence);
int  unlink(const char *name);
int  getpid(void);
unsigned int sleep(unsigned int seconds);
int  isatty(int fd);
char *strerror(int err);

/* ---- 退出跳板(crt0.asm 里的汇编,exit() 靠它回到 shell)---- */
typedef int jmp_buf[6];
extern jmp_buf mc_exitbuf;
extern int mc_exit_code;
int  mc_setjmp(jmp_buf b);
void mc_longjmp(jmp_buf b, int val);

#endif /* MINIC_H */
