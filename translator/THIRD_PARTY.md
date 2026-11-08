# 离线工具的公开格式依据

## Unity 5.5 Shader 布局（N5 首片）

`unityfs.py` 的 `SHADER_5_5` 是按固定公开 reader 的 **5.5 版本分支**重写的布局描述；
没有引入或执行 AssetStudio、没有新增运行时依赖、没有下载/复制 TypeTreeDumps 或 TPK 数据。
合成 fixture 是手写字节与预期，不读取游戏，也不遍历被测布局生成测试输入/答案。

来源固定为 **Perfare/AssetStudio `d158e864b556b5970709c2a52e47944d53aa98a2`**：

| 字段/边界 | 固定源码 |
| --- | --- |
| 属性、浮点/混合/模板/向量状态 | [Shader.cs L68–275](https://github.com/Perfare/AssetStudio/blob/d158e864b556b5970709c2a52e47944d53aa98a2/AssetStudio/Classes/Shader.cs#L68-L275)；5.5 没有 `zClip` 和 `conservative` |
| channels、向量/矩阵/纹理、缓冲 | [Shader.cs L279–473](https://github.com/Perfare/AssetStudio/blob/d158e864b556b5970709c2a52e47944d53aa98a2/AssetStudio/Classes/Shader.cs#L279-L473)；5.5 没有 multisample、buffer array size、struct params、partial CB |
| subprogram 顺序与关键字对齐 | [Shader.cs L563–690](https://github.com/Perfare/AssetStudio/blob/d158e864b556b5970709c2a52e47944d53aa98a2/AssetStudio/Classes/Shader.cs#L563-L690)；5.5 关键字数组后不对齐，tier/type 后对齐，没有 samplers/requirements |
| program/pass/subshader、依赖 | [Shader.cs L693–933](https://github.com/Perfare/AssetStudio/blob/d158e864b556b5970709c2a52e47944d53aa98a2/AssetStudio/Classes/Shader.cs#L693-L933)；无 common params、ray tracing、procedural flag、keyword masks |
| root、一维 offset/length、blob | [Shader.cs L964–1029](https://github.com/Perfare/AssetStudio/blob/d158e864b556b5970709c2a52e47944d53aa98a2/AssetStudio/Classes/Shader.cs#L964-L1029)；5.5 没有 nonmodifiable-texture map |
| root 名称 | [NamedObject.cs](https://github.com/Perfare/AssetStudio/blob/d158e864b556b5970709c2a52e47944d53aa98a2/AssetStudio/Classes/NamedObject.cs) |
| format 17 的 PPtr：i32 file ID + i64 path ID | [PPtr.cs](https://github.com/Perfare/AssetStudio/blob/d158e864b556b5970709c2a52e47944d53aa98a2/AssetStudio/Classes/PPtr.cs) |

布局只登记 `(class 48, hash 4496e93f2179252104401c8dda0a1751)`。
该身份来自[维护方 #494 的脱敏观察](https://github.com/jhaizhou-ops/S2Arm/pull/494#issuecomment-6417039957)：
SerializedFile 17、Unity 5.5.0p1、platform 38、无类型树。
**来源 reader 的版本分支 + 合成测试不证明此私有样本已经抽取成功**；
该款真实抽取数、直连翻译与编库仍须维护方用其已有合法样本二层验证。
不按版本字符串猜未知 hash；现有同 class/hash 借树优先和其他布局不变。

单测中的两条 Switch 程序仅有控制/代码头及长度，**没有真实 GPU 指令**，
不做翻译/编译/设备执行。52/56 字节子程序夹具分别验证奇数/偶数关键字对齐；
所测截断是缺少必要字段，不声称已加固通用 reader 对所有损坏长度或末尾 padding 的检查。

## Unity Shader 按版本生成布局（10-29，wire-c/unity-extract）

`unityfs.py` 的 `shader_layout(版本)` 按 Unity 版本生成 Shader（class 48）布局，取代逐 type hash 手写；
原先手写的布局（5.5.0p1 / 2020.3.18f1 / 2022.3.17f1 三份；2018.3.10f1 那份见本节末）原文移到
`graphics/tools/direct/tests/unity_layouts_golden.py` 当金样，生成结果逐字节等价（`t_unity_layouts.py`）。
**没有带进任何类型树数据库、上游代码或运行时依赖**；版本分支是读下表的公开 reader 后重写的规则。

| 来源 | 版本 / 提交 | 许可 | 用到什么 | 带进仓库的文件 |
| --- | --- | --- | --- | --- |
| Perfare/AssetStudio | `d158e864b556b5970709c2a52e47944d53aa98a2` | MIT（原文见下节） | [Shader.cs](https://github.com/Perfare/AssetStudio/blob/d158e864b556b5970709c2a52e47944d53aa98a2/AssetStudio/Classes/Shader.cs) 的版本分支：zClip 2017.2、conservative 2020.1（L246/L253）；MultiSampled、结构参数 2017.3（L362/L418）；BufferBinding.m_ArraySize 2020.1（L383）；m_IsPartialCB 2020.3.2 / 2021.1.4（L430–433）；关键字全局 / 局部 2019–2021.1、对齐 2017、参数套结构 2020.3.2 / 2021.1.1、m_ShaderRequirements 2017.2 / 64 位 2021.1（L587–679）；共用参数、2022.1 关键字掩码（L709–717）；pass 的 2020.2 编辑器哈希 / 平台 / 掩码、2019.3 光追、2018 程序化实例、2021.2 关键字掩码（L759–808）；2021.2 关键字名、2021.1 自定义编辑器（L901/L919）；2019.3 分段、2018 不可改纹理表（L984 起） | 无（规则在 `unityfs.py` 里重写） |
| aelurum/AssetStudio（AssetStudioMod） | `35b24990c6a5d99c15b661578cf9da26aefe8d1b` | MIT（Copyright 2016 Radu、2016-2022 Perfare、2021-2024 aelurum） | 只用来交叉核对上面的版本分支（同一组边界），没有取新规则 | 无 |
| 真实类型树（游戏自带资源包） | Ace Attorney Investigations Collection 2022.3.17f1、Servonauts 2021.3.34f1 | 游戏数据，不进仓库 | AssetStudio 两版都没读的 2022 式字段 `m_PlayerSubPrograms` / `m_ParameterBlobIndices` / `stageCounts`：2021.3.34f1 与 2022.3.5f1 起有；2021.3.0–2021.3.33、2022.1–2022.3.4 不知道，两种布局都试、对象字节定（`player_fields`） | 无（只记了版本点） |

调研过、**不带进仓库**的：

| 库 | 状态（10-29 GitHub 元数据） | 结论 |
| --- | --- | --- |
| AssetRipper/TypeTreeDumps | license 为 null，根目录无 LICENSE；数据是从 Unity 编辑器导出的 | 没有许可证 = 不能用（10-29 口径）：不带、不抄，仓库里原有两份取自它的布局已删（见本节末） |
| AssetRipper/Tpk | 代码 MIT；它打出的 `.tpk` 是 TypeTreeDumps 的压缩包 | 代码许可不覆盖数据，同上不带 |
| K0lb3/UnityPy、K0lb3/tpk_ar | 代码 MIT；UnityPy 读的 `resources/lzma.tpk` 即上面的 TPK | 同上，数据不带；也不加依赖 |
| AssetRipper/AssetRipper | GPL-3.0 | 与 Apache-2.0 / MIT 仓库不兼容，本次没有读它的代码 |

ComputeShader（class 72）没有许可清楚的分版本布局来源（AssetStudio 不读它），所以**不生成布局**：
没有类型树时按「kernel 代码是 i32 长度 + 程序码、程序码自校验」在对象字节里找（`shader_split.unity_scan_kernels`），不依赖任何外部数据。
**仓库不再含任何取自 TypeTreeDumps 的数据**（10-29，wire-c/unity-tt-clean；口径：没有许可证的等同不能用）：
原先的 2018.3 Shader 布局（`SHADER_2018_3`，来自 `StructsDump/release/2018.3.10f1.dump`）现在由 `shader_layout((2018, 3, 10))` 按上表 AssetStudio 规则生成，
测试金样里那份原文已删；原先的 2022.3 ComputeShader 布局（`COMPUTE_2022_3`，来自 `2022.3.54f1.dump`）连同它在 `KNOWN_TREES` 里按 hash 钉的那项一起删掉，
该 hash 的对象改走上面的免树扫描。测试里有树路径用的计算着色器布局是测试自拟的玩具布局，不对应任何 Unity 版本。

### 固定上游 MIT 许可

[上游 LICENSE](https://github.com/Perfare/AssetStudio/blob/d158e864b556b5970709c2a52e47944d53aa98a2/LICENSE)
原文保留如下（适用于上述公开格式依据，不为任何第三方数据库作许可背书）：

```text
MIT License

Copyright (c) 2016 Radu
Copyright (c) 2016-2020 Perfare

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
