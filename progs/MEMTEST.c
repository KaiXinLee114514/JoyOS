/* memtest: 一路 malloc 16KB 块,看堆到底有多大(窗口布局的现场证据) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
    void *ptrs[64];
    int n = 0, total = 0;
    while (n < 64) {
        void *p = malloc(16384);
        if (!p)
            break;
        memset(p, 0xAA, 1024);   /* 真写一下,确保页补进来 */
        ptrs[n++] = p;
        total += 16384;
    }
    printf("memtest: %d KB allocated (%d blocks), first fail at %d KB\n",
           total / 1024, n, (total + 16384) / 1024);
    return 0;
}
