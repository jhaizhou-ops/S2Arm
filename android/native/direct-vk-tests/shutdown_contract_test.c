// Exercise the production acquire admission epilogue and terminal present polling.
#ifndef S2A_DIRECT_SOURCE
#define S2A_DIRECT_SOURCE "../direct_vk.c"
#endif
#include S2A_DIRECT_SOURCE
#include <assert.h>
#include <sched.h>

static _Atomic int parked, polls;
_Noreturn void s2a_android_guest_park_forever(void) { atomic_store(&parked, 1); pthread_exit(NULL); }
static void block(void) {}
static VkResult VKAPI_CALL status(VkDevice d, VkFence f) {
    (void)d; (void)f;
    return atomic_fetch_add(&polls, 1) ? VK_SUCCESS : VK_NOT_READY;
}
static PFN_vkVoidFunction dispatch(const char *name) {
    if (!strcmp(name, "vkGetFenceStatus")) return (PFN_vkVoidFunction)status;
    abort();
}
static void *acquirer(void *ignored) {
    (void)ignored; uint32_t index;
    (void)acquire_next_image(device, (VkSwapchainKHR)(uintptr_t)&vi_chains[0], UINT64_MAX,
                             (VkSemaphore)(uintptr_t)1, VK_NULL_HANDLE, &index);
    abort();
}
int main(int argc, char **argv) {
    assert(argc == 2);
    host.symbol=dispatch; host.block_begin=block; host.block_end=block;
    device=(VkDevice)(uintptr_t)1; vi_enabled=1; atomic_store(&configured,1);
    struct vi_chain *c=&vi_chains[0]; c->live=1; c->device=device; c->host_count=1;
    if (!strcmp(argv[1], "acquire")) {
        pthread_t t; pthread_mutex_lock(&wsi_mutex);
        assert(!pthread_create(&t,NULL,acquirer,NULL));
        while (!atomic_load(&guest_inflight)) sched_yield();
        (void)s2a_android_vk_quiesce();
        pthread_mutex_unlock(&wsi_mutex);
        assert(!pthread_join(t,NULL));
        assert(atomic_load(&parked));
        assert(atomic_load(&guest_inflight)==0);
    } else {
        assert(!strcmp(argv[1], "present"));
        atomic_store(&terminating,1); c->images[0].pending=1;
#ifdef S2A_OLD_CONTRACT
        VkResult r=vi_poll_present(c,0,500);
#else
        VkResult r=vi_poll_present(c,0,wsi_deadline(500000000ull),VI_WAIT_TERMINAL);
#endif
        assert(r==VK_SUCCESS && atomic_load(&polls)==2 && !c->images[0].pending);
    }
    puts("PASS shutdown contract");
}
