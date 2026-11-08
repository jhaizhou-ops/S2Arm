#version 450
layout(location = 0) flat in uvec4 v;
layout(location = 0) out uvec4 o;
void main() { o = v; }
