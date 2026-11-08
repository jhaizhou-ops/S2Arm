// GLSL 源码改写层（gl_glsl_es.c）：出包离线链 gl_shaders.py 与宿主运行时兜底 gl_xlate.c 共用。返回 malloc 的文本（以 0 结尾，*out_n 为长度），调用方 free
#pragma once
#include <stddef.h>
// 原文（预处理之前）：「#version 300 / 310 / 320」不带 profile 的第一行补「 es」
char *s2a_glsl_es_prefix(const char *src, size_t n, size_t *out_n);
// 预处理之后的文本 → glslang -V 收的 GLSL ES 3.10（ES 1.00 / 3.00 升版、旧函数与内建改写）；stage = 'v' / 'f' / 'c'。失败返回 NULL、原因写 err
char *s2a_glsl_es_rewrite(const char *pre, size_t n, char stage, size_t *out_n, char *err, size_t errn);
