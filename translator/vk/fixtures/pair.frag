#version 450
layout(location = 0) in vec4 partial_value;
layout(location = 3) in vec4 missing_value;
layout(location = 0) out vec4 color;
void main() { color = partial_value + missing_value; }
