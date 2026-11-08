// Real tracker and real protected pages. Direct host reads must die with 5,
// while the production managed Android consumer uses the untracked alias.
#include "../../s2a_track.h"
#include <mach/mach.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static uint8_t *page;
static void unexpected_fault(int sig) { (void)sig; _exit(5); }
uint64_t fixture_prepare(void) {
    struct sigaction sa = {0}; sa.sa_handler = unexpected_fault; sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL); sigaction(SIGBUS, &sa, NULL);
    page = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (page == MAP_FAILED) return 0;
    memset(page, 0, 0x4000);
    uint64_t p = (uint64_t)(uintptr_t)page;
    s2a_track_set_readflush(1); s2a_track_set_emul(0); s2a_track_set_touch(NULL);
    s2a_track_prot_changed(p, 0x4000);
    s2a_track_batch initial; s2a_track_drain(&initial); s2a_track_drain_done();
    s2a_track_reprotect(p + 0x1000, 0x1000, S2A_TRACK_NONE);
    s2a_track_write_quiet(p + 0x1010, 1); page[0x1010] = 0x5a;
    return p + 0x1000;
}
int fixture_protection(void) {
    vm_address_t a = (vm_address_t)page; vm_size_t size = 0;
    vm_region_basic_info_data_64_t info; mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    return vm_region_64(mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64,
                        (vm_region_info_t)&info, &count, &object) == KERN_SUCCESS ? info.protection : -1;
}
int fixture_clobber_precise(void) {
    uint8_t value = 0x11;
    s2a_track_set_walias(1);
    s2a_track_write_untracked((uint64_t)(uintptr_t)page + 0x1010, &value, 1, 1);
    return fixture_protection();
}
int fixture_read_precise(void) {
    uint8_t value = 0;
    s2a_track_read_untracked((uint64_t)(uintptr_t)page + 0x1010, &value, 1);
    return value;
}
