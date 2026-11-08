# Android 直连实施契约 v1

初始设计：2026-10-25；本轮审订：2026-10-29。本文维护 Android runtime/NativeAOT、shader 与资源/完成的约束，**不维护当前进度，也不代替源码头文件或维护方 D0 公共后端接口**。任务和已验范围只见[统一方案 §11](fast-generic-v3.md#android-main-w236-plan)；原 iOS 对照来自 `a5ba0e16`，不能作为最新状态。修改接口须同步 producer、consumer、版本与独立反例，不能各自补默认值。

本文的 v1 是文档版本，不代表 services/runtime、native direct table、编译 JSON 和 D0 共用一个版本号。下列区分源码已定义的私有 ABI、必须满足的安全要求和维护方公共合同；要求不等于当前实现已经满足。实现差异及待验项只在统一方案维护；本次审订不改变源码 ABI 或游戏支持范围。

**2026-10-29 执行边界**：当前任务、状态与迁移以[统一方案 §11](fast-generic-v3.md#android-main-w236-plan)为准。跨平台公共后端 `nvn_backend.h` 由维护方画面线按 [#968 的 D0/W1 定序](https://github.com/jhaizhou-ops/S2Arm/issues/968#issuecomment-6489009411)负责；维护方已接受首轮意见并发布 v2，接收/实现仍须核验。本文不授权本线另建公共头、改 iOS 回放或扩展 `mtl_vk_shim`。runtime/NativeAOT、结果格式、所有权要求继续核验；不能把合同已发布当 main 已接实现。本轮只审订文档，不新增或改写 C ABI。

**D0 当前对照为 v2**：维护方[接受 7 条语义补充和 9 项选择](https://github.com/jhaizhou-ops/S2Arm/issues/968#issuecomment-6490388426)，在 `wire-c/nvn-backend-d0@e77ec0d54b0c6bf66760c7fdd418a7962a9b2dce` 发布[公共头](https://github.com/jhaizhou-ops/S2Arm/blob/e77ec0d54b0c6bf66760c7fdd418a7962a9b2dce/gfx/nvn/gfx/nvn/nvn_backend.h)和[平台节拍头](https://github.com/jhaizhou-ops/S2Arm/blob/e77ec0d54b0c6bf66760c7fdd418a7962a9b2dce/gfx/nvn/gfx/nvn/nvn_vsync.h)。`nvn_gpu_*` 是共享核心下沿，`nvn_be_*` 是上沿；AChoreographer 通过平台 `nvn_vsync_*` 接核心。v1 审查仅作追溯，当前接收状态/测试限制见统一方案 §11.4.4；未接共享核心/Metal/Vulkan，不能算 W1 已完成。

本轮源码对照包含 #868 的固定快照 `642ec4574e5191d59218c30507e5c16dd5c77526` 与本地旧开发树，不能把旧树缺文件或候选有文件外推为当前 main 状态。正式实施仍以统一方案锁定的接收 main 为准。下文“必须”表示安全/验收要求；“已有”限明确指出的符号/源码，不是整条生产链已通过。

## 1. 首版边界与 iOS 对照

首版只交付 **NVN C 前端 → 共享回放核心 → 原生 Vulkan 后端**；共享核心尚待 W1 抽取，现有过渡接线不是另一条长期路线。Switch Vulkan/OpenGL 是后续独立前端。一个进程只运行一局、只拥有一套执行后端，不实现局内切换。首款选已有通用可玩参照的 NVN 游戏；不承诺首版所有游戏、所有设备或全部 NVN 扩展可用，不用游戏名单或固定事实表选择能力。

| 接点 | 10-25 iOS 参照（非当前状态） | Android 的实现约束 |
|---|---|---|
| 装载前选择 | [gfxmode.c](../../runtime/src/gfxmode.c) 在 loader 查询时一次确定，direct 只接管图形入口 | runtime 在 `load_modules*` 前完成 Prepare/commit，`s2a_direct_lookup` 只读冻结结果；准入必须依真实 provider/能力，不能用成功桩代替 |
| 系统层与图形分流 | [Compose.cs](../../services/aot/Compose.cs) 的 direct AfterBoot 跳过 RenderLoop，仍登记 HLE；当时工厂还构造 NxRenderer 包装对象 | Android 在创建 `AndroidVulkanRuntime` 前分流；沿 #868 的 DirectServiceRenderer 保留 HLE 所需 GpuContext 外壳，不恢复旧树 DirectRenderer 的空同步方法，不启动 generic graphics loop 或第二 device |
| shader 源生命周期 | [hle_nvn.c](../../graphics/nvn/gfx/nvn/hle_nvn.c) 在 SetShaders 读取控制段，也记录了代码尚未映射的情况 | 当场复制控制段；代码用 pool/generation 解析，首次消费前补齐并复制；worker 永不回读控制段指针 |
| 现场翻译 | [Dsh.cs](../../graphics/tools/direct/dsh/Dsh.cs) 仍读取 Tables/Facts，并经 SwshXlate 出目标代码 | 只复用可证明的抽取/改写逻辑；采用主仓锁版本 Ryujinx translator、静态 accessor 和真实 draw 快照，不复用未知查询默认值 |
| 管线安全网 | [iOS 研究](../../../docs/研究/直连首遇安全网.md) 的函数体/链接桩依赖 Metal，文档自身仍标部分待实现 | Vulkan 首版没有桩：真实 SPIR-V → 真实 pipeline；需求任务优先，缺项等待，不跳 draw |
| 阻塞与虚拟核 | [s2a_direct_host.h](../../runtime/include/s2a_direct_host.h) 已定义 `s2a_core_block_begin/end` | guest 等 GPU、编译、Acquire、节拍时全部成对放核；异常/取消也归还，单核负例是门禁 |
| 跟踪/前后台 | iOS 已有统一 fault/write-prep 接点；Metal layer/后台门是 Apple 实现 | 保留 Android dispatcher、backing 事务和 lease，具体规则见 §6/7；不移植第二信号处理器或第二窗口来源 |
| 故障下一局通用 | gfxmode.c 的 fail 标记、mode 与 `s2a_mode_request` 已有实现 | 沿既有 selection/attempt 实现核验模式冻结与下次 AUTO generic；持久 attempt 覆盖 SIGKILL/崩溃未执行 handler，不重复新增另一套故障锁 |

这些是本地源码阅读结果；旧研究中“未实现/推断”的状态不能盖过当前源码，也不能把 iOS 的 Metal/游戏结果当作安卓证据。

## 2. native / NativeAOT ABI 与启动事务

### 2.1 接口版本与所有权

接口声明与布局唯一来源是 [s2a_direct.h](../native/direct/s2a_direct.h)、[services_abi.h](../native/runtime/services_abi.h)、[runtime.h](../native/runtime/runtime.h) 及其实际 managed 消费者。保留 services ABI v1 的 64 字节 request / 24 字节 status，**旧 start v1 只启动 generic**。direct 使用既有 services/runtime v2；不覆盖旧符号，不复用 v1 的 reserved 位传指针。v2 前缀的 size/version 必须为新值；旧入口收到 version 2 明确拒绝。

v2 services request 是原 request 字段布局前缀（version=2），后接 `const s2a_direct_api_v1 *graphics`（LP64 偏移 64）、`uint32_t graphics_mode`（72，0 generic / 1 direct）、`uint32_t flags`（76，首版必须 0），总长 **80 字节**。services status 保留 version=1，同时服务两种模式；不能把 request version=2 写进 status。generic 要求 graphics=NULL；direct 要求 table/context/session 与冻结 selection 全匹配。runtime v2 总长 **160 字节**，含 size/version、mode_preference、v2 services 请求、模块/NPDM/program 字段和带长度的 graphics descriptor；输入的 `services.graphics=NULL`、`services.graphics_mode=0`，由 native 在 Prepare/commit 后填写实际 table/mode，外壳不能注入任意 context。

**三个 status 不能互换**，即使 LP64 大小同为 24 字节：`s2a_android_services_status` 含 session，state/error 偏移为 16/20；`s2a_direct_status_v1` 含 blockers，state/blockers/error 偏移为 8/12/16；`s2a_android_runtime_status` 没有 size/version 前缀，另有 services_error/last_phase。managed direct/请求镜像见 [DirectAbi.cs](../core-runtime/DirectAbi.cs)，services 状态消费见 [AndroidGameRuntime.cs](../core-runtime/AndroidGameRuntime.cs)；services/runtime 各自状态和错误码不等同 direct 枚举。`mode_preference` 的 direct=2 与最终 `graphics_mode` 的 direct=1 同样不能直接复制。

本节不再手抄一份 C 函数表。`s2a_direct_api_v1` 的 LP64 大小/offset 由生产头中的断言约束；合入时核对实际 producer/managed consumer，不能因本文写了尺寸就宣布双端正确。

`table/context`、HostApi、lease 与已登记回调的控制记录保活到安全退出；不能 dlclose 仍有引用的 NativeAOT。Destroy 只释放已证明安全的 GPU/窗口/worker 资源；迟到回调必须能够安全识别已停止的 session/generation。

**三类接口分开处理**：NVN guest ABI 由共享 `nvn.h/nvn_obj.h` 定义；D0 的 `nvn_gpu_*` 是核心到图形后端的接口；`s2a_direct_api_v1` 是 Android 会话到 NativeAOT 的私有 ABI。三者的角色、版本和错误码不相同。D0 v1 的 -7/-5 撞值已在 v2 改为独立区间 [-1099,-1000]，返回单成员结构 `nvn_gpu_rc`：Pending=-1007、Timeout=-1005。接点须按维护方设计 §3.3 显式映射 `.code`，不能直接转成会话状态；仍需核纯 Pending、退休 timeout、可重建/撤销及终态错误的实际调用语义。

仅 Android 私有 direct ABI 的状态为 Prepared=0、Active=1、Stopping=2、Stopped=3、Failed=4，返回码为 0 成功，1 Pending，-1 Argument，-2 Version，-3 Unsupported，-4 Identity，-5 Stopped，-6 Compile，-7 Driver，-8 Retirement，-9 Internal。负码不能当成功；但 `query` 返回 0 只证明查询成功，仍须核返回的 state/error/blockers。blockers 位为 guest=1、compile=2、submit=4、present=8、readback=16、writer=32；Stopped 要求全部为零，也不单独证明 managed/guest 已退出或可清 attempt。编译诊断 `MISSING_FACT` / `RESOURCE_LIMIT` 是字符串原因，不是本表新增的数字错误码；UCO 的实际映射见 [DirectCompileNative.cs](../core-runtime/DirectCompileNative.cs)。

Prepare 是 native 私有工厂：消费已验证 descriptor/session/lease/路径，创建或持有唯一设备并采能力，返回 table 或准确错误；所有路径、JSON 与 profile 由 context 复制。GetProc 经冻结 selection 解析并走现有 xstack，不放进跨托管 table。Prepared 未激活且无在途引用时可 Destroy 撤销候选；激活后先走统一 Stop/退休，不能仅凭 Failed 或一次 Stop 返回就释放。失败后若真正完成安全收尾，可以释放安全资源，但首错和故障锁仍须保留；不能把“失败不伪造完成”理解成“失败对象永久不允许清理”。

`compile_fn` 必须在 Activate 前按 context/session 登记并冻结，同一指针重复可幂等，不允许替换成另一个 producer。**这是待核验的安全要求**：[compiler_bind.c](../native/direct/compiler_bind.c) 的现有登记函数本身仍允许覆盖同 context 的指针；不能据本文宣称已拒绝替换，也不能用 `bound_compile_any` 代替会话身份验证。生产调度由真实宿主 worker 执行，不能来自信号 handler；UCO 捕获异常并转换状态。缺口及回归统一归 §11 W2 的绑定/worker 工作。

编译入参在调用期间有效；编译器同步计算后最多调用 emit 一次，不保存入参或 sink。emit 在返回前把结果复制到 native owner 的内存；native 分配/native 释放，托管分配不交给 free。emit 非零则整个 compile 失败。取消通过 session/context generation 与停止位检查；迟到结果可释放但不能激活。一次跨界处理一个完整 graphics program 或 compute program，不逐条 NVN API 跨界。

### 2.2 唯一启动顺序

1. 外壳验证 current/artifact/graphics descriptor，建立 session，持有原有地址窗口与 lease；读取故障锁及玩家模式选择。
2. runtime 通过信号准备与基本 selfcheck，在 `load_modules*` 前 Prepare direct：选物理设备、单一 graphics+compute+present queue family，创建一份 device/Surface，得到实际 enabled profile。第一版不实现跨 queue-family ownership。
3. 尚未 commit 时的结构性不支持：销毁候选 Surface/device/窗口引用，证明全部释放后，AUTO 可选 generic；显式 direct 应报告准入失败，不能静默换模式。无法证明释放则失败退出，不能同时建立 generic；手动 generic 从始至终不创建 direct 候选。
4. 准备选 direct 时，将 attempt 持久落盘后发布冻结 selection，commit 一次。selection 中的身份/表以 [selection.h](../native/direct/selection.h) 为准，不按本文示意自建第二结构。此后终态错误结束本次会话/进程，不在已加载的本局原地改 generic；可恢复的窗口重建/未就绪按 §7.1 原协议处理，不能一律当致命错误。下次 AUTO 才按故障保护选择 generic。
5. loader 按 selection 解析导入；随后 `s2a_mem_init` 校验 NPDM/program 身份与现行内存 ABI。v2 services Start 按 mode 建 HLE/音频/输入/UI：direct 分支登记编译器、跟踪/服务 adapter，Activate native owner；generic 沿原 worker 路径。
6. Ready 的必要条件：原有服务自检、真实 guest pthread attach/fault 探针，加上 direct owner 已 Active、profile 匹配、编译函数可用、唯一 tracking 消费者和窗口控制已接。条件齐才放行 SDK/nnMain；启动中取消走相同 Stop。

mode 固定在 relocation 前，但 **不执行 guest，也不在 Prepare 注册不可撤销 tracking callbacks**。这些在 commit 后、guest 放行前登记；一旦登记失败按 fatal 处理。离线 shader 覆盖量、seen 数量或游戏白名单不参与 mode 准入。

### 2.3 实际设备与翻译 profile

这里已有两种不同 JSON，不能合并或由两端分别造 profile：native 的 [device_caps.c](../native/direct/device_caps.c) 从生产使用的唯一 device 导出 `s2a-device-caps-v1`，记录物理/driver 身份、实际 enabled features/extensions、limits/subgroup、格式用途与内存事实；Prepare 调 `s2a_direct_profile_json_v1`，由 compiler 的 [DirectProfileComposer.Compose](../../graphics/tools/direct/compiler/DirectProfileCompose.cs) 合成 `s2a-direct-profile-v1`。后者含编译目标、有效 Capabilities、support layout、closure/directABI/runtimeCompilerABI 与规范化 profileHash，不是原始 caps 的逐字段副本，也没有本文另造的 codec 字段。

native 原样持有合成结果，`s2a_direct_profile_v1` 的同步 emit 供 managed 读取；CLI `profile` 命令走同一 composer。native 不重算 support/profile hash，consumer 不创建 GAL Vulkan renderer 或第二 device 查能力。没有进入 effective profile 的原始 driver/device 身份仍须用于相应 driver cache 兼容校验和诊断，不能从 profileHash 相同推出驱动二进制可混用。closure 必须绑定实际 compiler 构建，缺口与验收见统一方案 §11 W2.1/W2.3。

首版正确性基线为单 queue family、普通 render pass/framebuffer、二进制 semaphore+fence、staging 上传/读回，不强依赖 dynamic rendering、descriptor buffer、timeline、BDA 或 graphics pipeline library。Vulkan1.1/SPIR-V1.3 是当前编译目标；正式 WSI 的额外准入见 §7.1，不能声称 Vulkan1.1 自带该能力。经过专项实现/验收的可选快路可以扩展 profile，不能悄悄抬高基线。descriptor/UBO/SSBO offset、range、VkFormat 用途按实际 limits 核对；robustness 必须有真实启用或已验证的等价边界处理。未实现的 geometry/tess/TF、vertex-as-compute 保持关闭，硬件支持不等于执行层支持。

Maxwell warp32 语义不能由“支持 subgroup”推出：只有所需 stage/操作实际满足 32-lane 合同，或等价改写通过 C3 GPU 输出验证后才开放，否则相关 shader 明确 Unsupported。格式/BC 先用设备真实支持的等价路径；CPU 解码只作已实现且验证过的回退，不能无条件重解码原生已支持格式，也不能宣称未实现格式已获支持。离线 profile 首版按规范 hash 精确匹配，不另建“硬件更强就可混用”规则；变化换键。

## 3. NVN / ELF 适配与命令边界

采用 main 的共享 `nvn.h/nvn_obj.h/nvn_tex.h` 与记录定义为唯一 guest/API 及命令布局来源；D2R 仅供算法/历史对照，不能让共享前端产生的记录按 D2R 格式解释。Android 平台移植沿现有 ELF/NDK/xstack 实现，不新增 Metal 类型、Mach-O thunk 或伪装宏；函数名表从维护方 `names.txt` 生成。紧凑/完整记录、版本与全部消费者一起核对，不能因无文本冲突或同 opcode 就认为可直接回放。

目标是共享前端/回放核心通过 D0 定稿接口分别调用 Metal/Vulkan；接口与共享核心/Metal 由维护方画面线牵头，我方接 Vulkan 下沿。平台无关 Vulkan 实现归 `graphics/vulkan/`，Android Surface/JNI/生命周期归 `android/`；具体子目录随属主/D0 确认，不据本文抢建接口或搬整目录。`mtl_vk_shim` 及 `mtl_vk_adapter` 的兼容转接不接新语义，不复制/改名 shim、不自建私有 backend ops 替代 D0。对象 FITS 断言不变；核心保有 NVN 对象/源身份，backend 保有目标资源及提交引用。Finalize 只撤销后续查找，已录制未提交、GPU 在途、worker 和间接 GPU 地址引用均须保活至最后真实使用，不能只保护已提交帧。

异步延后消费时，`QueueSubmitCommands` 返回 guest 前必须完成会失效的命令存储/CPU 控制元数据的自持快照，并按 NVN 语义处理必须在原线程执行的 guest 回调；同步路径不因此强制新增翻译线程或额外拷贝。END/JUMP/CALL、截断/越界、递归/预算等由共享核心按当前记录协议统一检查；本线不复制 OP 解码器。命令拍平只解决命令存储寿命，不自动冻结后续 draw 所读资源内容。GPU 生成字节/间接参数按执行序保留 backing lease、版本和真实依赖，不提前复制成旧 CPU 值。

owner 只有一条，不能同步回调 guest；需要申请 command memory 的回调在原 guest 调用线程、正常 xstack 上执行。多 guest 提交按 NVN queue 语义取序；首版同一队列提交锁串行且先完成快照，资源按 submit serial 持有。等待容量/完成时放开对象和 VM 锁并用 `s2a_core_block_begin/end`；取消必须唤醒。

所有已实现、只读查询、合法无副作用与未支持函数生成一张覆盖表，未知 API/record 报函数名/opcode 并失败。debug label 等正式无副作用可记录成功；控制流、内存、同步、draw/dispatch、stage、格式或 callback 均不能假设无副作用。首版 graphics 合同为 VS+FS，另支持 CS；geometry/tess/TF 语义明确报 Unsupported；设备和实现都支持并通过专项输出测试后才开放，不以返回空记录覆盖。

## 4. 现场着色器与 direct binding ABI

### 4.1 源快照与真实查询

只使用 `compat/tree` 锁定的 Graphics.Shader，禁止误链 `graphics/nvn/third_party` 的不同副本。使用共用 `DirectGpuAccessor : IGpuAccessor`，显式实现该锁版本的**全部方法**，禁止继承接口的“返回 0 / Texture2D / true”默认答案。接口增加方法时编译期/反射清单测试失败，要求新增来源映射；NativeAOT 正式路径无 DispatchProxy、反射造类型或进程内命令行编译器。

| IGpuAccessor 方法族 | 唯一事实来源与缺项规则 |
|---|---|
| GetCode、ConstantBuffer1Read | SetShaders 控制段快照、pool/backing 解析后的完整代码区、由对应 shader 代码区抽出的 NVN literal C1 有界字节；只读快照内地址，越界/缺失失败 |
| ComputeLocalSizeX/Y/Z、LocalMemory/SharedMemory | 同版本控制段/程序元数据正式字段；与 Dispatch 约束核对，不能从 dispatch 组数猜 local size |
| ConstantBufferUse、GraphicsState、DrawParameters、UnalignedStorageBuffer | 解码后当前绑定掩码、拓扑/顶点格式/附件类型/depth/alpha/tess 状态、真实 CB0 draw 参数规则与 storage 对齐；不按游戏名补值 |
| SamplerType、TextureIsBuffer、CoordNormalized、TextureFormat | 当前 stage 的真实绑定来源，解析 NVN 逻辑槽/texture handle 或 shader CbufSlot/handle word offset，再取 pool+generation 的 texture/view/sampler 描述；纹理型与 buffer 型分开记录 |
| TextureArrayLengthFromBuffer/Pool、SamplerArrayLengthFromPool | 以锁版本的实际 producer/translator consumer 为准：FromBuffer 返回当前 stage 的 cbuf 字节长度 / `Constants.TextureHandleSizeInBytes` 的整数商；该常量为 8，返回的是句柄个数。FromPool 为有效 maximumId+1 的可索引容量，不是已使用纹理数。来源/长度不明则缺事实，不答“1” |
| TransformFeedbackEnabled/VaryingLocations/Stride | 本次命令/程序的真实 TF 状态；首版没有实现其执行语义时，在消费该程序前 Unsupported |
| 全部 QueryHost* | Prepare 实际 enabled features、limits、formats、subgroup 与本 backend 已实现语义组成的 EffectiveProfile；bug workaround 为带证据版本的策略，未知不能宣称硬件支持 |
| Create*Binding、CreateExtraSet | §4.2 的确定 allocator，CreateExtraSet 固定 -1；数组仍在标准四个 set 中，descriptor 能力不足明确失败 |
| RegisterTexture、S2AReportStateUse、Log | 收集实际读取依赖/绑定反射与诊断，供重用验证；不是忽略错误的查询接口 |

**长度单位的独立期望**：64 字节 cbuf 的 FromBuffer 查询应为 8，128 字节应为 16，不能返回 64/128；texture pool maximumId=7 时 FromPool 应为 8。依据是 [GpuAccessor 的实际返回](../../compat/tree/src/Ryujinx.Graphics.Gpu/Shader/GpuAccessor.cs)、[8 字节句柄定义](../../compat/tree/src/Ryujinx.Graphics.Gpu/Constants.cs)及 [BindlessToArray 的数组长度消费](../../compat/tree/src/Ryujinx.Graphics.Shader/Translation/Optimizations/BindlessToArray.cs)。`IGpuAccessor` 的旧注释写“字节数”，与这些实现不一致；不能只按该注释实现。`textureBufferLengths` 输入采用相同个数单位，数据来源仍须先按 bank→NVN uniform 映射解析。

控制段在 SetShaders 调用内用受校验的 guest 范围复制，先验证自描述长度、stage、code size/offset；支持 parser 版本才解释字段。复用共用抽取器/解析器，新增版本用合成结构和合法本地样本证明，不能按标题号判格式。不能无条件 memcpy 0x880，不能把 iOS/D2R 单款配对表当解析器。代码若已映射就复制；尚未映射时记录地址/长度、pool 身份及未就绪状态，首次实际消费前从仍有效 backing 解析并复制；这不是向 guest NVN ABI 任意新增 Pending 返回码。来源失效明确失败，不回读旧 control 指针；代码/池代际改变失效旧源身份。

快照按命令执行序形成。此前 GPU 写过的 uniform、descriptor、代码或间接参数必须先满足真实依赖，必要时分批提交/读回，再复制事实；不能在 replay 前一次性读取所有 draw 状态。纹理/附件/资源“未知”与“实际未绑定”分别表示；只有正式 NVN/translator 语义定义的未绑定行为才可生成对应结果。

这里有一个必须与通用 GPU accessor 区分的 **NVN driver ABI**，不能把 Maxwell cbuf 编号直接当 NVN uniform 槽：

- **C1 是 shader literal 段，不是当前绑定的 uniform slot 1。** 已支持控制段的 `+0x700/+0x704` 为原代码区内起止位置，参见 [ShaderBake.XShader.C1](../../graphics/tools/shbake/ShaderBake.cs) 与 [Dsh.JobFor](../../graphics/tools/direct/dsh/Dsh.cs)。parser 校验起止/长度并绑定原始身份；越界不答 0。共用 parser 把原始 NVN 头转换为 translator 所需代码表示，graphics 请求仍保留其要求的 Maxwell header，不能把所有 header 一律剥掉。原始 code/control 完整摘要与转换后输入分开保留；仅凭后者不能重建前者的内容键。VertexA/B 若均存在，要保留两份源/literal 并正式实现、验证主仓的双顶点翻译；当前仅接受单 `vs` 的请求不等于已支持 A/B，不能丢弃 A 来伪造成功。native literal 绑定也使用同一字节/范围。
- 已核对 driver 规则中，**graphics bank 3..16 → NVN uniform slot bank-3**。C0/C2 是 driver 生成区，distinct 于 S2A SupportBuffer；计算 UBO 指针来自 C0 的表，不能把 graphics 映射强套到 compute。CB use mask、QueryTextureArrayLengthFromBuffer 和资源 resolver 都用同一 bank→来源表。
- driver 表的源码依据是 [nvn_mtl.m 的表布局及 encode_args](../../graphics/nvn/gfx/nvn/nvn_mtl.m)：C0 的 VS/CS/FS storage 表基址分别 0x110/0x310/0x510，每项 16 字节（guest 地址 64 位、长度 32 位）；CS dispatch XYZ 在 0x200，CS uniform 表在 0x210。C2 combined handles 在 0x20+8×slot，image 在 0x120，separate texture 在 0x168，sampler 在 0x568；重叠区须按已核布局处理。这些是 NVN driver 数据语义，引用 Metal 文件不代表执行 Metal。旧文的 `nvn-driver-tables-v1` 只是设计称呼，不是已存在的独立导出/schema；不为这个名字新增公共 codec ABI。共同语义随 W1 归共享核心，Vulkan 只接中立来源并转换目标绑定。
- C0 的 graphics baseInstance(0x644) 从真实draw参数生成，point limit(0x610) 从NVN/实际backend共同可支持范围生成；**0x640等源码仍标未确立的字段不沿用“填0”**。translator IR 分析列出 C0/C2 的实际读取区间/动态索引；只对codec有完整定义的区间生成数据，跨未知字段或无法界定的动态读返回 MissingFact。禁止以整块zero bank兜底。
- C2查询从当次NVN绑定生成有界driver表，并与pool实际容量/类型核对；间接handle按正式位编码/单位解出texture和sampler，保留pool/generation，不从资源名猜。动态数组需要完整可索引域和匹配descriptor能力，做不到准确Unsupported。
- reflected storage descriptor 的 SbCbSlot/SbCbOffset 先解析上述真实表/guest uniform内的指针与长度，再解析到NVN pool/backing的byte range，绑定对应VkBuffer及offset/range；compute uniform pointer同理。它们是guest地址语义，**不要求Vulkan buffer-device-address**，不把guest指针直接写成VkDeviceAddress。

这些来源约束仍须 C2/C3 的合成字段、GPU 输出和缺字段负例证明。新增布局或改变解释时同步已有 parser/directABI/closure 身份与消费者，不扩大默认兼容范围；本文不能据这些要求宣布 Android 已实现全部 driver 表，也不据此改 Apple 现有策略。`cbufSlot=-1`、`separate=false`、`handle=8+2×slot` 仅用于独立证明的 combined-handle 路径；UBO 间接/separate/image 的规则分别验证，不能外推。

查询依赖记录 method/arguments/value/source，源身份/有效代际由对应快照与资源账本保有，不要求每个 JSON 查询都新增 generation 字段。外来离线/私有条目采纳时核完整身份、依赖和布局；已验证内存程序可凭全部依赖未变的证明复用身份，不要求每笔 draw 重解析 JSON/重哈希。证明不足走完整校验；保守完整状态键可以保留，但不能漏输入或用裸地址/短 key 代替内容身份。

### 4.2 Android 当前 direct ABI 的四 set 与 support buffer

以下布局仅约束当前 Android Vulkan 编译/消费 ABI，不要求 Metal 使用四 set，也不将它变成跨平台 D0 的新枚举。接口若统一传中立反射，Vulkan 仍须忠实消费对应 compiler 布局；改变布局要版本化。

当前 `TargetApi.Vulkan`，SPIR-V 1.3、验证环境 vulkan1.1；目标更新进入 profile/closure。普通顶点输入，vertex-as-compute/Metal vertex pull 未开放；格式需真实支持或已验证的等价转换。四个 set 为 0=uniform（含 support）、1=storage buffer、2=texture/sampler/texel buffer、3=storage image；列出资源类别不代表其每个子类型都已实现。当前 [DirectProgram.Parse](../../graphics/tools/direct/compiler/DirectProgram.cs) 只接受 graphics=`vs+fs` 或 compute=`cs`，单 program 共用一份 allocator，先 VS 后 FS；TCS/TES/GS 不能因序列化器有名字就视为可用。以后增加阶段须正式版本化并确定顺序，不能使用枚举数猜顺序。

allocator 唯一来源是 [DirectGpuAccessor.cs 的 DirectAllocator](../../graphics/tools/direct/compiler/DirectGpuAccessor.cs)。当前从 `ResourceReservationCounts(false,false)` 取 UBO reservation，并校验为 1：set0/binding0 留给 `SupportBuffer.Binding`，guest UBO 从 1 开始，storage/texture/image 各自从 0 开始；各类按翻译调用顺序跨 stage 连续分配，不复用另一 stage 编号。若锁版本增加其他 reservation，要同步 allocator/profile/消费布局，不能据旧文假定已自动处理。每个 texture/image array 占一个 binding，descriptorCount 按真实 count，不能把一个数组只计为一个 descriptor；各 stage、全 pipeline 和 sampler 等实际限制分别核对。

descriptor limit 按当前实际使用数、各 stage 与总和检查；binding 号大不等于 descriptor 数多。需要的 descriptor indexing/nonuniform 能力未启用则不生成假有效程序；首版不靠全部数组标量化伪装支持。`CreateExtraSet=-1` 避免超出保证的四 set；后续额外 set 是新 profile/ABI。

绑定须综合 program 的 `bindings`、阶段 `info.cbuffers/sbuffers/textures/images`、support layout 与已验证源/依赖；没有“资源编号天然等于 NVN 槽”规则。SbCbSlot/SbCbOffset、CbufSlot/HandleIndex/Separate 分别按真实定义解释，不能只用简写 `slot` 覆盖。SPIR-V 校验必须覆盖 descriptor type/set/binding/count/stage 的实际声明；当前 `SpirvReflection` 只抽 decoration 的 set/binding，并不是完整验证器。现有 `ResolvePoolSlots` 仍明确拒绝 cbuf 间接/separate，不能因 profile 中某位为 true 就宣称该路径已闭环。缺完整反射/来源列入 W2/D0 R1，不从 MSL 字符串或猜测补槽。

SupportBuffer **沿用主仓同一结构及 S2ARegistry**：compiler 导出字段 offset/size、owner 和 layout hash，native 据表填写，不手抄偏移。viewport/inverse、BGRA/alpha/depth/draw 参数、点大小、render-scale、宽屏等按真实语义和脏状态更新，已证明未变可复用，不强制每笔重算整块。首版倍率为 1，也只给正式定义为单位倍率的字段填 1，不用整块零/一兜底。layout hash 进入 profile/content 身份；布局语义改变须同步对应 ABI/closure 与消费者。

宽屏/满屏由既有属主维护，本轮不规定另一套 hook 顺序或实现。D0 迁移保留已验证挂点及 compiler/support 布局，Android 不使用 Metal buffer slot13，也不靠拉伸/裁切改变验收；涉及 SupportBuffer/着色器布局的修改须由对应属主同步版本和消费者。

### 4.3 编译、文件格式与首遇调度

Android 本轮的旧格式退出要求见[统一方案 §3.1](fast-generic-v3.md#31-xgs-退出-android-的范围与完成标准)：移除 XGS 生成/加载及诊断兼容入口，不新增 S2AP。下面既有 JSON 契约是本轮生产接点，不以新的二进制封装或扩展名替代完整数据与身份；本次补充不改变跨界 ABI。

离线 CLI 与 NativeAOT UCO 都调用 [DirectShaderCompiler.Compile(byte[] requestUtf8)](../../graphics/tools/direct/compiler/DirectShaderCompiler.cs)，profile/program 在同一请求内；`Compile(snapshot, effectiveProfile)` 只是旧文示意，不是另一个待实现入口。同 accessor、allocator、translator、后处理和反射序列化；缺事实的离线输入保留 coverage gap，运行时从真实状态补，不生成假类型条目。

请求/结果为严格 UTF-8、带版本 JSON，进程内 span 的 length 明确、不要求 NUL，blob 用 base64；协议只走 miss，不进命中热路径。请求 schema=`s2a-direct-compile-v1`，含 session/generation/requestId、directABI/closure/runtimeCompilerABI/sourceParserVersion、profile/program。结果 schema=`s2a-direct-program-v1`，现有层级为 `transport`、`contentHash`、`content`；持久内容内有 `contract`、identity、kind、stages、bindings、supportLayout、dependencies。字段/大小写以 parser/serializer 为准，不能把本文概念列表展开成另一份平面 JSON、给严格 v1 擅加 `access/generation/length` 字段，或序列化 C# 内存结构。缺元数据时按正式版本/消费者共同扩展；未知字段/版本、重复 key、非法编码、非有限浮点及越界拒绝。

当前解析限制以 [DirectProgram.cs](../../graphics/tools/direct/compiler/DirectProgram.cs) 和 `DirectShaderCompiler.MaxRequestBytes` 为准：graphics 恰好 2 stages，compute 恰好 1；每阶段 control/C1 各不超过 64 KiB，所有阶段 code+control+C1 合计不超过 16 MiB，整个请求 JSON 不超过 256 MiB。blob/结果/缓存消费者还有各自上限，不能推断“请求能解析，native 也能接 256 MiB 回复”；例如 [nvn_vk_program.c](../native/nvn/nvn_vk_program.c) 的文件入口仍限制 4 MiB。先检长度/溢出再分配，超预算准确失败，不截断或按全库分配。`.program` 复用已有缓存封套，payload 仍为上述 program JSON，不另造格式。SPIR-V 校验 LE、magic、word 对齐、入口与目标环境；正确性身份用完整 SHA-256。

StageKey/VariantKey/ProgramKey/PipelineKey 是身份职责名，具体规范编码沿[统一方案 §5.3](fast-generic-v3.md#53-身份绑定和存储)及 §11 W2.2 的单一实现，不另手抄算法。session/generation/requestId 只作 transport/本局有效性，不进跨局键；源内容及被编译读取的真实语义决定复用。相同规范输入的离线/现场 SPIR-V、反射和依赖应逐字节一致，但不同 session 的整份 envelope 本来不同；检验持久 content，采纳时核当前 session，不把磁盘旧 transport 当本局身份。路径/耗时不进内容。

沿已有有界需求 worker 按完整 program 身份去重，需求优先；预热默认关闭，不因旧文写“一个预热槽”就再起一根线程。翻译与 driver pipeline 创建是不同任务/计数，pipeline 可在 worker 使用同一 device 创建，输入/对象保活、`VkPipelineCache` 按 Vulkan 外部同步规则保护，worker 不提交 queue。owner 遇 miss 保留当前执行包/恢复点并继续控制轮询，不靠 join 编译阻塞窗口撤销/Stop；同 queue 有依赖的后续 draw/copy/present 不越过，恢复恰好一次。

关键完成顺序：**结果就绪 → owner 核本局 generation/身份/完整布局后发布 → 唤醒需求者 → 后台写 cache**；只有 SPIR-V ready 不等于 pipeline/GPU ready，不让 fsync/rename 挡住发布。查找顺序为已验证内存 → 包内只读库 → 私有缓存 → 现场编译；库 miss、坏条目 reject、编译失败分开处理，准确规则见统一方案 W2.5。缓存写失败不否定正确内存结果；最终翻译/driver 失败结束 direct，禁止占位/丢笔。Stop 取消未开始任务，在途 worker 返回前保活 device/context；驱动调用没有可抢占承诺，迟到结果只能安全丢弃/释放，不得激活旧 generation。

## 5. HLE、VI 与视频

`Switch`/GpuContext 构造与进程登记保留；direct 不启动 **generic 的** shader disk-cache 加载与 GPFIFO graphics loop，自己的离线/私有 program cache 继续启用。#868 的 [DirectServiceRenderer](https://github.com/jhaizhou-ops/S2Arm/blob/642ec4574e5191d59218c30507e5c16dd5c77526/platforms/android/core-runtime/DirectServiceRenderer.cs) 是 HLE 构造用的明确拒绝执行壳：多数 GPU/sync/capability 方法会抛错，不是已经接通 native 的服务适配器。若 HLE 实际需要相应能力/同步/释放操作，须在既有服务接点按同一 native device/完成账本实现和验证，不能忽略异常、恢复旧 DirectRenderer 的空同步方法或再建一个假 renderer；也不能因改走共享核心删掉 HLE 所需上下文。

| 服务路径 | 首版处理 |
|---|---|
| vi 打开显示/建 layer/GetDisplayVsyncEvent | 继续 Ryujinx HLE 的显示对象/事件协议；其 `SurfaceFlinger` 是模拟的 Switch 显示服务，不是 Android 系统同名进程。事件由既有宿主节拍桥推进，不宣称二者一一对应；NVN interval/选帧语义归共享核心，Android 提供节拍源 |
| nvdrv Initialize、nvmap、as-gpu 元数据 | 保留正式服务、内存/句柄管理和检查；“直连不会调用”不能作为成功返回理由 |
| nvdec / vic / Host1x | 保留当前 CPU 解码/转换、SMMU 和同步点；[Host1xContext](../../compat/tree/src/Ryujinx.HLE/HOS/Services/Nv/Host1xContext.cs) 由真实 Synchronization 持有，无需第二 Vulkan device。所有 decoder 写 guest backing 必须走同一写前通知 |
| SurfaceFlinger 视频 BufferQueue 帧 | 在 PostFrameBuffer 完成原有 fence/nvmap/尺寸/crop 解析后、generic Window enqueue 前分流到有界 direct video 入口；按实际 block-linear/format/stride 上传，同一个 native owner 排序/合成/呈现；不能放进无人消费的 generic 队列 |
| /dev/nvhost-gpu 的真实 graphics GPFIFO 提交 | 首版不模拟第二套 graphics GPU；一旦出现明确 Unsupported 并保留故障锁，下次 generic。未来接入属于独立能力，不悄悄启动通用循环 |

**以下视频规则是待实现能力的要求，不是已接通的 ABI 行为**：在上述 #868 快照中，`s2a_direct_video_v1` 只在头中声明，不能据此声称已有 native 定义、HLE 调用者或 `s2a-direct-video-v1` JSON parser。实现前先核接收 main 是否已有等价能力；若仍需接线，producer/consumer/字段单位与错误/所有权一起定义并评审，不照旧文概念表另发一份 JSON 协议。它属于 HLE/视频接缝，不是让 Vulkan 再写 NVN 回放或新增 mtl 转发。

采用 CPU 快照时，沿 HLE BufferQueue/fence 证明 producer 完成、同步旧 GPU 写后复制实际帧字节；metadata 须有 session/window/layer/frame 身份与真实 format/planes/stride/block-linear/crop/transform 来源。接收方返回 0 前取得自有副本，此后不借用 C# 数组或 guest backing；0 只证明已接收，不代表 present/上屏。Pending 不接受帧所有权，已接受帧不能重复排入；释放 HLE 锁后在普通宿主线程等待/重试，Stop 唤醒。guest BufferQueue 归还前完成快照，不留 GPU 读 guest 源的引用。

视频队列必须有明确字节/帧数上限与背压；原设计的 metadata≤64 KiB、pixels≤64 MiB、最多 2 个待执行帧是预算要求，不是已存在实现/支持的声明。首版按一个可见 layer 的真实生产协议安排 NVN/视频，未实现多层合成则准确拒绝，不能吞掉可见层或静默丢帧。沿同一 owner 上传/呈现并遵守 §6 可见性；系统字典/字体/codec 缺项归系统数据/服务，不冒充 shader cache 错误。视频交付仍须真实视频路线单独验收。

## 6. 内存一致性、替页与锁

首版正确性基线选择 **上传/读回 + 现有 s2a_track 原生跟踪器**，host import 暂不作为基线依赖，后续可选能力须另验；不移植 D2R mprotect/fault handler，也不因此禁用 Apple 已有路径。direct 登记现有 touch/drain/backing 消费者，按需定向读回 GPU 修改页；generic 的 NxTrack 不在同一页再登记第二账本。服务 GuestMemory 的写/quiet/untracked/GpuModified 接同一消费者，现有 dispatcher 改道到正常宿主栈；Android 不用 Apple 的保护页数指标代替本端正确性证明。

资源账本需表达对象/内容/backing 身份与代际、byte range、CPU 脏版本、GPU 最后写入/使用及未提交引用；这是语义清单，不是要求再建一份平行资源表。**drain 只在真实依赖需要时执行，不是每条 NVN API/每笔 draw 全量 flush+wait**：CPU 脏变化令重叠内容失效，GPU 写记录真实批次/完成证明并登记读回页；CPU 读/写、替页或复用确实依赖旧 GPU 工作时，才按范围提交/等完成、invalidate/回写。信号上下文只改道，不能等待、调用 C#/JNI/Vulkan 或分配；保留现有 dispatcher 正常宿主栈路径，不能以历史“只拦写”实现证明 CPU 读已正确。

CPU 与 GPU 重叠写不能简单最后一次整页 memcpy：先完成实际有序的旧 GPU 写回，再允许 CPU 写；已捕获 CPU 脏字节与 GPU 输出按原跟踪器 precise batch 处理，防止覆盖 CPU 新字节。非 coherent 的 flush/invalidate 对齐实际 atom 与 allocation 边界，GPU完成和可见性是两件事。

参与 GPU 跟踪的范围有不受控长期虚拟内存 alias 时，沿 registry 的保守拒绝路径报告不支持；内部 `EOPNOTSUPP` 与 direct/D0 错误域须显式转换。它不等于拒绝 NVN 纹理/缓冲对合法同 backing 的多个 view，后者仍共享范围版本、处理重叠读写/保活。普通 backing 替换用既有 `s2a_track_backing_begin/end` 同线程同范围事务，先排空/写回源和目标相关使用、失效缓存，再提交映射/generation，失败回滚后 end。W3 只对已证明全空宿主页的 0x2C 增页操作免停世界；保留 writer 串行/epoch/账本锁，不取消活页 unmap/替换的停稳与 GPU 依赖证明，也不从图形层另造 writer gate。

锁顺序固定：短 registry/对象锁只取引用与快照 → 全部释放 → 发 owner 控制请求/等待 → 重取锁核对 generation → 提交结果。不得持 VM、tracking、descriptor/object、queue 锁进入编译、文件 IO 或读回等待；owner 不同步调用 guest/HLE；readback 内部写回用显式重入标记和原有 untracked 通路，不能再次排队等自己。等待路径 guest 放核，队列唤醒与停止使用同一条件变量/控制事件，禁止靠自旋推进。

## 7. WSI、停止与 IME

### 7.1 首版明确要求 present fence

**首版正式 direct 的既定 WSI 基线要求实际启用 `VK_EXT_swapchain_maintenance1` 和 `swapchainMaintenance1` feature**；instance 启用 VK_KHR_surface、VK_KHR_android_surface、VK_KHR_get_surface_capabilities2、VK_EXT_surface_maintenance1，device 启用 VK_KHR_swapchain/VK_EXT_swapchain_maintenance1 并核 feature=true。缺项时 AUTO 在 commit 前可 generic，显式 direct 准确失败。现行验收不覆盖无扩展 Reacquire 退休路径；KHR 等价入口不能仅换字符串就宣称本端已支持，须核依赖/feature/调用与同一退休测试后开放，不再造伪装接口。这是本项目兼容范围选择，不是 Vulkan1.1 保证具备，也不是 Vulkan 要求每帧 CPU 等 present fence。

理由：基础 acquire/reacquire 能证明某些旧 present 依赖，但在无后续帧/Surface 销毁时不能保证拿到最后一笔的退休证明。不能靠加 deadline、queue idle 或清掉异常解决用户日志里的 `No presentation retirement proof`。扩展允许为 present 附加资源可回收 fence，并提供释放未呈现 acquired image 的操作；**这不是实际 scanout 时间的证明**。[Khronos 扩展依赖与功能](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_swapchain_maintenance1.html)、[present fence 语义](https://docs.vulkan.org/refpages/latest/refpages/source/VkSwapchainPresentFenceInfoKHR.html)。

复用现有 native owner/退休模块，与 [RetirementLedger](../../graphics/vulkan/wsi/RetirementLedger.cs) 共用事实/反例向量；不是另造第二账本，也不把 C# Vk/TextureView 对象跨界。首版使用 EnabledPresentFence，以 session、window/device/swapchain generation、image index 及**本次操作序号**区分复用；相同 image index 不代表同一次 acquire/present。acquire semaphore 按实际在途操作，render-finished 按 image 使用，不能只凭 CPU 帧槽已完成就复用。

guest Fence/Finish、GPU 提交完成、present 资源退休、实际显示时间是不同证据。单 queue 次序还需正确 barrier/layout/访问可见性，不能把“同队列”当全部同步。D0 v2 对 FAILED 采用首失败段 F 之后终止后续段的合同：1 成功、2 失败、3 尝试时 wait(2)/wait(3) 准确失败，完成值不能越过 F；失败回调不做成功回写，零超时查询不隐式提交。v2 另保留 Metal 的非终态 GPU_FAULT/隔离策略，Android 必须核真实执行/结果及本端失败协议，不能把它当忽略 shader/driver 错误的通行证；不另造 fence ABI。

撤销/停止先拒绝新 acquire/present。已成功 acquire 的操作须证明 acquire 信号被安全消费、device 使用已完，再对未 present 图调用 `vkReleaseSwapchainImagesEXT`；不能直接丢掉已获 image/semaphore。D0 v2 规定 acquire 失败不授予 drawable，成功者只能 present 或 release 交回一次，present 无论返回何值都消耗该 token；这不代表内部 present/GPU/lease 义务已完成。已 present 的观察对应 present fence，失败/timeout 仍按状态保留 backend 内部责任。OUTDATED 可按 generation 协议重建，REVOKED 等新窗口，ORDER 不重试，不能统一当 DeviceLost 或成功。[释放 image 的限制](https://docs.vulkan.org/refpages/latest/refpages/source/vkReleaseSwapchainImagesKHR.html)。依赖证明后，按实际引用顺序销毁 framebuffers/views/swapchain、Surface，释放 take 的 window ref，最后 `released(generation)`，才允许 lease ACK；DeviceLost 走失败/安全清理，不伪造正常退休。

present fence 不代表实际显示；GPU 原始 timestamp 也不天然属于 host monotonic，换算绝对时刻须有[时钟域校准](https://docs.vulkan.org/refpages/latest/refpages/source/vkGetCalibratedTimestampsKHR.html)及误差证明。未测/不支持显示时间应记 unavailable，不能用 CPU present 返回时刻、等待时长或 0 代填；不在本文新增 D0 时间字段。

`poll` 的主动等待最多一个 10 ms 控制片；这不是对驱动调用返回时间的保证。Acquire 用有限超时且不阻塞 UI。driver 调用、GPU 或 present fence 真正超出外壳 detach deadline 时，记录 blockers、保持对象和 lease，按既有会话失败退出；不延长 UI 等待来冒充已回收。故障记录使下一局 generic，但不宣称 generic 的原有退休问题因此已解决。

### 7.2 统一 Stop 与系统输入法

Stop 沿已有单一协调者：关新 guest 图形入口 → **UI broker stop/撤销对话框并唤醒等待者** → 请求 guest/编译停止 → 持续推进必要的控制/提交/读回/present 收尾 → guest/worker/writer 真正退出 → 核 native 退休及 managed Cleanup 结果 → 安全 Destroy/归还 lease → 正常会话才清 attempt。各步遵守实际依赖，不要求已停止的 owner 继续执行游戏绘制，也不能先关掉唯一可完成收尾的执行通路。UI/GPU owner 不 join guest；request_stop 返回、blockers=0、native Stopped、managed Stopped 均不能单独充当全部收尾证明。失败保首错/attempt，已安全资源可清理，未知使用仍保活，不发布正常完成。

IME 沿用已合入的 `software-keyboard` v1，保留 UI 主线程每100ms取请求、JNI byte[]、EditText/当前系统输入法，不再新增 JNI worker。补齐如下确定规则：

- broker 初始化绑定 runtime 的非零真实 session；Java UUID 按原壳层约定传到 native，与 session 建一次映射，Activity attach 返回该 session 下的 generation。prepare 前的 Activity 只能登记可用状态，不能创建 session=1 的游戏 broker。take/complete 校验 session+generation+request ID；停局不复用 ID。
- dialog 只有一个完成标记；确认/取消/Back/生命周期回调经同一主线程 helper 发布一次。native 拒绝完成时不能仍按 accepted 关框：区分会话撤销与真实传输错误并记录，真实错误结束会话。Java 请求/回复 codec 用严格 UTF-8 decoder/encoder（错误 REPORT），不能依赖默认替换字符掩盖非法字节或代理对。
- 用 TextWatcher + composing SpanWatcher 观察文本与 composing 的添加/变更/移除；组字中禁用确认，移除 composing span 后即使文字不变也立即重新校验。保持正在组字的文本/选区，不在 watcher 中 setText 裁剪；长度在正式提交时按 HLE约束最终检查。
- HOME/Activity替换先 detach/revoke 再 dismiss；键盘模态期间清虚拟手柄按住状态并暂停其输入，恢复后不重放旧按键。IME focus/insets 只更新真实 ScreenConfig，不能单独标 direct 失败。
- inline **首版明确不支持**，保持正式 Unsupported，不能用一次 modal 伪装；需要 inline 的内容会准确失败/下局 generic，但 generic 当前也不保证 inline 可用。后续扩展必须实现正式 InputConnection 持续文本、选区及 applet 协议。

首款 modal 的两轨中文/确认/取消/停止通过是 DV5 前置；不用 inline 的首款可以验收，但发布说明必须写清 inline 不支持。详见[输入法方案](system-ime-plan.md)。

## 8. 包、更新、持久缓存与故障锁

采用 artifact v1 已有扩展机制：`requiredFeatures: ["org.s2arm.graphics.v1"]` 与同名 extension，extension 只含 `manifest` 相对路径、SHA-256 和 bytes，指向 `shaders/vulkan/direct/graphics.v1.json`。schema、Java/native/Python producer/consumer、旧版本拒绝测试配套交付；是否已接入按统一方案的新候选证据判断，不沿用本文 10-25 的“消费者不认识”作为当前结论。旧 v1 无 feature/descriptor 继续 generic，未知 required feature 拒绝，不静默猜路径。

`graphics.v1.json` 的 schema=`s2a-graphics-v1`，身份含 titleId/gameContentRoot/moduleSetDigest、frontend=`nvn`、backend=`vulkan-direct`、directABI/translatorClosure/sourceParserVersion/runtimeCompilerABI；profiles 列离线 profileHash，files 列精确相对路径/size/full SHA-256。字段以 #693 的统一 producer/validator 为准，不把 caps 全塞进 descriptor，不列 manifest 自身或 artifact/index/current。允许 coverage 为空，现场 compiler ABI 仍须受支持。结构/摘要/requiredFeature 无效的包由导入/校验器拒绝，不能靠改 generic 吞掉损坏；已验证包在 commit 前遇 direct 能力不支持时，AUTO 可 generic，显式 direct 准确失败。离线未列 live profile 只算 miss。

**10-29 确认的 profiles/closure 合同**（[#693 维护方回复](https://github.com/jhaizhou-ops/S2Arm/pull/693#issuecomment-6488500080)，producer/validator 由该 PR 属主落实，W2 不重复实现）：

- `files` 为空时，`profiles` 必须为 `[]`；非空时 profiles 为 1–8 项，各文件路径中的 profile 都已列出，每个 profile 至少有一个产物。不兼容“空库 + 占位 profile”的旧包，必须重出。
- 设备合成的 effective profile 未在列表里是离线库 miss，继续私有缓存/现场编译，不是 provider 准入失败；旧 engine 分支若仍存在须安全拒绝零 profile，不能读 `[0]`。这项安全处理不授权继续扩展旧 engine。
- 空 profiles 不跳过建 device 后的 live implementationKey 检查/attempt；commit 后异常终止，下次 AUTO 仍须 generic。
- translatorClosure 由 producer、CLI、设备编译器读取同一仓库来源；W2 的源码闭包推导/构建绑定规则见统一方案 §11.5。不得按游戏手写，不能只因请求/profile/descriptor 三者填了相同任意字符串就认为与实际编译器匹配。

保留现有两层身份而不改v1定义：[ShaderPackLayout.GameContentRoot](../../graphics/vulkan/cache/ShaderPackLayout.cs) 按原index顺序过滤全部 `shaders/` 行计算 gameContentRoot；shader和graphics manifest均放在该目录下，manifest仅绑定这个稳定gameContentRoot与模块集合，不包含最终revisionRoot。随后按 [make_pack.write_artifact](../tools/make_pack.py) / [attach_shaders](../tools/attach_shaders.py) 规则把graphics manifest及产物的文件行加入最终index，**artifact.contentRoot = sha256-<最终index hash>**，current.revisionDir仍是revisions/<artifact.contentRoot>。artifact的extension再绑定graphics manifest hash；artifact/index/current都不列入自身输入，避免循环。

shader/ABI更新重建最终index、artifact和新的不可变revision；不得在旧revision里原地改shader。安装器验证全部新增/变化文件并写current最后，旧revision活跃时不删除。gameContentRoot用于程序来源/跨局内容键，artifact.contentRoot用于激活与可追溯性，二者在run report分列；不因为前者未变就覆盖后者。

包内 `shaders/vulkan/direct/<directABI>/<profileHash>/` 只读；应用 cache 下 direct 域可清理，不影响游戏输入/存档。attempt/failure 放持久 stateDir 的 `graphics/direct/<implementationKey>/`，不放 cacheRoot。implementationKey 沿 [graphics.c](../native/direct/graphics.c) 的唯一算法：按 gameContentRoot、moduleSetDigest、十进制 directABI、translatorClosure、effectiveProfileHash 顺序，各字段含 NUL 分隔后 SHA-256，输出 64 小写 hex；不能把旧文的“+”当无分隔拼接，不能与 profileHash/contentRoot 的带前缀文本混用。稳定存档身份不随图形版本变化。

attempt 的 schema/字段/phase 沿 [attempt.h](../native/direct/attempt.h)，commit 前 temp→fsync(file)→rename→fsync(parent)。只在会话无错且全部 Stop/lease 退休完成后持久清除；异常/首错不清。selection 可能同时写 descriptor 预检别名和真实 live key，正常收局必须清本次实际写入的整组键；空 profiles 也必须保护 live key。最多 8 个离线 profile 与额外 live key 不能因固定槽满而漏记/漏清，不能据单键成功声称全部清锁。遗留 attempt/failure 下次 AUTO generic，只说明上次未正常结束，不虚称已定位 shader 崩溃。

锁持续到玩家明确重试或实现/内容身份变化后的受控重试，旧身份失败不擅删。手动 generic 优先；手动 direct 也过基本准入，不能静默降级。commit 前故障锁写失败时，AUTO 仅在候选/部分事务已按协议回滚后 generic，显式 direct 准确失败；commit 后存储失败保留 attempt 并错误结束。没有画面不自动等于故障：保留 guest progress、compile/submit/present 时间线，玩家可在下次启动选择 generic；不得在已运行本局切模式。

## 9. 交付顺序、验收与回滚

以下 C/DV 仅保留验收类别与历史证据对应，不是第二套任务、排期或发布许可。当前交付/依赖只在统一方案 §11，产品达标见其 §9；不能用“C7 通过”豁免 #968 的 W2/W3/W6 要求或 main 回归。先跑变更所需无游戏数据检查，再按实际范围验证 GPU/设备；不要求每次文档修改重跑整套游戏，也不以文档检查代替运行验证。

| 合同 / DV | 必须实现的交付与测法 | 合格的可观察结果 |
|---|---|---|
| C0 / DV0 | 核 services request80、runtime request160、direct table64、各自不同 status24 及 offset/版本/错误域；native ELF 参数/回调实调，生成 API/record 覆盖表 | 双端同布局，误用 status/mode/版本准确拒绝；xstack 返回值与手算一致，不以 host LP64 编译代替 ARM64 |
| C1 / DV1 | Prepare/attempt/commit 故障，v1generic/v2direct、重复 start、空 profiles/未列 live profile、全部 attempt 别名清理；记录 device/queue/worker 计数 | relocation 前冻结；AUTO precommit 可 generic，显式 direct 不静默变轨；commit 后失败下次 AUTO generic，单 owner/消费者不变 |
| C2 / DV2 | CLI/AOT 同 compiler 的 VS/FS/CS、纹理/附件变体、64 B→8 handles 等长度单位、GetCode/C1 越界与缺事实、JSON/预算、support/完整 descriptor 布局 | 持久 content/SPIR-V/反射/依赖规范结果一致，transport 分开；接口全有来源，错误不发布，首用唤醒先于写盘 |
| C3 / DV3 | 真 GPU clear/draw/compute/copy/readback，双pool同slot、program/texture同地址重建、GPU写间接参数、stride/整数附件与所需高级stage专项 | 独立手算像素/缓冲结果正确，验证层无新增错误；旧generation不能命中；未支持语义准确失败 |
| C4 / DV4 | 真 GPU CPU读写交错、服务写、backing成功/失败回滚、alias拒绝、读回重入；慢编译时窗口撤销/Stop，无后续帧退休，present不确定/device lost | CPU见实际GPU输出、CPU新字节不被覆盖；未知完成不ACK/不释放；启用present fence后无帧撤销可退休；故障保留根因/lease，下一局generic |
| C5 / DV1/4 | 实际 HLE Switch启动，vi/nvdrv元数据、Host1x输出、视频帧→direct上屏/同步、unexpected GPFIFO负例 | 服务/音频/输入/vi继续工作；片头实际可见；无第二device，无无人消费视频队列，无空renderer吞调用 |
| C6 / DV-UI | 两轨真机系统IME中文组字/候选/选区/emoji/长度、确认/取消、HOME/Activity替换/Stop；另跑单虚拟核 | 候选只移除span也更新确认；旧session/代际回复拒绝；Stop先唤醒再join，无按键粘连；inline保持准确Unsupported |
| C7 / DV5 | 固定合法游戏/存档/路线，按 §11 W2.8 的基线→新 staging 漏一键→次局复用；故障/SIGKILL/磁盘失败/升级/旧 requiredFeature | 基线 0 现编、漏项 1、次局 0，真实 adoption/compile 计数支持；不原地删安装 revision。音视频/输入/存档/属主宽屏结果保留；故障下次 AUTO generic |
| C8 / DV6/7 | 本轮按 §11 W6.5 跑帧率/稳定性/相关能耗；后续产品再扩不同内容/多 GPU，Vulkan/GL 前端和 OHOS 各按属主范围验收 | 端到端帧率按工单目标，不从单阶段推算；能耗 ≥3 局中位并标热/充电，首遇/稳态分开；未测不能外推全游戏/其他平台 |

测试按本次变更路由选取，统一方案规定的正式交付证据不能省略。W1 纯抽取与 bug 修复分开，Apple 同后端前后等价、Android 接线前后等价与跨后端独立期望分别验证；不把 Android 的失败/缓存策略强加给 Apple。失败修真实来源/所有权/版本，不靠跳 draw、假同步、成功桩或忽略异常过关。

开发回滚在新进程选择 generic；发布回滚须用匹配 APK/模块/资源身份的已验证激活事务，不把“旧 revision 仍在”当 Android 必然允许任意 APK 降级。ABI/支持布局/查询语义变更同步对应版本、closure、缓存身份和新 revision，拒绝不兼容条目；普通文档审订不擅升源码版本。保留存档与 Apple/generic 默认功能。

验证状态只在统一方案 §11 记录，本文不再保留“全部未完成”等过时总判。原设计的 LP64 布局检查只证明当时尺寸/offset，不证明当前 ARM64 双端、GPU 或游戏通过。设备不满足声明能力或语义未实现时准确拒绝/Unsupported，按提交阶段走既有故障协议，不猜默认值或伪造完成。

### 设备请求目录转宿主请求集（W2）

`python3 android/tools/direct_batch.py import-requests --capture <落盘目录> --out <新请求集目录>`
读取当前层 `*-<64hex>.compile-request.json`，要求前缀与请求 `requestId` 相同，
复用 `direct_library.validate_request`，仅接受一致的 directABI / translatorClosure /
profileHash / sourceParserVersion。无关日志不读取；坏匹配文件、软链、重复身份、
混合 cohort 或已存在输出明确失败。请求原字节保留，按身份排序，最后写
`programs.v1.json` 完成标记；这只是请求目录，不是运行时库。
随后以该清单调用既有 `direct_batch.py build --programs ...`，再 `verify`。

身份直接取设备文件名，**不是 JSON 的 SHA-256**，导入器也不能单靠 JSON 重算
规范输入身份或证明这些文件确由设备观察生成。采集方须保留设备 / APK / effective
profile 来源，输入仅使用可信本地采集。主库编译/装库继续核其原有身份与 profile /
closure 合同。本工具不填缺失图形事实，不把静态成员关系变成完整请求，不处理私有
query recipe，也不改变 ABI。合成身份的宿主测试只证明传递与装库，不是手机首遇
零现编证据。真实请求、生成库和原始错误日志可能包含游戏数据，不能上传公共仓库。
