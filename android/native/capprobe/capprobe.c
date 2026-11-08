/* capprobe.c — runtime capability probe for the "geometry shader +
 * occlusion query" combination (issue #1456 follow-up research).
 *
 * Background: on Mali-G710 driver r32p1 (vendorID 0x13b5,
 * driverVersion 134221824) a GS pipeline drawing inside a native
 * occlusion query reliably returns VK_ERROR_DEVICE_LOST, while the
 * same driver handles GS without queries and queries without GS.
 * Because the failure mode is device loss, the probe must run outside
 * the game process; this binary is that probe process.
 *
 * Standalone Android aarch64 executable (NDK 29, links libvulkan).
 * No window, no swapchain, no descriptors, no pipeline cache. Each arm
 * creates its own VkInstance + VkDevice so one arm's device loss cannot
 * be confused with another arm's result. In "all" mode every arm
 * additionally runs in a forked child process for driver-state
 * isolation.
 *
 * Usage:
 *   capprobe fingerprint             print one fingerprint JSON line
 *   capprobe arm <name>              run one arm, print one arm JSON line
 *   capprobe all [--badlist FILE]    fingerprint line + one line per arm
 *
 * Arms: occ (GS+precise query), occimp (GS+imprecise), tessocc
 * (tessellation+precise query), nogsocc (control: no GS + precise
 * query), noq (GS, no query).
 *
 * Output is one JSON object per line on stdout, always with a "type"
 * field: {"type":"fingerprint",...}, {"type":"arm","arm":...,"outcome":
 * "ok|skipped|error|lost|timeout|crashed",...}, or {"type":"blocked",
 * ...} when the fingerprint matches the known-bad list. Timeouts are
 * the caller's responsibility: wrap each invocation (or the whole
 * "all" run) in an outer kill timer and emit
 * {"type":"arm","arm":...,"outcome":"timeout"} for killed arms.
 *
 * Exit codes (arm mode): 0 ok, 2 error, 3 lost, 4 blocked, 5 skipped,
 * 6 internal fence timeout. "all" exits 0 when every arm line was
 * emitted, 4 when blocked by the badlist, 2 on usage/environment error.
 */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>
#ifdef __ANDROID__
#include <sys/system_properties.h>
#else
#define PROP_VALUE_MAX 128
#endif

struct arm_spec {
    const char *name;
    int want_gs;
    int want_tess;
    int want_query;
    int precise;
};

static const struct arm_spec ARMS[] = {
    {"occ",     1, 0, 1, 1},
    {"occimp",  1, 0, 1, 0},
    {"tessocc", 0, 1, 1, 1},
    {"nogsocc", 0, 0, 1, 1},
    {"noq",     1, 0, 0, 0},
};
#define N_ARMS (sizeof(ARMS) / sizeof(ARMS[0]))

#ifdef S2A_CAPPROBE_STANDALONE
/* Run order for "all": control arm first, then the GS-only arm, then
 * the risky combinations. If a risky arm poisons the driver
 * process-wide, the control data is already on stdout. The app host
 * (capprobe_host.c) runs the same order through Java's CapProbe. */
static const int ARM_ORDER[N_ARMS] = {3, 4, 0, 1, 2};
#endif

enum outcome { OUT_OK, OUT_SKIPPED, OUT_ERROR, OUT_LOST, OUT_TIMEOUT, OUT_CRASHED };

static const char *outcome_name(enum outcome o) {
    switch (o) {
    case OUT_OK: return "ok";
    case OUT_SKIPPED: return "skipped";
    case OUT_ERROR: return "error";
    case OUT_LOST: return "lost";
    case OUT_TIMEOUT: return "timeout";
    case OUT_CRASHED: return "crashed";
    }
    return "error";
}

static void json_string(const char *s) {
    putchar('"');
    if (s) {
        for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
            unsigned char c = *p;
            if (c == '"' || c == '\\')
                printf("\\%c", c);
            else if (c < 0x20)
                printf("\\u%04x", c);
            else
                putchar(c);
        }
    }
    putchar('"');
}

/* ---------- SPIR-V embedded by build.sh into capprobe_spv.h -------- */
#include "capprobe_spv.h"

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

struct arm_report {
    enum outcome outcome;
    VkResult result;
    long long samples;      /* -1 = not applicable */
    double elapsed_ms;
    const char *stage;      /* where it failed, NULL when ok/skipped */
    const char *reason;     /* skip reason / detail, may be NULL */
};

static struct arm_report rep;

#define FAIL(stage_name, rc_)                                              \
    do {                                                                   \
        rep.stage = (stage_name);                                          \
        rep.result = (rc_);                                                \
        rep.outcome = (rc_) == VK_ERROR_DEVICE_LOST ? OUT_LOST             \
                    : (rc_) == VK_TIMEOUT             ? OUT_TIMEOUT        \
                                                      : OUT_ERROR;         \
        goto done;                                                         \
    } while (0)

static void print_arm_line(const char *arm, const struct arm_report *r) {
    printf("{\"type\":\"arm\",\"arm\":");
    json_string(arm);
    printf(",\"outcome\":");
    json_string(outcome_name(r->outcome));
    printf(",\"vk_result\":%d,\"samples\":", (int)r->result);
    if (r->samples >= 0) printf("%lld", r->samples); else printf("null");
    printf(",\"elapsed_ms\":%.2f,", r->elapsed_ms);
    printf("\"stage\":");
    json_string(r->stage);
    printf(",\"reason\":");
    json_string(r->reason);
    printf("}\n");
    fflush(stdout);
}

/* ---------------- fingerprint ------------------------------------ */

static int emit_fingerprint(void) {
    VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app};
    VkInstance inst;
    VkResult rc = vkCreateInstance(&ici, NULL, &inst);
    if (rc != VK_SUCCESS) {
        printf("{\"type\":\"fingerprint\",\"error\":\"vkCreateInstance=%d\"}\n",
               (int)rc);
        fflush(stdout);
        return 2;
    }
    uint32_t nph = 0;
    vkEnumeratePhysicalDevices(inst, &nph, NULL);
    if (nph == 0) {
        printf("{\"type\":\"fingerprint\",\"error\":\"no-physical-device\"}\n");
        fflush(stdout);
        vkDestroyInstance(inst, NULL);
        return 2;
    }
    VkPhysicalDevice pd;
    vkEnumeratePhysicalDevices(inst, &nph, &pd);
    VkPhysicalDeviceProperties pr;
    vkGetPhysicalDeviceProperties(pd, &pr);
    VkPhysicalDeviceFeatures feat;
    vkGetPhysicalDeviceFeatures(pd, &feat);
    char build[PROP_VALUE_MAX] = "unknown";
#ifdef __ANDROID__
    __system_property_get("ro.build.fingerprint", build);
#endif
    printf("{\"type\":\"fingerprint\",\"deviceName\":");
    json_string(pr.deviceName);
    printf(",\"vendorID\":%u,\"deviceID\":%u,\"driverVersion\":%u,"
           "\"apiVersion\":%u,\"buildFingerprint\":",
           pr.vendorID, pr.deviceID, pr.driverVersion, pr.apiVersion);
    json_string(build);
    printf(",\"feat_geometryShader\":%u,\"feat_tessellationShader\":%u,"
           "\"feat_occlusionQueryPrecise\":%u}\n",
           feat.geometryShader, feat.tessellationShader,
           feat.occlusionQueryPrecise);
    fflush(stdout);
    vkDestroyInstance(inst, NULL);
    return 0;
}

/* ---------------- known-bad list ---------------------------------- */
/* File format (also kept in known-bad.txt): one entry per line,
 *   vendorID driverVersion   # optional comment
 * vendorID accepts 0x-prefixed hex or decimal; driverVersion is the
 * exact VkPhysicalDeviceProperties.driverVersion value in decimal.
 * Blank lines and #-comments are ignored. */

#ifdef S2A_CAPPROBE_STANDALONE
struct bad_entry {
    unsigned vendor_id;
    unsigned driver_version;
};

static int badlist_load(const char *path, struct bad_entry *out, int cap) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[256];
    int n = 0;
    while (n < cap && fgets(line, sizeof(line), f)) {
        char *hash = strchr(line, '#');
        if (hash) *hash = 0;
        unsigned v, d;
        if (sscanf(line, " %i %u", &v, &d) == 2) {
            out[n].vendor_id = v;
            out[n].driver_version = d;
            n++;
        }
    }
    fclose(f);
    return n;
}

static const struct bad_entry *badlist_match(const struct bad_entry *list,
                                             int n, unsigned vendor,
                                             unsigned driver) {
    for (int i = 0; i < n; i++)
        if (list[i].vendor_id == vendor && list[i].driver_version == driver)
            return &list[i];
    return NULL;
}
#endif /* S2A_CAPPROBE_STANDALONE */

/* ---------------- per-arm probe ----------------------------------- */

static VkShaderModule make_shader(VkDevice dev, const void *code,
                                  size_t bytes) {
    VkShaderModuleCreateInfo ci = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = bytes, .pCode = (const uint32_t *)code};
    VkShaderModule m;
    if (vkCreateShaderModule(dev, &ci, NULL, &m) != VK_SUCCESS)
        return VK_NULL_HANDLE;
    return m;
}

static const struct arm_spec *find_arm(const char *name) {
    for (size_t i = 0; i < N_ARMS; i++)
        if (!strcmp(ARMS[i].name, name)) return &ARMS[i];
    return NULL;
}

static const struct arm_report *run_arm(const struct arm_spec *spec) {
    double t0 = now_ms();
    memset(&rep, 0, sizeof(rep));
    rep.outcome = OUT_OK;
    rep.result = VK_SUCCESS;
    rep.samples = -1;

    /* --- instance + physical device (fresh per arm) --- */
    VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app};
    VkInstance inst;
    VkResult rc = vkCreateInstance(&ici, NULL, &inst);
    if (rc != VK_SUCCESS) FAIL("vkCreateInstance", rc);
    uint32_t nph = 0;
    vkEnumeratePhysicalDevices(inst, &nph, NULL);
    VkPhysicalDevice *pds = calloc(nph ? nph : 1, sizeof(VkPhysicalDevice));
    vkEnumeratePhysicalDevices(inst, &nph, pds);
    if (nph == 0) FAIL("vkEnumeratePhysicalDevices", VK_ERROR_INITIALIZATION_FAILED);
    VkPhysicalDevice pd = pds[0];
    free(pds);

    /* --- feature gate: skip rather than fail when unsupported --- */
    VkPhysicalDeviceFeatures have;
    vkGetPhysicalDeviceFeatures(pd, &have);
    if (spec->want_gs && !have.geometryShader) {
        rep.outcome = OUT_SKIPPED;
        rep.reason = "missing-feature:geometryShader";
        goto done;
    }
    if (spec->want_tess && !have.tessellationShader) {
        rep.outcome = OUT_SKIPPED;
        rep.reason = "missing-feature:tessellationShader";
        goto done;
    }
    if (spec->want_query && spec->precise && !have.occlusionQueryPrecise) {
        rep.outcome = OUT_SKIPPED;
        rep.reason = "missing-feature:occlusionQueryPrecise";
        goto done;
    }

    /* --- queue family + device (fresh per arm) --- */
    uint32_t nq = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, NULL);
    VkQueueFamilyProperties *qp = calloc(nq, sizeof(VkQueueFamilyProperties));
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, qp);
    uint32_t qfi = UINT32_MAX;
    for (uint32_t i = 0; i < nq; i++)
        if (qp[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { qfi = i; break; }
    free(qp);
    if (qfi == UINT32_MAX)
        FAIL("queue-family", VK_ERROR_INITIALIZATION_FAILED);
    float prio = 1.0f;
    VkDeviceQueueCreateInfo dqi = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = qfi, .queueCount = 1, .pQueuePriorities = &prio};
    VkPhysicalDeviceFeatures feat = {0};
    feat.geometryShader = spec->want_gs ? VK_TRUE : VK_FALSE;
    feat.tessellationShader = spec->want_tess ? VK_TRUE : VK_FALSE;
    feat.occlusionQueryPrecise =
        (spec->want_query && spec->precise) ? VK_TRUE : VK_FALSE;
    VkDeviceCreateInfo dci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &dqi,
        .pEnabledFeatures = &feat, .enabledExtensionCount = 0};
    VkDevice dev;
    rc = vkCreateDevice(pd, &dci, NULL, &dev);
    if (rc != VK_SUCCESS) FAIL("vkCreateDevice", rc);
    VkQueue queue;
    vkGetDeviceQueue(dev, qfi, 0, &queue);

    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pd, &mp);

    /* --- 256x256 RGBA8 attachment --- */
    VkImageCreateInfo imgci = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = {256, 256, 1}, .mipLevels = 1, .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
    VkImage img;
    rc = vkCreateImage(dev, &imgci, NULL, &img);
    if (rc != VK_SUCCESS) FAIL("vkCreateImage", rc);
    VkMemoryRequirements mr;
    vkGetImageMemoryRequirements(dev, img, &mr);
    uint32_t mt = UINT32_MAX;
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((mr.memoryTypeBits & (1u << i)) &&
            (mp.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
            mt = i;
            break;
        }
    VkMemoryAllocateInfo mai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mr.size, .memoryTypeIndex = mt};
    VkDeviceMemory imem;
    rc = vkAllocateMemory(dev, &mai, NULL, &imem);
    if (rc != VK_SUCCESS) FAIL("vkAllocateMemory-img", rc);
    vkBindImageMemory(dev, img, imem, 0);
    VkImageViewCreateInfo ivci = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img,
        .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    VkImageView iv;
    rc = vkCreateImageView(dev, &ivci, NULL, &iv);
    if (rc != VK_SUCCESS) FAIL("vkCreateImageView", rc);

    VkAttachmentDescription att = {
        .format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkAttachmentReference aref = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sub = {
        .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1, .pColorAttachments = &aref};
    VkRenderPassCreateInfo rpci = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &att,
        .subpassCount = 1, .pSubpasses = &sub};
    VkRenderPass rp;
    rc = vkCreateRenderPass(dev, &rpci, NULL, &rp);
    if (rc != VK_SUCCESS) FAIL("vkCreateRenderPass", rc);
    VkFramebufferCreateInfo fbci = {
        .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = rp,
        .attachmentCount = 1, .pAttachments = &iv,
        .width = 256, .height = 256, .layers = 1};
    VkFramebuffer fb;
    rc = vkCreateFramebuffer(dev, &fbci, NULL, &fb);
    if (rc != VK_SUCCESS) FAIL("vkCreateFramebuffer", rc);

    /* --- vertex buffer: one non-degenerate fullscreen triangle (also
     * serves as one 3-control-point patch for the tessellation arm) --- */
    static const float verts[12] = {
        -1.f, -1.f, 0.f, 1.f,   3.f, -1.f, 0.f, 1.f,   -1.f, 3.f, 0.f, 1.f};
    VkBufferCreateInfo vbci = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = sizeof(verts),
        .usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
    VkBuffer vb;
    rc = vkCreateBuffer(dev, &vbci, NULL, &vb);
    if (rc != VK_SUCCESS) FAIL("vkCreateBuffer", rc);
    vkGetBufferMemoryRequirements(dev, vb, &mr);
    mt = UINT32_MAX;
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((mr.memoryTypeBits & (1u << i)) &&
            (mp.memoryTypes[i].propertyFlags &
             (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
              VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) ==
                (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                 VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
            mt = i;
            break;
        }
    mai.allocationSize = mr.size;
    mai.memoryTypeIndex = mt;
    VkDeviceMemory vmem;
    rc = vkAllocateMemory(dev, &mai, NULL, &vmem);
    if (rc != VK_SUCCESS) FAIL("vkAllocateMemory-vb", rc);
    vkBindBufferMemory(dev, vb, vmem, 0);
    void *map;
    rc = vkMapMemory(dev, vmem, 0, sizeof(verts), 0, &map);
    if (rc != VK_SUCCESS) FAIL("vkMapMemory", rc);
    memcpy(map, verts, sizeof(verts));
    vkUnmapMemory(dev, vmem);

    /* --- pipeline: no cache, no descriptors --- */
    VkShaderModule sm_v = make_shader(dev, capprobe_vert, capprobe_vert_len);
    VkShaderModule sm_g =
        spec->want_gs ? make_shader(dev, capprobe_geom, capprobe_geom_len)
                      : VK_NULL_HANDLE;
    VkShaderModule sm_tc =
        spec->want_tess ? make_shader(dev, capprobe_tesc, capprobe_tesc_len)
                        : VK_NULL_HANDLE;
    VkShaderModule sm_te =
        spec->want_tess ? make_shader(dev, capprobe_tese, capprobe_tese_len)
                        : VK_NULL_HANDLE;
    VkShaderModule sm_f = make_shader(dev, capprobe_frag, capprobe_frag_len);
    if (!sm_v || (spec->want_gs && !sm_g) ||
        (spec->want_tess && (!sm_tc || !sm_te)) || !sm_f)
        FAIL("vkCreateShaderModule", VK_ERROR_INITIALIZATION_FAILED);

    VkPipelineShaderStageCreateInfo st[4];
    int nst = 0;
    st[nst++] = (VkPipelineShaderStageCreateInfo){
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = sm_v, .pName = "main"};
    if (spec->want_gs)
        st[nst++] = (VkPipelineShaderStageCreateInfo){
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_GEOMETRY_BIT, .module = sm_g,
            .pName = "main"};
    if (spec->want_tess) {
        st[nst++] = (VkPipelineShaderStageCreateInfo){
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT,
            .module = sm_tc, .pName = "main"};
        st[nst++] = (VkPipelineShaderStageCreateInfo){
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT,
            .module = sm_te, .pName = "main"};
    }
    st[nst++] = (VkPipelineShaderStageCreateInfo){
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = sm_f, .pName = "main"};

    VkVertexInputBindingDescription vib = {0, 16, VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription via = {
        0, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 0};
    VkPipelineVertexInputStateCreateInfo vis = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 1, .pVertexBindingDescriptions = &vib,
        .vertexAttributeDescriptionCount = 1, .pVertexAttributeDescriptions = &via};
    VkPipelineInputAssemblyStateCreateInfo ia = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = spec->want_tess ? VK_PRIMITIVE_TOPOLOGY_PATCH_LIST
                                   : VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
    VkPipelineTessellationStateCreateInfo tess = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_STATE_CREATE_INFO,
        .patchControlPoints = 3};
    VkViewport vp = {0, 0, 256, 256, 0, 1};
    VkRect2D sc = {{0, 0}, {256, 256}};
    VkPipelineViewportStateCreateInfo vps = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc};
    VkPipelineRasterizationStateCreateInfo rs = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE,
        .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1.0f};
    VkPipelineMultisampleStateCreateInfo ms = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
    VkPipelineColorBlendAttachmentState cba = {
        .blendEnable = VK_FALSE,
        .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                          VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT};
    VkPipelineColorBlendStateCreateInfo cb = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &cba};
    VkPipelineLayoutCreateInfo lci = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    VkPipelineLayout playout;
    rc = vkCreatePipelineLayout(dev, &lci, NULL, &playout);
    if (rc != VK_SUCCESS) FAIL("vkCreatePipelineLayout", rc);
    VkGraphicsPipelineCreateInfo gp = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = (uint32_t)nst, .pStages = st,
        .pVertexInputState = &vis, .pInputAssemblyState = &ia,
        .pTessellationState = spec->want_tess ? &tess : NULL,
        .pViewportState = &vps, .pRasterizationState = &rs,
        .pMultisampleState = &ms, .pColorBlendState = &cb,
        .layout = playout, .renderPass = rp, .subpass = 0};
    VkPipeline pipe;
    rc = vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gp, NULL, &pipe);
    if (rc != VK_SUCCESS) FAIL("vkCreateGraphicsPipelines", rc);

    /* --- query pool (query arms only) --- */
    VkQueryPool qpool = VK_NULL_HANDLE;
    if (spec->want_query) {
        VkQueryPoolCreateInfo qci = {
            .sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
            .queryType = VK_QUERY_TYPE_OCCLUSION, .queryCount = 1};
        rc = vkCreateQueryPool(dev, &qci, NULL, &qpool);
        if (rc != VK_SUCCESS) FAIL("vkCreateQueryPool", rc);
    }

    VkCommandPoolCreateInfo cpci = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = qfi,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT};
    VkCommandPool cp;
    rc = vkCreateCommandPool(dev, &cpci, NULL, &cp);
    if (rc != VK_SUCCESS) FAIL("vkCreateCommandPool", rc);
    VkCommandBufferAllocateInfo cbai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = cp, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1};
    VkCommandBuffer cmd;
    rc = vkAllocateCommandBuffers(dev, &cbai, &cmd);
    if (rc != VK_SUCCESS) FAIL("vkAllocateCommandBuffers", rc);
    VkCommandBufferBeginInfo bbi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    rc = vkBeginCommandBuffer(cmd, &bbi);
    if (rc != VK_SUCCESS) FAIL("vkBeginCommandBuffer", rc);
    /* reset outside the render pass (matches game + Ryujinx ordering) */
    if (spec->want_query) vkCmdResetQueryPool(cmd, qpool, 0, 1);
    VkClearValue cv = {{{0.f, 0.f, 0.f, 1.f}}};
    VkRenderPassBeginInfo rbi = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = rp,
        .framebuffer = fb, .renderArea = {{0, 0}, {256, 256}},
        .clearValueCount = 1, .pClearValues = &cv};
    vkCmdBeginRenderPass(cmd, &rbi, VK_SUBPASS_CONTENTS_INLINE);
    if (spec->want_query)
        vkCmdBeginQuery(cmd, qpool, 0,
                        spec->precise ? VK_QUERY_CONTROL_PRECISE_BIT : 0);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
    VkDeviceSize off = 0;
    vkCmdBindVertexBuffers(cmd, 0, 1, &vb, &off);
    vkCmdDraw(cmd, 3, 1, 0, 0);
    if (spec->want_query) vkCmdEndQuery(cmd, qpool, 0);
    vkCmdEndRenderPass(cmd);
    rc = vkEndCommandBuffer(cmd);
    if (rc != VK_SUCCESS) FAIL("vkEndCommandBuffer", rc);

    VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkFence fence;
    rc = vkCreateFence(dev, &fci, NULL, &fence);
    if (rc != VK_SUCCESS) FAIL("vkCreateFence", rc);
    VkSubmitInfo si = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1, .pCommandBuffers = &cmd};
    rc = vkQueueSubmit(queue, 1, &si, fence);
    if (rc != VK_SUCCESS) FAIL("vkQueueSubmit", rc);
    /* Internal fence budget is a detector, not the caller timeout: a
     * trivial draw that cannot retire in 10 s is a hung GPU. */
    rc = vkWaitForFences(dev, 1, &fence, VK_TRUE, 10000000000ULL);
    if (rc != VK_SUCCESS) FAIL("vkWaitForFences", rc);
    if (spec->want_query) {
        uint64_t samples = 0;
        rc = vkGetQueryPoolResults(dev, qpool, 0, 1, sizeof(samples), &samples,
                                   8, VK_QUERY_RESULT_64_BIT |
                                          VK_QUERY_RESULT_WAIT_BIT);
        if (rc != VK_SUCCESS) FAIL("vkGetQueryPoolResults", rc);
        rep.samples = (long long)samples;
    }

done:
    rep.elapsed_ms = now_ms() - t0;
    return &rep;
}

static int arm_exit_code(enum outcome o) {
    switch (o) {
    case OUT_OK: return 0;
    case OUT_ERROR: return 2;
    case OUT_LOST: return 3;
    case OUT_TIMEOUT: return 6;
    case OUT_CRASHED: return 3;
    case OUT_SKIPPED: return 5;
    }
    return 2;
}

#ifdef S2A_CAPPROBE_STANDALONE
static void usage(void) {
    fprintf(stderr,
            "usage: capprobe fingerprint\n"
            "       capprobe arm <occ|occimp|tessocc|nogsocc|noq>\n"
            "       capprobe all [--badlist FILE]\n");
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 2; }

    if (!strcmp(argv[1], "fingerprint"))
        return emit_fingerprint();

    if (!strcmp(argv[1], "arm")) {
        if (argc < 3) { usage(); return 2; }
        const struct arm_spec *spec = find_arm(argv[2]);
        if (!spec) { usage(); return 2; }
        const struct arm_report *r = run_arm(spec);
        print_arm_line(spec->name, r);
        return arm_exit_code(r->outcome);
    }

    if (!strcmp(argv[1], "all")) {
        const char *badlist = NULL;
        if (argc == 4 && !strcmp(argv[2], "--badlist")) badlist = argv[3];
        else if (argc != 2) { usage(); return 2; }
        if (emit_fingerprint() != 0) return 2;
        if (badlist) {
            /* Re-read the fingerprint fields for the match: instance
             * creation above already proved Vulkan is reachable, so a
             * second cheap instance for the ids is acceptable. */
            VkApplicationInfo app = {
                .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                .apiVersion = VK_API_VERSION_1_1};
            VkInstanceCreateInfo ici = {
                .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                .pApplicationInfo = &app};
            VkInstance inst;
            if (vkCreateInstance(&ici, NULL, &inst) == VK_SUCCESS) {
                VkPhysicalDevice pd;
                uint32_t n = 1;
                vkEnumeratePhysicalDevices(inst, &n, &pd);
                if (n) {
                    VkPhysicalDeviceProperties pr;
                    vkGetPhysicalDeviceProperties(pd, &pr);
                    struct bad_entry entries[64];
                    int nb = badlist_load(badlist, entries, 64);
                    const struct bad_entry *hit =
                        nb >= 0 ? badlist_match(entries, nb, pr.vendorID,
                                                pr.driverVersion)
                                : NULL;
                    if (hit) {
                        printf("{\"type\":\"blocked\",\"reason\":\"known-bad-list\","
                               "\"vendorID\":%u,\"driverVersion\":%u}\n",
                               hit->vendor_id, hit->driver_version);
                        fflush(stdout);
                        vkDestroyInstance(inst, NULL);
                        return 4;
                    }
                }
                vkDestroyInstance(inst, NULL);
            }
        }
        int rc = 0;
        for (size_t i = 0; i < N_ARMS; i++) {
            const struct arm_spec *spec = &ARMS[ARM_ORDER[i]];
            pid_t pid = fork();
            if (pid == 0) {
                const struct arm_report *r = run_arm(spec);
                print_arm_line(spec->name, r);
                _exit(arm_exit_code(r->outcome));
            }
            if (pid < 0) {
                struct arm_report cr = {
                    .outcome = OUT_ERROR, .result = VK_ERROR_INITIALIZATION_FAILED,
                    .samples = -1, .elapsed_ms = 0,
                    .stage = "fork", .reason = "fork-failed"};
                print_arm_line(spec->name, &cr);
                rc = 2;
                continue;
            }
            int status;
            while (waitpid(pid, &status, 0) < 0) { /* EINTR */ }
            if (!WIFEXITED(status)) {
                struct arm_report cr = {
                    .outcome = OUT_CRASHED, .result = VK_ERROR_DEVICE_LOST,
                    .samples = -1, .elapsed_ms = 0,
                    .stage = "child", .reason = "signaled"};
                print_arm_line(spec->name, &cr);
            }
        }
        return rc;
    }

    usage();
    return 2;
}
#endif /* S2A_CAPPROBE_STANDALONE */
