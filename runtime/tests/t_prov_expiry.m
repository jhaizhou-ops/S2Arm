// prov_expiry.m 单测：合成「CMS 头 + XML plist + CMS 尾」的描述文件判剩余小时；缺日期 / 坏文件 / 没文件读成 NAN。
//   用法：t_prov_expiry [<真描述文件> <期望到期 unix 秒>]——期望值由 mk 用系统 security cms -D + plutil 算，不经被测解析
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
double s2a_prov_hours_left(const char *path, double now_unix);
static int bad;
static void ck(int ok, const char *what) { printf("%s %s\n", ok ? "  ok" : "  ✗", what); if (!ok) bad++; }
static NSString *put(NSString *name, NSString *plist) {
    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:name]; NSMutableData *d = [NSMutableData data];
    const uint8_t head[] = {0x30, 0x82, 0x1f, 0x3c, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x00, 0xff}, tail[] = {0xa0, 0x82, 0x0d, 0x00, 0x30, 0x3c};
    [d appendBytes:head length:sizeof head]; if (plist) [d appendData:[plist dataUsingEncoding:NSUTF8StringEncoding]]; [d appendBytes:tail length:sizeof tail];
    [d writeToFile:p atomically:YES]; return p;
}
int main(int argc, char **argv) { @autoreleasepool {
    const double now = 1793300000;   // 2026-10-29 某时刻；合成文件的到期日 = now + 10 小时 = 1793336000 = 2026-10-30T04:53:20Z
    NSString *pl = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>Name</key><string>x</string>"
                    "<key>ExpirationDate</key><date>2026-10-30T04:53:20Z</date></dict></plist>";
    double h = s2a_prov_hours_left(put(@"t_prov_ok.mobileprovision", pl).UTF8String, now);
    ck(fabs(h - 10.0) < 1e-6, [NSString stringWithFormat:@"合成描述文件：剩 10 小时（读到 %.4f）", h].UTF8String);
    h = s2a_prov_hours_left(put(@"t_prov_old.mobileprovision", pl).UTF8String, now + 11 * 3600);
    ck(fabs(h + 1.0) < 1e-6, "过了到期时间：负数（-1 小时）");
    ck(isnan(s2a_prov_hours_left(put(@"t_prov_nodate.mobileprovision", @"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>").UTF8String, now)), "没有 ExpirationDate → NAN");
    ck(isnan(s2a_prov_hours_left(put(@"t_prov_trunc.mobileprovision", @"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>").UTF8String, now)), "plist 截断（没有 </plist>）→ NAN");
    ck(isnan(s2a_prov_hours_left("/nonexistent/embedded.mobileprovision", now)), "没有文件 → NAN");
    ck(isnan(s2a_prov_hours_left(NULL, now)), "路径为空 → NAN");
    if (argc == 3) {
        double want = atof(argv[2]); h = s2a_prov_hours_left(argv[1], want);
        ck(fabs(h) < 1e-6, [NSString stringWithFormat:@"真描述文件 %s：到期日与 security cms + plutil 读到的一致（差 %.6f 小时）", argv[1], h].UTF8String);
    } else printf("  （本机没有真描述文件，跳过真文件一项）\n");
    if (bad) { printf("prov_expiry 单测 %d 项不通\n", bad); return 1; }
    printf("✓ t_prov_expiry 单测全过\n"); return 0;
} }
