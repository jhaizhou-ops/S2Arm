# Metal 管线创建计时

这个工具按给定的函数配对和状态，逐项调用 Metal 创建渲染管线。它借用 `graphics/metal/tools/psobench` 的 `mach_absolute_time` 计时方式；原工具读取 MSL、测试 Metal 4 基础管线和特化，并输出汇总，不接受本工具的 metallib / 状态清单。

```sh
xcrun clang -fobjc-arc -mmacosx-version-min=15.0 tools/pipeline_timing.m \
  -framework Foundation -framework Metal -o /tmp/pipeline_timing
/tmp/pipeline_timing metal3 /path/to/shaders.metallib /path/to/cases.json > /tmp/pipeline-report.json
# macOS 26 且设备支持 Metal 4 时可单独测 Metal 4：
/tmp/pipeline_timing metal4 /path/to/shaders.metallib /path/to/cases.json > /tmp/pipeline-report-m4.json
bash tests/pipeline_timing_test.sh
```

输入为 JSON 数组，每项必须包含 `name`、`vertex`、`fragment`、`color`、`samples`、`blend`、`topology`、`attributes` 和 `buffers`；见 `tests/fixtures/pipeline_timing/cases.json`。`color` 支持 `rgba8unorm`、`bgra8unorm`、`rgba16float`、`r8unorm`；`blend` 支持 `none` 和 `alpha`，后者的 RGB 与 alpha 均为源因子 `SourceAlpha`、目标因子 `OneMinusSourceAlpha`、运算 `Add`；`topology` 支持 `triangle`、`line`、`point`、`unspecified`。`samples` 必须是设备支持的正整数。输入属性支持 `float`、`float2`、`float3`、`float4`、`int4`、`uint4` 和 `uchar4normalized`；buffer 的步进固定为 per-vertex，数组为空时适用于顶点着色器自行取值。工具只支持一个颜色附件，深度/模板、其他混合模式、实例步进和函数常量不在此版本；未识别的字段或状态会报错，不能用缺省值冒充指定状态。

结果 JSON 包括设备、系统、后端、每项状态和计时（毫秒），`over_1s`、`over_5s` 是耗时超过相应阈值的输入下标，失败也列出错误；任何一项失败退出 1，输入或设备错误退出 2。计时只包含同步创建管线的调用，不含加载 metallib、查询函数或建立 Metal 4 编译器。系统与驱动缓存未清理：相同配对重复运行可能命中缓存；冷编结论需在能控制缓存的环境另行测量。此工具不等同游戏运行时的所有状态或特化路径，Metal 3 和 Metal 4 数值不能混用。不要提交私有 metallib、着色器和游戏数据。

`coverage` 在计时后枚举 metallib 的函数：顶点和片元各自标记 `covered`（至少一组管线创建成功）、`failed_only`（只出现在失败配对）或 `uncovered`；`failed_pairs` 列出失败的输入配对。其他阶段放在 `other_stages`，类型是 Metal 的 `MTLFunctionType` 枚举值（3 为 kernel、5 为 visible、6 为 intersection、7 为 mesh、8 为 object）。无法通过 `newFunctionWithName` 取得的函数列在 `uninspectable`，例如需要函数常量的函数。工具不自动猜测配对；清单只有部分覆盖时不得称为全库覆盖。
