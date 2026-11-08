// 直连 Vulkan 层的设备上 SPIR-V → MSL（乙，总指挥 10-25：出包期自动生成着色器漏掉的，设备上后台翻译现编）。
// 规则与出包工具 translator/vk_shaders.py 逐条同口径（那边改了这里一起改，口径号 S2A_VK_LIB_ABI）：
//   · 把成员上的 ArrayStride 补到数组类型上（超级马力欧银河的生成着色器，NVIDIA 驱动收、SPIRV-Cross 不收）
//   · 描述符按种类重新编号：uniform / storage 缓冲 → buffer(n)、图像 → texture(n)、采样器 → sampler(n)，n 按 (set, binding) 序从 0 起，数组占连续槽；
//     组合图像采样器同时占 texture 与 sampler；push 常量块放在描述符缓冲之后的那个 buffer 槽
//   · MSL 3.1（同直连非曲面与通用层：图像原子走原生，2.3 时 SPIRV-Cross 用附带缓冲模拟、宿主不绑那个缓冲；审计 #1534 P1-66）、按 Binding 装饰取槽、1D 纹理当 2D、入口改名 vk_<键>、顶点着色器翻 y
//   · 只登记入口函数真带的资源；fast::min / max / clamp 换成 precise::（NaN 口径同 Switch 的 GPU）
//   · 片元着色器有 location 1 输出时另出 vk_<键>_d 变体（第二混合源）
//   · 计算着色器翻成 kernel，工作组大小记 w:x.y=z（大小由特化常量给的跳过）；子遍输入（input attachment）按纹理读
// 放在 graphics/metal：SPIRV-Cross 只编进这份库（Mac 宿主的 libnxgal.dylib 里符号隐藏），本函数显式导出给 graphics/nvn/gfx/vk/hle_vk.m 弱引用调用
#include "../third_party/spirv_cross/spirv_cross_c.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { OP_DECORATE = 71, OP_MEMBER_DECORATE = 72, OP_TYPE_ARRAY = 28, OP_TYPE_RTARRAY = 29, OP_TYPE_STRUCT = 30, DEC_ARRAY_STRIDE = 6, DEC_BINDING = 33, DEC_SET = 34 };

// 成员带 ArrayStride、数组类型没带的：在最后一条成员装饰之后补 OpDecorate <数组> ArrayStride <步长>（vk_shaders.py fix_strides）
static uint32_t *fix_strides(const uint32_t *w, size_t n, size_t *out_n) {
    size_t cap = n + 64, m = 0, at = 0; uint32_t *add = malloc(cap * sizeof *add); size_t nadd = 0;
    uint32_t *out = NULL;
    // 第一遍：哪些数组类型已有步长、哪些是数组、结构体成员类型
    size_t idmax = w[3];   // SPIR-V 头的 ID 上界
    char *is_arr = calloc(idmax, 1), *has = calloc(idmax, 1);
    for (size_t i = 5; i < n;) {
        uint32_t op = w[i] & 0xffff, len = w[i] >> 16; if (!len || i + len > n) goto bad;
        if (op == OP_DECORATE && len >= 4 && w[i + 2] == DEC_ARRAY_STRIDE && w[i + 1] < idmax) has[w[i + 1]] = 1;
        else if (op == OP_MEMBER_DECORATE && len >= 5 && w[i + 3] == DEC_ARRAY_STRIDE) at = i + len;
        else if ((op == OP_TYPE_ARRAY || op == OP_TYPE_RTARRAY) && w[i + 1] < idmax) is_arr[w[i + 1]] = 1;
        i += len;
    }
    // 第二遍：成员装饰指到的成员类型是没步长的数组 → 记一条（每个数组一次）
    char *done = calloc(idmax, 1);
    for (size_t i = 5; i < n;) {
        uint32_t op = w[i] & 0xffff, len = w[i] >> 16;
        if (op == OP_MEMBER_DECORATE && len >= 5 && w[i + 3] == DEC_ARRAY_STRIDE) {
            uint32_t st = w[i + 1], mem = w[i + 2], stride = w[i + 4];
            for (size_t j = 5; j < n;) {   // 找结构体定义
                uint32_t op2 = w[j] & 0xffff, l2 = w[j] >> 16;
                if (op2 == OP_TYPE_STRUCT && w[j + 1] == st) {
                    if (2 + mem < l2) { uint32_t t = w[j + 2 + mem]; if (t < idmax && is_arr[t] && !has[t] && !done[t]) { done[t] = 1; if (nadd + 4 > cap) { cap *= 2; add = realloc(add, cap * sizeof *add); } add[nadd++] = (4u << 16) | OP_DECORATE; add[nadd++] = t; add[nadd++] = DEC_ARRAY_STRIDE; add[nadd++] = stride; } }
                    break;
                }
                j += l2;
            }
        }
        i += len;
    }
    out = malloc((n + nadd) * sizeof *out);
    if (!nadd) { memcpy(out, w, n * sizeof *out); m = n; }
    else { memcpy(out, w, at * sizeof *out); memcpy(out + at, add, nadd * sizeof *out); memcpy(out + at + nadd, w + at, (n - at) * sizeof *out); m = n + nadd; }
    free(is_arr); free(has); free(done); free(add); *out_n = m; return out;
bad:
    free(is_arr); free(has); free(add); return NULL;
}

typedef struct { uint32_t var, set, binding; } decv;
static int dec_cmp(const void *a, const void *b) {
    const decv *x = a, *y = b; if (x->set != y->set) return x->set < y->set ? -1 : 1; if (x->binding != y->binding) return x->binding < y->binding ? -1 : 1; return x->var < y->var ? -1 : x->var > y->var;
}
// 入口函数参数里 [[buffer(n)]] / [[texture(n)]] / [[sampler(n)]] 有没有 n
static int arg_has(const char *args, size_t len, const char *cls, unsigned slot) {
    char pat[48]; int pl = snprintf(pat, sizeof pat, "[[%s(%u)]]", cls, slot);
    for (size_t i = 0; i + (size_t)pl <= len; i++) if (!memcmp(args + i, pat, (size_t)pl)) return 1;
    return 0;
}
static char *replace_all(const char *s, const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b), n = 0; for (const char *p = s; (p = strstr(p, a)); p += la) n++;
    char *o = malloc(strlen(s) + n * (lb > la ? lb - la : 0) + 1), *q = o;
    for (const char *p = s, *f; ; p = f + la) { f = strstr(p, a); if (!f) { strcpy(q, p); break; } memcpy(q, p, (size_t)(f - p)); q += f - p; memcpy(q, b, lb); q += lb; }
    return o;
}

// 返回 0 = 翻好（*msl 必有，*msl_d 片元第二混合源变体或 NULL，都由调用方 free）；1 = Metal 没有的阶段 / 特化常量定的工作组（跳过）；−1 = 失败（err）
// res：资源表那一栏（同 vk_shaders.tsv 第 3 列，空格分隔 kind:set.binding=slot[*count]）；*stage：0 顶点 / 1 片元 / 2 计算
// u8 / u16：顶点输入格式提示（位 = location）：这些位置上游戏给的是 8 / 16 位无符号整型格式（R8_UINT / R16_UINT 族），着色器输入若是有符号整型，
//   SPIRV-Cross 把那一项改声明成同宽分量数的无符号整型、函数体里按值转回（同 MoltenVK 按管线顶点格式给 MSL_SHADER_VARIABLE_FORMAT_UINT8 / UINT16）：
//   Metal 不许无符号顶点格式读进有符号输入（建管线报 Cannot convert … to a signed integer type），真硬件按格式零扩展进 32 位寄存器、着色器按位读，零扩展后的值 < 2^16 转 int 不变
static int xlate(const uint32_t *code, size_t nwords, const char *key, uint32_t u8, uint32_t u16, char **msl, char **msl_d, char *res, size_t rescap, int *stage, char *err, size_t errcap) {
    *msl = *msl_d = NULL; res[0] = 0; *stage = 0; int rc = -1, frag = 0; unsigned wg[3] = {0};
    size_t n = 0; uint32_t *w = nwords > 5 && code[0] == 0x07230203 ? fix_strides(code, nwords, &n) : NULL;
    if (!w) { snprintf(err, errcap, "SPIR-V 头 / 指令长度不对"); return -1; }
    spvc_context ctx = NULL; spvc_parsed_ir ir; spvc_compiler c; spvc_compiler_options o; spvc_resources rs; const char *src = NULL;
    decv *dv = NULL; char *fixed = NULL;
    if (spvc_context_create(&ctx) != SPVC_SUCCESS) { snprintf(err, errcap, "SPIRV-Cross 上下文建不出"); free(w); return -1; }
    if (spvc_context_parse_spirv(ctx, w, n, &ir) != SPVC_SUCCESS || spvc_context_create_compiler(ctx, SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &c) != SPVC_SUCCESS) {
        snprintf(err, errcap, "SPIRV-Cross 解析失败：%s", spvc_context_get_last_error_string(ctx)); goto out;
    }
    const spvc_entry_point *eps; size_t neps; spvc_compiler_get_entry_points(c, &eps, &neps);
    if (neps != 1) { snprintf(err, errcap, "入口 %zu 个，不是 1 个", neps); goto out; }
    SpvExecutionModel model = eps[0].execution_model;
    if (model != SpvExecutionModelVertex && model != SpvExecutionModelFragment && model != SpvExecutionModelGLCompute) { rc = 1; goto out; }
    frag = model == SpvExecutionModelFragment; *stage = frag ? 1 : model == SpvExecutionModelGLCompute ? 2 : 0;
    if (*stage == 2) {
        spvc_specialization_constant x, y, z; spvc_compiler_get_work_group_size_specialization_constants(c, &x, &y, &z);
        if (x.id || y.id || z.id) { rc = 1; goto out; }
        for (unsigned i = 0; i < 3; i++) wg[i] = spvc_compiler_get_execution_mode_argument_by_index(c, SpvExecutionModeLocalSize, i);
        for (unsigned i = 0; i < 3; i++) if (!wg[i]) wg[i] = 1;
    }
    // 资源：(set, binding) → 种类 / 描述符个数（vk_shaders.py KINDS）
    spvc_compiler_create_shader_resources(c, &rs);
    static const struct { spvc_resource_type t; char k; } kinds[] = {
        {SPVC_RESOURCE_TYPE_UNIFORM_BUFFER, 'u'}, {SPVC_RESOURCE_TYPE_STORAGE_BUFFER, 'b'}, {SPVC_RESOURCE_TYPE_SEPARATE_IMAGE, 't'}, {SPVC_RESOURCE_TYPE_STORAGE_IMAGE, 't'},
        {SPVC_RESOURCE_TYPE_SEPARATE_SAMPLERS, 's'}, {SPVC_RESOURCE_TYPE_SAMPLED_IMAGE, 'c'}, {SPVC_RESOURCE_TYPE_SUBPASS_INPUT, 't'}};
    struct { uint32_t set, binding, count; char k; } pr[64]; int npr = 0;
    for (size_t t = 0; t < sizeof kinds / sizeof *kinds; t++) {
        const spvc_reflected_resource *l; size_t nl; spvc_resources_get_resource_list_for_type(rs, kinds[t].t, &l, &nl);
        for (size_t i = 0; i < nl; i++) {
            spvc_type ty = spvc_compiler_get_type_handle(c, l[i].type_id); unsigned nd = spvc_type_get_num_array_dimensions(ty); uint32_t cnt = 1;
            if (nd > 1 || (nd == 1 && !(cnt = (uint32_t)spvc_type_get_array_dimension(ty, 0)))) { snprintf(err, errcap, "资源 %s 的数组维度没实现", l[i].name); goto out; }
            if (npr == 64) { snprintf(err, errcap, "资源超过 64 个"); goto out; }
            pr[npr].set = spvc_compiler_get_decoration(c, l[i].id, SpvDecorationDescriptorSet); pr[npr].binding = spvc_compiler_get_decoration(c, l[i].id, SpvDecorationBinding);
            pr[npr].count = cnt; pr[npr].k = kinds[t].k; npr++;
        }
    }
    const spvc_reflected_resource *pcs; size_t npc; spvc_resources_get_resource_list_for_type(rs, SPVC_RESOURCE_TYPE_PUSH_CONSTANT, &pcs, &npc);
    if (npc > 1) { snprintf(err, errcap, "push 常量块 %zu 个", npc); goto out; }
    // 带 Binding 装饰的变量按 (set, binding) 排序后编号（同一 (set, binding) 的变量共用一个槽）
    size_t ndv = 0, cdv = 64; dv = malloc(cdv * sizeof *dv);
    for (size_t i = 5; i < n;) {
        uint32_t op = w[i] & 0xffff, len = w[i] >> 16;
        if (op == OP_DECORATE && len >= 4 && w[i + 2] == DEC_BINDING) {
            if (ndv == cdv) { cdv *= 2; dv = realloc(dv, cdv * sizeof *dv); }
            dv[ndv].var = w[i + 1]; dv[ndv].binding = w[i + 3]; dv[ndv].set = spvc_compiler_get_decoration(c, w[i + 1], SpvDecorationDescriptorSet); ndv++;
        }
        i += len;
    }
    qsort(dv, ndv, sizeof *dv, dec_cmp);
    unsigned nb = 0, nt = 0, ns = 0; struct { uint32_t set, binding; unsigned slot; } done[64]; int ndone = 0; size_t ro = 0;
    for (size_t i = 0; i < ndv; i++) {
        int p = -1; for (int k = 0; k < npr; k++) if (pr[k].set == dv[i].set && pr[k].binding == dv[i].binding) { p = k; break; }
        if (p < 0) continue;   // 声明了没用：SPIRV-Cross 会丢掉
        int d = -1; for (int k = 0; k < ndone; k++) if (done[k].set == dv[i].set && done[k].binding == dv[i].binding) { d = k; break; }
        unsigned slot;
        if (d >= 0) slot = done[d].slot;
        else {
            char k = pr[p].k; unsigned cnt = pr[p].count;
            // 组合采样器同一个下标既是纹理又是采样器：取两个游标的较大值，两个游标都从这里加（同 spirv_msl.py；审计 1101 18:00 P1-19：原先只取纹理游标，
            //   绑定号更小的独立采样器先占了 0 号时组合采样器也拿到 0 号，采样器下标重复、这一支编不出）
            if (k == 'u' || k == 'b') { slot = nb; nb += cnt; } else if (k == 's') { slot = ns; ns += cnt; } else if (k == 'c') { slot = nt > ns ? nt : ns; nt = ns = slot + cnt; } else { slot = nt; nt += cnt; }
            if (ndone == 64) { snprintf(err, errcap, "资源超过 64 个"); goto out; }
            done[ndone].set = dv[i].set; done[ndone].binding = dv[i].binding; done[ndone].slot = slot; ndone++;
            ro += (size_t)snprintf(res + ro, ro < rescap ? rescap - ro : 0, "%s%c:%u.%u=%u", ro ? " " : "", k, dv[i].set, dv[i].binding, slot);
            if (cnt > 1) ro += (size_t)snprintf(res + ro, ro < rescap ? rescap - ro : 0, "*%u", cnt);
        }
        spvc_compiler_set_decoration(c, dv[i].var, SpvDecorationBinding, slot);
    }
    int pc_slot = npc ? (int)nb : -1; if (npc) nb++;
    if (nb > 16 || nt > 31 || ns > 16) { snprintf(err, errcap, "资源槽超限（缓冲 %u / 纹理 %u / 采样器 %u）", nb, nt, ns); goto out; }
    if (ro >= rescap) { snprintf(err, errcap, "资源表太长"); goto out; }
    if (npc) {   // push 常量块不带 Binding 装饰：显式给它那个缓冲槽
        spvc_msl_resource_binding b; spvc_msl_resource_binding_init(&b);
        b.stage = model; b.desc_set = SPVC_MSL_PUSH_CONSTANT_DESC_SET; b.binding = SPVC_MSL_PUSH_CONSTANT_BINDING; b.msl_buffer = (unsigned)pc_slot;
        spvc_compiler_msl_add_resource_binding(c, &b);
    }
    char ep[40]; snprintf(ep, sizeof ep, "vk_%s", key);
    spvc_compiler_rename_entry_point(c, eps[0].name, ep, model);
    spvc_compiler_create_compiler_options(c, &o);
    spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_VERSION, SPVC_MAKE_MSL_VERSION(3, 1, 0));
    spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING, SPVC_TRUE);
    spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_TEXTURE_1D_AS_2D, SPVC_TRUE);
    if (model == SpvExecutionModelVertex) spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_FLIP_VERTEX_Y, SPVC_TRUE);
    spvc_compiler_install_compiler_options(c, o);
    if (model == SpvExecutionModelVertex) for (unsigned l = 0; l < 32; l++) if ((u8 | u16) >> l & 1) {
        spvc_msl_shader_interface_var_2 v; spvc_msl_shader_interface_var_init_2(&v);
        // vecsize 至少 2：SPIRV-Cross 给标量输入换类型走 build_extended_vector_type，分量数 1 时 assert(components > 1) 当场中止（本库带断言编）；
        //   标量照样声明成 2 分量无符号、读 .x，Metal 允许单分量格式读进多分量输入（缺的分量补 0）
        v.location = l; v.vecsize = 2; v.format = u8 >> l & 1 ? SPVC_MSL_SHADER_VARIABLE_FORMAT_UINT8 : SPVC_MSL_SHADER_VARIABLE_FORMAT_UINT16;
        if (spvc_compiler_msl_add_shader_input_2(c, &v) != SPVC_SUCCESS) { snprintf(err, errcap, "顶点输入 %u 的格式提示加不上：%s", l, spvc_context_get_last_error_string(ctx)); goto out; }
    }
    if (spvc_compiler_compile(c, &src) != SPVC_SUCCESS || !src) { snprintf(err, errcap, "SPIRV-Cross 转 MSL 失败：%s", spvc_context_get_last_error_string(ctx)); goto out; }
    // 入口参数段：只留入口真带的资源
    char sig[48]; snprintf(sig, sizeof sig, "%s(", ep);
    const char *a0 = strstr(src, sig); const char *a1 = a0 ? strchr(a0, '{') : NULL;
    if (!a0 || !a1) { snprintf(err, errcap, "翻出的 MSL 里找不到入口 %s", ep); goto out; }
    { char kept[2048] = ""; size_t ko = 0; const char *t = res;
      while (*t) {
          const char *e = strchr(t, ' '); size_t l = e ? (size_t)(e - t) : strlen(t); char one[64]; if (l >= sizeof one) l = sizeof one - 1; memcpy(one, t, l); one[l] = 0;
          unsigned slot = (unsigned)atoi(strchr(one, '=') + 1); const char *cls = one[0] == 'u' || one[0] == 'b' ? "buffer" : one[0] == 's' ? "sampler" : "texture";
          if (arg_has(a0, (size_t)(a1 - a0), cls, slot)) ko += (size_t)snprintf(kept + ko, ko < sizeof kept ? sizeof kept - ko : 0, "%s%s", ko ? " " : "", one);
          t += l; while (*t == ' ') t++;
      }
      if (pc_slot >= 0 && arg_has(a0, (size_t)(a1 - a0), "buffer", (unsigned)pc_slot)) ko += (size_t)snprintf(kept + ko, ko < sizeof kept ? sizeof kept - ko : 0, "%sp:0.0=%d", ko ? " " : "", pc_slot);
      if (*stage == 2) ko += (size_t)snprintf(kept + ko, ko < sizeof kept ? sizeof kept - ko : 0, "%sw:%u.%u=%u", ko ? " " : "", wg[0], wg[1], wg[2]);
      if (ko >= sizeof kept || ko >= rescap) { snprintf(err, errcap, "资源表太长"); goto out; }
      memcpy(res, kept, ko + 1); }
    { char *p1 = replace_all(src, "fast::min(", "precise::min("), *p2 = replace_all(p1, "fast::max(", "precise::max("); free(p1);
      fixed = replace_all(p2, "fast::clamp(", "precise::clamp("); free(p2); }
    if (frag && strstr(fixed, "[[color(1)]]")) {
        char epd[44]; snprintf(epd, sizeof epd, "%s_d(", ep);
        char *d1 = replace_all(fixed, sig, epd); *msl_d = replace_all(d1, "[[color(1)]]", "[[color(0), index(1)]]"); free(d1);
    }
    *msl = fixed; fixed = NULL; rc = 0;
out:
    free(fixed); free(dv); free(w); spvc_context_destroy(ctx);
    return rc;
}
__attribute__((visibility("default")))
int s2a_vk_xlate(const uint32_t *code, size_t nwords, const char *key, char **msl, char **msl_d, char *res, size_t rescap, int *stage, char *err, size_t errcap) {
    return xlate(code, nwords, key, 0, 0, msl, msl_d, res, rescap, stage, err, errcap);
}
// 顶点着色器按管线的顶点格式重翻（hle_vk.m vin_variant）：u8 / u16 见 xlate
__attribute__((visibility("default")))
int s2a_vk_xlate_vin(const uint32_t *code, size_t nwords, const char *key, uint32_t u8, uint32_t u16, char **msl, char *res, size_t rescap, char *err, size_t errcap) {
    char *msl_d = NULL; int stage = 0, rc = xlate(code, nwords, key, u8, u16, msl, &msl_d, res, rescap, &stage, err, errcap);
    free(msl_d); if (!rc && stage) { free(*msl); *msl = NULL; snprintf(err, errcap, "不是顶点着色器"); return -1; }
    return rc;
}
