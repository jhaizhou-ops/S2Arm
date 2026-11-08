// Two real sessions in one process: page geometry and registered hooks survive.
// Between sessions the same two resets the in-process restart runs (runtime/src/session.c): the graphics layer's nvn_dirty_reset_session and the native
// layer's s2a_direct_host_session_reset, which clears every direct-host callback slot. 11-02 BotW restart on an iPhone: the second session protected pool
// pages but its fault hook had been cleared and nvn_dirty registered it only once per process, so the first guest write to such a page was a SIGBUS.
#include "../gfx/nvn/nvn_dirty.h"
#include "../host/dm.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

void nvn_dirty_reset_session(void);
void s2a_direct_host_session_reset(void);
int s2a_direct_fault(void *addr, int is_write, void *uctx);
static int checks, failures;
#define CK(c, msg) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL session %d: %s\n", session, msg); } } while (0)
static ssize_t kernel_copy(unsigned char *p) {
    int fd[2];
    if (pipe(fd)) return -2;
    unsigned char v = 0x5a;
    if (write(fd[1], &v, 1) != 1) { close(fd[0]); close(fd[1]); return -2; }
    ssize_t n = read(fd[0], p, 1);
    int error = errno;
    close(fd[0]); close(fd[1]); errno = error;
    return n;
}
int main(void) {
    if (setenv("S2A_GFX", "direct", 1)) { perror("setenv"); return 2; }
    size_t pg = (size_t)getpagesize();
    for (int session = 1; session <= 2; session++) {
        unsigned char *p = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (p == MAP_FAILED) { perror("mmap"); return 2; }
        nvn_dirty_add_range(p, pg);
        CK(nvn_dirty_page_size() == pg, "process page size retained");
        CK(nvn_dirty_tracked(p, pg), "real mapped range tracked");
        nvn_dirty_protect(p, pg);
        CK(s2a_direct_fault(p, 1, NULL) == 1 && kernel_copy(p) == 1, "native fault entry reaches the registered hook, which unprotects the page");
        nvn_dirty_protect(p, pg);
        ssize_t n = kernel_copy(p);
        CK(n == -1 && errno == EFAULT, "kernel copy confirms actual read-only protection");
        uint64_t stamp = nvn_dirty_now();
        dm_guest_write_prepare(p, 1);
        CK(kernel_copy(p) == 1 && *p == 0x5a, "registered pre-write hook restores real write access");
        CK(nvn_dirty_now() > stamp, "write generation advanced");
        uint64_t faults, preps; nvn_dirty_stats(&faults, &preps);
        CK(faults == (uint64_t)session && preps >= (uint64_t)session, "one claimed fault per session (the check above), host-track-NVN pre-write counted");
        nvn_dirty_reset_session();
        s2a_direct_host_session_reset();
        munmap(p, pg);
    }
    printf("%s t_dirty_reset: %d checks, %d failures (two real mmap/mprotect sessions, kernel copy)\n", failures ? "✗" : "✓", checks, failures);
    return failures != 0;
}
