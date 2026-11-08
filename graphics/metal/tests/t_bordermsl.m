// 自定义边框色 MSL 改写（gal_border.m gal_border_msl）单测：SPIRV-Cross 形态的手写 MSL，逐条核对改写与不改写的场合，改写结果须能被 Metal 编过。
// 期望按改写规则手写（不跑被测实现）：入口里对登记的单个采样器的 .sample( / .gather( 改走辅助函数；比较采样、数组采样器、入口外函数、未登记采样器不动
#import <Metal/Metal.h>
#include "../gal_internal.h"
#include <stdio.h>
#include <string.h>

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

static const char k_src[] =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct spvDescriptorSetBuffer2\n{\n"
"    texture2d<float> m_7 [[id(0)]];\n    sampler m_7Smplr [[id(1)]];\n"
"    depth2d<float> m_9 [[id(2)]];\n    sampler m_9Smplr [[id(3)]];\n"
"    array<texture2d<float>, 2> m_11 [[id(4)]];\n    array<sampler, 2> m_11Smplr [[id(6)]];\n"
"    texture2d<float> m_13 [[id(8)]];\n    sampler m_13Smplr [[id(9)]];\n"
"};\n"
"struct s1_out { float4 m_2 [[color(0)]]; float4 m_3 [[color(1)]]; };\n"
"static inline float4 helper(texture2d<float> t, sampler s, float2 uv) { return t.sample(s, uv); }\n"
"fragment s1_out s1(constant spvDescriptorSetBuffer2& spvDescriptorSet2 [[buffer(2)]], float4 gl_FragCoord [[position]])\n"
"{\n"
"    s1_out out = {};\n"
"    float2 uv = gl_FragCoord.xy * 0.25;\n"
"    if (uv.x > 0.5) { uv.y += 1.0; }\n"
"    float4 a = spvDescriptorSet2.m_7.sample(spvDescriptorSet2.m_7Smplr, uv, level(0.0));\n"
"    float c = spvDescriptorSet2.m_9.sample_compare(spvDescriptorSet2.m_9Smplr, uv, 0.5);\n"
"    float4 d = spvDescriptorSet2.m_11[1].sample(spvDescriptorSet2.m_11Smplr[1], uv);\n"
"    float4 e = spvDescriptorSet2.m_7.sample(spvDescriptorSet2.m_7Smplr, spvDescriptorSet2.m_13.sample(spvDescriptorSet2.m_13Smplr, uv).xy, bias(1.0));\n"
"    float4 g = spvDescriptorSet2.m_7.gather(spvDescriptorSet2.m_7Smplr, uv, int2(1, 0), component::w);\n"
"    float4 h = helper(spvDescriptorSet2.m_13, spvDescriptorSet2.m_13Smplr, uv);\n"
"    out.m_2 = a + c + d + e;\n    out.m_3 = g + h;\n"
"    return out;\n"
"}\n";

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("· 边框改写：单个采样器 sample / gather（含 level / bias / 偏移 / 嵌套）改写，比较采样 / 数组 / 入口外 / 未登记不动；改写后 Metal 编得过\n");
    const char *names[] = {"m_7Smplr", "m_9Smplr", "m_13Smplr"}; const uint16_t binds[] = {128, 130, 133};
    char *o = gal_border_msl(k_src, "s1", names, binds, 3);
    CHECK(o != NULL, "应有可改写的采样，实得 NULL");
    if (!o) { printf("失败：%d / %d 项通过\n", g_checks - g_fail, g_checks); return 1; }
    CHECK(strstr(o, ", constant S2ABorder* s2a_bt [[buffer(28)]])\n{") != NULL, "入口参数应加边框表 [[buffer(28)]]");
    CHECK(strstr(o, "float4 a = s2a_bsample(spvDescriptorSet2.m_7, spvDescriptorSet2.m_7Smplr, s2a_bt[128], uv, level(0.0));") != NULL, "level 采样改写不对");
    CHECK(strstr(o, "spvDescriptorSet2.m_9.sample_compare(spvDescriptorSet2.m_9Smplr, uv, 0.5)") != NULL, "比较采样应不动");
    CHECK(strstr(o, "spvDescriptorSet2.m_11[1].sample(spvDescriptorSet2.m_11Smplr[1], uv)") != NULL, "数组采样器应不动");
    CHECK(strstr(o, "float4 e = s2a_bsample(spvDescriptorSet2.m_7, spvDescriptorSet2.m_7Smplr, s2a_bt[128], s2a_bsample(spvDescriptorSet2.m_13, spvDescriptorSet2.m_13Smplr, s2a_bt[133], uv).xy, bias(1.0));") != NULL,
          "嵌套采样（坐标里还有一次采样）两层都应改写");
    CHECK(strstr(o, "float4 g = s2a_bgather_w(spvDescriptorSet2.m_7, spvDescriptorSet2.m_7Smplr, s2a_bt[128], uv, int2(1, 0));") != NULL, "gather 分量 w 应摘进辅助函数名");
    CHECK(strstr(o, "{ return t.sample(s, uv); }") != NULL, "入口外函数应不动");
    CHECK(strstr(o, "float4 h = helper(spvDescriptorSet2.m_13, spvDescriptorSet2.m_13Smplr, uv);") != NULL, "非采样调用应不动");
    // 未登记采样器：只登记 m_9（比较采样）→ 没有可改写的 → NULL（原样用）
    const char *n2[] = {"m_9Smplr"}; const uint16_t b2[] = {130};
    char *o2 = gal_border_msl(k_src, "s1", n2, b2, 1);
    CHECK(o2 == NULL, "只有比较采样时应返回 NULL（原样用）"); free(o2);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(o) options:[MTLCompileOptions new] error:&err];
    CHECK(lib != nil, "改写后的 MSL 编不过：%s", err.localizedDescription.UTF8String);
    free(o);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail != 0;
}
