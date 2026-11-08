// Live driver objects created through the guest API. Ordinary guest destruction
// still calls its allocator. Terminal shutdown owns no continuing guest code;
// guest allocator frees are quarantined until _exit, while Vulkan objects and
// GPU/presentation work are actually destroyed/drained before HLE disposal.
struct owned_vk_object { VkObjectType type; uint64_t handle; const VkAllocationCallbacks *allocator; };
static struct owned_vk_object *owned_objects;
static size_t owned_count, owned_capacity;
static pthread_mutex_t owned_mutex=PTHREAD_MUTEX_INITIALIZER;
static void remember_object(VkObjectType type,uint64_t handle,const VkAllocationCallbacks *a){
    if(!handle)return;
    pthread_mutex_lock(&owned_mutex);
    if(owned_count==owned_capacity){
        size_t n=owned_capacity?owned_capacity*2:256;
        void *next=n<=1048576?realloc(owned_objects,n*sizeof *owned_objects):NULL;
        if(!next){pthread_mutex_unlock(&owned_mutex);fatal("Vulkan object ledger capacity");}
        owned_objects=next;owned_capacity=n;
    }
    owned_objects[owned_count++]=(struct owned_vk_object){type,handle,a};
    pthread_mutex_unlock(&owned_mutex);
}
static void forget_object(VkObjectType type,uint64_t handle){
    if(!handle)return;
    pthread_mutex_lock(&owned_mutex);
    for(size_t j=owned_count;j;j--)if(owned_objects[j-1].type==type && owned_objects[j-1].handle==handle){
        owned_objects[j-1]=owned_objects[--owned_count];break;
    }
    pthread_mutex_unlock(&owned_mutex);
}
static int take_owned(VkObjectType type,struct owned_vk_object *out){
    for(size_t j=owned_count;j;j--)if(owned_objects[j-1].type==type){
        *out=owned_objects[j-1];owned_objects[j-1]=owned_objects[--owned_count];return 1;
    }
    return 0;
}
static void destroy_owned(VkObjectType type,const char *name){
    struct owned_vk_object o;
    size_t dropped=0;
    fprintf(stderr,"[vk-direct] 终止清场：销毁 %s\n",name);
    // Keep the actual Khronos function type, including pointer-typed handles.
#define DROP(kind,ctype,command) case kind: { \
    if(strcmp(name,#command))fatal("Vulkan destruction type mismatch"); \
    PFN_##command fn=(PFN_##command)raw(#command); \
    while(take_owned(type,&o)){fn(device,(ctype)(uintptr_t)o.handle,o.allocator);dropped++;}break; }
    switch(type){
    DROP(VK_OBJECT_TYPE_COMMAND_POOL,VkCommandPool,vkDestroyCommandPool)
    DROP(VK_OBJECT_TYPE_FRAMEBUFFER,VkFramebuffer,vkDestroyFramebuffer)
    DROP(VK_OBJECT_TYPE_PIPELINE,VkPipeline,vkDestroyPipeline)
    DROP(VK_OBJECT_TYPE_DESCRIPTOR_POOL,VkDescriptorPool,vkDestroyDescriptorPool)
    DROP(VK_OBJECT_TYPE_DESCRIPTOR_UPDATE_TEMPLATE,VkDescriptorUpdateTemplate,vkDestroyDescriptorUpdateTemplate)
    DROP(VK_OBJECT_TYPE_PIPELINE_LAYOUT,VkPipelineLayout,vkDestroyPipelineLayout)
    DROP(VK_OBJECT_TYPE_DESCRIPTOR_SET_LAYOUT,VkDescriptorSetLayout,vkDestroyDescriptorSetLayout)
    DROP(VK_OBJECT_TYPE_SAMPLER,VkSampler,vkDestroySampler)
    DROP(VK_OBJECT_TYPE_IMAGE_VIEW,VkImageView,vkDestroyImageView)
    DROP(VK_OBJECT_TYPE_BUFFER_VIEW,VkBufferView,vkDestroyBufferView)
    DROP(VK_OBJECT_TYPE_RENDER_PASS,VkRenderPass,vkDestroyRenderPass)
    DROP(VK_OBJECT_TYPE_SHADER_MODULE,VkShaderModule,vkDestroyShaderModule)
    DROP(VK_OBJECT_TYPE_SEMAPHORE,VkSemaphore,vkDestroySemaphore)
    DROP(VK_OBJECT_TYPE_FENCE,VkFence,vkDestroyFence)
    DROP(VK_OBJECT_TYPE_BUFFER,VkBuffer,vkDestroyBuffer)
    DROP(VK_OBJECT_TYPE_IMAGE,VkImage,vkDestroyImage)
    DROP(VK_OBJECT_TYPE_DEVICE_MEMORY,VkDeviceMemory,vkFreeMemory)
    default:fatal("Vulkan unreviewed destruction type");
    }
#undef DROP
    fprintf(stderr,"[vk-direct] 终止清场：%s 已销毁 %zu 个\n",name,dropped);
}
static void destroy_owned_views(void){
    // Retire command buffers and descriptor sets with their pools first.
    destroy_owned(VK_OBJECT_TYPE_COMMAND_POOL,"vkDestroyCommandPool");
    destroy_owned(VK_OBJECT_TYPE_FRAMEBUFFER,"vkDestroyFramebuffer");
    destroy_owned(VK_OBJECT_TYPE_DESCRIPTOR_POOL,"vkDestroyDescriptorPool");
    destroy_owned(VK_OBJECT_TYPE_DESCRIPTOR_UPDATE_TEMPLATE,"vkDestroyDescriptorUpdateTemplate");
    destroy_owned(VK_OBJECT_TYPE_PIPELINE,"vkDestroyPipeline");
    destroy_owned(VK_OBJECT_TYPE_PIPELINE_LAYOUT,"vkDestroyPipelineLayout");
    destroy_owned(VK_OBJECT_TYPE_DESCRIPTOR_SET_LAYOUT,"vkDestroyDescriptorSetLayout");
    destroy_owned(VK_OBJECT_TYPE_SAMPLER,"vkDestroySampler");
    destroy_owned(VK_OBJECT_TYPE_IMAGE_VIEW,"vkDestroyImageView");
    destroy_owned(VK_OBJECT_TYPE_BUFFER_VIEW,"vkDestroyBufferView");
    destroy_owned(VK_OBJECT_TYPE_RENDER_PASS,"vkDestroyRenderPass");
    destroy_owned(VK_OBJECT_TYPE_SHADER_MODULE,"vkDestroyShaderModule");
    destroy_owned(VK_OBJECT_TYPE_SEMAPHORE,"vkDestroySemaphore");
    destroy_owned(VK_OBJECT_TYPE_FENCE,"vkDestroyFence");
}
static void destroy_owned_storage(void){
    destroy_owned(VK_OBJECT_TYPE_BUFFER,"vkDestroyBuffer");
    destroy_owned(VK_OBJECT_TYPE_IMAGE,"vkDestroyImage");
    destroy_owned(VK_OBJECT_TYPE_DEVICE_MEMORY,"vkFreeMemory");
}
