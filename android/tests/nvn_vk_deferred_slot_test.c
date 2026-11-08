// Exercise actual production deferred-slot retirement with independent fence outcomes.
#ifndef FIRST_DRAW_SOURCE
#define FIRST_DRAW_SOURCE "../native/nvn/nvn_vk_first_draw.c"
#endif
#include FIRST_DRAW_SOURCE
#include <assert.h>
#define H(T,n) ((T)(uintptr_t)(n))
static int destroyed[64], waited[64], completed[64];
VKAPI_ATTR VkResult VKAPI_CALL vkWaitForFences(VkDevice d,uint32_t n,const VkFence*f,VkBool32 all,uint64_t t) { (void)d;(void)all;(void)t; assert(n==1); int x=(int)(uintptr_t)*f; waited[x]++; return x==11 ? VK_TIMEOUT : VK_SUCCESS; }
#define DESTROY(name,T) VKAPI_ATTR void VKAPI_CALL name(VkDevice d,T h,const VkAllocationCallbacks*a) { (void)d;(void)a;assert((uintptr_t)h<64);destroyed[(uintptr_t)h]++; }
DESTROY(vkDestroyFence,VkFence)
DESTROY(vkDestroyPipeline,VkPipeline)
DESTROY(vkDestroyBuffer,VkBuffer)
DESTROY(vkFreeMemory,VkDeviceMemory)
DESTROY(vkDestroySampler,VkSampler)
DESTROY(vkDestroyDescriptorPool,VkDescriptorPool)
DESTROY(vkDestroyFramebuffer,VkFramebuffer)
DESTROY(vkDestroyRenderPass,VkRenderPass)
DESTROY(vkDestroyImageView,VkImageView)
DESTROY(vkDestroyImage,VkImage)
void s2a_poolahb_complete_seq(uint64_t seq) { assert(seq<64); completed[seq]++; }
VKAPI_ATTR void VKAPI_CALL vkUnmapMemory(VkDevice d,VkDeviceMemory m){(void)d;(void)m;}
VKAPI_ATTR void VKAPI_CALL vkFreeCommandBuffers(VkDevice d,VkCommandPool p,uint32_t n,const VkCommandBuffer*c){(void)d;(void)p;(void)n;(void)c;}
VKAPI_ATTR VkResult VKAPI_CALL vkResetDescriptorPool(VkDevice d,VkDescriptorPool p,VkDescriptorPoolResetFlags f){(void)d;(void)p;(void)f;return VK_SUCCESS;}
int __android_log_print(int p,const char*t,const char*f,...){(void)p;(void)t;(void)f;return 0;}
int nvn_vk_query_resolve(struct s2a_vk_device*d,char*w,size_t z){(void)d;(void)w;(void)z;return 0;}
int nvn_vk_query_batch_completed(uint64_t s,char*w,size_t z){(void)s;(void)w;(void)z;return 0;}
int main(void) {
  struct s2a_vk_device d={0}; d.device=H(VkDevice,1);
  for (int i=0;i<2;i++) {
    g_slot[i].used=1; g_slot[i].q.dev=&d; g_slot[i].q.fence=H(VkFence,10+i);
    g_slot[i].q.npend=1; g_slot[i].q.pend[0]=H(VkPipeline,20+i);
    g_slot[i].ref_seq=30+i;
  }
  g_slot_cur=1;
  assert(nvn_vk_first_draw_retire_all()!=0);
  assert(waited[10]==1 && waited[11]==1);
  assert(!g_slot[0].used && destroyed[10]==1 && destroyed[20]==1 && completed[30]==1);
  assert(g_slot[1].used && g_slot[1].q.fence==H(VkFence,11) && g_slot[1].q.pend[0]==H(VkPipeline,21));
  assert(destroyed[11]==0 && destroyed[21]==0 && completed[31]==0);
  assert(g_slot_fail);
  puts("independent deferred slot proof passed"); return 0;
}
uint64_t s2a_vk_adapter_registry_generation(void){return 0;}
void nvn_vk_texcache_unpin(struct nvn_vk_tex*t){(void)t;}
void nvn_vk_texcache_unpin_view(struct nvn_vk_tex*t,VkImageView v){(void)t;(void)v;}
int __system_property_get(const char*n,char*v){(void)n;*v=0;return 0;}
VKAPI_ATTR VkResult VKAPI_CALL vkGetQueryPoolResults(VkDevice d,VkQueryPool p,uint32_t f,uint32_t n,size_t z,void*out,VkDeviceSize stride,VkQueryResultFlags flags){(void)d;(void)p;(void)f;(void)n;(void)z;(void)out;(void)stride;(void)flags;return VK_SUCCESS;}
