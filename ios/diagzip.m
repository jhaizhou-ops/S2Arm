// 诊断包 zip 写入（ios/diag.m 用）：只依赖 Foundation + zlib，Mac 上可单测（tests/diagzip_test.sh）
#import <Foundation/Foundation.h>
#include <zlib.h>
#include "diagzip.h"

// ---------- zip（PKWARE 规范最小子集：deflate / 不加密 / 不分卷 / 不用 zip64——诊断包 ≤ 30 MB）----------
// 条目路径相对工作目录（manifest.json、logs/…、metrickit/… 在根上），通用标志第 11 位 = 文件名是 UTF-8
static void put16(NSMutableData *d, uint16_t v) { uint8_t b[2] = {v & 0xff, v >> 8}; [d appendBytes:b length:2]; }
static void put32(NSMutableData *d, uint32_t v) { uint8_t b[4] = {v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, v >> 24}; [d appendBytes:b length:4]; }
static NSData *deflate_raw(NSData *in) {
    z_stream z = {0}; if (deflateInit2(&z, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:deflateBound(&z, (uLong)in.length) + 16];
    z.next_in = (Bytef *)in.bytes; z.avail_in = (uInt)in.length; z.next_out = out.mutableBytes; z.avail_out = (uInt)out.length;
    int rc = deflate(&z, Z_FINISH); out.length = z.total_out; deflateEnd(&z);
    return rc == Z_STREAM_END ? out : nil;
}
BOOL s2a_write_zip(NSString *root, NSString *dest) {
    NSFileManager *fm = NSFileManager.defaultManager; NSMutableData *z = [NSMutableData data], *cd = [NSMutableData data]; uint16_t n = 0;
    for (NSString *rel in [[[fm enumeratorAtPath:root] allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
        BOOL dir = NO; [fm fileExistsAtPath:[root stringByAppendingPathComponent:rel] isDirectory:&dir]; if (dir) continue;
        NSData *raw = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:rel]], *def = raw ? deflate_raw(raw) : nil; if (!def) return NO;
        NSData *nm = [rel dataUsingEncoding:NSUTF8StringEncoding]; uint32_t crc = (uint32_t)crc32(0, raw.bytes, (uInt)raw.length), off = (uint32_t)z.length;
        // 本地头：签名 / 需要版本 2.0 / 标志 UTF-8 / deflate / 时间日期置 0（manifest 里有导出时刻）/ CRC / 压缩后 / 原长 / 名长 / 扩展长
        put32(z, 0x04034b50); put16(z, 20); put16(z, 1u << 11); put16(z, 8); put16(z, 0); put16(z, 0x21);
        put32(z, crc); put32(z, (uint32_t)def.length); put32(z, (uint32_t)raw.length); put16(z, (uint16_t)nm.length); put16(z, 0);
        [z appendData:nm]; [z appendData:def];
        // 中央目录项：签名 / 制作版本（3 = Unix，2.0）/ 需要版本 / 标志 / 方法 / 时间日期 / CRC / 长度 / 名长 / 扩展 / 注释 / 盘号 / 内部属性 / 外部属性（0644）/ 本地头偏移
        put32(cd, 0x02014b50); put16(cd, (3u << 8) | 20); put16(cd, 20); put16(cd, 1u << 11); put16(cd, 8); put16(cd, 0); put16(cd, 0x21);
        put32(cd, crc); put32(cd, (uint32_t)def.length); put32(cd, (uint32_t)raw.length); put16(cd, (uint16_t)nm.length); put16(cd, 0); put16(cd, 0);
        put16(cd, 0); put16(cd, 0); put32(cd, 0100644u << 16); put32(cd, off); [cd appendData:nm]; n++;
    }
    uint32_t cdo = (uint32_t)z.length; [z appendData:cd];
    put32(z, 0x06054b50); put16(z, 0); put16(z, 0); put16(z, n); put16(z, n); put32(z, (uint32_t)cd.length); put32(z, cdo); put16(z, 0);
    return [z writeToFile:dest atomically:YES];
}
