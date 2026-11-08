# WP17 V1 探针：原地换底、APK 进程、CPU 吞吐、稀疏拼接（#401）

在 V0 探针（[../v0_external_memory/](../v0_external_memory)）之上补 V1 的 a / b / c / e 四项。
`v1probe.c` 直接 `#include` V0 的 `v0probe.c`（JSON 行、Vulkan 上下文、导入与一致性函数共用），
V0 的默认行为不变。结论与读数见 [docs/研究/安卓直连V1_n06ody.md](../../../../docs/研究/安卓直连V1_n06ody.md)。

## 编译

仓库根目录，需要 Docker（镜像默认 `s2arm-android-build:1` 的摘要 `sha256:4cbb20d3…8321`，NDK 29.0.14206865、
SDK 36；APK 用 `gradle --offline`，Gradle 缓存卷默认 `s2arm-owned-pr-android-cache`，可用 `S2A_ANDROID_CACHE` 覆盖）：

```sh
bash android/probes/v1_external_memory/build.sh        # 可执行 + APK
bash android/probes/v1_external_memory/build.sh exe    # 只出可执行
# build/android-probes/v1_external_memory/v1probe                                   adb shell 用
# build/android-probes/v1_external_memory/apk/outputs/apk/debug/v1probe-debug.apk   包名 org.s2arm.probe.v1，debug 签名
```

## 运行

```sh
# adb shell：每节一个子进程 + 240 秒看门狗
adb push build/android-probes/v1_external_memory/v1probe /data/local/tmp/
adb shell /data/local/tmp/v1probe device,ahb,dmabuf,heapcpu,swap_ahb,swap_heap > adb.jsonl
adb shell /data/local/tmp/v1probe bench > bench.jsonl
adb shell /data/local/tmp/v1probe sparse > sparse.jsonl
# APK：同一套节在应用进程里顺序执行（不 fork），JSON 行写 files/v1probe.jsonl 并打到 logcat（tag S2ArmV1）
adb install -r .../v1probe-debug.apk
adb shell am start -n org.s2arm.probe.v1/.ProbeActivity [--es sections device,ahb,...]
adb shell run-as org.s2arm.probe.v1 cat files/done          # rc=0 表示所有节完成
adb shell run-as org.s2arm.probe.v1 cat files/v1probe.jsonl > apk.jsonl
adb uninstall org.s2arm.probe.v1
```

`start` 行记录 `mode`（`fork` = adb 子进程 / `inproc` = APK 进程内）、uid、SELinux 上下文、机型 / SoC / fingerprint。
读数表由 `report.py` 从 jsonl 生成：`python3 -I report.py <读数目录>`。

**AHB 尺寸上限 448 MiB**：8E 上 ≥ 512 MiB 的 `AHardwareBuffer_allocate` 会让高通 allocator-service 崩溃并连带框架重启
（#401 V1-d）。本探针所有 AHB 申请 ≤ 400 MiB，超过 448 MiB 的请求在调用前拒绝（`AHB_LIMIT_BYTES`，定义在 v0probe.c）。

## 节

| 节 | V1 项 | 内容 |
|---|---|---|
| `device` | — | 同 V0 |
| `ahb` | b | V0 的 AHB 节（4K–64M 分配 → 导入 → cycle / persistent / fixed 一致性；256M 只分配 + 导入），不含 1G |
| `dmabuf` | b | V0 的 dma-buf 堆节，原样 |
| `heapcpu` | b | 不经 Vulkan：`/dev/dma_heap/{system,system-uncached,qcom,system,mtk_mm,mtk_mm-uncached}` 打开 → 分配 2M → MAP_FIXED 进预留窗口 → SYNC 包住写 / 读回。每个被拒调用报 errno |
| `swap_ahb` / `swap_heap` | a | 原地换底，见下 |
| `bench` | c | CPU 吞吐，见下 |
| `sparse` | e | 稀疏 VkBuffer 拼 4 × 100 MiB AHB，见下 |

### 原地换底（`swap_*`）

客体窗口形状照 `android/native/`：一段 PROT_NONE 预留里，`[gap_lo 2M | lo 2M | pool N | hi 2M | gap_hi 2M]`，
lo / pool / hi 是同一个后备映射（`memfd_shared`：memfd MAP_SHARED|MAP_FIXED，另用 `mremap(old_size=0)` 给 pool 建一个别名；
`anon_private`：匿名私有 MAP_FIXED），三段各填不同模式，两头 gap 保持 PROT_NONE。N = 2M / 64M / 400M。

1. 新后备：`swap_ahb` = AHB（BLOB，CPU_*_OFTEN | GPU_DATA_BUFFER），取原生句柄第一个 dma-buf fd；`swap_heap` = `system-uncached` 堆。
2. 换入：新后备临时映射 → `memcpy` pool → 解除临时映射 → `mmap(pool, MAP_SHARED|MAP_FIXED, fd)` 盖回原地址。
3. 检查：CPU 全段比对原内容；lo / hi 内容与 4 段相邻区间的 `/proc/self/maps` 描述（权限、inode、名字、文件偏移）与换入前一致；
   memfd 形状下别名是否还能看到 pool 的写入（`alias_sees_pool_write_while_swapped`）。
4. 导入 VkBuffer（AHB / dma-buf），GPU 全段读原内容（`gpu_reads_original_*`），再 CPU→GPU（`c2g_*`）、GPU→CPU（`g2c_*`）全段往返，
   每 64 MiB 一次派发，坏字节按字节计。
5. 换回（池销毁）：memfd 形状把内容拷回原 memfd 的原偏移再 MAP_FIXED 映射回去；匿名形状拷进新匿名页再 `mremap(MREMAP_FIXED)` 移到原地址。
   比对 GPU 写入的内容（换回后、释放导入与新后备后各一次）、邻居、整窗 maps 是否与换入前完全相同、别名是否重新看到同一份内容。

### CPU 吞吐（`bench`）

64 MiB，线程绑到 `cpuinfo_max_freq` 最高的在线核，先空转 300 ms。后备：`memfd`（现行客体内存形状，基线）、`ahb_fixed`
（AHB dma-buf fd MAP_FIXED，不 lock）、`heap_system_uncached`、`heap_system_nosync`、`heap_system_sync_ends`（同一 system 堆缓冲，
每次测量前 SYNC_START、后 SYNC_END，耗时计入）。AHB / 堆缓冲在测量前导入 Vulkan 并让 GPU 读一次（dma-buf 有 GPU 挂接时
SYNC 才做缓存维护）。操作：`seq_write_memset`、`seq_write_64b`（每次迭代写一条 64B 线）、`seq_read`（64 位累加）、
`rand_read_4b`（全部 16M 个字下标打乱后逐个 4B 读）。先不计时预热一轮，再交错执行 3 轮（每轮后备顺序轮转一位），
报每轮耗时与中位 MiB/s。

### 稀疏拼接（`sparse`）

先报 `sparseBinding` / `sparseResidencyBuffer` 特性、各队列族 flags、`vkGetPhysicalDeviceExternalBufferProperties`（AHB，
带 SPARSE 创建标志）。支持时用 sparseBinding 重建设备，建 400 MiB `SPARSE_BINDING` 缓冲（先带 AHB 外部句柄类型，失败再不带），
分 4 块 100 MiB AHB 导入（不带 dedicated）→ `vkQueueBindSparse`；CPU 侧把 4 个 dma-buf fd 依次 MAP_FIXED 成连续 400 MiB。
全段 CPU→GPU / GPU→CPU，另在 3 个块边界各取 2 MiB 窗口单独往返。AHB 导入的内存类型与稀疏缓冲要求的类型没有交集时不绑定（那是越过 VU 的调用），
改报同尺寸不带外部句柄的稀疏缓冲、带 AHB 句柄的普通缓冲各自的 `memoryTypeBits` 与全部内存类型。

## 限制

- 一致性只测单队列 + 栅栏之后的可见性，不测 CPU / GPU 同时访问。
- APK 模式不 fork：某节崩溃会带走整个应用进程，已写出的行仍有效。
- 吞吐只在单核、单线程下测，结果受调频 / 温度影响，读数行带绑核与频率。
