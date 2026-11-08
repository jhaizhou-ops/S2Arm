// NVN2 任务 / 网格绘制（11-05，时之笛 0400486024DEC000 进 3D 场景用 DrawMeshTasks / DrawMeshTasksIndirect）：直接包含生产 nvn_mtl.m，经 draw()（OP_DRAW 图元 DM_PRIM_MESH_TASKS）
//   走产品的网格绘制路径画到离屏目标、读回像素。着色器是 mk 用 xcrun metal 编好的真库（t_nvn_mesh.metal，形状照「网格着色接口约定」：入口 main0 / main0_z、起始工作组号在 buffer(29)），
//   反射 json 由本测按约定字段写进库目录，经产品的 shader_get → shader_build 载入。片元着色器写白。
// 期望按约定与夹具几何手算，不由被测实现推出（目标 8×4 RGBA8，先清黑；网格工作组画第 c 列整列，列掩码 bit c = 该列 4 个像素全白）：
//   ① 载入：任务 1111… 是 object（线程 32、载荷 4 → 管线按 16 对齐）；网格 2222… 是 mesh 且带任务、3333… 不带；开 near = 0 后网格载入的入口是 main0_z
//   ② 网格上限：max_vertices 300（> Metal 256）的网格着色器载不进来（nil），报红 1 行点名该键
//   ③ 只绑任务 / 网格 / 片元（BindProgram 位 0x40|0x80|0x02 录成 0x1a，hle_nvn.c）的程序不要求顶点阶段：bind_stages 回这个程序本身（改前回 NULL = 「没有程序」，整笔丢）
//   ④ 无任务 DrawMeshTasks(first 2, count 3)：首笔管线在后台建、本笔跳过并计数（等待数 +1、不报红）；建好后再画 → 列 2、3、4 白 = 0x1c
//   ⑤ 有任务 DrawMeshTasks(first 1, count 2)：任务 t = 1、2 各派 2 个网格组，列 2t、2t+1 → 列 2..5 = 0x3c
//   ⑥ 间接：参数位置 CPU 先写 {7, 0}（录制 / 回放若在 CPU 上读会画列 0..6），同一提交里 GPU 拷贝写成 {3, 4} 后再画 → 列 4、5、6 = 0x70；交完后该处 CPU 读到 {3, 4}
//   ⑦ 间接零工作量：GPU 写 {0, 1} → 一列都不画（0x00）、不报红、照样记一笔间接绘制
//   ⑧ 程序没有网格着色器：跳过、报红 1 行（不当普通绘制画）
//   ⑨ 着色器映射表的阶段名（翻译侧 shader_map.tsv 第 3 列写 task / mesh）经 prog_get 的 stage_of 落到宿主阶段 3 / 4（nvn2_stage_host：NVN 阶段 6 / 7 放曲面两阶段的位置），
//      shader_get 按该阶段载入的是 object / mesh 着色器（11-06 时之笛日志每局 20–30 行「shader … (task|mesh) failed to load」：stage_of 不认这两个名字回 -1，库里明明有）
//   ⑩ GPU 没有对象 / 网格管线（g_mesh_ok = 0，MTLGPUFamilyMetal3 以下）：跳过并计数、报红 1 行、不画（不当普通绘制画）
// 负对照（11-05 手工做，见坑记录）：把 mtk_encode 写进 29 号槽的起始号换成 0 → ④ 0x07、⑤ 0x0f、⑥ 0x07，三项红
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *capture(void (^f)(void)) {   // 这一段打到 stderr 的全部行
    char path[] = "/tmp/t_nvn_mesh_XXXXXX"; int fd = mkstemp(path); REQUIRE(fd >= 0);
    fflush(stderr); int saved = dup(2); REQUIRE(saved >= 0); dup2(fd, 2); close(fd);
    f();
    fflush(stderr); dup2(saved, 2); close(saved);
    NSString *out = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil] ?: @"";
    unlink(path); return out;
}
static int red_lines(NSString *text, NSString *needle) {
    int n = 0; for (NSString *l in [text componentsSeparatedByString:@"\n"]) n += [l containsString:@"【红】"] && (!needle || [l containsString:needle]); return n;
}
static void put_json(NSString *dir, NSString *key, NSDictionary *extra) {
    NSMutableDictionary *j = [@{@"route": @"B", @"bindings": @[], @"chain": @DMSH_CHAIN, @"entry": @"main0"} mutableCopy]; [j addEntriesFromDictionary:extra];
    NSData *d = [NSJSONSerialization dataWithJSONObject:j options:0 error:nil]; REQUIRE(d);
    NSString *path = [NSString stringWithFormat:@"%@/%@.json", dir, key]; REQUIRE([d writeToFile:path atomically:YES]);
}
static tex_t g_rt;
static void rt_make(void) {
    memset(&g_rt, 0, sizeof g_rt); g_rt.magic = MAGIC('T', 'E', 'X', 0); g_rt.serial = nvn_new_serial();
    g_rt.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 8, .height = 4, .depth = 1, .levels = 1};
    nvn_tex_layout(&g_rt.d, &g_rt.L); nvn_be_tex_init(&g_rt); REQUIRE(tex_mtl(&g_rt));
}
static uint64_t g_frame = 1;
static void frame_begin(void) {   // 新的一帧：目标设成 g_rt 并清黑（清除在渲染遍开时落下）
    nvn_be_set_frame(++g_frame); nvn_be_sub_begin(); state_reset();
    const struct { op_hdr set; p_set_rt_c rt; const tex_t *color0; uint8_t snap[sizeof(tex_t)]; op_hdr clear; p_clear_color color; op_hdr end; } c = {
        .set = {OP_SET_RT, sizeof(op_hdr) + sizeof(p_set_rt_c) + 8 + sizeof(tex_t)}, .rt = {.n = 1, .cmask = 1}, .color0 = &g_rt,
        .clear = {OP_CLEAR_COLOR, sizeof(op_hdr) + sizeof(p_clear_color)}, .color = {.index = 0, .mask = 15, .rgba = {0, 0, 0, 1}}, .end = {OP_END, sizeof(op_hdr)} };
    nvn_be_exec((const uint8_t *)&c);
}
// 交掉这一帧、读回目标：列掩码（bit c = 第 c 列 4 个像素全白）；有半白的列或杂色回 -1
static int frame_columns(void) {
    rp_flush(); uint64_t fence = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    id<MTLBuffer> rb = [g_dev newBufferWithLength:8 * 4 * 4 options:MTLResourceStorageModeShared]; REQUIRE(rb);
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:tex_mtl(&g_rt) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 4, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:128];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    const uint8_t *px = rb.contents; int mask = 0;
    for (int c = 0; c < 8; c++) { int white = 0;
        for (int r = 0; r < 4; r++) { const uint8_t *p = px + 32 * r + 4 * c; if (p[0] == 255 && p[1] == 255 && p[2] == 255) white++; else if (p[0] || p[1] || p[2]) return -1; }
        if (white == 4) mask |= 1 << c; else if (white) return -1; }
    return mask;
}
// 一笔网格绘制；管线还在后台建（本笔跳过、等待数 +1）就等建好再画一次。*waited = 本笔是否先跳过过
static void mesh_draw(const p_draw *dw, int *waited) {
    uint64_t w0 = g_mtk_wait; draw(dw, NULL);
    *waited = g_mtk_wait != w0;
    if (*waited) { dispatch_group_wait(g_mtk_group, DISPATCH_TIME_FOREVER); draw(dw, NULL); }
}

int main(void) {
    @autoreleasepool {
        const char *libdir = getenv("T_MESH_LIB"); REQUIRE(libdir);   // mk 编好的 <键>_b.metallib 所在目录；json 由本测写
        setenv("DM_PRESENT_LINK", "0", 1);
        mtl_init(); g_msl_dir = @(libdir);
        printf("后端 Metal %d，录制 %s\n", g_m3 ? 3 : 4, rec_on() ? "开" : "关");
        NSString *dir = @(libdir);
        put_json(dir, @"1111111111111111_b", @{@"stage": @"ts", @"msl_entry_kind": @"object", @"mesh_threads": @32, @"mesh_payload": @4});
        put_json(dir, @"2222222222222222_b", @{@"stage": @"ms", @"msl_entry_kind": @"mesh", @"entry_z": @"main0_z", @"mesh_threads": @32, @"mesh_payload": @4, @"mesh_task": @1, @"max_vertices": @4, @"max_primitives": @2});
        put_json(dir, @"3333333333333333_b", @{@"stage": @"ms", @"msl_entry_kind": @"mesh", @"entry_z": @"main0_z", @"mesh_threads": @32, @"max_vertices": @4, @"max_primitives": @2});
        put_json(dir, @"4444444444444444_b", @{@"stage": @"ms", @"msl_entry_kind": @"mesh", @"entry_z": @"main0_z", @"mesh_threads": @32, @"max_vertices": @300, @"max_primitives": @2});
        nvn_be_set_depth_zero(1);

        // ①
        NvShader *ts = shader_get(@"1111111111111111_b", 3), *mt = shader_get(@"2222222222222222_b", 4), *md = shader_get(@"3333333333333333_b", 4);
        VERIFY(ts && ts->mesh_kind == 1 && ts->mesh_threads == 32 && ts->mesh_payload == 4, "① 任务着色器载入：object、线程 32、载荷 4（实得 %d / %u / %u）", ts ? ts->mesh_kind : -1, ts ? ts->mesh_threads : 0, ts ? ts->mesh_payload : 0);
        VERIFY(mt && mt->mesh_kind == 2 && mt->mesh_task && md && md->mesh_kind == 2 && !md->mesh_task, "① 网格着色器载入：2222 带任务、3333 不带");
        VERIFY(mt && md && [mt->ventry isEqual:@"main0_z"] && [md->ventry isEqual:@"main0_z"], "① near = 0 下网格入口是 main0_z（实得 %s / %s）", mt ? mt->ventry.UTF8String : "-", md ? md->ventry.UTF8String : "-");
        REQUIRE(ts && mt && md);
        // ②
        __block NvShader *big = nil; NSString *o = capture(^{ big = shader_get(@"4444444444444444_b", 4); });
        VERIFY(!big && red_lines(o, @"4444444444444444_b") == 1, "② max_vertices 300 的网格着色器载不进、报红 1 行（实得 %s，红 %d 行；stderr：%s）", big ? "载入了" : "nil", red_lines(o, @"4444444444444444_b"), o.UTF8String);

        NvShader *fs = [NvShader new]; fs->stage = 1; strlcpy(fs->key, "ffffffffffffffff_b", sizeof fs->key); fs->ventry = @"main0";
        { NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 main0() { return float4(1); }\n" options:nil error:&e]; REQUIRE(l); fs->fn = [l newFunctionWithName:@"main0"]; REQUIRE(fs->fn); }
        NvProg *direct = [NvProg new]; direct->sh[1] = fs; direct->sh[4] = md;
        NvProg *task = [NvProg new]; task->sh[1] = fs; task->sh[3] = ts; task->sh[4] = mt;
        NvProg *none = [NvProg new]; none->sh[1] = fs;
        static prog_t gp[3]; NvProg *progs[3] = {direct, task, none};
        for (int i = 0; i < 3; i++) { memset(&gp[i], 0, sizeof gp[i]); gp[i].magic = MAGIC('P', 'R', 'O', 'G'); gp[i].serial = nvn_new_serial(); serial_put(gp[i].serial, progs[i]); }
        rt_make();

        // ③
        frame_begin();
        const prog_t *bound = bind_stages(&gp[1], 0x1a);
        VERIFY(bound == &gp[1], "③ 任务 + 网格 + 片元（位 0x1a）、没有顶点阶段的程序：bind_stages 回它本身（实得 %p，期望 %p）", (const void *)bound, (const void *)&gp[1]);

        // ④
        S.prog = &gp[0]; uint64_t n0 = g_mtk_n; __block int waited = 0;
        p_draw d4 = {.prim = DM_PRIM_MESH_TASKS, .first = 2, .count = 3, .instances = 1};
        o = capture(^{ mesh_draw(&d4, &waited); });
        int cols = frame_columns();
        VERIFY(waited && red_lines(o, nil) == 0, "④ 首笔管线后台建：本笔先跳过并计数、不报红（跳过过 %d；stderr：%s）", waited, o.UTF8String);
        VERIFY(cols == 0x1c && g_mtk_n == n0 + 1, "④ 无任务 first 2 count 3：列 2、3、4 白（列掩码 %#x，期望 0x1c；画出 +%llu）", cols, (unsigned long long)(g_mtk_n - n0));

        // ⑤
        frame_begin(); S.prog = &gp[1];
        p_draw d5 = {.prim = DM_PRIM_MESH_TASKS, .first = 1, .count = 2, .instances = 1};
        o = capture(^{ int w; mesh_draw(&d5, &w); });
        cols = frame_columns();
        VERIFY(cols == 0x3c && red_lines(o, nil) == 0, "⑤ 有任务 first 1 count 2：任务 1、2 各派 2 组 → 列 2..5 白（列掩码 %#x，期望 0x3c；stderr：%s）", cols, o.UTF8String);

        // ⑥ ⑦：参数在内存池里，GPU 在同一提交里写
        static uint32_t pool[4096] __attribute__((aligned(16384)));
        nvn_be_pool_add(pool, sizeof pool);
        pool[0] = 3; pool[1] = 4; pool[4] = 0; pool[5] = 1;   // 种子（GPU 拷贝的源）
        pool[64] = 7; pool[65] = 0; pool[68] = 7; pool[69] = 0;   // 参数位置：CPU 看到的旧值
        frame_begin(); S.prog = &gp[0]; uint64_t i0 = g_mtk_ind_n;
        mtl_sub_copy((uint64_t)(uintptr_t)&pool[0], (uint64_t)(uintptr_t)&pool[64], 8);
        p_draw d6 = {.prim = DM_PRIM_MESH_TASKS, .instances = 1, .ind = (uint64_t)(uintptr_t)&pool[64]};
        o = capture(^{ int w; mesh_draw(&d6, &w); });
        cols = frame_columns();
        VERIFY(cols == 0x70 && g_mtk_ind_n == i0 + 1 && red_lines(o, nil) == 0, "⑥ 间接：GPU 写 {3, 4}（CPU 先见 {7, 0}）→ 列 4、5、6 白（列掩码 %#x，期望 0x70；间接 +%llu；stderr：%s）",
               cols, (unsigned long long)(g_mtk_ind_n - i0), o.UTF8String);
        VERIFY(pool[64] == 3 && pool[65] == 4, "⑥ 参数确实是 GPU 写的：交完后 CPU 读到 {%u, %u}，期望 {3, 4}", pool[64], pool[65]);

        frame_begin(); S.prog = &gp[0]; i0 = g_mtk_ind_n;
        mtl_sub_copy((uint64_t)(uintptr_t)&pool[4], (uint64_t)(uintptr_t)&pool[68], 8);
        p_draw d7 = {.prim = DM_PRIM_MESH_TASKS, .instances = 1, .ind = (uint64_t)(uintptr_t)&pool[68]};
        o = capture(^{ int w; mesh_draw(&d7, &w); });
        cols = frame_columns();
        VERIFY(cols == 0 && g_mtk_ind_n == i0 + 1 && red_lines(o, nil) == 0, "⑦ 间接零工作量：GPU 写 {0, 1} → 一列不画（列掩码 %#x，期望 0）、照记一笔、不报红（stderr：%s）", cols, o.UTF8String);

        // ⑧
        frame_begin(); S.prog = &gp[2]; uint64_t s0 = g_mtk_skip;
        p_draw d8 = {.prim = DM_PRIM_MESH_TASKS, .first = 0, .count = 4, .instances = 1};
        o = capture(^{ draw(&d8, NULL); draw(&d8, NULL); });
        cols = frame_columns();
        VERIFY(cols == 0 && g_mtk_skip == s0 + 2 && red_lines(o, nil) == 1, "⑧ 程序没有网格着色器：两笔都跳过（+%llu）、报红 1 行、不画（列掩码 %#x；stderr：%s）", (unsigned long long)(g_mtk_skip - s0), cols, o.UTF8String);
        nvn_be_pool_del(pool);

        // ⑨
        int st_t = stage_of(@"task"), st_m = stage_of(@"mesh");
        NvShader *mt9 = st_t >= 0 ? shader_get(@"1111111111111111_b", st_t) : nil, *mm9 = st_m >= 0 ? shader_get(@"3333333333333333_b", st_m) : nil;
        VERIFY(st_t == 3 && st_m == 4 && mt9 && mt9->mesh_kind == 1 && mm9 && mm9->mesh_kind == 2,
               "⑨ 映射表阶段名 task / mesh → 宿主阶段 3 / 4 并载入 object / mesh（实得 %d / %d，种类 %d / %d）", st_t, st_m, mt9 ? mt9->mesh_kind : -1, mm9 ? mm9->mesh_kind : -1);

        // ⑩
        frame_begin(); S.prog = &gp[0]; s0 = g_mtk_skip; n0 = g_mtk_n; int ok_saved = g_mesh_ok; g_mesh_ok = 0;
        p_draw d10 = {.prim = DM_PRIM_MESH_TASKS, .first = 0, .count = 4, .instances = 1};
        o = capture(^{ draw(&d10, NULL); draw(&d10, NULL); });
        g_mesh_ok = ok_saved;
        cols = frame_columns();
        VERIFY(cols == 0 && g_mtk_skip == s0 + 2 && g_mtk_n == n0 && red_lines(o, @"no object / mesh pipelines") == 1,
               "⑩ GPU 无网格管线：两笔都跳过（+%llu）、报红 1 行、不画（列掩码 %#x；stderr：%s）", (unsigned long long)(g_mtk_skip - s0), cols, o.UTF8String);
    }
    if (failures) { printf("✗ t_nvn_mesh：%u 项里 %u 项不符\n", checks, failures); return 1; }   // 原生门禁按「✓ t_ / ✗ t_」逐组判
    printf("✓ t_nvn_mesh：%u 项全过（任务 / 网格绘制：约定字段载入、上限报红、无顶点阶段的程序、直接 / 有任务 / GPU 写参数的间接 / 零工作量画出的列与手算一致、缺网格着色器报红、映射表阶段名 task / mesh 载入、无网格管线的 GPU 跳过报红）\n", checks); return 0;
}
