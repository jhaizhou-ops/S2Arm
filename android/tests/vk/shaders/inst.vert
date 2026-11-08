#version 450
layout(location = 0) in vec4 aPos;
layout(location = 1) in vec4 aColor;
layout(location = 0) out vec4 vColor;
void main() { vec4 p = aPos; p.x += float(gl_InstanceIndex); gl_Position = p; vColor = aColor; }
