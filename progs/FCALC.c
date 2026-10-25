/* ============================================================================
 *  FCALC.C — JoyOS 浮点计算器(x87)
 *
 *  和定点版 CALC.asm 同界面、同操作,但内部用 double + x87 真浮点:
 *      加 减 乘 除、小数点、平方(s)、清零(c)、退格、q 退出
 *  结果按 6 位小数打印,自动去掉尾零(50.000000 → 50)。
 *
 *  依赖:kernel/fpu.asm 的 x87 初始化 + minic 的 %f 格式化。
 *  用法(shell 里):run FCALC
 * ==========================================================================*/
#include <stdio.h>
#include <string.h>
#include <joyos.h>

#define ROW_TITLE 0
#define ROW_EXPR  2
#define ROW_VALUE 4
#define ROW_NOTE  6
#define ROW_HELP  9
#define MAX_INPUT 32

static char  input[MAX_INPUT + 1];      /* 当前输入(或上次结果)字符串 */
static int   ilen;
static double acc;                      /* 左操作数 */
static char  op;                        /* 待执行的运算符(0 = 没有) */
static int   have_acc;                  /* acc 是否有效 */

/* ---- 把字符串解析成 double(支持负号和小数点;不依赖 strtod) ---------- */
static double parse_num(const char *s)
{
    double v = 0.0, frac = 0.1;
    int neg = 0, dot = 0;

    if (*s == '-') { neg = 1; s++; }
    while (*s) {
        if (*s == '.') {
            dot = 1;
        } else if (*s >= '0' && *s <= '9') {
            if (!dot) {
                v = v * 10.0 + (double)(*s - '0');
            } else {
                v += (double)(*s - '0') * frac;
                frac *= 0.1;
            }
        }
        s++;
    }
    return neg ? -v : v;
}

/* ---- double → 字符串:6 位小数,去掉尾零和小数点 ---------------------- */
static void fmt_num(char *buf, double v)
{
    int n;

    if (v > 1.0e308 || v < -1.0e308) {   /* 溢出(不含 NaN) */
        strcpy(buf, "overflow");
        return;
    }
    sprintf(buf, "%.6f", v);
    n = (int)strlen(buf);
    while (n > 0 && buf[n - 1] == '0')
        n--;
    if (n > 0 && buf[n - 1] == '.')
        n--;
    if (n == 0) {
        buf[0] = '0';
        n = 1;
    }
    buf[n] = '\0';
}

/* ---- 重画界面 -------------------------------------------------------- */
static void redraw(const char *expr, const char *value, const char *note)
{
    j_puts_at("JoyOS float calculator  (x87 double, 6 decimals)", ROW_TITLE, 0, 80);
    j_puts_at("expr:", ROW_EXPR, 0, 80);
    j_puts_at(expr, ROW_EXPR, 6, 80);
    j_puts_at("   =  ", ROW_VALUE, 0, 80);
    j_puts_at(value, ROW_VALUE, 6, 80);
    if (note && *note)
        j_puts_at(note, ROW_NOTE, 0, 80);
    else
        j_puts_at("                                        ", ROW_NOTE, 0, 80);
    j_puts_at("0-9 . + - * / =    s square    c clear    backspace    q quit",
              ROW_HELP, 0, 80);
}

/* ---- 清空输入(保留 acc/op 由调用者决定) ------------------------------ */
static void clear_input(void)
{
    int i;
    ilen = 0;
    for (i = 0; i <= MAX_INPUT; i++)
        input[i] = '\0';
}

int main(void)
{
    char expr[96];
    char value[64];
    char note[64];
    int  e;

    /* 初始状态 */
    clear_input();
    acc = 0.0;
    op = 0;
    have_acc = 0;
    note[0] = '\0';

    j_clrscr();
    redraw("", "0", "");

    for (;;) {
        int c = j_getchar();
        int done = 0;

        if (c == 'q' || c == 'Q') {
            j_clrscr();
            j_print("calculator closed.\n");
            return 0;
        }

        if (c >= '0' && c <= '9') {
            if (ilen < MAX_INPUT) {
                input[ilen++] = (char)c;
                input[ilen] = '\0';
            }
        } else if (c == '.') {
            if (ilen < MAX_INPUT && !strchr(input, '.')) {
                input[ilen++] = '.';
                input[ilen] = '\0';
            }
        } else if (c == 8 || c == 127) {            /* 退格 */
            if (ilen > 0)
                ilen--;
        } else if (c == '+' || c == '-' || c == '*' || c == '/') {
            double v;
            if (ilen == 0) {                        /* 没输入:直接用上次结果 */
                v = acc;
            } else {
                v = parse_num(input);
            }
            /* 先算掉前面挂着的运算 */
            if (have_acc && op) {
                if (op == '+') acc = acc + v;
                else if (op == '-') acc = acc - v;
                else if (op == '*') acc = acc * v;
                else if (op == '/') {
                    if (v == 0.0) {
                        strcpy(note, "cannot divide by zero");
                        clear_input();
                        goto show;
                    }
                    acc = acc / v;
                }
            } else {
                acc = v;
            }
            op = (char)c;
            have_acc = 1;
            clear_input();
            note[0] = '\0';
        } else if (c == '=') {
            double v = (ilen == 0) ? acc : parse_num(input);
            double r;
            if (!have_acc) {
                r = v;
            } else if (op == '+') {
                r = acc + v;
            } else if (op == '-') {
                r = acc - v;
            } else if (op == '*') {
                r = acc * v;
            } else if (op == '/') {
                if (v == 0.0) {
                    strcpy(note, "cannot divide by zero");
                    clear_input();
                    goto show;
                }
                r = acc / v;
            } else {
                r = v;
            }
            acc = r;
            have_acc = 1;
            op = 0;
            fmt_num(value, r);
            if (strcmp(value, "overflow") == 0) {
                strcpy(note, "overflow! value too large");
            } else {
                note[0] = '\0';
            }
            strcpy(input, value);
            ilen = (int)strlen(input);
            done = 1;
        } else if (c == 's' || c == 'S') {
            double v = (ilen == 0) ? acc : parse_num(input);
            double r = v * v;
            acc = r;
            have_acc = 1;
            op = 0;
            fmt_num(value, r);
            strcpy(note, " [sq]");
            strcpy(input, value);
            ilen = (int)strlen(input);
            done = 1;
        } else if (c == 'c' || c == 'C') {
            clear_input();
            acc = 0.0;
            op = 0;
            have_acc = 0;
            note[0] = '\0';
        }

show:
        /* 组装表达式行 */
        e = 0;
        if (have_acc && op && ilen >= 0) {
            char tmp[64];
            fmt_num(tmp, acc);
            e += sprintf(expr, "%s %c %s", tmp, op, input);
        } else {
            sprintf(expr, "%s", input);
        }
        if (done) {
            fmt_num(value, acc);
            j_clrscr();
            redraw(expr, value, note);
        } else {
            j_clrscr();
            redraw(expr, input[0] ? input : "0", note);
        }
    }
}
