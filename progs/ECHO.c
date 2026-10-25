/* ============================================================================
 *  ECHO.C — 调试用:把每个按键的 ASCII 码打出来
 *  用法:run ECHO   按 q 退出
 * ==========================================================================*/
#include <stdio.h>
#include <joyos.h>

int main(void)
{
    int c, n = 0;

    j_print("ECHO test: press keys (q to quit)\n");
    for (;;) {
        c = j_getchar();
        if (c == 'q')
            break;
        printf("[%d:0x%02x]", c, c);
        n++;
        if (n % 5 == 0)
            printf("\n");
    }
    j_print("\nECHO done.\n");
    return 0;
}
