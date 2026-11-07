/* ============================================================================
 *  HEAD.C — 管道小工具:只打印输入的前 N 行(默认 5 行)
 *  用法:  cat DOCS/README.TXT | run HEAD 3
 * ==========================================================================*/
#include <kkernel.h>

static int parse_int(const char *s)
{
    int v = 0;
    while (*s >= '0' && *s <= '9') {
        v = v * 10 + (*s - '0');
        s++;
    }
    return v;
}

int main(void)
{
    static char line[256];
    static char chunk[128];
    const char *arg;
    int want, ll, n, i, got, printed, stop;

    arg = j_arg();
    want = 5;
    if (arg && arg[0] >= '0' && arg[0] <= '9')
        want = parse_int(arg);
    if (want <= 0)
        want = 5;
    got = 0;
    printed = 0;
    stop = 0;
    ll = 0;
    while (!stop) {
        n = j_pipe_read(chunk, (int)sizeof chunk);
        if (n <= 0)
            break;
        got = 1;
        for (i = 0; i < n && !stop; i++) {
            char c = chunk[i];
            if (c == '\n') {
                line[ll] = 0;
                j_print(line);
                j_print("\n");
                ll = 0;
                printed++;
                if (printed >= want)
                    stop = 1;
            } else if (ll < (int)sizeof line - 1) {
                line[ll++] = c;
            }
        }
    }
    if (!got) {
        j_print("HEAD: no input on stdin (try: cat DOCS/README.TXT | run HEAD 3)\n");
        return 1;
    }
    return 0;
}
