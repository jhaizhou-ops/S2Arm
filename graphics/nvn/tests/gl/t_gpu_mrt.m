// #272 MRT 的真实 EGL / OpenGL → Metal GPU 回归。
// 着色器由生产 gl_shaders.py 离线出库；GL 调用均经 gl_lookup 指向生产实现。
// 期望由路由、uniform、初始纹理内容和 GL 混合公式独立计算，末尾统一 Metal blit 读回。
#include "../../gfx/gl/gl_int.h"
#include <math.h>
#include <stdint.h>

#define API(ret, name, ...) static ret (*name)(__VA_ARGS__)
API(EGLDisplay, eglGetDisplay, void *);
API(EGLBoolean, eglInitialize, EGLDisplay, EGLint *, EGLint *);
API(EGLBoolean, eglBindAPI, EGLenum);
API(EGLContext, eglCreateContext, EGLDisplay, EGLConfig, EGLContext, const EGLint *);
API(EGLBoolean, eglMakeCurrent, EGLDisplay, EGLSurface, EGLSurface, EGLContext);
API(EGLBoolean, eglDestroyContext, EGLDisplay, EGLContext);
API(void, glGenTextures, GLsizei, GLuint *);
API(void, glBindTexture, GLenum, GLuint);
API(void, glTexImage2D, GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
API(void, glTexParameteri, GLenum, GLenum, GLint);
API(void, glGenFramebuffers, GLsizei, GLuint *);
API(void, glBindFramebuffer, GLenum, GLuint);
API(void, glFramebufferTexture2D, GLenum, GLenum, GLenum, GLuint, GLint);
API(GLenum, glCheckFramebufferStatus, GLenum);
API(void, glDrawArrays, GLenum, GLint, GLsizei);
API(void, glViewport, GLint, GLint, GLsizei, GLsizei);
API(void, glScissor, GLint, GLint, GLsizei, GLsizei);
API(void, glEnable, GLenum);
API(void, glDisable, GLenum);
API(void, glClearColor, GLfloat, GLfloat, GLfloat, GLfloat);
API(void, glClearDepthf, GLfloat);
API(void, glClearStencil, GLint);
API(void, glClear, GLbitfield);
API(void, glDepthFunc, GLenum);
API(void, glDepthMask, GLuint);
API(void, glStencilFunc, GLenum, GLint, GLuint);
API(void, glStencilOp, GLenum, GLenum, GLenum);
API(void, glColorMask, GLuint, GLuint, GLuint, GLuint);
API(GLenum, glGetError, void);
API(void, glGetIntegerv, GLenum, GLint *);
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
API(void, glUniform1f, GLint, GLfloat);
API(void, glUniform2f, GLint, GLfloat, GLfloat);
API(void, glUniform4f, GLint, GLfloat, GLfloat, GLfloat, GLfloat);
API(void, glUniform4fv, GLint, GLsizei, const GLfloat *);
API(void, glGenVertexArrays, GLsizei, GLuint *);
API(void, glBindVertexArray, GLuint);
API(void, glGenBuffers, GLsizei, GLuint *);
API(void, glBindBuffer, GLenum, GLuint);
API(void, glBufferData, GLenum, GLsizeiptr, const void *, GLenum);
API(void, glVertexAttribPointer, GLuint, GLint, GLenum, GLboolean, GLsizei, const void *);
API(void, glEnableVertexAttribArray, GLuint);
API(void, glFinish, void);
API(void, glGenRenderbuffers, GLsizei, GLuint *);
API(void, glBindRenderbuffer, GLenum, GLuint);
API(void, glRenderbufferStorage, GLenum, GLenum, GLsizei, GLsizei);
API(void, glFramebufferRenderbuffer, GLenum, GLenum, GLenum, GLuint);
API(void, glGetBooleani_v, GLenum, GLuint, GLboolean *);
API(void, glGetIntegeri_v, GLenum, GLuint, GLint *);
API(GLboolean, glIsEnabledi, GLenum, GLuint);
API(void, glEnablei, GLenum, GLuint);
API(void, glDisablei, GLenum, GLuint);
API(void, glBlendFuncSeparate, GLenum, GLenum, GLenum, GLenum);
API(void, glBlendEquationSeparate, GLenum, GLenum);
API(void, glBlendFuncSeparatei, GLuint, GLenum, GLenum, GLenum, GLenum);
API(void, glBlendEquationSeparatei, GLuint, GLenum, GLenum);
API(void, glColorMaski, GLuint, GLuint, GLuint, GLuint, GLuint);
API(void, glDrawBuffers, GLsizei, const GLenum *);
API(void, glDrawBuffer, GLenum);

enum {
    EGL_OPENGL_ES_API = 0x30A0, EGL_OPENGL_API = 0x30A2,
    GL_TEXTURE_2D = 0x0DE1, GL_RGBA = 0x1908, GL_UNSIGNED_BYTE = 0x1401,
    GL_RGBA8 = 0x8058, GL_R8 = 0x8229, GL_RG8 = 0x822B, GL_RGBA16F = 0x881A, GL_RGBA32F = 0x8814,
    GL_TEXTURE_MIN_FILTER = 0x2801, GL_TEXTURE_MAG_FILTER = 0x2800, GL_NEAREST = 0x2600,
    GL_FRAMEBUFFER = 0x8D40, GL_COLOR_ATTACHMENT0 = 0x8CE0, GL_DEPTH_STENCIL_ATTACHMENT = 0x821A,
    GL_DEPTH_ATTACHMENT = 0x8D00, GL_STENCIL_ATTACHMENT = 0x8D20, GL_DEPTH_COMPONENT24 = 0x81A6,
    GL_RENDERBUFFER = 0x8D41, GL_DEPTH24_STENCIL8 = 0x88F0,
    GL_FRAMEBUFFER_COMPLETE = 0x8CD5, GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT = 0x8CD6,
    GL_TRIANGLES = 4, GL_ARRAY_BUFFER = 0x8892, GL_STATIC_DRAW = 0x88E4,
    GL_COLOR_BUFFER_BIT = 0x4000, GL_DEPTH_BUFFER_BIT = 0x0100, GL_STENCIL_BUFFER_BIT = 0x0400,
    GL_SCISSOR_TEST = 0x0C11, GL_BLEND = 0x0BE2, GL_DEPTH_TEST = 0x0B71, GL_STENCIL_TEST = 0x0B90,
    GL_COLOR_WRITEMASK = 0x0C23, GL_DRAW_BUFFER0 = 0x8825,
    GL_BLEND_EQUATION_RGB = 0x8009, GL_BLEND_EQUATION_ALPHA = 0x883D,
    GL_BLEND_SRC_RGB = 0x80C9, GL_BLEND_DST_RGB = 0x80C8,
    GL_BLEND_SRC_ALPHA = 0x80CB, GL_BLEND_DST_ALPHA = 0x80CA,
    GL_NONE = 0, GL_ZERO = 0, GL_ONE = 1, GL_SRC_COLOR = 0x0300, GL_ONE_MINUS_SRC_COLOR = 0x0301,
    GL_SRC_ALPHA = 0x0302, GL_ONE_MINUS_SRC_ALPHA = 0x0303, GL_DST_ALPHA = 0x0304,
    GL_ONE_MINUS_DST_ALPHA = 0x0305, GL_DST_COLOR = 0x0306, GL_ONE_MINUS_DST_COLOR = 0x0307,
    GL_FUNC_ADD = 0x8006, GL_MIN = 0x8007, GL_MAX = 0x8008, GL_FUNC_SUBTRACT = 0x800A,
    GL_FUNC_REVERSE_SUBTRACT = 0x800B, GL_BACK = 0x0405, GL_BACK_LEFT = 0x0402,
    GL_INVALID_ENUM = 0x0500, GL_INVALID_VALUE = 0x0501, GL_INVALID_OPERATION = 0x0502
};

#define N 8
#define MAX_PIXELS 1024
#define BLIT_SLOT 256
typedef struct { GLuint fbo, tex[N]; GLsizei w[N], h[N]; } bank;
typedef struct {
    __strong id<MTLTexture> image;
    NSUInteger x, y;
    MTLPixelFormat format;
    float want[4];
    char label[112];
} pixel_expect;

static pixel_expect expected[MAX_PIXELS];
static int expected_n, checks, fails;
static GLuint vao, vbo, control_program, mrt_program;
static GLint control_off, control_tint, mrt_z, mrt_colors;
static EGLDisplay display;
static EGLContext desktop_context;

static const float blue[4] = {0, 0, 1, 1};
static const float colors[N][4] = {
    {1,0,0,1}, {0,1,0,1}, {0,0,1,1}, {1,1,0,1},
    {1,0,1,1}, {0,1,1,1}, {1,1,1,1}, {0,0,0,1}
};
static const float rotated[N][4] = {
    {0,1,1,1}, {1,0,0,1}, {0,0,0,1}, {0,1,0,1},
    {1,1,1,1}, {0,0,1,1}, {1,0,1,1}, {1,1,0,1}
};

#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; fprintf(stderr, "败："); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)
static void require(int ok, const char *what) { if (!ok) { fprintf(stderr, "失败：%s\n", what); exit(2); } }

static void load_core_api(void) {
#define LOAD(name) do { name = (__typeof__(name))gl_lookup(#name); require(name != NULL, #name); } while (0)
    LOAD(eglGetDisplay); LOAD(eglInitialize); LOAD(eglBindAPI); LOAD(eglCreateContext); LOAD(eglMakeCurrent); LOAD(eglDestroyContext);
    LOAD(glGenTextures); LOAD(glBindTexture); LOAD(glTexImage2D); LOAD(glTexParameteri);
    LOAD(glGenFramebuffers); LOAD(glBindFramebuffer); LOAD(glFramebufferTexture2D); LOAD(glCheckFramebufferStatus);
    LOAD(glDrawArrays); LOAD(glViewport); LOAD(glScissor); LOAD(glEnable); LOAD(glDisable); LOAD(glClearColor); LOAD(glClearDepthf);
    LOAD(glClearStencil); LOAD(glClear); LOAD(glDepthFunc); LOAD(glDepthMask); LOAD(glStencilFunc); LOAD(glStencilOp); LOAD(glColorMask); LOAD(glGetError); LOAD(glGetIntegerv);
    LOAD(glCreateShader); LOAD(glShaderSource); LOAD(glCompileShader); LOAD(glGetShaderiv); LOAD(glCreateProgram); LOAD(glAttachShader);
    LOAD(glLinkProgram); LOAD(glGetProgramiv); LOAD(glUseProgram); LOAD(glGetAttribLocation); LOAD(glGetUniformLocation);
    LOAD(glUniform1f); LOAD(glUniform2f); LOAD(glUniform4f); LOAD(glUniform4fv); LOAD(glGenVertexArrays); LOAD(glBindVertexArray);
    LOAD(glGenBuffers); LOAD(glBindBuffer); LOAD(glBufferData); LOAD(glVertexAttribPointer); LOAD(glEnableVertexAttribArray); LOAD(glFinish);
    LOAD(glGenRenderbuffers); LOAD(glBindRenderbuffer); LOAD(glRenderbufferStorage); LOAD(glFramebufferRenderbuffer);
#undef LOAD
}

static int load_mrt_api(void) {
    int missing = 0;
#define OPTIONAL(name) do { name = (__typeof__(name))gl_lookup(#name); if (!name) { printf("缺少 GL 入口：%s\n", #name); missing++; } } while (0)
    OPTIONAL(glDrawBuffers); OPTIONAL(glDrawBuffer); OPTIONAL(glGetBooleani_v); OPTIONAL(glGetIntegeri_v); OPTIONAL(glIsEnabledi);
    OPTIONAL(glEnablei); OPTIONAL(glDisablei); OPTIONAL(glBlendFuncSeparate); OPTIONAL(glBlendEquationSeparate);
    OPTIONAL(glBlendFuncSeparatei); OPTIONAL(glBlendEquationSeparatei); OPTIONAL(glColorMaski);
#undef OPTIONAL
    return missing;
}

static void drain_errors(void) { for (int i = 0; i < 16 && glGetError(); i++) {} }
static void expect_error(GLenum want, const char *label) {
    GLenum got = glGetError(); CHECK(got == want, "%s GL error 期望 %#x，实际 %#x", label, want, got); drain_errors();
}
static void expect_no_error(const char *label) {
    GLenum got = glGetError(); CHECK(got == 0, "%s GL error=%#x", label, got); drain_errors();
}

static char *read_file(const char *name) {
    const char *dir = getenv("T_GPU_DIR"); require(dir != NULL, "T_GPU_DIR");
    char path[2048]; snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "rb"); require(f != NULL, path);
    require(!fseek(f, 0, SEEK_END), "shader seek"); long len = ftell(f); require(len > 0, "shader length"); rewind(f);
    char *text = calloc((size_t)len + 1, 1); require(text != NULL, "shader memory");
    require(fread(text, 1, (size_t)len, f) == (size_t)len, "shader read"); fclose(f); return text;
}

static GLuint compile_shader(const char *file, GLenum stage) {
    char *text = read_file(file); GLuint shader = glCreateShader(stage); const GLchar *source = text;
    glShaderSource(shader, 1, &source, NULL); free(text); glCompileShader(shader);
    GLint ok = 0; glGetShaderiv(shader, 0x8B81, &ok); require(ok == 1, file); return shader;
}

static GLuint make_program(const char *vert, const char *frag, int control) {
    GLuint p = glCreateProgram(); glAttachShader(p, compile_shader(vert, 0x8B31)); glAttachShader(p, compile_shader(frag, 0x8B30)); glLinkProgram(p);
    GLint ok = 0; glGetProgramiv(p, 0x8B82, &ok); require(ok == 1, frag); glUseProgram(p);
    GLint pos = glGetAttribLocation(p, "aPos"); require(pos >= 0, "aPos location");
    glVertexAttribPointer((GLuint)pos, 2, 0x1406, 0, 5 * (GLsizei)sizeof(float), NULL); glEnableVertexAttribArray((GLuint)pos);
    if (control) {
        GLint col = glGetAttribLocation(p, "aCol"); require(col >= 0, "aCol location");
        glVertexAttribPointer((GLuint)col, 3, 0x1406, 0, 5 * (GLsizei)sizeof(float), (const void *)(uintptr_t)(2 * sizeof(float)));
        glEnableVertexAttribArray((GLuint)col);
        control_off = glGetUniformLocation(p, "uOff"); control_tint = glGetUniformLocation(p, "uTint");
        require(control_off >= 0 && control_tint >= 0, "control uniforms");
    } else {
        mrt_z = glGetUniformLocation(p, "uZ"); mrt_colors = glGetUniformLocation(p, "uColors");
        require(mrt_z >= 0 && mrt_colors >= 0, "MRT uniforms");
    }
    return p;
}

static void setup_geometry(void) {
    static const float vertices[] = {
        -1,-1, 1,1,1,
         3,-1, 1,1,1,
        -1, 3, 1,1,1
    };
    glGenVertexArrays(1, &vao); glBindVertexArray(vao); glGenBuffers(1, &vbo); glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof vertices, vertices, GL_STATIC_DRAW);
}

static bank make_bank(const GLsizei widths[N], const GLsizei heights[N], const GLint formats[N], int attach_all) {
    bank b = {0}; glGenFramebuffers(1, &b.fbo); glBindFramebuffer(GL_FRAMEBUFFER, b.fbo);
    static uint8_t init[32 * 32 * 4]; static uint32_t packed[32 * 32];
    for (int i = 0; i < 32 * 32; i++) { init[i*4] = 0; init[i*4+1] = 0; init[i*4+2] = 255; init[i*4+3] = 255; packed[i] = 0xfff00000u; }
    for (int i = 0; i < N; i++) {
        b.w[i] = widths ? widths[i] : 16; b.h[i] = heights ? heights[i] : 16;
        require(b.w[i] > 0 && b.h[i] > 0 && b.w[i] <= 32 && b.h[i] <= 32, "bank dimensions");
        glGenTextures(1, &b.tex[i]); glBindTexture(GL_TEXTURE_2D, b.tex[i]);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        GLint format = formats ? formats[i] : GL_RGBA8;
        // RGB10_A2 用对应的 2_10_10_10_REV 源数据，蓝色 B=1023 / A=3；不依赖额外上传转换。
        glTexImage2D(GL_TEXTURE_2D, 0, format, b.w[i], b.h[i], 0, GL_RGBA, format == 0x8059 ? 0x8368 : GL_UNSIGNED_BYTE, format == 0x8059 ? (const void *)packed : init);
        if (attach_all || i == 0) glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + i, GL_TEXTURE_2D, b.tex[i], 0);
    }
    if (attach_all) {
        GLenum route[N]; for (int i = 0; i < N; i++) route[i] = GL_COLOR_ATTACHMENT0 + i;
        glDrawBuffers(N, route);
    }
    CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "bank FBO complete");
    expect_no_error("bank setup"); return b;
}

static bank make_rgba_bank(void) { return make_bank(NULL, NULL, NULL, 1); }

static void set_viewport(int w, int h) { glViewport(0, 0, w, h); }
static void use_mrt(const float value[N][4], float z) {
    glUseProgram(mrt_program); glUniform1f(mrt_z, z); glUniform4fv(mrt_colors, N, &value[0][0]);
    glDrawArrays(GL_TRIANGLES, 0, 3);
}
static void use_control(void) {
    glUseProgram(control_program); glUniform2f(control_off, 0, 0); glUniform4f(control_tint, 1, 0, 0, 1);
    glDrawArrays(GL_TRIANGLES, 0, 3);
}

static void add_image_pixel(id<MTLTexture> image, NSUInteger x, NSUInteger y, const float want[4], const char *label) {
    if (!image || expected_n >= MAX_PIXELS) { CHECK(0, "%s: no image / expectation capacity", label); return; }
    pixel_expect *e = &expected[expected_n++]; e->image = image; e->x = x; e->y = y; e->format = image.pixelFormat;
    memcpy(e->want, want, sizeof e->want); strlcpy(e->label, label, sizeof e->label);
}
static void add_tex_pixel(GLuint tex, NSUInteger x, NSUInteger y, const float want[4], const char *label) {
    add_image_pixel(gl_tex_mtl(tex, 0), x, y, want, label);
}
static void add_bank_center(const bank *b, const float want[N][4], const char *label) {
    for (int i = 0; i < N; i++) { char name[112]; snprintf(name, sizeof name, "%s ATT%d", label, i); add_tex_pixel(b->tex[i], 2, 2, want[i], name); }
}
static void expect_routes(const GLenum route[N], const char *label) {
    for (int i = 0; i < N; i++) { GLint got = -1; glGetIntegerv(GL_DRAW_BUFFER0 + i, &got); CHECK((GLenum)got == route[i], "%s route[%d] 期望 %#x 实际 %#x", label, i, route[i], (GLenum)got); }
}
static void fill_blue(float out[N][4]) { for (int i = 0; i < N; i++) memcpy(out[i], blue, sizeof blue); }
static void mapped_colors(float out[N][4], const GLenum route[N], const float src[N][4]) {
    fill_blue(out); for (int i = 0; i < N; i++) if (route[i] >= GL_COLOR_ATTACHMENT0 && route[i] < GL_COLOR_ATTACHMENT0 + N)
        memcpy(out[route[i] - GL_COLOR_ATTACHMENT0], src[i], sizeof out[0]);
}

static void probe_single_target_control(void) {
    GLint widths[N], heights[N], formats[N]; for (int i = 0; i < N; i++) { widths[i] = heights[i] = 16; formats[i] = GL_RGBA8; }
    bank b = make_bank(widths, heights, formats, 0); glBindFramebuffer(GL_FRAMEBUFFER, b.fbo); set_viewport(16, 16);
    glUseProgram(control_program); use_control(); const float red[4] = {1,0,0,1}; add_tex_pixel(b.tex[0], 8, 8, red, "单附件真实 GPU 控制");
    printf("单附件控制：已发出 tri GLSL 绘制，使用生产 GL / NVN / Metal 宿主。\n");
}

static void probe_each_color_attachment(void) {
    GLuint fbo; glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    for (int i = 0; i < N; i++) {
        GLuint tex; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 8, 8, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + i, GL_TEXTURE_2D, tex, 0);
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER); GLenum error = glGetError();
        CHECK(status == GL_FRAMEBUFFER_COMPLETE && error == 0, "ATT%d 独立 FBO completeness status=%#x error=%#x", i, status, error);
        printf("ATT%d 独立 FBO：status=%#x error=%#x\n", i, status, error); drain_errors();
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + i, GL_TEXTURE_2D, 0, 0);
    }
}

static void identity_and_permutation(void) {
    GLenum identity[N]; for (int i = 0; i < N; i++) identity[i] = GL_COLOR_ATTACHMENT0 + i;
    bank a = make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER, a.fbo); set_viewport(16,16); glDrawBuffers(N, identity);
    use_mrt(colors, 0); add_bank_center(&a, colors, "identity 八路颜色");

    bank b = make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER, b.fbo); set_viewport(16,16);
    const GLenum perm[N] = {GL_COLOR_ATTACHMENT0+7, GL_COLOR_ATTACHMENT0+2, GL_NONE, GL_COLOR_ATTACHMENT0+5,
                            GL_COLOR_ATTACHMENT0+0, GL_NONE, GL_COLOR_ATTACHMENT0+6, GL_COLOR_ATTACHMENT0+3};
    glDrawBuffers(N, perm); expect_routes(perm, "desktop permutation with NONE"); use_mrt(colors, 0);
    float want[N][4]; mapped_colors(want, perm, colors); add_bank_center(&b, want, "任意置换和 NONE 洞");
}

static void none_restore_and_unbound(void) {
    GLenum none[N] = {0}; bank a = make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER, a.fbo); set_viewport(16,16);
    glDrawBuffers(0, NULL); expect_routes(none, "DrawBuffers(0,NULL)"); use_mrt(colors, 0); expect_no_error("all NONE draw");
    float unchanged[N][4]; fill_blue(unchanged); add_bank_center(&a, unchanged, "全 NONE 不写附件");

    GLenum identity[N]; for (int i = 0; i < N; i++) identity[i] = GL_COLOR_ATTACHMENT0+i;
    bank b = make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER, b.fbo); set_viewport(16,16);
    glDrawBuffers(0, NULL); use_mrt(colors, 0); expect_no_error("draw before route restore");
    glDrawBuffers(N, identity); use_mrt(colors, 0); add_bank_center(&b, colors, "NONE 后恢复八路");

    // FBO 只附 ATT0；location 1..7 虽被路由但目标未附着，规范要求丢弃这些输出。
    bank c = make_bank(NULL, NULL, NULL, 0); glBindFramebuffer(GL_FRAMEBUFFER, c.fbo); set_viewport(16,16);
    glDrawBuffers(N, identity); use_mrt(colors, 0); const float red[4] = {1,0,0,1};
    add_tex_pixel(c.tex[0], 8, 8, red, "多输出 shader 的未附着输出丢弃"); expect_no_error("unbound MRT outputs");
}

static void duplicate_color_storage(void) {
    // 两个不同 GL attachment 指向同一张存储；最低编号按输出槽而非 attachment 编号判。
    for (int low = 0; low <= 2; low += 2) {
        bank b = make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER, b.fbo); set_viewport(16,16);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + 7, GL_TEXTURE_2D, b.tex[0], 0);
        GLenum route[N] = {0}; route[low] = GL_COLOR_ATTACHMENT0 + 7; route[6] = GL_COLOR_ATTACHMENT0;
        glDrawBuffers(N, route);
        CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "duplicate storage is GL complete, first slot %d", low);
        gl_target t = {0}; CHECK(gl_draw_target(&t), "duplicate storage resolves, first slot %d", low);
        CHECK(t.col[low] != nil && !t.col[6] && !t.cid[6], "duplicate Metal target keeps only lowest output slot %d", low);
        use_mrt(rotated, 0);
        add_tex_pixel(b.tex[0], 8, 8, rotated[low], "重复存储由最低输出槽写入");
        add_tex_pixel(b.tex[7], 8, 8, blue, "重复挂载不改写已脱离附件的原存储");
        expect_no_error("duplicate storage draw");
    }
}

static void framebuffer_route_state(void) {
    glBindFramebuffer(GL_FRAMEBUFFER,0); const GLenum default_initial[N]={GL_BACK,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE};
    expect_routes(default_initial,"new desktop context default draw route");
    GLuint fresh; glGenFramebuffers(1,&fresh); glBindFramebuffer(GL_FRAMEBUFFER,fresh);
    const GLenum initial[N]={GL_COLOR_ATTACHMENT0,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE};
    expect_routes(initial,"new FBO initial draw route");
    bank a = make_rgba_bank(), b = make_rgba_bank(); GLenum perm[N] = {GL_COLOR_ATTACHMENT0+7, GL_COLOR_ATTACHMENT0+6,
        GL_COLOR_ATTACHMENT0+5, GL_COLOR_ATTACHMENT0+4, GL_COLOR_ATTACHMENT0+3, GL_COLOR_ATTACHMENT0+2,
        GL_COLOR_ATTACHMENT0+1, GL_COLOR_ATTACHMENT0+0};
    glBindFramebuffer(GL_FRAMEBUFFER, a.fbo); glDrawBuffers(N, perm); expect_routes(perm, "FBO A routes");
    glBindFramebuffer(GL_FRAMEBUFFER, b.fbo); glDrawBuffer(GL_COLOR_ATTACHMENT0+3);
    GLenum one[N] = {GL_COLOR_ATTACHMENT0+3,0,0,0,0,0,0,0}; expect_routes(one, "glDrawBuffer resets other slots");
    set_viewport(16,16); use_mrt(colors,0); float wb[N][4]; fill_blue(wb); memcpy(wb[3], colors[0], sizeof wb[3]); add_bank_center(&b,wb,"FBO B 单路 glDrawBuffer");
    glBindFramebuffer(GL_FRAMEBUFFER,a.fbo); expect_routes(perm,"FBO A route persists after B"); set_viewport(16,16); use_mrt(colors,0);
    float wa[N][4]; mapped_colors(wa,perm,colors); add_bank_center(&a,wa,"FBO A 路由恢复");

    glBindFramebuffer(GL_FRAMEBUFFER,0); glDrawBuffer(GL_BACK_LEFT); GLenum def[N] = {GL_BACK_LEFT,0,0,0,0,0,0,0};
    expect_routes(def,"default FBO glDrawBuffer resets slots");
    glDrawBuffers(1,&(GLenum){GL_BACK}); GLenum back[N] = {GL_BACK,0,0,0,0,0,0,0}; expect_routes(back,"default FBO BACK");
    glBindFramebuffer(GL_FRAMEBUFFER,a.fbo);
}

static float blend_factor_value(GLenum f, int c, const float s[4], const float d[4]) {
    switch (f) {
        case GL_ZERO: return 0; case GL_ONE: return 1;
        case GL_SRC_COLOR: return s[c]; case GL_ONE_MINUS_SRC_COLOR: return 1-s[c];
        case GL_DST_COLOR: return d[c]; case GL_ONE_MINUS_DST_COLOR: return 1-d[c];
        case GL_SRC_ALPHA: return s[3]; case GL_ONE_MINUS_SRC_ALPHA: return 1-s[3];
        case GL_DST_ALPHA: return d[3]; case GL_ONE_MINUS_DST_ALPHA: return 1-d[3];
        default: return NAN;
    }
}
static float equation_value(GLenum eq, float s, float d) {
    switch (eq) {
        case GL_FUNC_ADD: return s+d; case GL_FUNC_SUBTRACT: return s-d; case GL_FUNC_REVERSE_SUBTRACT: return d-s;
        case GL_MIN: return fminf(s,d); case GL_MAX: return fmaxf(s,d); default: return NAN;
    }
}
static float clamp01(float v) { return fminf(1, fmaxf(0,v)); }
static void mask_and_blend_state(void) {
    static const GLuint masks[N][4] = {
        {1,1,1,1},{1,0,1,1},{1,1,0,1},{1,1,1,0},
        {0,1,1,1},{1,0,0,1},{0,1,0,1},{0,0,1,0}
    };
    static const GLenum sf[N] = {GL_SRC_ALPHA,GL_ONE,GL_ZERO,GL_SRC_COLOR,GL_DST_COLOR,GL_ONE_MINUS_DST_ALPHA,GL_SRC_ALPHA,GL_ONE};
    static const GLenum df[N] = {GL_ONE_MINUS_SRC_ALPHA,GL_ZERO,GL_ONE,GL_ONE_MINUS_SRC_COLOR,GL_ONE_MINUS_DST_COLOR,GL_DST_ALPHA,GL_ZERO,GL_ONE};
    static const GLenum eq[N] = {GL_FUNC_ADD,GL_FUNC_SUBTRACT,GL_FUNC_REVERSE_SUBTRACT,GL_MIN,GL_MAX,GL_FUNC_ADD,GL_FUNC_SUBTRACT,GL_FUNC_REVERSE_SUBTRACT};
    static const float src[N][4] = {
        {1,0,0,.5f},{0,1,0,.5f},{0,0,1,.5f},{1,1,0,.5f},
        {1,0,1,.5f},{0,1,1,.5f},{1,1,1,.5f},{0,0,0,.5f}
    };
    GLenum routes[N]; for (int i=0;i<N;i++) routes[i]=GL_COLOR_ATTACHMENT0+i;
    bank global = make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER,global.fbo); set_viewport(16,16);
    glColorMask(1,1,1,1); glBlendFuncSeparate(GL_ONE,GL_ZERO,GL_ONE,GL_ZERO); glBlendEquationSeparate(GL_FUNC_ADD,GL_FUNC_ADD);
    glEnable(GL_BLEND);
    for (int i=0;i<N;i++) { GLboolean m[4]={0}; glGetBooleani_v(GL_COLOR_WRITEMASK,i,m); CHECK(glIsEnabledi(GL_BLEND,i),"global blend broadcast[%d]",i); CHECK(m[0]&&m[1]&&m[2]&&m[3],"global color mask broadcast[%d]",i); }
    glDisable(GL_BLEND); for (int i=0;i<N;i++) CHECK(!glIsEnabledi(GL_BLEND,i),"global blend disable broadcast[%d]",i);
    glEnable(GL_BLEND); glDrawBuffers(N,routes); glBlendFuncSeparate(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA,GL_ONE,GL_ZERO);
    glBlendEquationSeparate(GL_FUNC_ADD,GL_FUNC_ADD);
    for (int i=0;i<N;i++) {
        glColorMaski(i,masks[i][0],masks[i][1],masks[i][2],masks[i][3]);
        glBlendFuncSeparatei(i,sf[i],df[i],GL_ONE,GL_ZERO); glBlendEquationSeparatei(i,eq[i],GL_FUNC_ADD);
        if (i%3==0) glDisablei(GL_BLEND,i); else glEnablei(GL_BLEND,i);
    }
    float want[N][4];
    for(int i=0;i<N;i++) {
        GLboolean got_mask[4]={0}; glGetBooleani_v(GL_COLOR_WRITEMASK,i,got_mask);
        for(int c=0;c<4;c++) CHECK(got_mask[c]==(masks[i][c]!=0),"indexed mask query[%d][%d]",i,c);
        CHECK((int)glIsEnabledi(GL_BLEND,i)==(i%3!=0),"indexed blend query[%d]",i);
        GLint q=-1; glGetIntegeri_v(GL_BLEND_SRC_RGB,i,&q); CHECK(q==(GLint)sf[i],"indexed src RGB query[%d]",i);
        glGetIntegeri_v(GL_BLEND_DST_RGB,i,&q); CHECK(q==(GLint)df[i],"indexed dst RGB query[%d]",i);
        glGetIntegeri_v(GL_BLEND_SRC_ALPHA,i,&q); CHECK(q==GL_ONE,"indexed src alpha query[%d]",i);
        glGetIntegeri_v(GL_BLEND_DST_ALPHA,i,&q); CHECK(q==GL_ZERO,"indexed dst alpha query[%d]",i);
        glGetIntegeri_v(GL_BLEND_EQUATION_RGB,i,&q); CHECK(q==(GLint)eq[i],"indexed equation RGB query[%d]",i);
        glGetIntegeri_v(GL_BLEND_EQUATION_ALPHA,i,&q); CHECK(q==GL_FUNC_ADD,"indexed equation alpha query[%d]",i);
        for(int c=0;c<4;c++) {
            // Separate alpha factors/equation are deliberately ONE / ZERO / ADD for every lane.
            float blend = c==3 ? src[i][3] : src[i][c];
            if(i%3!=0 && c!=3) {
                if(eq[i]==GL_MIN || eq[i]==GL_MAX) blend=equation_value(eq[i],src[i][c],blue[c]);
                else blend=equation_value(eq[i],src[i][c]*blend_factor_value(sf[i],c,src[i],blue),blue[c]*blend_factor_value(df[i],c,src[i],blue));
            }
            want[i][c]=masks[i][c]?clamp01(blend):blue[c];
        }
    }
    use_mrt(src,0); add_bank_center(&global,want,"八路 indexed blend / mask");

    bank simple = make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER,simple.fbo); glDrawBuffers(N,routes); glDisable(GL_BLEND); glColorMask(1,1,1,1);
    use_mrt(colors,0); add_bank_center(&simple,colors,"blend-mask PSO 简单状态");
    bank restored = make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER,restored.fbo); glDrawBuffers(N,routes); glEnable(GL_BLEND);
    for (int i=0;i<N;i++) { glColorMaski(i,masks[i][0],masks[i][1],masks[i][2],masks[i][3]); glBlendFuncSeparatei(i,sf[i],df[i],GL_ONE,GL_ZERO); glBlendEquationSeparatei(i,eq[i],GL_FUNC_ADD); if(i%3==0) glDisablei(GL_BLEND,i); else glEnablei(GL_BLEND,i); }
    use_mrt(src,0); add_bank_center(&restored,want,"恢复 indexed PSO 状态");
    glDisable(GL_BLEND); glColorMask(1,1,1,1);
}

static void clear_routing_and_masks(void) {
    bank b=make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER,b.fbo); glColorMask(1,1,1,1);
    GLenum first[N]={GL_COLOR_ATTACHMENT0+1,GL_NONE,GL_COLOR_ATTACHMENT0+5,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE};
    glDrawBuffers(N,first); glClearColor(1,0,0,1); glClear(GL_COLOR_BUFFER_BIT);
    GLenum second[N]={GL_COLOR_ATTACHMENT0,GL_NONE,GL_COLOR_ATTACHMENT0+2,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE};
    glDrawBuffers(N,second); glClearColor(0,1,0,1); glClear(GL_COLOR_BUFFER_BIT);
    float want[N][4]; fill_blue(want); const float red[4]={1,0,0,1},green[4]={0,1,0,1};
    memcpy(want[1],red,sizeof red); memcpy(want[5],red,sizeof red); memcpy(want[0],green,sizeof green); memcpy(want[2],green,sizeof green);
    add_bank_center(&b,want,"路由变化后的不同目标 clear");

    bank a=make_rgba_bank(), c=make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER,a.fbo); glDrawBuffers(N,(const GLenum[N]){
        GL_COLOR_ATTACHMENT0,GL_COLOR_ATTACHMENT0+1,GL_COLOR_ATTACHMENT0+2,GL_COLOR_ATTACHMENT0+3,
        GL_COLOR_ATTACHMENT0+4,GL_COLOR_ATTACHMENT0+5,GL_COLOR_ATTACHMENT0+6,GL_COLOR_ATTACHMENT0+7});
    glClearColor(1,0,0,1); glClear(GL_COLOR_BUFFER_BIT);
    glBindFramebuffer(GL_FRAMEBUFFER,c.fbo); glClearColor(0,1,0,1); glClear(GL_COLOR_BUFFER_BIT);
    float wa[N][4],wc[N][4]; for(int i=0;i<N;i++){memcpy(wa[i],red,sizeof red);memcpy(wc[i],green,sizeof green);}
    add_bank_center(&a,wa,"切换 FBO 后保留的 pending red clear"); add_bank_center(&c,wc,"第二个 FBO pending green clear");

    // 固定同一组八路目标，仅改变每路掩码；两个非空 clear 会合并到同一遍加载。
    bank same=make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER,same.fbo);
    for(int i=0;i<N;i++)glColorMaski(i,i<4,i<4,i<4,i<4);
    glClearColor(1,0,0,1); glClear(GL_COLOR_BUFFER_BIT);
    for(int i=0;i<N;i++)glColorMaski(i,i>=4,i>=4,i>=4,i>=4);
    glClearColor(0,1,0,1); glClear(GL_COLOR_BUFFER_BIT);
    float ws[N][4]; for(int i=0;i<N;i++){if(i<4)memcpy(ws[i],red,sizeof red);else memcpy(ws[i],green,sizeof green);}
    add_bank_center(&same,ws,"同 FBO 全写 / 全关 pending clear 快照"); glColorMask(1,1,1,1);

    bank full=make_rgba_bank(), none=make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER,full.fbo); glColorMask(1,1,1,1);
    glClearColor(1,0,1,1); glClear(GL_COLOR_BUFFER_BIT);
    glBindFramebuffer(GL_FRAMEBUFFER,none.fbo); glColorMask(0,0,0,0); glClearColor(0,1,0,1); glClear(GL_COLOR_BUFFER_BIT);
    float wf[N][4],wn[N][4]; for(int i=0;i<N;i++){const float magenta[4]={1,0,1,1};memcpy(wf[i],magenta,sizeof magenta);memcpy(wn[i],blue,sizeof blue);}
    add_bank_center(&full,wf,"全通道 clear 快照"); add_bank_center(&none,wn,"全关通道 mask 不清除"); glColorMask(1,1,1,1);
}

static void scissor_and_indexed_masks(void) {
    static const GLuint masks[N][4]={{1,1,1,1},{1,0,1,1},{1,1,0,1},{1,1,1,0},{0,1,1,1},{1,0,0,1},{0,1,0,1},{0,0,1,0}};
    bank b=make_rgba_bank(); GLenum routes[N]; for(int i=0;i<N;i++){routes[i]=GL_COLOR_ATTACHMENT0+i;glColorMaski(i,masks[i][0],masks[i][1],masks[i][2],masks[i][3]);}
    glBindFramebuffer(GL_FRAMEBUFFER,b.fbo); glDrawBuffers(N,routes); glDisable(GL_BLEND); glEnable(GL_SCISSOR_TEST); glScissor(4,4,8,8); set_viewport(16,16); use_mrt(colors,0);
    for(int i=0;i<N;i++) {
        float inside[4]; for(int c=0;c<4;c++) inside[c]=masks[i][c]?colors[i][c]:blue[c];
        char label[112]; snprintf(label,sizeof label,"scissor ATT%d inside",i); add_tex_pixel(b.tex[i],8,8,inside,label);
        snprintf(label,sizeof label,"scissor ATT%d outside",i); add_tex_pixel(b.tex[i],2,2,blue,label);
    }
    glDisable(GL_SCISSOR_TEST); glColorMask(1,1,1,1);

    bank clear_then_draw=make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER,clear_then_draw.fbo);
    glEnable(GL_SCISSOR_TEST); glScissor(4,4,8,8); set_viewport(4,4);
    for(int i=0;i<N;i++)glColorMaski(i,1,0,0,0);
    glClearColor(1,1,0,1); glClear(GL_COLOR_BUFFER_BIT);
    // 不切附件或路由：同一编码器下一笔须恢复用户的 4×4 视口、管线、掩码和裁剪。
    glDisable(GL_SCISSOR_TEST); glColorMask(1,1,1,1); use_mrt(colors,0);
    for(int i=0;i<N;i++) {
        const float changed[4]={1,0,1,1}; char label[112];
        snprintf(label,sizeof label,"partial clear ATT%d inside",i); add_tex_pixel(clear_then_draw.tex[i],8,8,changed,label);
        snprintf(label,sizeof label,"partial clear ATT%d outside",i); add_tex_pixel(clear_then_draw.tex[i],14,14,blue,label);
        snprintf(label,sizeof label,"same-pass draw after partial clear ATT%d",i); add_tex_pixel(clear_then_draw.tex[i],2,2,colors[i],label);
    }
}

static void mixed_formats_renderbuffer_depth(void) {
    const GLsizei w[N]={16,16,16,16,16,8,16,16},h[N]={16,16,16,16,16,8,16,16};
    const GLint fmts[N]={GL_RGBA8,0x8C43,0x8059,GL_R8,GL_RG8,GL_RGBA16F,GL_RGBA32F,GL_RGBA8}; // sRGB / RGB10_A2 也用精确端点。
    const float vals[N][4]={{1,0,0,1},{0,1,0,1},{0,0,1,1},{1,0,0,1},{0,1,0,1},{1,0,1,1},{1,1,0,1},{1,1,1,1}};
    GLenum route[N]; for(int i=0;i<N;i++) route[i]=GL_COLOR_ATTACHMENT0+i;
    bank b=make_bank(w,h,fmts,1); glBindFramebuffer(GL_FRAMEBUFFER,b.fbo); glDrawBuffers(N,route); set_viewport(16,16); use_mrt(vals,0);
    add_bank_center(&b,vals,"七种颜色格式与异尺寸交集");

    bank rb_bank=make_rgba_bank(); GLuint rb; glGenRenderbuffers(1,&rb); glBindRenderbuffer(GL_RENDERBUFFER,rb); glRenderbufferStorage(GL_RENDERBUFFER,GL_RGBA8,16,16);
    glBindFramebuffer(GL_FRAMEBUFFER,rb_bank.fbo); glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0+7,GL_RENDERBUFFER,rb);
    CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE,"MRT color renderbuffer FBO complete");
    set_viewport(16,16); use_mrt(colors,0); gl_target t={0}; CHECK(gl_draw_target(&t),"renderbuffer draw target");
    for(int i=0;i<7;i++) { char label[112]; snprintf(label,sizeof label,"MRT renderbuffer companion ATT%d",i); add_tex_pixel(rb_bank.tex[i],2,2,colors[i],label); }
    add_image_pixel(t.col[7],2,2,colors[7],"MRT renderbuffer ATT7 GPU pixel");

    GLuint depth_only,badfbo; glGenRenderbuffers(1,&depth_only); glBindRenderbuffer(GL_RENDERBUFFER,depth_only);
    glRenderbufferStorage(GL_RENDERBUFFER,GL_DEPTH_COMPONENT24,16,16); glGenFramebuffers(1,&badfbo); glBindFramebuffer(GL_FRAMEBUFFER,badfbo);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_STENCIL_ATTACHMENT,GL_RENDERBUFFER,depth_only);
    CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT,"depth-only image rejected as stencil");
    expect_no_error("depth/stencil format rejection");

    bank ds=make_rgba_bank(); GLuint dsrb; glGenRenderbuffers(1,&dsrb); glBindRenderbuffer(GL_RENDERBUFFER,dsrb);
    glRenderbufferStorage(GL_RENDERBUFFER,GL_DEPTH24_STENCIL8,16,16); glBindFramebuffer(GL_FRAMEBUFFER,ds.fbo);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_DEPTH_STENCIL_ATTACHMENT,GL_RENDERBUFFER,dsrb); glDrawBuffers(N,route);
    CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE,"MRT + depth/stencil FBO complete");
    glClearDepthf(1); glClearStencil(7); glDepthMask(1); glDepthFunc(0x0201); glClear(GL_DEPTH_BUFFER_BIT|GL_STENCIL_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glStencilFunc(0x0202,7,0xff); glStencilOp(0x1E00,0x1E00,0x1E00);
    set_viewport(16,16); use_mrt(colors,0); // depth .5 < 1，stencil 7 == 7：通过。
    use_mrt(rotated,.5f); // depth .75 >= .5：拒绝。
    glStencilFunc(0x0202,6,0xff); use_mrt(rotated,-.5f); // depth .25 可过，但 stencil 7 != 6：拒绝。
    add_bank_center(&ds,colors,"八路 MRT 深度与模板分别拒绝覆盖"); glDisable(GL_DEPTH_TEST); glDisable(GL_STENCIL_TEST);
}

static void redefinition_and_attachment_switch(void) {
    GLenum routes[N]; for(int i=0;i<N;i++) routes[i]=GL_COLOR_ATTACHMENT0+i;
    bank b=make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER,b.fbo); glDrawBuffers(N,routes); set_viewport(16,16); use_mrt(colors,0);
    id<MTLTexture> old_redefined=gl_tex_mtl(b.tex[2],0), old_detached=gl_tex_mtl(b.tex[4],0);
    add_image_pixel(old_redefined,8,8,colors[2],"TexImage 前的旧 ATT2 存储");
    add_image_pixel(old_detached,8,8,colors[4],"换附件前的旧 ATT4 存储");
    GLuint replacement; glGenTextures(1,&replacement); glBindTexture(GL_TEXTURE_2D,replacement);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    static uint8_t init[16*16*4]; for(int i=0;i<16*16;i++){init[i*4]=0;init[i*4+1]=0;init[i*4+2]=255;init[i*4+3]=255;}
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,16,16,0,GL_RGBA,GL_UNSIGNED_BYTE,init);
    glBindTexture(GL_TEXTURE_2D,b.tex[2]); glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,16,16,0,GL_RGBA,GL_UNSIGNED_BYTE,init);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0+4,GL_TEXTURE_2D,replacement,0); b.tex[4]=replacement;
    use_mrt(rotated,0); add_bank_center(&b,rotated,"TexImage 重定义和换附件后的写入");
    expect_no_error("TexImage redefinition / attachment switch");

    bank pending=make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER,pending.fbo);
    glClearColor(1,0,0,1); glClear(GL_COLOR_BUFFER_BIT);
    id<MTLTexture> pending_old=gl_tex_mtl(pending.tex[7],0);
    glBindTexture(GL_TEXTURE_2D,pending.tex[7]); glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,16,16,0,GL_RGBA,GL_UNSIGNED_BYTE,init);
    glClearColor(0,1,0,1); glClear(GL_COLOR_BUFFER_BIT);
    const float red[4]={1,0,0,1},green[4]={0,1,0,1}; float current[N][4];
    for(int i=0;i<N;i++)memcpy(current[i],green,sizeof green);
    add_image_pixel(pending_old,2,2,red,"pending clear 保活重定义前 ATT7 存储");
    add_bank_center(&pending,current,"pending clear 重定义后的八路存储");
}

static void invalid_calls_are_atomic(void) {
    bank b=make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER,b.fbo); GLenum route[N];
    for(int i=0;i<N;i++) route[i]=GL_COLOR_ATTACHMENT0+i;
    glDrawBuffers(N,route); expect_routes(route,"invalid-call initial routes");
    glDrawBuffers(-1,NULL); expect_error(GL_INVALID_VALUE,"negative draw buffer count"); expect_routes(route,"negative count atomic");
    glDrawBuffers(N+1,route); expect_error(GL_INVALID_VALUE,"draw buffer count above eight"); expect_routes(route,"large count atomic");
    GLenum dup[N]={GL_COLOR_ATTACHMENT0,GL_COLOR_ATTACHMENT0,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE};
    glDrawBuffers(2,dup); expect_error(GL_INVALID_OPERATION,"duplicate non-NONE route"); expect_routes(route,"duplicate route atomic");
    GLenum bad_enum=0xDEAD; glDrawBuffers(1,&bad_enum); expect_error(GL_INVALID_ENUM,"invalid route enum"); expect_routes(route,"enum route atomic");
    GLenum bad_att=GL_COLOR_ATTACHMENT0+N; glDrawBuffers(1,&bad_att); expect_error(GL_INVALID_ENUM,"attachment above seven"); expect_routes(route,"high attachment atomic");
    glDrawBuffer(GL_BACK); expect_error(GL_INVALID_OPERATION,"BACK on user FBO"); expect_routes(route,"single draw buffer invalid atomic");
    GLboolean before[4]={0}; glGetBooleani_v(GL_COLOR_WRITEMASK,0,before);
    glColorMaski(N,0,0,0,0); expect_error(GL_INVALID_VALUE,"color mask index eight");
    GLboolean after[4]={0}; glGetBooleani_v(GL_COLOR_WRITEMASK,0,after); CHECK(!memcmp(before,after,sizeof before),"invalid color mask changed state");
    glEnablei(0xDEAD,0); expect_error(GL_INVALID_ENUM,"indexed enable invalid cap");
    glBlendFuncSeparatei(N,GL_ONE,GL_ZERO,GL_ONE,GL_ZERO); expect_error(GL_INVALID_VALUE,"blend function index eight");
    GLboolean untouched[4]={7,7,7,7}; glGetBooleani_v(GL_COLOR_WRITEMASK,N,untouched); expect_error(GL_INVALID_VALUE,"indexed query index eight");
    CHECK(untouched[0]==7&&untouched[1]==7&&untouched[2]==7&&untouched[3]==7,"invalid indexed query wrote output");
    GLint q=0; glGetIntegeri_v(0xDEAD,0,&q); expect_error(GL_INVALID_ENUM,"indexed query enum");
    expect_routes(route,"all invalid calls preserve routes");

    // 桌面默认 framebuffer 只接受 FRONT/BACK 类缓冲；颜色附件 enum 必须原子失败。
    glBindFramebuffer(GL_FRAMEBUFFER,0); GLenum backleft[N]={GL_BACK_LEFT,0,0,0,0,0,0,0};
    glDrawBuffer(GL_BACK_LEFT); expect_routes(backleft,"desktop BACK_LEFT");
    for(int i=0;i<N;i++) {
        GLenum attachment=GL_COLOR_ATTACHMENT0+i; glDrawBuffers(1,&attachment); expect_error(GL_INVALID_OPERATION,"desktop default DrawBuffers attachment");
        expect_routes(backleft,"desktop default DrawBuffers invalid atomic");
        glDrawBuffer(attachment); expect_error(GL_INVALID_OPERATION,"desktop default DrawBuffer attachment"); expect_routes(backleft,"desktop default DrawBuffer invalid atomic");
    }
    GLenum default_back=GL_BACK; glDrawBuffers(2,(const GLenum[2]){GL_BACK,GL_NONE}); expect_error(GL_INVALID_OPERATION,"desktop default BACK with n=2"); expect_routes(backleft,"desktop n=2 BACK atomic");
    glDrawBuffers(0,NULL); expect_no_error("desktop default n=0"); expect_routes((const GLenum[N]){0,0,0,0,0,0,0,0},"desktop n=0 clears routes");
    glDrawBuffers(1,&default_back); expect_routes((const GLenum[N]){GL_BACK,0,0,0,0,0,0,0},"desktop default BACK restore");
    glBindFramebuffer(GL_FRAMEBUFFER,b.fbo);
}

static void es_routing_rules(void) {
    require(eglBindAPI(EGL_OPENGL_ES_API),"eglBindAPI ES"); EGLContext es=eglCreateContext(display,(EGLConfig)1,NULL,NULL);
    require(es&&eglMakeCurrent(display,NULL,NULL,es),"ES context current");
    glBindFramebuffer(GL_FRAMEBUFFER,0); expect_routes((const GLenum[N]){GL_BACK,0,0,0,0,0,0,0},"new ES context default draw route");
    GLenum esback=GL_BACK; glDrawBuffers(1,&esback); expect_routes((const GLenum[N]){GL_BACK,0,0,0,0,0,0,0},"ES default BACK");
    GLenum esleft=GL_BACK_LEFT; glDrawBuffers(1,&esleft); expect_error(GL_INVALID_ENUM,"ES default BACK_LEFT"); expect_routes((const GLenum[N]){GL_BACK,0,0,0,0,0,0,0},"ES default BACK_LEFT atomic");
    GLenum esatt=GL_COLOR_ATTACHMENT0; glDrawBuffers(1,&esatt); expect_error(GL_INVALID_OPERATION,"ES default color attachment");
    expect_routes((const GLenum[N]){GL_BACK,0,0,0,0,0,0,0},"ES default attachment atomic");
    glDrawBuffers(0,NULL); expect_error(GL_INVALID_OPERATION,"ES default n=0"); expect_routes((const GLenum[N]){GL_BACK,0,0,0,0,0,0,0},"ES default n=0 atomic");
    bank b=make_rgba_bank(); glBindFramebuffer(GL_FRAMEBUFFER,b.fbo);
    GLenum valid[N]={GL_COLOR_ATTACHMENT0,GL_NONE,GL_COLOR_ATTACHMENT0+2,GL_NONE,GL_COLOR_ATTACHMENT0+4,GL_COLOR_ATTACHMENT0+5,GL_NONE,GL_COLOR_ATTACHMENT0+7};
    glDrawBuffers(N,valid); expect_routes(valid,"ES identity-or-NONE routes");
    GLenum permutation[N]={GL_COLOR_ATTACHMENT0+1,GL_COLOR_ATTACHMENT0,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE};
    glDrawBuffers(N,permutation); expect_error(GL_INVALID_OPERATION,"ES route permutation"); expect_routes(valid,"ES permutation atomic");
    GLenum named_back[N]={GL_BACK,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE,GL_NONE};
    glDrawBuffers(N,named_back); expect_error(GL_INVALID_OPERATION,"ES named FBO BACK"); expect_routes(valid,"ES named BACK atomic");
    glDrawBuffers(1,&esleft); expect_error(GL_INVALID_ENUM,"ES named FBO BACK_LEFT"); expect_routes(valid,"ES named BACK_LEFT atomic");
    GLenum permuted=GL_COLOR_ATTACHMENT0+1; glDrawBuffers(1,&permuted); expect_error(GL_INVALID_OPERATION,"ES named nonmatching attachment"); expect_routes(valid,"ES named permutation atomic");
    glDrawBuffers(0,NULL); expect_no_error("ES named n=0"); expect_routes((const GLenum[N]){0,0,0,0,0,0,0,0},"ES named n=0 clears routes");
    glDrawBuffers(N,valid); expect_routes(valid,"ES named valid route restore");
    glBindFramebuffer(GL_FRAMEBUFFER,0); GLenum default_many[2]={GL_BACK,GL_NONE};
    glDrawBuffers(2,default_many); expect_error(GL_INVALID_OPERATION,"ES default draw buffers n>1");
    GLenum back=GL_BACK; glDrawBuffers(1,&back); expect_routes((const GLenum[N]){GL_BACK,0,0,0,0,0,0,0},"ES default BACK");
    require(eglDestroyContext(display,es),"destroy ES context"); require(eglMakeCurrent(display,NULL,NULL,desktop_context),"restore desktop context");
}

static NSUInteger pixel_size(MTLPixelFormat f) {
    switch(f) {
        case MTLPixelFormatR8Unorm: return 1;
        case MTLPixelFormatRG8Unorm: return 2;
        case MTLPixelFormatR16Float: return 2;
        case MTLPixelFormatR32Float: return 4;
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatRGB10A2Unorm: return 4;
        case MTLPixelFormatRGBA16Float: return 8;
        case MTLPixelFormatRGBA32Float: return 16;
        default: return 0;
    }
}
static void decode_pixel(MTLPixelFormat f, const uint8_t *p, float out[4]) {
    out[0]=out[1]=out[2]=0; out[3]=1;
    switch(f) {
        case MTLPixelFormatR8Unorm: out[0]=p[0]/255.f; break;
        case MTLPixelFormatRG8Unorm: out[0]=p[0]/255.f; out[1]=p[1]/255.f; break;
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB:
            for(int i=0;i<4;i++) out[i]=p[i]/255.f; break;
        case MTLPixelFormatBGRA8Unorm: out[0]=p[2]/255.f; out[1]=p[1]/255.f; out[2]=p[0]/255.f; out[3]=p[3]/255.f; break;
        case MTLPixelFormatRGBA16Float: { const _Float16 *v=(const _Float16 *)p; for(int i=0;i<4;i++)out[i]=(float)v[i]; break; }
        case MTLPixelFormatRGBA32Float: { const float *v=(const float *)p; memcpy(out,v,4*sizeof(float)); break; }
        case MTLPixelFormatRGB10A2Unorm: { uint32_t v; memcpy(&v,p,sizeof v); out[0]=(v&1023)/1023.f; out[1]=((v>>10)&1023)/1023.f; out[2]=((v>>20)&1023)/1023.f; out[3]=((v>>30)&3)/3.f; break; }
        case MTLPixelFormatR16Float: { const _Float16 *v=(const _Float16 *)p; out[0]=(float)v[0]; break; }
        case MTLPixelFormatR32Float: { const float *v=(const float *)p; out[0]=v[0]; break; }
        default: break;
    }
}
static void verify_pixels(void) {
    glFinish(); if (!expected_n) return;
    id<MTLBuffer> bytes=[gl_dev newBufferWithLength:(NSUInteger)expected_n*BLIT_SLOT options:MTLResourceStorageModeShared];
    require(bytes!=nil,"readback buffer"); id<MTLCommandQueue> queue=[gl_dev newCommandQueue]; id<MTLCommandBuffer> cb=[queue commandBuffer];
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder]; require(blit!=nil,"Metal blit encoder");
    for(int i=0;i<expected_n;i++) {
        pixel_expect *e=&expected[i]; require(pixel_size(e->format)>0,"unsupported readback pixel format");
        [blit copyFromTexture:e->image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(e->x,e->y,0) sourceSize:MTLSizeMake(1,1,1)
                     toBuffer:bytes destinationOffset:(NSUInteger)i*BLIT_SLOT destinationBytesPerRow:BLIT_SLOT destinationBytesPerImage:BLIT_SLOT];
    }
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted]; require(cb.status==MTLCommandBufferStatusCompleted&&!cb.error,"Metal blit completion");
    const uint8_t *data=bytes.contents;
    for(int i=0;i<expected_n;i++) {
        pixel_expect *e=&expected[i]; float got[4]; decode_pixel(e->format,data+(NSUInteger)i*BLIT_SLOT,got);
        float tol=(e->format==MTLPixelFormatRGBA8Unorm||e->format==MTLPixelFormatRGBA8Unorm_sRGB||e->format==MTLPixelFormatR8Unorm||e->format==MTLPixelFormatRG8Unorm)?(1.f/255.f+1e-5f):1e-3f;
        CHECK(fabsf(got[0]-e->want[0])<=tol&&fabsf(got[1]-e->want[1])<=tol&&fabsf(got[2]-e->want[2])<=tol&&fabsf(got[3]-e->want[3])<=tol,
              "%s format=%lu want={%.4f,%.4f,%.4f,%.4f} got={%.4f,%.4f,%.4f,%.4f}",e->label,(unsigned long)e->format,e->want[0],e->want[1],e->want[2],e->want[3],got[0],got[1],got[2],got[3]);
    }
}

int main(void) { @autoreleasepool {
    load_core_api(); display=eglGetDisplay(NULL); require(display&&eglInitialize(display,NULL,NULL),"EGL display initialize");
    require(eglBindAPI(EGL_OPENGL_API),"eglBindAPI desktop GL"); desktop_context=eglCreateContext(display,(EGLConfig)1,NULL,NULL);
    require(desktop_context&&eglMakeCurrent(display,NULL,NULL,desktop_context),"desktop GL context"); gl_dev_init();
    printf("GPU %s，真实 EGL / GL / Metal，默认 API=desktop GL\n",gl_dev.name.UTF8String);
    setup_geometry(); control_program=make_program("tri.vert","tri.frag",1); probe_single_target_control(); probe_each_color_attachment();
    int missing=load_mrt_api();
    if(missing) {
        verify_pixels(); printf("旧 GL 库缺 MRT 入口，未调用缺失函数；单附件控制与 ATT0..7 completeness 已实际检查。\n");
        printf("✗ t_gpu_mrt baseline：%d/%d，像素=%d，MRT entry 缺失=%d\n",checks-fails,checks,expected_n,missing);
        eglDestroyContext(display,desktop_context); return 1;
    }
    GLint max_colors=0,max_draw=0; glGetIntegerv(0x8CDF,&max_colors); glGetIntegerv(0x8824,&max_draw);
    CHECK(max_colors==N&&max_draw==N,"八路能力查询 colors=%d draw=%d",max_colors,max_draw);
    mrt_program=make_program("mrt.vert","mrt.frag",0);
    identity_and_permutation(); none_restore_and_unbound(); duplicate_color_storage(); framebuffer_route_state(); mask_and_blend_state();
    clear_routing_and_masks(); scissor_and_indexed_masks(); mixed_formats_renderbuffer_depth(); redefinition_and_attachment_switch();
    invalid_calls_are_atomic(); es_routing_rules();
    expect_no_error("valid MRT sequence"); verify_pixels();
    uint64_t bad_feature=0,bad_error=0; dm_gl_bad_draws(&bad_feature,&bad_error);
    CHECK(!bad_feature&&!bad_error,"GL bad counters feature=%llu error=%llu",(unsigned long long)bad_feature,(unsigned long long)bad_error);
    printf("%s t_gpu_mrt：%d/%d，%d 个 Metal GPU 像素期望\n",fails?"✗":"✓",checks-fails,checks,expected_n);
    eglDestroyContext(display,desktop_context); return fails?1:0;
} }
