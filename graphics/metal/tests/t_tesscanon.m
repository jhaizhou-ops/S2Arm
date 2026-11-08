// 单测 t_tesscanon：曲面阶段接口结构体规范布局 gal_tess_canon（gal_tessxc.m）遇到空结构体（11-02 普查 c1102_v2_air：泡姆泡姆 40 支、符文工房5 26、
//   奥日2 7、泡泡龙4 6、马力欧派对 1，直连库「MSL failed：main0_out 成员认不出：};」——顶点阶段不写任何通用输出时 SPIRV-Cross 出 struct main0_out\n{\n};，
//   旧写法从结构体头之后找「\n};\n」，空结构体的结尾就在头的最后一个换行上、找不到，落到下一个结构体的结尾，把「};」和别的结构体成员当成员读）。
// 期望（按规范布局手写，gal_internal.h：每控制点 35 槽，通用位置 0–31 与 gl_Position 32 / gl_PointSize 33 各 16 字节、gl_ClipDistance 34 占 32 字节）：
//   ① 空的每控制点结构体：成功，体内 35 行补位（s2a_p0..s2a_p33 各 uint[4]、s2a_p34 uint[8]），其后的结构体与函数原样不动
//   ② 有成员的结构体（float4 位置 1、gl_Position）：成功，成员进各自槽、其余补位——与修前同一结果（反证修法没改非空结构体）
//   ③ 空结构体放在文末（后面没有别的结构体）：同 ①
#import "../gal_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

// 35 槽补位（除 skip 指定的槽外）：手写的期望体
static void pad_body(char *o, size_t n, int skip_a, const char *line_a, int skip_b, const char *line_b) {
    size_t k = 0;
    for (int s = 0; s < 35; s++) {
        if (s == skip_a) { k += (size_t)snprintf(o + k, n - k, "%s\n", line_a); continue; }
        if (s == skip_b) { k += (size_t)snprintf(o + k, n - k, "%s\n", line_b); continue; }
        k += (size_t)snprintf(o + k, n - k, "    uint s2a_p%d[%d];\n", s, s == 34 ? 8 : 4);
    }
    if (k) o[k - 1] = 0;   // 最后一行的换行由结尾「\n};」带
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    static const char tail[] = "\n};\n\nstruct main0_in\n{\n    float4 m_5 [[attribute(0)]];\n};\n\nvertex main0_out main0(main0_in in [[stage_in]])\n{\n    main0_out out = {};\n    return out;\n}\n";
    char body[4096], want[8192], why[256];

    // ① 空结构体后面跟着别的结构体（泡姆泡姆失败支的样子）
    {
        char *m = strdup("#include <metal_stdlib>\nusing namespace metal;\n\nstruct main0_out\n{\n};\n\nstruct main0_in\n{\n    float4 m_5 [[attribute(0)]];\n};\n\nvertex main0_out main0(main0_in in [[stage_in]])\n{\n    main0_out out = {};\n    return out;\n}\n");
        why[0] = 0; int ok = gal_tess_canon(&m, "main0_out", 1, NULL, 0, why);
        pad_body(body, sizeof body, -1, NULL, -1, NULL);
        snprintf(want, sizeof want, "#include <metal_stdlib>\nusing namespace metal;\n\nstruct main0_out\n{\n%s%s", body, tail);
        CHECK(ok == 1, "① 空结构体应成功，实得 %d（%s）", ok, why);
        CHECK(ok == 1 && !strcmp(m, want), "① 输出与手写期望不同：\n%s", m);
        free(m);
    }
    // ② 有成员（位置 1 的 float4 + gl_Position）：成员进槽 1 / 32
    {
        char *m = strdup("struct main0_out\n{\n    float4 m_7;\n    float4 gl_Position;\n};\n\nstruct main0_in\n{\n    float4 m_5 [[attribute(0)]];\n};\n");
        gal_tess_loc locs[1]; memset(locs, 0, sizeof locs); snprintf(locs[0].name, sizeof locs[0].name, "m_7"); locs[0].loc = 1; locs[0].patch = 0;
        why[0] = 0; int ok = gal_tess_canon(&m, "main0_out", 1, locs, 1, why);
        pad_body(body, sizeof body, 1, "    float4 m_7;", 32, "    float4 gl_Position;");
        snprintf(want, sizeof want, "struct main0_out\n{\n%s\n};\n\nstruct main0_in\n{\n    float4 m_5 [[attribute(0)]];\n};\n", body);
        CHECK(ok == 1, "② 有成员应成功，实得 %d（%s）", ok, why);
        CHECK(ok == 1 && !strcmp(m, want), "② 输出与手写期望不同：\n%s", m);
        free(m);
    }
    // ③ 空结构体在文末
    {
        char *m = strdup("struct main0_out\n{\n};\n");
        why[0] = 0; int ok = gal_tess_canon(&m, "main0_out", 1, NULL, 0, why);
        pad_body(body, sizeof body, -1, NULL, -1, NULL);
        snprintf(want, sizeof want, "struct main0_out\n{\n%s\n};\n", body);
        CHECK(ok == 1, "③ 文末空结构体应成功，实得 %d（%s）", ok, why);
        CHECK(ok == 1 && !strcmp(m, want), "③ 输出与手写期望不同：\n%s", m);
        free(m);
    }
    printf("%s t_tesscanon：%d 项，失败 %d\n", g_fail ? "✗" : "✓", g_checks, g_fail);
    return g_fail != 0;
}
