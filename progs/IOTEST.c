/* 文件 I/O 自检:多簇(>1KB)写入保真测试 */
#include <stdio.h>
#include <string.h>

static unsigned char a[2000], b[2000];

int main(void)
{
    int i, r, bad = 0;
    FILE *f;

    for (i = 0; i < 2000; i++) a[i] = (unsigned char)(i * 7 + 3);

    f = fopen("BIG.BIN", "wb");
    if (!f) { printf("open fail\n"); return 1; }
    r = (int)fwrite(a, 1, 2000, f);
    printf("fwrite=%d\n", r);
    fclose(f);

    f = fopen("BIG.BIN", "rb");
    if (!f) { printf("reopen fail\n"); return 1; }
    memset(b, 0, 2000);
    r = (int)fread(b, 1, 2000, f);
    printf("fread=%d\n", r);
    fclose(f);

    for (i = 0; i < 2000; i++)
        if (b[i] != a[i]) { bad++; if (bad <= 4) printf("mismatch@%d %02x!=%02x\n", i, b[i], a[i]); }
    printf("mismatch=%d\n", bad);
    return 0;
}
