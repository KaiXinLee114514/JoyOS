/* ============================================================================
 *  GREP.C — 管道小工具:打印包含 pattern 的行(简单子串匹配)
 *  用法:  ls BIN | run GREP HELLO
 *         cat DOCS/README.TXT | run GREP the
 *  pattern 从 run 的参数(j_arg)取第一个词。
 * ==========================================================================*/
#include <stdio.h>
#include <string.h>
#include <kkernel.h>

int main(void)
{
    static char line[256];
    static char chunk[128];
    char pat[64];
    const char *arg;
    int pi, ll, n, i, got, found;

    arg = j_arg();
    pi = 0;
    if (arg) {
        while (arg[pi] && arg[pi] != ' ' && pi < 63) {
            pat[pi] = arg[pi];
            pi++;
        }
    }
    pat[pi] = 0;
    if (pi == 0) {
        j_print("usage: <producer> | run GREP <pattern>\n");
        return 1;
    }
    got = 0;
    found = 0;
    ll = 0;
    for (;;) {
        n = j_pipe_read(chunk, (int)sizeof chunk);
        if (n <= 0)
            break;
        got = 1;
        for (i = 0; i < n; i++) {
            char c = chunk[i];
            if (c == '\n') {
                line[ll] = 0;
                if (strstr(line, pat)) {
                    j_print(line);
                    j_print("\n");
                    found = 1;
                }
                ll = 0;
            } else if (ll < (int)sizeof line - 1) {
                line[ll++] = c;
            }
        }
    }
    if (ll > 0) {
        line[ll] = 0;
        if (strstr(line, pat)) {
            j_print(line);
            j_print("\n");
            found = 1;
        }
    }
    if (!got) {
        j_print("GREP: no input on stdin (try: ls BIN | run GREP HELLO)\n");
        return 1;
    }
    return found ? 0 : 1;
}
