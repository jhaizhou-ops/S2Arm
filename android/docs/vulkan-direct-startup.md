# #274 Vulkan 直连启动接线与一加实际复现

前置实现与原语验证见 [vulkan-direct-stage1.md](vulkan-direct-stage1.md)。
本批基于 `cbacdf8b`，代码只在Android目录；共享文档另补客观坑记录。

## 已接入的生产链

1. `s2arm.experimental_vulkan_direct` 是缺省关闭的冷启动实验开关。Java严格要求boolean，
   Native `direct_session.c` 在重定位前冻结选择；改变已冻结模式返回EBUSY。
   服务层只读同一 `s2a_gfx_mode`，不再从可变环境另作选择。自动就绪仍关闭。
   后续（#274 零配置就绪判定）：开关另收字符串 `"auto"`（`VulkanDirectChoice`），`s2a_vk_lib_ready` 改为按
   `direct-vulkan.txt` 判定（与冷启动准备同一解析，`direct_choice.c`）；缺省仍是通用（`VulkanDirectChoice.DEFAULT`）。
2. `make_pack.py --direct-vulkan` 复用 `nso_syms.py`，要求main有Vulkan导入、没有NVN/EGL。
   按导出识别嵌入的Vulkan loader/ICD模块，若剩余模块依赖其独有的非Vulkan符号则拒绝。
   不按游戏Title ID或地址选择。全部代码仍签入APK，直连局只跳过描述文件列出的驱动模块；
   通用模式保留完整模块集合。
3. `direct-vulkan.txt` 同时进入签名模块资产和资源根目录索引。后者会在移除外部
   `modules/` 的资源绑定阶段继续保留，避免冷启动找不到选择描述。
4. 直连组合使用 `DirectServiceRenderer` 承载HLE上下文。它不创建GAL资源；任何意外
   CreateBuffer/同步/管线/窗口等模拟GPU操作都抛错。真实 `GpuContext` 构造/销毁和9类
   误入负例共10项通过；不通过假渲染结果启动游戏。通用路径仍使用AndroidVulkanRuntime。
5. `DirectLayer` 为已存在的内部HLE getter保留NativeAOT反射元数据，只读当前layer ID。
   Native窗口解析还要校验guest内存与ANativeWindow头、锁定同一token/layer；实际Surface
   解析尚未到达，不能把代码接线当成窗口/旋转/退休已验收。
6. 复用 `tools/nro_exports.py` 出表，APK来源装载前从验证后的资源根读表。
   本地哈迪斯表有369个导出，39个EOS强导入转为原有延迟解析。没有实现EOS空函数；
   真正调用未完成装载的导入仍走共同的致命桩。动态NRO执行未因此宣称完成。

## 实际设备与包

用户随后固定改用一加：PJA110 / SM8550 / Adreno740 / Android15(API35) / 4096字节宿主页；
原厂Vulkan1.3.128、driverVersion2150252615，Surface2772×1240。后续安装/取证均用该机，
没有自动回退小米。设备序列号只留私有选择文件。

《哈迪斯》1.0.38233，TitleId0100535012974000，main前16字节Build ID
`d41357a3da356b09fa400b90f303b564`。安装本地v4候选，实际读回APK SHA和资源绑定一致。
资源3593文件、资源根
`sha256-6af1d403840915dbe8b24d258b4292fec3ba5f7735b27f418a837d0558509e83`。
USB传输106.7秒；通过正常导入器校验/激活，首次存储3910.6MiB、复用9.0MiB。

本轮是在USB充电、电量1%的设备上做有界启动诊断，不是性能或功耗验收。

## 真实启动结果（未出帧）

- 完成服务、输入泵、SDK初始化、DT_INIT，进入nnMain；HLE建layer1。
- 日志明确为Vulkan直连，通用GPU线程未启动，装载器未执行subsdk0/subsdk1。
- 第一个明确失败：`vkCreateInstance guest allocator: VkResult=-8`。
  -8为 `VK_ERROR_FEATURE_NOT_PRESENT`，由当前前端对未支持guest allocator的检查返回；
  并非Adreno驱动返回不支持Vulkan。随后游戏Break，收局仍记录guest/fault未停稳并退出125。
- 没到标题、没有游戏present、未调用实际vi Surface解析，不能宣称直连可操作或正常退出。

小米旧局也在同一处失败；一加本轮独立复现，不用旧手机结果替代新机证据。

## 后续实现与一加复验（v5–v7）

已在 Android 私有层支持 `VkAllocationCallbacks` 的反向调用，不忽略allocator或替换成默认malloc。
[Vulkan内存规范](https://docs.vulkan.org/spec/latest/chapters/memory.html)要求allocator回调在
触发API的同一线程同步调用，且回调不能调用Vulkan。因此可保留原guest线程/TLS，切回
其安全客体栈调用allocation/reallocation/free及可选internal notification，再恢复宿主栈。

`direct_callback.c/.S` 保存外层宿主活帧，回到外层入口保存的客体SP；回调前将xstack游标
推进到当前宿主帧之下，回调后恢复，允许客体回调再次进入svc/宿主。阻塞放核期间临时取回
虚拟核；allocator原结构复制到最多256组、进程内不回收的上下文，保留userdata与全部回调。
不接受回调递归、缺失客体线程或不匹配外层帧，错误明确终止。

一加真实xstack受控驱动：3次allocate、4次reallocate、3次free、2次internal通知，覆盖
嵌套24KiB宿主栈、32KiB驱动栈canary、TLS/同线程、结构复制后原结构清零、realloc(NULL)、
零长度释放和失败保留原块。真实Android驱动实例创建/销毁为13次allocate、21次free。
错误上下文、回调留宿主栈、不推进/不恢复游标、不取回虚拟核的负控均实际失败。

v5游戏实例创建成功，分配回调累计23次；随后被前端的设备pNext拒绝。v6记录链类型
1000059000和1000161001：标准Features2与DescriptorIndexingFeatures。
v7保留原链与请求位交给驱动，设备创建成功；随后客体PC=0退出，尚未到实际Surface。
相关受控回归验证完整链传递、请求位保留、拒绝循环与Features2/旧features同时设置。

## iOS参考的边界

对照 `origin/main@eef69537` 的 `graphics/nvn/gfx/vk/hle_vk.m`：iOS的CreateInstance/CreateDevice
使用自有对象、Metal设备，未把allocator或设备pNext转交系统Vulkan；GetPhysicalDeviceFeatures2
只填写基础features。这解释了它没有遇到Android转发的同一个拒绝点，不能将忽略字段照搬到
Adreno。Android继续采用同线程反向回调、纯数据功能链原样转发和真实驱动返回值。

iOS的取址会尝试去掉KHR后缀；Android初始只登记静态100入口，漏掉运行时请求的
BindMemory2KHR、GetMemoryRequirements2KHR和DescriptorUpdateTemplateKHR。
现已登记这些标准接口的真实转发，模板创建/销毁同样适配allocator，不返回占位成功。
取址按名称最多记录512项，区分driver不存在与桥接表未登记；实际游戏结果继续按新包复验。

未推送、未新建PR；一加保留最新诊断候选及已验证资源。完整交换链生命周期、真实上屏、正常
停止和性能/能耗仍未验收。首批 `s2a_vk_lib_ready` 继续返回0，防止自动开启未完成功能。
