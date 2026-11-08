// 预热清单里几何着色器模拟的库名（<键>_bgv 顶点 / <键>_bg<数字> 第 i 段几何）：11-05 Switch Sports 菜单转场那批几何管线在 pso_user.tsv 里记成 R 行（顶点键 _bgv）、
//   S 行（_bgv / _bg3），warm_stale 只去掉 _b 再查映射表 → 当「别的游戏版本」跳过（host.log「not in the shader map 62」），每局在提交线程现建。
// 期望（按库名语法 lp_kind_of 手写，与被测实现无关）：映射表只有键 K（vertex）
//   ① K_b / K_bgv / K_bg3 都不算过期（同一个 16 位键）  ② Z_bgv（Z 不在表里）算过期；K_bx（认不出的后缀）算过期
//   ③ warm_parse 一份清单：R(K_bgv, 无片元) + S K_bgv 0 + S K_bg3 2 + S Z_bgv 0 → 3 个任务（渲染 1 个、顶点键 K_bgv；着色器 2 个），跳过 1 行
// 反证（修前）：同一单测编改前的 nvn_mtl.m → ① 的 K_bgv / K_bg3 算过期、③ 只剩 0 个任务
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, fails;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    mtl_init();
    NSString *K = @"53bfc39140bd79b5", *Z = @"0123456789abcdef";
    g_shmap = [NSMutableDictionary dictionaryWithDictionary:@{ K: @"vertex" }];
    NSMutableSet<NSString *> *st = [NSMutableSet set];
    int b = warm_stale([K stringByAppendingString:@"_b"], st), bgv = warm_stale([K stringByAppendingString:@"_bgv"], st), bg3 = warm_stale([K stringByAppendingString:@"_bg3"], st);
    VERIFY(!b && !bgv && !bg3, "① K_b / K_bgv / K_bg3 不算过期（得 %d / %d / %d，期望 0 / 0 / 0）", b, bgv, bg3);
    int z = warm_stale([Z stringByAppendingString:@"_bgv"], st), bx = warm_stale([K stringByAppendingString:@"_bx"], st);
    VERIFY(z && bx, "② Z_bgv（不在表里）、K_bx（后缀认不出）算过期（得 %d / %d，期望 1 / 1）", z, bx);
    pso_skey sk; memset(&sk, 0, sizeof sk); snprintf(sk.vs, sizeof sk.vs, "%s_bgv", K.UTF8String);
    char hx[sizeof sk * 2 + 1]; pso_skey_hex(&sk, hx);
    NSString *list = [NSString stringWithFormat:@"# seed\nR\t%s\nS\t%@_bgv\t0\nS\t%@_bg3\t2\nS\t%@_bgv\t0\n", hx, K, K, Z];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_nvn_warm_geo_%d.tsv", getpid()]];
    REQUIRE([list writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    long lines = 0; NSArray<WarmTask *> *tasks = warm_parse(@[path], &lines);
    int nr = 0, ns = 0; NSString *vk = @"";
    for (WarmTask *t in tasks) { if (t->kind == 1) { nr++; vk = t->vkey; } else if (t->kind == 0) ns++; }
    VERIFY(tasks.count == 3 && nr == 1 && ns == 2 && [vk isEqualToString:[K stringByAppendingString:@"_bgv"]] && lines == 3,
           "③ 清单 4 行 → 任务 %lu 个（渲染 %d、着色器 %d，渲染任务顶点键 %s，计入 %ld 行；期望 3 / 1 / 2 / K_bgv / 3）", (unsigned long)tasks.count, nr, ns, vk.UTF8String, lines);
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    printf("%s t_nvn_warm_geo：%u 项，%u 项失败（预热认几何着色器模拟的库名，不当别的游戏版本跳过）\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }
