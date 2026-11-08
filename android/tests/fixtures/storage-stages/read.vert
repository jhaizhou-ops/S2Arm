#version 450
layout(set=1,binding=0,std430) readonly buffer B { uint v; } b;
void main() { gl_Position = vec4(float(b.v)); }
