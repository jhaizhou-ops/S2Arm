// 签名到期提示（免费签名分发，10-30）：免费账号的描述文件 7 天过期，过期后 App 直接打不开。起局读包里 embedded.mobileprovision 的 ExpirationDate，
//   剩不到 48 小时在画面顶部提示一次（横幅在 dprompt.m）。读不到（Xcode 以外的签法没嵌描述文件、ad-hoc 包、Mac）就不提示。
//   只用 Foundation，单测 runtime/tests/t_prov_expiry.m 在 Mac 上跑
#import <Foundation/Foundation.h>
#include <math.h>

// 描述文件是 CMS 签名包着的一段 XML plist：取 <?xml … </plist> 那段解析。返回 ExpirationDate 距 now 的小时数（已过期为负），读不到返回 NAN
double s2a_prov_hours_left(const char *path, double now_unix) {
    @autoreleasepool {
        NSData *d = path ? [NSData dataWithContentsOfFile:@(path)] : nil; if (!d.length) return NAN;
        NSData *a = [@"<?xml" dataUsingEncoding:NSASCIIStringEncoding], *b = [@"</plist>" dataUsingEncoding:NSASCIIStringEncoding];
        NSRange r0 = [d rangeOfData:a options:0 range:NSMakeRange(0, d.length)]; if (r0.location == NSNotFound) return NAN;
        NSRange r1 = [d rangeOfData:b options:0 range:NSMakeRange(r0.location, d.length - r0.location)]; if (r1.location == NSNotFound) return NAN;
        NSData *x = [d subdataWithRange:NSMakeRange(r0.location, NSMaxRange(r1) - r0.location)];
        id pl = [NSPropertyListSerialization propertyListWithData:x options:NSPropertyListImmutable format:NULL error:nil];
        id e = [pl isKindOfClass:NSDictionary.class] ? pl[@"ExpirationDate"] : nil;
        if (![e isKindOfClass:NSDate.class]) return NAN;
        return (((NSDate *)e).timeIntervalSince1970 - now_unix) / 3600.0;
    }
}

// 本包的描述文件剩几小时（读不到 NAN）
double s2a_prov_hours_left_self(void) {
    NSString *p = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"];
    return s2a_prov_hours_left(p.UTF8String, NSDate.date.timeIntervalSince1970);
}
