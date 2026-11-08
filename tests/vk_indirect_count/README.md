# AMD indirect count 真 GPU 回归

在仓库根目录、项目 Apple 工具链和 .NET 环境中运行：

```sh
make -j1 -f tests/vk_indirect_count/Makefile vk-indirect-count-test
```

门禁已登记为 `graphics/gate.sh` 的 `vk_indirect` 子项，支持 `GATE_ONLY`、`GATE_SKIP` 与 `GATE_CHANGED`。只跑该项：

```sh
MTL_DEBUG_LAYER=1 GATE_ONLY=vk_indirect bash graphics/gate.sh
```

依赖 `glslangValidator`、`spirv-cross` 和 Xcode Metal 工具链。只链直连层 `libnvn.a`（`graphics/nvn/Makefile` 的产物）和宿主替身（`graphics/nvn/tests/host_stubs.h`，与 t_nvn_m3 共用），不链宿主、不发布宽屏 NativeAOT；libnvn 已编好时约 6 秒。产物在 `build/tests/vk_indirect_count`。着色器从测试 GLSL 源码经 glslang 现编 SPIR-V，再用项目 `vk_shaders.py` 生成实际 Metal 库。mini 缺少同 OpenGL 子项使用的两个 Homebrew 工具，因此该子项按现有依赖证据登记为本机运行。

测试通过生产 `swhle` 表取得 Vulkan 入口，分别校验 instance/device 查址、AMD 扩展和所需 feature。所有对象、参数缓冲、索引、颜色与深度附件均通过公开 Vulkan API 建立；完成提交后通过公开 Vulkan 拷贝与映射读取 GPU 像素。

原有18组覆盖 AMD 两入口的 count=0/1/超过 max、max=0、非零内存绑定与命令/计数/索引偏移、40字节 stride、16/32位索引、负 vertexOffset、非零 firstInstance、同一命令缓冲的 GPU copy 后绘制，以及 core 两个固定数量 indirect 入口。像素与独立 direct 基线逐字节比较，并检查手算的内部像素、裁剪与深度遮挡；precise occlusion query 与 direct 基线完全相等。双 pass/query 用例还检查后面的 Metal render encoder 不清掉前一遍的查询结果。

新增6组覆盖同一 pass 的四次 AMD count draw（独立 count/参数偏移、两种入口混合）、同一 submit 的三个 command buffer、一次 `vkQueueSubmit` 的三个 `VkSubmitInfo`、无中间 idle 的三次 queue submit，以及前一 pass/command buffer 结束后合法 GPU copy 更新参数和计数。每组均比较完整64×64 RGBA、手定九格像素和遮挡查询。普通附件 barrier、pass 外依赖链、最后一次 count 后的依赖链与 max=0 都必须正常。

另1组在独立子进程中，通过合法 self-dependency 声明 `SHADER_WRITE → 0`、`0 → INDIRECT_COMMAND_READ` 链，要求有效 count draw 明确报不支持、错误计数只增加1；同位置 max=0 不得误报。测试着色器并不实际写缓冲，这一组只验证实现对该依赖组合的保守拒绝，不声称检测到了真实着色器写入。没有把不符合 Vulkan 规范的 pass 内 copy 作为合法测试。

实际 Metal 创建事件由只读 `dm_vk_indirect_stats` 提供：它在 render encoder 创建成功、submit scratch buffer 分配成功处记账，不使用逻辑 `g_n_pass` 冒充编码器数量。Apple M5 Pro、`MTL_DEBUG_LAYER=1` 实测25组全过，确认启用 Metal API Validation 且无验证错误。单 pass 四次 AMD draw 为1个 render encoder、1块176字节 scratch；三个 CB 或三个 SubmitInfo 为3个 encoder、1块528字节 scratch；三次未等待的 queue submit 为3个 encoder、3块 scratch，共528字节。两种前序 GPU copy 用例均为2个 encoder、1块176字节 scratch。全部 direct 基线分配0块 scratch。

本机门禁本次增量构建及运行共13.29秒（门禁报告13秒），低于该子项300秒上限。日志保存在 `build/gate_gfx/vk_indirect.log`；维护者反馈修订的正式验证归档在 `build/vk-indirect-rework/`。

这是本机 Metal GPU 接口回归；不代表具体游戏、iOS 或安卓的运行验证。
