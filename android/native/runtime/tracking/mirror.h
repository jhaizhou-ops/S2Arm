// Android-only backing mirror. Writers hold svc_mem g_mu; no tracker locks here.
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {   // bridge.cpp（C++）经 JNI 调 configure；C 文件和测试仍按 C 链接
#endif
// 生产开关（#1184 / owner #1285）：宿主创建前设一次，之后只读。缺省 0 = 关（运行时语义改动缺省关合入）。
// 关时下面的入口第一行判一次标志就返回：不建窗口、不映射、不分配、不改世代号。
// 首次 s2a_android_mirror_init（不论开关开/关）即冻结；之后 configure 同值幂等成功，不同值拒绝。
int s2a_android_mirror_configure(int enabled);   // 0 成功（含冻结后同值）；冻结后改值 EBUSY；非法值 EINVAL
// 只读开关查询：tracker / VM 的关路径据此决定是否走镜像专用时序（#1184 owner r4 第 2 条）。
int s2a_android_mirror_enabled(void);
void s2a_android_mirror_init(uintptr_t base, size_t size);
void s2a_android_mirror_begin(uintptr_t base, size_t size);
void s2a_android_mirror_end(uintptr_t base, size_t size, int mapped, int committed);
uint64_t s2a_android_mirror_sequence(void);
void s2a_android_mirror_note_retry(void);
void s2a_android_mirror_note_wait(void);
void s2a_android_mirror_report(const char *when);
// VMA 采样器用：镜像窗口地址 / 大小；开关关或未建窗时 base=0、size=0。
void s2a_android_mirror_region(uintptr_t *base, size_t *size);
#ifdef S2A_UNIT_TEST
uintptr_t s2a_android_mirror_test_base(void);
void s2a_android_mirror_test_paths(const char *maps_path, const char *limit_path);   // 报告读 /proc 与 max_map_count 的路径（单测注入）
void s2a_android_mirror_test_timeout_us(long us);   // 有界等待上限（单测调小）
uint64_t s2a_android_mirror_test_retries(void);
uint64_t s2a_android_mirror_test_waits(void);
int s2a_android_mirror_test_initialized(void);
void s2a_android_mirror_test_stats(uint64_t *hits, uint64_t *misses, uint64_t *outside, uint64_t *init_failures);
#endif
#ifdef __cplusplus
}
#endif
