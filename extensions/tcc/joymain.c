/* JoyOS 下的 TCC 入口:从内核参数页构造 argc/argv,再交给 TCC 真正的 main */
#include <joyos.h>
#include <stdlib.h>
#include <string.h>

extern int tcc_real_main(int argc, char **argv);

int main(void)
{
    static char buf[1024];
    static char *argv[64];
    const char *src;
    char *p;
    int argc = 0;

    argv[argc++] = "TCC.BIN";
    src = j_arg();
    if (src && *src) {
        strncpy(buf, src, sizeof(buf) - 1);
        buf[sizeof(buf) - 1] = '\0';
        p = buf;
        while (*p && argc < 63) {
            while (*p == ' ')
                p++;
            if (!*p)
                break;
            argv[argc++] = p;
            while (*p && *p != ' ')
                p++;
            if (*p)
                *p++ = '\0';
        }
    }
    argv[argc] = NULL;
    return tcc_real_main(argc, argv);
}
