// 单测 t_helper_m3：内部辅助库的 Metal 3 兼容版（-std=metal3.2，卡 M3-2 / #109）。
// 只用老接口：MTLDevice newLibraryWithURL:error: 逐个载入 7 个 metal3.2 库，再按名取入口函数（取得到 = 这套 MSL 在 Metal 3 路径上可用）。
// 库名带源码哈希，单测不写死：用 nxgal_helper_src(k, &base) 取基名再拼 .metallib；目录是本可执行文件旁的 gal_helpers/m3/。
// 运行时选库逻辑不在本卡（M3-4 再接），所以这里直接取设备，不经 nxgal_init。
#include "../gal_abi.h"
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libgen.h>
#include <mach-o/dyld.h>

const char *nxgal_helper_src(int32_t k, const char **base);   // gal_core.m：第 k 个辅助库的源码 / 基名

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

// 每个辅助库至少一个入口函数名（与 gal_xc --helpers 导出的 MSL 一致；入口改名这里就红）。顺序 = gal_internal.h 的 GH_*：
// 0 重排 / 1 索引 / 2 深度阈值 / 3 清屏 / 4 出图 / 5 贴图 / 6 曲面
static const char *const k_entry[7][4] = {
    {"restride", NULL},
    {"idx_conv", "ind_cnt", NULL},
    {"dt_vs", "dt_fs", NULL},
    {"clr_vs", NULL},
    {"pr_vs", "pr_fs", "cap_fs", NULL},
    {"blit_vs", "fs_f", "k_dspack", NULL},
    {"s2a_tess_emit", "s2a_tess_scan", "s2a_tess_count", NULL},
};

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("没有 Metal 设备\n"); return 2; }
    char exe[4096]; uint32_t sz = sizeof exe;
    if (_NSGetExecutablePath(exe, &sz)) { printf("取本可执行文件路径失败\n"); return 2; }
    char dir[4096]; snprintf(dir, sizeof dir, "%s", dirname(exe));
    char m3[4200]; snprintf(m3, sizeof m3, "%s/gal_helpers/m3", dir);
    printf("· Metal 3 兼容辅助库（-std=metal3.2）：%s\n", m3);
    for (int k = 0; k < 7; k++) {
        const char *base = NULL; nxgal_helper_src(k, &base);
        char path[4600]; snprintf(path, sizeof path, "%s/%s.metallib", m3, base ? base : "?");
        CHECK([[NSFileManager defaultManager] fileExistsAtPath:@(path)], "库不存在：%s", path);
        NSError *e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(path)] error:&e];
        CHECK(lib != nil, "老接口载入失败：%s（%s）", path, e ? e.localizedDescription.UTF8String : "-");
        if (!lib) continue;
        CHECK(lib.functionNames.count > 0, "库里没有函数：%s", base ? base : "?");
        for (int i = 0; i < 3 && k_entry[k][i]; i++)
            CHECK([lib newFunctionWithName:@(k_entry[k][i])] != nil, "按名取不到入口函数 %s（%s）", k_entry[k][i], base);
        printf("  · %s：%lu 个函数，入口 %s 取到\n", base, (unsigned long)lib.functionNames.count, k_entry[k][0]);
    }
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
