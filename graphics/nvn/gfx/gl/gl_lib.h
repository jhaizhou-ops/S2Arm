// OpenGL 款直连着色器库的口径（出包 GLSL → SPIR-V → MSL ↔ 运行时 gl_prog.m / 就绪判定 s2a_gl_lib_ready），同 gfx/vk/vk_lib.h：
//   库 = <资源包>/shaders/direct/gl/gl_shaders.metallib + gl_shaders.tsv，表第一行「# s2arm-gl-lib <口径号>」；表格式 / 槽位 / 翻译选项改了加 1
#pragma once
#define S2A_GL_LIB_ABI 3       // 2（11-03）：采样器数组 t:<名>=<槽>:<类型>:<个数>；3：MSL 3.1（审计 #1534 P1-66，表格式不变）
#define S2A_GL_LIB_ABI_MIN 1   // 宿主照读的最老口径：口径 1 的表只是没有采样器数组项，其余格式相同
#define S2A_GL_LIB_TAG "# s2arm-gl-lib "
