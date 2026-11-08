# SPIRV-Cross（收录子集，供 GAL Metal 渲染器 SPIR-V → MSL）

来源：KhronosGroup/SPIRV-Cross 标签 vulkan-sdk-1.4.363.0（Apache-2.0，见 LICENSE），与 Homebrew spirv-cross 1.4.363.0 同版。
下载：https://github.com/KhronosGroup/SPIRV-Cross/archive/refs/tags/vulkan-sdk-1.4.363.0.tar.gz，sha256 f708982e88b763ef5b0394ed468fc2c3628f68cdab89f2e7a946cd628c04e721（10-18 渲染线）。
收了：核心（spirv_cross / parsed_ir / parser / cfg）+ GLSL（MSL 的基类）+ MSL + C 接口，全部头文件；源码零改动。
11-01 出包线补：命令行 main.cpp 与它链接要的 HLSL / C++ / 反射后端（spirv_hlsl / spirv_cpp / spirv_reflect / spirv_cross_util 的 .cpp），同一标签、同一源码包（sha256 同上），零改动；
  供 translator/spvc_inproc.py 把命令行编成动态库在进程内调用（直连出库翻译段，输出与 Homebrew spirv-cross 1.4.363.0 命令行逐字节相同）。
编译开关：SPIRV_CROSS_C_API_MSL=1 SPIRV_CROSS_C_API_GLSL=1（其余语言不收）。
用途：sw/gfx/gal/gal_prog.m 的 Mac 运行时现编、iOS 首遇现编、tools/gal_xc 离线出库——三处同一份源码，生成的 MSL 一致。
