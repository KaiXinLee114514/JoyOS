/* ============================================================================
 *  RNGTEST.C — JoyOS 迷你 libc 扩展自检
 *
 *  验证新加的:rand/srand、time/clock、open/read/write/lseek、strtol。
 *  用法(shell 里):run RNGTEST
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>

int main(void)
{
    int i, fd, n;
    char buf[64];
    unsigned int a, b;

    printf("RNGTEST: libc 扩展自检\n");

    /* 1. rand 不播种:自动用 TSC 播 */
    printf("rand(): ");
    for (i = 0; i < 5; i++)
        printf("%u ", rand() % 1000);
    printf("\n");

    /* 2. srand 固定种子 → 序列可复现 */
    srand(12345);
    a = rand();
    srand(12345);
    b = rand();
    printf("srand(12345): %u / %u %s\n", a, b, (a == b) ? "OK" : "FAIL");

    /* 3. 计时器 */
    printf("time(): %ld  clock(): %u\n", (long)time(NULL), (unsigned)clock());

    /* 4. open + write + close */
    fd = open("RNGTEST.TXT", O_WRONLY | O_CREAT | O_TRUNC);
    if (fd < 0) {
        printf("open(w) FAIL errno=%d\n", errno);
        return 1;
    }
    n = write(fd, "hello posix\n", 12);
    printf("write: %d\n", n);
    close(fd);

    /* 5. open + read */
    fd = open("RNGTEST.TXT", O_RDONLY);
    if (fd < 0) {
        printf("open(r) FAIL errno=%d\n", errno);
        return 1;
    }
    memset(buf, 0, sizeof(buf));
    n = read(fd, buf, sizeof(buf) - 1);
    printf("read: %d [%s]\n", n, buf);
    close(fd);

    /* 6. lseek */
    fd = open("RNGTEST.TXT", O_RDONLY);
    lseek(fd, 6, SEEK_SET);
    memset(buf, 0, sizeof(buf));
    read(fd, buf, 5);
    printf("lseek(6)+read(5): [%s] %s\n", buf, (strcmp(buf, "posix") == 0) ? "OK" : "FAIL");
    close(fd);

    /* 7. strtol */
    printf("strtol(0x1F): %ld  strtol(42): %ld\n",
           strtol("0x1F", NULL, 0), strtol("42", NULL, 0));

    printf("RNGTEST done.\n");
    return 0;
}
