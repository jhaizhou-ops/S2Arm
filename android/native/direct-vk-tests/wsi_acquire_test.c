// A different image may be acquired while a prior presentation is pending.
#include "../direct_vk.c"
#include <assert.h>
static unsigned acquired;
static void block(void) {}
static VkResult VKAPI_CALL wait_fences(VkDevice d,uint32_t n,const VkFence *f,VkBool32 all,uint64_t ns) {
    (void)d;(void)n;(void)f;(void)all;(void)ns;return VK_SUCCESS;
}
static VkResult VKAPI_CALL fence_status(VkDevice d,VkFence f) { (void)d;(void)f;return VK_NOT_READY; }
static VkResult VKAPI_CALL acquire(VkDevice d,VkSwapchainKHR c,uint64_t ns,VkSemaphore s,VkFence f,uint32_t *index) {
    (void)d;(void)c;(void)ns;(void)s;(void)f;*index=1;acquired++;return VK_SUCCESS;
}
static PFN_vkVoidFunction dispatch(const char *name) {
    if(!strcmp(name,"vkWaitForFences"))return (PFN_vkVoidFunction)wait_fences;
    if(!strcmp(name,"vkGetFenceStatus"))return (PFN_vkVoidFunction)fence_status;
    if(!strcmp(name,"vkAcquireNextImageKHR"))return (PFN_vkVoidFunction)acquire;
    abort();
}
int main(void) {
    host.symbol=dispatch;host.block_begin=block;host.block_end=block;
    device=(VkDevice)(uintptr_t)1;
    struct vi_chain *c=&vi_chains[0];
    c->live=1;c->device=device;c->host_count=4;c->images[0].pending=1;
    uint32_t index=UINT32_MAX;
    VkResult r=vi_acquire(device,(VkSwapchainKHR)(uintptr_t)c,1000000,
        (VkSemaphore)(uintptr_t)2,VK_NULL_HANDLE,&index);
    assert(r==VK_SUCCESS && acquired==1 && index==0);
    assert(c->slots[0].acquired && c->slots[0].host_index==1);
    assert(c->images[0].pending); // no fictitious retirement of the earlier frame
    puts("PASS available image acquired while earlier present remains pending");
}
