// 审计 #1534 被动采样的计数会动（#1646 P1-65 / P1-23 起改了行为：界长表按指针后实际字节封顶、没打栅栏的 QueueWaitSync 回假）：直接包含生产 nvn_mtl.m，链 libnvn.a（hle_nvn.c 的 nvnQueueWaitSync 经引导表取）。期望按定义手写，与实现无关：
//   P1-65 界长表：着色器带 cb0 + 界长表（NVN_RB_UBOLEN），走生产 encode_args
//     ① cb0 绑在池头、4096 字节（池 64 KB）→ 表长 4096 ≤ 后面 64 KB：越界 0、建表 1
//     ② cb0 绑在池末 256 字节处、声明 4096 字节 → 表 4096 > 指针后 256（池缓冲到页尾）：「越过池缓冲末尾」1、宽屏 0
//     ③ 宽屏改写副本只拷了 256 字节（g_wd_last.len）、表 4096 → 「宽屏副本」1、池 0
//     ④ 着色器没有界长表、绑定同 ② → 不建表、不计（计数只看有表的参数表）
//   P1-23 等待：⑧ QueueWaitSync 等没打栅栏的同步对象 → 未打栅栏 1；打过栅栏的 → 0（GPU 等事件强放计数随 main ca7f9b478 撤销一并去掉）
//   P1-20 纹理类型：⑨ 声明 2D、实绑 2D RGBA8 → 0；⑩ 声明 2D、实绑 3D → 类型不符 1；⑪ 同 ⑩ 且该槽库元数据记「缺类型按 2D」→ 其中缺省 2D 1；
//     ⑫ 声明 uint、实绑 RGBA8Unorm → 像素类不符 1；声明 float 实绑深度格式 → 0（Metal 合法）
#include "../gfx/nvn/nvn_mtl.m"
#include "nvn_protos.h"
#include <sys/mman.h>
extern void *h_nvnBootstrapLoader(const char *name);
extern uint64_t g_nvn_qws_n, g_nvn_qws_unfenced;
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
#define API(name) ((NVNT_##name)h_nvnBootstrapLoader(#name))
static NvShader *cb_shader(int with_table) {   // 片元：cb0（参数 0）+ 可选界长表（参数 1）
    NvShader *sh = [NvShader new]; sh->stage = 1; sh->arg_len = 16; strcpy(sh->key, "t_audit_p65");
    sh->rf.nb = with_table ? 2 : 1; sh->rf.b = calloc(2, sizeof *sh->rf.b);
    sh->rf.b[0].kind = NVN_RB_CBUF; sh->rf.b[0].reg = 0; sh->rf.b[0].aid = 0;
    sh->rf.b[1].kind = NVN_RB_UBOLEN; sh->rf.b[1].aid = 1;
    return sh;
}
static void enc(NvShader *sh, uint64_t addr, uint64_t size) { S.ubo[1][0].addr = addr; S.ubo[1][0].size = size; args_dirty_all(); encode_args(nil, sh, 1, 0); }
// 审计 #1646 P1-65：读回这一笔写出的界长表第 0 项（cb0 的 vec4 个数）：参数缓冲第 1 个槽是表的 GPU 地址，按暂存块换回 CPU 地址
static uint32_t table0(NvShader *sh) {
    uint64_t g = ((const uint64_t *)((const uint8_t *)sh->ab_buf.contents + sh->ab_off))[1];
    for (NSArray *list in @[g_sub_arenas, g_arenas]) for (NvArena *a in list) if (g >= a->gpu && g < a->gpu + a->len) return *(const uint32_t *)(a->cpu + (g - a->gpu));
    REQUIRE(!"界长表地址不在任何暂存块里"); return 0;
}
static id<MTLTexture> mk_tex(MTLTextureType tt, MTLPixelFormat pf) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor new]; d.textureType = tt; d.pixelFormat = pf; d.width = d.height = 4; d.depth = tt == MTLTextureType3D ? 4 : 1; d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageShaderRead; id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; REQUIRE(t); return t;
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    setenv("DM_NVN_ENC_THREAD", "0", 0); setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init(); arena_begin();
    // ---------- P1-65 ----------
    size_t psz = 65536; uint8_t *pool = mmap(NULL, psz, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); REQUIRE(pool != MAP_FAILED);
    nvn_be_pool_add(pool, psz);
    NvShader *sh = cb_shader(1), *bare = cb_shader(0);
    uint64_t t0 = g_p65_tables, w0 = g_p65_wd, p0 = g_p65_pool;
    enc(sh, (uint64_t)(uintptr_t)pool, 4096);
    VERIFY(g_p65_tables == t0 + 1 && g_p65_pool == p0 && g_p65_wd == w0, "① 池头 4096 字节：建表 +%llu（期望 1）、池末越界 +%llu、宽屏 +%llu（期望 0 / 0）",
           (unsigned long long)(g_p65_tables - t0), (unsigned long long)(g_p65_pool - p0), (unsigned long long)(g_p65_wd - w0));
    VERIFY(table0(sh) == 256, "① 表值 %u（期望 4096 / 16 = 256：指针后有 64 KB，按绑定长度）", table0(sh));
    t0 = g_p65_tables; p0 = g_p65_pool;
    enc(sh, (uint64_t)(uintptr_t)(pool + psz - 256), 4096);
    // #1646 P1-65 修后：表按指针后实际的整 vec4 封顶，探针比的是写出的表，不再越界
    VERIFY(g_p65_tables == t0 + 1 && g_p65_pool == p0 && g_p65_wd == w0, "② 池末 256 字节处声明 4096：池末越界 +%llu（期望 0：表已封顶）、宽屏 +%llu（期望 0）", (unsigned long long)(g_p65_pool - p0), (unsigned long long)(g_p65_wd - w0));
    VERIFY(table0(sh) == 16, "② 表值 %u（期望 256 / 16 = 16：指针后只剩 256 字节，不按声明的 4096）", table0(sh));
    p0 = g_p65_pool;
    g_wd = 1; g_wd_gpu[1][0] = support_gpu(); g_wd_last[1][0].len = 256;
    enc(sh, (uint64_t)(uintptr_t)pool, 4096); uint32_t tb3 = table0(sh);
    g_wd = -1; g_wd_gpu[1][0] = 0; g_wd_last[1][0].len = 0;
    VERIFY(g_p65_wd == w0 && g_p65_pool == p0, "③ 宽屏副本 256 字节、绑定 4096：宽屏 +%llu（期望 0：表已封顶）、池末 +%llu（期望 0）", (unsigned long long)(g_p65_wd - w0), (unsigned long long)(g_p65_pool - p0));
    VERIFY(tb3 == 16, "③ 表值 %u（期望 256 / 16 = 16：副本只拷了 256 字节）", tb3);
    t0 = g_p65_tables; p0 = g_p65_pool; w0 = g_p65_wd;
    enc(bare, (uint64_t)(uintptr_t)(pool + psz - 256), 4096);
    VERIFY(g_p65_tables == t0 && g_p65_pool == p0 && g_p65_wd == w0, "④ 没有界长表：建表 +%llu、越界 +%llu（期望 0 / 0）", (unsigned long long)(g_p65_tables - t0), (unsigned long long)(g_p65_pool + g_p65_wd - p0 - w0));
    // ---------- P1-23 ----------
    // GPU 等事件的强放计数随 main ca7f9b478 撤销「GPU 等事件」一并去掉，只留 QueueWaitSync 未打栅栏计数
    NVNdevice dev; NVNqueue q; memset(&dev, 0, sizeof dev); memset(&q, 0, sizeof q);
    NVNsync bare_s, fenced; API(nvnSyncInitialize)(&bare_s, &dev); API(nvnSyncInitialize)(&fenced, &dev);
    API(nvnQueueFenceSync)(&q, &fenced, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
    uint64_t q0 = g_nvn_qws_n, u0 = g_nvn_qws_unfenced;
    NVNboolean rf = API(nvnQueueWaitSync)(&q, &fenced);
    VERIFY(g_nvn_qws_n == q0 + 1 && g_nvn_qws_unfenced == u0, "⑧ 打过栅栏的 QueueWaitSync：等待 +%llu、未打栅栏 +%llu（期望 1 / 0）", (unsigned long long)(g_nvn_qws_n - q0), (unsigned long long)(g_nvn_qws_unfenced - u0));
    NVNboolean rb = API(nvnQueueWaitSync)(&q, &bare_s);
    VERIFY(rf == 1 && rb == 0, "⑧ 返回值：打过栅栏 %d（期望 1）、没打栅栏 %d（期望 0：宿主等不了，不报成功；审计 #1646 P1-23）", (int)rf, (int)rb);
    VERIFY(g_nvn_qws_n == q0 + 2 && g_nvn_qws_unfenced == u0 + 1, "⑧ 没打栅栏的 QueueWaitSync：等待 +%llu、未打栅栏 +%llu（期望 2 / 1，累计）", (unsigned long long)(g_nvn_qws_n - q0), (unsigned long long)(g_nvn_qws_unfenced - u0));
    // ---------- P1-20 ----------
    NvShader *ts = [NvShader new]; strcpy(ts->key, "t_audit_p20");
    nvn_rbind b = {0}; b.kind = NVN_RB_TEX; b.reg = 3; b.dtt = (uint8_t)MTLTextureType2D; b.dpf = NVN_DPF_FLOAT;
    id<MTLTexture> t2 = mk_tex(MTLTextureType2D, MTLPixelFormatRGBA8Unorm), t3 = mk_tex(MTLTextureType3D, MTLPixelFormatRGBA8Unorm), tz = mk_tex(MTLTextureType2D, MTLPixelFormatDepth32Float);
    uint64_t c0 = g_p20_checked, y0 = g_p20_type, d0 = g_p20_type_d2d, k0 = g_p20_cls;
    p20_check(ts, 1, &b, -1, (__bridge void *)t2);
    VERIFY(g_p20_checked == c0 + 1 && g_p20_type == y0 && g_p20_cls == k0, "⑨ 2D 对 2D：比 +%llu、类型不符 +%llu、像素类不符 +%llu（期望 1 / 0 / 0）",
           (unsigned long long)(g_p20_checked - c0), (unsigned long long)(g_p20_type - y0), (unsigned long long)(g_p20_cls - k0));
    p20_check(ts, 1, &b, -1, (__bridge void *)t3);
    VERIFY(g_p20_type == y0 + 1 && g_p20_type_d2d == d0 && g_p20_cls == k0, "⑩ 声明 2D 实绑 3D：类型不符 +%llu、其中缺省 2D +%llu、像素类 +%llu（期望 1 / 0 / 0）",
           (unsigned long long)(g_p20_type - y0), (unsigned long long)(g_p20_type_d2d - d0), (unsigned long long)(g_p20_cls - k0));
    ts->d2d[0] |= 1ull << 3;
    p20_check(ts, 1, &b, -1, (__bridge void *)t3);
    VERIFY(g_p20_type == y0 + 2 && g_p20_type_d2d == d0 + 1, "⑪ 同上、该槽库里记缺类型按 2D：类型不符 +%llu、其中缺省 2D +%llu（期望 2 / 1，累计）", (unsigned long long)(g_p20_type - y0), (unsigned long long)(g_p20_type_d2d - d0));
    nvn_rbind bu = b; bu.dpf = NVN_DPF_UINT;
    p20_check(ts, 1, &bu, -1, (__bridge void *)t2);
    p20_check(ts, 1, &b, -1, (__bridge void *)tz);
    VERIFY(g_p20_cls == k0 + 1 && g_p20_type == y0 + 2, "⑫ 声明 uint 实绑 RGBA8Unorm、声明 float 实绑 Depth32Float：像素类不符 +%llu（期望 1：只算前者）、类型 +%llu（期望仍 2）",
           (unsigned long long)(g_p20_cls - k0), (unsigned long long)(g_p20_type - y0));
    audit_probe_report(300);
  }
    if (failures) { printf("✗ t_nvn_audit1534_probes：%u 项里 %u 项不符\n", checks, failures); return 1; }
    printf("✓ t_nvn_audit1534_probes：%u 项全过（审计 #1534 被动采样：P1-65 界长表两种越界、P1-23 未打栅栏的等待、P1-20 纹理类型 / 像素类不符，命中计 1、正常计 0）\n", checks); return 0;
}
