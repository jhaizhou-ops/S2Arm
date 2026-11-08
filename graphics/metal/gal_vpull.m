// 顶点自取（着色器全量预编第 2 步 2b，10-20）：顶点着色器不再用 [[stage_in]] + 顶点描述符取属性，改由着色器按「顶点取数表」自己从顶点缓冲读字节、按格式解码。
// 目的：管线键去掉顶点布局（顶点布局取决于游戏网格数据，出包不可知），每个程序一个基础管线，出包时全量预编（2c）。Apple GPU 的顶点取数本来就是驱动按描述符
// 生成进着色器的前导代码，这里等于我们自己生成、格式改由运行时表给。
// 做法：SPIRV-Cross 出的 MSL 上做文本改写（同无点大小变体的后处理层）——
//   struct <入口>_in { T m_N [[attribute(L)]]; … } 去掉 [[attribute]]；入口参数 <入口>_in in [[stage_in]] 换成取数表 [[buffer(GAL_VPULL_SLOT)]] + vertex_id / instance_id / base_instance；
//   函数体开头逐成员 in.m_N = s2a_v{f,u,i}(表, L, …)。结构不规整（数组成员、非 4 分量等）就不改，返回空，调用方照旧走顶点描述符（不影响正确性）。
// 取数表（每个用到的位置 24 字节，见 gal_vpull_entry）：u64 地址（0 = 零属性，读 0）、u32 步长 | 格式描述 << 16、u32 步进 | 除数 << 2、u32 从地址起可读字节数、u32 0。
// 越界（10-24 画幅线，图形接口盘点 11）：元素偏移 + 属性字节数 > 可读字节数时整个属性读 0（同零属性）。Maxwell 顶点取数按缓冲上限寄存器截断读 0；
//   Ryujinx Vulkan 绑顶点缓冲时带长度（VertexBufferUpdater.cs CmdBindVertexBuffers2 的 sizes），旧实现只有地址，越界读到相邻内存、出了映射页就是 GPU 访存错。
// 格式描述（gal_vpull_desc）：位 0–1 分量数 − 1、位 2–3 log2(分量字节)、位 4–7 类别（0 unorm 1 snorm 2 uint 3 sint 4 float；8–11 1010102 unorm / snorm / uint / sint；12 11_11_10 浮点；13 9e5 浮点）、位 8 BGRA 交换、
//   位 9 缩放（类别 2 / 3 / 10 / 11 的 uscaled / sscaled：整数值转浮点）
// 三种读法（MSL 成员按翻译口径选）：
//   s2a_vf / s2a_vu / s2a_vi（按类型读，旧口径：着色器按属性类型声明 float4 / uint4 / int4，缩放格式按整数读、着色器自己补换算）；
//   s2a_vr（原始位读，10-21 画面·着色器线，Ryujinx 补丁 vattr-raw：成员名 s2a_raw<位置>、uint4）：按 Maxwell 硬件语义产出寄存器位——
//   浮点 / unorm / snorm / scaled / 打包浮点格式给转换后的浮点位（缺分量补 0, 0, 0, 1.0f），int / uint 格式给整数位（缺分量补 0, 0, 0, 1），着色器指令再按自己的类型解释。
//   原始位着色器与属性类型无关（一个客体着色器一个变体），必须走自取（顶点描述符做不出 unorm → 浮点位），改写不了就是翻译失败
#include "gal_internal.h"
#include "gal_formats.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "gal_vpullc.c"   // 辅助 MSL 原文 k_vpull_msl 与成员读法 gal_vpull_kind（纯 C，曲面翻译段在 Windows 出包机上也要，11-05 拆出）

// GAL 格式 → 格式描述（见文件头）；GAL_VPULL_BAD = 顶点格式不支持（调用方按零属性处理并报红）。0 是合法描述（R8Unorm），不能当「不支持」
NXGAL_API uint32_t gal_vpull_desc(int32_t f) {
#define D(n, lgsz, kind) ((uint32_t)((n) - 1) | (uint32_t)(lgsz) << 2 | (uint32_t)(kind) << 4)
#define S 512u
    switch (f) {
        case F_R8Unorm: return D(1, 0, 0); case F_R8Snorm: return D(1, 0, 1); case F_R8Uint: return D(1, 0, 2); case F_R8Sint: return D(1, 0, 3);
        case F_R16Float: return D(1, 1, 4); case F_R16Unorm: return D(1, 1, 0); case F_R16Snorm: return D(1, 1, 1); case F_R16Uint: return D(1, 1, 2); case F_R16Sint: return D(1, 1, 3);
        case F_R32Float: return D(1, 2, 4); case F_R32Uint: return D(1, 2, 2); case F_R32Sint: return D(1, 2, 3);
        case F_R8G8Unorm: return D(2, 0, 0); case F_R8G8Snorm: return D(2, 0, 1); case F_R8G8Uint: return D(2, 0, 2); case F_R8G8Sint: return D(2, 0, 3);
        case F_R16G16Float: return D(2, 1, 4); case F_R16G16Unorm: return D(2, 1, 0); case F_R16G16Snorm: return D(2, 1, 1); case F_R16G16Uint: return D(2, 1, 2); case F_R16G16Sint: return D(2, 1, 3);
        case F_R32G32Float: return D(2, 2, 4); case F_R32G32Uint: return D(2, 2, 2); case F_R32G32Sint: return D(2, 2, 3);
        case F_R8G8B8Unorm: return D(3, 0, 0); case F_R8G8B8Snorm: return D(3, 0, 1); case F_R8G8B8Uint: return D(3, 0, 2); case F_R8G8B8Sint: return D(3, 0, 3);
        case F_R16G16B16Float: return D(3, 1, 4); case F_R16G16B16Unorm: return D(3, 1, 0); case F_R16G16B16Snorm: return D(3, 1, 1); case F_R16G16B16Uint: return D(3, 1, 2); case F_R16G16B16Sint: return D(3, 1, 3);
        case F_R32G32B32Float: return D(3, 2, 4); case F_R32G32B32Uint: return D(3, 2, 2); case F_R32G32B32Sint: return D(3, 2, 3);
        case F_R8G8B8A8Unorm: return D(4, 0, 0); case F_R8G8B8A8Snorm: return D(4, 0, 1); case F_R8G8B8A8Uint: return D(4, 0, 2); case F_R8G8B8A8Sint: return D(4, 0, 3);
        case F_R16G16B16A16Float: return D(4, 1, 4); case F_R16G16B16A16Unorm: return D(4, 1, 0); case F_R16G16B16A16Snorm: return D(4, 1, 1); case F_R16G16B16A16Uint: return D(4, 1, 2); case F_R16G16B16A16Sint: return D(4, 1, 3);
        case F_R32G32B32A32Float: return D(4, 2, 4); case F_R32G32B32A32Uint: return D(4, 2, 2); case F_R32G32B32A32Sint: return D(4, 2, 3);
        case F_R10G10B10A2Unorm: return 8u << 4; case F_R10G10B10A2Snorm: return 9u << 4; case F_R10G10B10A2Uint: return 10u << 4; case F_R10G10B10A2Sint: return 11u << 4;
        case F_R11G11B10Float: return 12u << 4; case F_R9G9B9E5Float: return 13u << 4;
        case F_B8G8R8A8Unorm: return D(4, 0, 0) | 256u;
        case F_A8B8G8R8Uint: return D(4, 0, 2);   // 小端内存字节序 R G B A，同 R8G8B8A8Uint（同 gal_state.m vfmt）
        // 缩放整数（能力表报顶点自取时 Gpu 层原样交来，Ryujinx 补丁 vattr-raw）：类别同 uint / sint，位 9 标缩放——原始位读转浮点，按类型读仍是整数（旧口径着色器自己补换算）
        case F_R8Uscaled: return D(1, 0, 2) | S; case F_R8Sscaled: return D(1, 0, 3) | S; case F_R16Uscaled: return D(1, 1, 2) | S; case F_R16Sscaled: return D(1, 1, 3) | S;
        case F_R32Uscaled: return D(1, 2, 2) | S; case F_R32Sscaled: return D(1, 2, 3) | S;
        case F_R8G8Uscaled: return D(2, 0, 2) | S; case F_R8G8Sscaled: return D(2, 0, 3) | S; case F_R16G16Uscaled: return D(2, 1, 2) | S; case F_R16G16Sscaled: return D(2, 1, 3) | S;
        case F_R32G32Uscaled: return D(2, 2, 2) | S; case F_R32G32Sscaled: return D(2, 2, 3) | S;
        case F_R8G8B8Uscaled: return D(3, 0, 2) | S; case F_R8G8B8Sscaled: return D(3, 0, 3) | S; case F_R16G16B16Uscaled: return D(3, 1, 2) | S; case F_R16G16B16Sscaled: return D(3, 1, 3) | S;
        case F_R32G32B32Uscaled: return D(3, 2, 2) | S; case F_R32G32B32Sscaled: return D(3, 2, 3) | S;
        case F_R8G8B8A8Uscaled: return D(4, 0, 2) | S; case F_R8G8B8A8Sscaled: return D(4, 0, 3) | S; case F_R16G16B16A16Uscaled: return D(4, 1, 2) | S; case F_R16G16B16A16Sscaled: return D(4, 1, 3) | S;
        case F_R32G32B32A32Uscaled: return D(4, 2, 2) | S; case F_R32G32B32A32Sscaled: return D(4, 2, 3) | S;
        case F_R10G10B10A2Uscaled: return 10u << 4 | S; case F_R10G10B10A2Sscaled: return 11u << 4 | S;
    }
    return GAL_VPULL_BAD;
#undef S
#undef D
}

// 取数表一项（GAL_VPULL_ENTRY = 24 字节，与 MSL S2AVtxAttr 同布局）；len = 从 addr 起可读的字节数
NXGAL_API void gal_vpull_entry(uint32_t *o, uint64_t addr, uint32_t stride, uint32_t desc, uint32_t step, uint32_t divisor, uint32_t len) {
    memcpy(o, &addr, 8); o[2] = (stride & 0xffffu) | desc << 16; o[3] = (step & 3u) | divisor << 2; o[4] = len; o[5] = 0;
}

// 顶点着色器 MSL 的输入结构体里有没有原始位成员（有就必须走自取，gal_prog.m）
int gal_vpull_raw_in(const char *msl, const char *entry) {
    char hdr[160]; snprintf(hdr, sizeof hdr, "struct %s_in\n{\n", entry);
    const char *sb = strstr(msl, hdr); if (!sb) return 0;
    const char *se = strstr(sb, "\n};\n"); if (!se) return 0;
    const char *r = strstr(sb, " s2a_raw");
    return r && r < se;
}
// MSL 改写：成功返回新串（调用方 free），不规整返回 NULL（照旧走顶点描述符）
static char *vp_dup(const char *s, size_t n) { char *r = malloc(n + 1); memcpy(r, s, n); r[n] = 0; return r; }
// in_struct：stage_in 结构体名。gal 一个入口一个结构体（<入口>_in，gal_vpull_msl）；直连 MSL 的 main0 / main0_z / main0_gs 共用 main0_in（nxgal_dmsh_link）。
//   签名在该入口那一行里找（不是结构体后第一处），改写后其余共用结构体的入口不再可编
char *gal_vpull_msl_in(const char *msl, const char *entry, const char *in_struct) {
    char hdr[160]; snprintf(hdr, sizeof hdr, "struct %s\n{\n", in_struct);
    const char *sb = strstr(msl, hdr); if (!sb) return NULL;
    const char *se = strstr(sb, "\n};\n"); if (!se) return NULL;
    // 成员：「    float4 m_100 [[attribute(0)]];」，类型只认 float4 / uint4 / int4
    typedef struct { char ty, name[64]; int loc; } mb;
    mb m[32]; int nm = 0;
    char *body = vp_dup(sb + strlen(hdr), (size_t)(se - (sb + strlen(hdr))));
    char nb[4096]; size_t nbl = 0;
    char *sv = NULL;   // strtok_r：10-20 并行 gal_xc 里 strtok 的全局切分状态被别的线程改，1.59 万支里 4～7 支 _in 结构串成别的着色器的成员
    for (char *line = strtok_r(body, "\n", &sv); line; line = strtok_r(NULL, "\n", &sv)) {
        char ty[16], name[64]; int loc;
        if (sscanf(line, " %15s %63s [[attribute(%d)]];", ty, name, &loc) != 3 || nm >= 32 || loc < 0 || loc >= 32 || strchr(name, '[')) { free(body); return NULL; }
        char c = gal_vpull_kind(ty, name); if (!c) { free(body); return NULL; }
        m[nm].ty = c; snprintf(m[nm].name, sizeof m[nm].name, "%s", name); m[nm].loc = loc; nm++;
        int w = snprintf(nb + nbl, sizeof nb - nbl, "    %s %s;\n", ty, name); if (w < 0 || (size_t)w >= sizeof nb - nbl) { free(body); return NULL; } nbl += (size_t)w;
    }
    free(body);
    if (!nm) return NULL;
    // 入口签名
    char sig[200], ent[160]; snprintf(sig, sizeof sig, "%s in [[stage_in]]", in_struct); snprintf(ent, sizeof ent, " %s(", entry);
    const char *sp = NULL, *ln_s = NULL, *ln_e = NULL;
    for (const char *l = se; l && *l; l = strchr(l, '\n') ? strchr(l, '\n') + 1 : NULL) {   // 行首 vertex、带「 <入口>(」的那一行
        const char *e = strchr(l, '\n'); if (!e) break;
        if (strncmp(l, "vertex ", 7)) continue;
        const char *n = strstr(l, ent); if (!n || n > e) continue;
        const char *q = strstr(l, sig); if (!q || q > e) return NULL;
        sp = q; ln_s = l; ln_e = e; break;
    }
    if (!sp) return NULL;
    const char *brace = strstr(ln_e, "\n{\n"); if (!brace) return NULL;
    // 签名里已有的 vertex_id / instance_id / base_instance 参数沿用其名字，没有就加
    char line[8192]; size_t ll = (size_t)(ln_e - ln_s); if (ll >= sizeof line) return NULL; memcpy(line, ln_s, ll); line[ll] = 0;
    const char *attrs[3] = {"[[vertex_id]]", "[[instance_id]]", "[[base_instance]]"}; char nm3[3][64] = {"s2a_vid", "s2a_iid", "s2a_bi"}; int have[3] = {0, 0, 0};
    for (int k = 0; k < 3; k++) {
        const char *a = strstr(line, attrs[k]); if (!a) continue;
        const char *e = a; while (e > line && e[-1] == ' ') e--; const char *b = e; while (b > line && b[-1] != ' ') b--;
        if (e - b <= 0 || e - b >= 63) return NULL; memcpy(nm3[k], b, (size_t)(e - b)); nm3[k][e - b] = 0; have[k] = 1;
    }
    char add[512]; snprintf(add, sizeof add, "constant S2AVtxAttr* s2a_vt [[buffer(%d)]]%s%s%s%s%s%s", GAL_VPULL_SLOT,
        have[0] ? "" : ", uint s2a_vid [[vertex_id]]", "", have[1] ? "" : ", uint s2a_iid [[instance_id]]", "", have[2] ? "" : ", uint s2a_bi [[base_instance]]", "");
    char init[4096]; size_t il = (size_t)snprintf(init, sizeof init, "    %s in = {};\n", in_struct);
    for (int i = 0; i < nm && il < sizeof init; i++)
        il += (size_t)snprintf(init + il, sizeof init - il, "    in.%s = s2a_v%c(s2a_vt, %d, %s, %s, %s);\n", m[i].name, m[i].ty, m[i].loc, nm3[0], nm3[1], nm3[2]);
    if (il >= sizeof init) return NULL;
    // 拼：文件头（第一个 using namespace metal; 之后插辅助）… 结构体（去属性）… 签名（换参数）… 函数体开头（取数）
    const char *ns = strstr(msl, "using namespace metal;\n"); if (!ns || ns > sb) return NULL; ns += strlen("using namespace metal;\n");
    size_t cap = strlen(msl) + sizeof k_vpull_msl + nbl + strlen(add) + il + 64;
    char *o = malloc(cap), *w = o;
#define PUT(p, n) do { memcpy(w, (p), (n)); w += (n); } while (0)
    PUT(msl, (size_t)(ns - msl)); PUT(k_vpull_msl, strlen(k_vpull_msl));
    PUT(ns, (size_t)(sb + strlen(hdr) - ns)); PUT(nb, nbl); PUT(se + 1, (size_t)(ln_s - (se + 1)));
    PUT(ln_s, (size_t)(sp - ln_s)); PUT(add, strlen(add)); PUT(sp + strlen(sig), (size_t)(brace + 3 - (sp + strlen(sig))));
    PUT(init, il); { size_t rest = strlen(brace + 3); PUT(brace + 3, rest); }
#undef PUT
    *w = 0;
    return o;
}
char *gal_vpull_msl(const char *msl, const char *entry) { char in[160]; snprintf(in, sizeof in, "%s_in", entry); return gal_vpull_msl_in(msl, entry, in); }
