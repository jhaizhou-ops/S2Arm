// Android 起局准入：只用已持有窗口与 HostApi 实际读数，不套 iOS 签名权限阈值。
#include "native.h"
#include "s2a_hostapi.h"

#ifndef S2A_MEM_NEED_MB
#define S2A_MEM_NEED_MB 0
#endif
_Static_assert(S2A_MEM_NEED_MB >= 0, "memory budget must not be negative");
static char g_hint[640] = "Android 原生运行时尚未完成起局自检";
const char *s2a_selfcheck_hint(void) { return g_hint; }

static int selfcheck_fail(const char *why) {
    snprintf(g_hint, sizeof g_hint, "%s", why);
    LOG("【红】Android 自检不过：%s", g_hint);
    return 0;
}

int s2a_selfcheck(void) {
    uint64_t base = 0, size = 0;
    s2a_window_get(&base, &size);
    if (!s2a_window_ok() || !base || (base & ((1ull << 30) - 1)) ||
        size != S2A_WIN_SIZE || base > (1ull << 39) - size)
        return selfcheck_fail("尚未持有完整、1 GiB 对齐且位于 39 位地址范围内的 68 GiB 游戏窗口");
    const s2a_host_api_v1 *host = s2a_host_get();
    if (!host || host->hdr.size < sizeof *host || host->hdr.abi_version != S2A_HOST_API_ABI_VERSION ||
        !(host->capabilities & S2A_HOST_CAP_MEMINFO) || !host->meminfo ||
        host->meminfo->hdr.size < sizeof *host->meminfo ||
        host->meminfo->hdr.abi_version != S2A_HOST_API_ABI_VERSION || !host->meminfo->query)
        return selfcheck_fail("HostApi 内存查询接口未就绪");
    s2a_host_meminfo memory = {.size = sizeof memory, .abi_version = S2A_HOST_API_ABI_VERSION};
    int error = host->meminfo->query(host->host, &memory);
    if (error || memory.size < sizeof memory || memory.abi_version != S2A_HOST_API_ABI_VERSION ||
        !memory.total_bytes || !memory.available_bytes || memory.available_bytes > memory.total_bytes)
        return selfcheck_fail("HostApi 内存读数不可用或不完整，不能确认当前内存状况");
    LOG("Android 自检：持有窗口 %#llx +%llu MB｜物理内存 %llu MB｜当前可用 %llu MB（%s）｜进程 RSS %llu MB",
        (unsigned long long)base, (unsigned long long)(size >> 20),
        (unsigned long long)(memory.total_bytes >> 20), (unsigned long long)(memory.available_bytes >> 20),
        memory.flags & 1 ? "HostApi 明示硬上限" : "瞬时估计，非单进程硬上限",
        (unsigned long long)(memory.process_rss_bytes >> 20));
#if S2A_MEM_NEED_MB > 0
    if (memory.available_bytes < (uint64_t)S2A_MEM_NEED_MB * (1ull << 20))
        return selfcheck_fail("当前可用内存低于本构建明确声明的起局预算");
#endif
    snprintf(g_hint, sizeof g_hint, "Android 地址窗口与当前内存读数可用；不保证后续全部游戏分配成功");
    return 1;
}
