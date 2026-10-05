/* ============================================================================
 *  CHELLO.C — 用 C 写的 JoyOS 程序(最小的一份)
 *
 *  它证明三件事:gcc 编出来的平铺二进制能跑、迷你 libc 能用、
 *  程序参数和文件接口从 C 里调起来是普通函数调用。
 *
 *  编译(不用管,`make` 会做):
 *      gcc -m32 -std=gnu89 -ffreestanding -fno-pic -nostdlib -Iinclude -c ...
 *      ld  -m elf_i386 -T lib/joyos.ld build/crt0.o ... -o build/CHELLO.BIN
 *
 *  运行: run CHELLO            (跑给你看)
 *        run CHELLO 你好        (参数会被打出来)
 *        run CHELLO README.TXT  (参数当文件名,读出来数数)
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <joyos.h>

static void show_colors(void)
{
    int i;
    const char *names[16] = {
        "black", "blue", "green", "cyan", "red", "magenta", "brown", "grey",
        "dgrey", "lblue", "lgreen", "lcyan", "lred", "lmagenta", "yellow", "white"
    };
    for (i = 1; i < 16; i++) {
        j_color(i);
        printf(" %-8s ", names[i]);
    }
    j_color(JOY_GREY);
    printf("\n");
}

int main(void)
{
    const char *arg = j_arg();
    int cols, rows;

    cols = j_screensize(&rows);

    j_color(JOY_LCYAN);
    printf("HELLO from C!  (compiled by gcc, no libc - just lib/minic.c)\n");

    j_color(JOY_GREY);
    printf("screen: %d cols x %d rows\n", cols, rows);
    printf("printf 试一圈: dec=%d  neg=%d  hex=%x  HEX=%X  char=%c  str=%s  ptr=%p\n",
           42, -7, 0xBEEF, 0xBEEF, 'J', "string", (void *)0x1234);
    printf("sprintf: %s\n", "这个是拼出来的");

    printf("malloc: ");
    {
        char *p = (char *)malloc(1234);
        char *q = (char *)malloc(4096);
        printf("两块都拿到了(%s),还剩 %u 字节堆\n",
               (p && q) ? "p 和 q 非空" : "有一块失败",
               (unsigned)heap_free_bytes());
        free(p);
        free(q);
        printf("free 之后还剩 %u 字节堆\n", (unsigned)heap_free_bytes());
    }

    show_colors();

    if (arg && *arg) {
        printf("参数是: [%s]\n", arg);
        /* 如果参数像个文件名,就把那个文件读进来数数(用迷你 stdio) */
        {
            FILE *f = fopen(arg, "r");
            if (f) {
                char line[256];
                int lines = 0, chars = 0;
                while (fgets(line, sizeof(line), f)) {
                    lines++;
                    chars += (int)strlen(line);
                }
                fclose(f);
                printf("打开 %s 成功:%d 行,%d 字节\n", arg, lines, chars);
            } else {
                printf("打不开 %s(当文件名试了一下)\n", arg);
            }
        }
    } else {
        printf("试试: run CHELLO README.TXT   (参数当文件名读)\n");
    }

    j_color(JOY_LGREEN);
    printf("C 程序跑完了,ret 回 shell。\n");
    return 0;
}
