/* ============================================================================
 *  UPPER.C — 管道小工具:把输入里的 a-z 转成大写
 *  用法:  cat DOCS/README.TXT | run UPPER
 * ==========================================================================*/
#include <kkernel.h>

int main(void)
{
    static char buf[512];
    int n, i, got;

    got = 0;
    for (;;) {
        n = j_pipe_read(buf, (int)sizeof buf - 1);
        if (n <= 0)
            break;
        got = 1;
        for (i = 0; i < n; i++)
            if (buf[i] >= 'a' && buf[i] <= 'z')
                buf[i] = (char)(buf[i] - 32);
        buf[n] = 0;
        j_print(buf);
    }
    if (!got) {
        j_print("UPPER: no input on stdin (try: cat DOCS/README.TXT | run UPPER)\n");
        return 1;
    }
    return 0;
}
