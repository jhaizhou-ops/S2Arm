#version 450 core
in vec3 position;
in vec2 texcoord;
out vec2 uv;
out vec3 tint;
layout(std140) uniform Camera { mat4 vp; } camera;
uniform float exposure;
void main() {
    uv = texcoord;
    tint = vec3(exposure);
    gl_Position = camera.vp * vec4(position, 1.0);
    if (position.x < -100.0) return;
    gl_Position.z += 0.0;
}
