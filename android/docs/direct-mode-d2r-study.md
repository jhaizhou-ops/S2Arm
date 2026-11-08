# Android 直连：d2r-mobile 代码借鉴审计与实施细则

审计日期：2026-10-26。产品目标、模式选择和着色器生产契约以[快速通用模式](fast-generic-v3.md)为准。本文规定如何借鉴算法、适配当前消费者和验证结果，不另立产品方案或后端。下文 `xbg_*` 是上游源码定位；本仓实现位于 `android/native/nvn/`，按用途命名，来源、版本与许可证单独保留，不把上游命名或旧引擎依赖当作实施要求。旧导入目录已在 2026-10-30 删除（来源与删除记录见 §9），从未参与当前 `nvn_vk` 产品构建。

源码基线：

- d2r-mobile：`445bf05e600dabb735f89d932469396f6a15ea1a`，本机 `<d2r-mobile 工作副本>`。以下 `D2R/` 指该仓库根，`engine/` 指其中 `dm/gfx/vulkan/engine/`。
- S2Arm：`android/direct-mode-d2r@4b2d5bb057d7f9c8ff9c9edf29eaaee329f2f11e`。“当前缺口”指该基线，实施前核对后续提交，已修的不重做。
- R17 管线缓存另于同日复核至 `d699d42b`（含 `6c4a86cd` 对象缓存和批量录制），并检查当时工作区的后续改动；该节明确区分现状、风险与待实现方案，不把代码提交视为已验收。
- 此前导入本仓的 `graphics/third_party/d2r_vulkan_engine`（2026-10-30 已删除，见 §9）由 `SOURCE.json` 标注的来源是旧版 `e3756f8942b40eba6c851e881828a5b1bda17fd6`；它没有包含外层 `dm/android/vulkan_present.cpp`，不能代表完整 Android 实现。
- 本轮只改本文，不导入运行时代码、游戏 shader/资源、密钥、存档或设备转储。参考测试通过不代表 S2Arm 真机通过。

## 1. 实施 AI 必须先读的边界

### 1.1 固定生产链

```text
普通游戏输入
  → 共享 NVN 前端、S2Arm 命令记录和真实对象/状态快照
  → 现有统一 DirectShaderCompiler（离线和现场共用）
  → s2a-direct-program-v1：SPIR-V + 完整反射/依赖/身份
  → 当前 Android Vulkan 执行器
  → 当前会话唯一的 device/queue 与窗口租约
  → 正确像素和真实上屏
```

当前接点：`mtl_vk_shim → mtl_vk_adapter → nvn_vk_session / vk_record / nvn_vk_first_draw / texcache / swapchain`。`mtl_*` 名字不表示调用 Metal，不为换名重写功能。通用兜底按主方案在下次进程选择，不在本局切换后端。

### 1.2 XGS 与旧 shader 链：明确禁止

以下内容不进入新的 Android 生产路径，也不以“临时诊断兼容”恢复：

| 禁止内容 | 不允许的接法 |
|---|---|
| `.xgs` / XGS1 头、parser、writer | 不生成、不加载、不改后缀迁移、不扩展名探测、不失败后回退 |
| `xbg_shader_header`、`xbg_shader_binding`、`XBG_SOURCE_*` 旧程序 ABI | 不复制类型和编号到新接口，不把统一反射适配成旧单 set 协议 |
| 旧 stage 顺序、固定 binding 偏移、固定 support buffer 大小 | 不当作 NVN 枚举或当前编译器契约，数字相同不证明语义相同 |
| `<control 短键>.xgs` loader、旧 `Shader` 加载对象 | 不接其 `shader_directory`，短 control 键不作为完整内容身份 |
| `dmsh_vk.py` / `pack_game_shaders.py` 等旧游戏 shader 产物流程 | 不接当前打包/现场编译链，不导入游戏 shader 表、PC 配对反射或默认事实答案 |
| 旧 shader/module 缓存、warm seed/list 及其加载入口 | 不读取旧文件，不沿用旧身份；可另行适配真实配方预热算法，但只接当前 program 契约 |
| `xbg_game_initialize()` / `dm_android_vk_initialize()` 整套初始化 | 不连回旧引擎，不借其创建第二 device/queue，不恢复 XGS 初始化依赖 |
| 换名后的旧协议 | 不新建 S2AP 或私有程序包，继续使用现有 `s2a-direct-program-v1` |

可以研究同文件中的 Vulkan 算法；移植依赖闭包必须与上表断开。不能因为函数和 XGS loader 在同文件，就把整文件/旧头文件一起链接。

禁止范围是新的 Android 生产依赖，不是全仓字符串删除：其他平台仍使用的共用文件、旧研究记录和来源清单不据此删除。旧产物只在现有私有隔离流程中处理，不改写安装 revision、存档或游戏资源。

后端自己生成的通用 masked-clear shader 不等于 XGS 游戏 shader 库。只有来源/生成方法可追溯、授权明确、用途通用且接口独立时才可提取；不得用游戏 shader 或固定 shader key 冒充工具 shader。

### 1.3 复用分类

| 类别 | 实施方式 |
|---|---|
| A：可提取函数 | 保持算法，最小适配头文件、类型和错误出口；保留来源及测试 |
| B：可适配机制 | 保留本仓 owner、对象 ABI、编译反射和缓存身份，迁移明确的状态/生命周期规则 |
| C：后续优化 | 正确性及实际热点已证实后，单项默认关闭验证 |
| D：不采用 | XGS 链、游戏专用数据/政策、跳 draw、空成功、第二套 owner、未证明的语义改写 |

每轮只选一条已触发链路或一个可独立验收的通用模块。本文是复用依据，不要求 AI 在两小时内实现整张清单。

## 2. 为什么已有参考仍然重复踩坑

1. **导入引擎漏了平台层。** d2r 的 `dm/android/vulkan_present.cpp::create_swap()` 在旧导入对应版本就检查 Identity 并使用 Identity `preTransform`；新 swapchain 最初用了 `currentTransform`。只看 engine 目录找不到这段。
2. **退出 XGS 时，没有逐项保留执行语义。** 视口、采样器、深度平面、行距、掩码清理与 XGS 无关，本应提取适配，不能先简化后等待游戏暴露。
3. **“已采用”与真实消费没有分清。** 文件已入仓、helper 绿、APK 链接成功不证明当前 draw 调用了它，必须追到真实生产调用点。
4. **纯色 present 看不出旋转。** 方向、比例、裁剪必须用非对称图和真实屏幕验证。
5. **单款覆盖不等于完整 NVN。** d2r 有通用机制，也有单款逻辑、实验默认值和覆盖空缺；不能整库照搬。

特别纠正：本轮没有在 d2r Vulkan 引擎找到任意 texture/view swizzle 的完整消费。`Image::view()` 的固定格式 alpha 处理不能代替它。此项补充参考本仓 iOS 和 Ryujinx，见 §4.4。

## 3. 复用清单与真实接点

优先级依据实际首错和调用，不能把“已发现缺口”全部认定为当前画面根因。修复是否推进，以同场景结果判断，不按日志或 draw 数量计进度。

| 项 | D2R 入口 | 类别 | 当前接点/顺序 |
|---|---|---|---|
| R01 上屏/窗口变化 | `dm/android/vulkan_present.cpp`：create_swap/present | B | swapchain/window lease；先验 `23c5d21b` 后状态 |
| R02 视口/坐标 | `engine/xbg_nvn.cpp`：xbg_nvn_viewport | A/B | first_draw 和真实 origin/depth 状态；防重复翻转 |
| R03 严格采样器 | `engine/xbg_sampler.cpp/.h` | A | sampler/device enabled caps；已有近似语义需纠正 |
| R04 图像/view | Image::view；另参考 iOS/Ryujinx | B | 注册表、texcache、描述符/附件；swizzle 修复后补完整性 |
| R05 pitch/copy | nvn_copy_pitch.h、xbg_blit.cpp | A | upload、COPY_B2T/T2B/T2T |
| R06 深度平面 | xbg_depth.c/.h | A | 深度上传/读回；usage 通过不等于内容正确 |
| R07 格式/压缩 | xbg_bc_policy.h、xbg_texture.c | A/B | 格式用途、解码和拷贝；按触发格式实施 |
| R08 附件/target/MSAA | xbg_framebuffer.c、xbg_stages.cpp | A/B | framebuffer/pipeline 与阶段适配 |
| R09 清理命令 | clear_attachment、MaskedClear、xbg_clear.cpp | A/B | record/pass；已知 CLEAR_DS 缺口 |
| R10 固定/动态状态 | draw、stencil、attachments | B | 状态快照 → 实际 pipeline/dynamic call |
| R11 绘制参数 | xbg_draw_plan.c、xbg_vertex.c、draw | A/B | 属性/索引/实例/间接绘制 |
| R12 内容/别名 | get_image_slow、invalidate_cpu_range、writeback policy | A/B | backing/texcache/CPU 写跟踪 |
| R13 描述符来源 | descriptors、RegisteredTexture、pool_key | B | 当前 program 完整反射；不迁旧 ABI |
| R14 同步/退休 | Slot/Commands、retire_slot、completion_wait | B | vk_track/vk_sync；覆盖上传/读回/present 分支 |
| R15 写回/event/query | resolve_pending、preflight_cpu_reads、GPU queries | B | CPU 可见边界、guest event/report |
| R16 命令存储 | xbg_command_clone.c、前端快照规则 | A/B | 当前 ABI decoder 与资源引用时点 |
| R17 缓存/预热 | pipeline_key/memo、cache/warm 机制 | B/C | 当前完整 program 身份；先正确后热点 |
| R18 诊断/对照 | capture_image/pass、provenance_image、raster facts | B | 真实 GPU 输入、前后 RT、同帧截图 |
| R19 性能/驱动 | arena/snapshot/resident cache、adreno policy | C | 仅已证实热点，不随功能修复默认打开 |
| R20 生命周期/IME | lifecycle_dispatch.h、text_input_jni.c、Activity | A/B | 当前 HostKeyboard/broker/lease，不重做服务 |

上述 `xbg_game.cpp` 中的机制只能逐函数适配，不能整文件引入。各项的最小验收见下文。

## 4. 逐项适配细则

### 4.1 R01：Android 上屏方向、比例与窗口恢复

**来源**：`D2R/dm/android/vulkan_present.cpp::create_swap/present`，以及 `vulkan_present.h` 的 UI/渲染线程约定。

可借鉴 Identity 支持检查、transform 选择、窗口 generation、crop 校验、等比居中、黑边清理、blit 能力检查、失效窗口重建。acquire 等待阶段和 swapchain 初次写入/布局转换也要配套研究。

**接点**：[nvn_vk_swapchain.c](../native/nvn/nvn_vk_swapchain.c)、[nvn_vk_session.c](../native/nvn/nvn_vk_session.c) 与现有窗口租约。审计期间 `23c5d21b` 已改 Identity、发布窗口坐标和等比居中；先验证后续状态，不重复实施。

适配规则：

1. 同帧比较真实源图和屏幕，源图正确时保持 shader/UBO/游戏投影不变。
2. transform、窗口尺寸、extent、crop、目标区域采用同一坐标契约。优先参考本仓 [AndroidWindow.cs](../../graphics/vulkan/wsi/AndroidWindow.cs) 的 Identity + Android 合成器旋转方案，核对能力和合法尺寸，不能只改单个常量。
3. 按有效 crop 等比缩放居中，黑边清黑；越界 crop 明确拒绝，不悄悄当整图。
4. d2r `present_native` 会用 `ANativeWindow_setBuffersGeometry` 改缓冲尺寸，它是额外显示缩放优化，不随方向修复搬入，避免改写本仓租约/触控坐标来源。
5. d2r 的无限等窗口、queue-idle 和同步 present 返回条件不替代本仓 Stop/detach deadline/present retirement 证明。UI 只发布状态，无后续帧也必须能撤销。
6. 不搬其 initialize、设备选择和队列创建；只使用当前 owner。

**验收**：非对称四角/TOP/LEFT、真实同帧源图与截图、不同窗口比例、应用支持的横屏方向、后台恢复、Surface 失效重建、无新帧 Stop、触控对应。纯色 present 不通过本项。

iOS `nvn_mtl.m::present_encode/present_enqueue` 可参考 crop/origin/居中及随帧快照；Ryujinx `Window.cs::Present` 可参考 Vulkan 源/目标区域。NVN crop 是 x/y/w/h，Ryujinx 是边界坐标，不能直接复制四个数字；两者均不替代 Android transform 契约。

### 4.2 R02：视口、原点与深度

**来源**：`D2R/dm/gfx/vulkan/engine/xbg_nvn.cpp::xbg_nvn_viewport`。

该函数已做有限值/宽高/深度检查，明确 shader 链 `YNegateEnabled=false` 前提下使用 `{x, y+h, w, -h, near, far}`。可提取纯转换，但必须核对当前编译请求、Position、NVN origin、viewport 和 present 各自负责哪一次转换。

不能在 shader/viewport/present 重复翻转，不能只关 cull 或改 frontFace 掩盖错误；前后模板语义与方向一同验证。`vp_seen/sc_seen` 区分未设置与有效零值，显式空 scissor 不扩大为整目标。多 viewport/swizzle/depth mode 尚未支持时明确失败，不能仅保存记录后忽略。

**验收**：不同 y/h、非对称图、正反面三角形、不同深度模式/near/far、显式空 scissor。检查实际位置与剔除结果，不只检查结构数值。

### 4.3 R03：严格采样器转换

**来源**：`engine/xbg_sampler.cpp/.h::xbg_sampler_from_nvn`，由 d2r 的真实 `sampler()` 调用。纯状态转换，不调用 Vulkan，适合提取。

**当前缺口**：[nvn_vk_sampler.c](../native/nvn/nvn_vk_sampler.c) 对部分 mirror/legacy clamp 近似映射、非标准边框色退回黑色，未完整验证 enabled anisotropy/LOD limits。这些不是通用等价实现。

适配规则：

- 从真实 samp_par 构造输入；限制取当前 device 已启用 feature 和实际 limits，supported 不等于 enabled。
- 保留精确 mirror-clamp-to-edge 及扩展门槛。需额外 shader 语义的 legacy clamp 明确 Unsupported。
- 保留无 mip minification 的 LOD 处理、min/mag 区别、有限值/范围校验。
- 整数/浮点边框按实际 view 格式区分；自定义色无实现就失败，不替换颜色。
- 缓存键比较规范化有效字段；保留在途 sampler 引用，不靠 padding 或固定小容量证明生命周期。

**验收**：各 wrap 边界、min≠mag、LOD/mip、disabled anisotropy、非标准边框、整数 view；非法输入不部分修改输出；GPU 边缘采样与独立预期对照。

### 4.4 R04：底层图像与采样/附件 view 分离

**d2r 可借鉴**：`Image::view()` 的 mip/layer 范围、格式/类型/usage、view 缓存、深度采样与附件 aspect 区分。任意 NVN swizzle 的完整实现不在这份 Vulkan 代码中。

**补充来源**：[iOS nvn_mtl.m](../../graphics/nvn/gfx/nvn/nvn_mtl.m) 的 texture/view 覆盖关系及 view key；[Ryujinx TextureView.cs](../../compat/tree/src/Ryujinx.Graphics.Vulkan/TextureView.cs) 的采样 `_imageView`、附件 `_imageViewDraw`、identity view 和共享 TextureStorage。

**当前缺口**：`43471709` 已消费 texture swizzle，但注册的 view_t 未完整进入 lookup；同一 tex->view 同时用于采样/framebuffer；swizzle 进入整图命中条件，变化可能销毁重建图像。因此不能标“完整 view 支持”。

适配规则：

1. lookup 携带现有 t/v/has_view。view 显式 swizzle 优先，否则继承 texture，未设置才恒等。
2. backing/lifetime 保存 VkImage；view key 包含有效格式/类型/mip/layer/aspect/component mapping/用途。
3. 采样和附件/storage 用适合各自用途的 view，不能把某用途的恒等限制推广为所有深度采样都忽略 swizzle。
4. 只变 view 不重建 image、不上传旧 CPU 数据。异格式 view 必须满足创建条件或有保内容升级，否则拒绝。
5. 依 [NVN 枚举](../../graphics/nvn/gfx/nvn/include/nvn.h) 显式转换 ZERO/ONE/R/G/B/A，不能强转；无效 6/7 不静默回退。不能失败后换 base view/零纹理/其他槽。

**验收**：R8_UNORM 的 0/128/255 经 A=R 后 alpha≈0/0.502/1；view 覆盖 texture；同图多 mip/layer/映射不串；先渲染再换 view 内容保持；附件与默认映射回归；真实字形修前实心块、修后字形/透明背景对照。

### 4.5 R05：上传、读回、行距和层距

**来源**：`D2R/dm/gfx/nvn/nvn_copy_pitch.h`；`engine/xbg_blit.cpp/.h::xbg_copy_rows/xbg_copy_rows_write`；BC 块 pitch helper。

guest row/image stride 是字节跨度；bufferRowLength 是 texel 数，不能固定除以 4。guest 存储范围、有效像素字节、紧排 staging 是三个值。

保留当前 nvn_tex_layout/nvn_deswizzle，先核输入再采用 planner；每 mip/layer/3D slice 按真实尺寸和块尺寸规划。紧排 staging 可用 bufferRowLength=0，guest 读取仍按 stride；双向 copy 只改有效字节，保留行/层 padding。访问指针前检查负值、乘加溢出、池范围和 region，压缩格式按 block 计算。

**验收**：不同 bpp、奇数宽、非紧排行/层间隙、非整块 BC 尺寸、mip/array/3D、双向 copy 的 padding 哨兵、非法/溢出。t_copy_pitch 与 native_bc_policy 调真实 helper；copy_stride_test 的模型不能替代 GPU copy。

### 4.6 R06：深度/模板打包和分平面

**来源**：`engine/xbg_depth.c/.h::xbg_depth_format_info/extract/merge`；`append_depth_planes()` 实际消费。

Tegra/NVN Z24S8 的 packed 字节与 Vulkan D24 depth 拷贝表示不同；depth/stencil 拷贝应各自规划。正确 attachment usage 不证明深度值已正确。

**当前缺口**：上传路径尚未完整消费拆平面/合并规则，可能把组合 depth/stencil aspect 交给普通 buffer-image copy；纯 stencil 也不能统一加 depth aspect。

使用当前 NVN 枚举适配 helper，先解排布再拆平面，各自 copy；读回/局部写时保留未修改平面和 padding，D32F+stencil 单独核布局。精确格式无支持且无完整替代时明确拒绝。

**验收**：手写 D24S8 packed/depth/stencil 预期字节、只改一平面、多行多层 padding、D16/D32F/S8、GPU 清理→读回→合并→再采样。无 device lost 不等于此项通过。

### 4.7 R07：格式、BC/ASTC 与标量类型

**来源**：xbg_bc_policy.h、xbg_texture.c/.h、xbg_blit.cpp、随附 decoder/参考测试及各自许可证。

按实际格式、usage、过滤、samples 和 enabled feature 决定原生压缩/解码，保留 signed、sRGB、mip/layer、region。映射表有 VkFormat 不代表所有用途都支持。

当前 nvn_vk_format.c 把 UI2F/I2F 映射为 UINT/SINT 存储，注释说明取样转换未接；不能因此宣称采样完整支持。顶点类别、shader 标量类型、storage image 和采样转换分别验证。

d2r native-BC helper 的 ASTC 目标排除和 marker 默认值服务其转码链，不能直接当通用策略。复用能力/范围算法，按本仓实际输入决定目标政策；第三方 bcdec 等分别保留许可证。

**验收**：线性/sRGB、signed BC4/5、透明块、多 mip/layer、局部更新、标量类型负例；原生/参考解码对拍并明确精度范围。

### 4.8 R08：附件、target、MSAA 和阶段

**来源**：xbg_framebuffer.c/.h::xbg_framebuffer_plan、create_pass、xbg_stages.cpp::xbg_graphics_stages。

提取选定 mip/slice 后的范围、samples 一致性、layered 拒绝、颜色 location 和 depth-only 阶段要求，输入改用当前快照/反射。

已核对风险：

- 当前 image/render-pass 多固定 1 sample，pipeline 却可能取 2/4/8。必须一致，未实现时在非法 Vulkan 调用前拒绝。
- 主要 draw 消费者只接一个颜色附件及 VS/FS，不能证明 MRT、无 FS 深度绘制或其他阶段完成。
- texcache 把 target 5/6 称作 cube；当前 NVN 头实际 5/6 为 multisample，cube/cube-array 是 8/9。按枚举名适配，不延续错误裸数字。
- d2r helper 的数组是 VS/TCS/TES/GS/FS；当前 NVN 是 VS/FS/GS/TCS/TES/CS。不能把旧索引或 `1<<i` 当当前阶段身份。

**验收**：不同 mip/layer/附件尺寸、混合 samples 拒绝、颜色 location 空洞、depth-only、MSAA resolve、target 负例；不补虚假 FS/占位附件。

### 4.9 R09：清理是有顺序的命令

**来源**：clear_attachment、MaskedClear、xbg_clear.cpp/.h。掩码、裁剪和 preserve 判定可提取，render pass 按本仓适配。

当前 OP_CLEAR_DS 仍 pending 到下一笔 draw，消费者又用合并布尔值决定 depth/stencil loadOp，不能算完整清理语义。

清理作用于当时目标/view，与 copy/read/present 保持顺序；没有后续 draw 也生效。深度/模板分别处理，保留模板值和位掩码、scissor、其他 aspect/mip/layer 内容。部分 stencil mask 不能全清，可参考精确写掩码的 masked clear；合成清理 draw 不算游戏遮挡查询。

**验收**：清 A→绑 B→draw；清后无 draw；清后 copy/read；连续清不同目标；只清模板保留 depth；部分位、局部 scissor。不能只测试“第二笔不再重复清理”。

### 4.10 R10：固定/动态状态与默认值

**来源**：draw、stencil、attachments、XbgPipelineDrawState 的状态分类。默认值依当前 NVN/实际初始化核对，不把旧结构列表当权威答案。

当前 decoder 记录 OP_STENCIL，消费者仍固定 compare/write mask=0xff、ref=0；blend constant、depth bias、primitive restart、rasterizer discard、render condition 等也必须追到消费点。保存字段后 break 不等于支持。

逐项建立“记录字段→快照→pipeline/dynamic call”，保留前后面和逐附件状态。未实现准确报错，不默认 COPY/关闭测试/三角形 topology 来跨过。

**验收**：单状态改变有独立预期像素，front/back ref/mask、blend constant、写掩码、restart、discard、pass 切换后状态保持；一项通过不写成全部状态完成。

### 4.11 R11：顶点、索引、实例和间接绘制

**来源**：xbg_draw_plan.c/.h、xbg_vertex.c/.h 和 draw。纯 planner 可提取；xbg_2d_vertices_from_nvn 是特定 2D 接口，不代替所有 VS 取数。

按实际 location/stream/offset/stride/format/class/divisor 提取，按真实索引与有符号 baseVertex 计算，保留 first/baseInstance；零 count/instances 不强制变成一次。间接参数由 GPU 写入时，CPU 解析前解决正确来源。

当前快照 base_vertex 为无符号再强转，实际 indexed 调用 firstInstance 为 0；应从记录到调用保留语义并验证范围，不根据 `%u` 日志猜测。u8 索引扩展要保留范围和 restart 语义。

**验收**：负 baseVertex、非零 first/firstInstance、u8/u16/u32、多 stream、实例属性、归一化整数/整数接口、零实例、间接 stride/溢出。缓冲头几个顶点不能代替实际索引顶点。

### 4.12 R12：GPU 内容、别名与 CPU 写跟踪

**来源**：get_image_slow、invalidate_cpu_range、for_images_overlapping、xbg_writeback_policy.h::xbg_image_after_cpu_access、nvn_pool_flags_registry.h。

当前 gpu_written 只限制 LRU；同址不同 serial/格式/尺寸/swizzle 仍可能 release 后上传旧 CPU 数据。对象 finalize 与 CPU 内容失效不能共用“backing 已过期”的判断。

适配规则：

1. 区分对象、backing/lifetime、内容版本、view；同一有效 backing 的兼容对象可共享 GPU 内容。
2. 地址相同不等于生命周期相同。pool 释放重建、范围重叠、别名写、view/descriptor 变化联动失效。
3. 完整 CPU 覆盖可接管最新内容；部分写先读回/合并或明确拒绝，不丢整图。
4. 写标记覆盖真实 draw/clear/copy/resolve/storage/compute producer，不能未完成就对 CPU 发布。
5. 同步可能淘汰缓存时，先复制描述，等待后重新 lookup，不使用旧引用。
6. 接本仓 fault/tracking owner，不安装第二套 SIGSEGV handler；未跟踪内存有保守正确路径。

不直接复制 d2r 裸 memcmp descriptor 的 alias 判断当完整证明；有效字段、generation、范围和生命周期均要核对。

**验收**：RT 写→新对象别名采样、同址重分配、部分 CPU 写、pool finalize/reinit、缓存压力、同步中旧对象删除再 lookup。CPU helper 测试之外还需真实 GPU 链。

### 4.13 R13：完整描述符来源

**来源**：descriptors、RegisteredTexture revision、pool_key、命中缓存时重查资源/内容。只借机制，不迁 xbg_shader_binding、旧 source kind 或单 set 模型。

统一 program 的 stage/set/binding/element/slot/source/读写用途逐项解析为当前 NVN 状态。不同 pool 的同 ID 不串；原地注册变化使 descriptor/view memo 失效。SSBO range/offset/writable、storage image aspect/format/usage、独立 sampler、数组长度不能丢；当前固定 descriptorCount=1 等子集不算完整支持。

UBO 几个成员吻合只能降低那次上传错误的嫌疑。guestUBO[3] 不保证 NVN slot 3，按编译器/前端契约转换，不试槽。C1 用真实源快照，不能恢复固定 support/C1 大小的旧 ABI 假设。

**验收**：VS/FS 同槽不同值、多 pool、注册更新、数组不同资源、非零 offset、不同 set、GPU 写 SSBO 后读；缺项/类型冲突/越界拒绝。旧单 set 用例不能证明当前四 set 生产契约。

### 4.14 R14：提交、屏障与资源退休

**来源**：Slot/Commands/retire_slot/submit_slots 的引用保留、xbg_completion_wait.h 的总 deadline/短锁通知。优先接本仓 [vk_track](../native/direct/vk_track.h)，不再造 completion owner。

当前 draw 超时保留不代表所有分支安全：texcache upload 忽略 submit/wait 结果后释放资源，部分 present/dump 等待失败后仍释放。所有已提交分支都要入完成账本。

区分未提交、pending、执行失败与 present 尚未退休；cmd/staging/descriptor/view/pipeline 等保留至完成证明，超时不发布完成。GENERAL 不代替访问屏障，GPU 等完不自动解决 CPU 镜像/flush/invalidate/alias。acquire 等待阶段与布局转换、present 信号配套。

queue 外部同步、总等待预算、Stop/窗口 pump 一起设计，不持 UI/guest 全局锁等 GPU/编译，不每次重置超时。S2Arm lease/present 证明优先于 d2r 的 queue-idle 策略，不能退回旧释放方式。

**验收**：submit failure、timeout、device lost、present failure、窗口撤销；创建/退休/销毁计数对应，无在途销毁、假 ACK；无新帧可 Stop。completion helper 的发布者仍须接真实生产完成。

### 4.15 R15：写回、事件、时间戳与遮挡查询

**来源**：resolve_pending、preflight_cpu_reads、timestamp_query、query/report 退休、event WRITE/ADD 顺序。

CPU 消费前完成相关 producer 写回；先 preflight 再取可能失效的引用。先正确，再优化为只同步相关范围；不能先关闭 preflight。

当前 OP_REPORT_COUNTER 用 CLOCK_MONOTONIC 写 8 字节却称 GPU timestamp。d2r 用真实 query、timestampValidBits/timestampPeriod 和 NVNcounterData 布局/单位；按本仓定义适配，CPU 单调时钟不是等价结果。

fence=0/event 立即发布只在相关 GPU 工作及 CPU 可见写回均已完成时成立；异步、延后写回或遗漏 wait 检查会破坏前提。writeback-skip 仅后写完整覆盖、CPU 未观察、pool/alias 已证明时可用；partial/未知池/复用地址不省略，不继承 d2r 实验默认值。

**验收**：GPU WRITE/ADD→CPU 读写、wrap、event 重建、报告结构哨兵、reset 顺序、timestamp 单位/有效位；samples-passed 用真实 query。缺失功能报 Unsupported，不填成功值。

### 4.16 R16：命令记录存储和 deferred 参数

**来源**：xbg_command_clone.c 的 CALL/JUMP 遍历、可用范围回调、深度/数量上界。

只提取算法，header/opcode/payload 用当前 S2Arm 定义。clone 命令存储不等于复制资源数据；deferred 读取时点保持原语义，不能把所有 guest 指针变为录制时快照。

ABI 探针已显示同名编号/布局不同，raw command 不进入旧 decoder。OP_COUNT_+N 私有扩展逐项映射，不按碰巧相同数字互通。

**验收**：源记录内存回收覆盖、嵌套 CALL/JUMP、坏长度/循环、回调重入、deferred range 提交前改变；测试真实前端产物。

### 4.17 R17：管线身份、驱动缓存和预热

本节规定所有游戏共用的机制，不按暗黑 shader key、游戏名、地址或场景另写路径。这里的“预制”是设备提前创建稍后会用到的真实管线；桌面离线编译 SPIR-V、设备创建 VkPipeline、保存驱动缓存是不同步骤。

#### 4.17.1 当前实现复核：先补正确性，再扩预建

复核入口：[nvn_vk_draw.c](../native/nvn/nvn_vk_draw.c)、[nvn_vk_first_draw.c](../native/nvn/nvn_vk_first_draw.c)、[nvn_vk_session.c](../native/nvn/nvn_vk_session.c)。以下为上述补充审计快照；实施前再次检查最新代码。

| 已看到的代码 | 判断与必须调整的边界 |
|---|---|
| `fd_prog_get()` 的 64 槽 parsed-program 缓存只比较 requestId | `nvk_program_compile()` 的 requestId 只拼各阶段 control 短键，附件类型、纹理查询事实、profile 等不在其中。同源 shader 的不同编译结果可能同 ID；不能据此跳过新 program 的解析/校验 |
| `fd_pipe_key()` 把 requestId、部分 NVN 状态和目标格式做 64 位 FNV | 缺完整 program 内容身份，命中只比 hash、不比键正文；原始对象切片也不适合稳定序列化。改为从实际管线创建描述生成完整键 |
| `g_pipeline_cache` 由空 initialData 懒创建 | 这是本进程的驱动缓存，目前没有读取/原子保存文件，不能称为跨启动预制缓存 |
| `g_pipe_cache` 有 256 槽，缓存 VkPipeline/layout/set layouts | 已有对象复用，但均为静态全局；未见与本局 device/session generation 对应的清理入口，函数末尾 session/generation 仍未使用。旧设备句柄不能进入重建后的会话 |
| LRU 满时立即 `vkDestroyPipeline` | `d699d42b` 批量录制把 draw 命令留待 flush（队列容量 1024），旧管线可能仍被已录制命令引用；即使尚未 submit，也不能销毁后继续提交这些命令。缓存条目要由命令包持引用，完成证明之后才退休 |
| 命中判断位于 shader module、set layouts、pipeline layout、render pass 创建之后 | 命中仍有大量可省的创建。先得到完整逻辑描述并查缓存，miss 才创建相应对象；不能为了提早命中漏掉真实状态 |

已确认的是上述缓存契约缺口，尚未证明它们就是当前游戏加载停滞的根因。不要因此重新改 UBO、纹理或 shader 语义。

`nvn_vk_pipeline.c` 的 `nvn_vk_pipeline_get()` 仍是 C2/NVKP 探针消费者，不能因为名字包含 pipeline/cache 就让真实游戏绕回该文件加载器。通用缓存接当前 program 内存消费者和当前 session；可整理模块，但不增加第二套程序格式、后端或 device owner。

#### 4.17.2 iOS 与 d2r：分别借什么

| 参考代码 | 已核对的机制 | 在 Android 的适配 |
|---|---|---|
| [iOS NVN/Metal](../../graphics/nvn/gfx/nvn/nvn_mtl.m)：`pso_key_fill/pso_get_` | 根据实际 shader 与 Metal 管线状态查对象缓存，miss 才创建；成功后记录真实配方 | 借完整描述查找和“观察→记录”的顺序；Vulkan 的固定状态集合单独定义，不能照抄 Metal 的键字段 |
| 同文件 `warm_start/warm_worker/warm_claim` | 随包 `pso_manifest.tsv` 与本机 `pso_user.tsv` 提供种子和已观察条目；后台创建后交给真实绘制缓存，WarmItem 持有 shader/object | 借“随包种子 + 本机增量 + 实际消费”，使用当前 program 内容引用；本局对象由当前 owner 持有 |
| [iOS stable-key helper](../../graphics/nvn/gfx/nvn/nvn_pso_skey.h) | 记录前把 runtime shader/function 指针与持久化身份分开 | 借分离规则；该 helper 仍复制 C struct/旧 shader key，其 TSV/hex ABI 不作为通用磁盘格式 |
| [Metal 共用基座](../../graphics/metal/gal_core.m)：`gal_pso_job_wait`；[针对性测试](../../graphics/metal/tests/t_psowait.m) | 需要的后台作业尚未开始时，等待方可认领执行；避免排在无关积压后，双引用防止提前释放 | 借单作业认领、队列优先级和引用寿命；Metal4 链接版/特化管线能力不据此承诺给 Vulkan 1.1 |
| 同基座与 [gal_be.h](../../graphics/metal/gal_be.h) | Metal4 Archive、Metal3 BinaryArchive 是各自后端的二进制归档 | 借“后端私有归档加速创建”的分层；它们不是 VkPipelineCache 文件，也不证明直连 `pso_get_` 走了该基座入口 |
| `D2R/engine/xbg_pipeline_key.h` | 将 Vk 创建描述逐字段序列化，比较完整字节；未知扩展不缓存 | 借键生成和保守旁路。其 layout helper 只支持一个 set，module ID hook 接旧身份，必须改为当前四 set/完整 program，不能原样连入 |
| `D2R/engine/xbg_game.cpp`：`load_pipeline_cache/write_pipeline_cache` | 读取设备相容的驱动数据、临时文件写入后 rename，单独保存线程 | 借校验、原子替换和 join；不照搬未成功保存就把 unsaved 清零、以创建耗时 ≥2 ms 推断驱动编译的策略 |
| 同文件 `warm::record/start/take/shutdown`、`pipeline_lookup` | 观察真实配方、去重、后台创建、draw 取走预建结果、取消并 join | 只借流程。旧 module loader、`.seed`/warm list 内容及编号不采用；`async_request/async_skippable` 首遇跳 draw 明确禁止 |

这些代码说明闭环可以实施，不证明参考实现没有其他问题。尤其 `xbg_pipeline_memo.h` 的 generation 用例只覆盖该 helper；d2r 生产 `xbg_game.cpp` 另有 `PipeMemoKey`。本仓要直接验证自己的真实查找、提交、淘汰和关闭路径。

#### 4.17.3 统一模型：三类数据，一个创建入口

| 数据 | 内容和用途 | 可跨启动/设备的范围 |
|---|---|---|
| 内存对象缓存 | 已解析的 Program、ShaderModule、DescriptorSetLayout、PipelineLayout、兼容 pass 描述和 VkPipeline；分别缓存不可变对象 | VkHandle 只属于创建它的 device；当前实现按 session/device generation 管理，不能直接落盘 |
| 管线配方 | 引用已验证 program 的完整内容身份，保存实际有效固定状态、布局及目标兼容描述；描述“要创建什么” | 可持久化、可随资源包携带；重新验证内容、backend/profile/ABI/翻译闭包后才能在另一设备重建 |
| 驱动二进制缓存 | `vkGetPipelineCacheData` 返回的不透明字节，交回 `vkCreatePipelineCache` | 手机本机私有缓存；按设备/驱动/UUID 兼容域隔离，不作为跨设备 shader 库，不当作离线桌面机器码交付 |

配方是当前缓存封套内的元数据，不替换 `s2a-direct-program-v1`，不新建 shader 包、stage/binding ABI 或旧格式兼容层。iOS 与 Android 可共用身份、观察和调度原则，实际配方声明 backend/profile，Metal/Vulkan 创建描述及驱动二进制分别由各后端解释。

```text
真实 Draw 快照 → 统一编译结果 / 兼容离线 program
             → 校验并建立不可变 ProgramRef
             → 生成当前 backend 的完整 PipelineDesc
             → 同一个 get_or_create(desc, ProgramRef, owner)
                    ├─ Ready 命中：取得引用，录制真实 draw
                    └─ miss：合并同键作业，正确创建，发布 Ready，继续该 draw
             → 记录本局确实使用的完整配方（去重、异步保存）

下次启动：兼容随包配方 + 本机配方
        → 校验 program/依赖/profile → 有界预建
        → 同一个 get_or_create / 同一个 Ready 缓存
驱动 cache 只传给上述创建调用，不另走一条绘制链
```

没有配方、配方过期或预建未完成都允许当前 draw 按需创建；没有完整事实的条目 Deferred，不能枚举假答案、静态猜全部组合或要求全库预热完才能启动。shader 数量不等于管线数量，同一 program 可对应多种 blend、附件格式、MSAA、顶点输入组合。

#### 4.17.4 身份和键：必须明确到字段

入口在统一编译结果首次接收时验证完整契约、contentHash 和本局 transport 身份，建立自有、只读、可引用的 ProgramRef；热 draw 传该引用，不逐笔重复解析/hash 大 JSON。requestId 保留追踪用途，不是缓存身份。跨局保存规范化 content/源与编译事实依赖，session/generation/requestId 只用于本局结果接收和迟到拒绝。

ProgramRef 预先形成稳定的 ProgramVariantKey：以已验证 contentHash 为核心，仅补入当前 content 尚未覆盖的必要兼容身份。下表列的是必须被身份覆盖的语义，不要求把 content 内已有字段再复制、再 hash 一套；SPIR-V 摘要、布局和 profile 的校验/索引在接收时完成，管线键引用已确认的结果。

完整键从**实际传给 Vk 创建调用的有效描述**生成，含版本和数组长度；字段暂未支持就明确 Unsupported 或保留正确创建慢路径，不因缓存而删语义。

| 键部分 | 必须包括 |
|---|---|
| 程序/变体 | 已验证的 contentHash；各 stage 的实际 SPIR-V SHA256、entry point、specialization constants（若启用）；目标环境、enabled profile、direct/compiler/parser ABI、翻译闭包及 support layout 的身份 |
| Descriptor/Pipeline layout | 当前四 set 的序号及每个 binding 的 type/count/stageFlags、实际使用的 binding flags/immutable sampler 定义（若支持）、push constant ranges、相关创建 flags；数组需保序或按已证明等价的规则规范化 |
| 顶点和图元 | 实际启用的 location/format/offset/binding、stream stride/inputRate/divisor、topology、primitive restart、tessellation patch 状态（若支持） |
| 目标兼容性 | 所有有效颜色格式/数量、深度模板格式、samples、subpass/viewMask 等已支持信息；render-pass 路径使用正确兼容描述，dynamic rendering 路径使用对应格式描述 |
| 固定状态 | rasterizer discard、polygon/cull/front face、depth bias/clamp、line width；depth test/write/compare/bounds；前后 stencil；每个 RT 的 blend/写掩码、logicOp；multisample/sample mask/alpha-to-coverage 等实际启用状态 |
| 动态状态声明 | `VkDynamicState` 集合、viewport/scissor 数量及有关扩展声明；值只有在本条管线真正声明为动态且 draw 发出相应 Set 命令时才不入键 |
| 生命周期域 | 内存对象按 owner/device generation 隔离；portable 配方不写本局 generation，读取后在新 owner 下实例化；driver blob 另加下一节兼容域 |

运行时 UBO/SSBO 字节、资源地址、texture/VkImage 句柄、索引/顶点 buffer 地址、draw count、动态 viewport/scissor 数值不自动进入管线键。纹理事实若影响 shader 翻译，其变化必须先产生不同的编译依赖/结果身份，不能拿“资源数据不进 pipeline key”当理由复用旧 SPIR-V。

render-pass 兼容规范化尚未证明正确时，先保守记录完整创建描述，宁可多建，不按“同一张图”或“颜色格式相同”错误复用。clear color、load/store 等是否可从管线兼容键排除，与 clear 是否正确执行是两件事，不因缓存合并/跳过清理命令。

使用无指针、无 padding、固定字节序的显式序列化；hash 只做桶索引，命中还比较完整键字节。未知 pNext/specialization/布局扩展如果能由正确路径创建但未编码进键，旁路缓存；原执行器也不支持时明确失败，不能空成功。磁盘不保存 C struct、内存地址、VkHandle 或 control 短键充当内容身份。

#### 4.17.5 本机 driver cache 的加载与保存

1. **归属与命名空间**：归当前 Vulkan owner 管理；复用现有私有缓存根，按 mode/backend/内容域/ABI/profile/翻译闭包，再按 vendorID/deviceID/driverVersion/pipelineCacheUUID 隔离。记录实现实际使用的 API/feature profile；APK hash 不代替兼容身份，也不因每次重打 APK 就必定丢弃相容缓存。
2. **加载**：先检查封套版本、文件尺寸上界、长度/摘要，再按小端解析 Vulkan header。version-one 检查 headerSize=32、版本、vendorID/deviceID/UUID。坏/不兼容缓存可隔离并以空 cache 重建；`vkCreatePipelineCache` 因初始数据失败时只有限重试空数据，设备丢失等真实错误上报，不永久重试。
3. **创建**：所有本局管线通过同一个 factory 使用该 cache。默认单个预建 worker；共享 cache 的创建/快照采用明确的线程同步规则，不持队列/guest/窗口锁做慢编译或磁盘 I/O。若以后采用 externally-synchronized flag 或多个 worker，补足能力检查和所有修改入口的同步；不直接把 d2r 的三线程数搬过来。
4. **快照**：按有界间隔/新增批量或正常 Stop 请求保存，不逐 draw 序列化。协调创建和快照，处理两次 `vkGetPipelineCacheData` 间尺寸变化与 `VK_INCOMPLETE`；第一版要求取得完整成功快照，按实际上限有限重试，失败保留 dirty 和旧文件。
5. **原子保存**：自有字节交 I/O worker，临时文件完整写入并关闭、必要的持久化处理后原子 rename。保存 captured dirty generation；成功才推进 saved generation，保存期间新创建仍留 dirty。不能先清零 unsaved、也不能用“创建不足 2 ms”认定已命中驱动缓存。I/O 失败不阻止已创建管线执行。
6. **关闭**：停止接收任务，取消未开始的预建，等待已认领创建和保存线程退出；持有有效 device 至所有使用它的任务结束。缓存条目与命令包按完成证明退休，最后销毁 VkPipelineCache 和 device。Stop/窗口撤销可被处理；不在 UI 回调里无限等待全库预建。

规范依据：[缓存头字段/字节序](https://docs.vulkan.org/refpages/latest/refpages/source/VkPipelineCacheHeaderVersionOne.html)、[读取与 VK_INCOMPLETE](https://docs.vulkan.org/refpages/latest/refpages/source/vkGetPipelineCacheData.html)、[cache 修改的同步标志](https://docs.vulkan.org/refpages/latest/refpages/source/VkPipelineCacheCreateFlagBits.html)。上述 envelope/driverVersion/原子保存/dirty-generation 是本项目在规范接口之上的策略，不冒称 Vulkan 自动提供。

#### 4.17.6 配方观察、预建与淘汰的完整顺序

**观察和出包**：在真实支持的 program/管线创建成功并被 draw 使用后，记录去重配方，保存完整内容引用及首次使用顺序/频次等调度元数据。增量记录留应用私有缓存，只有经当前编译链验证、依赖相容且无 guest 指针的配方才可随既有资源打包流程作为种子。离线导入/导出只处理当前元数据，不读取 d2r/iOS 旧 warm 文件。游戏 program/SPIR-V、配方及诊断证据均不随代码进入仓库/PR。

**启动预建**：合并相容的随包与本机条目，先校验去重；已有 program 可提前加载，事实完整的热门/早用配方优先。有界队列、内存预算、可取消、可观测进度；默认一个 worker 并允许按实测让步，不把长库编译、等待所有条目或联网设为首启门槛。不同设备重新创建自己的 VkPipeline，设备不支持的配方记录具体原因，不假报 Ready。

**单作业状态**：`Queued → Compiling → Ready / Failed / Cancelled`；无完整事实的 Deferred 条目不进创建队列。同完整键只允许一个生产者，draw 优先提升自己的任务；还未开始可原子认领在需求 worker 执行，已开始则等待同一结果，不再重复建。若没有后台任务，miss 直接用同一 factory 正确创建。等待期间让 owner 继续处理 Stop/撤销，不握住 worker/队列所需的锁；不在 owner 消息循环上为抢任务同步卡死。临时资源不足、取消和永久 Unsupported 分开，不把一次失败永久缓存成全部会话的结论。

**发布与真实消费**：任务持有不可变 ProgramRef、布局及 owner 引用，产物发布前检查仍为同一 device/session generation；迟到对象按原 owner 安全销毁，不注入新会话。Ready 直接进入正常对象缓存，真实 draw 取得同一 PipelineRef 及对应 layout；不能只把 driver cache 烧热，却在 draw 另建一遍并宣称“预制命中”。当前必需的 draw 等正确结果，绝不 skip、返回空管线成功或用占位 shader 顶替。

**录制与退休**：录制命令包就持 PipelineRef，提交后转为对应 fence/submit 序号的在途引用；命令包被安全丢弃或完成证明到达才释放。LRU 只移除查找入口并标退休，实际销毁等待录制/创建/在途引用归零；缓存满且全被引用时有界扩容或等待退休，不抢先销毁。fence timeout 不意味着工作完成，更不能清引用后继续复用 fence/缓存。依赖的 layout/set-layout 对象按同一所有权规则处理，worker 正在创建时 shader modules 也不能被回收。

[Vulkan 要求引用 pipeline 的已提交命令全部完成后才能销毁](https://docs.vulkan.org/refpages/latest/refpages/source/vkDestroyPipeline.html)。本方案进一步保留尚未提交命令的引用，避免销毁导致这些命令失效。仅凭“前一笔等过 fence”或上一轮同步实现的假设不足以支持本轮批量录制。

#### 4.17.7 分三步交付，逐步进入生产调用

| 顺序 | 本轮只完成的闭环 | 退出条件 |
|---|---|---|
| A：正确对象缓存 | 修 requestId 误用；建完整 descriptor/key 与 ProgramRef；实际 draw 先查后建；接当前 owner、引用与退休 | 相同 requestId/不同结果不会错命中；相同完整键真实复用；批量录制/LRU/重启不使用已销毁对象 |
| B：跨启动驱动缓存 | 在 A 的同一 factory 增加兼容加载、快照、原子保存和关闭 join | 真机第二次启动确实加载本机保存数据；损坏/版本变化可正确重建；保存失败不丢 dirty |
| C：观察配方并预建 | 在 A/B 增加本机记录、既有出包种子、单 worker/需求认领、Ready 供真实 draw 使用 | 重启后的预建对象被实际消费；相同场景有减少首遇创建/卡顿的证据；无配方仍完整执行 |

这不是要求另一位 AI 同时改全部三步。当前应先完成 A，B/C 独立验收；批处理和上传优化另按 R14/R19 保持自己的证据，不能借管线缓存改动重写整个渲染器。尚未支持的 NVN 功能按实际触发补齐，不把所有新功能写进此次缓存任务。

#### 4.17.8 必须验证什么，怎样判定有用

| 验证 | 必须看到的结果 |
|---|---|
| 相同 requestId、不同 SPIR-V/反射/profile/编译事实 | 不返回旧 parsed program 或旧管线；直接调用本仓生产入口验证 |
| 相同完整键重复 draw | 同一缓存对象被使用，创建计数不增；命中路径不重复建 shader module/set layouts/pipeline layout；资源内容仍按真实 draw 更新 |
| 固定字段逐项变化、动态值变化 | blend/depth/stencil/MRT/samples/顶点输入/布局等影响描述的变化 miss；真正动态的 viewport/scissor 值变化可 hit，并发出正确动态命令 |
| 强制 hash 冲突 | 完整字节比较阻止不同配方错命中，不靠概率声明不会发生 |
| owner 重建、同地址复用、LRU 超容量、录制未提交、fence 超时、迟到 worker | 不跨代使用句柄、不销毁仍被引用的对象；Stop 收齐任务，错误可传播 |
| cache 截断/超长/坏摘要/错设备或 UUID、写入失败、快照时继续新增 | 不接受不兼容数据；空 cache 慢路径仍正确；保存代际只在成功后确认，新数据不丢 |
| 相同键同时预建与需求创建、后台队列被占 | 只创建一次，draw 能认领尚未开始的任务；不受无关后台积压无限阻塞；取消不假报 Ready |
| warm 开/关、冷启/二启、无种子/过期种子 | 正确像素和绘制顺序一致，不跳 draw；真实 warm-object 命中、创建耗时和首屏/新场景帧时间分别记录 |

计数至少分 `program_hit/miss`、`pipeline_object_hit/miss/create`、`warm_queued/ready/used/failed/stale`、driver-cache load/save 字节与相容域、按需等待时间。driver-cache 命中只有设备支持且正确启用创建反馈时才报告其原生口径，否则写“未知”，不以耗时阈值冒充。

性能用同 APK/资源/场景、相同诊断开关对照冷启动和第二次启动，记录首画面、可操作时间、帧时间 P95/P99、CPU 录制/GPU/等待与功耗；draw/s 不是 FPS。审计样本在新增批量录制前约 `1614 µs/draw`，其中 pipe 约 `42 µs`、record 约 `834 µs`、wait 约 `648 µs`，且开启了读回/日志；它提示稳态主要耗时不只在 pipeline，不能承诺“加预制缓存即可 60 FPS”。该样本不作为正式基准或新工作区性能验收。

### 4.18 R18：可复核的图像和逐笔诊断

**来源**：capture_image/pass/data、provenance_image、xbg_spirv_raster.cpp 与测试。

显式诊断时有界抓一帧/一条链：实际 GPU 输入、stage/set/binding/element、backing/serial/generation、view、最近 writer/upload/rebuild、前后 RT 与差异 bbox。raw 标注格式/尺寸/pitch/子资源，不以开局上传样本替代真实绑定。

五点不变不证明无覆盖；Position 初始化块不证明最终值；阈值 0/大浮点不证明错；存在 OpKill 不证明全 kill。raster facts 只识别严格 Position 直拷模式，未知返回未知，不是 VS 执行器；提取时适配阶段类型，不能保留 XGS stage 协议。

读回不能重复 Begin、越界比较、不等完成即释放；未知格式拒绝。修改 shader 副作用/原子的诊断不作为正常像素真值。

**验收**：APK/revision、固定命令、实际输入、首次错误边界、修前/修后、限制完整。游戏图像/raw/shader dump 留私有证据域，不入仓或 PR。

### 4.19 R19：正确性之后的性能经验

可研究按 slot 退休的 arena/snapshot、脏页 generation、resident texel、完整 pipeline/layout/descriptor memo、CPU/GPU/present 分项测量。fast path 保留正确慢路径，按内容/对象/pool/slot/alias 失效，不能把没观察到写当没有写。

xbg_adreno_policy.h 记录 740/750 对某些 SPIR-V 改写编译接受却运行 fault。本轮测试仅验证机型和开关，不证明设备安全。warp32、quad/helper、LDC/temp、NaN、亮度/LUT 等不随接线默认启用；需统一编译器中的独立证明、版本/profile 身份和目标 GPU 回归。禁止删 interlock。

不复制 CPU 绑核、强制帧率、marker 默认、亮度/分辨率、固定 shader key 热点、游戏 UI 特例。不沿用 d2r 单款功率/FPS 作为本仓指标。

### 4.20 R20：Android 生命周期、JNI、IME 和输入

**来源**：D2R/dm/android/lifecycle_dispatch.h、text_input_jni.c、DmActivity.java、touch_android.c 及 tests。

可借：UI 只发布状态、宿主线程串行；请求 ID/generation、字符串自有副本、不持锁跨 JNI、原始 pthread 栈 worker、标准 UTF-8/UTF-16、中文 composing、取消/旋转/Stop once 回复、失焦释放 touch。

本仓已有 [HostKeyboard.java](../app/src/main/java/org/s2arm/android/HostKeyboard.java) 和 applet/broker，优先查接线，不新增第二输入框/系统服务。d2r TextInputRules 的角色名/金币政策、SDK 名称拦截、地址表不搬；限制来自真实请求。

状态合并不能丢旧 lease 的退休义务。guest memory/SVC 崩溃沿当前 fault 证据定位，不搬 d2r 固定地址布局、signal handler 或成功桩。4b2d5bb0 的退出路径是独立待查项，不能凭 exit(134) 归因 GPU/shader。

打包只借来源/版本记录和验证方法，不采用游戏目录、XGS 清单/资源格式，不另开 Linux 启动器任务。

## 5. ABI 核对：先适配接口，再接算法

工具 [d2r_direct_audit.py](../tools/d2r_direct_audit.py) 编译两仓真实头文件，不读游戏数据：

```bash
python3 android/tools/d2r_direct_audit.py \
  --d2r-root <d2r-mobile 工作副本> \
  --output /tmp/s2arm-d2r-nvn-abi-20261026.json
```

本轮 Linux LP64：**30 项抽查值不同、10 个 S2Arm 独有、2 个 d2r 独有**。这不是 Android ARM64 认证，也不能保证未抽项兼容。

| 项 | S2Arm | d2r | 影响 |
|---|---:|---:|---|
| OP_BLEND_COLOR | 32 | 33 | 不能共用原 decoder |
| p_bind_program 大小 | 184 | 16 | 当前内联程序/键快照 |
| p_bind_handles.h 偏移 | 24 | 16 | deferred/src 字段不同 |
| p_set_rt 大小 | 240 | 344 | 附件/view 编码不同 |
| tex_t / view_t 大小 | 128 / 16 | 144 / 28 | 禁止写旧对象结构 |
| p_draw / p_dispatch 大小 | 48 / 32 | 12 / 24 | 按当前 payload 解码 |
| cmd_t.end 偏移 | 24 | 16 | 存储/guest 内联写标记不同 |

内部 helper 描述可以适配，不能反过来改 guest ABI 迎合参考代码。

## 6. 本轮验证与重跑命令

### 6.1 已执行与证据边界

d2r `445bf05` 上 **7 个 C/C++ 程序编译运行成功、3 个 Python 守卫/模型脚本成功，另有本仓 ABI 探针成功**。未创建 Vulkan device、未部署 APK、未新增游戏局。

| 测试 | 结果/范围 |
|---|---|
| dm/gfx/tests/t_copy_pitch.c | 真实 pitch helper：压缩块、padding、非法跨度/溢出通过 |
| engine/tests/writeback_skip_test.cpp | 110 检查；真实范围/写回 helper、同步后重新 lookup；无 GPU |
| dm/gfx/tests/t_completion_wait.cpp | 7 用例、232 断言；总预算/可见性/通知竞态，完成发布者为模型 |
| engine/tests/native_bc_policy_test.cpp + xbg_blit.cpp | 真实策略、block pitch、ASTC planner/保留判定；无 GPU |
| engine/tests/raster_facts_test.cpp + xbg_spirv_raster.cpp | 合成 SPIR-V 严格识别，包含初始化后写 Position 的模式 |
| engine/tests/adreno_policy_test.cpp | 机型/开关解析；不证明实际 shader/driver 安全 |
| engine/tests/pool_flags_registry_test.c | 4121 检查；真实 C 池表、alias/owner/溢出；无宿主 mutex/GPU |
| engine/tests/event_order_test.py | 事件模型/源码接线，不是真实 GPU 完成 |
| engine/tests/test_read_preflight_order.py | 3 用例；源码守卫和负控制 |
| engine/tests/copy_stride_test.py | 1000 独立模型用例和源码守卫，不是 Vulkan copy |

本机摘要 `/tmp/s2arm-d2r-reuse-20261026.json` 与 ABI 报告不含游戏数据；临时文件不是长期门禁凭据，不随本文入仓。旧文 10-25 的测试/全仓门禁读数不沿用成本轮通过。

### 6.2 可重跑命令

在 d2r 根目录执行，输出只放临时目录：

```bash
audit_dir=$(mktemp -d /tmp/s2arm-d2r-reference.XXXXXX)
cc -std=c11 dm/gfx/tests/t_copy_pitch.c -o "$audit_dir/copy_pitch"
"$audit_dir/copy_pitch"
c++ -std=c++17 dm/gfx/vulkan/engine/tests/writeback_skip_test.cpp -o "$audit_dir/writeback"
"$audit_dir/writeback"
c++ -std=c++17 -pthread -DDM_COMPLETION_WAIT_SELFTEST -DDM_COMPLETION_WAIT_MAIN \
  dm/gfx/tests/t_completion_wait.cpp -o "$audit_dir/completion"
"$audit_dir/completion"
cc -std=c11 -UNDEBUG dm/gfx/vulkan/engine/tests/pool_flags_registry_test.c -o "$audit_dir/pools"
"$audit_dir/pools"
c++ -std=c++17 dm/gfx/vulkan/engine/tests/raster_facts_test.cpp \
  dm/gfx/vulkan/engine/xbg_spirv_raster.cpp -o "$audit_dir/raster"
"$audit_dir/raster"
```

BC 测试需要 Vulkan 头但不链接 Vulkan/访问 GPU。本轮保留宿主 libc/C++ 头优先级，仅用 `-idirafter` 补 NDK Vulkan 头：

```bash
audit_vk_headers=$ANDROID_HOME/ndk/29.0.14206865/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include
c++ -std=c++17 -idirafter "$audit_vk_headers" \
  dm/gfx/vulkan/engine/tests/native_bc_policy_test.cpp \
  dm/gfx/vulkan/engine/xbg_blit.cpp -o "$audit_dir/native_bc"
"$audit_dir/native_bc"
c++ -std=c++17 dm/gfx/vulkan/engine/tests/adreno_policy_test.cpp -o "$audit_dir/adreno_policy"
"$audit_dir/adreno_policy"
python3 dm/gfx/vulkan/engine/tests/event_order_test.py
python3 dm/gfx/vulkan/engine/tests/test_read_preflight_order.py
python3 dm/gfx/vulkan/engine/tests/copy_stride_test.py
```

提取后，测试必须调用本仓实际生产函数、使用独立期望和负例；不能仅跑上游测试证明接入。测试中旧 stage 约定也要适配到当前类型，不恢复旧 ABI。

## 7. 实施顺序与停止条件

### 7.1 当前问题先看实际首错

先验证 23c5d21b 后的同帧源图/截图；方向已正确不再改。视觉错误追真实 draw；guest memory/SVC 错误走原生层证据，不混成一个 shader 问题。

按实际调用命中选择下一项：

1. R01/R02/R04：方向、view 消费和内容保持。
2. R09/R10：clear 顺序、模板 mask/ref 等已知状态缺口。
3. R03/R05/R06/R08：严格 sampler、pitch、深度平面、附件/target/sample。
4. R12–R16：alias、写回、完成与记录生命周期；任何 pending 释放风险实际触发时优先处理。
5. R17/R19：正确画面、稳定运行后按热点做缓存/批处理/预热。

排序不覆盖真实首错。未触发功能可保持明确 Unsupported，不能静默跳过后称完成。

### 7.2 每项采用的交付模板

```text
问题：固定场景/命令及首次错误边界，是否影响当前首错。
参考：固定 commit、文件、函数；若 d2r 没实现，明确补充来源。
提取：保留的算法、头文件/枚举/owner/反射适配。
禁止带入：XGS/旧 loader/旧 ABI/固定 shader key/单款政策/第二 owner。
消费者：本仓哪个生产函数实际调用；未接的仍标待接。
验证：本仓生产函数的独立期望/负例，以及所需真实 GPU/像素对照。
结果：修前/修后、候选身份、限制；无画面改善不写首帧突破。
```

两小时交付一项可验证结果或明确的下一边界，时间到不扩大为重写全部模块。现有正确实现通过后保留，不因找到另一参考又换一套。

### 7.3 完成标准

- 依赖闭包无 XGS 文件/parser/writer、旧绑定 ABI/缓存/初始化入口，统一 program 契约未降级。
- 核对构建源文件、头文件包含和最终链接依赖，不能仅靠新文件没有 `.xgs` 字符串验收；不得通过整套 `xbg_game_internal.h/xbg_game.h` 间接带回旧程序 ABI。
- 无第二 GPU/窗口/信号/系统服务 owner，无游戏地址/名称/数据政策。
- 真实消费者已接，测试调用本仓生产函数而非只证明参考 helper 绿。
- 游戏进度按正确像素、加载推进、可操作与稳定性，不按代码量/draw 数。
- 保留许可证、作者、来源及固定 commit；第三方依赖分别核对授权。
- 按现有流程完成适用检查，提 PR 前跑 `bash tools/contrib_check.sh`，缺跑如实报告；本文不是已完成清单。

## 8. 固定源码索引

链接固定为本轮 d2r commit。迁移时保留函数名索引，行号变化后不从零查找。

- [Android 呈现](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/android/vulkan_present.cpp)：create_surface/create_swap/present。
- [执行、资源和诊断](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_game.cpp)：逐函数适配，整文件不可直接采用。
- [视口等转换](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_nvn.cpp)、[严格采样器](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_sampler.cpp)。
- [字节 pitch](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/nvn/nvn_copy_pitch.h)、[copy/blit](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_blit.cpp)、[深度平面](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_depth.c)。
- [附件 planner](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_framebuffer.c)、[清理 helper](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_clear.cpp)、[draw planner](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_draw_plan.c)。
- [BC 策略](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_bc_policy.h)、[顶点接口](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_vertex.c)。
- [写回](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_writeback_policy.h)、[完成等待](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_completion_wait.h)、[pool registry](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/nvn/nvn_pool_flags_registry.h)。
- [命令展平](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_command_clone.c)、[pipeline 键](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_pipeline_key.h)、[memo helper](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_pipeline_memo.h)。
- [光栅事实](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_spirv_raster.cpp)、[Adreno 实验策略](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/gfx/vulkan/engine/xbg_adreno_policy.h)。
- [生命周期](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/android/lifecycle_dispatch.h)、[JNI 输入桥](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/android/text_input_jni.c)、[Activity](https://github.com/jhaizhou-ops/d2r-mobile/blob/445bf05e600dabb735f89d932469396f6a15ea1a/dm/android/app/src/main/java/com/xiaoboluo/d2r/DmActivity.java)。

补充来源均用本仓锁定代码：iOS nvn_mtl.m、Ryujinx TextureView/TextureStorage/EnumConversion/Window、AndroidWindow.cs。三者分别提供 NVN 语义、Vulkan 机制和 Android 窗口契约，适配前提不同，不能相互替代。

<a id="d2r-engine-removal"></a>

## 9. 旧导入副本的来源与删除记录

- 来源：`jhaizhou-ops/d2r-mobile` 的 `dm/gfx/vulkan/engine/`，整批导入本仓 `graphics/third_party/d2r_vulkan_engine/`，MIT 许可（版权 jhaizhou），目录内附 `LICENSE`；`SOURCE.json` 记录逐文件 SHA-256，并标注来源提交 `e3756f8942b40eba6c851e881828a5b1bda17fd6`（不含外层 `dm/android/vulkan_present.cpp`，不能代表完整 Android 实现）。
- 作者与许可确认：jhz 2026-10-30 确认「Harmony NVN-to-Vulkan implementation」为其自写、MIT（版权 © 2026 jhaizhou），原记录在 `SOURCE.json` 的 `author` 字段（该文件随目录删除，本段即保留的来源说明）。
- 用途边界：该副本只作算法与历史验证参考，从未进入 `nvn_vk` 产品构建；本仓实现在 `android/native/nvn/` 按用途重写，不复制上游类型、命名或 XGS 协议。
- 删除（2026-10-30）：整目录、CMake 的 `engine` 后端分支与 `S2ARM_ANDROID_VK_BACKEND=engine` 选项、专属探针（`runtime/vk_engine_*.cpp`、`tools/direct_vk_engine_*.sh`、`tools/direct_engine_assets.sh`、`tools/direct_c2_xgs*.py`、`tests/vk_engine_*`）以及 `android/test.sh` 中两支旧源码守卫一起删除。删除前逐个核对消费者：生产代码、构建和内用探针都不再引用该目录。
- 许可与历史：删除后本仓不再分发该副本的任何逐字文件，第三方许可表不新增条目；`LICENSE`、`SOURCE.json` 与逐文件摘要仍可在上游仓库和本仓此前的 git 历史中取得。若以后再次搬入上游文件，须恢复对应的 MIT 署名与许可副本。
- 上游定位保留：本文 §8 的 `D2R/.../xbg_*` 链接是上游源码定位，不指向本仓已删目录。
