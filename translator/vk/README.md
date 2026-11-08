# Vulkan SPIR-V 等价 pass（T101 / #781）

独立离线工具；不改 `dmsh_chain.py` 的 `FILES`，不经过 MSL，也不改变现有苹果链。
只处理调用方显式提供的模块，不下载依赖，不读取游戏配置或着色器缓存。

## 使用

需要 Python 3.12+、`glslangValidator`（测试夹具）、SPIRV-Tools 的
`spirv-val` / `spirv-dis` / `spirv-as`。缺工具明确失败，不算跳过通过。

```sh
python3 translator/vk/spirv_passes.py vertex.spv -o vertex-vk.spv \
  --passes vs_pad,vs_init,precise,vs_depth --fragment fragment.spv
bash translator/vk/test.sh
bash tests/vk_spirv_passes_test.sh
```

`--fragment` 可重复，表示同一 VS 配对的多个 FS。选取的 pass 必须保持上例顺序，
可以省略；`precise` 可单独用于 FS/CS。默认 Vulkan 1.1，支持显式 `--target-env`
指定 Vulkan 1.0/1.1/1.2/1.3。模块原 SPIR-V 版本保留；输入和输出都经真实
`spirv-val`。任何读取、变换、装配、验证错误均非零退出，原输出不变。

## 四项语义

- `vs_pad`：读取配对 FS 的用户 Location，缺少的 VS 输出补 float32 vec4，
  入口写 `(0,0,0,1)`；已有 Location 保留原标量/向量类型并核配对匹配。
  这里“缺少”指未声明的 Location，已声明但未写值由 `vs_init` 负责；
  完整路径按上例组合两项。配对类型或插值声明冲突明确失败。
- `vs_init`：在 VS 入口局部变量声明后、用户指令前初始化每个 float32 vec4
  输出，包含接口块内成员与 Position。保留原来的后续写入；配合 `vs_pad`
  不重复初始化新增输出。其他标量/向量不改。
- `precise`：只转换 `GLSL.std.450` 的 FMin/FMax/FClamp 为 NMin/NMax/NClamp。
  不改其它扩展集或整型操作。
- `vs_depth`：保留原入口名/原始深度，新增 `<入口名>_depth`，在原入口函数体
  完成后仅改 Position.z 为 `z*0.5+w*0.5`。原函数体改为内部函数，两个入口
  分别调用它；因此 helper 写 Position、原入口的多个 return 都会经过正确收尾。
  不通过复制函数体制造第二套逻辑；无 `VK_EXT_depth_clip_control` 的后端
  可按深度模式选变体。工具自身不修改后端管线选择。

初始化/深度变体采用一次性合同，重复提交带相应标记的模块会明确拒绝，
不把标记当作语义验证成功。`precise` 可重复执行。

## 明确支持范围

当前工具接受一个指定 VS 入口（默认 `main`）和每个配对模块一个 `main` FS
入口；用户接口为 32 位标量/向量或带成员装饰的接口块。补齐的 FS 用户输入
须为 float32 vec4（对应当前 NVN 离线 locn 合同）。Position 可直接声明或位于
`gl_PerVertex`；ClipDistance/CullDistance 标量数组保持原样。

用户数组/矩阵、块级 Location、非零 Component/Index、装饰组、多 VS/FS 入口
均明确拒绝，不在未实现的形状上声称等价。这里不支持 vs_push/fs_uvx，不处理
运行时反射绑定或 Vulkan 管线创建；这些是独立任务。

## 证据口径

夹具均为本目录原创 GLSL，经实际 glslang 编译。测试检查配对输出、初始化位置
与次数、操作码计数、原入口保留及深度变体的独立数值解释；每个输出都过
spirv-val。四个独立负控在临时副本删除一个 pass 的核心函数，再跑同一语义
断言，必须失败；生产工具没有“跳过改写”的隐藏开关。

`tests/vk_spirv_passes_test.sh` 使用门禁现有 `tests/*_test.sh` 发现入口。
这些是离线编译/结构/数值测试，不是 GPU 出图、游戏、Android 或 Apple 真机
验收；不会用软件测试推导画面正确或能耗结论。

规范依据：Khronos [GLSL.std.450](https://registry.khronos.org/SPIR-V/specs/unified1/GLSL.std.450.html)
的 NMin/NMax/NClamp；[SPIR-V](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html)
的入口、函数、类型及逻辑布局。项目语义来自 #781 和回放核心契约 §4.4。
