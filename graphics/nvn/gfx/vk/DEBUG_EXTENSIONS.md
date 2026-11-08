# Vulkan 调试扩展

关联 #271。三组扩展共 19 个入口，均通过 `VK` 宏检查官方 `PFN_vk*` 签名并注册到真实 `swhle` 表。

| 扩展 | 层级 / revision | 入口与行为 |
|---|---|---|
| `VK_EXT_debug_utils` | instance / 2 | Create / Destroy messenger、Submit message；对象 Name / Tag；Queue 与 Cmd 的 Begin / Insert / End label，共 11 个 |
| `VK_EXT_debug_report` | instance / 10 | Create / Destroy callback、Report message，共 3 个 |
| `VK_EXT_debug_marker` | device / 4，依赖 debug_report | 对象 Name / Tag；Cmd Begin / Insert / End marker，共 5 个 |

每个 instance 独立拥有回调。utils 按 severity 和 type 同时过滤，report 按 flags 过滤；主动提交的消息保留调用者字段，仅分发到对应扩展。回调在调用线程同步执行。分发先在锁内保活本轮回调，再解锁调用，允许 report consumer 创建其他回调并嵌套提交消息；销毁等待正在执行的调用结束。

`VkInstanceCreateInfo.pNext` 中的临时回调仍登记、随 instance 释放，仅供创建、销毁期间的真实诊断使用；不合成创建或销毁消息，中间主动提交消息不触发它们。保存的 createInfo 和 instance 分配器均为值拷贝。child 未指定分配器时继承 instance；销毁使用调用者传入的兼容分配器。创建过程分配失败会释放已分配对象并返回 `VK_ERROR_OUT_OF_HOST_MEMORY`。

`DM_VK_LOG` 开启时，对象名、二进制 tag 和 queue label 写入 `[vk] [debug]` 日志；tag 每 32 字节一行十六进制，保留全部数据。Cmd label / marker 把名字和颜色拷贝进命令流，提交时输出，reset 后丢弃；关闭时六个 Cmd 入口直接返回，不复制或记录标签，对象和 queue 诊断也不输出。它们不改 Metal 渲染状态。这是任务允许的日志实现，不是 Vulkan 验证层或 Metal 调试工具集成；不会为普通绘制合成验证消息。

## 验证

局部接口回归链接实际宿主、当前 NVN 库和真实 Widen NativeAOT，检查扩展层级 / revision、19 个注册入口与全部函数行为。覆盖过滤、完整消息字段、同线程、instance 隔离、回调重入、分配器继承和兼容销毁；日志覆盖名字移除、7 / 65 字节 tag、全部 label / marker、录制输入快照与 reset。私有验证副本不纳入仓库或常规门禁。

GPU 对照为两次 16×16 RGBA8 附件清除 / 读回：无标签和带标签结果逐字节一致，并逐像素核对手算 `{64,128,191,255}`。这是 Apple 芯片 Mac 接口回归；哈迪斯直连局、iPhone / iPad 和老系统实机由维护者继续验收。

规范：[debug_utils](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_debug_utils.html)、[debug_report](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_debug_report.html)、[debug_marker](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_debug_marker.html)、[宿主分配回调](https://docs.vulkan.org/spec/latest/chapters/memory.html#memory-host)。
