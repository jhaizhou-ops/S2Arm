// Linux host: force real alias protect+restore failure and simulate reuse of
// its no-longer-owned destination before the provider receives EIO.
#include "track_platform.h"
#include "plat.h"
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

void plat_vm_test_set_protect_fail(int on);
void plat_vm_test_set_restore_fail(int on);
int __real_plat_vm_alias(void *dst, const void *src, size_t size, uint32_t prot);
static void *reclaimed;
int __real_munmap(void *address, size_t size);
int __wrap_munmap(void *address, size_t size) {
    if (address == reclaimed) fprintf(stderr, "reclaimed destination was unmapped\n");
    return __real_munmap(address, size);
}
int __wrap_plat_vm_alias(void *dst, const void *src, size_t size, uint32_t prot) {
    int error = __real_plat_vm_alias(dst, src, size, prot);
    if (error == EIO) {
        // Controlled replacement models another owner after ownership is lost.
        reclaimed = mmap(dst, size, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
        if (reclaimed != dst) _exit(90);
        *(volatile uint8_t *)reclaimed = 0x7b;
        fprintf(stderr, "poisoned destination installed\n");
    }
    return error;
}
int main(void) {
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    int fd[2]; if (pipe(fd)) return 2;
    pid_t child = fork();
    if (child == 0) {
        close(fd[0]); if (dup2(fd[1], STDERR_FILENO) < 0) _exit(91); close(fd[1]);
        void *source = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
        if (source == MAP_FAILED) _exit(92);
        plat_vm_test_set_protect_fail(1); plat_vm_test_set_restore_fail(1);
        void *alias = NULL;
        int error = s2a_track_platform_alias((uintptr_t)source, page, PROT_READ, &alias);
        unsigned char vec;
        int was_unmapped = reclaimed && mincore(reclaimed, page, &vec) == -1 && errno == ENOMEM;
        fprintf(stderr, "alias returned %d; reclaimed mapping unmapped=%d\n", error, was_unmapped);
        _exit(was_unmapped ? 42 : 43);
    }
    close(fd[1]);
    int status = 0; if (waitpid(child, &status, 0) != child) return 3;
    char report[1024] = {0}; ssize_t n = read(fd[0], report, sizeof report - 1); close(fd[0]);
    if (!WIFSIGNALED(status) || WTERMSIG(status) != SIGABRT || n <= 0 ||
        !strstr(report, "poisoned destination installed") || !strstr(report, "共享别名保留区失效") ||
        strstr(report, "reclaimed destination was unmapped")) {
        fprintf(stderr, "FAIL poisoned destination continued: status=%d detail=%s\n", status, n > 0 ? report : "none"); return 1;
    }
    puts("PASS poisoned alias destination terminates without cleanup");
    return 0;
}
