#ifndef _SETJMP_H
#define _SETJMP_H
/* JoyOS: 复用 mini libc 的 mc_setjmp/mc_longjmp (crt0.asm 实现) */
#include "minic.h"
#define setjmp  mc_setjmp
#define longjmp mc_longjmp
#define _setjmp  mc_setjmp
#define _longjmp mc_longjmp
#endif
