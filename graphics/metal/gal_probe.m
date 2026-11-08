// 零拷贝宿主映射 iOS 可行性探针（帧率能耗线 10-22，总指挥派：游戏数据缓冲零拷贝立项前先拿 iPhone 读数，见 设计.md 8a-1）。
// NXGAL_HOSTMAP_PROBE=1 时渲染器初始化后跑一次（NxRenderer.Initialize 调），不碰游戏路径：
//   三档 64 KB / 4 MB / 64 MB，每档一段匿名内存（同客体内存：页对齐、先触碰）→ nxgal_buf_create_host 建零拷贝缓冲 → GPU 拷入图样（录进命令流、提交等完）
//   → CPU 直接读这段内存逐字节核对（不回读、不经 GetData）→ 删缓冲、等完 → 放内存。每步前后记进程 footprint（TASK_VM_INFO phys_footprint）
//   与整机 wired（HOST_VM_INFO64 wire_count × 页大小）。安全：每档删缓冲后整机 wired 比建之前多出超过 max(4 MB, 本档 1/4) 即判「wired 回不去」，
//   当场停（后面的档不跑）、报红。整机 wired 是全机读数，别的进程也会动它，小档的变化淹在噪声里属正常，看 64 MB 档。
#import "gal_internal.h"
#include <mach/mach.h>
#include <sys/mman.h>
#include <string.h>
#include <unistd.h>

static uint64_t probe_footprint(void) {
    task_vm_info_data_t i; mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &c) == KERN_SUCCESS ? i.phys_footprint : 0;
}
static uint64_t probe_wired(void) {
    vm_statistics64_data_t s; mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
    return host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&s, &c) == KERN_SUCCESS ? (uint64_t)s.wire_count * vm_kernel_page_size : 0;
}
static uint8_t probe_pat(size_t k) { return (uint8_t)(k * 131 + (k >> 12) * 7 + 0x5d); }

// 返回 0 = 三档都跑完且 wired 都回得去；1 = 某档 wired 回不去（已停）；2 = 建缓冲 / 核对失败
NXGAL_API int32_t nxgal_hostmap_probe(void) {
    static const size_t sizes[] = {64u << 10, 4u << 20, 64u << 20};
    const size_t chunk = 4u << 20;
    GLOG("零拷贝探针：页 %lu B，三档 64 KB / 4 MB / 64 MB；读数 = 进程 footprint / 整机 wired（MB）", (unsigned long)vm_kernel_page_size);
    // 图样源：一个普通缓冲（≤ 4 MB），按块拷进零拷贝缓冲
    uint8_t *pat = malloc(chunk); if (!pat) { GLOG("【红】零拷贝探针：图样内存分配失败"); return 2; }
    for (size_t k = 0; k < chunk; k++) pat[k] = probe_pat(k);
    uint32_t src = nxgal_buf_create((int32_t)chunk, 0); nxgal_buf_set_data(src, 0, pat, (int32_t)chunk); gal_finish();
    // 预热：同一流程先完整走一遍（普通缓冲拷一次 + 一段零拷贝建 → 用 → 删），把首次用 GPU 的一次性开销（命令分配器 / 驻留集 / 内部管线，
    // Mac 实测整机 wired +181 MB、footprint +162 MB）排除在各档读数外
    { uint32_t d = nxgal_buf_create((int32_t)chunk, 0); nxgal_buf_copy(src, d, 0, 0, (int32_t)chunk); gal_finish(); nxgal_buf_delete(d);
      size_t wn = 64u << 10; uint8_t *wm = mmap(NULL, wn, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
      if (wm != MAP_FAILED) { memset(wm, 0, wn); uint32_t wh = nxgal_buf_create_host(wm, (int32_t)wn);
          if (wh) { nxgal_buf_copy(src, wh, 0, 0, (int32_t)wn); gal_finish(); nxgal_buf_delete(wh); }
          gal_finish(); usleep(200000); gal_finish(); munmap(wm, wn); } }
    GLOG("零拷贝探针预热后：footprint %.1f MB、整机 wired %.1f MB", (double)probe_footprint() / 1048576.0, (double)probe_wired() / 1048576.0);
    int rc = 0;
    for (int t = 0; t < 3 && !rc; t++) {
        size_t n = sizes[t];
        uint64_t f0 = probe_footprint(), w0 = probe_wired();
        uint8_t *mem = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (mem == MAP_FAILED) { GLOG("【红】零拷贝探针 %zu KB：mmap 失败", n >> 10); rc = 2; break; }
        memset(mem, 0xa5, n);   // 先触碰（同客体内存：已驻留的普通页）
        uint64_t f1 = probe_footprint(), w1 = probe_wired();
        uint32_t h = nxgal_buf_create_host(mem, (int32_t)n);
        if (!h) { GLOG("【红】零拷贝探针 %zu KB：nxgal_buf_create_host 失败", n >> 10); munmap(mem, n); rc = 2; break; }
        uint64_t f2 = probe_footprint(), w2 = probe_wired();
        for (size_t o = 0; o < n; o += chunk) { size_t m = n - o < chunk ? n - o : chunk; nxgal_buf_copy(src, h, 0, (int32_t)o, (int32_t)m); }
        gal_finish();
        uint64_t f3 = probe_footprint(), w3 = probe_wired();
        size_t bad = 0, first = (size_t)-1;   // GPU 写的结果 CPU 直接读这段内存（零拷贝：不回读）
        for (size_t k = 0; k < n; k++) if (mem[k] != pat[k % chunk]) { if (first == (size_t)-1) first = k; bad++; }
        nxgal_buf_delete(h); gal_finish(); usleep(200000); gal_finish();
        uint64_t f4 = probe_footprint(), w4 = probe_wired();
        munmap(mem, n);
        uint64_t f5 = probe_footprint(), w5 = probe_wired();
#define MB(x) ((double)(int64_t)(x) / 1048576.0)
        GLOG("零拷贝探针 %zu KB：footprint 建前 %.1f → 触碰后 %.1f → 建缓冲后 %.1f → GPU 写完 %.1f → 删缓冲后 %.1f → 放内存后 %.1f；"
             "整机 wired 同序 %.1f → %.1f → %.1f → %.1f → %.1f → %.1f；逐字节核对 %zu 字节错 %zu（首错 %zd）",
             n >> 10, MB(f0), MB(f1), MB(f2), MB(f3), MB(f4), MB(f5), MB(w0), MB(w1), MB(w2), MB(w3), MB(w4), MB(w5), n, bad, bad ? (ssize_t)first : -1);
        GLOG("零拷贝探针 %zu KB 增量：建缓冲 wired %+.1f MB、GPU 用后 %+.1f MB（相对触碰后）；删缓冲后 wired 相对触碰后 %+.1f MB、footprint %+.1f MB",
             n >> 10, MB(w2 - w1), MB(w3 - w1), MB(w4 - w1), MB(f4 - f1));
        int64_t left = (int64_t)w4 - (int64_t)w1, lim = (int64_t)(n / 4 > (4u << 20) ? n / 4 : (4u << 20));
        if (bad) { GLOG("【红】零拷贝探针 %zu KB：GPU 写的数据 CPU 直接读不对（%zu 字节错），停", n >> 10, bad); rc = 2; }
        else if (left > lim) { GLOG("【红】零拷贝探针 %zu KB：删缓冲后整机 wired 回不去（比建前多 %.1f MB，限 %.1f MB），停，后面的档不跑", n >> 10, MB(left), MB(lim)); rc = 1; }
#undef MB
    }
    nxgal_buf_delete(src); gal_finish(); free(pat);
    GLOG("零拷贝探针结束：%s", rc == 0 ? "三档都跑完，wired 都回得去" : rc == 1 ? "【红】wired 回不去，已停" : "【红】建缓冲 / 核对失败");
    return rc;
}
