/* ============================================================================
 *  joyos.c — STEVIE 在 JoyOS 上的"机器相关层"
 *
 *  STEVIE(公有领域的 vi 克隆,vim 的前身)把"和机器打交道"的那部分全放在一个
 *  文件里(NT 版是 nt.c,Atari 版是 tos.c,UNIX 版是 unix.c)。这个文件就是
 *  JoyOS 版:屏幕用 int 0x30 的 9/13 号(定位 + 在指定位置画字),键盘用 10 号
 *  (带方向键的键事件),文件用 7/8 号。编辑器核心一行没改。
 *
 *  平台层要提供的东西(stevie.h 里声明的):
 *      windinit / windexit / windgoto(row,col) / wchangescreen
 *      outchar / outstr / flushbuf            画字符(我们按行攒起来一次画)
 *      inchar                                 收一个键(方向键映射成 K_xxx)
 *      beep / delay / sleep / sig             杂项
 *      fopenb / fixname / dochdir             文件与路径
 *      mysystem / doshell / usecmdconsole / useviconsole / setviconsoletitle
 *
 *  屏幕模型:STEVIE 自己维护两块字符缓冲(Realscreen / Nextscreen),有变化才
 *  调 outchar 重画那几格 —— 所以这里"攒一行再一次画出去"很划算:往 VBE 帧缓冲
 *  写一个像素在 QEMU 里就是一次 MMIO,能少画就少画。
 * ==========================================================================*/
#include "stevie.h"
#include <joyos.h>

/* ---- 当前绘制位置(字符格)和攒着的这一小段 ---- */
static int  p_row, p_col;               /* 下一次 outchar 画在哪 */
static int  saved_row, saved_col;       /* SaveCursor/RestoreCursor */
static char linebuf[512];
static int  linelen, linecol;           /* 攒的内容 + 它的起始列 */

static void flush_line(void)
{
    if (linelen <= 0)
        return;
    linebuf[linelen] = '\0';
    j_puts_at(linebuf, p_row, linecol, Columns + 8);
    linelen = 0;
    linecol = p_col;
}

/* ---------------------------------------------------------------------------
 *  init / exit
 * -------------------------------------------------------------------------*/
void windinit(void)
{
    int rows = 0;
    Columns = j_screensize(&rows);
    Rows = rows;
    if (Columns < 20)
        Columns = 80;
    if (Rows < 5)
        Rows = 25;
    /* 留一行给底部的 : 命令行(vi 的经典布局) */
    Rows--;
    j_clrscr();
    p_row = p_col = 0;
    linelen = 0;
    linecol = 0;
}

void windexit(void)
{
    flush_line();
    j_clrscr();
    j_print("vi closed.\n");
}

void wchangescreen(void)
{
    /* 我们没有"翻页/刷新硬件"的事要做 */
}

/* ---------------------------------------------------------------------------
 *  画字符
 * -------------------------------------------------------------------------*/
void windgoto(int row, int col)
{
    flush_line();
    p_row = row;
    p_col = col;
    linecol = col;
}

void outchar(int c)
{
    unsigned char ch = (unsigned char)c;

    if (ch == '\n') {                   /* 换行:flush 之后下一行 */
        flush_line();
        p_row++;
        p_col = 0;
        linecol = 0;
        return;
    }
    if (ch == '\r') {
        flush_line();
        p_col = 0;
        linecol = 0;
        return;
    }
    if (ch < 32)                        /* 其它控制字符(响铃之类)不画 */
        return;
    if (linelen == 0)
        linecol = p_col;
    if (linelen >= (int)sizeof(linebuf) - 2) {
        flush_line();
        linecol = p_col;
    }
    linebuf[linelen++] = (char)ch;
    p_col++;
    if (p_col >= Columns) {             /* 到右边界:自动换行 */
        flush_line();
        p_row++;
        p_col = 0;
        linecol = 0;
    }
}

void outstr(char *s)
{
    while (s && *s)
        outchar(*s++);
}

void flushbuf(void)
{
    flush_line();
}

/* ---------------------------------------------------------------------------
 *  键盘
 *
 *  STEVIE 要求 inchar() 直接返回"编辑器认识的键值":普通字符就是 ASCII,
 *  特殊键用 keymap.h 里的 K_xxx(0x80 起)。JoyOS 的键事件接口正好给的是
 *  ASCII 或 0x100+编号,所以这里就是一张小映射表。
 * -------------------------------------------------------------------------*/
int inchar(void)
{
    int k = j_getkey();

    switch (k) {
    case JOY_KEY_HOME:  return K_HOME;
    case JOY_KEY_END:   return K_END;
    case JOY_KEY_DEL:   return K_DELETE;
    case JOY_KEY_UP:    return K_UARROW;
    case JOY_KEY_DOWN:  return K_DARROW;
    case JOY_KEY_LEFT:  return K_LARROW;
    case JOY_KEY_RIGHT: return K_RARROW;
    case JOY_KEY_PGUP:  return K_PAGEUP;
    case JOY_KEY_PGDN:  return K_PAGEDOWN;
    default:            return k & 0xFF;
    }
}

/* ---------------------------------------------------------------------------
 *  杂项:没有的东西就老实做不了,但别让编辑器崩
 * -------------------------------------------------------------------------*/
void beep(void)
{
    /* 没有蜂鸣器(要真响得去编程 PIT 的通道 2) */
}

void delay(int n)
{
    volatile int i;
    while (n-- > 0)
        for (i = 0; i < 2000; i++)
            ;
}

void sleep(int n)
{
    delay(n * 50);
}

void sig(int n)
{
    (void)n;                            /* 没有信号 */
}

void setviconsoletitle(void)
{
}

void usecmdconsole(void)
{
}

void useviconsole(void)
{
}

void dochdir(char *dir)
{
    (void)dir;                          /* 没有目录(只有根目录) */
}

char *StrLength(char *s)
{
    return s + strlen(s);               /* NT 版用它算字符串末尾 */
}

/* ---------------------------------------------------------------------------
 *  NT 版专有的几个小函数(核心代码调用了它们,所以 JoyOS 版也得有)
 * -------------------------------------------------------------------------*/
void EraseLine(void)
{
    /* 把当前这一行擦干净(NT 版是调 Win32 的 FillConsoleOutputCharacter) */
    int i;
    flush_line();
    j_setcursor(p_row, 0);
    for (i = 0; i < Columns; i++)
        outchar(' ');
    flush_line();
    p_col = 0;
    linecol = 0;
}

void ClearDisplay(void)
{
    flush_line();
    j_clrscr();
    p_row = p_col = 0;
    linelen = 0;
    linecol = 0;
}

void VisibleCursor(void)
{
    /* 光标要显示出来 —— JoyOS 的定位接口只定位,不画块状光标;
       文字模式下有硬件光标,图形模式下暂时没有(先这样,能编辑就行) */
}

void InvisibleCursor(void)
{
    /* 重画屏幕时先把光标藏起来;我们不做闪烁光标,所以是空操作 */
}

void CursorSize(int n)
{
    (void)n;                            /* 光标大小:硬件才有的概念 */
}

void SaveCursor(void)
{
    flush_line();
    saved_row = p_row;
    saved_col = p_col;
}

void RestoreCursor(void)
{
    flush_line();
    p_row = saved_row;
    p_col = saved_col;
    linecol = p_col;
}

void EraseNLinesAtRow(int n, int row)
{
    int i, j;
    flush_line();
    for (i = 0; i < n; i++) {
        j_setcursor(row + i, 0);
        for (j = 0; j < Columns; j++)
            outchar(' ');
        flush_line();
        p_row = row + i + 1;
        p_col = 0;
        linecol = 0;
    }
}

/*
 * Scroll(t, l, b, r, Row, Col):把矩形区域里的一块内容滚到 Row/Col 去。
 * NT 版靠 Win32 的 ScrollConsoleScreenBuffer,我们没有"读回屏幕"的接口,
 * 所以这里用个偷懒但正确的办法:**把 Realscreen 弄脏**,让 STEVIE 下一次
 * 重画时自己把整屏重画一遍(它本来就是靠 Realscreen/Nextscreen 的差异画的)。
 * 只影响"插入/删除整行"那种少见的操作,代价是全屏重画一次。
 */
void Scroll(int t, int l, int b, int r, int Row, int Col)
{
    (void)t; (void)l; (void)b; (void)r; (void)Row; (void)Col;
    flush_line();
    if (Realscreen)
        memset(Realscreen, 0x01, (size_t)Rows * (size_t)(Columns + 1));
}

void HighlightLine(int row, int col, int len)
{
    /* NT 版反显一行(搜索命中时闪一下)。我们没有反显属性,先空着 */
    (void)row; (void)col; (void)len;
}

void HighlightCheck(void)
{
    /* NT 版用它做"高亮/反显"的收尾;我们只有一个颜色,不用管 */
}

char *EraseNChars(int n)
{
    (void)n;
    return NULL;
}

/* MSVC 的大小写无关比较;命令行 :tag 用得上 */
int _stricmp(const char *a, const char *b)
{
    while (*a && tolower((unsigned char)*a) == tolower((unsigned char)*b)) {
        a++;
        b++;
    }
    return tolower((unsigned char)*a) - tolower((unsigned char)*b);
}

/* _mktemp:给 :!cmd 那种过滤命令生成临时文件名。
   我们没有 shell,也没法建临时文件 —— 给个可预期的名字,失败会在写文件时报出来 */
char *_mktemp(char *templ)
{
    static int counter = 0;
    char num[8];
    int i, j;

    counter++;
    sprintf(num, "%d", counter);
    i = (int)strlen(templ) - 6;         /* 找 "XXXXXX" */
    if (i < 0)
        i = 0;
    for (j = 0; j < 6 && num[j]; j++)
        templ[i + j] = num[j];
    for (; j < 6; j++)
        templ[i + j] = '0';
    return templ;
}

/* ---------------------------------------------------------------------------
 *  文件
 * -------------------------------------------------------------------------*/
FILE *fopenb(char *fname, char *mode)
{
    return fopen(fname, mode);
}

/*
 * fixname(s) —— 把用户给的名字收拾成 FAT 8.3 的样子(大写、基名 8、扩展名 3)。
 *
 * ★ 这里踩过一个坑:NT 版的签名是 fixname(char *s),**一个参数、返回静态缓冲**,
 *   我第一版按"写到调用方给的 buf 里"写了三个参数 —— 编译能过(stevie.h 里是
 *   老式的 char *fixname(); 不检查参数个数),可运行时 foo.c 里那句
 *   fopen(fixname(fname), "w") 传进来的第二个参数是**垃圾**,于是文件名变成空的:
 *   vi 照样"存盘成功",磁盘上却出现一个名字全是空格的目录项(第二次打开还认不出来)。
 *   教训:老代码里的平台函数,先看真实现,别按自己以为的签名写。
 */
char *fixname(char *s)
{
    static char f[128];
    char base[64], ext[16];
    char *p, *dot;
    int i, n;

    if (!s)
        s = "";
    p = s;
    for (i = 0; s[i]; i++)              /* 只取最后一段(我们没有目录) */
        if (s[i] == '/' || s[i] == '\\' || s[i] == ':')
            p = s + i + 1;

    dot = strchr(p, '.');
    if (dot) {
        n = (int)(dot - p);
        if (n > 8)
            n = 8;
        for (i = 0; i < n; i++)
            base[i] = (char)toupper((unsigned char)p[i]);
        base[n] = 0;
        n = (int)strlen(dot + 1);
        if (n > 3)
            n = 3;
        for (i = 0; i < n; i++)
            ext[i] = (char)toupper((unsigned char)dot[1 + i]);
        ext[n] = 0;
        if (n)
            sprintf(f, "%s.%s", base, ext);
        else
            strcpy(f, base);
    } else {
        n = (int)strlen(p);
        if (n > 8)
            n = 8;
        for (i = 0; i < n; i++)
            f[i] = (char)toupper((unsigned char)p[i]);
        f[n] = 0;
    }
    return f;
}

/* STEVIE 用 mysystem/doshell 跑外部命令(:!cmd、:sh)——
   这个系统里没有进程,所以只会打印一句话 */
char *mysystem(char *cmd, int async)
{
    (void)async;
    windexit();
    j_color(JOY_LCYAN);
    j_print("JoyOS has no shell escape (no processes yet): ");
    j_print(cmd ? cmd : "");
    j_print("\npress any key to go back to vi...");
    j_getchar();
    j_clrscr();
    return NULL;
}

void doshell(void)
{
    mysystem(NULL, 0);
}

/* ---------------------------------------------------------------------------
 *  入口:crt0 调的是 main(void),而 stevie 的 main 要 argc/argv。
 *  参数从 int 0x30 的 12 号功能取(`run VI NOTES.TXT [+num] [文件名]`)。
 * -------------------------------------------------------------------------*/
extern int vimain(int argc, char **argv);

#define MAXARGS 8
static char *args[MAXARGS];

int main(void)
{
    const char *arg = j_arg();
    char  buf[128];
    int   argc = 0, i = 0;
    int   inword = 0;

    /* argv[0] 固定是 "vi"(程序名) */
    args[argc++] = "vi";

    while (arg && arg[i] && argc < MAXARGS) {
        if (arg[i] == ' ' || arg[i] == '\t') {
            buf[i] = '\0';
            inword = 0;
            i++;
            continue;
        }
        if (!inword) {
            int j = 0;
            inword = 1;
            while (arg[i] && arg[i] != ' ' && arg[i] != '\t' && j < 120)
                buf[j++] = arg[i++];
            buf[j] = '\0';
            args[argc] = (char *)malloc((size_t)j + 1);
            if (!args[argc])
                break;
            strcpy(args[argc], buf);
            argc++;
            continue;
        }
        i++;
    }

    return vimain(argc, args);
}
