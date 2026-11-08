// #272 分离 depth / stencil：生产 EGL / GL → Metal；最后统一独立 blit 读颜色。
// 不读取 gl_state / gl_target 布局，旧 GL archive 与新生产库使用同一组公开调用及手算期望。
#include "../../gfx/gl/gl_int.h"
#include <stdint.h>

#define API(ret, name, ...) static ret (*name)(__VA_ARGS__)
API(EGLDisplay, eglGetDisplay, void *);
API(EGLBoolean, eglInitialize, EGLDisplay, EGLint *, EGLint *);
API(EGLBoolean, eglBindAPI, EGLenum);
API(EGLContext, eglCreateContext, EGLDisplay, EGLConfig, EGLContext, const EGLint *);
API(EGLBoolean, eglMakeCurrent, EGLDisplay, EGLSurface, EGLSurface, EGLContext);
API(EGLBoolean, eglDestroyContext, EGLDisplay, EGLContext);
API(void, glGenTextures, GLsizei, GLuint *);
API(void, glDeleteTextures, GLsizei, const GLuint *);
API(void, glBindTexture, GLenum, GLuint);
API(void, glTexImage2D, GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
API(void, glTexStorage2D, GLenum, GLsizei, GLenum, GLsizei, GLsizei);
API(void, glGenFramebuffers, GLsizei, GLuint *);
API(void, glDeleteFramebuffers, GLsizei, const GLuint *);
API(void, glBindFramebuffer, GLenum, GLuint);
API(void, glFramebufferTexture2D, GLenum, GLenum, GLenum, GLuint, GLint);
API(void, glFramebufferRenderbuffer, GLenum, GLenum, GLenum, GLuint);
API(GLenum, glCheckFramebufferStatus, GLenum);
API(void, glGenRenderbuffers, GLsizei, GLuint *);
API(void, glBindRenderbuffer, GLenum, GLuint);
API(void, glRenderbufferStorage, GLenum, GLenum, GLsizei, GLsizei);
API(void, glViewport, GLint, GLint, GLsizei, GLsizei);
API(void, glScissor, GLint, GLint, GLsizei, GLsizei);
API(void, glEnable, GLenum);
API(void, glDisable, GLenum);
API(void, glColorMask, GLuint, GLuint, GLuint, GLuint);
API(void, glClearColor, GLfloat, GLfloat, GLfloat, GLfloat);
API(void, glClearDepthf, GLfloat);
API(void, glClearStencil, GLint);
API(void, glClear, GLbitfield);
API(void, glDepthFunc, GLenum);
API(void, glDepthMask, GLuint);
API(void, glDepthRange, GLdouble, GLdouble);
API(void, glStencilFunc, GLenum, GLint, GLuint);
API(void, glStencilOp, GLenum, GLenum, GLenum);
API(void, glStencilMask, GLuint);
API(void, glDrawArrays, GLenum, GLint, GLsizei);
API(GLenum, glGetError, void);
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
API(void, glUniform4f, GLint, GLfloat, GLfloat, GLfloat, GLfloat);
API(void, glGenVertexArrays, GLsizei, GLuint *);
API(void, glBindVertexArray, GLuint);
API(void, glGenBuffers, GLsizei, GLuint *);
API(void, glBindBuffer, GLenum, GLuint);
API(void, glBufferData, GLenum, GLsizeiptr, const void *, GLenum);
API(void, glVertexAttribPointer, GLuint, GLint, GLenum, GLboolean, GLsizei, const void *);
API(void, glEnableVertexAttribArray, GLuint);
API(void, glFinish, void);

enum {
    GL_TEXTURE_2D=0x0DE1, GL_RGBA=0x1908, GL_RGBA8=0x8058, GL_UNSIGNED_BYTE=0x1401, GL_FLOAT=0x1406,
    GL_DEPTH_COMPONENT=0x1902, GL_DEPTH_STENCIL=0x84F9, GL_UNSIGNED_INT_24_8=0x84FA,
    GL_DEPTH_COMPONENT16=0x81A5, GL_DEPTH_COMPONENT24=0x81A6, GL_DEPTH_COMPONENT32F=0x8CAC, GL_STENCIL_INDEX8=0x8D48, GL_DEPTH24_STENCIL8=0x88F0,
    GL_FRAMEBUFFER=0x8D40, GL_RENDERBUFFER=0x8D41, GL_COLOR_ATTACHMENT0=0x8CE0,
    GL_DEPTH_ATTACHMENT=0x8D00, GL_STENCIL_ATTACHMENT=0x8D20, GL_DEPTH_STENCIL_ATTACHMENT=0x821A,
    GL_FRAMEBUFFER_COMPLETE=0x8CD5, GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT=0x8CD6, GL_FRAMEBUFFER_UNSUPPORTED=0x8CDD, GL_INVALID_FRAMEBUFFER_OPERATION=0x0506,
    GL_COLOR_BUFFER_BIT=0x4000, GL_DEPTH_BUFFER_BIT=0x0100, GL_STENCIL_BUFFER_BIT=0x0400,
    GL_BLEND=0x0BE2, GL_CULL_FACE=0x0B44, GL_SCISSOR_TEST=0x0C11, GL_DEPTH_TEST=0x0B71, GL_STENCIL_TEST=0x0B90,
    GL_NEVER=0x0200, GL_LESS=0x0201, GL_EQUAL=0x0202, GL_LEQUAL=0x0203, GL_GREATER=0x0204,
    GL_NOTEQUAL=0x0205, GL_GEQUAL=0x0206, GL_ALWAYS=0x0207,
    GL_KEEP=0x1E00, GL_REPLACE=0x1E01, GL_INCR=0x1E02, GL_DECR=0x1E03, GL_INVERT=0x150A,
    GL_INCR_WRAP=0x8507, GL_DECR_WRAP=0x8508, GL_ZERO=0,
    GL_TRIANGLES=4, GL_ARRAY_BUFFER=0x8892, GL_STATIC_DRAW=0x88E4,
    MAX_PIXELS=512, BLIT_SLOT=256
};
typedef struct { GLuint name; int rb; GLenum format; int w,h; } plane;
typedef struct { GLuint fbo,color; int w,h; plane depth,stencil; } bank;
typedef struct { __strong id<MTLTexture> image; NSUInteger x,y; uint8_t rgba[4]; char label[128]; } pixel_expect;
static pixel_expect expected[MAX_PIXELS];
static int expected_n,checks,fails;
static GLuint program;
static GLint u_z,u_color;
static const uint8_t blue[4]={0,0,255,255},red[4]={255,0,0,255},green[4]={0,255,0,255};
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; fprintf(stderr,"FAIL "); fprintf(stderr,__VA_ARGS__); fputc('\n',stderr); } } while (0)
static void require(int ok,const char *what) { if (!ok) { fprintf(stderr,"ERROR %s\n",what); exit(2); } }
static void no_error(const char *label) { GLenum e=glGetError(); CHECK(e==0,"%s GL error=%#x",label,e); }
static void error_is(GLenum want,const char *label) { GLenum e=glGetError(); CHECK(e==want,"%s expected GL error=%#x got=%#x",label,want,e); }
static void load_api(void) {
#define LOAD(name) do { name=(__typeof__(name))gl_lookup(#name); require(name!=NULL,#name); } while (0)
    LOAD(eglGetDisplay); LOAD(eglInitialize); LOAD(eglBindAPI); LOAD(eglCreateContext); LOAD(eglMakeCurrent); LOAD(eglDestroyContext);
    LOAD(glGenTextures); LOAD(glDeleteTextures); LOAD(glBindTexture); LOAD(glTexImage2D); LOAD(glTexStorage2D);
    LOAD(glGenFramebuffers); LOAD(glDeleteFramebuffers); LOAD(glBindFramebuffer); LOAD(glFramebufferTexture2D); LOAD(glFramebufferRenderbuffer); LOAD(glCheckFramebufferStatus);
    LOAD(glGenRenderbuffers); LOAD(glBindRenderbuffer); LOAD(glRenderbufferStorage);
    LOAD(glViewport); LOAD(glScissor); LOAD(glEnable); LOAD(glDisable); LOAD(glColorMask); LOAD(glClearColor); LOAD(glClearDepthf); LOAD(glClearStencil); LOAD(glClear);
    LOAD(glDepthFunc); LOAD(glDepthMask); LOAD(glDepthRange); LOAD(glStencilFunc); LOAD(glStencilOp); LOAD(glStencilMask); LOAD(glDrawArrays); LOAD(glGetError);
    LOAD(glCreateShader); LOAD(glShaderSource); LOAD(glCompileShader); LOAD(glGetShaderiv); LOAD(glCreateProgram); LOAD(glAttachShader); LOAD(glLinkProgram); LOAD(glGetProgramiv);
    LOAD(glUseProgram); LOAD(glGetAttribLocation); LOAD(glGetUniformLocation); LOAD(glUniform1f); LOAD(glUniform4f);
    LOAD(glGenVertexArrays); LOAD(glBindVertexArray); LOAD(glGenBuffers); LOAD(glBindBuffer); LOAD(glBufferData); LOAD(glVertexAttribPointer); LOAD(glEnableVertexAttribArray); LOAD(glFinish);
#undef LOAD
}
static char *read_shader(const char *name) {
    const char *dir=getenv("T_GPU_DIR"); require(dir!=NULL,"T_GPU_DIR"); char path[2048]; snprintf(path,sizeof path,"%s/%s",dir,name);
    FILE *f=fopen(path,"rb"); require(f!=NULL,path); require(!fseek(f,0,SEEK_END),"shader seek"); long n=ftell(f); require(n>0,"shader size"); rewind(f);
    char *p=calloc((size_t)n+1,1); require(p!=NULL,"shader allocation"); require(fread(p,1,(size_t)n,f)==(size_t)n,"shader read"); fclose(f); return p;
}
static GLuint shader(const char *name,GLenum stage) {
    char *p=read_shader(name); GLuint sh=glCreateShader(stage); const GLchar *src=p; glShaderSource(sh,1,&src,NULL); free(p); glCompileShader(sh);
    GLint ok=0; glGetShaderiv(sh,0x8B81,&ok); require(ok==1,name); return sh;
}
static void geometry(void) {
    GLuint vao,vbo; const float verts[]={-1,-1,3,-1,-1,3};
    glGenVertexArrays(1,&vao); glBindVertexArray(vao); glGenBuffers(1,&vbo); glBindBuffer(GL_ARRAY_BUFFER,vbo); glBufferData(GL_ARRAY_BUFFER,sizeof verts,verts,GL_STATIC_DRAW);
    program=glCreateProgram(); glAttachShader(program,shader("ds.vert",0x8B31)); glAttachShader(program,shader("ds.frag",0x8B30)); glLinkProgram(program);
    GLint ok=0; glGetProgramiv(program,0x8B82,&ok); require(ok==1,"link ds shaders"); glUseProgram(program);
    GLint pos=glGetAttribLocation(program,"aPos"); u_z=glGetUniformLocation(program,"uZ"); u_color=glGetUniformLocation(program,"uColor"); require(pos>=0&&u_z>=0&&u_color>=0,"ds shader locations");
    glVertexAttribPointer((GLuint)pos,2,GL_FLOAT,0,2*sizeof(float),NULL); glEnableVertexAttribArray((GLuint)pos);
}
static plane make_plane(int rb,GLenum format,int w,int h) {
    plane p={.rb=rb,.format=format,.w=w,.h=h};
    if (rb) { glGenRenderbuffers(1,&p.name); glBindRenderbuffer(GL_RENDERBUFFER,p.name); glRenderbufferStorage(GL_RENDERBUFFER,format,w,h); }
    else {
        glGenTextures(1,&p.name); glBindTexture(GL_TEXTURE_2D,p.name);
        if (format==GL_STENCIL_INDEX8) glTexStorage2D(GL_TEXTURE_2D,1,format,w,h);
        else glTexImage2D(GL_TEXTURE_2D,0,format,w,h,0,format==GL_DEPTH24_STENCIL8?GL_DEPTH_STENCIL:GL_DEPTH_COMPONENT,format==GL_DEPTH24_STENCIL8?GL_UNSIGNED_INT_24_8:GL_FLOAT,NULL);
    }
    no_error("allocate depth/stencil plane"); return p;
}
static plane packed_storage(int w,int h) {
    plane p={.format=GL_DEPTH24_STENCIL8,.w=w,.h=h}; glGenTextures(1,&p.name); glBindTexture(GL_TEXTURE_2D,p.name);
    glTexStorage2D(GL_TEXTURE_2D,1,p.format,w,h); no_error("packed immutable storage with level view"); return p;
}
static void attach_plane(GLenum slot,plane p) {
    if (p.rb) glFramebufferRenderbuffer(GL_FRAMEBUFFER,slot,GL_RENDERBUFFER,p.name);
    else glFramebufferTexture2D(GL_FRAMEBUFFER,slot,GL_TEXTURE_2D,p.name,0);
}
static void reset_state(int w,int h) {
    glDisable(GL_DEPTH_TEST); glDisable(GL_STENCIL_TEST); glDisable(GL_SCISSOR_TEST); glDisable(GL_BLEND); glDisable(GL_CULL_FACE);
    glColorMask(1,1,1,1); glDepthMask(1); glDepthFunc(GL_LESS); glDepthRange(0,1);
    glStencilMask(255); glStencilFunc(GL_ALWAYS,0,255); glStencilOp(GL_KEEP,GL_KEEP,GL_KEEP); glViewport(0,0,w,h);
}
static void attach_color(bank *b) {
    size_t n=(size_t)b->w*b->h; uint8_t *pixels=malloc(n*4); require(pixels!=NULL,"initial color bytes");
    for (size_t i=0;i<n;i++) memcpy(pixels+i*4,blue,4);
    glGenTextures(1,&b->color); glBindTexture(GL_TEXTURE_2D,b->color); glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,b->w,b->h,0,GL_RGBA,GL_UNSIGNED_BYTE,pixels); free(pixels);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,b->color,0);
}
static void new_color(bank *b) {
    attach_color(b);
    glColorMask(1,1,1,1); glDisable(GL_SCISSOR_TEST); glClearColor(0,0,1,1); glClear(GL_COLOR_BUFFER_BIT);
}
static bank make_bank(int w,int h,plane d,plane s) {
    bank b={.w=w,.h=h,.depth=d,.stencil=s}; glGenFramebuffers(1,&b.fbo); glBindFramebuffer(GL_FRAMEBUFFER,b.fbo); reset_state(w,h);
    attach_plane(GL_DEPTH_ATTACHMENT,d); attach_plane(GL_STENCIL_ATTACHMENT,s); new_color(&b);
    CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE,"supported depth/stencil FBO complete");
    glClearDepthf(1); glClearStencil(0); glClear(GL_DEPTH_BUFFER_BIT|GL_STENCIL_BUFFER_BIT); no_error("initialize supported FBO"); return b;
}
static void draw(float z,const uint8_t rgba[4]) {
    glUseProgram(program); glUniform1f(u_z,z); glUniform4f(u_color,rgba[0]/255.f,rgba[1]/255.f,rgba[2]/255.f,rgba[3]/255.f); glDrawArrays(GL_TRIANGLES,0,3);
}
static id<MTLTexture> color_image(GLuint color) {
    gl_wd_shadow *s=gl_tex_wd(color); if (s&&s->tex) return s->tex;
    return gl_tex_attach(color,GL_TEXTURE_2D,0);
}
static void image_pixel(id<MTLTexture> image,NSUInteger x,NSUInteger y,const uint8_t rgba[4],const char *label) {
    require(expected_n<MAX_PIXELS,"pixel capacity"); require(image!=nil,"color image"); require(x<image.width&&y<image.height,"pixel bounds");
    pixel_expect *e=&expected[expected_n++]; e->image=image; e->x=x; e->y=y; memcpy(e->rgba,rgba,4); strlcpy(e->label,label,sizeof e->label);
}
static void center(const bank *b,const uint8_t rgba[4],const char *label) { id<MTLTexture> image=color_image(b->color); image_pixel(image,image.width/2,image.height/2,rgba,label); }
static void baseline_cases(void) {
    plane packed=make_plane(0,GL_DEPTH24_STENCIL8,16,16); bank a=make_bank(16,16,packed,packed);
    glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL,0,255); draw(0,red); center(&a,red,"shared packed positive control"); no_error("shared packed draw");
    plane d=make_plane(0,GL_DEPTH_COMPONENT32F,16,16),s=make_plane(0,GL_STENCIL_INDEX8,16,16); bank b=make_bank(16,16,d,s);
    glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glStencilFunc(GL_NEVER,0,255); draw(0,red); center(&b,blue,"separate D32 + S8 STENCIL NEVER rejects"); no_error("separate baseline draw");
}
static bank separate_bank(int drb,int srb,GLenum df,int w,int h) { return make_bank(w,h,make_plane(drb,df,w,h),make_plane(srb,GL_STENCIL_INDEX8,w,h)); }
static void source_combinations(void) {
    for (int f=0;f<2;f++) for (int d=0;d<2;d++) for (int s=0;s<2;s++) for (int mode=0;mode<5;mode++) {
        bank b=separate_bank(d,s,f?GL_DEPTH_COMPONENT32F:GL_DEPTH_COMPONENT16,16,16);
        if (mode!=2) glEnable(GL_DEPTH_TEST); if (mode!=1) glEnable(GL_STENCIL_TEST);
        glDepthFunc(mode==1||mode==4?GL_NEVER:GL_LESS); glStencilFunc(mode==2||mode==3?GL_NEVER:GL_EQUAL,0,255);
        draw(0,red); char label[128]; snprintf(label,sizeof label,"D%s %s + S8 %s gating%d",f?"32":"16",d?"RB":"texture",s?"RB":"texture",mode);
        center(&b,mode==0?red:blue,label); no_error(label);
    }
}
static void packed_planes(void) {
    // GL 4.5 §9.2.7 / §9.2.8.1：只更新指定 attachment；§17.3.3 / §17.3.4：缺平面时测试恒过。
    // mode3 只挂 depth + STENCIL NEVER 仍写红；mode4 只挂 stencil + DEPTH NEVER 仍写红。
    // 原规范：https://registry.khronos.org/OpenGL/specs/gl/glspec45.core.pdf
    for (int rb=0;rb<2;rb++) for (int mode=0;mode<5;mode++) {
        plane p=make_plane(rb,GL_DEPTH24_STENCIL8,16,16),none={0};
        bank b=make_bank(16,16,mode==4?none:p,mode==3?none:p);
        glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST);
        glDepthFunc(mode==1||mode==4?GL_NEVER:GL_LESS); glStencilFunc(mode==2||mode==3?GL_NEVER:GL_EQUAL,0,255);
        draw(0,red); char label[128]; snprintf(label,sizeof label,"packed %s mode%d shared / logical single plane",rb?"RB":"texture",mode);
        center(&b,mode==1||mode==2?blue:red,label); no_error(label);
    }
}
static void packed_stencil_views(void) {
    // 代表性的交叉来源：两种纯 depth 格式分别配 packed 纹理 / RB 的 stencil 平面。
    for (int f=0;f<2;f++) for (int drb=0;drb<2;drb++) for (int reject=0;reject<2;reject++) {
        bank b=make_bank(16,16,make_plane(drb,f?GL_DEPTH_COMPONENT32F:GL_DEPTH_COMPONENT16,16,16),make_plane(!drb,GL_DEPTH24_STENCIL8,16,16));
        glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glStencilFunc(reject?GL_NEVER:GL_EQUAL,0,255); draw(0,red);
        char label[128]; snprintf(label,sizeof label,"D%s %s + packed stencil %s %s",f?"32":"16",drb?"RB":"texture",drb?"texture":"RB",reject?"reject":"accept");
        center(&b,reject?blue:red,label); no_error(label);
    }
    bank mapped=separate_bank(0,1,GL_DEPTH_COMPONENT24,16,16); glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL,0,255);
    draw(0,red); center(&mapped,red,"D24 mapped to D32 + independent S8"); no_error("D24 separate stencil");
}
static void comparisons(void) {
    static const GLenum funcs[]={GL_NEVER,GL_LESS,GL_EQUAL,GL_LEQUAL,GL_GREATER,GL_NOTEQUAL,GL_GEQUAL,GL_ALWAYS};
    static const int depth_pass[]={0,0,1,1,0,0,1,1},stencil_pass[]={0,1,0,1,0,1,0,1};
    for (int i=0;i<8;i++) {
        bank d=separate_bank(0,0,GL_DEPTH_COMPONENT32F,16,16); glClearDepthf(.5f); glClear(GL_DEPTH_BUFFER_BIT);
        glEnable(GL_DEPTH_TEST); glDepthFunc(funcs[i]); draw(0,red); char label[128]; snprintf(label,sizeof label,"D32 comparison %#x incoming .5 stored .5",funcs[i]);
        center(&d,depth_pass[i]?red:blue,label); no_error(label);
        bank s=separate_bank(1,1,GL_DEPTH_COMPONENT16,16,16); glClearStencil(5); glClear(GL_STENCIL_BUFFER_BIT);
        glEnable(GL_STENCIL_TEST); glStencilFunc(funcs[i],3,255); draw(0,red); snprintf(label,sizeof label,"S8 comparison %#x reference3 stored5",funcs[i]);
        center(&s,stencil_pass[i]?red:blue,label); no_error(label);
    }
}
static void stencil_operations(void) {
    static const GLenum ops[]={GL_KEEP,GL_ZERO,GL_REPLACE,GL_INCR,GL_DECR,GL_INVERT,GL_INCR_WRAP,GL_DECR_WRAP};
    static const int initial[]={5,5,5,255,0,0x35,255,0},want[]={5,0,9,255,0,0xCA,0,255};
    for (int i=0;i<8;i++) {
        bank b=separate_bank(i&1,(i>>1)&1,GL_DEPTH_COMPONENT32F,16,16); glClearStencil(initial[i]); glClear(GL_STENCIL_BUFFER_BIT);
        glEnable(GL_STENCIL_TEST); glColorMask(0,0,0,0); glStencilFunc(GL_ALWAYS,9,255); glStencilOp(GL_KEEP,GL_KEEP,ops[i]); draw(0,red);
        new_color(&b); glStencilOp(GL_KEEP,GL_KEEP,GL_KEEP); glStencilFunc(GL_EQUAL,want[i],255); draw(0,red);
        char label[128]; snprintf(label,sizeof label,"stencil pass op %#x %d -> %d",ops[i],initial[i],want[i]); center(&b,red,label); no_error(label);
    }
    for (int depth_fail=0;depth_fail<2;depth_fail++) {
        bank b=separate_bank(0,1,GL_DEPTH_COMPONENT32F,16,16); glClearDepthf(0); glClearStencil(4); glClear(GL_DEPTH_BUFFER_BIT|GL_STENCIL_BUFFER_BIT);
        glEnable(GL_STENCIL_TEST); glColorMask(0,0,0,0);
        if (depth_fail) { glEnable(GL_DEPTH_TEST); glDepthFunc(GL_LESS); glStencilFunc(GL_ALWAYS,9,255); glStencilOp(GL_KEEP,GL_INCR,GL_KEEP); }
        else { glStencilFunc(GL_NEVER,9,255); glStencilOp(GL_REPLACE,GL_KEEP,GL_KEEP); }
        draw(0,red); new_color(&b); glDisable(GL_DEPTH_TEST); glStencilOp(GL_KEEP,GL_KEEP,GL_KEEP); glStencilFunc(GL_EQUAL,depth_fail?5:9,255); draw(0,red);
        center(&b,red,depth_fail?"stencil depth-fail INCR":"stencil-fail REPLACE"); no_error("stencil failure op");
    }
    bank masked=separate_bank(1,0,GL_DEPTH_COMPONENT16,16,16); glClearStencil(0xA5); glClear(GL_STENCIL_BUFFER_BIT);
    glEnable(GL_STENCIL_TEST); glColorMask(0,0,0,0); glStencilMask(0x0F); glStencilFunc(GL_ALWAYS,0x3C,255); glStencilOp(GL_KEEP,GL_KEEP,GL_REPLACE); draw(0,red);
    new_color(&masked); glStencilMask(255); glStencilOp(GL_KEEP,GL_KEEP,GL_KEEP); glStencilFunc(GL_EQUAL,0xAC,255); draw(0,red); center(&masked,red,"stencil replace write mask retains high bits"); no_error("stencil write mask");
    bank read=separate_bank(0,1,GL_DEPTH_COMPONENT32F,16,16); glClearStencil(0xA5); glClear(GL_STENCIL_BUFFER_BIT);
    glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL,0xF5,0x0F); draw(0,red); center(&read,red,"stencil compare read mask ignores high bits"); no_error("stencil read mask");
}
static void depth_write_masks(void) {
    for (int write=0;write<2;write++) {
        bank b=separate_bank(0,1,GL_DEPTH_COMPONENT32F,16,16); glClearDepthf(.75f); glClear(GL_DEPTH_BUFFER_BIT);
        glEnable(GL_DEPTH_TEST); glDepthFunc(GL_LESS); glDepthMask(write); draw(0,red);   // .5 < .75
        new_color(&b); glDepthMask(1); draw(.25f,green);   // .625 < .75, but not < .5 if the first draw wrote depth.
        center(&b,write?blue:green,write?"depth write enabled retains nearer .5":"depth write mask zero preserves .75"); no_error("depth draw write mask");
    }
}
static void clear_planes(void) {
    for (int plane_id=0;plane_id<2;plane_id++) {
        bank b=separate_bank(plane_id,1-plane_id,GL_DEPTH_COMPONENT32F,16,16);
        glClearDepthf(.25f); glClearStencil(7); glClear(GL_DEPTH_BUFFER_BIT|GL_STENCIL_BUFFER_BIT);
        if (plane_id==0) { glClearDepthf(.75f); glClear(GL_DEPTH_BUFFER_BIT); }
        else { glClearStencil(5); glClear(GL_STENCIL_BUFFER_BIT); }
        glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glDepthFunc(plane_id?GL_GREATER:GL_LESS); glStencilFunc(GL_EQUAL,plane_id?5:7,255);
        draw(0,red); center(&b,red,plane_id?"stencil-only clear preserves depth":"depth-only clear preserves stencil"); no_error("independent full plane clear");
    }
    bank dm=separate_bank(1,0,GL_DEPTH_COMPONENT16,16,16); glDepthMask(0); glClearDepthf(0); glClear(GL_DEPTH_BUFFER_BIT);
    glDepthMask(1); glEnable(GL_DEPTH_TEST); draw(0,red); center(&dm,red,"depth clear respects depth write mask zero"); no_error("depth clear mask");
    bank sm=separate_bank(0,1,GL_DEPTH_COMPONENT32F,16,16); glClearStencil(0xA5); glClear(GL_STENCIL_BUFFER_BIT);
    glStencilMask(0x0F); glClearStencil(0x3C); glClear(GL_STENCIL_BUFFER_BIT); glStencilMask(255); glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL,0xAC,255);
    draw(0,red); center(&sm,red,"stencil clear write mask preserves high bits"); no_error("stencil clear mask");
    for (int stencil=0;stencil<2;stencil++) {
        bank b=separate_bank(0,0,GL_DEPTH_COMPONENT32F,16,16); glEnable(GL_SCISSOR_TEST); glScissor(0,0,8,16);
        if (stencil) { glClearStencil(3); glClear(GL_STENCIL_BUFFER_BIT); }
        else { glClearDepthf(0); glClear(GL_DEPTH_BUFFER_BIT); }
        glDisable(GL_SCISSOR_TEST); if (stencil) { glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL,3,255); }
        else glEnable(GL_DEPTH_TEST);
        draw(0,red); id<MTLTexture> image=color_image(b.color);
        image_pixel(image,4,8,stencil?red:blue,stencil?"scissor stencil clear inside":"scissor depth clear inside");
        image_pixel(image,12,8,stencil?blue:red,stencil?"scissor stencil clear outside":"scissor depth clear outside"); no_error("scissor plane clear");
    }
    bank snap=separate_bank(1,1,GL_DEPTH_COMPONENT32F,16,16);
    glClearDepthf(.25f); glClear(GL_DEPTH_BUFFER_BIT); glClearDepthf(.75f); glClearStencil(3); glClear(GL_STENCIL_BUFFER_BIT); glClearStencil(9);
    glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glDepthFunc(GL_GREATER); glStencilFunc(GL_EQUAL,3,255); draw(0,red);
    center(&snap,red,"same-target pending clears snapshot each plane value"); no_error("same-target pending plane values");
}
static void lifetime_and_sizes(void) {
    bank a=separate_bank(0,0,GL_DEPTH_COMPONENT32F,16,16); glClearDepthf(0); glClearStencil(7); glClear(GL_DEPTH_BUFFER_BIT|GL_STENCIL_BUFFER_BIT);
    bank b=separate_bank(1,1,GL_DEPTH_COMPONENT16,16,16); glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL,0,255); draw(0,green);
    center(&b,green,"switch FBO new depth/stencil contents");
    glBindFramebuffer(GL_FRAMEBUFFER,a.fbo); reset_state(16,16); glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL,7,255); draw(0,red);
    center(&a,blue,"switch FBO preserves old pending depth rejection");
    new_color(&a); glDisable(GL_DEPTH_TEST); draw(0,red); center(&a,red,"switch FBO preserves old pending stencil7"); no_error("FBO switch pending clear");
    for (int stencil=0;stencil<2;stencil++) {
        bank r=separate_bank(stencil,stencil,GL_DEPTH_COMPONENT32F,16,16); glClearDepthf(.25f); glClearStencil(7); glClear(GL_DEPTH_BUFFER_BIT|GL_STENCIL_BUFFER_BIT);
        if (stencil) { glBindRenderbuffer(GL_RENDERBUFFER,r.stencil.name); glRenderbufferStorage(GL_RENDERBUFFER,GL_STENCIL_INDEX8,16,16); glClearStencil(3); glClear(GL_STENCIL_BUFFER_BIT); }
        else { glBindTexture(GL_TEXTURE_2D,r.depth.name); glTexImage2D(GL_TEXTURE_2D,0,GL_DEPTH_COMPONENT32F,16,16,0,GL_DEPTH_COMPONENT,GL_FLOAT,NULL); glClearDepthf(1); glClear(GL_DEPTH_BUFFER_BIT); }
        glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glDepthFunc(stencil?GL_GREATER:GL_LESS); glStencilFunc(GL_EQUAL,stencil?3:7,255); draw(0,red);
        center(&r,red,stencil?"stencil RB redefinition keeps pending depth .25":"depth texture redefinition keeps pending stencil7"); no_error("plane redefinition");
    }
    bank size=make_bank(16,16,make_plane(0,GL_DEPTH_COMPONENT32F,8,8),make_plane(1,GL_STENCIL_INDEX8,8,8));
    glClearColor(1,0,0,1); glClear(GL_COLOR_BUFFER_BIT); id<MTLTexture> cleared=color_image(size.color);
    image_pixel(cleared,4,4,red,"intersection color clear inside"); image_pixel(cleared,12,4,blue,"intersection color clear outside depth width"); image_pixel(cleared,4,12,blue,"intersection color clear outside stencil height");
    new_color(&size); glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL,0,255); draw(0,red); id<MTLTexture> image=color_image(size.color);
    image_pixel(image,4,4,red,"equal D/S sizes with larger color intersection inside"); image_pixel(image,12,4,blue,"larger color outside depth/stencil width"); image_pixel(image,4,12,blue,"larger color outside depth/stencil height"); no_error("larger color and equal depth/stencil sizes");
}
static void intersection_plane_clears(void) {
    for (int stencil=0;stencil<2;stencil++) {
        plane large=make_plane(0,stencil?GL_STENCIL_INDEX8:GL_DEPTH_COMPONENT32F,16,16),none={0};
        bank b=make_bank(16,16,stencil?none:large,stencil?large:none);
        if (stencil) { glClearStencil(5); glClear(GL_STENCIL_BUFFER_BIT); }
        else { glClearDepthf(.75f); glClear(GL_DEPTH_BUFFER_BIT); }
        // 先把单个大 plane 完整初始化，再换 8×8 颜色附件限制有效区域；不构造 Metal 不支持的异尺寸 D/S。
        GLuint large_color=b.color; b.w=b.h=8; attach_color(&b);
        if (stencil) { glClearStencil(3); glClear(GL_STENCIL_BUFFER_BIT); }
        else { glClearDepthf(.25f); glClear(GL_DEPTH_BUFFER_BIT); }
        b.w=b.h=16; b.color=large_color; glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,b.color,0);
        if (stencil) { glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL,5,255); }
        else { glEnable(GL_DEPTH_TEST); glDepthFunc(GL_LESS); }
        draw(0,red); id<MTLTexture> image=color_image(b.color);
        image_pixel(image,4,4,blue,stencil?"intersection stencil clear changed inside to3":"intersection depth clear changed inside to .25");
        image_pixel(image,12,4,red,stencil?"intersection stencil clear retained outside width=5":"intersection depth clear retained outside width=.75");
        image_pixel(image,4,12,red,stencil?"intersection stencil clear retained outside height=5":"intersection depth clear retained outside height=.75"); no_error("intersection plane clear preserves outside");
    }
}
static void cached_stencil_lifetimes(void) {
    plane nested=packed_storage(16,16); bank b=make_bank(16,16,make_plane(0,GL_DEPTH_COMPONENT32F,16,16),nested);
    glEnable(GL_STENCIL_TEST); glClearStencil(3); glClear(GL_STENCIL_BUFFER_BIT); glStencilFunc(GL_EQUAL,3,255);
    glEnable(GL_SCISSOR_TEST); glScissor(0,0,8,16); draw(0,red);
    glDisable(GL_SCISSOR_TEST); glClearStencil(7); glClear(GL_STENCIL_BUFFER_BIT); glStencilFunc(GL_EQUAL,7,255);
    glEnable(GL_SCISSOR_TEST); glScissor(8,0,8,16); draw(0,green); id<MTLTexture> image=color_image(b.color);
    image_pixel(image,4,8,red,"nested packed stencil view repeated draw left"); image_pixel(image,12,8,green,"nested packed stencil view repeated clear/draw right");
    plane replacement=make_plane(0,GL_DEPTH24_STENCIL8,16,16); bank tw=make_bank(16,16,replacement,replacement); (void)tw;
    glClearStencil(9); glClear(GL_STENCIL_BUFFER_BIT); glBindFramebuffer(GL_FRAMEBUFFER,b.fbo); reset_state(16,16);
    attach_plane(GL_STENCIL_ATTACHMENT,replacement); new_color(&b); glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL,9,255); draw(0,red);
    center(&b,red,"packed stencil attachment replacement reads9 from shared-packed writer"); no_error("cached texture stencil view lifetime");

    plane rb=make_plane(1,GL_DEPTH24_STENCIL8,16,16); bank r=make_bank(16,16,make_plane(0,GL_DEPTH_COMPONENT32F,16,16),rb);
    glEnable(GL_STENCIL_TEST); glClearStencil(3); glClear(GL_STENCIL_BUFFER_BIT); glStencilFunc(GL_EQUAL,3,255); draw(0,red); center(&r,red,"packed RB cached view before redefinition");
    glBindRenderbuffer(GL_RENDERBUFFER,rb.name); glRenderbufferStorage(GL_RENDERBUFFER,GL_DEPTH24_STENCIL8,16,16);
    // 通过共享 packed 路径写新存储，绕开旧 X32 view；回原 FBO 后若误用旧 view，其值3不能通过 ref7。
    bank writer=make_bank(16,16,rb,rb); (void)writer; glClearStencil(7); glClear(GL_STENCIL_BUFFER_BIT);
    glBindFramebuffer(GL_FRAMEBUFFER,r.fbo); reset_state(16,16); new_color(&r); glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL,7,255); draw(0,red);
    center(&r,red,"redefined packed RB reads7 written through shared-packed FBO"); no_error("packed RB storage view replacement");
}
int s2a_screen_h(void);
static void widened_planes(void) {
    for (int reject=0;reject<2;reject++) {
        bank b=separate_bank(0,0,GL_DEPTH_COMPONENT32F,1920,1080); glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glStencilFunc(reject?GL_NEVER:GL_EQUAL,0,255); draw(0,red);
        id<MTLTexture> image=color_image(b.color); gl_wd_shadow *dw=gl_tex_wd(b.depth.name),*sw=gl_tex_wd(b.stencil.name);
        id<MTLTexture> di=dw&&dw->tex?dw->tex:gl_tex_attach(b.depth.name,GL_TEXTURE_2D,0),si=sw&&sw->tex?sw->tex:gl_tex_attach(b.stencil.name,GL_TEXTURE_2D,0);
        CHECK(di.width==image.width&&si.width==image.width&&di.height==image.height&&si.height==image.height,"large color/depth/stencil actual extents all agree");
        // 窄屏加高（审计 P1-79，屏 1920×1350 → ky 1.25）：大附件按核心给的高加高到 1080 × 1.25 = 1350，宽不变；颜色 / 深度 / 模板三张一致（上一条 CHECK）
        int tall=s2a_screen_h()>1080;
        if (gl_wd_on()>0&&tall) { CHECK(image.width==1920&&image.height==1350,"tall widen must make large attachments 1920x1350, got %lux%lu",(unsigned long)image.width,(unsigned long)image.height);
            printf("tall widen: large attachment %lux%lu (expect 1920x1350)\n",(unsigned long)image.width,(unsigned long)image.height); }
        else if (gl_wd_on()>0) CHECK(image.width>1920,"FULL widen must widen all large attachments, width=%lu",(unsigned long)image.width);
        else CHECK(image.width==1920,"ordinary large target width stays1920");
        image_pixel(image,image.width/4,image.height/2,reject?blue:red,reject?"large separated STENCIL NEVER left quarter":"large separated accept left quarter");
        image_pixel(image,image.width*3/4,image.height/2,reject?blue:red,reject?"large separated STENCIL NEVER right quarter":"large separated accept right quarter"); no_error("large separated depth/stencil");
    }
}
static void widened_packed_stencil(void) {
    plane s=make_plane(0,GL_DEPTH24_STENCIL8,1920,1080); bank b=make_bank(1920,1080,make_plane(0,GL_DEPTH_COMPONENT32F,1920,1080),s);
    glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glClearStencil(3); glClear(GL_STENCIL_BUFFER_BIT); glStencilFunc(GL_EQUAL,3,255); draw(0,red);
    id<MTLTexture> old=color_image(b.color); gl_wd_shadow *sw=gl_tex_wd(s.name),*dw=gl_tex_wd(b.depth.name);
    id<MTLTexture> old_stencil=sw&&sw->tex?sw->tex:gl_tex_attach(s.name,GL_TEXTURE_2D,0);
    id<MTLTexture> old_depth=dw&&dw->tex?dw->tex:gl_tex_attach(b.depth.name,GL_TEXTURE_2D,0);
    CHECK(old_stencil.width==old.width&&old_depth.width==old.width,"large packed stencil/depth share actual color width");
    CHECK(old_stencil.usage&MTLTextureUsagePixelFormatView,"large packed stencil storage permits X32 view");
    CHECK(gl_wd_on()>0?(s2a_screen_h()>1080?old.width==1920&&old.height==1350:old.width>1920):old.width==1920,"large packed stencil respects ordinary/FULL width (tall: 1920x1350)");
    image_pixel(old,old.width/4,old.height/2,red,"packed stencil shadow before redefine left quarter"); image_pixel(old,old.width*3/4,old.height/2,red,"packed stencil shadow before redefine right quarter");
    glBindTexture(GL_TEXTURE_2D,s.name); glTexImage2D(GL_TEXTURE_2D,0,GL_DEPTH24_STENCIL8,1920,1080,0,GL_DEPTH_STENCIL,GL_UNSIGNED_INT_24_8,NULL);
    bank writer=make_bank(1920,1080,s,s); (void)writer; glClearStencil(7); glClear(GL_STENCIL_BUFFER_BIT);
    glBindFramebuffer(GL_FRAMEBUFFER,b.fbo); reset_state(1920,1080); new_color(&b); glClearDepthf(1); glClear(GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL,7,255); draw(0,green);
    id<MTLTexture> image=color_image(b.color); sw=gl_tex_wd(s.name); dw=gl_tex_wd(b.depth.name);
    id<MTLTexture> si=sw&&sw->tex?sw->tex:gl_tex_attach(s.name,GL_TEXTURE_2D,0),di=dw&&dw->tex?dw->tex:gl_tex_attach(b.depth.name,GL_TEXTURE_2D,0);
    CHECK(si!=old_stencil&&si.width==image.width&&di.width==image.width,"redefined packed stencil gets current correctly sized storage");
    CHECK(si.usage&MTLTextureUsagePixelFormatView,"redefined packed stencil shadow permits X32 view");
    image_pixel(image,image.width/4,image.height/2,green,"packed stencil shadow after redefine left quarter"); image_pixel(image,image.width*3/4,image.height/2,green,"packed stencil shadow after redefine right quarter"); no_error("large packed stencil shadow replacement");
}
static void pending_deleted_planes(void) {
    plane d=make_plane(0,GL_DEPTH_COMPONENT32F,16,16),s=packed_storage(16,16); bank b=make_bank(16,16,d,s);
    glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL,0,255); draw(0,red);   // 先形成 packed stencil 的缓存视图。
    glClearColor(0,1,0,1); glClearStencil(5); glClear(GL_COLOR_BUFFER_BIT|GL_STENCIL_BUFFER_BIT);
    id<MTLTexture> image=color_image(b.color); center(&b,green,"pending clear retains packed stencil view after FBO/texture deletion");
    glDeleteFramebuffers(1,&b.fbo); const GLuint names[]={d.name,s.name,b.color}; glDeleteTextures(3,names);
    // 下一张 FBO 使挂起清除兑现；原 D/S 的客体对象均已消失，仅生产 pending target 应持有它们。
    bank next=separate_bank(0,1,GL_DEPTH_COMPONENT16,16,16); draw(0,red); center(&next,red,"draw after deleted pending framebuffer");
    require(image!=nil,"held pending color storage"); no_error("delete pending depth/stencil objects");
}
static void rejected_attachments(void) {
    // 不在 --baseline 运行：旧库会把不支持的物理组合直接交 Metal，可能在驱动内部 abort。
    for (int packed_stencil=0;packed_stencil<2;packed_stencil++) {
        plane d=make_plane(packed_stencil,GL_DEPTH24_STENCIL8,16,16);
        plane s=make_plane(!packed_stencil,packed_stencil?GL_DEPTH24_STENCIL8:GL_STENCIL_INDEX8,16,16);
        bank b={.w=16,.h=16,.depth=d,.stencil=s}; glGenFramebuffers(1,&b.fbo); glBindFramebuffer(GL_FRAMEBUFFER,b.fbo); reset_state(16,16);
        attach_plane(GL_DEPTH_ATTACHMENT,d); attach_plane(GL_STENCIL_ATTACHMENT,s); attach_color(&b);
        CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_UNSUPPORTED,"packed depth + %s must report FRAMEBUFFER_UNSUPPORTED",packed_stencil?"another packed stencil":"independent S8"); no_error("unsupported status query");
        glClearColor(1,0,0,1); glClear(GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT|GL_STENCIL_BUFFER_BIT); error_is(GL_INVALID_FRAMEBUFFER_OPERATION,"unsupported clear");
        draw(0,red); error_is(GL_INVALID_FRAMEBUFFER_OPERATION,"unsupported draw");
        center(&b,blue,"rejected clear/draw leave original color bytes unchanged");
        CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_UNSUPPORTED,"rejected commands leave unsupported attachments intact");
        // 同一 FBO 改回支持的共享 image，换独立颜色存储，既核恢复也避免覆盖前一条期望。
        attach_plane(GL_STENCIL_ATTACHMENT,d); new_color(&b);
        CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE,"same FBO recovers to shared packed");
        glClearDepthf(1); glClearStencil(0); glClear(GL_DEPTH_BUFFER_BIT|GL_STENCIL_BUFFER_BIT); glEnable(GL_DEPTH_TEST); glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL,0,255); draw(0,green);
        center(&b,green,"supported attachment repair after rejected operations"); no_error("supported FBO after rejected pair");
    }
    {
        plane d=make_plane(0,GL_DEPTH_COMPONENT32F,8,12),s=make_plane(1,GL_STENCIL_INDEX8,12,8);
        bank b={.w=16,.h=16,.depth=d,.stencil=s}; glGenFramebuffers(1,&b.fbo); glBindFramebuffer(GL_FRAMEBUFFER,b.fbo); reset_state(16,16);
        attach_plane(GL_DEPTH_ATTACHMENT,d); attach_plane(GL_STENCIL_ATTACHMENT,s); attach_color(&b);
        CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_UNSUPPORTED,"different depth/stencil dimensions explicitly unsupported"); no_error("different depth/stencil size status");
        glClearColor(1,0,0,1); glClear(GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT|GL_STENCIL_BUFFER_BIT); error_is(GL_INVALID_FRAMEBUFFER_OPERATION,"different depth/stencil size clear");
        draw(0,red); error_is(GL_INVALID_FRAMEBUFFER_OPERATION,"different depth/stencil size draw"); center(&b,blue,"different depth/stencil size rejected without changing color"); no_error("different depth/stencil size errors consumed");
    }
    for (int stencil=0;stencil<2;stencil++) {
        bank b={.w=16,.h=16}; glGenFramebuffers(1,&b.fbo); glBindFramebuffer(GL_FRAMEBUFFER,b.fbo); reset_state(16,16); attach_color(&b);
        glFramebufferTexture2D(GL_FRAMEBUFFER,stencil?GL_STENCIL_ATTACHMENT:GL_DEPTH_ATTACHMENT,GL_TEXTURE_2D,b.color,0);
        CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT,"color image as %s reports incomplete attachment",stencil?"stencil":"depth");
        glClearColor(1,0,0,1); glClear(GL_COLOR_BUFFER_BIT); error_is(GL_INVALID_FRAMEBUFFER_OPERATION,"wrong-plane clear");
        draw(0,red); error_is(GL_INVALID_FRAMEBUFFER_OPERATION,"wrong-plane draw"); center(&b,blue,"wrong-plane operations leave initial color unchanged"); no_error("wrong-plane errors consumed");
    }
}
static void verify_pixels(void) {
    glFinish(); require(expected_n>0,"recorded pixels");
    id<MTLBuffer> bytes=[gl_dev newBufferWithLength:(NSUInteger)expected_n*BLIT_SLOT options:MTLResourceStorageModeShared]; require(bytes!=nil,"readback buffer");
    id<MTLCommandQueue> q=[gl_dev newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder]; require(blit!=nil,"readback blit");
    for (int i=0;i<expected_n;i++) { pixel_expect *e=&expected[i]; require(e->image.pixelFormat==MTLPixelFormatRGBA8Unorm,"RGBA8 color readback");
        [blit copyFromTexture:e->image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(e->x,e->y,0) sourceSize:MTLSizeMake(1,1,1)
                     toBuffer:bytes destinationOffset:(NSUInteger)i*BLIT_SLOT destinationBytesPerRow:BLIT_SLOT destinationBytesPerImage:BLIT_SLOT]; }
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted]; require(cb.status==MTLCommandBufferStatusCompleted&&!cb.error,"readback completed");
    for (int i=0;i<expected_n;i++) { const uint8_t *p=(const uint8_t *)bytes.contents+(NSUInteger)i*BLIT_SLOT; pixel_expect *e=&expected[i];
        CHECK(!memcmp(p,e->rgba,4),"%s pixel(%lu,%lu) expected %02x %02x %02x %02x got %02x %02x %02x %02x",e->label,(unsigned long)e->x,(unsigned long)e->y,
              e->rgba[0],e->rgba[1],e->rgba[2],e->rgba[3],p[0],p[1],p[2],p[3]); }
}
int main(int argc,char **argv) { @autoreleasepool {
    int baseline=argc==2&&!strcmp(argv[1],"--baseline"); require(argc==1||baseline,"usage: t_gpu_depth_stencil [--baseline]");
    load_api(); EGLDisplay display=eglGetDisplay(NULL); require(display&&eglInitialize(display,NULL,NULL),"EGL initialize"); require(eglBindAPI(0x30A2),"desktop GL API");
    EGLContext ctx=eglCreateContext(display,(EGLConfig)1,NULL,NULL); require(ctx&&eglMakeCurrent(display,NULL,NULL,ctx),"EGL current"); gl_dev_init(); geometry();
    printf("GPU %s, production EGL / GL / Metal, mode=%s\n",gl_dev.name.UTF8String,baseline?"baseline":"full"); baseline_cases();
    if (!baseline) {
        source_combinations(); packed_planes(); packed_stencil_views(); comparisons(); stencil_operations(); depth_write_masks(); clear_planes(); lifetime_and_sizes();
        intersection_plane_clears(); cached_stencil_lifetimes(); widened_planes(); widened_packed_stencil(); pending_deleted_planes();
        uint64_t feature=0,error=0; dm_gl_bad_draws(&feature,&error);
        CHECK(!feature&&!error,"valid cases bad-draw counters feature=%llu error=%llu",(unsigned long long)feature,(unsigned long long)error);
        rejected_attachments();
    }
    no_error("depth/stencil sequence"); verify_pixels();
    printf("%s t_gpu_depth_stencil: %d/%d checks, %d independent Metal pixels%s\n",fails?"✗":"✓",checks-fails,checks,expected_n,baseline?" (baseline subset)":"");
    eglDestroyContext(display,ctx); return fails?1:0;
} }
