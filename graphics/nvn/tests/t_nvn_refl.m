// 反射绑定数（nvn_refl_from_json）：绑定数组按反射里的个数分配。期望值手写：71 个绑定（怪猎崛起 12 个着色器，最大 71；暗黑2 24 个超 64）解析成功、逐个对上；
//   超过参数缓冲上限（NVN_REFL_MAXARG）才拒；改前固定 64 时 71 个报「over the limit 64」（反证：同一单测编改前的 nvn_refl.m 即不过）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSDictionary *refl_with(int n) {
    NSMutableArray *b = [NSMutableArray array];
    for (int i = 0; i < n; i++) [b addObject:@{ @"kind": @"cbuf", @"reg": @(i % 14), @"arg_id": @(i), @"msl_name": [NSString stringWithFormat:@"fp_c%d", 3 + i % 14] }];
    return @{ @"route": @"B", @"bindings": b };
}

int main(void) {
    @autoreleasepool {
        char err[256] = "";
        NvShader *s = [NvShader new];
        int rc = nvn_refl_from_json(refl_with(71), &s->rf, err, sizeof err);
        VERIFY(rc == 0 && s->rf.nb == 71, "71 个绑定解析成功（rc %d，nb %d%s%s）", rc, s->rf.nb, err[0] ? "，" : "", err);
        int ok = rc == 0; for (int i = 0; ok && i < 71; i++) ok = s->rf.b[i].kind == NVN_RB_CBUF && s->rf.b[i].aid == i && s->rf.b[i].reg == i % 14;
        VERIFY(ok, "71 个绑定逐个对上（种类、参数缓冲项、槽号）");
        s = nil;   // dealloc 释放 b 与 c1

        NvShader *t = [NvShader new]; err[0] = 0;
        rc = nvn_refl_from_json(refl_with(NVN_REFL_MAXARG + 1), &t->rf, err, sizeof err);
        VERIFY(rc != 0 && strstr(err, "argument buffer limit") && !t->rf.b, "超过参数缓冲上限 %d 才拒、失败路径释放绑定数组（%s）", NVN_REFL_MAXARG, err);

        // 存储缓冲可写（10-27 异度3 人物蒙皮：出包写的 "rw" 恒为 false，非 const 的 device 类型才是真话）：rw 真 → 可写；rw 假但类型 "device _23*" → 可写；
        //   rw 假、类型 "const device _25*" → 只读；没有 rw、类型 const → 只读；没有 rw 也没有类型 → 可写（宁可多记写）
        NSDictionary *sb[5] = { @{ @"rw": @YES, @"msl_type": @"const device _25*" }, @{ @"rw": @NO, @"msl_type": @"device _23*" }, @{ @"rw": @NO, @"msl_type": @"const device _25*" },
                                @{ @"msl_type": @"const device _25*" }, @{} };
        const int want[5] = {1, 1, 0, 0, 1}; int got[5];
        for (int i = 0; i < 5; i++) {
            NSMutableDictionary *b = [sb[i] mutableCopy]; b[@"kind"] = @"sbuf"; b[@"reg"] = @0; b[@"arg_id"] = @0; b[@"msl_name"] = @"vp_s0";
            NvShader *u = [NvShader new]; err[0] = 0; int r2 = nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[b] }, &u->rf, err, sizeof err);
            got[i] = r2 == 0 && u->rf.nb == 1 ? u->rf.b[0].rw : -1;
        }
        VERIFY(!memcmp(got, want, sizeof want), "存储缓冲可写判定：rw 真 / rw 假但非 const / rw 假且 const / 无 rw 且 const / 都没有 → 1 1 0 0 1（实得 %d %d %d %d %d）", got[0], got[1], got[2], got[3], got[4]);

        // #1106: NVN order differs from Maxwell's; expectations are literal ABI offsets.
        const int bases[6] = {0x110, 0x510, 0x410, 0x210, 0x310, 0x310};
        for (int stage = 0; stage < 6; stage++)
            VERIFY(c0_ssbo_base(stage, 0) == bases[stage], "c0 stage %d base %#x（期望 %#x）", stage, c0_ssbo_base(stage, 0), bases[stage]);
        VERIFY(c0_ssbo_base(-1, 0) == -1 && c0_ssbo_base(6, 0) == -1, "未知阶段不返回存储缓冲基址");
        // NVN2 任务 / 网格着色器（mesh 1 / 2）：c0 存储表在 0x670 / 0x770（网格着色接口约定第 4 条），与所在宿主阶段无关
        VERIFY(c0_ssbo_base(3, 1) == 0x670 && c0_ssbo_base(4, 2) == 0x770 && c0_ssbo_base(0, 2) == 0x770, "任务 / 网格存储表基址 0x670 / 0x770（实得 %#x / %#x）", c0_ssbo_base(3, 1), c0_ssbo_base(4, 2));

        // Real shared Metal buffers, filled by production encode_args, not a duplicate table writer.
        mtl_init(); arena_begin();
        g_dispatch_dim[0] = 3; g_dispatch_dim[1] = 5; g_dispatch_dim[2] = 7;
        g_draw_binst = 11;
        for (int stage = 0; stage < 6; stage++) {
            uint8_t expected[DRV_SIZE] = {0};
            for (int r = 0; r < 16; r++) {
                uint64_t addr = 0x1234000000ull + 0x100000 * stage + 0x1000 * r;
                uint32_t size = 0x400 + 17 * r;
                S.ssbo[stage][r].addr = addr; S.ssbo[stage][r].size = size;
                memcpy(expected + bases[stage] + 16 * r, &addr, 8);
                memcpy(expected + bases[stage] + 16 * r + 8, &size, 4);
            }
            if (stage != 5) {
                const float max_point = 2047.0f;
                memcpy(expected + 0x610, &max_point, 4); memcpy(expected + 0x644, &g_draw_binst, 4);
            } else memcpy(expected + 0x200, g_dispatch_dim, 12);
            NvShader *driver = [NvShader new]; driver->stage = stage; driver->arg_len = 8;
            driver->rf.b = calloc(1, sizeof *driver->rf.b); driver->rf.nb = 1;
            driver->rf.b[0].kind = NVN_RB_DRV0; driver->rf.drv_read[0] = 1;
            args_dirty_all(); int encoded = encode_args(nil, driver, stage, stage != 1);
            uint64_t gpu = 0; if (driver->ab_buf) memcpy(&gpu, (uint8_t *)driver->ab_buf.contents + driver->ab_off, 8);
            const uint8_t *bytes = NULL;
            for (NvArena *a in g_sub_arenas) if (gpu >= a->gpu && gpu + DRV_SIZE <= a->gpu + a->buf.length)
                bytes = (const uint8_t *)a->buf.contents + (gpu - a->gpu);
            VERIFY(encoded && bytes && !memcmp(bytes, expected, DRV_SIZE), "c0 stage %d：实际编码缓冲逐字节对齐16个地址/大小与表外围（base %#x）", stage, bases[stage]);
        }
    }
    if (failures) { printf("✗ t_nvn_refl：%u 项里 %u 项不符\n", checks, failures); return 1; }   // 原生门禁按「✓ t_ / ✗ t_」逐组判
    printf("✓ t_nvn_refl：%u 项全过（绑定数组按个数分配：71 个照收，超参数缓冲上限才拒；存储缓冲可写按 rw 或非 const 类型）\n", checks); return 0;
}
