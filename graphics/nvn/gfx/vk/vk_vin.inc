// 顶点输入整型的符号性（11-05 Minecraft：管线 a9cdfdc315093ef8 Metal 拒建「Cannot convert attribute from MTLAttributeFormatUShort to a signed integer type」，那条管线的绘制全丢）。
// 由 hle_vk.m 在 vk_rt.inc 之后包含。
// · 真机语义：整型顶点格式按格式本身扩展进 32 位寄存器（UINT 零扩展、SINT 符号扩展），着色器按自己声明的类型读那 32 位，符号性不一致照样读到原值的位
//   （同 MoltenVK：按管线顶点格式给 SPIRV-Cross MSL_SHADER_VARIABLE_FORMAT_UINT8 / UINT16）。
// · Metal（本机实测 M 系列，11-05）：无符号格式只许读进无符号输入、有符号格式只许读进有符号输入，不一致整条管线建不成。
// · 做法：建模块时扫 SPIR-V，记下顶点入口每个 location 上的输入是有符号 / 无符号整型；建管线时逐项对格式：
//   32 位分量：换同宽异号格式（UInt* ↔ Int*，读进来的 32 位逐位相同）；
//   8 / 16 位无符号格式喂有符号输入：这支顶点着色器按本管线的格式重翻（s2a_vk_xlate_vin，那几项改声明成无符号、按值转回，零扩展后 < 2^16 转 int 不变）、后台现编，
//     编好之前建的管线走现编补建（pipe_finish），同一模块同一组格式只翻一次；
//   8 / 16 位有符号格式喂无符号输入（要符号扩展后按位读）：SPIRV-Cross 没有这种提示，没实现，报红、照旧建不成。
int s2a_vk_xlate_vin(const uint32_t *code, size_t nwords, const char *key, uint32_t u8, uint32_t u16, char **msl, char *res, size_t rescap, char *err, size_t errcap) __attribute__((weak_import));

// SPIR-V：顶点入口的 Input 变量（标量 / 向量整型、带 Location）按符号性各记一位（位 = location，只记 < 32）
static void vin_scan(const uint32_t *w, size_t n, uint32_t *sg, uint32_t *us) {
    *sg = *us = 0;
    if (n < 5 || w[0] != 0x07230203) return;
    uint32_t bound = w[3]; if (!bound || bound > (1u << 22)) return;
    int vert = 0;
    uint32_t *loc = calloc(bound, sizeof *loc), *ity = calloc(bound, sizeof *ity), *ptr = calloc(bound, sizeof *ptr);   // loc：Location + 1；ity：整型 1 无符号 / 2 有符号（向量同分量）；ptr：Input 指针指向的类型 + 1
    if (!loc || !ity || !ptr) goto out;
    for (size_t i = 5; i < n;) {
        uint32_t op = w[i] & 0xffff, len = w[i] >> 16; if (!len || i + len > n) break;
        if (op == 15 && len >= 3 && w[i + 1] == 0) vert = 1;                                                            // OpEntryPoint Vertex
        else if (op == 71 && len >= 4 && w[i + 2] == 30 && w[i + 1] < bound) loc[w[i + 1]] = w[i + 3] + 1;                 // OpDecorate Location
        else if (op == 21 && len >= 4 && w[i + 1] < bound) ity[w[i + 1]] = w[i + 3] ? 2 : 1;                               // OpTypeInt
        else if (op == 23 && len >= 4 && w[i + 1] < bound && w[i + 2] < bound) ity[w[i + 1]] = ity[w[i + 2]];             // OpTypeVector
        else if (op == 32 && len >= 4 && w[i + 2] == 1 && w[i + 1] < bound && w[i + 3] < bound) ptr[w[i + 1]] = w[i + 3] + 1;   // OpTypePointer Input
        else if (op == 59 && len >= 4 && w[i + 3] == 1 && w[i + 1] < bound && w[i + 2] < bound && ptr[w[i + 1]]) {        // OpVariable Input
            uint32_t v = w[i + 2], t = ptr[w[i + 1]] - 1, l = loc[v];
            if (l && l - 1 < 32 && ity[t]) { if (ity[t] == 2) *sg |= 1u << (l - 1); else *us |= 1u << (l - 1); }
        }
        i += len;
    }
    if (!vert) *sg = *us = 0;
out:
    free(loc); free(ity); free(ptr);
}
// Metal 整型顶点格式：1 无符号 / −1 有符号 / 0 不是整型（含归一化）；*wd 分量字节数，*flip 同分量数异号的 32 位格式（只 32 位填）
static int vin_cls(MTLVertexFormat f, int *wd, MTLVertexFormat *flip) {
    *flip = MTLVertexFormatInvalid;
    switch (f) {
        case MTLVertexFormatUChar: case MTLVertexFormatUChar2: case MTLVertexFormatUChar3: case MTLVertexFormatUChar4: *wd = 1; return 1;
        case MTLVertexFormatChar: case MTLVertexFormatChar2: case MTLVertexFormatChar3: case MTLVertexFormatChar4: *wd = 1; return -1;
        case MTLVertexFormatUShort: case MTLVertexFormatUShort2: case MTLVertexFormatUShort3: case MTLVertexFormatUShort4: *wd = 2; return 1;
        case MTLVertexFormatShort: case MTLVertexFormatShort2: case MTLVertexFormatShort3: case MTLVertexFormatShort4: *wd = 2; return -1;
        case MTLVertexFormatUInt: *wd = 4; *flip = MTLVertexFormatInt; return 1;
        case MTLVertexFormatUInt2: *wd = 4; *flip = MTLVertexFormatInt2; return 1;
        case MTLVertexFormatUInt3: *wd = 4; *flip = MTLVertexFormatInt3; return 1;
        case MTLVertexFormatUInt4: *wd = 4; *flip = MTLVertexFormatInt4; return 1;
        case MTLVertexFormatInt: *wd = 4; *flip = MTLVertexFormatUInt; return -1;
        case MTLVertexFormatInt2: *wd = 4; *flip = MTLVertexFormatUInt2; return -1;
        case MTLVertexFormatInt3: *wd = 4; *flip = MTLVertexFormatUInt3; return -1;
        case MTLVertexFormatInt4: *wd = 4; *flip = MTLVertexFormatUInt4; return -1;
        default: *wd = 0; return 0;
    }
}
// 本管线这一项顶点属性：格式与着色器输入符号性不一致时就地换格式（32 位）或记进要重翻的位（8 / 16 位无符号）
static MTLVertexFormat vin_fix(VkShaderModule vm, uint32_t location, MTLVertexFormat vf, uint32_t *u8, uint32_t *u16) {
    int wd; MTLVertexFormat fl; int c = vm && location < 32 ? vin_cls(vf, &wd, &fl) : 0; uint32_t b = 1u << location;
    if (c > 0 && vm->vin_s & b) { if (wd == 4) return fl; if (wd == 1) *u8 |= b; else *u16 |= b; }
    else if (c < 0 && vm->vin_u & b) {
        if (wd == 4) return fl;
        RED1("vertex attribute %u: an 8 / 16-bit signed integer format feeds an unsigned shader input (%s): not implemented, Metal refuses the pipeline", location, vm->key);
    }
    return vf;
}
typedef struct vin_ent { char key[17]; uint32_t u8, u16; rt_ent e; struct vin_ent *next; } vin_ent;
static vin_ent *g_vin; static pthread_mutex_t g_vin_mu = PTHREAD_MUTEX_INITIALIZER;
void dm_vk_vin_stats(uint64_t *ok, uint64_t *bad) { *ok = g_vin_ok; *bad = g_vin_bad; }
// 模块 m 按格式提示 (u8, u16) 重翻的顶点着色器：已有就给它，没有就登记、交后台翻译现编（rt_finish 发布状态）
static rt_ent *vin_variant(VkShaderModule m, uint32_t u8, uint32_t u16) {
    pthread_mutex_lock(&g_vin_mu);
    for (vin_ent *v = g_vin; v; v = v->next) if (v->u8 == u8 && v->u16 == u16 && !memcmp(v->key, m->key, 16)) { pthread_mutex_unlock(&g_vin_mu); return &v->e; }
    vin_ent *v = calloc(1, sizeof *v); memcpy(v->key, m->key, 16); v->u8 = u8; v->u16 = u16; memcpy(v->e.key, m->key, 16); v->next = g_vin; g_vin = v;
    pthread_mutex_unlock(&g_vin_mu);
    LOG("[vk] 顶点输入：%s 的 8 / 16 位无符号格式喂有符号输入（location 位 u8 %#x / u16 %#x），按本管线格式重翻现编（第 %llu 帧）", m->key, u8, u16, (unsigned long long)g_frames);
    if (!s2a_vk_xlate_vin || !m->spv || m->spv.length % 4) {
        LOG("[vk] 【红】 顶点输入：%s 重翻不了（%s）", m->key, !s2a_vk_xlate_vin ? "这份宿主没链 graphics/metal 的翻译" : "没留 SPIR-V");
        g_vin_bad++; atomic_store(&v->e.state, 2); return &v->e;
    }
    NSData *spv = m->spv; rt_ent *e = &v->e;
    dispatch_async(rt_queue(), ^{
        char *msl = NULL, res[4096], err[600] = "";
        if (s2a_vk_xlate_vin(spv.bytes, spv.length / 4, e->key, u8, u16, &msl, res, sizeof res, err, sizeof err) || !msl) {
            LOG("[vk] 【红】 顶点输入：%s 重翻失败：%s", e->key, err); g_vin_bad++; atomic_store_explicit(&e->state, 2, memory_order_release); free(msl); return;
        }
        rt_finish(e, msl, NULL, res, 0, 2); free(msl);
    });
    return e;
}
