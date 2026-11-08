# Vulkan 内置 utility SPIR-V 合同

`HelperShader` 直接加载项目嵌入的二进制，绕过运行时 GLSL 的目标环境选择。
本入口读取真实 `Ryujinx.Graphics.Vulkan.csproj` 的 utility 资源清单，再用显式提供的
`spirv-val` 按 Vulkan 1.1 校验每一份模块；不下载工具，不修改输入或操作设备。

```sh
python3 graphics/vulkan/runtime/utility-tests/run.py \
  --vulkan-root /absolute/S2Arm/ryujinx/tree/src/Ryujinx.Graphics.Vulkan \
  --spirv-val /absolute/bin/spirv-val \
  --output /tmp/utility-validation-new
```

输出目录必须尚不存在且位于输入目录之外。退出码 0 为全部模块通过，1 为模块校验失败，
2 为工具或输入准备失败。完整命令、工具与项目 SHA、资源 SHA 和原始输出写入 `result.json`。
固定旧源目录可走同一个入口作红例；不要改 SPIR-V 头部伪造目标版本。

本次四份 1.5 模块从未修改的 GLSL 真实重编为 Vulkan 1.1 / SPIR-V 1.3：
`ChangeBufferStride`、`ColorCopyShorteningCompute`、`ColorCopyWideningCompute`、
`ConvertD32S8ToD24S8`。可复跑的生成方式为：

```sh
glslangValidator -V --target-env vulkan1.1 -S comp \
  -o /tmp/ChangeBufferStride.spv \
  /absolute/S2Arm/ryujinx/tree/src/Ryujinx.Graphics.Vulkan/Shaders/ChangeBufferStrideShaderSource.comp
```

其他三份同样以其 `*ShaderSource.comp` 编译。实际生成器为 glslang 16.6.0，
校验器为 SPIRV-Tools v2026.4；不同工具版本可能产生不同二进制，不据此宣称像素等价。

校验明确启用 `--uniform-buffer-standard-layout`，因为现有 utility 的 std430 UBO
需要实际启用该设备功能。8 位存储等模块能力也必须由真实 device feature 链满足。
这里不能证明扩展被广告、查询或启用；对应初始化测试及真机 VVL 验收必须另列。
静态通过不代表 GPU 结果、渲染正确性、帧率或 DeviceLost 已修复。
