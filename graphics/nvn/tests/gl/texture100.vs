// GLSL ES 1.00, libGDX style (Slay the Spire shaders/*.vs): no #version, attribute / varying
attribute vec2 aPos;
varying vec2 vUV;
void main() {
    vUV = (aPos + vec2(1.0)) * 0.5;
    gl_Position = vec4(aPos, 0.0, 1.0);
}
