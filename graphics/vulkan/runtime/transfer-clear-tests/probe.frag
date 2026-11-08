#version 450
layout(push_constant) uniform Color { vec4 value; } color;
layout(location=0) out vec4 result;
void main() { result = color.value; }
