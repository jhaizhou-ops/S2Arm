#version 320 es
precision highp float;
precision highp samplerCubeShadow;
uniform samplerCubeShadow uShadow;
uniform vec3 uDir;
uniform float uRef;
out vec4 color;
void main() {
    float pass = texture(uShadow, vec4(uDir, uRef));
    color = vec4(pass, pass, pass, 1.0);
}
