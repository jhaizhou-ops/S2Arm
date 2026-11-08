// A device may not be destroyed with live children, regardless of ledger size.
// Include production code to seed an independently counted synthetic driver.
#include "../direct_vk.c"
#include <assert.h>

static unsigned children, destroyed_children, destroyed_devices;
static VkResult VKAPI_CALL idle(VkDevice d) { assert(d == device); return VK_SUCCESS; }
static void VKAPI_CALL drop_buffer(VkDevice d, VkBuffer b, const VkAllocationCallbacks *a) {
    assert(d == device && !a && (uintptr_t)b >= 1 && (uintptr_t)b <= 128);
    assert(children); children--; destroyed_children++;
    if (destroyed_children == 1)
        for (unsigned i = 1; i <= 75000; i++) terminal_free((void *)(uintptr_t)(i * 16));
}
static void VKAPI_CALL drop_device(VkDevice d, const VkAllocationCallbacks *a) {
    assert(d == device && !a);
    assert(children == 0); // independent oracle, not the frontend's owned_count
    destroyed_devices++;
}
static void unused(void) { abort(); }
static PFN_vkVoidFunction dispatch(const char *name) {
    if (!strcmp(name, "vkDeviceWaitIdle")) return (PFN_vkVoidFunction)idle;
    if (!strcmp(name, "vkDestroyBuffer")) return (PFN_vkVoidFunction)drop_buffer;
    if (!strcmp(name, "vkDestroyDevice")) return (PFN_vkVoidFunction)drop_device;
    return unused; // other destruction types have no objects in this fixture
}
int main(void) {
    host.symbol = dispatch;
    device = (VkDevice)(uintptr_t)0x1234;
    for (unsigned i = 1; i <= 128; i++) {
        remember_object(VK_OBJECT_TYPE_BUFFER, i, NULL); children++;
    }
    // FIFO frees force the old linear provenance search to scan the full set.
    for (unsigned i = 1; i <= 75000; i++) allocation_remember((void *)(uintptr_t)(i * 16), 16, 0);
    assert(s2a_android_vk_terminal_drain() == 0);
    assert(destroyed_children == 128 && destroyed_devices == 1);
    assert(s2a_android_vk_stop() == 0);
    assert(atomic_load(&quarantined_frees) == 75000);
    assert(!allocation_find((void *)(uintptr_t)16, NULL, 1)); // retired key cannot free twice
    unsigned char *scratch=terminal_allocate(32,16);
    assert(scratch); memset(scratch,0x5a,32);
    scratch=terminal_reallocate(scratch,64,16); assert(scratch);
    for(unsigned i=0;i<32;i++)assert(scratch[i]==0x5a);
    assert(terminal_scratch_left()==1);
    terminal_free(scratch); assert(terminal_scratch_left()==0);
    puts("PASS 128 child objects destroyed before device");
}
