// 外置镜像包（通用映射加载器）：接口与格式见 imgpack.h、docs/接口_原生层.md「外置镜像包」
#if defined(__APPLE__)
#include "imgpack.h"
#include <errno.h>
#include <stdarg.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <mach-o/loader.h>
#include <mach/mach.h>

#define PG 0x4000ull
typedef struct { char name[24]; struct { uint64_t off, len; } b[4]; } img_ent;   // 与 embed.py 每项 88 字节一致
_Static_assert(sizeof(img_ent) == 88, "偏移表项 88 字节");
struct s2a_imgpack {
    char path[1024]; int fd;
    uint64_t code_off, code_len, w_off, w_len;   // 两个合并节在包文件里的绝对偏移与长度
    img_ent *ent; uint32_t n;
    struct s2a_imgpack *next;
};
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static struct s2a_imgpack *g_open;   // 已打开的包（按路径，进程内只开 / 注册一次）

static int fail(char *why, size_t whyn, int rc, const char *fmt, ...) __attribute__((format(printf, 4, 5)));
static int fail(char *why, size_t whyn, int rc, const char *fmt, ...) {
    if (why && whyn) { va_list ap; va_start(ap, fmt); vsnprintf(why, whyn, fmt, ap); va_end(ap); }
    return rc;
}
static int rd(int fd, void *b, size_t n, uint64_t off) {
    for (size_t got = 0; got < n;) { ssize_t r = pread(fd, (char *)b + got, n - got, (off_t)(off + got)); if (r < 0 && errno == EINTR) continue; if (r <= 0) return -1; got += (size_t)r; }
    return 0;
}
static int load(struct s2a_imgpack *p, int sign, char *why, size_t whyn) {   // sign = 0：只读头与偏移表（s2a_imgpack_index），不注册签名
    struct mach_header_64 h;
    if (rd(p->fd, &h, sizeof h, 0) || h.magic != MH_MAGIC_64) return fail(why, whyn, S2A_IMG_EFORMAT, "%s 不是 64 位 Mach-O（瘦文件）", p->path);
    uint8_t *lc = malloc(h.sizeofcmds); if (!lc || rd(p->fd, lc, h.sizeofcmds, sizeof h)) { free(lc); return fail(why, whyn, S2A_IMG_EFORMAT, "%s 读 load commands 失败", p->path); }
    uint64_t io = 0, iz = 0; int have_c = 0, have_w = 0, have_i = 0; struct linkedit_data_command cs = {0};
    for (uint32_t i = 0, o = 0; i < h.ncmds && o + sizeof(struct load_command) <= h.sizeofcmds; i++) {
        struct load_command *l = (struct load_command *)(lc + o);
        if (l->cmdsize < sizeof *l || o + l->cmdsize > h.sizeofcmds) break;
        if (l->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *sg = (struct segment_command_64 *)l; struct section_64 *s = (struct section_64 *)(sg + 1);
            for (uint32_t k = 0; k < sg->nsects; k++, s++) {
                if (!strncmp(s->segname, "__TEXT", 16) && !strncmp(s->sectname, "__swcode", 16)) { p->code_off = s->offset; p->code_len = s->size; have_c = 1; }
                else if (!strncmp(s->segname, "__SWDATA", 16) && !strncmp(s->sectname, "__img", 16)) { p->w_off = s->offset; p->w_len = s->size; have_w = 1; }
                else if (!strncmp(s->segname, "__TEXT", 16) && !strncmp(s->sectname, "__swidx", 16)) { io = s->offset; iz = s->size; have_i = 1; }
            }
        } else if (l->cmd == LC_CODE_SIGNATURE) cs = *(struct linkedit_data_command *)l;
        o += l->cmdsize;
    }
    free(lc);
    if (!have_i || iz < 16) return fail(why, whyn, S2A_IMG_EFORMAT, "%s 缺偏移表 __TEXT,__swidx", p->path);
    uint8_t hd[16]; if (rd(p->fd, hd, 16, io) || memcmp(hd, "S2AEMB01", 8)) return fail(why, whyn, S2A_IMG_EFORMAT, "%s 偏移表魔数不符（embed.py 与本程序不配套）", p->path);
    uint32_t n, es; memcpy(&n, hd + 8, 4); memcpy(&es, hd + 12, 4);
    if (es != sizeof(img_ent) || 16 + (uint64_t)n * es > iz) return fail(why, whyn, S2A_IMG_EFORMAT, "%s 偏移表项长 %u（应 %zu）或项数 %u 超出表长 %#llx", p->path, es, sizeof(img_ent), n, (unsigned long long)iz);
    if (n && (!have_c || !have_w || ((p->code_off | p->w_off) & (PG - 1))))
        return fail(why, whyn, S2A_IMG_EFORMAT, "%s 合并节 __TEXT,__swcode / __SWDATA,__img 缺失或文件偏移未按 16K 对齐", p->path);
    p->ent = calloc(n ? n : 1, sizeof *p->ent);
    if (!p->ent || (n && rd(p->fd, p->ent, (size_t)n * sizeof *p->ent, io + 16))) return fail(why, whyn, S2A_IMG_EFORMAT, "%s 读偏移表失败", p->path);
    uint64_t cend = 0, wend = 0;
    for (uint32_t i = 0; i < n; i++)
        for (int k = 0; k < 4; k++) {
            uint64_t o = p->ent[i].b[k].off, l = p->ent[i].b[k].len;
            if (!l) { if (k == S2A_IMG_X0 || k == S2A_IMG_W) return fail(why, whyn, S2A_IMG_EFORMAT, "镜像 %.24s 的第 %d 块长度为 0", p->ent[i].name, k); continue; }
            uint64_t *end = k == S2A_IMG_W ? &wend : &cend, lim = k == S2A_IMG_W ? p->w_len : p->code_len;
            if (((o | l) & (PG - 1)) || o < *end || o + l > lim)
                return fail(why, whyn, S2A_IMG_EFORMAT, "镜像 %.24s 第 %d 块（偏移 %#llx 长 %#llx）未按 16K 对齐、与前一块重叠或超出合并节（%#llx）", p->ent[i].name, k,
                            (unsigned long long)o, (unsigned long long)l, (unsigned long long)lim);
            *end = o + l;
        }
    p->n = n;
    if (!sign) return S2A_IMG_OK;
    // 签名注册（进程内一次；dyld 装 dylib 也是这一步）：内核按文件登记代码目录，之后这个文件的页才能映射成可执行；库校验要同团队签名
    if (!cs.cmd) return fail(why, whyn, S2A_IMG_ESIGN, "%s 没有代码签名（LC_CODE_SIGNATURE）", p->path);
    fsignatures_t fs = {.fs_file_start = 0, .fs_blob_start = (void *)(uintptr_t)cs.dataoff, .fs_blob_size = cs.datasize};
    if (fcntl(p->fd, F_ADDFILESIGS_RETURN, &fs) == -1) return fail(why, whyn, S2A_IMG_ESIGN, "%s 注册签名失败 errno=%d", p->path, errno);
    char msg[256] = ""; fchecklv_t lv = {.lv_file_start = 0, .lv_error_message_size = sizeof msg, .lv_error_message = msg};
    if (fcntl(p->fd, F_CHECK_LV, &lv) == -1) return fail(why, whyn, S2A_IMG_ESIGN, "%s 库校验失败 errno=%d %s", p->path, errno, msg);
    return S2A_IMG_OK;
}
int s2a_imgpack_open(const char *path, s2a_imgpack **out, char *why, size_t whyn) {
    *out = NULL;
    pthread_mutex_lock(&g_mu);
    for (struct s2a_imgpack *q = g_open; q; q = q->next) if (!strcmp(q->path, path)) { *out = q; pthread_mutex_unlock(&g_mu); return S2A_IMG_OK; }
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) { int e = errno; pthread_mutex_unlock(&g_mu); return fail(why, whyn, e == ENOENT ? S2A_IMG_ENOFILE : S2A_IMG_EFORMAT, "打不开 %s errno=%d", path, e); }
    struct s2a_imgpack *p = calloc(1, sizeof *p);
    if (!p) { close(fd); pthread_mutex_unlock(&g_mu); return fail(why, whyn, S2A_IMG_EFORMAT, "内存不足"); }
    strlcpy(p->path, path, sizeof p->path); p->fd = fd;
    int rc = load(p, 1, why, whyn);
    if (rc) { close(fd); free(p->ent); free(p); pthread_mutex_unlock(&g_mu); return rc; }
    p->next = g_open; g_open = p; *out = p;
    pthread_mutex_unlock(&g_mu);
    return S2A_IMG_OK;
}
int s2a_imgpack_index(const char *path, s2a_imgpack **out, char *why, size_t whyn) {
    *out = NULL;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) { int e = errno; return fail(why, whyn, e == ENOENT ? S2A_IMG_ENOFILE : S2A_IMG_EFORMAT, "打不开 %s errno=%d", path, e); }
    struct s2a_imgpack *p = calloc(1, sizeof *p);
    if (!p) { close(fd); return fail(why, whyn, S2A_IMG_EFORMAT, "内存不足"); }
    strlcpy(p->path, path, sizeof p->path); p->fd = fd;
    int rc = load(p, 0, why, whyn);
    close(fd); p->fd = -1;   // 只查表：不映射，fd 不留
    if (rc) { free(p->ent); free(p); return rc; }
    *out = p; return S2A_IMG_OK;
}
void s2a_imgpack_free(s2a_imgpack *p) { if (p) { free(p->ent); free(p); } }
int s2a_imgpack_find(const s2a_imgpack *p, const char *name, int blk, uint64_t *off, uint64_t *len) {
    *off = *len = 0;
    if (!p || blk < 0 || blk > 3 || strlen(name) >= sizeof p->ent[0].name) return 0;
    for (uint32_t i = 0; i < p->n; i++)
        if (!strncmp(p->ent[i].name, name, sizeof p->ent[i].name)) {
            *len = p->ent[i].b[blk].len;
            *off = (blk == S2A_IMG_W ? p->w_off : p->code_off) + p->ent[i].b[blk].off;
            return 1;
        }
    return 0;
}
int s2a_imgpack_map(const s2a_imgpack *p, void *at, uint64_t off, uint64_t len, int code, int *err) {
    if (err) *err = 0;
    if (!p || (((uint64_t)(uintptr_t)at | off | len) & (PG - 1))) { if (err) *err = EINVAL; return S2A_IMG_EMAP; }
    if (!len) return S2A_IMG_OK;
    void *m = mmap(at, (size_t)len, code ? PROT_READ | PROT_EXEC : PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE, p->fd, (off_t)off);
    if (m != at) { if (err) *err = m == MAP_FAILED ? errno : EFAULT; return S2A_IMG_EMAP; }
    if (code && vm_protect(mach_task_self(), (vm_address_t)at, (vm_size_t)len, TRUE, VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS) { if (err) *err = EPERM; return S2A_IMG_EPROT; }
    return S2A_IMG_OK;
}
int s2a_imgpack_same(const s2a_imgpack *p, const void *at, uint64_t off, uint64_t len) {
    if (!p || !len) return 0;
    for (vm_address_t a = (vm_address_t)at; a < (vm_address_t)at + len;) {   // 逐段核：中间有没映射 / 不可读的段就不比（读到会崩）
        vm_address_t r = a; vm_size_t sz = 0; natural_t depth = 0; vm_region_submap_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &r, &sz, &depth, (vm_region_recurse_info_t)&info, &cnt) != KERN_SUCCESS || r > a || !(info.protection & VM_PROT_READ)) return 0;
        a = r + sz;
    }
    enum { CH = 1 << 20 }; uint8_t *b = malloc(CH); if (!b) return 0;
    int same = 1;
    for (uint64_t d = 0; d < len && same; d += CH) {
        size_t n = (size_t)(len - d < CH ? len - d : CH);
        same = !rd(p->fd, b, n, off + d) && !memcmp((const uint8_t *)at + d, b, n);
    }
    free(b); return same;
}
#else
typedef int s2a_imgpack_not_apple;   // 安卓：模块映射走 APK 资源，本文件不编内容（空翻译单元会被 -Wpedantic 报）
#endif
