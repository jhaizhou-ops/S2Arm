// 苹果局域网联机（ios/ldn_lan.m）的「是不是本机」与「选谁当中继」必须走与安卓共用的那份实现
//   （runtime/src/lan_elect.c，规则本身由 t_lan_elect 测）。审计 P2-12：原先 ldn_lan.m 用 NSString 自写一份，生产从不调可测的那份，
//   两边规则一漂移，同一 Wi-Fi 的苹果机和安卓机就选出不同的中继。
// 这里把被测文件整份编进来，换上「故意和名字最小规则不同」的假 s2a_lan_elect / s2a_lan_is_self：生产代码照假实现的答案走 = 确实委托给共用实现；
//   自写比较的旧代码不理假实现，照「名字最小」选 → 红。不碰网络：不调 start（不发布、不浏览、不解析），只直接驱动 elect / isSelf。
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

#include "../../ios/ldn_lan.m"

static int failures;
static void check(int ok, const char *what) {
    if (!ok) { failures++; fprintf(stderr, "✗ t_ldn_lan: %s\n", what); }
}

// 被测文件引用的外部符号：权限说明（lan_permission.m）与共享层的改指入口
void s2a_lan_permission_then(int dev_mode, void (^go)(void)) { (void)dev_mode; (void)go; }
void s2a_lan_permission_failed(const char *what, NSDictionary *err) { (void)what; (void)err; }
static char g_server[64];
static int g_set_calls;
void S2A_LdnSetServer(const char *ipv4) { snprintf(g_server, sizeof g_server, "%s", ipv4); g_set_calls++; }

// 假共用实现：选名字「最大」的那个（与真规则相反）；记下收到的前缀与候选
static int g_elect_calls, g_elect_n, g_own_seen;
static char g_elect_prefix[64];
int s2a_lan_elect(const char *prefix, const char *const *names, int n) {
    g_elect_calls++; g_elect_n = n; g_own_seen = 0;
    snprintf(g_elect_prefix, sizeof g_elect_prefix, "%s", prefix ? prefix : "");
    int best = -1;
    for (int i = 0; i < n; i++) {
        if (!strcmp(names[i], "0100000000000001-bbbb")) g_own_seen = 1;
        if (best < 0 || strcmp(names[i], names[best]) > 0) best = i;
    }
    return best;
}
// 假共用实现：只认「zzzz」是本机（真规则下 bbbb 才是）
static int g_self_calls;
int s2a_lan_is_self(const char *prefix, const char *dev, const char *name) {
    (void)prefix; (void)dev;
    g_self_calls++;
    return strstr(name, "zzzz") != NULL;
}

int main(void) {
    @autoreleasepool {
        S2ALdnLan *lan = [S2ALdnLan new];
        lan.prefix = @"0100000000000001-"; lan.dev = @"bbbb"; lan.ownName = @"0100000000000001-bbbb";
        lan.ips = [@{@"0100000000000001-aaaa": @"10.0.0.1", @"0100000000000001-cccc": @"10.0.0.3"} mutableCopy];
        pthread_mutex_lock(&g_lan_gate); g_lan = lan; pthread_mutex_unlock(&g_lan_gate);

        // 1. 选举委托：假实现选最大的 cccc → 改指 10.0.0.3（自写「名字最小」会选 aaaa → 10.0.0.1）
        [lan elect];
        check(g_elect_calls == 1, "elect 没调 s2a_lan_elect（生产仍自写比较）");
        check(g_set_calls == 1 && !strcmp(g_server, "10.0.0.3"), "选中中继没按共用实现的答案（应 10.0.0.3）");
        // 候选 = 本机 + 已解析的两台，前缀原样递过去（共用实现要求调用方把本机名放进候选）
        check(g_elect_n == 3 && g_own_seen && !strcmp(g_elect_prefix, "0100000000000001-"), "递给 s2a_lan_elect 的候选 / 前缀不对（应本机 + 2 台、前缀 <程序号>-）");

        // 2. 共用实现选中本机 → 回环地址
        [lan.ips removeObjectForKey:@"0100000000000001-cccc"];
        lan.ips[@"0100000000000001-0000"] = @"10.0.0.9";   // 比本机小：真规则会选它，假实现选最大 = 本机 bbbb
        [lan elect];
        check(!strcmp(g_server, "127.0.0.1"), "共用实现选中本机时没改指回环 127.0.0.1");

        // 3. 是不是本机委托：假实现只认 zzzz（自写判定认 bbbb / !bbbb）
        check([lan isSelf:@"0100000000000001-zzzz"] && ![lan isSelf:@"0100000000000001-!bbbb"] && g_self_calls == 2,
              "isSelf 没走 s2a_lan_is_self（生产仍自写判定）");

        pthread_mutex_lock(&g_lan_gate); g_lan = nil; pthread_mutex_unlock(&g_lan_gate);
    }
    if (failures) return 1;
    puts("✓ t_ldn_lan: 苹果联机的选举 / 本机判定委托共用 s2a_lan_elect / s2a_lan_is_self，选中本机走回环");
    return 0;
}
