// #272：默认纹理按上下文/目标持有，同目标跨单元共用；经真实 GL 绘制读回，不用名字0偷换成命名纹理。
// 纹理分片测试对象文件的calloc/free由脚本重命名到这里；产品编译不含这些符号。
static void *texture_allocs[2048]; static unsigned texture_live; static int texture_fail_once;
void *t_gl_tex_calloc(size_t n, size_t size) {
    if (texture_fail_once) { texture_fail_once=0; return NULL; }
    void *p=calloc(n,size); if (!p) return NULL;
    for (unsigned i=0;i<2048;i++) if (!texture_allocs[i]) { texture_allocs[i]=p; texture_live++; return p; }
    abort();
}
void t_gl_tex_free(void *p) {
    if (p) for (unsigned i=0;i<2048;i++) if (texture_allocs[i]==p) { texture_allocs[i]=NULL; texture_live--; break; }
    free(p);
}
static int default_textures(gpa_t gpa, EGLDisplay dpy, EGLSurface sf, EGLContext original) {
    F(eglBindAPI,EGLBoolean,EGLenum) F(eglCreateContext,EGLContext,EGLDisplay,EGLConfig,EGLContext,const EGLint *)
    F(eglMakeCurrent,EGLBoolean,EGLDisplay,EGLSurface,EGLSurface,EGLContext) F(eglDestroyContext,EGLBoolean,EGLDisplay,EGLContext)
    F(glCreateProgram,GLuint,void) F(glCreateShader,GLuint,GLenum) F(glShaderSource,void,GLuint,GLsizei,const GLchar *const *,const GLint *)
    F(glCompileShader,void,GLuint) F(glAttachShader,void,GLuint,GLuint) F(glLinkProgram,void,GLuint) F(glGetProgramiv,void,GLuint,GLenum,GLint *)
    F(glUseProgram,void,GLuint) F(glDeleteProgram,void,GLuint) F(glDeleteShader,void,GLuint)
    F(glGetUniformLocation,GLint,GLuint,const GLchar *) F(glUniform1i,void,GLint,GLint) F(glUniform1f,void,GLint,GLfloat)
    F(glUniform2f,void,GLint,GLfloat,GLfloat) F(glUniform3f,void,GLint,GLfloat,GLfloat,GLfloat)
    F(glGenVertexArrays,void,GLsizei,GLuint *) F(glBindVertexArray,void,GLuint) F(glDeleteVertexArrays,void,GLsizei,const GLuint *)
    F(glGenBuffers,void,GLsizei,GLuint *) F(glBindBuffer,void,GLenum,GLuint) F(glBufferData,void,GLenum,GLsizeiptr,const void *,GLenum)
    F(glDeleteBuffers,void,GLsizei,const GLuint *) F(glGetAttribLocation,GLint,GLuint,const GLchar *)
    F(glVertexAttribPointer,void,GLuint,GLint,GLenum,GLuint,GLsizei,const void *) F(glEnableVertexAttribArray,void,GLuint)
    F(glActiveTexture,void,GLenum) F(glBindTexture,void,GLenum,GLuint) F(glGenTextures,void,GLsizei,GLuint *) F(glDeleteTextures,void,GLsizei,const GLuint *)
    F(glTexParameteri,void,GLenum,GLenum,GLint) F(glTexImage2D,void,GLenum,GLint,GLint,GLsizei,GLsizei,GLint,GLenum,GLenum,const void *)
    F(glTexSubImage2D,void,GLenum,GLint,GLint,GLint,GLsizei,GLsizei,GLenum,GLenum,const void *) F(glTexStorage2D,void,GLenum,GLsizei,GLenum,GLsizei,GLsizei)
    F(glGenerateMipmap,void,GLenum) F(glGetIntegerv,void,GLenum,GLint *) F(glGetError,GLenum,void)
    F(glGenSamplers,void,GLsizei,GLuint *) F(glBindSampler,void,GLuint,GLuint) F(glSamplerParameteri,void,GLuint,GLenum,GLint) F(glDeleteSamplers,void,GLsizei,const GLuint *)
    F(glGenFramebuffers,void,GLsizei,GLuint *) F(glBindFramebuffer,void,GLenum,GLuint) F(glFramebufferTexture2D,void,GLenum,GLenum,GLenum,GLuint,GLint)
    F(glCheckFramebufferStatus,GLenum,GLenum) F(glDeleteFramebuffers,void,GLsizei,const GLuint *)
    F(glViewport,void,GLint,GLint,GLsizei,GLsizei) F(glClear,void,GLbitfield) F(glDrawArrays,void,GLenum,GLint,GLsizei) F(glFinish,void,void)
    enum { T2=0x0DE1, CUBE=0x8513, PX=0x8515, RGBA=0x1908, UB=0x1401, FB=0x8D40 };
    const uint8_t colors[6][4]={{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,255,255},{255,255,0,255},{0,255,255,255}};
    const float dirs[6][3]={{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
    const EGLint attrs[]={0x3098,3,0x30FB,2,0x3038};
    // 两种 API 都经相同生产入口；不把本片测试扩大成 EGL profile 一致性认证。
    for (int api=0; api<2; api++) {
        unsigned live_before=texture_live;
        eglBindAPI(api ? 0x30A2 : 0x30A0);
        EGLContext ctx=eglCreateContext(dpy,(EGLConfig)1,NULL,attrs);
        CHECK(ctx && eglMakeCurrent(dpy,sf,sf,ctx),"⑫ API%d 新默认纹理上下文",api);
        id<MTLTexture> col=gl_surface_color(); double k=(double)col.width/1920;
        glViewport(0,0,64,64);
        GLuint prog=glCreateProgram(), shaders[2];
        for (int i=0;i<2;i++) {
            char path[1024]; snprintf(path,sizeof path,"%s/cube.%s",getenv("T_GL_DIR"),i?"frag":"vert");
            FILE *f=fopen(path,"rb"); if (!f) return 1; fseek(f,0,SEEK_END); long n=ftell(f); rewind(f);
            char *src=calloc(1,(size_t)n+1); if (!src || fread(src,1,(size_t)n,f)!=(size_t)n) { free(src); fclose(f); return 1; } fclose(f);
            shaders[i]=glCreateShader(i?0x8B30:0x8B31); const char *s=src; glShaderSource(shaders[i],1,&s,NULL); free(src); glCompileShader(shaders[i]); glAttachShader(prog,shaders[i]);
        }
        glLinkProgram(prog); GLint ok; glGetProgramiv(prog,0x8B82,&ok); CHECK(ok,"⑫ 默认纹理采样程序链接"); if (!ok) return 1; glUseProgram(prog);
        GLint tex=glGetUniformLocation(prog,"uTex"), cube=glGetUniformLocation(prog,"uCube"), use=glGetUniformLocation(prog,"uUse2D"), dir=glGetUniformLocation(prog,"uDir");
        GLint off=glGetUniformLocation(prog,"uOff"), scale=glGetUniformLocation(prog,"uScale");
        glUniform1i(tex,0); glUniform1i(cube,1); glUniform1f(use,1); glUniform3f(dir,1,0,0); glUniform2f(off,0,0); glUniform2f(scale,1,1);
        GLuint vao,vbo; glGenVertexArrays(1,&vao); glBindVertexArray(vao); glGenBuffers(1,&vbo); glBindBuffer(0x8892,vbo);
        const float quad[]={-1,-1,1,-1,-1,1,-1,1,1,-1,1,1}; glBufferData(0x8892,sizeof quad,quad,0x88E4);
        GLint pos=glGetAttribLocation(prog,"aPos"); glVertexAttribPointer(pos,2,0x1406,0,8,NULL); glEnableVertexAttribArray(pos);
#define ZDRAW() do { glClear(0x4000); glDrawArrays(4,0,6); glFinish(); } while (0)
#define ZPIX(c,label) tex_pixel(col,(uint32_t)(32*k),32,c,"默认纹理 " label)
        glTexStorage2D(T2,1,0x8058,1,1); CHECK(glGetError()==0x0502 && texture_live==live_before,"⑫ Storage拒绝零号时不分配默认对象");
        texture_fail_once=1; glTexImage2D(T2,0,0x8058,1,1,0,RGBA,UB,colors[0]);
        GLint failed_binding=-1; glGetIntegerv(0x8069,&failed_binding);
        CHECK(!texture_fail_once && glGetError()==0x0505 && failed_binding==0 && texture_live==live_before,"⑫ 默认对象分配失败报OOM，不改变绑定、不发布半对象");
        texture_fail_once=0; // 反证跑旧代码时也不把尚未消费的失败注入带进后面的命名对象测试。
        glTexParameteri(T2,0x2801,0x2600); glTexParameteri(T2,0x2800,0x2600);
        glTexImage2D(T2,0,0x8058,1,1,0,RGBA,UB,colors[0]);
        CHECK(glGetError()==0,"⑫ 初始零号绑定允许参数和上传"); ZDRAW(); ZPIX(colors[0],"初始绑定红");
        if (getenv("T_GL_WIDEN")) CHECK(g_wd_ntex==1 && g_wd_tex[0].w==1 && g_wd_tex[0].h==1,"⑫ 宽屏收到默认2D的1×1尺寸，不误报未定义cube");
        // 默认cube与2D同名0但不是同一对象，六面各自独立。
        glActiveTexture(0x84C1); glTexParameteri(CUBE,0x2801,0x2600); glTexParameteri(CUBE,0x2800,0x2600);
        for (int face=0;face<6;face++) glTexImage2D(PX+face,0,0x8058,1,1,0,RGBA,UB,colors[face]);
        glUniform1f(use,0);
        for (int face=0;face<6;face++) { glUniform3f(dir,dirs[face][0],dirs[face][1],dirs[face][2]); ZDRAW(); tex_pixel(col,(uint32_t)(32*k),32,colors[face],"默认cube六面"); }
        glUniform1f(use,1); ZDRAW(); ZPIX(colors[0],"2D未被cube覆盖");
        if (getenv("T_GL_WIDEN")) CHECK(g_wd_ntex==2,"⑫ 宽屏同时收到默认2D与cube");
        // 默认参数仍需mip；已有采样器只覆盖它所在单元，解绑后恢复纹理本身的NEAREST。
        glActiveTexture(0x84C0); const uint8_t quadcols[4][4]={{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,255,255}};
        glTexImage2D(T2,0,0x8058,2,2,0,RGBA,UB,quadcols); ZDRAW(); ZPIX(colors[3],"NEAREST中心取右上白");
        GLuint sampler; glGenSamplers(1,&sampler); glSamplerParameteri(sampler,0x2801,0x2601); glSamplerParameteri(sampler,0x2800,0x2601); glBindSampler(0,sampler);
        const uint8_t gray[4]={128,128,128,255}; ZDRAW(); ZPIX(gray,"sampler LINEAR覆盖为四格平均");
        glBindSampler(0,0); glDeleteSamplers(1,&sampler); ZDRAW(); ZPIX(colors[3],"解绑sampler恢复默认对象参数");
        glTexImage2D(T2,0,0x8058,1,1,0,RGBA,UB,colors[0]); glActiveTexture(0x84C1);
        // 同目标跨单元共享；uniform显式选择单元，不能只检查active_unit。
        glUniform1i(tex,1); ZDRAW(); ZPIX(colors[0],"单元1看见单元0的默认2D");
        glTexSubImage2D(T2,0,0,0,1,1,RGBA,UB,colors[1]); glUniform1i(tex,0); ZDRAW(); ZPIX(colors[1],"单元0看见单元1改绿");
        glActiveTexture(0x84C0); GLuint named; glGenTextures(1,&named); glBindTexture(T2,named);
        glTexParameteri(T2,0x2801,0x2600); glTexParameteri(T2,0x2800,0x2600); glTexImage2D(T2,0,0x8058,1,1,0,RGBA,UB,colors[2]);
        ZDRAW(); ZPIX(colors[2],"命名对象蓝"); glBindTexture(T2,0); ZDRAW(); ZPIX(colors[1],"重新绑定0仍绿");
        GLuint zero=0; glDeleteTextures(1,&zero); glBindTexture(T2,named); glDeleteTextures(1,&named);
        GLint binding=-1; glGetIntegerv(0x8069,&binding); CHECK(binding==0,"⑫ 删除命名纹理恢复绑定0"); ZDRAW(); ZPIX(colors[1],"删除0及命名纹理不清掉默认图");
        glTexStorage2D(T2,1,0x8058,1,1); CHECK(glGetError()==0x0502,"⑫ TexStorage2D仍拒绝零号"); ZDRAW(); ZPIX(colors[1],"Storage失败保留原绿");
        glTexSubImage2D(T2,0,1,0,1,1,RGBA,UB,colors[0]); CHECK(glGetError()==0x0501,"⑫ 默认纹理越界上传拒绝"); ZDRAW(); ZPIX(colors[1],"越界失败不改原图");
        const uint8_t green4[4][4]={{0,255,0,255},{0,255,0,255},{0,255,0,255},{0,255,0,255}};
        glTexImage2D(T2,0,0x8058,2,2,0,RGBA,UB,green4); glGenerateMipmap(T2); glTexParameteri(T2,0x813C,1);
        ZDRAW(); ZPIX(colors[1],"默认对象生成mip后采起始级1仍绿"); glTexParameteri(T2,0x813C,0);
        // 两笔同提交：沿用既有在途快照，不能为了默认纹理新增等待或切遍。
        glTexImage2D(T2,0,0x8058,1,1,0,RGBA,UB,colors[0]); glUniform2f(scale,.45f,.8f); glUniform2f(off,-.5f,0);
        uint64_t fr,dr,pa,d0,p0; dm_gl_stats(&fr,&d0,&p0); glClear(0x4000); glDrawArrays(4,0,6);
        glTexSubImage2D(T2,0,0,0,1,1,RGBA,UB,colors[1]); glUniform2f(off,.5f,0); glDrawArrays(4,0,6); glFinish();
        tex_pixel(col,(uint32_t)(16*k),32,colors[0],"默认纹理在途旧红"); tex_pixel(col,(uint32_t)(48*k),32,colors[1],"默认纹理在途新绿");
        dm_gl_stats(&fr,&dr,&pa); CHECK(dr==d0+2 && pa==p0+1,"⑫ 默认纹理上传两笔一遍"); glUniform2f(scale,1,1); glUniform2f(off,0,0);
        // FBO的texture=0是解绑，不能因默认纹理已定义就挂上它。
        GLuint fb; glGenFramebuffers(1,&fb); glBindFramebuffer(FB,fb); glFramebufferTexture2D(FB,0x8CE0,T2,0,0);
        CHECK(glCheckFramebufferStatus(FB)==0x8CD7,"⑫ FBO零号附件仍为缺附件"); glBindFramebuffer(FB,0); glDeleteFramebuffers(1,&fb);
        // B只上传、不借用A的命名对象；切回A采样，证明默认图像跨上下文不串。
        EGLContext other=eglCreateContext(dpy,(EGLConfig)1,NULL,attrs); glFinish(); eglMakeCurrent(dpy,sf,sf,other);
        glTexImage2D(T2,0,0x8058,1,1,0,RGBA,UB,colors[2]); CHECK(glGetError()==0,"⑫ B默认对象独立上传");
        eglMakeCurrent(dpy,sf,sf,ctx); eglDestroyContext(dpy,other); ZDRAW(); ZPIX(colors[1],"切回A仍绿，销毁B不影响A");
        CHECK(glGetError()==0,"⑫ 默认对象有效绘制无错误");
        glFinish(); glUseProgram(0); glDeleteProgram(prog); for(int i=0;i<2;i++) glDeleteShader(shaders[i]);
        glDeleteBuffers(1,&vbo); glDeleteVertexArrays(1,&vao); eglMakeCurrent(dpy,sf,sf,original); eglDestroyContext(dpy,ctx);
        CHECK(texture_live==live_before,"⑫ 默认对象释放回到原对象数（原%u，现%u）",live_before,texture_live);
#undef ZDRAW
#undef ZPIX
    }
    return 0;
}
