// GLSL ES 1.00, libGDX style (Slay the Spire shaders/*.fs): precision only under GL_ES, texture2D, gl_FragColor
#ifdef GL_ES
precision mediump float;
#endif
uniform sampler2D uTex;
varying vec2 vUV;
void main() { gl_FragColor = texture2D(uTex, vUV); }
