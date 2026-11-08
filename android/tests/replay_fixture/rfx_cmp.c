// rfx_cmp：期望流与实际流逐字节比对（0 容差，报第一处差异）。
//   rfx_cmp <期望.rfx> <实际.rfx> [--funcs a,b,c] [--dump <文件>]
// --funcs：只比下沿函数号在表内的 EXP 记录（按 D 步的范围截取比较面，README §4）。
// --dump：把记录流按序打成文本行（tag/函数名/字节数），人读用。
#include "rfx.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int dump(const char *path) {
    rfx_r r;
    if (rfx_r_open(&r, path)) { fprintf(stderr, "打不开 %s\n", path); return 2; }
    rfx_rec rec;
    int st, i = 0;
    while ((st = rfx_r_next(&r, &rec)) == 1) {
        const char *n = rec.tag == RFX_REC_EXP ? rfx_gpu_name(rec.id)
                        : rec.tag == RFX_REC_CHK ? rfx_chk_name(rec.id)
                        : rec.tag == RFX_REC_CALL ? rfx_call_name(rec.id)
                        : rec.tag == RFX_REC_RES ? rfx_res_name(rec.id) : rfx_tag_name(rec.tag);
        printf("%5u  @%-8llx %-6s %s  %uB\n", i++, (unsigned long long)rec.off, rfx_tag_name(rec.tag), n, rec.len);
    }
    if (st < 0) { fprintf(stderr, "%s 在 %#llx 处截断\n", path, (unsigned long long)r.pos); rfx_r_close(&r); return 2; }
    rfx_r_close(&r);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 3 && !strcmp(argv[1], "--dump")) return dump(argv[2]);
    if (argc < 3) {
        fprintf(stderr, "用法：rfx_cmp <期望.rfx> <实际.rfx> [--funcs a,b,c] | rfx_cmp --dump <文件>\n");
        return 2;
    }
    uint32_t funcs[128], nf = 0;
    const uint32_t *fp = NULL;
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--funcs") && i + 1 < argc) {
            char *s = argv[++i], *t;
            while ((t = strchr(s, ',')) || *s) {
                char *e; unsigned long v = strtoul(s, &e, 10);
                if (e == s || nf >= 128) { fprintf(stderr, "--funcs 参数坏：%s\n", s); return 2; }
                funcs[nf++] = (uint32_t)v;
                s = t ? t + 1 : e;
                if (!t) break;
            }
            fp = funcs;
        } else {
            fprintf(stderr, "认不得参数 %s\n", argv[i]);
            return 2;
        }
    }
    rfx_diff d;
    int r = rfx_cmp_file(argv[1], argv[2], fp, nf, &d);
    if (r) { printf("【红】%s\n", d.msg); return 1; }
    printf("一致：%s 与 %s 逐字节相同\n", argv[1], argv[2]);
    return 0;
}
