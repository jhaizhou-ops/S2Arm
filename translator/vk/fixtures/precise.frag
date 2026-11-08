#version 450
layout(location = 0) in vec4 value;
layout(location = 0) out vec4 color;
void main() {
    color = min(value, vec4(2.0)) + max(value, vec4(-2.0))
          + clamp(value, vec4(-3.0), vec4(3.0));
}
