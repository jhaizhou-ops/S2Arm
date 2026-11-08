#version 450
layout(location = 0) out vec4 oColor;
layout(push_constant) uniform PC { vec4 col; } pc;
void main() { oColor = pc.col; }
