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

    /* ---- /DEV 设备抽象层:虚拟设备不占磁盘,读写在内存里现做 ---- */
    {
        char t[64];
        memset(t, 0, sizeof t);
        f = fopen("DEV/RTC", "rb");
        if (!f) { printf("dev/rtc open fail\n"); return 1; }
        r = (int)fread(t, 1, sizeof t - 1, f);
        printf("dev/rtc read=%d [%s]\n", r, t);
        fclose(f);

        f = fopen("DEV/NULL", "wb");
        if (!f) { printf("dev/null open fail\n"); return 1; }
        r = (int)fwrite("discard me", 1, 10, f);
        printf("dev/null write=%d\n", r);
        fclose(f);
    }
    return 0;
}
