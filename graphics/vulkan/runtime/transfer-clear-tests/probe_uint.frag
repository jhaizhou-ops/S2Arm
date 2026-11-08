#version 450
layout(push_constant) uniform Color { uvec4 value; } color;
layout(location=0) out uvec4 result;
void main() { result = color.value; }
