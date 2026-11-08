// VI logical images are independent of Android's BufferQueue image count.
// Included after raw()/adapt_allocator(): all driver calls stay private here.
#include "direct_wsi_plan.h"
#include <time.h>
#define WSI_HOST_IMAGES 16
static int maintenance_instance, maintenance_device;
static VkPhysicalDevice wsi_physical;
static uint32_t wsi_family;
static pthread_mutex_t wsi_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wsi_changed = PTHREAD_COND_INITIALIZER;
struct vi_slot { VkImage image; VkDeviceMemory memory; VkCommandBuffer command; VkFence copied; int acquired; uint32_t host_index; };
struct vi_host_image { VkImage image; VkSemaphore ready; VkFence presented; int pending; };
struct vi_chain {
    int live, poisoned; VkDevice device; VkSwapchainKHR native; VkSurfaceKHR surface;
    VkExtent2D extent, host_extent; VkRect2D destination; VkFormat format;
    VkCommandPool pool; unsigned next, host_count, last_copy; int copy_pending;
    const VkAllocationCallbacks *allocator;
    struct vi_slot slots[S2A_VI_IMAGES];
    struct vi_host_image images[WSI_HOST_IMAGES];
};
static struct vi_chain vi_chains[4];
#define WAPI(n) ((PFN_##n)raw(#n))
static struct vi_chain *vi_find(VkSwapchainKHR handle) {
    for (unsigned j=0;j<4;j++) if (vi_chains[j].live && handle==(VkSwapchainKHR)(uintptr_t)&vi_chains[j]) return &vi_chains[j];
    return NULL;
}
static int vi_image(VkImage image) {
    for (unsigned j=0;j<4;j++) if (vi_chains[j].live)
        for (unsigned k=0;k<S2A_VI_IMAGES;k++) if (vi_chains[j].slots[k].image==image) return 1;
    return 0;
}
static VkResult vi_wait(VkDevice d, VkFence f, uint64_t timeout) {
    return WAPI(vkWaitForFences)(d,1,&f,VK_TRUE,timeout);
}
// 客体可能带着无限超时停在 acquire / present 里，而这两条路径都持有 WSI 锁；
// 单次持锁必须有上界，否则终止清场只能等到 watchdog 直接 _exit(124)。
#define WSI_STEP_NS 100000000ull   // 单次持锁上限：驱动等待与 WSI 锁都按这一步切分
static uint64_t wsi_wait(uint64_t timeout) {
    return timeout > WSI_STEP_NS ? WSI_STEP_NS : timeout;
}
static uint64_t wsi_now_ns(void) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}
enum vi_wait_mode { VI_WAIT_LIVE, VI_WAIT_TERMINAL };
static uint64_t wsi_deadline(uint64_t timeout) {
    uint64_t now=wsi_now_ns();
    return timeout==UINT64_MAX || timeout>UINT64_MAX-now?UINT64_MAX:now+timeout;
}
static uint64_t wsi_remaining(uint64_t deadline) {
    if(deadline==UINT64_MAX)return UINT64_MAX;
    uint64_t now=wsi_now_ns();
    return now<deadline?deadline-now:0;
}
// Poll present completion with one absolute deadline. A wrapper-stage timeout
// alone does not identify a driver wait as the cause. Terminal retirement must
// finish admitted work despite the closed guest gate.
static VkResult vi_poll_present(struct vi_chain *c,unsigned index,uint64_t deadline,enum vi_wait_mode mode) {
    for(;;){
        VkResult st=WAPI(vkGetFenceStatus)(c->device,c->images[index].presented);
        if(st==VK_SUCCESS){c->images[index].pending=0;return VK_SUCCESS;}
        if(st!=VK_NOT_READY){c->poisoned=1;return st;}
        if(mode==VI_WAIT_LIVE && VK_GUEST_STOPPED())return VK_TIMEOUT;
        uint64_t remaining=wsi_remaining(deadline);
        if(!remaining)return VK_TIMEOUT;
        uint64_t sleep=remaining<1000000ull?remaining:1000000ull;
        struct timespec delay={0,(long)sleep};
        nanosleep(&delay,NULL);
    }
}
static VkResult vi_wait_copied(struct vi_chain *c,VkFence fence,uint64_t deadline,enum vi_wait_mode mode) {
    for(;;){
        if(mode==VI_WAIT_LIVE && VK_GUEST_STOPPED())return VK_TIMEOUT;
        uint64_t remaining=wsi_remaining(deadline);
        VkResult r=vi_wait(c->device,fence,wsi_wait(remaining));
        if(r!=VK_TIMEOUT)return r;
        if(!wsi_remaining(deadline))return VK_TIMEOUT;
    }
}
static VkResult vi_retire(struct vi_chain *c,uint64_t deadline,enum vi_wait_mode mode) {
    if(c->poisoned)return VK_ERROR_DEVICE_LOST;
    VkResult r=VK_SUCCESS;
    for(unsigned j=0;j<S2A_VI_IMAGES && r==VK_SUCCESS;j++)
        if(c->slots[j].copied)r=vi_wait_copied(c,c->slots[j].copied,deadline,mode);
    for(unsigned j=0;j<c->host_count && r==VK_SUCCESS;j++)
        if(c->images[j].pending)r=vi_poll_present(c,j,deadline,mode);
    for(unsigned j=0;j<S2A_VI_IMAGES && r==VK_SUCCESS;j++)if(c->slots[j].acquired){
        uint32_t index=c->slots[j].host_index;
        VkReleaseSwapchainImagesInfoEXT release={.sType=VK_STRUCTURE_TYPE_RELEASE_SWAPCHAIN_IMAGES_INFO_EXT,
            .swapchain=c->native,.imageIndexCount=1,.pImageIndices=&index};
        r=WAPI(vkReleaseSwapchainImagesEXT)(c->device,&release);
        if(r==VK_SUCCESS)c->slots[j].acquired=0;
    }
    return r;
}
static void vi_dispose(struct vi_chain *c) {
    const VkAllocationCallbacks *a=c->allocator; VkDevice d=c->device;
    for (unsigned j=0;j<c->host_count;j++) {
        if(c->images[j].ready) WAPI(vkDestroySemaphore)(d,c->images[j].ready,a);
        if(c->images[j].presented) WAPI(vkDestroyFence)(d,c->images[j].presented,a);
    }
    if(c->pool) WAPI(vkDestroyCommandPool)(d,c->pool,a);
    for (unsigned j=0;j<S2A_VI_IMAGES;j++) {
        if(c->slots[j].copied) WAPI(vkDestroyFence)(d,c->slots[j].copied,a);
        if(c->slots[j].image) WAPI(vkDestroyImage)(d,c->slots[j].image,a);
        if(c->slots[j].memory) WAPI(vkFreeMemory)(d,c->slots[j].memory,a);
    }
    if(c->native) WAPI(vkDestroySwapchainKHR)(d,c->native,a);
    memset(c,0,sizeof *c); pthread_cond_broadcast(&wsi_changed);
}
static VkResult vi_create(VkDevice d,const VkSwapchainCreateInfoKHR *info,const VkAllocationCallbacks *allocator,VkSwapchainKHR *out) {
    if (!info || !out || info->sType!=VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR) return VK_ERROR_INITIALIZATION_FAILED;
    if (!maintenance_device || info->pNext || info->flags || info->minImageCount!=S2A_VI_IMAGES ||
        info->imageArrayLayers!=1 || info->imageSharingMode!=VK_SHARING_MODE_EXCLUSIVE ||
        info->preTransform!=VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR) return VK_ERROR_FEATURE_NOT_PRESENT;
    if(info->imageFormat!=VK_FORMAT_R8G8B8A8_UNORM && info->imageFormat!=VK_FORMAT_B8G8R8A8_UNORM &&
        info->imageFormat!=VK_FORMAT_R8G8B8A8_SRGB && info->imageFormat!=VK_FORMAT_B8G8R8A8_SRGB) return VK_ERROR_FORMAT_NOT_SUPPORTED;
    const VkAllocationCallbacks *a; VkResult r=adapt_allocator(allocator,&a); if(r!=VK_SUCCESS)return r;
    VkSurfaceCapabilitiesKHR caps;
    r=WAPI(vkGetPhysicalDeviceSurfaceCapabilitiesKHR)(wsi_physical,info->surface,&caps); if(r!=VK_SUCCESS)return r;
    if(!(caps.supportedUsageFlags&VK_IMAGE_USAGE_TRANSFER_DST_BIT))return VK_ERROR_FORMAT_NOT_SUPPORTED;
    VkFormatProperties fp; WAPI(vkGetPhysicalDeviceFormatProperties)(wsi_physical,info->imageFormat,&fp);
    if((fp.optimalTilingFeatures&(VK_FORMAT_FEATURE_BLIT_SRC_BIT|VK_FORMAT_FEATURE_BLIT_DST_BIT|VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT))!=
        (VK_FORMAT_FEATURE_BLIT_SRC_BIT|VK_FORMAT_FEATURE_BLIT_DST_BIT|VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT))return VK_ERROR_FORMAT_NOT_SUPPORTED;
    pthread_mutex_lock(&wsi_mutex);
    struct vi_chain *old=info->oldSwapchain?vi_find(info->oldSwapchain):NULL;
    if(info->oldSwapchain && !old){pthread_mutex_unlock(&wsi_mutex);return VK_ERROR_INITIALIZATION_FAILED;}
    struct vi_chain *c=NULL;for(unsigned j=0;j<4;j++)if(!vi_chains[j].live){c=&vi_chains[j];break;}
    if(!c){pthread_mutex_unlock(&wsi_mutex);return VK_ERROR_TOO_MANY_OBJECTS;}
    memset(c,0,sizeof *c);c->live=1;c->device=d;c->allocator=a;c->surface=info->surface;c->format=info->imageFormat;c->extent=info->imageExtent;
    c->host_extent=caps.currentExtent.width==UINT32_MAX?info->imageExtent:caps.currentExtent;
    if(!s2a_vi_fit(c->extent,c->host_extent,&c->destination)){r=VK_ERROR_INITIALIZATION_FAILED;goto failed;}
    VkSwapchainCreateInfoKHR native=*info;
    native.minImageCount=caps.minImageCount; native.imageExtent=c->host_extent;
    if(!(caps.supportedTransforms&VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR)){r=VK_ERROR_FEATURE_NOT_PRESENT;goto failed;}
    // The compositor applies display rotation. Copying an unrotated logical
    // image into a pre-rotated native buffer would rotate the picture twice.
    native.preTransform=VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;native.oldSwapchain=old?old->native:VK_NULL_HANDLE;
    native.imageUsage=VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    native.compositeAlpha=(caps.supportedCompositeAlpha&VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)?VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR:VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
    r=WAPI(vkCreateSwapchainKHR)(d,&native,a,&c->native);if(r!=VK_SUCCESS)goto failed;
    uint32_t n=0;r=WAPI(vkGetSwapchainImagesKHR)(d,c->native,&n,NULL);if(r!=VK_SUCCESS)goto failed;
    if(!n||n>WSI_HOST_IMAGES){r=VK_ERROR_TOO_MANY_OBJECTS;goto failed;}
    VkImage images[WSI_HOST_IMAGES];r=WAPI(vkGetSwapchainImagesKHR)(d,c->native,&n,images);if(r!=VK_SUCCESS)goto failed;
    c->host_count=n;
    VkSemaphoreCreateInfo si={.sType=VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    VkFenceCreateInfo fi={.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    for(unsigned j=0;j<n;j++){
        c->images[j].image=images[j];
        r=WAPI(vkCreateSemaphore)(d,&si,a,&c->images[j].ready);if(r!=VK_SUCCESS)goto failed;
        r=WAPI(vkCreateFence)(d,&fi,a,&c->images[j].presented);if(r!=VK_SUCCESS)goto failed;
    }
    VkCommandPoolCreateInfo pi={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,.queueFamilyIndex=wsi_family};
    r=WAPI(vkCreateCommandPool)(d,&pi,a,&c->pool);if(r!=VK_SUCCESS)goto failed;
    VkCommandBufferAllocateInfo cai={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=c->pool,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=S2A_VI_IMAGES};
    VkCommandBuffer commands[S2A_VI_IMAGES];r=WAPI(vkAllocateCommandBuffers)(d,&cai,commands);if(r!=VK_SUCCESS)goto failed;
    VkPhysicalDeviceMemoryProperties memory;WAPI(vkGetPhysicalDeviceMemoryProperties)(wsi_physical,&memory);
    fi.flags=VK_FENCE_CREATE_SIGNALED_BIT;
    for(unsigned j=0;j<S2A_VI_IMAGES;j++){
        struct vi_slot *s=&c->slots[j];s->command=commands[j];
        VkImageCreateInfo ii={.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,.imageType=VK_IMAGE_TYPE_2D,.format=c->format,
            .extent={c->extent.width,c->extent.height,1},.mipLevels=1,.arrayLayers=1,.samples=VK_SAMPLE_COUNT_1_BIT,
            .tiling=VK_IMAGE_TILING_OPTIMAL,.usage=info->imageUsage|VK_IMAGE_USAGE_TRANSFER_SRC_BIT,.sharingMode=VK_SHARING_MODE_EXCLUSIVE};
        r=WAPI(vkCreateImage)(d,&ii,a,&s->image);if(r!=VK_SUCCESS)goto failed;
        VkMemoryRequirements req;WAPI(vkGetImageMemoryRequirements)(d,s->image,&req);
        unsigned type=0;while(type<memory.memoryTypeCount && (!(req.memoryTypeBits&(1u<<type)) || !(memory.memoryTypes[type].propertyFlags&VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)))type++;
        if(type==memory.memoryTypeCount){r=VK_ERROR_OUT_OF_DEVICE_MEMORY;goto failed;}
        VkMemoryAllocateInfo ai={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=req.size,.memoryTypeIndex=type};
        r=WAPI(vkAllocateMemory)(d,&ai,a,&s->memory);if(r!=VK_SUCCESS)goto failed;
        r=WAPI(vkBindImageMemory)(d,s->image,s->memory,0);if(r!=VK_SUCCESS)goto failed;
        r=WAPI(vkCreateFence)(d,&fi,a,&s->copied);if(r!=VK_SUCCESS)goto failed;
    }
    *out=(VkSwapchainKHR)(uintptr_t)c;
    fprintf(stderr,"[vk-direct] VI交换链：客体3图 %ux%u；Android %u图 %ux%u；等比区域 %d,%d %ux%u，present fence启用\n",
        c->extent.width,c->extent.height,n,c->host_extent.width,c->host_extent.height,c->destination.offset.x,c->destination.offset.y,c->destination.extent.width,c->destination.extent.height);
    pthread_mutex_unlock(&wsi_mutex);return VK_SUCCESS;
failed:
    vi_dispose(c);pthread_mutex_unlock(&wsi_mutex);return r;
}
static VkResult vi_images(VkDevice d,VkSwapchainKHR chain,uint32_t *count,VkImage *images){
    if(!count)return VK_ERROR_INITIALIZATION_FAILED;
    pthread_mutex_lock(&wsi_mutex);struct vi_chain *c=vi_find(chain);
    if(!c||c->device!=d){pthread_mutex_unlock(&wsi_mutex);return VK_ERROR_INITIALIZATION_FAILED;}
    VkResult r=VK_SUCCESS;
    if(!images)*count=S2A_VI_IMAGES;
    else{unsigned n=*count<S2A_VI_IMAGES?*count:S2A_VI_IMAGES;for(unsigned j=0;j<n;j++)images[j]=c->slots[j].image;*count=n;if(n<S2A_VI_IMAGES)r=VK_INCOMPLETE;}
    pthread_mutex_unlock(&wsi_mutex);return r;
}
// 每次最多持 WSI 锁 100 ms 再放回，按客体给的超时继续等：客体用无限超时停在 acquire 里时，
// 收尾线程仍能拿到锁完成排空；客体语义不变（只有它自己的超时到期才收到 VK_TIMEOUT）。
static VkResult vi_acquire(VkDevice d,VkSwapchainKHR chain,uint64_t timeout,VkSemaphore sem,VkFence fence,uint32_t *index){
    if(!index || (!sem&&!fence))return VK_ERROR_INITIALIZATION_FAILED;
    const uint64_t deadline=wsi_deadline(timeout);
    for(;;){
        VkResult r=VK_TIMEOUT;
        note_call_stage("acquire: 等 WSI 锁");
        pthread_mutex_lock(&wsi_mutex);
        struct vi_chain *c=vi_find(chain);
        if(!c||c->device!=d||c->poisoned){pthread_mutex_unlock(&wsi_mutex);return VK_ERROR_INITIALIZATION_FAILED;}
        if(VK_GUEST_STOPPED()){pthread_mutex_unlock(&wsi_mutex);return VK_ERROR_INITIALIZATION_FAILED;}
        unsigned v=c->next%S2A_VI_IMAGES;struct vi_slot *s=&c->slots[v];
        // One outstanding acquire is the advertised minimum guarantee (3-3+1).
        int busy=0;for(unsigned j=0;j<S2A_VI_IMAGES;j++)if(c->slots[j].acquired){busy=1;break;}
        if(busy){pthread_mutex_unlock(&wsi_mutex);if(!timeout)return VK_NOT_READY;r=VK_TIMEOUT;}
        else if(timeout && !wsi_remaining(deadline)){pthread_mutex_unlock(&wsi_mutex);return VK_TIMEOUT;}
        else{
            uint64_t step_deadline=wsi_deadline(WSI_STEP_NS);
            if(deadline<step_deadline)step_deadline=deadline;
            // A guest can reuse one acquire semaphore every frame. Its previous GPU
            // wait must have completed before the loader signals it again. Waiting only
            // this slot's fence proves completion three frames back, which is too old.
            // Other host images may be available while a prior present remains
            // pending. Its resources are retired before their actual next use.
            r=VK_SUCCESS;
            note_call_stage("acquire: 等拷贝 fence");
            if(r==VK_SUCCESS && c->copy_pending)r=vi_wait_copied(c,c->slots[c->last_copy].copied,step_deadline,VI_WAIT_LIVE);
            if(r==VK_SUCCESS)r=vi_wait_copied(c,s->copied,step_deadline,VI_WAIT_LIVE);
            note_call_stage("acquire: 驱动 vkAcquireNextImageKHR");
            uint32_t h=0;if(r==VK_SUCCESS)r=WAPI(vkAcquireNextImageKHR)(d,c->native,wsi_remaining(step_deadline),sem,fence,&h);
            note_call_stage("acquire: 宿主图 present fence");
            if((r==VK_SUCCESS||r==VK_SUBOPTIMAL_KHR)&&h<c->host_count){
                // Success already submitted the caller's semaphore/fence signal.
                // Record ownership immediately; never turn it into a retryable
                // timeout or forget it if stop races with present retirement.
                s->acquired=1;s->host_index=h;*index=v;c->next++;
            }else if(r==VK_SUCCESS||r==VK_SUBOPTIMAL_KHR){c->poisoned=1;r=VK_ERROR_INITIALIZATION_FAILED;}
            pthread_mutex_unlock(&wsi_mutex);
        }
        if(r!=VK_TIMEOUT)return r;
        if(timeout==0)return VK_NOT_READY;
        if(!wsi_remaining(deadline))return VK_TIMEOUT;
    }
}
static VkResult vi_present(VkQueue q,const VkPresentInfoKHR *info){
    if(!info||info->pNext||info->swapchainCount!=1||!info->pSwapchains||!info->pImageIndices||info->waitSemaphoreCount>32)return VK_ERROR_FEATURE_NOT_PRESENT;
    note_call_stage("present: 等 WSI 锁");
    struct vi_chain *c;struct vi_slot *s;struct vi_host_image *h;
    for(;;){
        pthread_mutex_lock(&wsi_mutex);c=vi_find(info->pSwapchains[0]);uint32_t v=info->pImageIndices[0];
        if(!c||v>=S2A_VI_IMAGES||!c->slots[v].acquired||c->poisoned){pthread_mutex_unlock(&wsi_mutex);return VK_ERROR_INITIALIZATION_FAILED;}
        s=&c->slots[v];h=&c->images[s->host_index];
        // Acquire owns this image and its signal even if the previous present
        // fence is not yet retired. Wait only before reusing that image's
        // ready semaphore/present fence, not before returning acquire success.
        if(!h->pending)break;
        VkResult retired=vi_poll_present(c,s->host_index,wsi_deadline(WSI_STEP_NS),VI_WAIT_LIVE);
        if(retired==VK_SUCCESS)break;
        pthread_mutex_unlock(&wsi_mutex);
        if(retired!=VK_TIMEOUT || VK_GUEST_STOPPED())return retired;
        // QueuePresent has no caller timeout. Release the WSI lock every step
        // so terminal shutdown can take over the already acquired image.
    }
    VkResult r=WAPI(vkResetCommandBuffer)(s->command,0);if(r!=VK_SUCCESS)goto done;
    note_call_stage("present: 录制拷贝命令");
    VkCommandBufferBeginInfo bi={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    r=WAPI(vkBeginCommandBuffer)(s->command,&bi);if(r!=VK_SUCCESS)goto done;
    VkImageSubresourceRange range={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
    VkImageMemoryBarrier barriers[2]={
        {.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_MEMORY_WRITE_BIT,.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT,
         .oldLayout=VK_IMAGE_LAYOUT_GENERAL,.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.image=s->image,.subresourceRange=range},
        {.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT,.oldLayout=VK_IMAGE_LAYOUT_UNDEFINED,.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
         .srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.image=h->image,.subresourceRange=range}};
    WAPI(vkCmdPipelineBarrier)(s->command,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,NULL,0,NULL,2,barriers);
    if(c->destination.extent.width!=c->host_extent.width||c->destination.extent.height!=c->host_extent.height){
        VkClearColorValue black={{0,0,0,1}};WAPI(vkCmdClearColorImage)(s->command,h->image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,&black,1,&range);
        VkMemoryBarrier order={.sType=VK_STRUCTURE_TYPE_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT,.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT};
        WAPI(vkCmdPipelineBarrier)(s->command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,1,&order,0,NULL,0,NULL);
    }
    VkImageBlit blit={.srcSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.dstSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1}};
    blit.srcOffsets[1]=(VkOffset3D){c->extent.width,c->extent.height,1};
    blit.dstOffsets[0]=(VkOffset3D){c->destination.offset.x,c->destination.offset.y,0};
    blit.dstOffsets[1]=(VkOffset3D){c->destination.offset.x+(int32_t)c->destination.extent.width,c->destination.offset.y+(int32_t)c->destination.extent.height,1};
    WAPI(vkCmdBlitImage)(s->command,s->image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,h->image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&blit,VK_FILTER_LINEAR);
    barriers[0].srcAccessMask=VK_ACCESS_TRANSFER_READ_BIT;barriers[0].dstAccessMask=VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT;
    barriers[0].oldLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;barriers[0].newLayout=VK_IMAGE_LAYOUT_GENERAL;
    barriers[1].srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;barriers[1].dstAccessMask=0;
    barriers[1].oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;barriers[1].newLayout=VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    WAPI(vkCmdPipelineBarrier)(s->command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,0,0,NULL,0,NULL,2,barriers);
    r=WAPI(vkEndCommandBuffer)(s->command);if(r!=VK_SUCCESS)goto done;
    r=WAPI(vkResetFences)(c->device,1,&s->copied);if(r!=VK_SUCCESS)goto done;
    VkPipelineStageFlags stages[32];for(unsigned j=0;j<info->waitSemaphoreCount;j++)stages[j]=VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo submit={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.waitSemaphoreCount=info->waitSemaphoreCount,.pWaitSemaphores=info->pWaitSemaphores,
        .pWaitDstStageMask=stages,.commandBufferCount=1,.pCommandBuffers=&s->command,.signalSemaphoreCount=1,.pSignalSemaphores=&h->ready};
    note_call_stage("present: 提交拷贝命令");
    r=WAPI(vkQueueSubmit)(q,1,&submit,s->copied);if(r!=VK_SUCCESS)goto done;
    c->last_copy=(unsigned)(s-c->slots);c->copy_pending=1;
    r=WAPI(vkResetFences)(c->device,1,&h->presented);if(r!=VK_SUCCESS)goto done;
    VkSwapchainPresentFenceInfoEXT finish={.sType=VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_EXT,.swapchainCount=1,.pFences=&h->presented};
    VkPresentInfoKHR native={.sType=VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,.pNext=&finish,.waitSemaphoreCount=1,.pWaitSemaphores=&h->ready,
        .swapchainCount=1,.pSwapchains=&c->native,.pImageIndices=&s->host_index};
    note_call_stage("present: 驱动 vkQueuePresentKHR");
    r=WAPI(vkQueuePresentKHR)(q,&native);
    if(r==VK_SUCCESS||r==VK_SUBOPTIMAL_KHR){h->pending=1;s->acquired=0;atomic_fetch_add(&presents,1);pthread_cond_broadcast(&wsi_changed);}
done:
    if(info->pResults)info->pResults[0]=r;
    if(r<0)c->poisoned=1;
    pthread_mutex_unlock(&wsi_mutex);return r;
}
static VkResult vi_destroy(VkDevice d,VkSwapchainKHR chain,const VkAllocationCallbacks *allocator){
    if(!chain)return VK_SUCCESS;
    const VkAllocationCallbacks *a;VkResult r=adapt_allocator(allocator,&a);
    if(r!=VK_SUCCESS)return r;
    pthread_mutex_lock(&wsi_mutex);struct vi_chain *c=vi_find(chain);
    if(!c||c->device!=d||c->allocator!=a){pthread_mutex_unlock(&wsi_mutex);return VK_ERROR_INITIALIZATION_FAILED;}
    r=vi_retire(c,wsi_deadline(30000000000ull),VI_WAIT_LIVE);
    if(r==VK_SUCCESS)vi_dispose(c);
    pthread_mutex_unlock(&wsi_mutex);return r;
}
static int vi_live(void){for(unsigned j=0;j<4;j++)if(vi_chains[j].live)return 1;return 0;}
#undef WAPI
