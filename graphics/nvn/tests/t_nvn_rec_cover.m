// 延后编码替身齐全（nvn_rec.h，DM_NVN_ENC_THREAD 在 iOS 缺省开、Mac 缺省关）：替身类漏一个方法，Mac 局和别的单测都拦不住，iOS 真机起局即 MDIE。
//   11-01：审计缺口族 36（a4de9da27）把 enc_r_stencil_ref 改成 setStencilFrontReferenceValue:backReferenceValue:，DmRecEnc 只有旧的 setStencilReferenceValue:，
//   iOS 上凡用到模板参考值的直连包首帧前就停（马车8 测试机1 连崩 3 次触发直连安全网）。
// ① 通用：本文件直接包含生产 nvn_mtl.m，构建时先单独编成 .o（argv[1]）。这个编译单元发出的全部消息（.o 里的 _objc_msgSend$<选择子> 桩符号——arm64 的 clang 缺省把每个消息发送编成对桩的调用——
//    加上 __objc_selrefs 经重定位指到的选择子名；不用 __objc_methname：@protocol 元数据会把整份协议的方法名都放进去）里，
//    凡属于 Metal 4 编码器 / 命令缓冲 / 参数表协议的，对应替身（DmRecEnc / DmRecCB / DmRecTable）都必须实现。只看这一个 .o：链进来的宿主库各自发的消息不算。
//    本文件自己不发这些协议里的消息（探针方法只经 enc_r_* 与 rec_exec 调到），选择子全部来自生产代码。
// ② 模板参考值、按线程数派发经替身录制、在探针编码器上回放，参数原样到位（期望值 3 / 7、37 / 32 手写，与实现无关）。
#include "../gfx/nvn/nvn_mtl.m"
#include <fcntl.h>
#include <mach-o/getsect.h>
#include <mach-o/nlist.h>
#include <mach-o/reloc.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks;
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)

// 协议 p（含它采纳的协议）里声明的实例方法，凡被本程序引用的、cls 都要能答；返回漏的个数，逐个打印
// 选择子同名、但生产代码只发给真对象（不经替身）的，逐条写明接收者；新增一条前先核所有发送点
static const struct { const char *cls, *sel, *why; } g_real_only[] = {
    {"DmRecEnc", "commandBuffer", "只发给命令队列 g_q / g_q3 / q（nvn_mtl.m q_cb 等），编码器协议里同名属性没人读"},
    {"DmRecEnc", "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:options:",
        "只发给 Metal 3 拷贝编码器（读回 / 诊断：cb 来自真队列 [q commandBuffer] / q_cb）"},
    {"DmRecEnc", "copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:options:",
        "只发给 Metal 3 拷贝编码器（帧录放 nvn_frame_rec.inc fr_blit_planes：深度模板面写回，cb 来自真队列 [g_q commandBuffer]，不经编码线程）"},
    {"DmRecCB", "setLabel:", "只发给编码器（DM_NVN_ENC_LABEL，DmRecEnc 有替身），命令缓冲不设标签"},
};
static int real_only(Class cls, SEL s) {
    for (size_t i = 0; i < sizeof g_real_only / sizeof *g_real_only; i++)
        if (!strcmp(class_getName(cls), g_real_only[i].cls) && !strcmp(sel_getName(s), g_real_only[i].sel)) return 1;
    return 0;
}
static unsigned cover(Protocol *p, Class cls, const SEL *refs, size_t nref, unsigned *seen) {
    unsigned miss = 0, n = 0;
    for (int req = 0; req < 2; req++) {
        struct objc_method_description *m = protocol_copyMethodDescriptionList(p, req, YES, &n);
        for (unsigned i = 0; i < n; i++)
            for (size_t k = 0; k < nref; k++) if (refs[k] == m[i].name) {
                (*seen)++;
                if (![cls instancesRespondToSelector:m[i].name] && !real_only(cls, m[i].name)) { fprintf(stderr, "  %s 没有替身：-%s（%s）\n", class_getName(cls), sel_getName(m[i].name), protocol_getName(p)); miss++; }
                break;
            }
        free(m);
    }
    unsigned np = 0; Protocol *__unsafe_unretained *sub = protocol_copyProtocolList(p, &np);
    for (unsigned i = 0; i < np; i++) if (sub[i] != @protocol(NSObject)) miss += cover(sub[i], cls, refs, nref, seen);
    free(sub);
    return miss;
}

@interface StencilProbe : NSObject
@property uint32_t front, back;
@end
@implementation StencilProbe
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b { self.front = f; self.back = b; }
@end
@interface DispatchProbe : NSObject
@property MTLSize n, t;
@end
@implementation DispatchProbe
- (void)dispatchThreads:(MTLSize)n threadsPerThreadgroup:(MTLSize)t { self.n = n; self.t = t; }
@end

int main(int argc, char **argv) { @autoreleasepool {
    REQUIRE(argc == 2);
    int fd = open(argv[1], O_RDONLY); REQUIRE(fd >= 0); struct stat st; REQUIRE(!fstat(fd, &st));
    const struct mach_header_64 *mh = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0); REQUIRE(mh != MAP_FAILED && mh->magic == MH_MAGIC_64 && mh->filetype == MH_OBJECT);
    const struct section_64 *nm = getsectbynamefromheader_64(mh, "__TEXT", "__objc_methname"), *sr = getsectbynamefromheader_64(mh, "__DATA", "__objc_selrefs");
    REQUIRE(nm && sr && nm->offset + nm->size <= (uint64_t)st.st_size && sr->offset + sr->size <= (uint64_t)st.st_size);
    const struct symtab_command *symtab = NULL; const struct load_command *lc = (const void *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) if (lc->cmd == LC_SYMTAB) symtab = (const void *)lc;
    const struct nlist_64 *syms = symtab ? (const void *)((const char *)mh + symtab->symoff) : NULL;
    // 每个选择子引用占 8 字节：重定位带外部符号 = 名字串的局部符号地址 + 原地加数；不带 = 原地就是名字串在 .o 里的地址
    size_t nref = sr->size / 8; SEL *refs = calloc(nref, sizeof *refs); size_t got = 0;
    const struct relocation_info *rel = (const void *)((const char *)mh + sr->reloff);
    for (uint32_t i = 0; i < sr->nreloc; i++) {
        uint64_t at = rel[i].r_address, v; REQUIRE(at + 8 <= sr->size); memcpy(&v, (const char *)mh + sr->offset + at, 8);
        if (rel[i].r_extern) { REQUIRE(syms && rel[i].r_symbolnum < symtab->nsyms); v += syms[rel[i].r_symbolnum].n_value; }
        REQUIRE(v >= nm->addr && v < nm->addr + nm->size);
        refs[got++] = sel_registerName((const char *)mh + nm->offset + (v - nm->addr));
    }
    REQUIRE(got == nref);
    for (uint32_t i = 0; syms && i < symtab->nsyms; i++) {
        const char *n = (const char *)mh + symtab->stroff + syms[i].n_un.n_strx;
        if (!strncmp(n, "_objc_msgSend$", 14)) { refs = realloc(refs, (nref + 1) * sizeof *refs); refs[nref++] = sel_registerName(n + 14); }
    }
    unsigned seen = 0, miss = 0;
    miss += cover(@protocol(MTL4RenderCommandEncoder), [DmRecEnc class], refs, nref, &seen);
    miss += cover(@protocol(MTL4ComputeCommandEncoder), [DmRecEnc class], refs, nref, &seen);
    miss += cover(@protocol(MTL4CommandBuffer), [DmRecCB class], refs, nref, &seen);
    miss += cover(@protocol(MTL4ArgumentTable), [DmRecTable class], refs, nref, &seen);
    REQUIRE(seen >= 30);   // 射程：生产代码确实对这些协议发了消息（扫空了就是取段出错）
    REQUIRE(miss == 0);

    DmRecEnc *rec = [DmRecEnc new]; rec->render = 1;
    enc_r_stencil_ref((id<MTL4RenderCommandEncoder>)(id)rec, 3, 7);
    REQUIRE(g_rb_cur && g_rb_cur->n >= 1);
    rec_t r = g_rb_cur->r[g_rb_cur->n - 1]; g_rb_cur->n--;   // 取回刚录的一条，不交给编码线程
    StencilProbe *probe = [StencilProbe new]; g_rx_enc = probe; rec_exec(&r); g_rx_enc = nil;
    REQUIRE(probe.front == 3); REQUIRE(probe.back == 7);
    // 曲面细分 TCS（eb9f2b947 起用 dispatchThreads，最后一组不补满）：经替身录制、回放，线程数与组大小原样
    enc_c_dispatch_threads([DmRecEnc new], MTLSizeMake(37, 1, 1), MTLSizeMake(32, 1, 1));
    r = g_rb_cur->r[g_rb_cur->n - 1]; g_rb_cur->n--;
    DispatchProbe *dp = [DispatchProbe new]; g_rx_enc = dp; rec_exec(&r); g_rx_enc = nil;
    REQUIRE(dp.n.width == 37 && dp.n.height == 1 && dp.n.depth == 1); REQUIRE(dp.t.width == 32 && dp.t.height == 1 && dp.t.depth == 1);
    printf("✓ t_nvn_rec_cover：%zu 个消息里 %u 次落在 Metal 4 编码器 / 命令缓冲 / 参数表协议，替身全有；模板参考值、按线程数派发回放原样（%u 项）\n", nref, seen, checks);
    return 0;
} }
