# Vulkan 保留绑定容量（#881）

从仓库根运行 `bash tests/vulkan_reserved_bindings_test.sh`。需要已安装 .NET 10；
NuGet 源清空，不下载 SDK / 包。测试仅用原创合成资源请求，不需 Vulkan、GPU 或游戏。

显式链接生产 `GpuAccessorBase`、`ResourceReservations` / `ResourceReservationCounts`、
`Capabilities`、资源枚举和 Vulkan `Constants`；不复制绑定计算算法。宿主替身只替代设备、
日志、格式查询与未使用的 profile 路径，意外调用会抛异常。未编译完整 GPU 项目及游戏派生宏表。

覆盖 5 阶段 × 变换反馈开关 × 顶点转计算开关，实际调用生产绑定分配器，核 UBO、
SSBO、普通纹理、缓冲纹理、未改变的 image 范围。细分评估阶段输入索引为 2，
生产 `GetStageIndex` 映射到绑定阶段 4。最大值分别为 UBO 91 / 92、SSBO 86 / 87、
缓冲纹理 673 / 674（绑定 / 容量），要求最大索引等于容量减一。

纹理的两种引用数组及实际 SSBO 引用数组容量读取 `DescriptorSetUpdater.cs` 的生产
分配表达式，并用链接的生产常量求值、实际索引 CPU 数组；找不到表达式会失败。
这是容量边界测试，**不是 Vulkan 描述符更新或设备执行测试**。SSBO 已有诊断槽 96，
实际数组容量 97；保留它不缩容，另测普通 SSBO 常量的容量合同。布局由程序资源描述符动态
生成，不存在要同步扩大的固定常量布局。

在基线 bf4b7c9d4 用同一测试修前 11 项失败、退出 1；修后 141 项通过、退出 0。
UBO cbuf 17 原为绑定 90 / 容量 90；全保留模式为 91 / 90。
纹理原为 673 / 640。普通 SSBO 常量原为 86 / 80，而已有诊断数组仍可容纳。
对应语义来源：NextendoNetwork/Ryujinx-Nextendo 的 `c7a285a6e0` 和 `6697528fff`。
