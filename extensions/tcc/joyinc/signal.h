#ifndef _SIGNAL_H
#define _SIGNAL_H
typedef void (*sighandler_t)(int);
#define SIGINT   2
#define SIGSEGV  11
#define SIGABRT  6
#define SIGFPE   8
sighandler_t signal(int sig, sighandler_t handler);
int raise(int sig);
void abort(void);
#endif
