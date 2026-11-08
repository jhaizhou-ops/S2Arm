#version 450
layout(location = 0) in vec4 aPos;
layout(location = 1) in vec4 aColor;
layout(location = 0) out vec4 vColor;
void main() { gl_Position = aPos; gl_PointSize = 1.0; vColor = aColor; }
