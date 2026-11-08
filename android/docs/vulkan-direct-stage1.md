# #274 Android Vulkan 直连：第一批实现与接入边界

本文保留首批实现的验证范围；后续启动接线和一加实测见
[vulkan-direct-startup.md](vulkan-direct-startup.md)。

基线 `android/integration@cbacdf8b`；本批只改 `android/`。
维护者已在 #274 的 `6391726766` 评论更正入口为 `s2a_vk_entry` 和
`s2a_vk_lib_ready`，不是早期说明的 `s2a_vk_lookup`。

## 已实现

原生前端 `native/direct_vk.c` 通过 `s2a_android_vk_configure` 接收唯一、进程生命周期
不变的宿主 owner。首批链接进 game native 目标，但不改变默认通用图形启动。

- 静态入口、`vkGetInstanceProcAddr`、`vkGetDeviceProcAddr` 都先核驱动可用性和已审查
  命令集，再交给宿主 `wrap`（生产 owner 应传 `sw_xstack_wrap`）。动态取名也不能泄漏
  裸函数指针。不支持的名称返回 NULL；没有驱动入口时不造成功函数。
- `vkEnumerateInstanceExtensionProperties` 把设备提供的 Android WSI 扩展显示为
  `VK_NN_vi_surface`，保留 layer 查询、容量和 `VK_INCOMPLETE` 语义。
- `vkCreateInstance` 在私有局部副本中改写扩展并去重，不修改游戏的列表；要求
  `VK_KHR_surface` 依赖。物理设备、队列族、内存类型等均由实际驱动返回。
- `vkCreateViSurfaceNN` 必须通过宿主 `window(guest_token)` 解析 HLE 的 vi token。
  不把 token 强转 `ANativeWindow`。现有 window lease 的尺寸/前台/停止状态先验，
  真实 Android Surface 创建失败则归还引用和 generation；成功则持有到 surface 销毁。
- `vkDestroySurfaceKHR` 先销毁驱动 Surface，再释放窗口并确认 lease 撤销；持有 Surface
  时销毁实例明确中止。不对仍在用的窗口提前确认释放。
- fence 等待、acquire、submit、present 和 queue wait 包装 `block_begin/end`，复用
  虚拟核阻塞合同；负 VkResult 原值返回并报告，不混成超时/成功。
- 首批拒绝allocator与实例/设备pNext；后续已补同线程allocator反向调用和经过审核的纯数据
  设备功能链，见[启动接线与复验](vulkan-direct-startup.md)。其他回调仍需单独合同。

首批只允许一实例、一 vi Surface。多实例/Surface、扩展 pNext 和回调需单独补合同。
对象自身的调用并发遵守 Vulkan 外部同步规则。

## 实际验证

小米17 / 25113PN0EC / Android16，原厂 Adreno840，实际 Vulkan1.4.295。
只运行原生探针，未重装或启动游戏，未改存档/keys/资源。

- 《哈迪斯》NSP 本体+更新的 ExeFS 已实际读取：1.0.38233 / 更新589824，
  TitleId `0100535012974000`；main Build ID 前16字节 `d41357a3da356b09fa400b90f303b564`。
  main 100 个 Vulkan 静态导入、0 个 NVN 导入。没有使用金手指。
- 实际驱动对这100个入口均能解析；这只是地址可用性，不是全部API/游戏调用验收。
- 真实提交、fence 等待与4096字节逐字读回通过，调用路径经过本前端。
- 真实切栈128次静态/动态调用通过，客体栈有两侧保护页。
- 受控分派＋真实lease用例136项检查通过；七个编译成功的负控均产生预期失败。
  两项void错误退出码均为72。具体源码哈希以 `run.py` 的回执为准。
- NDK29 / API29 的game CMake目标中，新增 `direct_vk.c.o` 实际编译通过。
  该项配置使用已有NativeAOT archive作为CMake输入，只构建新增对象，未完整重链APK。
- 生产提交 `8984093f` 的 `tools/contrib_check.sh --base cbacdf8b` 返回0：
  第一层应跑4步、实跑4步、绿4红0；语法、shared_path、252个补丁核对、Android钩子通过。
  使用本机Xcode26.3路径；doctor仍提示与27.1要求不符，本次路由不含iOS构建，未跳过
  本轮应跑步骤。不能将此摘要扩展为苹果运行端或完整Android APK验证。

## 尚未完成，不能声称直连游戏已出帧

1. `plat_android.c` 的 `s2a_gfx_mode` / `s2a_direct_lookup` 当前仍固定通用。
   NativeAOT 组合仍启动通用 `AndroidVulkanRuntime`。需先设计冷启动冻结的模式选择，
   让装载期与服务期消费同一份选择；两套渲染器不能同时持有窗口 lease。
2. `window(guest_token)` 要从实际 HLE vi/Binder 层建立身份映射。本批只定义接口并测
   真lease消费者；受控 token 验证不是已完成生产 HLE 接线。
3. swapchain 代际、后台/旋转、inflight present 退休与停止的生产 owner 还要接既有合同。
   仅Surface销毁测试不能证明在途交换链安全。不得把 present 返回当 GPU/显示完成。
4. 因此 `s2a_vk_lib_ready` 本批明确返回0，不将未完成的后端自动宣告就绪。包内SPIR-V
   清单、缓存身份、模块选择（跳过客体Vulkan加载器/驱动）仍要复用公共识别接上。
5. 需将同一游戏真正跑到第一帧/可操作，覆盖完整SPIR-V与动态取名，再量性能、热态及
   多局能耗。原语通过不能替代本单游戏验收。

本批未改公共图形识别、Metal、Ryujinx 或其他平台目录，不向 main/integration 推送，
也未创建PR；后续发布按设备持有人确认执行。
