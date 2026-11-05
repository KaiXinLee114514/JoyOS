/* 最小的 KKernel 程序:只有 C,没有一行汇编 */
#include <stdio.h>
#include <kkernel.h>

int main(void)
{
    int cols, rows, i;

    j_color(KK_LCYAN);
    printf("大家好,我是用纯 C 写的 KKernel 程序!\n");
    j_color(KK_GREY);

    cols = j_screensize(&rows);
    printf("屏幕是 %d 列 × %d 行\n", cols, rows);

    for (i = 1; i <= 5; i++)
        printf("  %d 的平方是 %d\n", i, i * i);

    printf("参数(argv): %s\n", j_arg());
    return 0;
}
