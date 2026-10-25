/* JoyOS TCC 移植配置(手写) */
#define TCC_VERSION "0.9.28rc"

#define CC_NAME CC_gcc
#define GCC_MAJOR 14
#define GCC_MINOR 2

#define TCC_TARGET_I386 1

#define CONFIG_TCC_STATIC 1
#define CONFIG_TCC_SEMLOCK 0
#define CONFIG_TCC_BCHECK 0
#define CONFIG_TCC_BACKTRACE 0

#define CONFIG_TCC_SYSINCLUDEPATHS "/include"
#define CONFIG_TCC_LIBPATHS "/lib"
#define CONFIG_TCC_CRTPREFIX "/lib"
#define CONFIG_TCC_ELFINTERP "/lib/ld-tcc.so.1"
#define CONFIG_TCCDIR "/lib/tcc"
#define CONFIG_TCC_PREDEFS 1
