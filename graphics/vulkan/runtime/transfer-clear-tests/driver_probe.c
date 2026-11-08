// Standalone Vulkan driver probe; generated colors only, no application/game memory.
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#define OK(x)                                                     \
  do {                                                            \
    VkResult r = (x);                                             \
    if (r != VK_SUCCESS) {                                        \
      fprintf(stderr, "%s failed %d line %d\n", #x, r, __LINE__); \
      exit(2);                                                    \
    }                                                             \
  } while (0)
static VkPhysicalDevice pd;
static VkDevice d;
static VkQueue q;
static uint32_t family;
static uint32_t memtype(uint32_t bits, VkMemoryPropertyFlags flags) {
  VkPhysicalDeviceMemoryProperties p;
  vkGetPhysicalDeviceMemoryProperties(pd, &p);
  for (uint32_t i = 0; i < p.memoryTypeCount; i++)
    if ((bits & (1u << i)) && (p.memoryTypes[i].propertyFlags & flags) == flags)
      return i;
  fprintf(stderr, "no memory type\n");
  exit(2);
}
static VkShaderModule shader(const char* path) {
  FILE* f = fopen(path, "rb");
  if (!f)
    exit(2);
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  rewind(f);
  uint32_t* b = malloc(n);
  if (fread(b, 1, n, f) != (size_t)n)
    exit(2);
  fclose(f);
  VkShaderModuleCreateInfo ci = {
      .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = n, .pCode = b};
  VkShaderModule m;
  OK(vkCreateShaderModule(d, &ci, 0, &m));
  free(b);
  return m;
}
static void barrier(VkCommandBuffer c, VkImage image, VkImageLayout old, VkAccessFlags src,
                    VkAccessFlags dst) {
  VkImageMemoryBarrier b = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                            .srcAccessMask = src,
                            .dstAccessMask = dst,
                            .oldLayout = old,
                            .newLayout = VK_IMAGE_LAYOUT_GENERAL,
                            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                            .image = image,
                            .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
  vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0,
                       0, 0, 0, 0, 1, &b);
}
static int run(VkFormat format, VkShaderModule vert, VkShaderModule frag, int precise, int omit) {
  enum { W = 96, H = 80, N = 128 };
  int bpp = format == VK_FORMAT_R16G16B16A16_SFLOAT
                ? 8
                : (format == VK_FORMAT_R8_UNORM || format == VK_FORMAT_R8_UINT ? 1 : 4);
  int uint_format = format == VK_FORMAT_R8_UINT;
  VkFormatProperties props;
  vkGetPhysicalDeviceFormatProperties(pd, format, &props);
  if (!(props.optimalTilingFeatures & VK_FORMAT_FEATURE_TRANSFER_DST_BIT))
    return 2;
  VkImageCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                           .imageType = VK_IMAGE_TYPE_2D,
                           .format = format,
                           .extent = {W, H, 1},
                           .mipLevels = 1,
                           .arrayLayers = 1,
                           .samples = VK_SAMPLE_COUNT_1_BIT,
                           .tiling = VK_IMAGE_TILING_OPTIMAL,
                           .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                                    VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                                    VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                           .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
  VkImage im;
  OK(vkCreateImage(d, &ici, 0, &im));
  VkMemoryRequirements mr;
  vkGetImageMemoryRequirements(d, im, &mr);
  VkMemoryAllocateInfo mai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = mr.size,
      .memoryTypeIndex = memtype(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
  VkDeviceMemory mi;
  OK(vkAllocateMemory(d, &mai, 0, &mi));
  OK(vkBindImageMemory(d, im, mi, 0));
  VkImageViewCreateInfo vi = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                              .image = im,
                              .viewType = VK_IMAGE_VIEW_TYPE_2D,
                              .format = format,
                              .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
  VkImageView view;
  OK(vkCreateImageView(d, &vi, 0, &view));
  VkAttachmentDescription ad = {.format = format,
                                .samples = VK_SAMPLE_COUNT_1_BIT,
                                .loadOp = VK_ATTACHMENT_LOAD_OP_LOAD,
                                .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                                .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                                .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
                                .initialLayout = VK_IMAGE_LAYOUT_GENERAL,
                                .finalLayout = VK_IMAGE_LAYOUT_GENERAL};
  VkAttachmentReference ar = {0, VK_IMAGE_LAYOUT_GENERAL};
  VkSubpassDescription sd = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
                             .colorAttachmentCount = 1,
                             .pColorAttachments = &ar};
  VkRenderPassCreateInfo ri = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
                               .attachmentCount = 1,
                               .pAttachments = &ad,
                               .subpassCount = 1,
                               .pSubpasses = &sd};
  VkRenderPass rp;
  OK(vkCreateRenderPass(d, &ri, 0, &rp));
  VkFramebufferCreateInfo fi = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                                .renderPass = rp,
                                .attachmentCount = 1,
                                .pAttachments = &view,
                                .width = W,
                                .height = H,
                                .layers = 1};
  VkFramebuffer fb;
  OK(vkCreateFramebuffer(d, &fi, 0, &fb));
  VkPushConstantRange pc = {VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16};
  VkPipelineLayoutCreateInfo li = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
                                   .pushConstantRangeCount = 1,
                                   .pPushConstantRanges = &pc};
  VkPipelineLayout layout;
  OK(vkCreatePipelineLayout(d, &li, 0, &layout));
  VkPipelineShaderStageCreateInfo stages[2] = {
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
       .stage = VK_SHADER_STAGE_VERTEX_BIT,
       .module = vert,
       .pName = "main"},
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
       .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
       .module = frag,
       .pName = "main"}};
  VkPipelineVertexInputStateCreateInfo vin = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
  VkPipelineInputAssemblyStateCreateInfo ia = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
      .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
  VkViewport vp = {0, 0, W, H, 0, 1};
  VkRect2D sc = {{0, 0}, {W, H}};
  VkPipelineViewportStateCreateInfo vs = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
      .viewportCount = 1,
      .pViewports = &vp,
      .scissorCount = 1,
      .pScissors = &sc};
  VkPipelineRasterizationStateCreateInfo rs = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
      .polygonMode = VK_POLYGON_MODE_FILL,
      .cullMode = VK_CULL_MODE_NONE,
      .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE,
      .lineWidth = 1};
  VkPipelineMultisampleStateCreateInfo ms = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
      .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
  VkPipelineColorBlendAttachmentState ba = {.colorWriteMask = 15};
  VkPipelineColorBlendStateCreateInfo bs = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
      .attachmentCount = 1,
      .pAttachments = &ba};
  VkDynamicState dyn = VK_DYNAMIC_STATE_SCISSOR;
  VkPipelineDynamicStateCreateInfo ds = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
      .dynamicStateCount = 1,
      .pDynamicStates = &dyn};
  VkGraphicsPipelineCreateInfo pi = {.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
                                     .stageCount = 2,
                                     .pStages = stages,
                                     .pVertexInputState = &vin,
                                     .pInputAssemblyState = &ia,
                                     .pViewportState = &vs,
                                     .pRasterizationState = &rs,
                                     .pMultisampleState = &ms,
                                     .pColorBlendState = &bs,
                                     .pDynamicState = &ds,
                                     .layout = layout,
                                     .renderPass = rp};
  VkPipeline pipeline;
  OK(vkCreateGraphicsPipelines(d, VK_NULL_HANDLE, 1, &pi, 0, &pipeline));
  VkBufferCreateInfo bi = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                           .size = W * H * bpp * N,
                           .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
  VkBuffer buf;
  OK(vkCreateBuffer(d, &bi, 0, &buf));
  vkGetBufferMemoryRequirements(d, buf, &mr);
  mai.allocationSize = mr.size;
  mai.memoryTypeIndex = memtype(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                                       VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
  VkDeviceMemory mb;
  OK(vkAllocateMemory(d, &mai, 0, &mb));
  OK(vkBindBufferMemory(d, buf, mb, 0));
  void* mapped;
  OK(vkMapMemory(d, mb, 0, VK_WHOLE_SIZE, 0, &mapped));
  VkCommandPoolCreateInfo cpi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                 .queueFamilyIndex = family};
  VkCommandPool pool;
  OK(vkCreateCommandPool(d, &cpi, 0, &pool));
  VkCommandBufferAllocateInfo cai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                     .commandPool = pool,
                                     .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                                     .commandBufferCount = 1};
  VkCommandBuffer c;
  OK(vkAllocateCommandBuffers(d, &cai, &c));
  VkQueryPoolCreateInfo qi = {.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
                              .queryType = VK_QUERY_TYPE_OCCLUSION,
                              .queryCount = N};
  VkQueryPool queries;
  OK(vkCreateQueryPool(d, &qi, 0, &queries));
  VkCommandBufferBeginInfo cb = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
  OK(vkBeginCommandBuffer(c, &cb));
  barrier(c, im, VK_IMAGE_LAYOUT_UNDEFINED, 0,
          VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT);
  vkCmdResetQueryPool(c, queries, 0, N);
  VkRenderPassBeginInfo rb = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                              .renderPass = rp,
                              .framebuffer = fb,
                              .renderArea = {{0, 0}, {W, H}}};
  float red[] = {1, 0, 0, 1}, green[] = {0, 1, 0, 1};
  uint32_t red_uint[] = {255, 0, 0, 255}, green_uint[] = {0, 255, 0, 255};
  for (int i = 0; i < N; i++) {
    vkCmdBeginQuery(c, queries, i, precise ? VK_QUERY_CONTROL_PRECISE_BIT : 0);
    vkCmdBeginRenderPass(c, &rb, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    sc = (VkRect2D){{0, 0}, {W, H}};
    vkCmdSetScissor(c, 0, 1, &sc);
    vkCmdPushConstants(c, layout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16,
                       uint_format ? (void*)red_uint : (void*)red);
    vkCmdDraw(c, 3, 1, 0, 0);
    vkCmdEndRenderPass(c);
    barrier(c, im, VK_IMAGE_LAYOUT_GENERAL, VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
            VK_ACCESS_TRANSFER_WRITE_BIT);
    VkClearColorValue color = {.float32 = {i % 2 ? .5f : 0, 0, 1, 1}};
    if (format == VK_FORMAT_R16G16_SNORM)
      color.float32[0] = i % 2 ? -.5f : .25f;
    if (uint_format)
      color = (VkClearColorValue){.uint32 = {i % 2 ? 123 : 17, 0, 255, 255}};
    VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    if (!omit)
      vkCmdClearColorImage(c, im, VK_IMAGE_LAYOUT_GENERAL, &color, 1, &range);
    barrier(c, im, VK_IMAGE_LAYOUT_GENERAL, VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT);
    vkCmdBeginRenderPass(c, &rb, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    sc = (VkRect2D){{i % 16, i % 8}, {8, 8}};
    vkCmdSetScissor(c, 0, 1, &sc);
    vkCmdPushConstants(c, layout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16,
                       uint_format ? (void*)green_uint : (void*)green);
    vkCmdDraw(c, 3, 1, 0, 0);
    vkCmdEndRenderPass(c);
    vkCmdEndQuery(c, queries, i);
    barrier(c, im, VK_IMAGE_LAYOUT_GENERAL, VK_ACCESS_MEMORY_WRITE_BIT,
            VK_ACCESS_TRANSFER_READ_BIT);
    VkBufferImageCopy copy = {.bufferOffset = (VkDeviceSize)i * W * H * bpp,
                              .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                              .imageExtent = {W, H, 1}};
    vkCmdCopyImageToBuffer(c, im, VK_IMAGE_LAYOUT_GENERAL, buf, 1, &copy);
    barrier(c, im, VK_IMAGE_LAYOUT_GENERAL, VK_ACCESS_TRANSFER_READ_BIT,
            VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT);
  }
  VkMemoryBarrier host = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                          .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                          .dstAccessMask = VK_ACCESS_HOST_READ_BIT};
  vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &host,
                       0, 0, 0, 0);
  OK(vkEndCommandBuffer(c));
  VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
  VkFence fence;
  OK(vkCreateFence(d, &fci, 0, &fence));
  VkSubmitInfo sub = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &c};
  OK(vkQueueSubmit(q, 1, &sub, fence));
  OK(vkWaitForFences(d, 1, &fence, VK_TRUE, 5000000000ULL));
  int bad = 0;
  uint8_t* bytes = mapped;
  for (int i = 0; i < N; i++)
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) {
        int in = x >= i % 16 && x < i % 16 + 8 && y >= i % 8 && y < i % 8 + 8;
        uint8_t* actual = bytes + ((i * H + y) * W + x) * bpp;
        if (format == VK_FORMAT_R16G16B16A16_SFLOAT) {
          uint16_t exp[] = {in ? 0 : (i % 2 ? 0x3800 : 0), in ? 0x3c00 : 0, in ? 0 : 0x3c00,
                            0x3c00};
          if (memcmp(actual, exp, 8))
            bad++;
          continue;
        }
        if (format == VK_FORMAT_B10G11R11_UFLOAT_PACK32) {
          uint32_t exp = (in ? 0u : (i % 2 ? 0x380u : 0u)) | (in ? 0x3c0u << 11 : 0u) |
                         (in ? 0u : 0x1e0u << 22);
          if (memcmp(actual, &exp, 4))
            bad++;
          continue;
        }
        if (format == VK_FORMAT_R16G16_SNORM) {
          int16_t value[2];
          memcpy(value, actual, 4);
          int r = in ? 0 : (i % 2 ? -16384 : 8192), g = in ? 32767 : 0;
          if (abs(value[0] - r) > 1 || value[1] != g)
            bad++;
          continue;
        }
        if (uint_format) {
          if (*actual != (in ? 0 : (i % 2 ? 123 : 17)))
            bad++;
          continue;
        }
        int half = format == VK_FORMAT_R8G8B8A8_SRGB ? 188 : 128;
        uint8_t exp[4] = {(uint8_t)(in ? 0 : (i % 2 ? half : 0)), (uint8_t)(in ? 255 : 0),
                          (uint8_t)(in ? 0 : 255), 255};
        if (format == VK_FORMAT_B8G8R8A8_UNORM) {
          uint8_t t = exp[0];
          exp[0] = exp[2];
          exp[2] = t;
        }
        int wrong = 0;
        for (int k = 0; k < bpp; k++)
          if (abs((int)actual[k] - exp[k]) > 1)
            wrong = 1;
        bad += wrong;
      }
  uint64_t samples[N];
  OK(vkGetQueryPoolResults(d, queries, 0, N, sizeof(samples), samples, 8,
                           VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT));
  int qbad = 0;
  for (int i = 0; i < N; i++)
    if (precise ? samples[i] != W * H + 64 : samples[i] == 0)
      qbad++;
  printf("format=%d cases=%d pixels=%d mismatches=%d queryFailures=%d precise=%d\n", format, N,
         W * H * N, bad, qbad, precise);
  vkDestroyFence(d, fence, 0);
  vkDestroyQueryPool(d, queries, 0);
  vkDestroyCommandPool(d, pool, 0);
  vkUnmapMemory(d, mb);
  vkDestroyBuffer(d, buf, 0);
  vkFreeMemory(d, mb, 0);
  vkDestroyPipeline(d, pipeline, 0);
  vkDestroyPipelineLayout(d, layout, 0);
  vkDestroyFramebuffer(d, fb, 0);
  vkDestroyRenderPass(d, rp, 0);
  vkDestroyImageView(d, view, 0);
  vkDestroyImage(d, im, 0);
  vkFreeMemory(d, mi, 0);
  return bad || qbad;
}
int main(int argc, char** argv) {
  if (argc < 4)
    return 2;
  VkApplicationInfo ai = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                          .pApplicationName = "S2Arm transfer clear probe",
                          .apiVersion = VK_API_VERSION_1_1};
  VkInstanceCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                             .pApplicationInfo = &ai};
  VkInstance instance;
  OK(vkCreateInstance(&ci, 0, &instance));
  uint32_t n = 1;
  OK(vkEnumeratePhysicalDevices(instance, &n, &pd));
  VkPhysicalDeviceProperties props;
  vkGetPhysicalDeviceProperties(pd, &props);
  printf("device=%s driver=%u\n", props.deviceName, props.driverVersion);
  VkPhysicalDeviceFeatures features;
  vkGetPhysicalDeviceFeatures(pd, &features);
  VkPhysicalDeviceFeatures enabled = {.occlusionQueryPrecise = features.occlusionQueryPrecise};
  n = 0;
  vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, 0);
  VkQueueFamilyProperties* f = calloc(n, sizeof(*f));
  vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, f);
  for (family = 0; family < n; family++)
    if (f[family].queueFlags & VK_QUEUE_GRAPHICS_BIT)
      break;
  free(f);
  if (family == n)
    return 2;
  float priority = 1;
  VkDeviceQueueCreateInfo qc = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                .queueFamilyIndex = family,
                                .queueCount = 1,
                                .pQueuePriorities = &priority};
  VkDeviceCreateInfo dc = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                           .queueCreateInfoCount = 1,
                           .pQueueCreateInfos = &qc,
                           .pEnabledFeatures = &enabled};
  OK(vkCreateDevice(pd, &dc, 0, &d));
  vkGetDeviceQueue(d, family, 0, &q);
  VkShaderModule v = shader(argv[1]), p = shader(argv[2]), ui = shader(argv[3]);
  VkFormat formats[] = {VK_FORMAT_R8G8B8A8_UNORM,
                        VK_FORMAT_B8G8R8A8_UNORM,
                        VK_FORMAT_R8G8B8A8_SRGB,
                        VK_FORMAT_R16G16B16A16_SFLOAT,
                        VK_FORMAT_B10G11R11_UFLOAT_PACK32,
                        VK_FORMAT_R8_UNORM,
                        VK_FORMAT_R16G16_SNORM,
                        VK_FORMAT_R8_UINT};
  int result = 0;
  for (unsigned i = 0; i < sizeof(formats) / sizeof(formats[0]); i++)
    result |= run(formats[i], v, formats[i] == VK_FORMAT_R8_UINT ? ui : p,
                  features.occlusionQueryPrecise, argc > 4);
  vkDestroyShaderModule(d, v, 0);
  vkDestroyShaderModule(d, p, 0);
  vkDestroyShaderModule(d, ui, 0);
  vkDestroyDevice(d, 0);
  vkDestroyInstance(instance, 0);
  return result;
}
