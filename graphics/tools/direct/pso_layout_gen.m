// 管线键 pso_skey 布局导出（#1100 W6，11-04 Windows 出包线）：pso_layout_gen > graphics/tools/direct/pso_layout.json
//   直连出库要按运行时结构体 pso_skey（nvn_pso_skey.h）读管线键 R 行，原先 fout_want.m / pso_skey_size.m 出库时现编现跑（要 Objective-C 编译器与 Metal 头文件，
//   Windows 没有）。现在只在 Mac 上用本程序把布局与整数像素格式表导出成 JSON 提交进仓库，出库一律用 Python（pso_layout.py、fout_want.py）读这份 JSON，Mac / Windows 同一份。
//   tests/pso_layout_test.sh 在 Mac 上重新编本程序、与提交的 JSON 逐字节比：结构体或像素格式判定一改，没重导 JSON 就红。
//   位域（blend_st 的混合因子）按「置满一个字段、看哪些位亮」实测位移与位宽，不靠手算
// 编：clang -fobjc-arc -I graphics/nvn/gfx/nvn -I graphics/nvn/gfx/nvn/include graphics/tools/direct/pso_layout_gen.m -framework Foundation -o pso_layout_gen
#import <Foundation/Foundation.h>
@interface NvShader : NSObject { @public int stage; char key[24]; } @end
#include "nvn_pso_skey.h"
#include "nvn_pfkind.h"
#include <stddef.h>
#include <stdio.h>

static void bits(const char *name, void (*set)(blend_st *), int last) {
    blend_st b; memset(&b, 0, sizeof b); set(&b);
    uint64_t v; memcpy(&v, &b, sizeof v);
    int shift = 0, width = 0; while (shift < 64 && !(v >> shift & 1)) shift++;
    while (shift + width < 64 && (v >> (shift + width) & 1)) width++;
    printf("    \"%s\": [%d, %d]%s\n", name, shift, width, last ? "" : ",");
}
static void s_src_rgb(blend_st *b) { b->src_rgb = 0x7f; }
static void s_dst_rgb(blend_st *b) { b->dst_rgb = 0x7f; }
static void s_src_a(blend_st *b) { b->src_a = 0x7f; }
static void s_dst_a(blend_st *b) { b->dst_a = 0x7f; }

int main(void) {
    _Static_assert(sizeof(blend_st) == 8, "blend_st 不是 8 字节：pso_layout.py 按 u64 读位域");
    size_t k = offsetof(pso_skey, k);
    printf("{\n  \"comment\": \"pso_skey 布局与整数像素格式（graphics/tools/direct/pso_layout_gen.m 在 Mac 上导出，勿手改；tests/pso_layout_test.sh 核）\",\n");
    printf("  \"skey_size\": %zu,\n", sizeof(pso_skey));
    printf("  \"fs\": [%zu, %zu],\n", offsetof(pso_skey, fs), sizeof(((pso_skey *)0)->fs));
    printf("  \"merged\": %zu,\n  \"fz\": %zu,\n", offsetof(pso_skey, merged), offsetof(pso_skey, fz));
    printf("  \"cfmt\": %zu,\n  \"blend_en\": %zu,\n  \"blend0\": %zu,\n  \"lmap\": %zu,\n",
           k + offsetof(pso_key, cfmt), k + offsetof(pso_key, blend_en), k + offsetof(pso_key, blend), k + offsetof(pso_key, lmap));
    printf("  \"blend_bits\": {\n");
    bits("src_rgb", s_src_rgb, 0); bits("dst_rgb", s_dst_rgb, 0); bits("src_a", s_src_a, 0); bits("dst_a", s_dst_a, 1);
    printf("  },\n");
    for (int kind = 1; kind <= 2; kind++) {   // pf_int_kind：1 = 无符号整数、2 = 有符号整数（MTLPixelFormat 取值都在 0–1023 内）
        printf("  \"%s\": [", kind == 1 ? "uint_formats" : "sint_formats"); int first = 1;
        for (unsigned f = 0; f < 1024; f++) if (pf_int_kind((MTLPixelFormat)f) == kind) { printf("%s%u", first ? "" : ", ", f); first = 0; }
        printf("]%s\n", kind == 1 ? "," : "");
    }
    printf("}\n");
    return 0;
}
