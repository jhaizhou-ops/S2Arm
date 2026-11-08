// GAL 日志宏：纯 C，不引 Metal 头；gal_internal.h 在 Metal 4 可用性区之前包含本头，gal_spvx.c 在 Linux / Windows 出包机单独编时也用（#783）。
#pragma once
#include <stdio.h>
#define GLOG(...) do { fprintf(stderr, "[gal] " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define GRED_ONCE(...) do { static int once_; if (!once_++) { fprintf(stderr, "[gal] 【红】" __VA_ARGS__); fputc('\n', stderr); } } while (0)
