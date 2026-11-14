#version 450
// #977 零属性用例：location 3 没设格式，核心补一条全 0 属性；读到 (0,0,0,0) 输出红，否则蓝。
layout(location = 0) in vec4 aPos;
layout(location = 3) in vec4 aZero;
layout(location = 0) out vec4 vColor;
void main() { gl_Position = aPos; vColor = aZero == vec4(0.0) ? vec4(1.0, 0.0, 0.0, 1.0) : vec4(0.0, 0.0, 1.0, 1.0); }
