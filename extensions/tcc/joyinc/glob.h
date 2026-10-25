#ifndef _GLOB_H
#define _GLOB_H
#include <stddef.h>
typedef struct {
    size_t gl_pathc;
    char **gl_pathv;
    size_t gl_offs;
} glob_t;
#define GLOB_MARK 1
#define GLOB_NOSORT 2
#define GLOB_NOCHECK 4
#define GLOB_ERR 8
int glob(const char *pat, int flags, int (*errfunc)(const char *, int), glob_t *pglob);
void globfree(glob_t *pglob);
#endif
