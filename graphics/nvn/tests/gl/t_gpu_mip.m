// #272：只经登记的 EGL / GL 入口写纹理、采样；链接生产宿主、NVN / Metal、真实 Widen。
// GLSL 由生产 gl_shaders.py 出库。期望来自显式 LOD、cube 六轴与 clear / uniform 的常量值；
// 结果统一画到 RGBA8 FBO，最后 GPU blit 读回。没有宿主 / 后端 / 宽屏替身。
#include "../../gfx/gl/gl_int.h"
#include <math.h>

#define API(ret, name, ...) static ret (*name)(__VA_ARGS__)
API(EGLDisplay, eglGetDisplay, void *);
API(EGLBoolean, eglInitialize, EGLDisplay, EGLint *, EGLint *);
API(EGLContext, eglCreateContext, EGLDisplay, EGLConfig, EGLContext, const EGLint *);
API(EGLBoolean, eglMakeCurrent, EGLDisplay, EGLSurface, EGLSurface, EGLContext);
API(EGLBoolean, eglDestroyContext, EGLDisplay, EGLContext);
API(void, glGenTextures, GLsizei, GLuint *);
API(void, glBindTexture, GLenum, GLuint);
API(void, glTexImage2D, GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
API(void, glCompressedTexImage2D, GLenum, GLint, GLenum, GLsizei, GLsizei, GLint, GLsizei, const void *);
API(void, glTexSubImage2D, GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *);
API(void, glTexParameteri, GLenum, GLenum, GLint);
API(void, glActiveTexture, GLenum);
API(void, glGenFramebuffers, GLsizei, GLuint *);
API(void, glBindFramebuffer, GLenum, GLuint);
API(void, glFramebufferTexture2D, GLenum, GLenum, GLenum, GLuint, GLint);
API(GLenum, glCheckFramebufferStatus, GLenum);
API(void, glViewport, GLint, GLint, GLsizei, GLsizei);
API(void, glClearColor, GLfloat, GLfloat, GLfloat, GLfloat);
API(void, glClearDepthf, GLfloat);
API(void, glClear, GLbitfield);
API(GLuint, glCreateShader, GLenum);
API(void, glShaderSource, GLuint, GLsizei, const GLchar *const *, const GLint *);
API(void, glCompileShader, GLuint);
API(void, glGetShaderiv, GLuint, GLenum, GLint *);
API(GLuint, glCreateProgram, void);
API(void, glAttachShader, GLuint, GLuint);
API(void, glLinkProgram, GLuint);
API(void, glGetProgramiv, GLuint, GLenum, GLint *);
API(void, glUseProgram, GLuint);
API(GLint, glGetAttribLocation, GLuint, const GLchar *);
API(GLint, glGetUniformLocation, GLuint, const GLchar *);
API(void, glUniform1i, GLint, GLint);
API(void, glUniform1f, GLint, GLfloat);
API(void, glUniform3f, GLint, GLfloat, GLfloat, GLfloat);
API(void, glUniform4f, GLint, GLfloat, GLfloat, GLfloat, GLfloat);
API(void, glGenVertexArrays, GLsizei, GLuint *);
API(void, glBindVertexArray, GLuint);
API(void, glGenBuffers, GLsizei, GLuint *);
API(void, glBindBuffer, GLenum, GLuint);
API(void, glBufferData, GLenum, GLsizeiptr, const void *, GLenum);
API(void, glVertexAttribPointer, GLuint, GLint, GLenum, GLuint, GLsizei, const void *);
API(void, glEnableVertexAttribArray, GLuint);
API(void, glDrawArrays, GLenum, GLint, GLsizei);
API(void, glFinish, void);
API(GLenum, glGetError, void);

enum { TEX2D = 0x0DE1, CUBE = 0x8513, PX = 0x8515, RGBA = 0x1908, UBYTE = 0x1401,
       FB = 0x8D40, COLOR = 0x8CE0, DEPTH = 0x8D00, MIN_FILTER = 0x2801, MAG_FILTER = 0x2800,
       BASE = 0x813C, MAX_LEVEL = 0x813D, MIP_NEAREST = 0x2700, NEAREST = 0x2600 };
static int checks, fails, cells;
static GLuint sample2d, samplecube, solid, src_fb, out_fb, out_tex;
static const uint8_t red[4] = {255,0,0,255}, green[4] = {0,255,0,255}, blue[4] = {0,0,255,255},
    yellow[4] = {255,255,0,255}, magenta[4] = {255,0,255,255};
static struct { uint8_t color[4]; char label[112]; } expected[128];
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("败 " __VA_ARGS__); putchar('\n'); } } while (0)
static void require(int ok, const char *what) { if (!ok) { fprintf(stderr, "失败：%s\n", what); exit(2); } }

static void load_api(void) {
#define LOAD(name) name = gl_lookup(#name); require(name != NULL, #name)
    LOAD(eglGetDisplay); LOAD(eglInitialize); LOAD(eglCreateContext); LOAD(eglMakeCurrent); LOAD(eglDestroyContext);
    LOAD(glGenTextures); LOAD(glBindTexture); LOAD(glTexImage2D); LOAD(glCompressedTexImage2D); LOAD(glTexSubImage2D); LOAD(glTexParameteri); LOAD(glActiveTexture);
    LOAD(glGenFramebuffers); LOAD(glBindFramebuffer); LOAD(glFramebufferTexture2D); LOAD(glCheckFramebufferStatus);
    LOAD(glViewport); LOAD(glClearColor); LOAD(glClearDepthf); LOAD(glClear); LOAD(glCreateShader); LOAD(glShaderSource);
    LOAD(glCompileShader); LOAD(glGetShaderiv); LOAD(glCreateProgram); LOAD(glAttachShader); LOAD(glLinkProgram);
    LOAD(glGetProgramiv); LOAD(glUseProgram); LOAD(glGetAttribLocation); LOAD(glGetUniformLocation);
    LOAD(glUniform1i); LOAD(glUniform1f); LOAD(glUniform3f); LOAD(glUniform4f); LOAD(glGenVertexArrays); LOAD(glBindVertexArray);
    LOAD(glGenBuffers); LOAD(glBindBuffer); LOAD(glBufferData); LOAD(glVertexAttribPointer); LOAD(glEnableVertexAttribArray);
    LOAD(glDrawArrays); LOAD(glFinish); LOAD(glGetError);
#undef LOAD
}
static GLuint shader(const char *file, GLenum stage) {
    char path[2048]; snprintf(path, sizeof path, "%s/%s", getenv("T_GPU_DIR"), file);
    FILE *f = fopen(path, "rb"); require(f != NULL, path);
    require(!fseek(f, 0, SEEK_END), "shader seek"); long n = ftell(f); require(n > 0, "shader size"); rewind(f);
    char *text = calloc((size_t)n + 1, 1); require(text != NULL, "shader allocation");
    require(fread(text, 1, (size_t)n, f) == (size_t)n, "shader read"); fclose(f);
    GLuint s = glCreateShader(stage); const GLchar *source = text; glShaderSource(s, 1, &source, NULL); free(text);
    glCompileShader(s); GLint ok = 0; glGetShaderiv(s, 0x8B81, &ok); require(ok == 1, file); return s;
}
static GLuint program(const char *fragment) {
    GLuint p = glCreateProgram(); glAttachShader(p, shader("gpu_mip.vert", 0x8B31));
    glAttachShader(p, shader(fragment, 0x8B30)); glLinkProgram(p);
    GLint ok = 0; glGetProgramiv(p, 0x8B82, &ok); require(ok == 1, fragment);
    GLint a = glGetAttribLocation(p, "aPos"); require(a >= 0, "aPos");
    glVertexAttribPointer((GLuint)a, 2, 0x1406, 0, 0, NULL); glEnableVertexAttribArray((GLuint)a); return p;
}
static void parameters(GLenum target, int max) {
    glTexParameteri(target, MIN_FILTER, MIP_NEAREST); glTexParameteri(target, MAG_FILTER, NEAREST);
    glTexParameteri(target, MAX_LEVEL, max);
}
static GLuint texture(GLenum target, GLint format, int levels, int depth) {
    GLuint t; glGenTextures(1, &t); glActiveTexture(0x84C0); glBindTexture(target, t);
    for (int face = 0; face < (target == CUBE ? 6 : 1); face++) for (int l = 0; l < levels; l++)
        glTexImage2D(target == CUBE ? PX + face : TEX2D, l, format, 8 >> l, 8 >> l, 0, depth ? 0x1902 : RGBA, depth ? 0x1406 : UBYTE, NULL);
    parameters(target, levels - 1); return t;
}
static void attachment(GLuint tex, GLenum target, int level, int depth) {
    glBindFramebuffer(FB, src_fb);
    glFramebufferTexture2D(FB, depth ? COLOR : DEPTH, TEX2D, 0, 0);
    glFramebufferTexture2D(FB, depth ? DEPTH : COLOR, target, tex, level);
    require(glCheckFramebufferStatus(FB) == 0x8CD5, "source FBO complete");
    glViewport(0, 0, 8 >> level, 8 >> level);
}
static void paint_value(GLuint tex, GLenum target, int level, const float c[4], int draw) {
    attachment(tex, target, level, 0);
    if (draw) {
        glUseProgram(solid); glUniform4f(glGetUniformLocation(solid, "uColor"), c[0], c[1], c[2], c[3]);
        glDrawArrays(4, 0, 3);
    } else { glClearColor(c[0], c[1], c[2], c[3]); glClear(0x4000); }
}
static void paint(GLuint tex, GLenum target, int level, const uint8_t c[4], int draw) {
    const float value[] = {c[0]/255.f, c[1]/255.f, c[2]/255.f, c[3]/255.f};
    paint_value(tex, target, level, value, draw);
}
static void sample(GLuint tex, int cube, int face, int lod, int depth, const uint8_t c[4], const char *label) {
    require(cells < 128, "output capacity"); glBindFramebuffer(FB, out_fb); glViewport(cells*8, 0, 8, 8);
    GLuint p = cube ? samplecube : sample2d; glUseProgram(p); glActiveTexture(0x84C0); glBindTexture(cube ? CUBE : TEX2D, tex);
    glUniform1i(glGetUniformLocation(p, cube ? "uCube" : "uTex"), 0); glUniform1f(glGetUniformLocation(p, "uLod"), lod);
    if (cube) {
        static const float dir[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
        glUniform3f(glGetUniformLocation(p, "uDir"), dir[face][0], dir[face][1], dir[face][2]);
    }
    glUniform1f(glGetUniformLocation(p, "uDepth"), depth);
    glDrawArrays(4, 0, 3); memcpy(expected[cells].color, c, 4);
    snprintf(expected[cells].label, sizeof expected[cells].label, "%s face=%d LOD=%d", label, face, lod); cells++;
}
static void two_dimensional(void) {
    GLuint t = texture(TEX2D, 0x8058, 3, 0);
    uint64_t seq = gl_seq_ref(), waits = atomic_load(&gl_wait_n);
    paint(t, TEX2D, 0, green, 0); paint(t, TEX2D, 1, red, 1); paint(t, TEX2D, 2, blue, 0);
    sample(t, 0, 0, 0, 0, green, "2D pending clear / draw"); sample(t, 0, 0, 1, 0, red, "2D mip1"); sample(t, 0, 0, 2, 0, blue, "2D last pending mip2");
    glTexParameteri(TEX2D, BASE, 1);
    sample(t, 0, 0, 0, 0, red, "2D base1"); sample(t, 0, 0, 1, 0, blue, "2D base1 mip2");
    glTexParameteri(TEX2D, BASE, 0); glTexParameteri(TEX2D, MAX_LEVEL, 1);
    sample(t, 0, 0, 1, 0, red, "2D max1"); glTexParameteri(TEX2D, MAX_LEVEL, 2);
    paint(t, TEX2D, 1, magenta, 1); sample(t, 0, 0, 1, 0, magenta, "2D draw into assembled level");
    CHECK(gl_seq_ref() == seq && atomic_load(&gl_wait_n) == waits, "2D组链发生了CPU提交或等待");
    glTexImage2D(TEX2D, 2, 0x8058, 2, 2, 0, RGBA, UBYTE, NULL);
    seq = gl_seq_ref(); waits = atomic_load(&gl_wait_n);
    paint(t, TEX2D, 2, yellow, 0);
    sample(t, 0, 0, 0, 0, green, "2D mixed old/new storage mip0");
    sample(t, 0, 0, 1, 0, magenta, "2D mixed old/new storage mip1");
    sample(t, 0, 0, 2, 0, yellow, "2D redefined mip2 pending clear");
    CHECK(gl_seq_ref() == seq && atomic_load(&gl_wait_n) == waits, "2D重定义后的组链发生了CPU提交或等待");
    // 上传确实需要与前序 GPU 写同步；只改 mip1，之前画出的结果和其他级仍须保全。
    uint8_t pixels[4*4*4]; for (size_t i = 0; i < sizeof pixels; i += 4) memcpy(pixels+i, blue, 4);
    glTexSubImage2D(TEX2D, 1, 0, 0, 4, 4, RGBA, UBYTE, pixels);
    sample(t, 0, 0, 0, 0, green, "2D upload keeps mip0"); sample(t, 0, 0, 1, 0, blue, "2D upload replaces mip1"); sample(t, 0, 0, 2, 0, yellow, "2D upload keeps mip2");
}
static const uint8_t cube_colors[3][6][4] = {
    {{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,0,255},{0,255,255,255},{255,0,255,255}},
    {{0,255,255,255},{255,0,255,255},{255,255,0,255},{0,0,255,255},{255,0,0,255},{0,255,0,255}},
    {{255,255,255,255},{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,0,255},{0,255,255,255}}
};
static void cubes(void) {
    GLuint t = texture(CUBE, 0x8058, 3, 0); uint64_t seq = gl_seq_ref(), waits = atomic_load(&gl_wait_n);
    for (int l = 0; l < 3; l++) for (int s = 0; s < 6; s++) paint(t, PX+s, l, cube_colors[l][s], s == 2 && l == 1);
    for (int l = 0; l < 3; l++) for (int s = 0; s < 6; s++) sample(t, 1, s, l, 0, cube_colors[l][s], "cube face/level");
    glTexParameteri(CUBE, BASE, 1);
    for (int l = 0; l < 2; l++) for (int s = 0; s < 6; s++) sample(t, 1, s, l, 0, cube_colors[l+1][s], "cube base1");
    glTexParameteri(CUBE, BASE, 0); glTexParameteri(CUBE, MAX_LEVEL, 0);
    for (int s = 0; s < 6; s++) sample(t, 1, s, 0, 0, cube_colors[0][s], "cube single level");
    glTexParameteri(CUBE, MAX_LEVEL, 2); paint(t, PX+4, 1, blue, 1);
    sample(t, 1, 4, 1, 0, blue, "cube rewritten assembled face");
    CHECK(gl_seq_ref() == seq && atomic_load(&gl_wait_n) == waits, "cube组链发生了CPU提交或等待");
    glTexImage2D(PX+3, 2, 0x8058, 2, 2, 0, RGBA, UBYTE, NULL); paint(t, PX+3, 2, yellow, 0);
    seq = gl_seq_ref(); waits = atomic_load(&gl_wait_n);
    sample(t, 1, 3, 2, 0, yellow, "cube redefined pending face");
    sample(t, 1, 4, 1, 0, blue, "cube reassembly keeps other face/level");
    CHECK(gl_seq_ref() == seq && atomic_load(&gl_wait_n) == waits, "cube重定义后的组链发生了CPU提交或等待");
    const uint8_t pixels[16] = {255,0,255,255,255,0,255,255,255,0,255,255,255,0,255,255};
    glTexSubImage2D(PX+1, 2, 0, 0, 2, 2, RGBA, UBYTE, pixels);
    sample(t, 1, 1, 2, 0, magenta, "cube uploaded face"); sample(t, 1, 3, 2, 0, yellow, "cube upload keeps other face");
}
static void formats(void) {
    static const struct { GLint internal; uint8_t value[4]; const char *name; } formats[] = {
        {0x8229,{64,0,0,255},"R8"}, {0x822B,{64,128,0,255},"RG8"},
        {0x881A,{64,128,191,255},"RGBA16F"}, {0x8814,{64,128,191,255},"RGBA32F"},
        {0x8059,{64,128,191,255},"RGB10_A2"}, {0x805B,{64,128,191,255},"RGBA16"},
        {0x8C3A,{64,128,191,255},"R11F_G11F_B10F"}, {0x8C43,{0,255,0,255},"SRGB8_ALPHA8"}
    };
    for (size_t i = 0; i < sizeof formats/sizeof formats[0]; i++) {
        GLuint t = texture(TEX2D, formats[i].internal, 2, 0); uint64_t seq = gl_seq_ref(), waits = atomic_load(&gl_wait_n);
        // 二进制可精确表示的 .25/.5/.75 在 R11/G11/B10 浮点中也精确；
        // 不能把 191/255 当成 .75，再忽略较低尾数位宽的存储量化。
        const float linear[] = {.25f,.5f,.75f,1}, srgb[] = {0,1,0,1};
        const float *input = formats[i].internal == 0x8C43 ? srgb : linear;
        paint_value(t, TEX2D, 0, input, 1); paint_value(t, TEX2D, 1, input, 0);
        for (int l = 0; l < 2; l++) sample(t, 0, 0, l, 0, formats[i].value, formats[i].name);
        CHECK(gl_seq_ref() == seq && atomic_load(&gl_wait_n) == waits, "%s组链提交或等待", formats[i].name);
    }
    const GLint depths[] = {0x81A5,0x8CAC,0x8CAD};
    for (size_t i = 0; i < sizeof depths/sizeof depths[0]; i++) {
        GLuint t = texture(TEX2D, depths[i], 2, 1); uint64_t seq = gl_seq_ref(), waits = atomic_load(&gl_wait_n);
        for (int l = 0; l < 2; l++) { attachment(t, TEX2D, l, 1); glClearDepthf(l ? .75f : .25f); glClear(0x100); }
        const uint8_t a[4] = {64,64,64,255}, b[4] = {191,191,191,255};
        sample(t, 0, 0, 0, 1, a, "private depth mip0"); sample(t, 0, 0, 1, 1, b, "private depth mip1");
        CHECK(gl_seq_ref() == seq && atomic_load(&gl_wait_n) == waits, "private深度组链提交或等待");
    }
    GLuint cube = texture(CUBE, 0x8CAC, 2, 1); uint64_t seq = gl_seq_ref(), waits = atomic_load(&gl_wait_n);
    for (int l = 0; l < 2; l++) for (int s = 0; s < 6; s++) {
        attachment(cube, PX+s, l, 1); glClearDepthf((l ? 7-s : s+1)/8.f); glClear(0x100);
    }
    for (int l = 0; l < 2; l++) for (int s = 0; s < 6; s++) {
        int numerator = l ? 7-s : s+1; uint8_t value = (uint8_t)((numerator*255+4)/8);
        const uint8_t color[] = {value,value,value,255};
        sample(cube, 1, s, l, 1, color, "private depth cube");
    }
    CHECK(gl_seq_ref() == seq && atomic_load(&gl_wait_n) == waits, "private深度cube组链提交或等待");
    // BC1 RGB 每级一个块：endpoint0 为红 / 绿，所有 selector=0；RGB 采样 alpha 必须为 1。
    // 第二级 2×2 小于一个块，验证 whole-surface blit 对压缩 mip 尾部的处理与换位视图。
    GLuint compressed; glGenTextures(1,&compressed); glBindTexture(TEX2D,compressed);
    const uint8_t blocks[2][8] = {{0,0xf8,0,0,0,0,0,0},{0xe0,7,0,0,0,0,0,0}};
    for (int l = 0; l < 2; l++) glCompressedTexImage2D(TEX2D,l,0x83F0,4 >> l,4 >> l,0,8,blocks[l]);
    parameters(TEX2D,1); seq = gl_seq_ref(); waits = atomic_load(&gl_wait_n);
    sample(compressed,0,0,0,0,red,"BC1 RGB swizzle mip0"); sample(compressed,0,0,1,0,green,"BC1 RGB tail mip1");
    CHECK(gl_seq_ref() == seq && atomic_load(&gl_wait_n) == waits, "压缩纹理组链提交或等待");
}
static void verify(void) {
    glFinish(); GLenum error = glGetError(); CHECK(error == 0, "GL error=%#x", error);
    id<MTLTexture> image = gl_tex_mtl(out_tex, 0); require(image != nil, "output Metal texture");
    id<MTLBuffer> bytes = [gl_dev newBufferWithLength:1024*8*4 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [gl_dev newCommandQueue]; id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(1024,8,1)
                 toBuffer:bytes destinationOffset:0 destinationBytesPerRow:4096 destinationBytesPerImage:32768];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted]; require(cb.status == MTLCommandBufferStatusCompleted && !cb.error, "readback GPU completion");
    const uint8_t *data = bytes.contents;
    for (int i = 0; i < cells; i++) {
        const uint8_t *p = data + (4*1024 + i*8+4)*4, *e = expected[i].color;
        CHECK(abs((int)p[0]-e[0]) <= 1 && abs((int)p[1]-e[1]) <= 1 && abs((int)p[2]-e[2]) <= 1 && abs((int)p[3]-e[3]) <= 1,
              "%s：期望{%u,%u,%u,%u} 实际{%u,%u,%u,%u}", expected[i].label, e[0],e[1],e[2],e[3],p[0],p[1],p[2],p[3]);
    }
    uint64_t badfeat, baderr; dm_gl_bad_draws(&badfeat, &baderr); CHECK(!badfeat && !baderr, "坏绘制：feature=%llu error=%llu", (unsigned long long)badfeat, (unsigned long long)baderr);
}
int main(void) { @autoreleasepool {
    load_api(); EGLDisplay d = eglGetDisplay(NULL); require(eglInitialize(d, NULL, NULL), "eglInitialize");
    EGLContext c = eglCreateContext(d, (EGLConfig)1, NULL, NULL); require(c != NULL && eglMakeCurrent(d,NULL,NULL,c), "EGL context");
    gl_dev_init(); printf("GPU %s，真实宿主/NVN/Widen，宽屏环境=%s\n", gl_dev.name.UTF8String, getenv("S2A_WIDEN_DIRECT") ?: "0");
    GLuint vao, vbo; glGenVertexArrays(1,&vao); glBindVertexArray(vao); glGenBuffers(1,&vbo); glBindBuffer(0x8892,vbo);
    const float pos[] = {-1,-1,3,-1,-1,3}; glBufferData(0x8892,sizeof pos,pos,0x88E4);
    sample2d = program("gpu_mip.frag"); samplecube = program("gpu_cube.frag"); solid = program("gpu_solid.frag");
    glGenFramebuffers(1,&src_fb); glGenFramebuffers(1,&out_fb); glGenTextures(1,&out_tex); glBindTexture(TEX2D,out_tex);
    glTexImage2D(TEX2D,0,0x8058,1024,8,0,RGBA,UBYTE,NULL); glBindFramebuffer(FB,out_fb);
    glFramebufferTexture2D(FB,COLOR,TEX2D,out_tex,0); require(glCheckFramebufferStatus(FB)==0x8CD5,"output FBO complete");
    glClearColor(0,0,0,0); glClear(0x4000);
    two_dimensional(); cubes(); formats(); verify(); eglDestroyContext(d,c);
    printf("%s t_gpu_mip：%d/%d，%d个GPU像素期望\n", fails ? "✗" : "✓", checks-fails,checks,cells); return fails ? 1 : 0;
} }
