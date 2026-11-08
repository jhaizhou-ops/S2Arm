#version 450
layout(location = 0) in vec4 vColor;
layout(location = 0) out vec4 o0;
layout(location = 1) out vec4 o1;
void main() {
    o0 = vColor;
    o1 = vec4(0.0, 1.0, 0.0, vColor.a);
}
