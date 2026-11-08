// 直连库打包容器读法（graphics/nvn/lib_pack.inc）单测：按格式手造一个两分片的小容器（期望值全由本测试写进去的字节决定，不跑被测实现），
//   验：取过的分片不留文件映射、取库并取到入口、json 逐字节相等、没有的种类返回空、链版本不符判格式错、分片大小不符报红返回空、没有 lib.idx 返回 0。
//   两个真 metallib 由 Makefile 用 xcrun metal 编（tests/t_lib_pack_a.metal / _b.metal），路径从参数传进来
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
// 本进程有几块虚拟内存映射着 <dir> 下的 .pak 文件（按区域的文件路径认）。
//   路径用 PROC_PIDREGIONPATHINFO 取这一区自己的：proc_regionfilename 对匿名区（如 Metal 建库时的 malloc 块）回的是其后第一块文件映射的路径，
//   会把紧挨在 .pak 映射前面的匿名区算进来（11-02 守望红：64 MB 的 malloc 区记到 1 MB 的分片名下）
static uint64_t g_pak_bytes;   // pak_maps 顺带记 .pak 映射的总字节
static int pak_maps(const char *dir) {
    int n = 0; mach_vm_address_t a = 0; g_pak_bytes = 0; mach_vm_size_t sz; vm_region_basic_info_data_64_t info; mach_msg_type_number_t c; mach_port_t obj; struct proc_regionwithpathinfo ri;
    for (;; a += sz) { c = VM_REGION_BASIC_INFO_COUNT_64;
        if (mach_vm_region(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &c, &obj) != KERN_SUCCESS) break;
        if (proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, a, &ri, sizeof ri) == (int)sizeof ri && ri.prp_prinfo.pri_address == a
            && strstr(ri.prp_vip.vip_path, dir) && strstr(ri.prp_vip.vip_path, ".pak")) { n++; g_pak_bytes += sz; } }
    return n;
}
// [lo, hi) 里映射着 <dir> 下 .pak 的字节（同 pak_maps 的认法）
static uint64_t pak_bytes_in(const char *dir, uint64_t lo, uint64_t hi) {
    uint64_t b = 0; mach_vm_address_t a = lo; mach_vm_size_t sz; vm_region_basic_info_data_64_t info; mach_msg_type_number_t c; mach_port_t obj; struct proc_regionwithpathinfo ri;
    for (;; a += sz) { c = VM_REGION_BASIC_INFO_COUNT_64;
        if (mach_vm_region(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &c, &obj) != KERN_SUCCESS || a >= hi) break;
        if (proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, a, &ri, sizeof ri) == (int)sizeof ri && ri.prp_prinfo.pri_address == a
            && strstr(ri.prp_vip.vip_path, dir) && strstr(ri.prp_vip.vip_path, ".pak")) b += sz; }
    return b;
}
static int g_red;
#define LP_LOG(...) do { char b_[512]; snprintf(b_, sizeof b_, __VA_ARGS__); if (strstr(b_, "【红】")) g_red++; printf("    日志：%s\n", b_); } while (0)
// 宿主高位区由测试注入（生产里是 runtime/src/vawin.c s2a_host_hi_range）：缺省 -1 = 没链原生层，照旧 mmap(NULL)，前面各项按原样跑
static int g_hr_rc = -1; static uint64_t g_hr_lo, g_hr_hi;
#define LP_HI_RANGE(lo, hi) (*(lo) = g_hr_lo, *(hi) = g_hr_hi, g_hr_rc)
#include "../lib_pack.inc"
static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("✗ " __VA_ARGS__); printf("\n"); } else { printf("✓ " __VA_ARGS__); printf("\n"); } } while (0)
static NSData *rd(const char *p) { NSData *d = [NSData dataWithContentsOfFile:@(p)]; if (!d) { printf("读不到 %s\n", p); exit(2); } return d; }
typedef struct { uint64_t key; uint8_t kind, shard; uint32_t len; uint64_t off; } rec;
// 写容器：shard0 = segs 里 shard==0 的段依次（16 字节对齐），shard1 同理；ssize_bad >= 0 时把分片 1 在索引里的大小写错
static void write_pack(const char *dir, const char *chain, NSArray<NSData *> *segs, const uint8_t *shards, const uint64_t *keys, const uint8_t *kinds, int n, int ssize_bad) {
    NSMutableData *sh[2] = {[NSMutableData data], [NSMutableData data]}; rec r[8];
    for (int i = 0; i < n; i++) { NSMutableData *s = sh[shards[i]]; int j = 0;
        while (j < i && !(segs[j] == segs[i] && shards[j] == shards[i])) j++;   // 同一个 NSData 对象、同一分片：共用一段（批库：多个键指向同一个 metallib）
        if (j < i) { r[i] = r[j]; r[i].key = keys[i]; r[i].kind = kinds[i]; continue; }
        while (s.length % 16) [s appendBytes:"\0" length:1];
        r[i] = (rec){keys[i], kinds[i], shards[i], (uint32_t)segs[i].length, s.length}; [s appendData:segs[i]]; }
    for (int k = 0; k < 2; k++) [sh[k] writeToFile:[NSString stringWithFormat:@"%s/lib.%03d.pak", dir, k] atomically:YES];
    NSMutableData *ix = [NSMutableData data]; uint32_t ver = 1, nn = (uint32_t)n, ns = 2, z = 0; char ch[12] = {0}; memcpy(ch, chain, strlen(chain) < 12 ? strlen(chain) : 12);
    [ix appendBytes:"S2ALIB\0\0" length:8]; [ix appendBytes:&ver length:4]; [ix appendBytes:&nn length:4]; [ix appendBytes:&ns length:4]; [ix appendBytes:&z length:4]; [ix appendBytes:ch length:12]; [ix appendBytes:&z length:4]; [ix appendBytes:&z length:4]; [ix appendBytes:&z length:4];   // 头 48 字节：偏移 36–47 为 0（草案字段合计 44，另补 4 字节到 48，待着色器线确认）
    for (int k = 0; k < 2; k++) { uint64_t sz = sh[k].length + (k == 1 && ssize_bad >= 0 ? 7 : 0), zz = 0; [ix appendBytes:&sz length:8]; [ix appendBytes:&zz length:8]; }
    for (int i = 0; i < n; i++) { uint16_t z16 = 0; [ix appendBytes:&r[i].key length:8]; [ix appendBytes:&r[i].kind length:1]; [ix appendBytes:&r[i].shard length:1]; [ix appendBytes:&z16 length:2]; [ix appendBytes:&r[i].len length:4]; [ix appendBytes:&r[i].off length:8]; }
    [ix writeToFile:[NSString stringWithFormat:@"%s/lib.idx", dir] atomically:YES];
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { printf("用法：t_lib_pack <a.metallib> <b.metallib>\n"); return 2; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSData *la = rd(argv[1]), *lb = rd(argv[2]); NSData *ja = [@"{\"chain\":\"abcdef012345\",\"entry\":\"fa\"}" dataUsingEncoding:NSUTF8StringEncoding];
    char dir[] = "/tmp/t_lib_pack.XXXXXX"; if (!mkdtemp(dir)) return 2;
    // 键 A = 0x00000000000000aa（种类 0 库、1 json，分片 0），键 B = 0x0123456789abcdef（种类 0 库、3 影子输入库，分片 1）；按 (键, 种类) 升序
    // 另有两段 1 MB 填充（键 0xff…fe / 0xff…ff，各在一个分片尾，从不取）：分片远大于页，整片映射会让下面的映射字节判据红
    NSMutableData *pad = [NSMutableData dataWithLength:1 << 20];
    uint64_t keys[6] = {0xaa, 0xaa, 0x0123456789abcdefull, 0x0123456789abcdefull, 0xfffffffffffffffeull, 0xffffffffffffffffull}; uint8_t kinds[6] = {0, 1, 0, 3, 0, 0}, shards[6] = {0, 0, 1, 1, 0, 1};
    write_pack(dir, "abcdef012345", @[la, ja, lb, la, pad, pad], shards, keys, kinds, 6, -1);
    lp_pack p; CHECK(lp_open(&p, dir, "abcdef012345") == 1 && p.n == 6 && p.nshard == 2, "打开：6 条记录、2 个分片");
    dispatch_data_t a = lp_get(&p, "00000000000000aa_b", 0), j = lp_get(&p, "00000000000000aa_b", 1), b = lp_get(&p, "0123456789abcdef_b", 0), bv = lp_get(&p, "0123456789abcdef_bv", 3);
    CHECK(a && [(NSData *)a isEqualToData:la], "键 A 种类 0 = a.metallib 原字节（%zu 字节）", la.length);
    CHECK(j && [(NSData *)j isEqualToData:ja], "键 A 种类 1 = json 原字节");
    CHECK(b && [(NSData *)b isEqualToData:lb], "键 B 种类 0（分片 1）= b.metallib 原字节");
    CHECK(bv && [(NSData *)bv isEqualToData:la], "键 B 种类 3（分片 1 第二段，16 字节对齐偏移）= a.metallib 原字节");
    NSError *e = nil; id<MTLLibrary> L = a ? [dev newLibraryWithData:a error:&e] : nil, M = b ? [dev newLibraryWithData:b error:&e] : nil;
    CHECK(L && [L newFunctionWithName:@"fa"], "切片建库取到入口 fa");
    CHECK(M && [M newFunctionWithName:@"fb"], "分片 1 切片建库取到入口 fb");
    // 10-26 巫师3：分片整片映射且常驻，21 片 1343 MB 吃光低区。11-01 起一段 = 只映射这一段（无主之地3：malloc 读出的段被库持有、全算常驻 1.4 GB）。
    //   两个分片都取过、库也建着：.pak 映射总字节 ≤ 取到的 4 段各自按页取整之和（整片映射会超）
    char real[PATH_MAX]; int okp = realpath(dir, real) != NULL; uint64_t pg = (uint64_t)getpagesize(), lim = 0;
    NSData *segs4[4] = {la, ja, lb, la}; for (int i = 0; i < 4; i++) lim += (segs4[i].length + 16 + pg - 1) / pg * pg + pg;   // 段前对齐差 < 一页
    int nm = okp ? pak_maps(real) : -1;
    CHECK(okp && nm <= 4 && g_pak_bytes <= lim, "取过 4 段：.pak 映射 %d 块、%llu 字节 ≤ 各段按页取整之和 %llu（只映射取到的段，不整片映射）", nm, (unsigned long long)g_pak_bytes, (unsigned long long)lim);
    {   // 量法自检：紧贴一块 1 MB 匿名区之后映射 lib.000.pak 一页，计数只多这一页（匿名区不算进来）
        char pk[PATH_MAX]; snprintf(pk, sizeof pk, "%s/lib.000.pak", real); int fd = open(pk, O_RDONLY); uint64_t b0 = g_pak_bytes;
        char *an = mmap(NULL, (1 << 20) + pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); an[0] = 1;
        void *fm = fd >= 0 && an != MAP_FAILED ? mmap(an + (1 << 20), pg, PROT_READ, MAP_PRIVATE | MAP_FIXED, fd, 0) : MAP_FAILED; if (fd >= 0) close(fd);
        int n2 = pak_maps(real);
        CHECK(fm != MAP_FAILED && n2 == nm + 1 && g_pak_bytes == b0 + pg, "量法：.pak 映射前紧贴 1 MB 匿名区，只多算 1 块 %llu 字节（得 %d 块、多 %lld 字节）", (unsigned long long)pg, n2 - nm, (long long)(g_pak_bytes - b0));
        if (an != MAP_FAILED) munmap(an, (1 << 20) + pg); }
    CHECK(lp_get(&p, "00000000000000aa_bf", 2) == NULL && g_red == 0, "没有的种类（键 A 种类 2）返回空、不报红");
    CHECK(lp_get(&p, "00000000000000ab_b", 0) == NULL, "没有的键返回空");
    CHECK(lp_get(&p, "zz00000000000000_b", 0) == NULL, "名字前 16 位不是十六进制返回空");
    lp_pack q; CHECK(lp_open(&q, dir, "000000000000") == -1 && g_red == 1, "链版本不符：判格式错并报红");
    write_pack(dir, "abcdef012345", @[la, ja, lb, la], shards, keys, kinds, 4, 1);   // 分片 1 在索引里的大小写错
    lp_pack r2; int o = lp_open(&r2, dir, "abcdef012345"); int red0 = g_red;
    CHECK(o == 1 && lp_get(&r2, "00000000000000aa_b", 0) != NULL, "分片 0 照常取");
    CHECK(lp_get(&r2, "0123456789abcdef_b", 0) == NULL && g_red == red0 + 1, "分片 1 大小与索引不符：报红、返回空");
    char empty[] = "/tmp/t_lib_pack_e.XXXXXX"; if (!mkdtemp(empty)) return 2;
    lp_pack s; int red1 = g_red; CHECK(lp_open(&s, empty, "abcdef012345") == 0 && g_red == red1, "没有 lib.idx：返回 0、不报红（由调用方判旧格式）");
    {   // 同一段只建一个库（lp_library，11-05 时之笛：批库 1139 段被多键共用，最大一段 22 MB / 196 键；按键各建一个库，进 3D 时低区被吃掉约 800 MB）
        //   键 C1、C2 的种类 0 指向同一段 a.metallib（分片 0），键 C3 指向另一段 b.metallib（分片 1）。期望（由写进去的记录决定）：C1、C2 拿到同一个库对象、只建 1 次；
        //   C3 是另一个库；没有的键给 ENOENT。负对照：三个库都放掉后再取 C1，弱引用表里已没有它，要新建（计数 +1）——表不能把库续命
        char d3[] = "/tmp/t_lib_pack_s.XXXXXX"; if (!mkdtemp(d3)) return 2;
        uint64_t k3[3] = {0xc1, 0xc2, 0xc3}; uint8_t kd3[3] = {0, 0, 0}, sh3[3] = {0, 0, 1};
        write_pack(d3, "abcdef012345", @[la, la, lb], sh3, k3, kd3, 3, -1);
        lp_pack t; int o3 = lp_open(&t, d3, "abcdef012345");
        CHECK(o3 == 1 && t.rec[0].off == t.rec[1].off && t.rec[0].shard == t.rec[1].shard && t.rec[2].shard == 1, "共用段容器：C1、C2 记录同分片同偏移，C3 在分片 1");
        uint64_t b0 = atomic_load(&g_lp_lib_built), s0 = atomic_load(&g_lp_lib_shared); int ly1 = -1, ly2 = -1; NSError *e3 = nil;
        uintptr_t w1 = 0;
        @autoreleasepool {
            id<MTLLibrary> c1 = lp_library(&t, dev, "00000000000000c1_b", 0, &ly1, &e3), c2 = lp_library(&t, dev, "00000000000000c2_b", 0, &ly2, &e3), c3 = lp_library(&t, dev, "00000000000000c3_b", 0, NULL, &e3);
            CHECK(c1 && c1 == c2, "C1、C2 同段：同一个库对象（%p / %p）", (__bridge void *)c1, (__bridge void *)c2);
            CHECK(c3 && c3 != c1 && [c3 newFunctionWithName:@"fb"] && [c1 newFunctionWithName:@"fa"], "C3 另一段：另一个库，入口各自取得到（fa / fb）");
            CHECK(atomic_load(&g_lp_lib_built) - b0 == 2 && atomic_load(&g_lp_lib_shared) - s0 == 1, "建库 2 次、共用 1 次（得建 %llu、共用 %llu）",
                  (unsigned long long)(atomic_load(&g_lp_lib_built) - b0), (unsigned long long)(atomic_load(&g_lp_lib_shared) - s0));
            CHECK(ly1 == ly2, "同段的图层标志一致（%d / %d）", ly1, ly2);
            NSError *e4 = nil; CHECK(lp_library(&t, dev, "00000000000000c4_b", 0, NULL, &e4) == nil && e4.code == ENOENT, "没有的键：nil、ENOENT");
            w1 = (uintptr_t)(__bridge void *)c1;
        }
        uint64_t b1 = atomic_load(&g_lp_lib_built);
        @autoreleasepool { id<MTLLibrary> c1b = lp_library(&t, dev, "00000000000000c1_b", 0, NULL, &e3);
            CHECK(c1b && atomic_load(&g_lp_lib_built) == b1 + 1, "负对照：库全部放掉后再取 C1 要新建（建库 +%llu；表是弱引用，不给库续命）", (unsigned long long)(atomic_load(&g_lp_lib_built) - b1)); (void)w1; }
    }
    {   // 段映射放宿主高位区（11-05 赤痕 / 轩辕剑柒：开局预热 1.4 秒映射 796 MB / 251 段，mmap(NULL) 全落低区，GC 现长 32 MB 新段拿不到地址、托管 OOM）。
        //   模拟：「低区」= mmap(NULL) 落的最低空洞；「高位区」= 在 0x60_0000_0000 一带先占 64 MB 再放掉留下的空洞 [H, H + 64 MB)，注入给 LP_HI_RANGE。
        //   期望（只由造的区间与写进去的字节决定）：6 段（各 1 MB、内容各不同）全落 [H, H + 64 MB)、字节逐段相等、H 之下的 .pak 映射字节不增长；
        //   高位区里的段建库取得到入口；段全部放掉后区里 .pak 字节回 0（释放路径 munmap）。区满（区间 4 MB、整块已被占）：段照样取到（退回低区，地址在 H 之下）、
        //   报红恰好 1 次（两段只报一次）；有原生层但没有高位区（LP_HI_RANGE 回 0）：同样退回、报红恰好 1 次
        char d5[] = "/tmp/t_lib_pack_h.XXXXXX"; if (!mkdtemp(d5)) return 2; char r5[PATH_MAX]; if (!realpath(d5, r5)) return 2;
        enum { NS = 6 }; NSMutableArray<NSData *> *sg = [NSMutableArray array]; uint64_t k5[NS + 1]; uint8_t kd5[NS + 1], sh5[NS + 1];
        for (int i = 0; i < NS; i++) { NSMutableData *m = [NSMutableData dataWithLength:(1 << 20) + 4096 * i]; memset(m.mutableBytes, 0x11 * (i + 1), m.length); [sg addObject:m]; k5[i] = 0xd0 + i; kd5[i] = 0; sh5[i] = i & 1; }
        [sg addObject:la]; k5[NS] = 0xe0; kd5[NS] = 0; sh5[NS] = 0;
        write_pack(d5, "abcdef012345", sg, sh5, k5, kd5, NS + 1, -1);
        lp_pack h; CHECK(lp_open(&h, d5, "abcdef012345") == 1, "高位区容器：7 段");
        const uint64_t HN = 64ull << 20; void *hr = mmap((void *)0x6000000000ull, HN, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); uint64_t H = (uint64_t)hr;
        CHECK(hr != MAP_FAILED, "造高位区：%#llx +64 MB", (unsigned long long)H); munmap(hr, HN);
        g_hr_rc = 1; g_hr_lo = H; g_hr_hi = H + HN; int red0 = g_red; uint64_t low0 = pak_bytes_in(r5, 0, H);
        @autoreleasepool {
            dispatch_data_t seg[NS]; int inr = 0, same = 0; uint64_t sum = 0, pg = (uint64_t)getpagesize();
            for (int i = 0; i < NS; i++) { char nm[32]; snprintf(nm, sizeof nm, "%016llx_b", (unsigned long long)k5[i]); seg[i] = lp_get(&h, nm, 0);
                const void *b = NULL; size_t n = 0; dispatch_data_t f = seg[i] ? dispatch_data_create_map(seg[i], &b, &n) : nil; (void)f;
                if (b && (uint64_t)b >= H && (uint64_t)b + n <= H + HN) inr++;
                if (seg[i] && [(NSData *)seg[i] isEqualToData:sg[i]]) same++;
                sum += (sg[i].length + pg - 1) / pg * pg; }
            CHECK(inr == NS, "6 段都落在高位区 [%#llx, %#llx)（得 %d 段）", (unsigned long long)H, (unsigned long long)(H + HN), inr);
            CHECK(same == NS, "6 段字节逐段相等（得 %d 段）", same);
            uint64_t low1 = pak_bytes_in(r5, 0, H), inb = pak_bytes_in(r5, H, H + HN);
            CHECK(low1 == low0, "低区（H 之下）.pak 映射不增长：%llu → %llu 字节", (unsigned long long)low0, (unsigned long long)low1);
            CHECK(inb >= sum && inb <= sum + NS * pg, "高位区里 .pak 映射 %llu 字节 = 6 段按页取整之和 %llu（+每段至多一页对齐差）", (unsigned long long)inb, (unsigned long long)sum);
            NSError *e5 = nil; id<MTLLibrary> lh = lp_library(&h, dev, "00000000000000e0_b", 0, NULL, &e5);
            CHECK(lh && [lh newFunctionWithName:@"fa"], "高位区里的段建库取到入口 fa");
            CHECK(g_red == red0, "高位区放得下：不报红（得 %d 次）", g_red - red0);
            for (int i = 0; i < NS; i++) seg[i] = nil;
            lh = nil;
        }
        uint64_t left = 0; for (int t = 0; t < 200 && (left = pak_bytes_in(r5, H, H + HN)); t++) usleep(10000);   // 放掉的回调在全局队列上异步跑
        CHECK(left == 0, "段全部放掉后高位区 .pak 映射回 0（得 %llu 字节）", (unsigned long long)left);
        void *full = mmap((void *)H, 4 << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);   // 区满：区间 4 MB（比段大）、整块已被别人占着
        g_hr_lo = (uint64_t)full; g_hr_hi = (uint64_t)full + (4 << 20); int red1 = g_red;
        @autoreleasepool {
            dispatch_data_t f0 = lp_get(&h, "00000000000000d0_b", 0), f1 = lp_get(&h, "00000000000000d1_b", 0);
            const void *b0 = NULL, *b1 = NULL; size_t n0 = 0, n1 = 0; dispatch_data_t m0 = f0 ? dispatch_data_create_map(f0, &b0, &n0) : nil, m1 = f1 ? dispatch_data_create_map(f1, &b1, &n1) : nil; (void)m0; (void)m1;
            CHECK(f0 && f1 && [(NSData *)f0 isEqualToData:sg[0]] && [(NSData *)f1 isEqualToData:sg[1]], "区满：两段照样取到、字节相等（退回原路径，开局不失败）");
            CHECK(b0 && b1 && (uint64_t)b0 < H && (uint64_t)b1 < H, "区满：两段落在低区（%p / %p，H 之下）", b0, b1);
            CHECK(g_red == red1 + 1, "区满：报红恰好 1 次（两段，得 %d 次）", g_red - red1);
        }
        g_hr_rc = 0; int red2 = g_red;
        @autoreleasepool {
            dispatch_data_t f2 = lp_get(&h, "00000000000000d2_b", 0), f3 = lp_get(&h, "00000000000000d3_b", 0);
            CHECK(f2 && f3 && [(NSData *)f2 isEqualToData:sg[2]] && [(NSData *)f3 isEqualToData:sg[3]] && g_red == red2 + 1, "没有高位区：两段照样取到、报红恰好 1 次（得 %d 次）", g_red - red2);
        }
        g_hr_rc = -1; if (full != MAP_FAILED) munmap(full, 4 << 20);
    }
    printf("%s t_lib_pack：%d 项，不通 %d\n", fails ? "✗" : "✓", checks, fails);
    return fails ? 1 : 0;
} }
