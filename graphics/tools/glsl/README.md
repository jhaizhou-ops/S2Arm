# GLSL 出包离线链（#280）

唯一入口是 `translator/gl_shaders.py`。它扫描 RomFS 的 MVGL、main NSO 的 `#version` 字符串和采集目录，也接受单独的 `.vert / .frag / .comp`。每支独立翻译；SPIR-V → MSL 的分槽、有效资源过滤和 NaN precise 改写与 Vulkan 共用 `graphics/tools/spirv_msl.py`。

```sh
# 依赖由玩家准备；GLSLANG 可指向 glslang / glslangValidator，其他工具从 PATH 找。
python3 translator/gl_shaders.py <RomFS> <main NSO> <采集目录> <macOS输出根> --ios <iOS输出根>
python3 translator/gl_shaders.py graphics/nvn/tests/gl/tri.vert graphics/nvn/tests/gl/tri.frag <输出根>
```

## 运行时接口

按 [GL 前端接口说明](../../../docs/研究/GL前端接口.md) §4、§8 出库：

- `<输出根>/gl/` 仅包含 `gl_shaders.metallib` 和 `gl_shaders.tsv`；表头 `# s2arm-gl-lib 1`，随后两行注释记录字段格式、glslang / SPIRV-Cross 版本。`--ios` 生成同格式 iPhone 库，带 `-mios-version-min=18.0 -fmetal-math-mode=relaxed`。
- 键为原始 GLSL 源码截到首个 NUL 的 SHA-256 前 16 位，加阶段。函数名 `gl_<键>_v / gl_<键>_f`；预处理和配对不改变键，一个顶点可配多支片元。
- 表项为 `a:名=槽:类型`、`u:名=偏移:类型:个数:步长`、`b:槽:大小`、`t:名=槽:类型`、`o:名=位置`。普通 uniform 用 `glslang -V -R --aml --amb` 收进每阶段一个 `gl_DefaultUniformBlock`，名字位置由运行时链接阶段分配。GL 各类资源的原 binding 与反射保留在核验 JSON，前端区分命名空间，共用后端统一分配 Metal 槽。
- 顶点输出 / 片元输入用 `[[user(变量名)]]` 配对。SPIRV-Cross `--fixup-clipspace` 在顶点每个返回前作 `z=(z+w)*0.5`；离线链不翻 Y，运行时按 GL 行序、负高度视口和公共后端上屏翻转处理。

采用 `-V -R` 与现行 GL 接口一致。glslang 16.6.0 的同一普通 uniform 样例用 `-G` / `-G -R` 都不会收默认块，不能用这两个选项代替单块契约；本链不把发射器产物描述成 OpenGL SPIR-V。

默认翻译与 Metal 编译均使用线程池，`-j / --jobs` 可指定并行数，缺省为本机 CPU 数。每个输入有独立临时目录，避免同源码的显式阶段与 NSO 未知阶段尝试互踩文件。`.air` 仅在临时目录中存在；逐支 `.metal` / `.spv` 和 `gl_shaders.json` 写到 `<输出根>/gl_diagnostics/`，不随 `gl/` 进包。

## 失败、计数与重复出包

失败逐支记录 `[RED] 来源:行号`；坏的那支不入表，其余继续编库。末行 `GLSL 汇总：成功 N、失败 N、跳过 0`，有失败时退出 1。未知阶段的 NSO 字符串会分别尝试顶点 / 片元，任一阶段成功就不把另一个失败尝试重复计错。成功数按去重后且所有请求 SDK 均编译成功的阶段行计；失败数按失败输入及 Metal 编译失败的阶段计。

6 支可编源码 + 1 支第 4 行语法错误 + 1 支不支持的自定义 UBO，结果为成功 6、失败 2，macOS / iOS 表各保留 6 行。全部失败则不出库，并移除目标中上次的库与表，避免旧成功冒充本轮成功。

允许对已有输出目录重跑：库与表覆盖，表只含本轮成功项。旧版本写进 `gl/` 的工具生成核验文件移到 `gl_diagnostics/legacy/`；工具不清空输出根或输入资源。

## 阶段组件验证

当前 GL 表口径 1 尚无显式 UBO / SSBO / image 接线，GL 运行时也无计算阶段。默认入口将这些阶段计失败并继续处理其他输入。任务中的组件可显式验证：

```sh
python3 translator/gl_shaders.py --components-only \
  tests/glsl/desktop.vert tests/glsl/desktop.frag tests/glsl/desktop.comp \
  <组件输出根> --ios <iOS组件输出根>
```

库在 `components/`，核验 JSON / SPIR-V / MSL 在 `components_diagnostics/`；不生成运行时 TSV。JSON 的 `runtime_table=false`，`unsupported` 说明未接线项。采样器表可以生成，纹理绑定和复杂扩展仍以运行时分片为准；varying 数组 / 接口块 / 矩阵不猜按名接线。

Vulkan 缺省入口保留最新主线行为：固定工作组计算着色器出 kernel 和 `w:x.y=z`，工作组由特化常量决定的跳过；输入附件映射为纹理，保留 `--msl-texture-1d-as-2d`、push constants 和双源变体。

## 验证与证据

```sh
# S2A_PY 使用已有仓库依赖环境；NSO 读取需要 lz4。
bash tests/glsl_offline_test.sh
git show <本轮主线基线>:translator/vk_shaders.py > <临时目录>/vk_before.py
"$S2A_PY" tests/glsl_offline_test.py --baseline <临时目录>/vk_before.py --out <验证目录>
bash graphics/nvn/tests/gl/t_gl_min.sh
bash tools/contrib_check.sh
```

离线集成测试覆盖桌面 450 / ES 310 六支组件的双 SDK 编库、源码键 / NUL 去重、按名独立链接、20 个普通 uniform 单块、三类源码读取、混合失败、重复出包、全部失败清旧表及精简产物。Vulkan 15 项对拍包含输入附件、固定 8×4×2 工作组与特化工作组跳过。

维护者对 `f3c237d8` 的复审已报告 `t_gl_min.sh` **191/191 通过**，见 [复审原文](https://github.com/jhaizhou-ops/S2Arm/pull/304#pullrequestreview-5641630698)；这是维护者环境的 GPU 读数。本机离线组件工具仍为 Xcode 16.2，统一 Xcode 27.1 自检的缺跑项以 PR 摘要为准。来源与许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。尚无真实 GL 游戏、帧率、能耗或 iPhone 起局验收。
