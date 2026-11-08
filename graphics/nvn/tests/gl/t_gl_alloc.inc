// 只在 t_gl_min.sh 编译测试库时把 calloc 重定向到此钩子；产品构建不含替换。
// 故障只在一次受测 Gen/Create 调用期间启用，不影响框架或测试自身分配。
static size_t alloc_fail_at, alloc_calls;
void *t_gl_calloc(size_t n, size_t size) {
    if (alloc_fail_at && ++alloc_calls == alloc_fail_at) return NULL;
    return calloc(n, size);
}
static void alloc_arm(size_t at) { alloc_calls = 0; alloc_fail_at = at; }
static void alloc_disarm(void) { alloc_fail_at = 0; }

static int allocation_case(void) {
    gpa_t gpa = gl_lookup;
    F(glGetError, GLenum, void)
    F(glCreateShader, GLuint, GLenum) F(glDeleteShader, void, GLuint)
    F(glCreateProgram, GLuint, void) F(glDeleteProgram, void, GLuint)
    F(glAttachShader, void, GLuint, GLuint)
    F(glGetShaderiv, void, GLuint, GLenum, GLint *)
    F(glGetProgramiv, void, GLuint, GLenum, GLint *)
    // 只测生产 GL 对象与错误状态；无 EGL 表面、GPU 命令、宿主或游戏。
    gl_state state = {0}; gl_state *saved = gl_cur; gl_cur = &state;
    enum { OOM = 0x0505, INVALID_OPERATION = 0x0502 };
    gl_names empty = {0};
    CHECK(gl_name_new(&empty, NULL) == 0 && !empty.n && !empty.cap && !empty.v,
          "分配失败不初始化/扩容名字表、不发布名字");
    CHECK(glGetError() == OOM && glGetError() == 0, "NULL 对象设置一次 OOM");
    free(empty.v);
    static const struct { const char *gen, *del, *bind; GLenum target; } kinds[] = {
        {"glGenBuffers", "glDeleteBuffers", "glBindBuffer", 0x8892},
        {"glGenVertexArrays", "glDeleteVertexArrays", "glBindVertexArray", 0},
        {"glGenFramebuffers", "glDeleteFramebuffers", "glBindFramebuffer", 0x8D40},
        {"glGenRenderbuffers", "glDeleteRenderbuffers", "glBindRenderbuffer", 0x8D41},
    };
    for (unsigned t = 0; t < sizeof kinds / sizeof *kinds; t++) {
        void (*gen)(GLsizei, GLuint *) = (void *)gpa(kinds[t].gen);
        void (*del)(GLsizei, const GLuint *) = (void *)gpa(kinds[t].del);
        void *bind = gpa(kinds[t].bind);
        CHECK(gen && del && bind, "%s 真实登记入口存在", kinds[t].gen);
        if (!gen || !del || !bind) { gl_cur = saved; return 1; }
        GLuint seed[2]; gen(2, seed); del(1, seed); // 留一个空槽、一个存活名字。
        CHECK(seed[0] && seed[1] && seed[0] != seed[1] && glGetError() == 0,
              "%s 初始两个对象有效且互异", kinds[t].gen);
        for (int k = 1; k <= 3; k++) {
            GLuint out[3] = {~0u, ~0u, ~0u};
            alloc_arm((size_t)k); gen(3, out); alloc_disarm();
            CHECK(alloc_calls == 3, "%s 第 %d 次失败后仍完成三项输出", kinds[t].gen, k);
            CHECK(glGetError() == OOM && glGetError() == 0,
                  "%s 第 %d 次失败只记录一次 OOM", kinds[t].gen, k);
            int names_ok = out[k - 1] == 0;
            for (int i = 0; i < 3; i++) if (i != k - 1) {
                names_ok &= out[i] != 0 && out[i] != ~0u && out[i] != seed[1];
                for (int j = i + 1; j < 3; j++) if (j != k - 1) names_ok &= out[i] != out[j];
            }
            CHECK(names_ok, "%s 第 %d 项为0，其余有效且不重复已发布名字", kinds[t].gen, k);
            for (int i = 0; i < 3; i++) if (out[i]) {
                if (kinds[t].target) ((void (*)(GLenum, GLuint))bind)(kinds[t].target, out[i]);
                else ((void (*)(GLuint))bind)(out[i]);
            }
            CHECK(glGetError() == 0, "%s 同批成功对象都能 Bind", kinds[t].gen);
            GLuint next = 0; gen(1, &next);
            CHECK(next && next != seed[1] && next != out[0] && next != out[1] && next != out[2] && glGetError() == 0,
                  "%s 恢复分配后新对象不复用已发布名字", kinds[t].gen);
            del(3, out); del(1, &next);
        }
        GLuint out[3] = {~0u, ~0u, ~0u};
        gl_set_error(INVALID_OPERATION); alloc_arm(2); gen(3, out); alloc_disarm();
        CHECK(out[1] == 0 && glGetError() == INVALID_OPERATION && glGetError() == 0,
              "%s OOM 不覆盖尚未取走的首错误", kinds[t].gen);
        del(3, out); del(1, &seed[1]);
    }
    GLuint shader = glCreateShader(0x8B31), program = glCreateProgram();
    CHECK(shader && program && glGetError() == 0, "Shader/Program 初始对象有效");
    for (int k = 0; k < 2; k++) {
        alloc_arm(1); GLuint bad = k ? glCreateProgram() : glCreateShader(0x8B31); alloc_disarm();
        CHECK(alloc_calls == 1 && bad == 0 && glGetError() == OOM && glGetError() == 0,
              "Create%s 对象分配失败返回0、不写空指针、记录OOM", k ? "Program" : "Shader");
        GLuint good = k ? glCreateProgram() : glCreateShader(0x8B30);
        CHECK(good && good != (k ? program : shader) && glGetError() == 0,
              "Create%s 恢复后名字不重复", k ? "Program" : "Shader");
        GLint status = -1;
        if (k) { glAttachShader(good, shader); glGetProgramiv(good, 0x8B82, &status); }
        else { glAttachShader(program, good); glGetShaderiv(good, 0x8B81, &status); }
        CHECK(status == 0 && glGetError() == 0, "Create%s 成功对象可经真实API查询/附加", k ? "Program" : "Shader");
        if (k) glDeleteProgram(good); else glDeleteShader(good);
    }
    glDeleteProgram(program); glDeleteShader(shader);
    gl_cur = saved;
    return 0;
}
