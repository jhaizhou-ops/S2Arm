#include "native.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/prctl.h>

static int deny_stat;
int __real_open(const char *, int, ...);
int __wrap_open(const char *name, int flags, ...) {
    if (deny_stat && !strcmp(name, "/proc/self/stat")) { errno = EACCES; return -1; }
    return __real_open(name, flags);
}
int main(int argc, char **argv) {
    (void)argv;
    if (argc > 1) deny_stat = 1;
    if (prctl(PR_SET_NAME, "s2a ) space )", 0, 0, 0)) return 1;
    usleep(80000);
    s2a_boot_mark("test-first");
    usleep(60000);
    s2a_boot_mark("test-second");
    return 0;
}
