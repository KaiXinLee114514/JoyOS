#ifndef _SYS_MMAN_H
#define _SYS_MMAN_H
#define PROT_NONE  0
#define PROT_READ  1
#define PROT_WRITE 2
#define PROT_EXEC  4
#define MAP_PRIVATE   2
#define MAP_ANONYMOUS 0x20
#define MAP_FIXED     0x10
#define MAP_FAILED ((void *)-1)
void *mmap(void *addr, unsigned int len, int prot, int flags, int fd, long off);
int munmap(void *addr, unsigned int len);
int mprotect(void *addr, unsigned int len, int prot);
#endif
