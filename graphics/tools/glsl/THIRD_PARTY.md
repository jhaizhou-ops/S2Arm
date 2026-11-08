# 第三方来源与致谢

本链调用下列开源工具；不把工具源码或可执行文件打包进本目录。发布包含这些工具的发行物时，应随包保留相应完整许可与版权声明。

| 工具 | 本次实际验证版本 / 提交 | 来源与许可 |
|---|---|---|
| glslang | `16.6.0`，`e1b562a8bed273a02f30b59b66a5d499793cede5` | [KhronosGroup/glslang](https://github.com/KhronosGroup/glslang/tree/16.6.0)；[该版完整 LICENSE.txt](https://github.com/KhronosGroup/glslang/blob/16.6.0/LICENSE.txt)。许可文件包含 BSD 3-Clause、预处理器的 BSD 2-Clause 等各部分条款，不把整个仓库简称为单一许可。本次关闭可选优化器 / HLSL / 测试，没有使用外部测试依赖。 |
| SPIRV-Cross | `vulkan-sdk-1.4.363.0`，`f11ba9f0b21ba8fc15153d50a2a1ae31ab1cf8f7` | [KhronosGroup/SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross/tree/vulkan-sdk-1.4.363.0)，[Apache-2.0](https://github.com/KhronosGroup/SPIRV-Cross/blob/vulkan-sdk-1.4.363.0/LICENSE)。与仓库 `graphics/third_party/spirv_cross` 收录版一致；本链调用其官方 CLI，不复制翻译器。 |
| SPIRV-Tools（测试） | `v2026.4`，工具自报 `v2026.4-0-gef96ed7` | [KhronosGroup/SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools/tree/v2026.4)，[Apache-2.0](https://github.com/KhronosGroup/SPIRV-Tools/blob/v2026.4/LICENSE)。测试用 `spirv-as / spirv-val`；不是运行时依赖。 |

Apple Metal / metallib 编译器来自用户自行安装并同意许可的 Xcode。本次组件验证为 Xcode 16.2（16C5032a）、Metal 32023.404；项目统一开发工具链仍以 `tools/toolchain.env` 为准，未更改或放宽它。
