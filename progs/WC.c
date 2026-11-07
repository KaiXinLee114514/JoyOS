/* ============================================================================
 *  WC.C — 管道小工具:数行数/词数/字节数
 *  用法:  cat DOCS/README.TXT | run WC
 *  它从 int 0x30 功能 17(j_pipe_read)读管道输入,和 Unix 的 wc 一个用法。
 * ==========================================================================*/
#include <stdio.h>
#include <kkernel.h>

int main(void)
{
    static char buf[512];
    int n, i, got;
    int lines = 0, words = 0, bytes = 0, inword = 0;

    got = 0;
    for (;;) {
        n = j_pipe_read(buf, (int)sizeof buf);
        if (n <= 0)
            break;
        got = 1;
        bytes += n;
        for (i = 0; i < n; i++) {
            char c = buf[i];
            if (c == '\n')
                lines++;
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
                inword = 0;
            else if (!inword) {
                inword = 1;
                words++;
            }
        }
    }
    if (!got) {
        j_print("WC: no input on stdin (try: cat DOCS/README.TXT | run WC)\n");
        return 1;
    }
    printf("%d lines %d words %d bytes\n", lines, words, bytes);
    return 0;
}
