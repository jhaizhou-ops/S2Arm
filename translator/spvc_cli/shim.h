// 仅在编译 graphics/third_party/spirv_cross/main.cpp 时预包含（-include）：把 spirv-cross 命令行原样编进动态库，供出包工具在进程内调用（spvc_inproc.py）。
//   · main → spvc_cli_main：入口由 shim.cpp 的 spvc_cli_run 包一层；
//   · exit → 抛 spvc_exit：命令行在出错分支（找不到入口点、参数不对）直接 exit，进程内会带走整个 Python；改抛异常，main 自己的 try 接住、返回 EXIT_FAILURE；
//   · stderr → 本线程的内存流：报错文本按调用分开交回（多线程同时调用不串）。stdout 不动：调用方一律给 --output。
// main.cpp 零改动（与 vulkan-sdk-1.4.363.0 标签逐字节相同）。
#pragma once
#include <cstdio>
#include <cstdlib>
#include <exception>
struct spvc_exit : std::exception { const char *what() const noexcept override { return "spirv-cross exit"; } };
[[noreturn]] inline void spvc_shim_exit(int) { throw spvc_exit(); }
extern "C" FILE *spvc_shim_err(void);
#undef stderr
#define stderr spvc_shim_err()
//   · fopen → 本线程的内存（spvc_cli_run_mem）：路径 "mem:in" 读调用方给的 SPIR-V、"mem:out" 写进内存流；其余路径照常开文件（出包 C# 批量进程不落逐键临时文件）
extern "C" FILE *spvc_shim_fopen(const char *path, const char *mode);
#define fopen spvc_shim_fopen
#define exit spvc_shim_exit
#define main spvc_cli_main
