/* 最小的 JoyOS 程序:只有 C,没有一行汇编 */
#include <stdio.h>
#include <joyos.h>

int main(void)
{
    int cols, rows, i;

    j_color(JOY_LCYAN);
    printf("大家好,我是用纯 C 写的 JoyOS 程序!\n");
    j_color(JOY_GREY);

    cols = j_screensize(&rows);
    printf("屏幕是 %d 列 × %d 行\n", cols, rows);

    for (i = 1; i <= 5; i++)
        printf("  %d 的平方是 %d\n", i, i * i);

    printf("参数(argv): %s\n", j_arg());
    return 0;
}
