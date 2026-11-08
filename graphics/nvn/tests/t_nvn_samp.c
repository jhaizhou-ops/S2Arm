// Sampler / Buffer 调试与边界色（#270 N12）：
//   · SamplerBuilder 的整数 / 无符号整数边界色写进 samp_par.border，SamplerGetBorderColorui 读回（负数按 0、四舍五入）；
//   · Sampler / Buffer 的调试 ID：对象存活期间稳定、不同对象不同（本层用对象地址）。
//   · Sampler 对象布局（#100 奥德赛帽子国高光闪烁）：全部状态都在字节 [8, 0x30) 里。游戏的采样器缓存按对象 [8, ...) 算 CRC 去重，
//     状态落在 0–7 字节的话只差过滤 / 环绕的两个采样器 CRC 相同，缓存反复重分配、重新登记同一 ID，已录制的绘制回放时读到被覆盖的状态。
#include "../gfx/nvn/nvn_obj.h"
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
static int bad;
static void *api(const char *n) { void *p = h_nvnBootstrapLoader(n); if (!p) { fprintf(stderr, "找不到公开 API：%s\n", n); bad++; } return p; }
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)

int main(void) {
    NVNT_nvnSamplerBuilderSetBorderColori seti = (NVNT_nvnSamplerBuilderSetBorderColori)api("nvnSamplerBuilderSetBorderColori");
    NVNT_nvnSamplerBuilderSetBorderColorui setui = (NVNT_nvnSamplerBuilderSetBorderColorui)api("nvnSamplerBuilderSetBorderColorui");
    NVNT_nvnSamplerGetBorderColorui getui = (NVNT_nvnSamplerGetBorderColorui)api("nvnSamplerGetBorderColorui");
    NVNT_nvnSamplerGetDebugID sampid = (NVNT_nvnSamplerGetDebugID)api("nvnSamplerGetDebugID");
    NVNT_nvnBufferGetDebugID bufid = (NVNT_nvnBufferGetDebugID)api("nvnBufferGetDebugID");
    if (bad) return 1;

    union { NVNsamplerBuilder b; NVNsampler s; char raw[256]; } u;
    memset(&u, 0, sizeof u);

    // builder 的 samp_par 在 dev 之后（偏移 8），sampler 的在 8 字节对象头之后（偏移 8），各自的头不同，不能直接把 builder 当 sampler 读：
    // 真游戏是先 SamplerInitialize 把参数抄进对象再查询，这里照同样方式造一个 sampler
    union { NVNsampler s; char raw[256]; } so;
    memset(&so, 0, sizeof so);

    // ① 整数边界色：写 (−1, 2, 3, 4) → 读回 (0, 2, 3, 4)（负数按 0）
    int ci[4] = {-1, 2, 3, 4};
    seti(&u.b, ci);
    memcpy(&((samp_t *)&so.s)->p, &((samp_builder_t *)&u.b)->p, sizeof(samp_par));
    uint32_t back[4] = {0, 0, 0, 0};
    getui(&so.s, back);
    CHECK(back[0] == 0 && back[1] == 2 && back[2] == 3 && back[3] == 4,
          "整数边界色读回不符：%u %u %u %u", back[0], back[1], back[2], back[3]);

    // ② 无符号边界色：原样往返
    uint32_t cu[4] = {10, 20, 30, 40};
    setui(&u.b, cu);
    memcpy(&((samp_t *)&so.s)->p, &((samp_builder_t *)&u.b)->p, sizeof(samp_par));
    memset(back, 0, sizeof back);
    getui(&so.s, back);
    CHECK(back[0] == 10 && back[1] == 20 && back[2] == 30 && back[3] == 40,
          "无符号边界色读回不符：%u %u %u %u", back[0], back[1], back[2], back[3]);

    // ③ 调试 ID：同对象稳定、不同对象不同
    char other[256];
    memset(other, 0, sizeof other);
    uint64_t a1 = sampid((const NVNsampler *)&u), a2 = sampid((const NVNsampler *)&u), b1 = sampid((const NVNsampler *)other);
    CHECK(a1 == a2, "SamplerGetDebugID 同对象不稳定：%llu vs %llu", (unsigned long long)a1, (unsigned long long)a2);
    CHECK(a1 != b1, "SamplerGetDebugID 不同对象相同：%llu", (unsigned long long)a1);
    uint64_t p1 = bufid((const NVNbuffer *)&u), p2 = bufid((const NVNbuffer *)other);
    CHECK(p1 != p2, "BufferGetDebugID 不同对象相同：%llu", (unsigned long long)p1);

    // ④ 对象布局：两个只差某一项状态的 sampler，字节 [0, 8) 相同、[8, 0x30) 不同；所有枚举取最大合法值经公开 API 往返不丢
    {
        NVNT_nvnSamplerBuilderSetDefaults defs = (NVNT_nvnSamplerBuilderSetDefaults)api("nvnSamplerBuilderSetDefaults");
        NVNT_nvnSamplerBuilderSetMinMagFilter setf = (NVNT_nvnSamplerBuilderSetMinMagFilter)api("nvnSamplerBuilderSetMinMagFilter");
        NVNT_nvnSamplerBuilderSetWrapMode setw = (NVNT_nvnSamplerBuilderSetWrapMode)api("nvnSamplerBuilderSetWrapMode");
        NVNT_nvnSamplerBuilderSetCompare setc = (NVNT_nvnSamplerBuilderSetCompare)api("nvnSamplerBuilderSetCompare");
        NVNT_nvnSamplerBuilderSetReductionFilter setr = (NVNT_nvnSamplerBuilderSetReductionFilter)api("nvnSamplerBuilderSetReductionFilter");
        NVNT_nvnSamplerInitialize init = (NVNT_nvnSamplerInitialize)api("nvnSamplerInitialize");
        NVNT_nvnSamplerGetMinMagFilter getf = (NVNT_nvnSamplerGetMinMagFilter)api("nvnSamplerGetMinMagFilter");
        NVNT_nvnSamplerGetWrapMode getw = (NVNT_nvnSamplerGetWrapMode)api("nvnSamplerGetWrapMode");
        NVNT_nvnSamplerGetCompare getc = (NVNT_nvnSamplerGetCompare)api("nvnSamplerGetCompare");
        NVNT_nvnSamplerGetReductionFilter getr = (NVNT_nvnSamplerGetReductionFilter)api("nvnSamplerGetReductionFilter");
        if (bad) return 1;
        enum { MINF, MAGF, WS, WT, WR, NK };
        static const char *kn[NK] = {"min 过滤", "mag 过滤", "S 环绕", "T 环绕", "R 环绕"};
        for (int k = 0; k < NK; k++) {
            union { NVNsamplerBuilder b; char raw[256]; } b0, b1; union { NVNsampler s; char raw[256]; } s0, s1;
            memset(&b0, 0, sizeof b0); memset(&b1, 0, sizeof b1); memset(&s0, 0, sizeof s0); memset(&s1, 0, sizeof s1);
            defs(&b0.b); defs(&b1.b);
            setf(&b1.b, k == MINF ? NVN_MIN_FILTER_NEAREST : NVN_MIN_FILTER_LINEAR, k == MAGF ? NVN_MAG_FILTER_NEAREST : NVN_MAG_FILTER_LINEAR);
            setw(&b1.b, k == WS ? NVN_WRAP_MODE_CLAMP : NVN_WRAP_MODE_REPEAT, k == WT ? NVN_WRAP_MODE_CLAMP : NVN_WRAP_MODE_REPEAT, k == WR ? NVN_WRAP_MODE_CLAMP : NVN_WRAP_MODE_REPEAT);
            init(&s0.s, &b0.b); init(&s1.s, &b1.b);
            CHECK(!memcmp(s0.raw, s1.raw, 8), "只差%s的两个 sampler 字节 [0, 8) 不同（状态不该放在这里：游戏的缓存 CRC 不覆盖）", kn[k]);
            CHECK(memcmp(s0.raw + 8, s1.raw + 8, sizeof(NVNsampler) - 8), "只差%s的两个 sampler 字节 [8, 0x%zx) 全同（游戏缓存按这段算 CRC，会撞）", kn[k], sizeof(NVNsampler));
        }
        union { NVNsamplerBuilder b; char raw[256]; } bm; union { NVNsampler s; char raw[256]; } sm;
        memset(&bm, 0, sizeof bm); memset(&sm, 0, sizeof sm); defs(&bm.b);
        setf(&bm.b, NVN_MIN_FILTER_LINEAR_MIPMAP_LINEAR, NVN_MAG_FILTER_LINEAR);
        setw(&bm.b, NVN_WRAP_MODE_MIRRORED_REPEAT, NVN_WRAP_MODE_CLAMP_TO_EDGE, NVN_WRAP_MODE_CLAMP_TO_BORDER);
        setc(&bm.b, NVN_COMPARE_MODE_COMPARE_R_TO_TEXTURE, NVN_COMPARE_FUNC_ALWAYS); setr(&bm.b, NVN_SAMPLER_REDUCTION_MAX);
        init(&sm.s, &bm.b);
        NVNminFilter mi; NVNmagFilter ma; NVNwrapMode w0, w1, w2; NVNcompareMode cm; NVNcompareFunc cf;
        getf(&sm.s, &mi, &ma); getw(&sm.s, &w0, &w1, &w2); getc(&sm.s, &cm, &cf);
        CHECK(mi == NVN_MIN_FILTER_LINEAR_MIPMAP_LINEAR && ma == NVN_MAG_FILTER_LINEAR, "过滤往返不符：%d %d", (int)mi, (int)ma);
        CHECK(w0 == NVN_WRAP_MODE_MIRRORED_REPEAT && w1 == NVN_WRAP_MODE_CLAMP_TO_EDGE && w2 == NVN_WRAP_MODE_CLAMP_TO_BORDER, "环绕往返不符：%d %d %d", (int)w0, (int)w1, (int)w2);
        CHECK(cm == NVN_COMPARE_MODE_COMPARE_R_TO_TEXTURE && cf == NVN_COMPARE_FUNC_ALWAYS, "比较往返不符：%d %d", (int)cm, (int)cf);
        CHECK(getr(&sm.s) == NVN_SAMPLER_REDUCTION_MAX, "归约往返不符：%d", (int)getr(&sm.s));
    }

    printf("%s t_nvn_samp：整数/无符号边界色往返、Sampler/Buffer 调试 ID 稳定唯一、Sampler 状态全在字节 [8, 0x30) → %s\n", bad ? "✗" : "✓", bad ? "有不符合项" : "通过");
    return bad != 0;
}
