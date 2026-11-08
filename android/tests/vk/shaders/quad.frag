#version 450
layout(location = 0) in vec4 vColor;
layout(location = 0) out vec4 oColor;
void main() {
    if (vColor.b > 0.5) oColor = vec4(0.0, 0.0, 1.0, 1.0);
    else if (vColor.r > 0.5) oColor = vec4(1.0, 0.0, 0.0, 1.0);
    else oColor = vec4(0.0, 1.0, 0.0, 1.0);
    oColor.a = vColor.a;
}
