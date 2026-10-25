/* ============================================================================
 *  FPU.C — x87 浮点单元自检
 *
 *  验证:kernel/fpu.asm 的初始化(CR0.NE=1、fninit、控制字) +
 *        minic 的 %f 浮点格式化。
 *  用法(shell 里):run FPU
 * ==========================================================================*/
#include <stdio.h>
#include <string.h>

int main(void)
{
    double a = 3.14159265;
    double b = 2.5;
    float  f = 1.25f;

    printf("FPU test: x87 + printf %%f\n");
    printf("a = %f  b = %f\n", a, b);
    printf("a * b = %f\n", a * b);
    printf("a / b = %.4f\n", a / b);
    printf("1.0 / 3.0 = %f\n", 1.0 / 3.0);
    printf("float 1.25 * 2 = %f\n", (double)(f * 2.0f));
    printf("float 1.25 * 2 via double = %f\n", (double)f * 2.0);
    printf("neg -1.5 * 2 = %f\n", -1.5 * 2.0);
    printf("int part of 2.75 = %d\n", (int)2.75);
    printf("width: [%10.2f] [%-10.2f] [%08.3f]\n", 3.14159, 3.14159, 3.14159);
    {
        char wbuf[64];
        int n = sprintf(wbuf, "[%10.2f]", 3.14159);
        printf("width check: sprintf len=%d strlen=%d value=%s\n", n, (int)strlen(wbuf), wbuf);
    }
    if (3.0 > 2.5 && 1.5 != 2.0)
        printf("compare: OK\n");
    printf("done.\n");
    return 0;
}
