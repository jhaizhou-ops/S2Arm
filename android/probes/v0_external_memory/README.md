# WP17 V0 外部内存零拷贝探针（#401）

验证 Android 上能否把「游戏内存」直接当 `VkBuffer` 用（Metal 侧对应 `newBufferWithBytesNoCopy`），
以及扩展缺席时的替代路径。单个 C 文件 + 一个计算着色器（编译期内嵌 SPIR-V），只链接
`libvulkan`、`libandroid`，`adb shell` 直接跑，无需 root、无需 APK。

结论口径与读数见 [docs/研究/安卓直连V0_n06ody.md](../../../../docs/研究/安卓直连V0_n06ody.md)。

## 编译

在仓库根目录（需要 Docker，用 Android 构建镜像里的 NDK 29.0.14206865，目标 API 35，`-Wall -Wextra -Werror`）：

```sh
bash android/probes/v0_external_memory/build.sh
# 产物：build/android-probes/v0_external_memory/v0probe（arm64，已 strip），脚本末尾打印 SHA256
```

镜像默认是 `s2arm-android-build:1` 的摘要 `sha256:4cbb20d3…8321`，可用 `S2A_ANDROID_IMAGE` 覆盖。
着色器 `xor.comp` 在构建时由 NDK 的 `glslc` 编成 C 初始化列表并过 `spirv-val`。

## 运行

```sh
adb push build/android-probes/v0_external_memory/v0probe /data/local/tmp/
adb shell chmod 755 /data/local/tmp/v0probe
adb shell /data/local/tmp/v0probe > v0probe_<机型>.jsonl
# 只跑一节：adb shell /data/local/tmp/v0probe ahb
# 自定义 AHB 尺寸（MiB，逗号分隔；只跑 ahb 节的 ahb_size 行，每个尺寸分配→导入→首/尾各 1 MiB 双向一致性）：
#   adb shell /data/local/tmp/v0probe ahb 256,384,400   （或环境变量 S2A_AHB_SIZES_MIB）
```

**AHB 尺寸上限 448 MiB（硬规矩）**：在 8E（Adreno 830，高通 gralloc）上 `AHardwareBuffer_allocate`
申请 ≥ 512 MiB 会让 `vendor.qti.hardware.display.allocator-service` 崩溃（SIGABRT），并连带
zygote / 框架重启约 20 秒（#401 V1-d）。因此探针默认的 `ahb_max` 只测 256 MiB（不再测 1 GiB）；
命令行或环境变量给出任一 > 448 MiB 的 AHB 尺寸时，探针打印 `{"sec":"args","status":"refused",...}`
并以退出码 2 结束，不调用 `AHardwareBuffer_allocate`。dma-buf 堆的 256M / 1G（`dmabuf_max`）不受此限
（9000 上 1 GiB 已验证无副作用）。

预计全程 < 60 秒（单节有 25 秒看门狗）。退出码：所有节都正常结束为 0，否则 1。
建议同时记下 `adb shell getprop ro.product.model`、`ro.build.fingerprint`、`ro.soc.model`。

## 测什么

| 节 | 内容 |
|---|---|
| `device` | GPU 名、vendor/device ID、driverVersion、apiVersion、驱动名、`getpagesize()`、内存堆 / 内存类型（含 DEVICE_LOCAL / HOST_VISIBLE / HOST_COHERENT / HOST_CACHED 组合）、与内存相关的扩展清单、四种外部句柄（opaque_fd / host_allocation / AHB / dma_buf）的 `vkGetPhysicalDeviceExternalBufferProperties` |
| `host_props` | `VK_EXT_external_memory_host`：三种后备内存 × 4K/64K/2M/64M 的 `vkGetMemoryHostPointerPropertiesEXT` 的 memoryTypeBits |
| `host_import` | 同上组合：导入建 `VkDeviceMemory` + `VkBuffer`，再做双向一致性；256M / 1G 只做导入（`host_max`） |
| `host_unaligned_0..4` | 违反对齐 VU 的调用（+64 字节、+半页起点、非对齐大小、4K 大小），每例单独子进程，只记录驱动行为 |
| `ahb` | AHardwareBuffer（BLOB，CPU_READ/WRITE_OFTEN \| GPU_DATA_BUFFER）→ 导入 `VkBuffer` → 双向一致性：`cycle_`（每次 CPU 访问都 lock/unlock）、`persistent_`（一次 lock 贯穿 GPU 读写）、`fixed_*`（把 AHB 的 dma-buf fd 用 MAP_FIXED 映射到预留窗口，经该地址读写）；256M 只分配 + 导入（`ahb_max`；V0 读数里的 1G 行来自旧版，现已按 448 MiB 上限去掉） |
| `dmabuf` | `/dev/dma_heap/{system,system-uncached,qcom,system,mtk_mm}` 分配 → MAP_FIXED 映射到预留窗口 → `VK_EXT_external_memory_dma_buf` 导入 → 双向一致性：`sync_`（`DMA_BUF_IOCTL_SYNC` 包住 CPU 访问）、`nosync_`（不包）；256M / 1G 只分配 + 导入（`dmabuf_max`）。打不开如实报 errno |

后备内存（`backing`）：`anon_private`（匿名私有）、`anon_shared`（匿名共享）、`memfd_fixed`
（memfd 共享后备，MAP_FIXED 放进 PROT_NONE 预留窗口——S2Arm 游戏地址空间的形状，见
`android/native/memory.c`）。

一致性做法（每个成功导入的缓冲、每个大小各一轮）：
- **CPU→GPU（`c2g_`）**：CPU 经自己的指针写模式数据 → 计算着色器读被测缓冲、`^ 0xA5C3F00F` 写到普通
  HOST_COHERENT 辅助缓冲 → CPU 比对。辅助缓冲预填 0xCD，GPU 没真读写就过不了。
- **GPU→CPU（`g2c_`）**：CPU 先把被测缓冲刷成 0x5A → 着色器读辅助缓冲写被测缓冲 → CPU 经自己的指针比对。
- 屏障：派发前 HOST_WRITE→SHADER_READ|WRITE，派发后 SHADER_WRITE→HOST_READ，栅栏等待；非一致内存类型用
  `vkMapMemory` + flush / invalidate；AHB / dma-buf 被测缓冲另加来自 / 交还 `VK_QUEUE_FAMILY_FOREIGN_EXT`
  （无该扩展时用 `VK_QUEUE_FAMILY_EXTERNAL`）的所有权转移屏障。
- 报告不一致**字节数**和第一个出错的字下标。

## 输出格式

每行一个 JSON 对象（JSON Lines），都有 `"probe":"v0"` 和 `"sec"`。主要字段：

- `status`：`ok` / `fail` / `unsupported` / `skip` / `absent`（堆不存在）/ `accepted`·`rejected`（违规调用的驱动行为）。
- 失败时：`step`（哪一步）+ `vk` / `vk_code`（VkResult）或 `errno` / `strerror` / `ahb_err`。
- 导入：`memory_type_bits`、`req_bits`、`type`、`type_flags`、`dedicated`、`import_us`（建立耗时，含建缓冲 + 分配 + 绑定；不做性能结论）、`props_us`、`ahb_alloc_us`、`heap_alloc_us`。
- 一致性：`[前缀]coh`（ok/fail/skip_…）、`[前缀]coh_step`、`[前缀]c2g_bad_bytes`、`[前缀]g2c_bad_bytes`、`[前缀]*_first_bad_word`。
- 地址：`host_ptr_mod_64k`、`lock_ptr_mod_64k`、`lock_ptr_stable`、`mmap_fixed_ok`、`fixed`、`fixed_alias_lock_ptr`、`map_ptr_eq_host_ptr`。
- 进程：每节结束一行 `sec:"section"`（`done` / `crash` + `signal` / `timeout` / `init_fail`，`ms`），最后一行 `sec:"end"`。

`sec:"section"` 为 `crash` / `timeout` 时，该节已打印的行仍有效，未打印的部分就是没测到，不能当成功。

## 限制

- 一致性只测「单队列 + 栅栏等待」下的可见性，不测 CPU 与 GPU 同时访问同一页、不测性能。
- `fixed_*` 依赖 AHB 原生句柄的第一个 fd 是可 mmap 的 dma-buf、偏移为 0；不满足时如实报 `fail_*`。
- dma-buf 堆在非 root shell 下可能被 SELinux 拒绝，这本身就是读数。
