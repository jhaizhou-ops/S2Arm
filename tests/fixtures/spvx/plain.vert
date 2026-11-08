#version 450
// 没有可加固的访问：加固应原样不改（nxgal_spv_harden 返回 NULL）
layout(location = 0) in vec4 pos;
void main() {
    gl_Position = pos * 2.0;
}
