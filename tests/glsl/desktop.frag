#version 450 core
in vec3 tint;
in vec2 uv;
uniform sampler2D albedo;
layout(std140) uniform Settings { vec4 multiplier; } settings;
layout(std430) buffer Results { vec4 values[]; } results;
out vec4 color;
void main() {
    color = texture(albedo, uv) * settings.multiplier * vec4(tint, 1.0);
    results.values[0] = color;
}
