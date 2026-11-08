// Link into native-graphics-session-probe with the production host and NativeAOT.
// All EGL/GL calls use the registered implementation. The readback uses the GL
// command queue's real Metal blit encoder, as glReadPixels is not implemented.
// No game, shader pack, replacement host symbols, or per-object Delete cleanup.
#include "../../gfx/gl/gl_int.h"
#include "../../graphics_session.h"
#include <stdio.h>


#define API(ret, name, ...) static ret (*name)(__VA_ARGS__)
API(EGLDisplay, eglGetDisplay, void *);
API(EGLBoolean, eglInitialize, EGLDisplay, EGLint *, EGLint *);
API(EGLBoolean, eglChooseConfig, EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
API(EGLContext, eglCreateContext, EGLDisplay, EGLConfig, EGLContext, const EGLint *);
API(EGLSurface, eglCreateWindowSurface, EGLDisplay, EGLConfig, EGLNativeWindowType, const EGLint *);
API(EGLBoolean, eglMakeCurrent, EGLDisplay, EGLSurface, EGLSurface, EGLContext);
API(EGLContext, eglGetCurrentContext, void);
API(void, glGenBuffers, GLsizei, GLuint *);
API(void, glBindBuffer, GLenum, GLuint);
API(void, glBufferData, GLenum, GLsizeiptr, const void *, GLenum);
API(void, glGenVertexArrays, GLsizei, GLuint *);
API(void, glBindVertexArray, GLuint);
API(void, glGenTextures, GLsizei, GLuint *);
API(void, glBindTexture, GLenum, GLuint);
API(void, glTexImage2D, GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
API(void, glGenFramebuffers, GLsizei, GLuint *);
API(void, glBindFramebuffer, GLenum, GLuint);
API(void, glFramebufferTexture2D, GLenum, GLenum, GLenum, GLuint, GLint);
API(void, glGenRenderbuffers, GLsizei, GLuint *);
API(void, glBindRenderbuffer, GLenum, GLuint);
API(void, glRenderbufferStorage, GLenum, GLenum, GLsizei, GLsizei);
API(void, glFramebufferRenderbuffer, GLenum, GLenum, GLenum, GLuint);
API(GLenum, glCheckFramebufferStatus, GLenum);
API(void, glViewport, GLint, GLint, GLsizei, GLsizei);
API(void, glScissor, GLint, GLint, GLsizei, GLsizei);
API(void, glEnable, GLenum);
API(void, glDisable, GLenum);
API(void, glClearColor, GLfloat, GLfloat, GLfloat, GLfloat);
API(void, glClear, GLbitfield);
API(void, glFinish, void);
API(GLenum, glGetError, void);
#undef API

#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "[gl-session] failed at %s:%d: %s\n", __FILE__, __LINE__, #c); return 1; } } while (0)
enum { ARRAY = 0x8892, STATIC_DRAW = 0x88E4, TEX2D = 0x0DE1, RGBA8 = 0x8058,
       RGBA = 0x1908, UBYTE = 0x1401, FB = 0x8D40, RB = 0x8D41, COLOR = 0x8CE0,
       DEPTH = 0x8D00, DEPTH32F = 0x8CAC, COMPLETE = 0x8CD5, SCISSOR = 0x0C11,
       COLOR_BIT = 0x4000, DEPTH_BIT = 0x0100, SIDE = 32, ROW = 256, BYTES = ROW * SIDE };
typedef struct {
    __weak id<MTLBuffer> buffer;
    __weak id<MTLTexture> texture, surface_color, surface_depth, depth_attachment;
    __weak id<MTLSharedEvent> event;
} observed_owners;

static int load_api(void) {
#define LOAD(name) name = gl_lookup(#name); REQUIRE(name != NULL)
    LOAD(eglGetDisplay); LOAD(eglInitialize); LOAD(eglChooseConfig); LOAD(eglCreateContext);
    LOAD(eglCreateWindowSurface); LOAD(eglMakeCurrent); LOAD(eglGetCurrentContext);
    LOAD(glGenBuffers); LOAD(glBindBuffer); LOAD(glBufferData); LOAD(glGenVertexArrays); LOAD(glBindVertexArray);
    LOAD(glGenTextures); LOAD(glBindTexture); LOAD(glTexImage2D);
    LOAD(glGenFramebuffers); LOAD(glBindFramebuffer); LOAD(glFramebufferTexture2D); LOAD(glCheckFramebufferStatus);
    LOAD(glGenRenderbuffers); LOAD(glBindRenderbuffer); LOAD(glRenderbufferStorage); LOAD(glFramebufferRenderbuffer);
    LOAD(glViewport); LOAD(glScissor); LOAD(glEnable); LOAD(glDisable); LOAD(glClearColor); LOAD(glClear);
    LOAD(glFinish); LOAD(glGetError);
#undef LOAD
    return 0;
}
static void clear_color(const uint8_t color[4]) {
    glClearColor(color[0] / 255.f, color[1] / 255.f, color[2] / 255.f, color[3] / 255.f);
}
static int pixels_equal(const uint8_t *pixels, const uint8_t outside[4], const uint8_t inside[4]) {
    for (int y = 0; y < SIDE; y++) for (int x = 0; x < SIDE; x++) {
        const uint8_t *want = x >= 8 && x < 24 && y >= 8 && y < 24 ? inside : outside;
        for (int c = 0; c < 4; c++) REQUIRE(abs((int)pixels[y * ROW + x * 4 + c] - want[c]) <= 1);
    }
    return 0;
}
static int create_and_readback(unsigned round, observed_owners *owners) {
    EGLDisplay display = eglGetDisplay(NULL); REQUIRE(display != NULL);
    REQUIRE(eglInitialize(display, NULL, NULL));
    EGLConfig config = NULL; EGLint count = 0;
    REQUIRE(eglChooseConfig(display, NULL, &config, 1, &count) && count == 1 && config);
    EGLContext context = eglCreateContext(display, config, NULL, NULL); REQUIRE(context != NULL);
    EGLSurface surface = eglCreateWindowSurface(display, config, NULL, NULL); REQUIRE(surface != NULL);
    REQUIRE(eglMakeCurrent(display, surface, surface, context));
    REQUIRE(eglGetCurrentContext() == context && gl_cur && !gl_cur->vao && !gl_cur->fb_draw && !gl_cur->buf_bound[0]);
    REQUIRE(gl_cur->clear_color[0] == 0 && gl_cur->unpack_align == 4 && gl_cur->enable == 0);
    REQUIRE(gl_seq_ref() == 1 && gl_ev.signaledValue == 0);
    owners->surface_color = gl_surface_color(); owners->surface_depth = gl_surface_depth(); owners->event = gl_ev;
    REQUIRE(owners->surface_color && owners->surface_depth && owners->event);

    uint8_t contents[4096];
    for (size_t i = 0; i < sizeof contents; i++) contents[i] = (uint8_t)(i * 131 + round);
    GLuint buffer = 0, vao = 0, texture = 0, framebuffer = 0, depth = 0;
    glGenBuffers(1, &buffer); glGenVertexArrays(1, &vao); glGenTextures(1, &texture);
    glGenFramebuffers(1, &framebuffer); glGenRenderbuffers(1, &depth);
    REQUIRE(buffer == 1 && vao == 1 && texture == 1 && framebuffer == 1 && depth == 1);
    glBindVertexArray(vao); glBindBuffer(ARRAY, buffer); glBufferData(ARRAY, sizeof contents, contents, STATIC_DRAW);
    struct gl_buffer *storage = gl_name_get(&gl_buffers, buffer); REQUIRE(storage && storage->buf);
    owners->buffer = storage->buf;

    // The default surface is a real private texture registered with the shared
    // present backend; its owner must disappear even without eglDestroySurface.
    const uint8_t surface_color[4] = {32, 64, (uint8_t)(80 + round), 255};
    glViewport(0, 0, SIDE, SIDE); clear_color(surface_color); glClear(COLOR_BIT | DEPTH_BIT);
    glBindTexture(TEX2D, texture); glTexImage2D(TEX2D, 0, RGBA8, SIDE, SIDE, 0, RGBA, UBYTE, NULL);
    glBindRenderbuffer(RB, depth); glRenderbufferStorage(RB, DEPTH32F, SIDE, SIDE);
    glBindFramebuffer(FB, framebuffer); glFramebufferTexture2D(FB, COLOR, TEX2D, texture, 0);
    glFramebufferRenderbuffer(FB, DEPTH, RB, depth); REQUIRE(glCheckFramebufferStatus(FB) == COMPLETE);
    owners->texture = gl_tex_mtl(texture, 0); gl_target target;
    REQUIRE(gl_draw_target(&target)); owners->depth_attachment = target.dep;
    REQUIRE(owners->texture && owners->depth_attachment);
    const uint8_t outside[4] = {(uint8_t)(64 + round), 128, 192, 255};
    const uint8_t inside[4] = {192, (uint8_t)(32 + round), 64, 255};
    clear_color(outside); glClear(COLOR_BIT | DEPTH_BIT);
    // A scissored clear creates and executes the production Metal clear PSO;
    // this also checks its lifetime, beyond a render-pass loadAction alone.
    glScissor(8, 8, 16, 16); glEnable(SCISSOR); clear_color(inside); glClear(COLOR_BIT); glDisable(SCISSOR);

    id<MTLBuffer> buffer_bytes = [gl_dev newBufferWithLength:sizeof contents options:MTLResourceStorageModeShared];
    id<MTLBuffer> texture_bytes = [gl_dev newBufferWithLength:BYTES options:MTLResourceStorageModeShared];
    id<MTLBuffer> surface_bytes = [gl_dev newBufferWithLength:BYTES options:MTLResourceStorageModeShared];
    REQUIRE(buffer_bytes && texture_bytes && surface_bytes);
    id<MTLBlitCommandEncoder> blit = gl_blit_enc(); REQUIRE(blit != nil);
    gl_buffer_ref(storage);
    [blit copyFromBuffer:storage->buf sourceOffset:0 toBuffer:buffer_bytes destinationOffset:0 size:sizeof contents];
    [blit copyFromTexture:gl_tex_mtl(texture, 0) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
              sourceSize:MTLSizeMake(SIDE, SIDE, 1) toBuffer:texture_bytes destinationOffset:0 destinationBytesPerRow:ROW destinationBytesPerImage:BYTES];
    [blit copyFromTexture:gl_surface_color() sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
              sourceSize:MTLSizeMake(SIDE, SIDE, 1) toBuffer:surface_bytes destinationOffset:0 destinationBytesPerRow:ROW destinationBytesPerImage:BYTES];
    id<MTLCommandBuffer> command = gl_cmd();
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    [command addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c; dispatch_semaphore_signal(completed); }];
    glFinish();
    REQUIRE(dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    REQUIRE(gl_ev.signaledValue == 1 && command.status == MTLCommandBufferStatusCompleted && !command.error);
    REQUIRE(!memcmp(buffer_bytes.contents, contents, sizeof contents));
    REQUIRE(pixels_equal(texture_bytes.contents, outside, inside) == 0);
    REQUIRE(pixels_equal(surface_bytes.contents, surface_color, surface_color) == 0);
    REQUIRE(glGetError() == 0 && !atomic_load(&gl_bad_feat) && !atomic_load(&gl_bad_err));
    // Leave an uncommitted clear and all bindings live. Unified shutdown must
    // release both pending encoder references and every frontend owner.
    clear_color(inside); glClear(COLOR_BIT);
    return 0;
}

// Call only between complete graphics sessions. Returning success covers this
// headless GL resource cycle, not presentation, game rendering, or iOS play.
int s2a_test_gl_session_resources(unsigned rounds) {
    REQUIRE(rounds > 0 && load_api() == 0);
    for (unsigned round = 1; round <= rounds; round++) {
        observed_owners owners = {0};
        @autoreleasepool {
            REQUIRE(s2a_graphics_native_begin_session() == 0);
            REQUIRE(create_and_readback(round, &owners) == 0);
        }
        @autoreleasepool {
            REQUIRE(s2a_graphics_native_restart_check() == 0);
            REQUIRE(s2a_graphics_native_request_stop() == 0 && gl_session_stopping());
            REQUIRE(s2a_graphics_native_shutdown_session() == 0);
        }
        REQUIRE(!eglGetCurrentContext() && !gl_cur && !gl_surface_color() && !gl_surface_depth());
        REQUIRE(!gl_dev && !gl_ev && gl_seq_ref() == 1);
        REQUIRE(!gl_buffers.v && !gl_buffers.n && !gl_buffers.cap && !gl_vaos.v && !gl_vaos.n && !gl_vaos.cap);
        REQUIRE(!gl_tex_mtl(1, 0));
        REQUIRE(!owners.buffer && !owners.texture && !owners.surface_color && !owners.surface_depth && !owners.depth_attachment && !owners.event);
        REQUIRE(!atomic_load(&gl_n_frames) && !atomic_load(&gl_n_draws) && !atomic_load(&gl_n_passes));
        mtl_res_count counts; mtl_res_snapshot(&counts);
        REQUIRE(!counts.pools && !counts.live_tex && !counts.view_nonnull && !counts.view_slots && !counts.sview_nonnull);
        fprintf(stderr, "[gl-session] %u/%u EGL + buffer/texture/FBO GPU readback/reset passed\n", round, rounds);
    }
    return 0;
}
