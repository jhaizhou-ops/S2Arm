// All Vulkan objects and commands use the production swhle API. GPU readback is
// compared with independent direct draws and hand-selected interior pixels.
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern void *dm_vk_lookup(const char *);
extern void dm_vk_indirect_stats(uint64_t *, uint64_t *, uint64_t *);
extern void dm_vk_bad_draws(uint64_t *, uint64_t *);
typedef struct { const char *name; void *fn; } Entry;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
#define OK(x) REQUIRE((x) == VK_SUCCESS)
#define APIS(X) \
 X(vkGetInstanceProcAddr) X(vkGetDeviceProcAddr) X(vkCreateInstance) X(vkEnumeratePhysicalDevices) \
 X(vkEnumerateDeviceExtensionProperties) X(vkGetPhysicalDeviceFeatures) X(vkCreateDevice) X(vkGetDeviceQueue) \
 X(vkCreateBuffer) X(vkGetBufferMemoryRequirements) X(vkAllocateMemory) X(vkBindBufferMemory) X(vkMapMemory) \
 X(vkCreateImage) X(vkGetImageMemoryRequirements) X(vkBindImageMemory) X(vkCreateImageView) \
 X(vkCreateRenderPass) X(vkCreateFramebuffer) X(vkCreateShaderModule) X(vkCreatePipelineLayout) X(vkCreateGraphicsPipelines) \
 X(vkCreateCommandPool) X(vkAllocateCommandBuffers) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) X(vkResetCommandBuffer) \
 X(vkCmdBeginRenderPass) X(vkCmdEndRenderPass) X(vkCmdBindPipeline) X(vkCmdSetViewport) X(vkCmdSetScissor) \
 X(vkCmdBindIndexBuffer) X(vkCmdDraw) X(vkCmdDrawIndexed) X(vkCmdDrawIndirectCountAMD) X(vkCmdDrawIndexedIndirectCountAMD) \
 X(vkCmdDrawIndirect) X(vkCmdDrawIndexedIndirect) \
 X(vkCmdCopyBuffer) X(vkCmdCopyImageToBuffer) X(vkCmdPipelineBarrier) X(vkQueueSubmit) X(vkQueueWaitIdle) \
 X(vkCreateQueryPool) X(vkCmdResetQueryPool) X(vkCmdBeginQuery) X(vkCmdEndQuery) X(vkGetQueryPoolResults)
#define DECL(n) static PFN_##n n;
APIS(DECL)
static VkInstance instance;
static VkDevice device;
static VkQueue queue;
static VkCommandBuffer cb;
static VkCommandPool commandPool;
static VkRenderPass pass;
static VkFramebuffer fb;
static VkPipeline pipeline;
static VkImage color;
static VkQueryPool query;
enum { W = 64, H = 64, BIND = 256, ARG_OFF = 32, COUNT_OFF = 20, STRIDE = 40, INDEX_OFF = 16 };
typedef struct { VkBuffer buffer; VkDeviceMemory memory; uint8_t *bytes; } Buffer;
static Buffer args, count, stagingArgs, stagingCount, indices16, indices32, readback;

static void *registered(const char *name) {
    unsigned long size = 0;
    const Entry *entries = (const Entry *)getsectiondata(&_mh_execute_header, "__DATA", "swhle", &size);
    REQUIRE(entries);
    for (unsigned long i = 0; i < size / sizeof *entries; ++i)
        if (!strcmp(entries[i].name, name)) return entries[i].fn;
    return NULL;
}
static Buffer buffer(VkDeviceSize size, VkBufferUsageFlags usage) {
    Buffer b = {0};
    VkBufferCreateInfo bi = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage, .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
    OK(vkCreateBuffer(device, &bi, NULL, &b.buffer));
    VkMemoryRequirements r;
    vkGetBufferMemoryRequirements(device, b.buffer, &r);
    REQUIRE(BIND % r.alignment == 0);
    VkMemoryAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = BIND + r.size, .memoryTypeIndex = 1};
    OK(vkAllocateMemory(device, &ai, NULL, &b.memory));
    OK(vkBindBufferMemory(device, b.buffer, b.memory, BIND));
    void *p;
    OK(vkMapMemory(device, b.memory, BIND, size, 0, &p));
    b.bytes = p;
    memset(b.bytes, 0, size);
    return b;
}
static VkImageView image(VkFormat format, VkImageUsageFlags usage, VkImageAspectFlags aspect, VkImage *out) {
    VkImageCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = format, .extent = {W, H, 1}, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = usage, .sharingMode = VK_SHARING_MODE_EXCLUSIVE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
    OK(vkCreateImage(device, &ci, NULL, out));
    VkMemoryRequirements r;
    vkGetImageMemoryRequirements(device, *out, &r);
    VkMemoryAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = r.size, .memoryTypeIndex = 0};
    VkDeviceMemory memory;
    OK(vkAllocateMemory(device, &ai, NULL, &memory));
    OK(vkBindImageMemory(device, *out, memory, 0));
    VkImageViewCreateInfo vi = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = *out, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = format, .subresourceRange = {aspect, 0, 1, 0, 1}};
    VkImageView view;
    OK(vkCreateImageView(device, &vi, NULL, &view));
    return view;
}
static VkShaderModule shader(const char *name) {
    char path[1024];
    REQUIRE(getenv("T_VK_SPV"));
    snprintf(path, sizeof path, "%s/%s.spv", getenv("T_VK_SPV"), name);
    FILE *f = fopen(path, "rb"); REQUIRE(f);
    REQUIRE(fseek(f, 0, SEEK_END) == 0);
    long n = ftell(f); REQUIRE(n > 0 && n % 4 == 0);
    rewind(f);
    uint32_t *words = malloc((size_t)n); REQUIRE(words);
    REQUIRE(fread(words, 1, (size_t)n, f) == (size_t)n); REQUIRE(fclose(f) == 0);
    VkShaderModuleCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = (size_t)n, .pCode = words};
    VkShaderModule module;
    OK(vkCreateShaderModule(device, &ci, NULL, &module));
    free(words);
    return module;
}
static void setup(void) {
    vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)dm_vk_lookup("vkGetInstanceProcAddr");
    REQUIRE(vkGetInstanceProcAddr && (void *)vkGetInstanceProcAddr == registered("vkGetInstanceProcAddr"));
    vkCreateInstance = (PFN_vkCreateInstance)vkGetInstanceProcAddr(VK_NULL_HANDLE, "vkCreateInstance");
    REQUIRE(vkCreateInstance && (void *)vkCreateInstance == registered("vkCreateInstance"));
    VkApplicationInfo application = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "S2Arm AMD indirect count GPU regression", .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &application};
    OK(vkCreateInstance(&ici, NULL, &instance));
#define LOAD(n) n = (PFN_##n)vkGetInstanceProcAddr(instance, #n); REQUIRE(n); REQUIRE((void *)n == registered(#n));
    APIS(LOAD)
#undef LOAD
    uint32_t n = 1; VkPhysicalDevice physical;
    OK(vkEnumeratePhysicalDevices(instance, &n, &physical)); REQUIRE(n == 1);
    // VK_AMD_draw_indirect_count / multiDrawIndirect are not advertised (hle_vk.m: Hades stops at its title when they are), the entry points are still registered
    float priority = 1;
    VkDeviceQueueCreateInfo qi = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &priority};
    VkPhysicalDeviceFeatures available;
    vkGetPhysicalDeviceFeatures(physical, &available);
    REQUIRE(!available.multiDrawIndirect && available.drawIndirectFirstInstance && available.occlusionQueryPrecise);
    VkPhysicalDeviceFeatures enabled = {.drawIndirectFirstInstance = VK_TRUE, .occlusionQueryPrecise = VK_TRUE};
    VkDeviceCreateInfo di = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qi, .pEnabledFeatures = &enabled};
    OK(vkCreateDevice(physical, &di, NULL, &device));
#define DEVICE_CHECK(n) REQUIRE(vkGetDeviceProcAddr(device, #n) == (PFN_vkVoidFunction)n);
    DEVICE_CHECK(vkCmdDrawIndirectCountAMD) DEVICE_CHECK(vkCmdDrawIndexedIndirectCountAMD)
    DEVICE_CHECK(vkCmdDrawIndirect) DEVICE_CHECK(vkCmdDrawIndexedIndirect)
    REQUIRE(vkGetInstanceProcAddr(instance, "vkCmdDrawIndirectCountAMD") == (PFN_vkVoidFunction)vkCmdDrawIndirectCountAMD);
    REQUIRE(vkGetInstanceProcAddr(instance, "vkCmdDrawIndexedIndirectCountAMD") == (PFN_vkVoidFunction)vkCmdDrawIndexedIndirectCountAMD);
    vkGetDeviceQueue(device, 0, 0, &queue);
    VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = 0};
    OK(vkCreateCommandPool(device, &pci, NULL, &commandPool));
    VkCommandBufferAllocateInfo cai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = commandPool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    OK(vkAllocateCommandBuffers(device, &cai, &cb));
    VkQueryPoolCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_OCCLUSION, .queryCount = 2};
    OK(vkCreateQueryPool(device, &qci, NULL, &query));
    VkImage depth;
    VkImageView views[] = {image(VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, VK_IMAGE_ASPECT_COLOR_BIT, &color), image(VK_FORMAT_D32_SFLOAT, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, VK_IMAGE_ASPECT_DEPTH_BIT, &depth)};
    VkAttachmentDescription attachments[] = {
        {.format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL},
        {.format = VK_FORMAT_D32_SFLOAT, .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL}};
    VkAttachmentReference cr = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL}, dr = {1, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sub = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &cr, .pDepthStencilAttachment = &dr};
    // Discarding old contents (UNDEFINED) does not remove the write-after-write
    // dependency when two consecutive passes reuse the same attachments.
    VkPipelineStageFlags attachmentStages = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
    VkSubpassDependency dependency = {.srcSubpass = VK_SUBPASS_EXTERNAL, .dstSubpass = 0, .srcStageMask = attachmentStages, .dstStageMask = attachmentStages,
        .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT};
    VkSubpassDependency dependencies[] = {dependency, {.srcSubpass = 0, .dstSubpass = VK_SUBPASS_EXTERNAL,
        .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, .dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT,
        .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT},
        {.srcSubpass = 0, .dstSubpass = 0, .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
         .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .dependencyFlags = VK_DEPENDENCY_BY_REGION_BIT},
        {.srcSubpass = 0, .dstSubpass = 0, .srcStageMask = VK_PIPELINE_STAGE_VERTEX_SHADER_BIT, .dstStageMask = VK_PIPELINE_STAGE_VERTEX_SHADER_BIT, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT},
        {.srcSubpass = 0, .dstSubpass = 0, .srcStageMask = VK_PIPELINE_STAGE_VERTEX_SHADER_BIT, .dstStageMask = VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT, .dstAccessMask = VK_ACCESS_INDIRECT_COMMAND_READ_BIT}};
    VkRenderPassCreateInfo rpi = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 2, .pAttachments = attachments, .subpassCount = 1, .pSubpasses = &sub, .dependencyCount = 5, .pDependencies = dependencies};
    OK(vkCreateRenderPass(device, &rpi, NULL, &pass));
    VkFramebufferCreateInfo fi = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = pass, .attachmentCount = 2, .pAttachments = views, .width = W, .height = H, .layers = 1};
    OK(vkCreateFramebuffer(device, &fi, NULL, &fb));
    VkPipelineLayoutCreateInfo li = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    VkPipelineLayout layout; OK(vkCreatePipelineLayout(device, &li, NULL, &layout));
    VkPipelineShaderStageCreateInfo stages[] = {{.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = shader("tri.vert"), .pName = "main"}, {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = shader("tri.frag"), .pName = "main"}};
    VkPipelineVertexInputStateCreateInfo vertex = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    VkPipelineInputAssemblyStateCreateInfo assembly = {.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
    VkPipelineViewportStateCreateInfo viewport = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1};
    VkPipelineRasterizationStateCreateInfo raster = {.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1};
    VkPipelineMultisampleStateCreateInfo ms = {.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
    VkPipelineDepthStencilStateCreateInfo ds = {.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, .depthTestEnable = VK_TRUE, .depthWriteEnable = VK_TRUE, .depthCompareOp = VK_COMPARE_OP_LESS};
    VkPipelineColorBlendAttachmentState blendAttachment = {.colorWriteMask = 15};
    VkPipelineColorBlendStateCreateInfo blend = {.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &blendAttachment};
    VkDynamicState dynamicStates[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamic = {.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2, .pDynamicStates = dynamicStates};
    VkGraphicsPipelineCreateInfo pi = {.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2, .pStages = stages, .pVertexInputState = &vertex, .pInputAssemblyState = &assembly, .pViewportState = &viewport, .pRasterizationState = &raster, .pMultisampleState = &ms, .pDepthStencilState = &ds, .pColorBlendState = &blend, .pDynamicState = &dynamic, .layout = layout, .renderPass = pass};
    OK(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pi, NULL, &pipeline));
    args = buffer(256, VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    count = buffer(256, VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    stagingArgs = buffer(256, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    stagingCount = buffer(256, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    indices16 = buffer(256, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
    indices32 = buffer(256, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
    // Three commands have firstIndex 2, 5, 8; -6 turns indices 15..23 into vertices 9..17.
    uint16_t ix16[] = {0, 0, 15, 16, 17, 18, 19, 20, 21, 22, 23};
    uint32_t ix32[] = {0, 0, 15, 16, 17, 18, 19, 20, 21, 22, 23};
    memcpy(indices16.bytes + INDEX_OFF, ix16, sizeof ix16);
    memcpy(indices32.bytes + INDEX_OFF, ix32, sizeof ix32);
    readback = buffer(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
}

typedef struct { const char *name; uint32_t count, max, expected; int indexed, gpu_copy, preserve, core; } Case;
static uint64_t render(const Case *test, int indirect, uint8_t pixels[W * H * 4], uint64_t *earlierSamples) {
    memset(args.bytes, 0, 256); memset(count.bytes, 0, 256);
    memset(stagingArgs.bytes, 0, 256); memset(stagingCount.bytes, 0, 256);
    for (uint32_t i = 0; i < 3; ++i) {
        if (test->indexed) {
            VkDrawIndexedIndirectCommand command = {3, 1, 2 + 3 * i, -6, 1 + i};
            memcpy(stagingArgs.bytes + ARG_OFF + STRIDE * i, &command, sizeof command);
        } else {
            VkDrawIndirectCommand command = {3, 1, 9 + 3 * i, 1 + i};
            memcpy(stagingArgs.bytes + ARG_OFF + STRIDE * i, &command, sizeof command);
        }
    }
    memcpy(stagingCount.bytes + COUNT_OFF, &test->count, 4);
    if (!test->gpu_copy) { memcpy(args.bytes, stagingArgs.bytes, 256); memcpy(count.bytes, stagingCount.bytes, 256); }
    OK(vkResetCommandBuffer(cb, 0));
    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    OK(vkBeginCommandBuffer(cb, &bi));
    vkCmdResetQueryPool(cb, query, 0, 2);
    if (test->gpu_copy) {
        VkBufferCopy ac = {ARG_OFF, ARG_OFF, STRIDE * 3}, cc = {COUNT_OFF, COUNT_OFF, 4};
        vkCmdCopyBuffer(cb, stagingArgs.buffer, args.buffer, 1, &ac);
        vkCmdCopyBuffer(cb, stagingCount.buffer, count.buffer, 1, &cc);
        VkMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_INDIRECT_COMMAND_READ_BIT};
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT, 0, 1, &barrier, 0, NULL, 0, NULL);
    }
    uint32_t passes = earlierSamples ? 2 : 1;
    for (uint32_t p = 0; p < passes; ++p) {
        VkClearValue clear[] = {{{{0, 0, 0, 1}}}, {.depthStencil = {1, 0}}};
        VkRenderPassBeginInfo ri = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = pass, .framebuffer = fb, .renderArea = {{0, 0}, {W, H}}, .clearValueCount = 2, .pClearValues = clear};
        vkCmdBeginRenderPass(cb, &ri, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        VkViewport vp = {8, 8, 48, 48, 0, 1}; VkRect2D sc = {{12, 12}, {40, 36}};
        vkCmdSetViewport(cb, 0, 1, &vp); vkCmdSetScissor(cb, 0, 1, &sc);
        vkCmdBindIndexBuffer(cb, test->indexed == 32 ? indices32.buffer : indices16.buffer, INDEX_OFF, test->indexed == 32 ? VK_INDEX_TYPE_UINT32 : VK_INDEX_TYPE_UINT16);
        vkCmdBeginQuery(cb, query, p, VK_QUERY_CONTROL_PRECISE_BIT);
        vkCmdDraw(cb, 3, 1, 0, 1); // top-left tile, before any render-encoder split
        if (test->preserve) vkCmdDraw(cb, 3, 1, 27, 3); // nearer blue blocks the later red middle-left tile
        if (indirect) {
            if (test->core && test->indexed) vkCmdDrawIndexedIndirect(cb, args.buffer, ARG_OFF, test->expected, STRIDE);
            else if (test->core) vkCmdDrawIndirect(cb, args.buffer, ARG_OFF, test->expected, STRIDE);
            else if (test->indexed) vkCmdDrawIndexedIndirectCountAMD(cb, args.buffer, ARG_OFF, count.buffer, COUNT_OFF, test->max, STRIDE);
            else vkCmdDrawIndirectCountAMD(cb, args.buffer, ARG_OFF, count.buffer, COUNT_OFF, test->max, STRIDE);
        } else {
            // Explicit expected count comes from the test table, independently of count-buffer handling.
            for (uint32_t i = 0; i < test->expected; ++i)
                if (test->indexed) vkCmdDrawIndexed(cb, 3, 1, 2 + 3 * i, -6, 1 + i);
                else vkCmdDraw(cb, 3, 1, 9 + 3 * i, 1 + i);
        }
        vkCmdDraw(cb, 3, 1, 24, 3); // bottom-right tile, state must survive the split
        vkCmdEndQuery(cb, query, p);
        vkCmdEndRenderPass(cb);
    }
    VkMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &barrier, 0, NULL, 0, NULL);
    VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {W, H, 1}};
    vkCmdCopyImageToBuffer(cb, color, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.buffer, 1, &copy);
    VkMemoryBarrier host = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &host, 0, NULL, 0, NULL);
    OK(vkEndCommandBuffer(cb));
    VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
    OK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE)); OK(vkQueueWaitIdle(queue));
    memcpy(pixels, readback.bytes, W * H * 4);
    uint64_t samples = 0;
    OK(vkGetQueryPoolResults(device, query, passes - 1, 1, sizeof samples, &samples, sizeof samples, VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT));
    REQUIRE(samples > 0);
    if (earlierSamples) {
        OK(vkGetQueryPoolResults(device, query, 0, 1, sizeof *earlierSamples, earlierSamples, sizeof *earlierSamples, VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT));
        REQUIRE(*earlierSamples > 0);
    }
    return samples;
}
static void pixel(const uint8_t *pixels, int x, int y, int r, int g, int b) {
    const uint8_t *p = pixels + 4 * (y * W + x);
    if (p[0] != r || p[1] != g || p[2] != b || p[3] != 255) {
        fprintf(stderr, "FAIL pixel (%d,%d): got %u,%u,%u,%u expected %d,%d,%d,255\n", x, y, p[0], p[1], p[2], p[3], r, g, b); exit(1);
    }
}
enum { BATCH_COUNT = 3, BATCH_ARG_BYTES = 1024, BATCH_COUNT_BYTES = 128 };
static Buffer batchArgs, batchCounts, batchSourceArgs, batchSourceCounts, batchIndices[2], batchOutput[BATCH_COUNT];
static VkCommandBuffer batchCommands[BATCH_COUNT], producer;
static VkImage batchColor[BATCH_COUNT];
static VkFramebuffer batchFrames[BATCH_COUNT];
static VkQueryPool batchQueries;
static const uint32_t batchValues[BATCH_COUNT][4] = {{1, 7, 0, 2}, {2, 0, 1, 1}, {0, 1, 3, 0}};
// These explicit direct draw counts are the independent expected results.
static const uint32_t batchExpected[BATCH_COUNT][4] = {{1, 2, 0, 2}, {2, 0, 1, 1}, {0, 1, 3, 0}};
static const uint32_t batchMax[] = {2, 2, 3, 2};
static const uint32_t batchFirstTile[] = {0, 3, 5, 7};
static const uint32_t batchFirstColor[] = {1, 2, 3, 3};
static const int batchIndexed[] = {0, 16, 0, 32};
typedef struct { uint64_t encoders, buffers, bytes; } MetalStats;
static MetalStats metal_stats(void) {
    MetalStats s; dm_vk_indirect_stats(&s.encoders, &s.buffers, &s.bytes); return s;
}
static void metal_delta(const char *name, MetalStats before, unsigned encoders, unsigned buffers, unsigned minBytes) {
    MetalStats after = metal_stats();
    printf("  %s actual Metal render encoders=%llu scratch buffers=%llu scratch bytes=%llu\n", name,
           (unsigned long long)(after.encoders - before.encoders), (unsigned long long)(after.buffers - before.buffers), (unsigned long long)(after.bytes - before.bytes));
    REQUIRE(after.encoders - before.encoders == encoders);
    REQUIRE(after.buffers - before.buffers == buffers);
    REQUIRE(after.bytes - before.bytes >= minBytes);
    if (!buffers) REQUIRE(after.bytes == before.bytes);
}
static void batch_setup(void) {
    batchArgs = buffer(BATCH_COUNT * BATCH_ARG_BYTES, VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    batchCounts = buffer(BATCH_COUNT * BATCH_COUNT_BYTES, VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    batchSourceArgs = buffer(BATCH_COUNT * BATCH_ARG_BYTES, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    batchSourceCounts = buffer(BATCH_COUNT * BATCH_COUNT_BYTES, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    batchIndices[0] = buffer(256, VK_BUFFER_USAGE_INDEX_BUFFER_BIT); batchIndices[1] = buffer(256, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
    uint16_t ix16[29] = {0}; uint32_t ix32[29] = {0};
    for (uint32_t i = 0; i < 27; ++i) ix16[i + 2] = (uint16_t)(i + 6), ix32[i + 2] = i + 6;
    memcpy(batchIndices[0].bytes + INDEX_OFF, ix16, sizeof ix16); memcpy(batchIndices[1].bytes + INDEX_OFF, ix32, sizeof ix32);
    VkCommandBufferAllocateInfo ca = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = commandPool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = BATCH_COUNT};
    OK(vkAllocateCommandBuffers(device, &ca, batchCommands)); ca.commandBufferCount = 1; OK(vkAllocateCommandBuffers(device, &ca, &producer));
    VkQueryPoolCreateInfo qi = {.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_OCCLUSION, .queryCount = BATCH_COUNT};
    OK(vkCreateQueryPool(device, &qi, NULL, &batchQueries));
    for (unsigned i = 0; i < BATCH_COUNT; ++i) {
        VkImage depth;
        VkImageView views[] = {image(VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, VK_IMAGE_ASPECT_COLOR_BIT, &batchColor[i]), image(VK_FORMAT_D32_SFLOAT, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, VK_IMAGE_ASPECT_DEPTH_BIT, &depth)};
        VkFramebufferCreateInfo fi = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = pass, .attachmentCount = 2, .pAttachments = views, .width = W, .height = H, .layers = 1};
        OK(vkCreateFramebuffer(device, &fi, NULL, &batchFrames[i]));
        batchOutput[i] = buffer(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    }
}
static void batch_prepare(int gpuCopy) {
    memset(batchSourceArgs.bytes, 0, BATCH_COUNT * BATCH_ARG_BYTES); memset(batchSourceCounts.bytes, 0, BATCH_COUNT * BATCH_COUNT_BYTES);
    for (unsigned owner = 0; owner < BATCH_COUNT; ++owner) for (unsigned g = 0; g < 4; ++g) {
        memcpy(batchSourceCounts.bytes + owner * BATCH_COUNT_BYTES + COUNT_OFF + 16 * g, &batchValues[owner][g], 4);
        for (uint32_t j = 0; j < batchMax[g]; ++j) {
            unsigned tile = batchFirstTile[g] + j, color = (batchFirstColor[g] - 1 + j) % 3 + 1;
            uint8_t *destination = batchSourceArgs.bytes + owner * BATCH_ARG_BYTES + ARG_OFF + 256 * g + STRIDE * j;
            if (batchIndexed[g]) {
                VkDrawIndexedIndirectCommand draw = {3, 1, 2 + 3 * tile, -6, color}; memcpy(destination, &draw, sizeof draw);
            } else {
                VkDrawIndirectCommand draw = {3, 1, 3 * tile, color}; memcpy(destination, &draw, sizeof draw);
            }
        }
    }
    if (gpuCopy) { memset(batchArgs.bytes, 0, BATCH_COUNT * BATCH_ARG_BYTES); memset(batchCounts.bytes, 0, BATCH_COUNT * BATCH_COUNT_BYTES); }
    else { memcpy(batchArgs.bytes, batchSourceArgs.bytes, BATCH_COUNT * BATCH_ARG_BYTES); memcpy(batchCounts.bytes, batchSourceCounts.bytes, BATCH_COUNT * BATCH_COUNT_BYTES); }
}
static void batch_begin_pass(VkCommandBuffer command, unsigned owner) {
    VkClearValue clear[] = {{{{0, 0, 0, 1}}}, {.depthStencil = {1, 0}}};
    VkRenderPassBeginInfo ri = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = pass, .framebuffer = batchFrames[owner], .renderArea = {{0, 0}, {W, H}}, .clearValueCount = 2, .pClearValues = clear};
    vkCmdBeginRenderPass(command, &ri, VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    VkViewport viewport = {8, 8, 48, 48, 0, 1}; VkRect2D scissor = {{0, 0}, {W, H}};
    vkCmdSetViewport(command, 0, 1, &viewport); vkCmdSetScissor(command, 0, 1, &scissor);
}
static void batch_seed_and_copy(VkCommandBuffer command) {
    batch_begin_pass(command, 0); vkCmdDraw(command, 3, 1, 24, 3); vkCmdEndRenderPass(command);
    // These copies are outside the render pass. The following pass must mask
    // after their GPU writes, even when they were recorded in another CB.
    VkBufferCopy argsCopy = {0, 0, BATCH_ARG_BYTES}, countCopy = {0, 0, BATCH_COUNT_BYTES};
    vkCmdCopyBuffer(command, batchSourceArgs.buffer, batchArgs.buffer, 1, &argsCopy);
    vkCmdCopyBuffer(command, batchSourceCounts.buffer, batchCounts.buffer, 1, &countCopy);
    VkMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_INDIRECT_COMMAND_READ_BIT};
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT, 0, 1, &barrier, 0, NULL, 0, NULL);
}
static void dependency_chain(VkCommandBuffer command) {
    VkMemoryBarrier available = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT};
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_VERTEX_SHADER_BIT, VK_PIPELINE_STAGE_VERTEX_SHADER_BIT, 0, 1, &available, 0, NULL, 0, NULL);
    VkMemoryBarrier visible = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_INDIRECT_COMMAND_READ_BIT};
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_VERTEX_SHADER_BIT, VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT, 0, 1, &visible, 0, NULL, 0, NULL);
}
static void batch_record(VkCommandBuffer command, unsigned owner, int indirect, int previousPass) {
    OK(vkResetCommandBuffer(command, 0)); VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; OK(vkBeginCommandBuffer(command, &bi));
    if (previousPass) batch_seed_and_copy(command);
    dependency_chain(command); // Outside a render pass: must not reject later count draws.
    vkCmdResetQueryPool(command, batchQueries, owner, 1); batch_begin_pass(command, owner);
    vkCmdBeginQuery(command, batchQueries, owner, VK_QUERY_CONTROL_PRECISE_BIT);
    for (unsigned g = 0; g < 4; ++g) {
        if (batchIndexed[g]) vkCmdBindIndexBuffer(command, batchIndices[batchIndexed[g] == 32].buffer, INDEX_OFF, batchIndexed[g] == 32 ? VK_INDEX_TYPE_UINT32 : VK_INDEX_TYPE_UINT16);
        if (indirect) {
            VkDeviceSize argsOffset = owner * BATCH_ARG_BYTES + ARG_OFF + 256 * g, countOffset = owner * BATCH_COUNT_BYTES + COUNT_OFF + 16 * g;
            if (batchIndexed[g]) vkCmdDrawIndexedIndirectCountAMD(command, batchArgs.buffer, argsOffset, batchCounts.buffer, countOffset, batchMax[g], STRIDE);
            else vkCmdDrawIndirectCountAMD(command, batchArgs.buffer, argsOffset, batchCounts.buffer, countOffset, batchMax[g], STRIDE);
        } else for (uint32_t j = 0; j < batchExpected[owner][g]; ++j) {
            unsigned tile = batchFirstTile[g] + j, color = (batchFirstColor[g] - 1 + j) % 3 + 1;
            if (batchIndexed[g]) vkCmdDrawIndexed(command, 3, 1, 2 + 3 * tile, -6, color);
            else vkCmdDraw(command, 3, 1, 3 * tile, color);
        }
        if (!g) {
            VkMemoryBarrier attachment = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT};
            vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_DEPENDENCY_BY_REGION_BIT, 1, &attachment, 0, NULL, 0, NULL);
        }
    }
    dependency_chain(command); // No later nonzero count draw: must not reject earlier draws.
    vkCmdDrawIndirectCountAMD(command, batchArgs.buffer, owner * BATCH_ARG_BYTES + ARG_OFF, batchCounts.buffer, owner * BATCH_COUNT_BYTES + COUNT_OFF, 0, STRIDE);
    vkCmdEndQuery(command, batchQueries, owner); vkCmdEndRenderPass(command);
    VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {W, H, 1}};
    vkCmdCopyImageToBuffer(command, batchColor[owner], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, batchOutput[owner].buffer, 1, &copy);
    VkMemoryBarrier host = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT};
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &host, 0, NULL, 0, NULL); OK(vkEndCommandBuffer(command));
}
enum { SINGLE_PASS, MULTI_CB, MULTI_INFO, MULTI_SUBMIT, PREVIOUS_PASS_COPY, PREVIOUS_CB_COPY };
static void batch_submit(unsigned number, int mode) {
    VkSubmitInfo infos[BATCH_COUNT];
    for (unsigned i = 0; i < number; ++i) infos[i] = (VkSubmitInfo){.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &batchCommands[i]};
    if (mode == PREVIOUS_CB_COPY) {
        VkCommandBuffer pair[] = {producer, batchCommands[0]}; infos[0].commandBufferCount = 2; infos[0].pCommandBuffers = pair;
        OK(vkQueueSubmit(queue, 1, infos, VK_NULL_HANDLE));
    } else if (mode == MULTI_CB) { infos[0].commandBufferCount = number; infos[0].pCommandBuffers = batchCommands; OK(vkQueueSubmit(queue, 1, infos, VK_NULL_HANDLE)); }
    else if (mode == MULTI_INFO) OK(vkQueueSubmit(queue, number, infos, VK_NULL_HANDLE));
    else for (unsigned i = 0; i < number; ++i) OK(vkQueueSubmit(queue, 1, &infos[i], VK_NULL_HANDLE));
    // In MULTI_SUBMIT no idle wait separates the queue submissions.
    OK(vkQueueWaitIdle(queue));
}
static void batch_test(const char *name, int mode) {
    unsigned number = mode == MULTI_CB || mode == MULTI_INFO || mode == MULTI_SUBMIT ? BATCH_COUNT : 1;
    uint8_t baseline[BATCH_COUNT][W * H * 4]; uint64_t baselineQueries[BATCH_COUNT];
    for (int indirect = 0; indirect < 2; ++indirect) {
        int copied = mode == PREVIOUS_PASS_COPY || mode == PREVIOUS_CB_COPY; batch_prepare(copied);
        if (mode == PREVIOUS_CB_COPY) {
            OK(vkResetCommandBuffer(producer, 0)); VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; OK(vkBeginCommandBuffer(producer, &bi));
            batch_seed_and_copy(producer); OK(vkEndCommandBuffer(producer));
        }
        for (unsigned i = 0; i < number; ++i) batch_record(batchCommands[i], i, indirect, mode == PREVIOUS_PASS_COPY);
        MetalStats before = metal_stats(); batch_submit(number, mode);
        unsigned renderCount = number + (copied ? 1 : 0), scratchCount = indirect ? (mode == MULTI_SUBMIT ? number : 1) : 0;
        metal_delta(name, before, renderCount, scratchCount, indirect ? 160 * number : 0);
        for (unsigned i = 0; i < number; ++i) {
            uint64_t samples; OK(vkGetQueryPoolResults(device, batchQueries, i, 1, sizeof samples, &samples, sizeof samples, VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT)); REQUIRE(samples > 0);
            if (!indirect) { memcpy(baseline[i], batchOutput[i].bytes, sizeof baseline[i]); baselineQueries[i] = samples; }
            else {
                REQUIRE(!memcmp(baseline[i], batchOutput[i].bytes, sizeof baseline[i])); REQUIRE(samples == baselineQueries[i]);
                // Explicit hand-calculated tile colours, independent of counts.
                static const uint8_t tiles[BATCH_COUNT][9] = {{1, 0, 0, 2, 3, 0, 0, 3, 1}, {1, 2, 0, 0, 0, 3, 0, 3, 0}, {0, 0, 0, 2, 0, 3, 1, 2, 0}};
                for (unsigned tile = 0; tile < 9; ++tile) {
                    unsigned color = tiles[i][tile]; pixel(batchOutput[i].bytes, 16 + 16 * (tile % 3), 16 + 16 * (tile / 3), color == 1 ? 255 : 0, color == 2 ? 255 : 0, color == 3 ? 255 : 0);
                }
                pixel(batchOutput[i].bytes, 2, 2, 0, 0, 0);
            }
        }
    }
    printf("PASS %s: separate offsets/counts/args, exact GPU direct baseline and occlusion, actual Metal creation counters\n", name);
}
static void rejected_dependency(void) {
    batch_setup(); batch_prepare(0);
    uint64_t beforeFeature, beforeError, feature, error; dm_vk_bad_draws(&beforeFeature, &beforeError);
    OK(vkResetCommandBuffer(cb, 0)); VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; OK(vkBeginCommandBuffer(cb, &bi));
    batch_begin_pass(cb, 0); vkCmdDraw(cb, 3, 1, 0, 1);
    dependency_chain(cb);
    vkCmdDrawIndirectCountAMD(cb, batchArgs.buffer, ARG_OFF, batchCounts.buffer, COUNT_OFF, 0, STRIDE);
    vkCmdDrawIndirectCountAMD(cb, batchArgs.buffer, ARG_OFF, batchCounts.buffer, COUNT_OFF, 1, STRIDE);
    vkCmdEndRenderPass(cb); OK(vkEndCommandBuffer(cb));
    VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb}; OK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE)); OK(vkQueueWaitIdle(queue));
    dm_vk_bad_draws(&feature, &error); REQUIRE(feature == beforeFeature && error == beforeError + 1);
    puts("PASS legal dependency chain conservatively rejected once; max0 does not report an error");
}
static void dependency_child(const char *executable) {
    FILE *log = tmpfile(); REQUIRE(log); fflush(stdout); fflush(stderr);
    pid_t child = fork(); REQUIRE(child >= 0);
    if (!child) {
        if (dup2(fileno(log), STDOUT_FILENO) < 0 || dup2(fileno(log), STDERR_FILENO) < 0) _exit(126);
        execl(executable, executable, "--reject-dependency", (char *)NULL); _exit(127);
    }
    int status; REQUIRE(waitpid(child, &status, 0) == child);
    REQUIRE(fseek(log, 0, SEEK_END) == 0); long size = ftell(log); REQUIRE(size >= 0); rewind(log);
    char *text = calloc((size_t)size + 1, 1); REQUIRE(text); REQUIRE(fread(text, 1, (size_t)size, log) == (size_t)size); REQUIRE(fclose(log) == 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status)) { fputs(text, stderr); REQUIRE(WIFEXITED(status) && WEXITSTATUS(status) == 0); }
    REQUIRE(strstr(text, "【红】 indirect draw: count draw after an in-pass shader-write dependency or copy is unsupported"));
    REQUIRE(strstr(text, "PASS legal dependency chain conservatively rejected once")); free(text);
    puts("PASS dependency-rejection child: legal self-dependencies and explicit unsupported diagnostic; no claim of actual shader writes");
}
int main(int argc, char **argv) {
    setup();
    if (argc == 2 && !strcmp(argv[1], "--reject-dependency")) { rejected_dependency(); return 0; }
    int failures = 0;
    const Case cases[] = {
        {"array-count0", 0, 3, 0, 0, 0, 0, 0}, {"array-count1", 1, 3, 1, 0, 0, 0, 0},
        {"array-clamp", 9, 2, 2, 0, 0, 0, 0}, {"array-max0", 3, 0, 0, 0, 0, 0, 0},
        {"index16-count0", 0, 3, 0, 16, 0, 0, 0}, {"index16-count1", 1, 3, 1, 16, 0, 0, 0},
        {"index16-clamp", 9, 2, 2, 16, 0, 0, 0}, {"index16-max0", 3, 0, 0, 16, 0, 0, 0},
        {"index32-count1", 1, 3, 1, 32, 0, 0, 0}, {"index32-clamp", 9, 2, 2, 32, 0, 0, 0},
        {"array-GPU-copy", 3, 3, 3, 0, 1, 0, 0}, {"index16-GPU-copy", 3, 3, 3, 16, 1, 0, 0}, {"index32-GPU-copy", 3, 3, 3, 32, 1, 0, 0},
        {"array-preserve-depth", 3, 3, 3, 0, 1, 1, 0}, {"index32-preserve-depth", 3, 3, 3, 32, 1, 1, 0},
        {"core-array-GPU-copy", 3, 3, 3, 0, 1, 0, 1}, {"core-index32-GPU-copy", 3, 3, 3, 32, 1, 0, 1}};
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; ++i) {
        uint8_t baseline[W * H * 4], actual[W * H * 4];
        uint64_t baselineSamples = render(&cases[i], 0, baseline, NULL), actualSamples = render(&cases[i], 1, actual, NULL);
        if (memcmp(baseline, actual, sizeof actual)) {
            size_t differences = 0; for (size_t j = 0; j < sizeof actual; ++j) differences += baseline[j] != actual[j];
            fprintf(stderr, "FAIL %s: %zu differing channel bytes against direct GPU baseline\n", cases[i].name, differences); return 1;
        }
        // Centers map to x=16,32,48 and y=16,32,48 through the 48x48 viewport.
        // The final row's center y=48 lies outside scissor; sample its triangle at y=46.
        pixel(actual, 16, 16, 255, 0, 0); pixel(actual, 48, 46, 0, 0, 255);
        pixel(actual, 8, 16, 0, 0, 0); pixel(actual, 48, 48, 0, 0, 0);
        if (cases[i].preserve) pixel(actual, 16, 32, 0, 0, 255);
        else pixel(actual, 16, 32, cases[i].expected > 0 ? 255 : 0, 0, 0);
        pixel(actual, 32, 32, 0, cases[i].expected > 1 ? 255 : 0, 0);
        pixel(actual, 48, 32, 0, 0, cases[i].expected > 2 ? 255 : 0);
        if (baselineSamples != actualSamples) {
            fprintf(stderr, "FAIL %s: pixels exact; occlusion direct=%llu indirect=%llu\n", cases[i].name, (unsigned long long)baselineSamples, (unsigned long long)actualSamples);
            failures++;
            continue;
        }
        printf("PASS %s: exact 64x64 RGBA direct baseline, hand-calculated pixels, occlusion=%llu\n", cases[i].name, (unsigned long long)actualSamples);
    }
    // Independent queries in consecutive render passes share one VkQueueSubmit.
    // The second pass must not clear the first pass's visibility results.
    Case twoPass = {"two-pass-query", 3, 3, 3, 0, 1, 0, 0};
    uint8_t baseline[W * H * 4], actual[W * H * 4];
    uint64_t baselineFirst, actualFirst;
    uint64_t baselineLast = render(&twoPass, 0, baseline, &baselineFirst);
    uint64_t actualLast = render(&twoPass, 1, actual, &actualFirst);
    REQUIRE(memcmp(baseline, actual, sizeof actual) == 0);
    REQUIRE(baselineFirst == baselineLast && actualFirst == baselineFirst && actualLast == baselineLast);
    printf("PASS two-pass-query: independent query0=%llu query1=%llu in one submit, exact RGBA direct baseline\n", (unsigned long long)actualFirst, (unsigned long long)actualLast);
    REQUIRE(failures == 0);
    batch_setup();
    batch_test("multi-count-one-pass", SINGLE_PASS); batch_test("three-command-buffers", MULTI_CB); batch_test("three-submit-infos", MULTI_INFO);
    batch_test("pending-queue-submits", MULTI_SUBMIT); batch_test("previous-pass-GPU-copy", PREVIOUS_PASS_COPY); batch_test("previous-command-buffer-GPU-copy", PREVIOUS_CB_COPY);
    uint64_t feature, error; dm_vk_bad_draws(&feature, &error); REQUIRE(feature == 0 && error == 0);
    dependency_child(argv[0]);
    puts("✓ t_vk_indirect_count：25 real Metal GPU cases; exact pixels/occlusion, encoder/scratch counts and legal dependency rejection");
    return 0;
}
