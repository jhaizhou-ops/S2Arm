// 直连冷启动（测试契约 tests/真机契约.md §1，S2A_COLD_START=1）：清直连兜底目录 DM_MSL_FALLBACK（Documents/wire/<程序号>/shaders）。
// 兜底目录装的是本机首遇现编的 <键>_b.metal / .json（dsh_miss.inc），跨局保留、下局按「复用上局」直接登记——它是首启没有的东西。
// 通用模式的冷启动由 graphics/metal/cs/NxColdStart.cs 清（渲染器缓存 / 主机缓存 / 设备归档 / Metal 系统缓存），但直连模式不建通用渲染器、那段不跑，
// 兜底目录一直没人清：10-26 运维线暗黑3 测试机1 冷启局「成功 0、复用上局 36」，首遇现编被复用掩盖（同包测试机2 是「成功 36」）。
// 只清兜底目录里的文件（含子目录），不碰 wire/<程序号>/ 下的 mode / fail（图形模式选择）与 pso_user.tsv。返回删掉的文件数，*bytes 累加字节数
#include <ftw.h>
static _Thread_local uint64_t g_cold_n, g_cold_b;
static int dsh_cold_one(const char *path, const struct stat *st, int flag, struct FTW *f) {
    (void)f;
    if (flag == FTW_F && !unlink(path)) { g_cold_n++; g_cold_b += (uint64_t)st->st_size; }
    return 0;
}
static uint64_t dsh_cold_clear(const char *dir, uint64_t *bytes) {
    g_cold_n = 0; g_cold_b = 0;
    if (dir && *dir) nftw(dir, dsh_cold_one, 16, FTW_PHYS);
    if (bytes) *bytes = g_cold_b;
    return g_cold_n;
}
