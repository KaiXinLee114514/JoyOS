/* ============================================================================
 *  P2TEST.C — JoyOS 迷你 libc 第二批自检
 *
 *  验证:fread/fwrite/fseek/ftell/feof/ungetc、qsort、strerror、
 *        strnlen/strpbrk/strcasecmp/strncasecmp/strtok_r、isatty/fileno。
 *  用法(shell 里):run P2TEST
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

static int icmp(const void *a, const void *b)
{
    int x = *(const int *)a;
    int y = *(const int *)b;
    return (x > y) - (x < y);
}

int main(void)
{
    int nums[6] = { 42, -7, 0, 99, 13, -58 };
    int i;
    char buf[32];
    size_t n;
    FILE *f;
    char *tok, *save;

    printf("P2TEST: libc 第二批自检\n");

    /* 1. fwrite + fread + fseek + ftell */
    f = fopen("P2TEST.TXT", "w");
    if (!f) { printf("fopen(w) FAIL\n"); return 1; }
    n = fwrite("abcdefghij", 1, 10, f);
    printf("fwrite: %u\n", (unsigned)n);
    fclose(f);

    f = fopen("P2TEST.TXT", "r");
    if (!f) { printf("fopen(r) FAIL\n"); return 1; }
    n = fread(buf, 1, 5, f);
    buf[n] = 0;
    printf("fread(5): %u [%s] ftell=%ld\n", (unsigned)n, buf, ftell(f));

    fseek(f, 2, SEEK_SET);
    n = fread(buf, 1, 4, f);
    buf[n] = 0;
    printf("fseek(2)+fread(4): [%s] %s\n", buf, (strcmp(buf, "cdef") == 0) ? "OK" : "FAIL");

    fseek(f, -3, SEEK_END);
    n = fread(buf, 1, 3, f);
    buf[n] = 0;
    printf("fseek(-3,END): [%s] %s\n", buf, (strcmp(buf, "hij") == 0) ? "OK" : "FAIL");
    printf("feof: %d (期望 1) %s\n", feof(f), feof(f) ? "OK" : "FAIL");

    rewind(f);
    ungetc('X', f);
    n = fread(buf, 1, 1, f);
    buf[n] = 0;
    printf("ungetc/read: [%s] %s\n", buf, (buf[0] == 'a') ? "OK" : "FAIL");
    fclose(f);

    /* 2. qsort */
    qsort(nums, 6, sizeof(int), icmp);
    printf("qsort: ");
    for (i = 0; i < 6; i++)
        printf("%d ", nums[i]);
    printf("%s\n", (nums[0] == -58 && nums[5] == 99) ? "OK" : "FAIL");

    /* 3. string 加固 */
    printf("strnlen: %u  strpbrk: [%s]\n",
           (unsigned)strnlen("hello", 3), strpbrk("abc-def", "-x"));
    printf("strcasecmp: %d  strncasecmp: %d\n",
           strcasecmp("Hello", "hELLO"), strncasecmp("ABCx", "abcy", 3));

    save = NULL;
    tok = strtok_r("alpha,beta,gamma", ",", &save);
    printf("strtok_r: %s", tok);
    while ((tok = strtok_r(NULL, ",", &save)) != NULL)
        printf(" | %s", tok);
    printf("\n");

    /* 4. strerror / isatty / fileno */
    printf("strerror(ENOENT): %s\n", strerror(ENOENT));
    printf("isatty(1): %d  fileno(stdout): %d\n", isatty(1), fileno(stdout));

    printf("P2TEST done.\n");
    return 0;
}
