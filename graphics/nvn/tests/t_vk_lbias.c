// Vulkan 层采样器 LOD 偏置改写（graphics/nvn/gfx/vk/vk_lbias.inc vk_lb_rewrite，#800）逐字核：输入 = SPIRV-Cross --msl-decoration-binding 的离散绑定形态（片元 / 计算各一支，
//   照 glslangValidator + spirv-cross 对真 GLSL 的输出抄来、入口改名 vk_<键>），期望手写；改写后的整份源码 xcrun metal -c 编得过（有 xcrun 才核，Linux 上跳过并写明）。
//   GPU 读数在 tests/vk_core ⑭（S2A_SAMP_EMU=1 一路走同一函数）。用法：make native-test-vk_lbias（末行 ✓ / ✗）
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "../gfx/vk/vk_lbias.inc"
static int fail, n;
static void ck(int ok, const char *m) { n++; fail += !ok; printf("%s %s\n", ok ? "✓" : "✗", m); }
static const char FS[] =
    "#include <metal_stdlib>\nusing namespace metal;\n\n"
    "fragment vk_k_out vk_k(texture2d<float> t [[texture(0)]], texture2d<float> t2 [[texture(1)]], texture2d_array<float> ta [[texture(3)]], texture2d<float> tsh [[texture(4)]], sampler tSmplr [[sampler(0)]], sampler s2 [[sampler(2)]], sampler taSmplr [[sampler(3)]], sampler tshSmplr [[sampler(4)]], float4 gl_FragCoord [[position]])\n{\n"
    "    vk_k_out out = {};\n    float2 uv = gl_FragCoord.xy / float2(int2(t.get_width(), t.get_height()));\n    float3 _77 = float3(uv, 1.0);\n    float3 _88 = float3(uv, 0.5);\n"
    "    out.o = ((((((t.sample(tSmplr, uv) + t.sample(tSmplr, uv, level(0.0))) + t.sample(tSmplr, uv, bias(0.5))) + t.sample(tSmplr, uv, gradient2d(dfdx(uv), dfdy(uv)))) + t.sample(tSmplr, uv, int2(1, 0))) + t2.sample(s2, uv)) + ta.sample(taSmplr, _77.xy, uint(rint(_77.z)))) + float4(spvDepthCast(tsh).sample_compare(tshSmplr, _88.xy, _88.z));\n"
    "    return out;\n}\n\n";
static const char FS_WANT[] =
    "#include <metal_stdlib>\nusing namespace metal;\n\n"
    "fragment vk_k_out vk_k(texture2d<float> t [[texture(0)]], texture2d<float> t2 [[texture(1)]], texture2d_array<float> ta [[texture(3)]], texture2d<float> tsh [[texture(4)]], sampler tSmplr [[sampler(0)]], sampler s2 [[sampler(2)]], sampler taSmplr [[sampler(3)]], sampler tshSmplr [[sampler(4)]], float4 gl_FragCoord [[position]], constant float4* s2a_vkb [[buffer(30)]])\n{\n"
    "    vk_k_out out = {};\n    float2 uv = gl_FragCoord.xy / float2(int2(t.get_width(), t.get_height()));\n    float3 _77 = float3(uv, 1.0);\n    float3 _88 = float3(uv, 0.5);\n"
    "    out.o = ((((((t.sample(tSmplr, uv, bias(s2a_vkb[0].x)) + t.sample(tSmplr, uv, level((0.0) + s2a_vkb[0].x))) + t.sample(tSmplr, uv, bias((0.5) + s2a_vkb[0].x))) + "
    "t.sample(tSmplr, uv, gradient2d((dfdx(uv)) * precise::exp2(s2a_vkb[0].x), (dfdy(uv)) * precise::exp2(s2a_vkb[0].x)))) + t.sample(tSmplr, uv, bias(s2a_vkb[0].x), int2(1, 0))) + "
    "t2.sample(s2, uv, bias(s2a_vkb[2].x))) + ta.sample(taSmplr, _77.xy, uint(rint(_77.z)), bias(s2a_vkb[3].x))) + float4(spvDepthCast(tsh).sample_compare(tshSmplr, _88.xy, _88.z));\n"
    "    return out;\n}\n\n";
static const char CS[] =
    "kernel void vk_c(device B& _11 [[buffer(1)]], texture2d<float> t [[texture(0)]], sampler tSmplr [[sampler(0)]])\n{\n"
    "    _11.o[0] = t.sample(tSmplr, float2(0.5), level(1.0)) + t.sample(tSmplr, float2(0.5), gradient2d(float2(0.100000001490116119384765625), float2(0.0))) + t.sample(tSmplr, float2(0.5)) + t.sample(tSmplr, float2(0.5), min_lod_clamp(1.0));\n}\n";
static const char CS_WANT[] =
    "kernel void vk_c(device B& _11 [[buffer(1)]], texture2d<float> t [[texture(0)]], sampler tSmplr [[sampler(0)]], constant float4* s2a_vkb [[buffer(29)]])\n{\n"
    "    _11.o[0] = t.sample(tSmplr, float2(0.5), level((1.0) + s2a_vkb[0].x)) + t.sample(tSmplr, float2(0.5), gradient2d((float2(0.100000001490116119384765625)) * precise::exp2(s2a_vkb[0].x), (float2(0.0)) * precise::exp2(s2a_vkb[0].x))) "
    "+ t.sample(tSmplr, float2(0.5), level(s2a_vkb[0].x)) + t.sample(tSmplr, float2(0.5), level(max(s2a_vkb[0].x, 1.0)));\n}\n";
int main(void) {
    char *o = NULL; int left = 0, r = vk_lb_rewrite(FS, "vk_k", 30, &o, &left);
    ck(r == 7 && o && !strcmp(o, FS_WANT), "片元：隐式插 bias(b)、level / bias 加 b、gradient 导数 × 2^b、带偏移在偏移前插、分开的贴图 + 采样器按采样器槽取 b、数组层号后插；表参数在最后");
    if (o && strcmp(o, FS_WANT)) printf("  真结果：\n%s", o);
    ck(left == 1, "片元：比较采样（sample_compare）不改，记 1 处没改");
    // 私有临时目录（11-05 不稳定项 #7：原先写死 /tmp/t_vk_lbias.*，同机两份门禁互删对方的 .metal / .air）
    char td[] = "/tmp/t_vk_lbias.XXXXXX", src[64], cmd[256];
    if (!mkdtemp(td)) { ck(0, "片元：建私有临时目录"); return 1; }
    snprintf(src, sizeof src, "%s/k.metal", td);
    FILE *f = fopen(src, "w");
    if (f && o) {
        fputs("#include <metal_stdlib>\nusing namespace metal;\nstruct vk_k_out { float4 o [[color(0)]]; };\n"   // SPIRV-Cross 自己出的 spvDepthCast（照抄）
              "template <typename T> static inline depth2d<T> spvDepthCast(texture2d<T> t) { return reinterpret_cast<thread const depth2d<T> &>(t); }\n", f);
        fputs(strstr(o, "fragment "), f); fclose(f);
        snprintf(cmd, sizeof cmd, "xcrun -sdk macosx metal -c %s/k.metal -o %s/k.air 2>%s/k.err", td, td, td);
        int rc = system(cmd);
        if (rc == -1 || system("xcrun -f metal >/dev/null 2>&1")) printf("· 没有 xcrun metal：改写结果未编（未验证）\n");
        else ck(rc == 0, "片元：改写后 xcrun metal -c 编过");
    } else if (f) fclose(f);
    snprintf(cmd, sizeof cmd, "%s/k.metal", td); remove(cmd); snprintf(cmd, sizeof cmd, "%s/k.air", td); remove(cmd);
    snprintf(cmd, sizeof cmd, "%s/k.err", td); remove(cmd); rmdir(td);
    free(o); o = NULL;
    r = vk_lb_rewrite(CS, "vk_c", 29, &o, &left);
    ck(r == 4 && o && !strcmp(o, CS_WANT) && !left, "计算：level 加 b、gradient、隐式插 level(b)、只带 min_lod_clamp(m) → level(max(b, m))");
    if (o && strcmp(o, CS_WANT)) printf("  真结果：\n%s", o);
    free(o); o = NULL;
    static const char NOS[] = "fragment vk_k_out vk_k(texture2d<float> t [[texture(0)]])\n{\n    vk_k_out out = {};\n    out.o = t.read(uint2(0));\n    return out;\n}\n";
    r = vk_lb_rewrite(NOS, "vk_k", 30, &o, &left);
    ck(r == 0 && !o && !left, "没有采样 → 0 处、不出源码");
    static const char ARR[] = "fragment vk_k_out vk_k(array<texture2d<float>, 2> t [[texture(0)]], array<sampler, 2> tSmplr [[sampler(0)]])\n{\n    vk_k_out out = {};\n    out.o = t[1].sample(tSmplr[1], float2(0.5));\n    return out;\n}\n";
    r = vk_lb_rewrite(ARR, "vk_k", 30, &o, &left);
    ck(r == 0 && !o && left == 1, "贴图 / 采样器数组 → 不改，记 1 处没改");
    static const char HELP[] = "static float4 f(texture2d<float> t, sampler s) { return t.sample(s, float2(0.5)); }\nfragment vk_k_out vk_k(texture2d<float> t [[texture(0)]], sampler tSmplr [[sampler(0)]])\n{\n    vk_k_out out = {};\n    out.o = f(t, tSmplr);\n    return out;\n}\n";
    r = vk_lb_rewrite(HELP, "vk_k", 30, &o, &left);
    ck(r == 0 && !o && left == 1, "入口外的辅助函数里的采样 → 不改，记 1 处没改");
    ck(vk_lb_rewrite(HELP, "vk_x", 30, &o, &left) == -1, "认不出入口 → -1");
    printf("%s t_vk_lbias：%d 项，失败 %d\n", fail ? "✗" : "✓", n, fail);
    return fail != 0;
}
