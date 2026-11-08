#version 450
layout(set=1,binding=0,std430) buffer B { uint v; } b;
void main() { atomicAdd(b.v, 1); gl_Position = vec4(0.0); }
