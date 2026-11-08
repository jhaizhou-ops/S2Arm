#version 450
// 片元阶段的常量缓冲动态下标（fp_c4：NVN 槽 1）与常量下标（静态可证在界内，不动）
layout(std140, set = 0, binding = 3) uniform U4 { vec4 data[4096]; } fp_c4;
layout(location = 0) flat in uint idx;
layout(location = 0) out vec4 color;
void main() {
    color = fp_c4.data[idx] + fp_c4.data[2];
}
