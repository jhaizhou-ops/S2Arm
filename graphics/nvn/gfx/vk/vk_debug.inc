// 调试扩展：回调按规范同步分发；标记、对象名称和 tag 写入宿主日志。
// 不依赖 Metal 调试工具，不改变渲染状态或绘制命令。
struct debug_callback {
    debug_callback *next;
    unsigned users;
    int kind, temporary, custom_allocator; // 1: utils, 2: report; temporary: instance pNext
    VkDebugUtilsMessengerCreateInfoEXT utils;
    VkDebugReportCallbackCreateInfoEXT report;
};
static const VkAllocationCallbacks *debug_allocator(VkInstance i, const VkAllocationCallbacks *a) {
    return a ? a : i && i->custom_allocator ? &i->allocator : NULL;
}
static void *debug_alloc(const VkAllocationCallbacks *a, size_t size, VkSystemAllocationScope scope) {
    void *p = a ? a->pfnAllocation(a->pUserData, size, _Alignof(max_align_t), scope) : malloc(size);
    if (p) memset(p, 0, size);
    return p;
}
static void debug_free(const VkAllocationCallbacks *a, void *p) {
    if (a) a->pfnFree(a->pUserData, p); else free(p);
}
static debug_callback *debug_add(VkInstance i, const VkAllocationCallbacks *a, int kind, int temporary, const void *ci) {
    debug_callback *c = debug_alloc(debug_allocator(i, a), sizeof *c, temporary ? VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE : VK_SYSTEM_ALLOCATION_SCOPE_OBJECT);
    if (!c) return NULL;
    c->custom_allocator = debug_allocator(i, a) != NULL;
    c->kind = kind; c->temporary = temporary;
    if (kind == 1) { c->utils = *(const VkDebugUtilsMessengerCreateInfoEXT *)ci; c->utils.pNext = NULL; }
    else { c->report = *(const VkDebugReportCallbackCreateInfoEXT *)ci; c->report.pNext = NULL; }
    pthread_mutex_lock(&i->debug_mu); c->next = i->debug; i->debug = c; pthread_mutex_unlock(&i->debug_mu);
    return c;
}
static void debug_remove(VkInstance i, debug_callback *c, const VkAllocationCallbacks *a) {
    if (!c) return;
    pthread_mutex_lock(&i->debug_mu);
    debug_callback **p = &i->debug;
    while (*p && *p != c) p = &(*p)->next;
    if (!*p) die("[vk] debug callback does not belong to this instance");
    *p = c->next;
    while (c->users) pthread_cond_wait(&i->debug_cv, &i->debug_mu);
    pthread_mutex_unlock(&i->debug_mu);
    debug_free(debug_allocator(i, a), c);
}
typedef struct { VkDebugReportObjectTypeEXT type; uint64_t object; size_t location; int32_t code; const char *prefix, *text; } debug_report_message;
static int debug_matches(const debug_callback *c, int kind, int temporary, uint32_t severity, uint32_t types) {
    return c->kind == kind && c->temporary == temporary &&
           (kind == 1 ? (c->utils.messageSeverity & severity) && (c->utils.messageType & types) : (c->report.flags & severity) != 0);
}
static VkResult debug_emit(VkInstance i, int kind, int temporary, uint32_t severity, uint32_t types,
                       const VkDebugUtilsMessengerCallbackDataEXT *data, const debug_report_message *report) {
    // 先保活本次要调用的对象，再解锁调用用户函数。report 回调允许重入部分 Vulkan API。
    pthread_mutex_lock(&i->debug_mu);
    size_t n = 0;
    for (debug_callback *c = i->debug; c; c = c->next) n += debug_matches(c, kind, temporary, severity, types);
    if (!n) { pthread_mutex_unlock(&i->debug_mu); return VK_SUCCESS; }
    const VkAllocationCallbacks *a = debug_allocator(i, NULL);
    debug_callback **calls = debug_alloc(a, n * sizeof *calls, VK_SYSTEM_ALLOCATION_SCOPE_COMMAND);
    if (!calls) { pthread_mutex_unlock(&i->debug_mu); return VK_ERROR_OUT_OF_HOST_MEMORY; }
    size_t k = 0;
    for (debug_callback *c = i->debug; c; c = c->next) if (debug_matches(c, kind, temporary, severity, types)) { c->users++; calls[k++] = c; }
    pthread_mutex_unlock(&i->debug_mu);
    for (k = 0; k < n; k++) {
        debug_callback *c = calls[k];
        if (kind == 1) c->utils.pfnUserCallback((VkDebugUtilsMessageSeverityFlagBitsEXT)severity, types, data, c->utils.pUserData);
        else c->report.pfnCallback(severity, report->type, report->object, report->location, report->code, report->prefix, report->text, c->report.pUserData);
        pthread_mutex_lock(&i->debug_mu); c->users--; pthread_cond_broadcast(&i->debug_cv); pthread_mutex_unlock(&i->debug_mu);
    }
    debug_free(a, calls); return VK_SUCCESS;
}
static void debug_instance_release(VkInstance i, const VkAllocationCallbacks *a) {
    pthread_mutex_lock(&g_object_mu);
    VkInstance *link = &g_instances; while (*link && *link != i) link = &(*link)->session_next;
    if (*link) *link = i->session_next;
    pthread_mutex_unlock(&g_object_mu);
    while (i->debug) debug_remove(i, i->debug, a);
    pthread_cond_destroy(&i->debug_cv); pthread_mutex_destroy(&i->debug_mu);
    debug_free(a, i);
}
static VkResult debug_instance_create(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *a, VkInstance *out) {
    *out = VK_NULL_HANDLE;
    VkInstance i = debug_alloc(a, sizeof *i, VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE);
    if (!i) return VK_ERROR_OUT_OF_HOST_MEMORY;
    if (a) { i->allocator = *a; i->custom_allocator = 1; }
    if (pthread_mutex_init(&i->debug_mu, NULL) || pthread_cond_init(&i->debug_cv, NULL)) die("[vk] cannot initialize debug callback synchronization");
    pthread_mutex_lock(&g_object_mu); i->session_next = g_instances; g_instances = i; pthread_mutex_unlock(&g_object_mu);
    for (const VkBaseInStructure *p = ci->pNext; p; p = p->pNext) {
        int kind = p->sType == VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT ? 1 : p->sType == VK_STRUCTURE_TYPE_DEBUG_REPORT_CALLBACK_CREATE_INFO_EXT ? 2 : 0;
        if (kind && !debug_add(i, a, kind, 1, p)) { debug_instance_release(i, a); return VK_ERROR_OUT_OF_HOST_MEMORY; }
    }
    *out = i; return VK_SUCCESS;
}
static void debug_instance_destroy(VkInstance i, const VkAllocationCallbacks *a) {
    if (!i) return;
    debug_instance_release(i, a);
}
VK(vkCreateDebugUtilsMessengerEXT, VkResult, VkInstance i, const VkDebugUtilsMessengerCreateInfoEXT *ci, const VkAllocationCallbacks *a, VkDebugUtilsMessengerEXT *out) {
    *out = (VkDebugUtilsMessengerEXT)debug_add(i, a, 1, 0, ci); return *out ? VK_SUCCESS : VK_ERROR_OUT_OF_HOST_MEMORY;
}
VK(vkDestroyDebugUtilsMessengerEXT, void, VkInstance i, VkDebugUtilsMessengerEXT c, const VkAllocationCallbacks *a) { debug_remove(i, (debug_callback *)c, a); }
VK(vkSubmitDebugUtilsMessageEXT, void, VkInstance i, VkDebugUtilsMessageSeverityFlagBitsEXT severity, VkDebugUtilsMessageTypeFlagsEXT types, const VkDebugUtilsMessengerCallbackDataEXT *data) {
    if (debug_emit(i, 1, 0, severity, types, data, NULL) != VK_SUCCESS) die("[vk] cannot allocate debug callback dispatch");
}
VK(vkCreateDebugReportCallbackEXT, VkResult, VkInstance i, const VkDebugReportCallbackCreateInfoEXT *ci, const VkAllocationCallbacks *a, VkDebugReportCallbackEXT *out) {
    *out = (VkDebugReportCallbackEXT)debug_add(i, a, 2, 0, ci); return *out ? VK_SUCCESS : VK_ERROR_OUT_OF_HOST_MEMORY;
}
VK(vkDestroyDebugReportCallbackEXT, void, VkInstance i, VkDebugReportCallbackEXT c, const VkAllocationCallbacks *a) { debug_remove(i, (debug_callback *)c, a); }
VK(vkDebugReportMessageEXT, void, VkInstance i, VkDebugReportFlagsEXT flags, VkDebugReportObjectTypeEXT type, uint64_t object, size_t location, int32_t code, const char *prefix, const char *message) {
    debug_report_message report = {type, object, location, code, prefix, message};
    if (debug_emit(i, 2, 0, flags, 0, NULL, &report) != VK_SUCCESS) die("[vk] cannot allocate debug callback dispatch");
}

static VkResult debug_name(int type, uint64_t object, const char *name) {
    if (!g_log) return VK_SUCCESS;
    VLOG("[debug] name object_type=%d object=%llu name=%s", type, (unsigned long long)object, name ? name : ""); return VK_SUCCESS;
}
static VkResult debug_tag(int type, uint64_t object, uint64_t tag, size_t size, const void *data) {
    if (!g_log) return VK_SUCCESS;
    VLOG("[debug] tag object_type=%d object=%llu tag=%llu size=%zu", type, (unsigned long long)object, (unsigned long long)tag, size);
    const uint8_t *bytes = data; const char hex[] = "0123456789abcdef";
    for (size_t off = 0; off < size;) {
        size_t n = MIN(size - off, (size_t)32); char text[65];
        for (size_t k = 0; k < n; k++) { text[k * 2] = hex[bytes[off + k] >> 4]; text[k * 2 + 1] = hex[bytes[off + k] & 15]; }
        text[n * 2] = 0; VLOG("[debug] tag-data offset=%zu hex=%s", off, text); off += n;
    }
    return VK_SUCCESS;
}
VK(vkSetDebugUtilsObjectNameEXT, VkResult, VkDevice d, const VkDebugUtilsObjectNameInfoEXT *p) { (void)d; return debug_name(p->objectType, p->objectHandle, p->pObjectName); }
VK(vkSetDebugUtilsObjectTagEXT, VkResult, VkDevice d, const VkDebugUtilsObjectTagInfoEXT *p) { (void)d; return debug_tag(p->objectType, p->objectHandle, p->tagName, p->tagSize, p->pTag); }
VK(vkDebugMarkerSetObjectNameEXT, VkResult, VkDevice d, const VkDebugMarkerObjectNameInfoEXT *p) { (void)d; return debug_name(p->objectType, p->object, p->pObjectName); }
VK(vkDebugMarkerSetObjectTagEXT, VkResult, VkDevice d, const VkDebugMarkerObjectTagInfoEXT *p) { (void)d; return debug_tag(p->objectType, p->object, p->tagName, p->tagSize, p->pTag); }

enum { DEBUG_UTILS_BEGIN, DEBUG_UTILS_INSERT, DEBUG_UTILS_END, DEBUG_MARKER_BEGIN, DEBUG_MARKER_INSERT, DEBUG_MARKER_END };
typedef struct { uint32_t op; float color[4]; char name[]; } c_debug_label;
static void debug_log_label(const char *op, const void *target, const char *name, const float *color) {
    if (!g_log) return;
    if (color) VLOG("[debug] %s target=%p name=%s color=%g,%g,%g,%g", op, target, name, color[0], color[1], color[2], color[3]);
    else VLOG("[debug] %s target=%p", op, target);
}
static void debug_record_label(VkCommandBuffer cb, uint32_t op, const char *name, const float *color) {
    size_t size = name ? strlen(name) + 1 : 1;
    if (size > UINT32_MAX - sizeof(c_debug_label) - sizeof(chdr) - 7) die("[vk] debug label is too large");
    c_debug_label *p = rec(cb, C_DEBUG_LABEL, sizeof *p + size); p->op = op;
    if (color) memcpy(p->color, color, sizeof p->color); else memset(p->color, 0, sizeof p->color);
    if (name) memcpy(p->name, name, size); else p->name[0] = 0;
}
static void debug_replay_label(VkCommandBuffer cb, const c_debug_label *p) {
    static const char *const names[] = {"vkCmdBeginDebugUtilsLabelEXT", "vkCmdInsertDebugUtilsLabelEXT", "vkCmdEndDebugUtilsLabelEXT",
        "vkCmdDebugMarkerBeginEXT", "vkCmdDebugMarkerInsertEXT", "vkCmdDebugMarkerEndEXT"};
    debug_log_label(names[p->op], cb, p->name, p->op == DEBUG_UTILS_END || p->op == DEBUG_MARKER_END ? NULL : p->color);
}
VK(vkCmdBeginDebugUtilsLabelEXT, void, VkCommandBuffer cb, const VkDebugUtilsLabelEXT *p) { if (!g_log) return; debug_record_label(cb, DEBUG_UTILS_BEGIN, p->pLabelName, p->color); }
VK(vkCmdInsertDebugUtilsLabelEXT, void, VkCommandBuffer cb, const VkDebugUtilsLabelEXT *p) { if (!g_log) return; debug_record_label(cb, DEBUG_UTILS_INSERT, p->pLabelName, p->color); }
VK(vkCmdEndDebugUtilsLabelEXT, void, VkCommandBuffer cb) { if (!g_log) return; debug_record_label(cb, DEBUG_UTILS_END, NULL, NULL); }
VK(vkCmdDebugMarkerBeginEXT, void, VkCommandBuffer cb, const VkDebugMarkerMarkerInfoEXT *p) { if (!g_log) return; debug_record_label(cb, DEBUG_MARKER_BEGIN, p->pMarkerName, p->color); }
VK(vkCmdDebugMarkerInsertEXT, void, VkCommandBuffer cb, const VkDebugMarkerMarkerInfoEXT *p) { if (!g_log) return; debug_record_label(cb, DEBUG_MARKER_INSERT, p->pMarkerName, p->color); }
VK(vkCmdDebugMarkerEndEXT, void, VkCommandBuffer cb) { if (!g_log) return; debug_record_label(cb, DEBUG_MARKER_END, NULL, NULL); }
VK(vkQueueBeginDebugUtilsLabelEXT, void, VkQueue q, const VkDebugUtilsLabelEXT *p) { debug_log_label("vkQueueBeginDebugUtilsLabelEXT", q, p->pLabelName, p->color); }
VK(vkQueueInsertDebugUtilsLabelEXT, void, VkQueue q, const VkDebugUtilsLabelEXT *p) { debug_log_label("vkQueueInsertDebugUtilsLabelEXT", q, p->pLabelName, p->color); }
VK(vkQueueEndDebugUtilsLabelEXT, void, VkQueue q) { debug_log_label("vkQueueEndDebugUtilsLabelEXT", q, NULL, NULL); }
