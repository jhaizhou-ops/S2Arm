// S 行只记「用过」（shader_used）：原创真实 MSL 从生产预取/加载入口进入。
//   后台预取装上的着色器被提交线程接收（warm_claim）→ pso_user.tsv 0 行 S；
//   第一次用到（shader_get 命中缓存）→ 1 行「S<TAB>键<TAB>阶段」；再用一次 → 仍 1 行。
//   反证：改前代码在接收时就记 S 行，第一项读到 1 行（斯普拉遁3 开机建的 1.26 万个程序全进了 pso_user.tsv，下次开机预热全装，交付线 10-27）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static int s_rows(const char *path) {
    FILE *f = fopen(path, "r"); if (!f) return 0; char l[256]; int n = 0;
    while (fgets(l, sizeof l, f)) n += !strcmp(l, "S\taaaaaaaaaaaaaaaa_b\t5\n");
    fclose(f); return n;
}

// 本测扮演链了 S2A.Aot 的 App：兜底目录的 json 要带与它相同的翻译器指纹才载（nvn_mtl.m fb_json_current，dlsym 在主程序里找到它）
const char *s2a_dsh_xfp(void) { return "0123456789abcdef"; }
int main(void) {
    @autoreleasepool {
        char root[] = "/tmp/t_srec_XXXXXX"; REQUIRE(mkdtemp(root));
        NSString *dir=@(root), *fallback=[dir stringByAppendingPathComponent:@"fallback"];
        REQUIRE([NSFileManager.defaultManager createDirectoryAtPath:fallback withIntermediateDirectories:YES attributes:nil error:nil]);
        REQUIRE([NSFileManager.defaultManager createDirectoryAtPath:[dir stringByAppendingPathComponent:@"b-" DMSH_CHAIN]
            withIntermediateDirectories:YES attributes:nil error:nil]);
        NSString *user=[dir stringByAppendingPathComponent:@"user.tsv"], *map=[dir stringByAppendingPathComponent:@"map.tsv"];
        REQUIRE([@"original\t0\tcompute\taaaaaaaaaaaaaaaa\n" writeToFile:map atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        REQUIRE([@"#include <metal_stdlib>\nusing namespace metal;\nkernel void main0() {}\n"
            writeToFile:[fallback stringByAppendingPathComponent:@"aaaaaaaaaaaaaaaa_b.metal"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"chain":@DMSH_CHAIN,@"xfp":@"0123456789abcdef",@"route":@"B",@"bindings":@[],@"entry":@"main0"} options:0 error:nil];
        REQUIRE(json && [json writeToFile:[fallback stringByAppendingPathComponent:@"aaaaaaaaaaaaaaaa_b.json"] atomically:YES]);
        setenv("DM_PSO_USER",user.fileSystemRepresentation,1); setenv("DM_NVN_SHMAP",map.fileSystemRepresentation,1);
        setenv("DM_MSL_DIR",root,1); setenv("DM_MSL_FALLBACK",fallback.fileSystemRepresentation,1);
        setenv("DM_PSO_MANIFEST","off",1); setenv("DM_PSO_ARCHIVE","0",1);
        mtl_init();
        const uint8_t md[8]={0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa}; nvn_be_shader_prefetch(md);
        // 按事件等（10-30 mini 上 gfx / native 两钩子并行时 10 秒墙钟期限超时、把 868 那批打红）：预取在通道 g_shpre（11-02 起几条串行队列并排）上，
        //   shpre_sync 在每条通道排一个空块并等齐，返回时预取那件活一定做完了（成败都算），再判就绪标志；挂死由门禁超时兜底，不设墙钟期限
        REQUIRE(g_shpre.n); shpre_sync();
        REQUIRE(atomic_load_explicit(&g_warm_ready,memory_order_acquire));
        os_unfair_lock_lock(&g_warm_lock); NvShader *s=g_warm_items.firstObject->shader; os_unfair_lock_unlock(&g_warm_lock);
        REQUIRE(s && s->fn && s->stage==5);
        warm_claim();
        VERIFY(s_rows(user.fileSystemRepresentation)==0,"真实预取被接收：pso_user.tsv 不记 S 行（%d 行）",s_rows(user.fileSystemRepresentation));
        VERIFY(shader_get(@"aaaaaaaaaaaaaaaa_b",5)==s && s_rows(user.fileSystemRepresentation)==1,"第一次用到同一真实对象：记 1 行 S（%d 行）",s_rows(user.fileSystemRepresentation));
        shader_get(@"aaaaaaaaaaaaaaaa_b",5);
        VERIFY(s_rows(user.fileSystemRepresentation)==1,"再用一次：仍 1 行（%d 行）",s_rows(user.fileSystemRepresentation));
        REQUIRE([NSFileManager.defaultManager removeItemAtPath:dir error:nil]);
    }
    if (failures) { printf("✗ t_nvn_srec：%u 项里 %u 项不符\n", checks, failures); return 1; }
    printf("✓ t_nvn_srec：%u 项（预取接收不记 / 首次用到记一行 / 不重复）\n", checks);
    return 0;
}
