// imlent.c 单测：合成 Mach-O + SuperBlob 判带 / 缺 IML / 读不到；再拿本程序自身（make 分片用 codesign 带 / 不带权限各签一份）验内存里真签名段。
//   用法：t_imlent [<键> <期望自身结果 1 | 0 | -1>]…（不给参数不验自身）。macOS 不让 ad-hoc 签名带受限的 IML 键的程序启动（AMFI 直接 Killed: 9），
//   真签名这一支用可自签的 get-task-allow 键验「内存里的签名段能读到」，IML 键名匹配由合成数据覆盖
#include "../src/native.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/ldsyms.h>

#define IML "com.apple.developer.kernel.increased-memory-limit"
static int bad;
static void ck(int ok, const char *what) { printf("%s %s\n", ok ? "  ok" : "  ✗", what); if (!ok) bad++; }
static void pbe(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void ple(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void ple64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }

// SuperBlob：槽 0（假代码目录）+ 可选槽 5（权限 XML）；返回总长
static size_t superblob(uint8_t *o, const char *xml) {
    uint32_t n = xml ? 2 : 1, hdr = 12 + 8 * n, cd = hdr, cdl = 16;
    pbe(o, 0xfade0cc0); pbe(o + 8, n);
    pbe(o + 12, 0); pbe(o + 16, cd); pbe(o + cd, 0xfade0c02); pbe(o + cd + 4, cdl);
    uint32_t tot = cd + cdl;
    if (xml) { uint32_t xl = (uint32_t)strlen(xml); pbe(o + 20, 5); pbe(o + 24, tot); pbe(o + tot, 0xfade7171); pbe(o + tot + 4, 8 + xl); memcpy(o + tot + 8, xml, xl); tot += 8 + xl; }
    pbe(o + 4, tot); return tot;
}
// 合成 Mach-O：__TEXT vm 0x100000000 文件 0；__LINKEDIT vm 0x100004000 文件 0x2000（故意不等，验换算）；签名在 __LINKEDIT 里偏 0x40
static uint8_t img[0x8000] __attribute__((aligned(16)));
static void macho(int with_cs, const char *xml, uint32_t cs_shift) {
    memset(img, 0, sizeof img);
    uint8_t *h = img, *lc = h + 32; uint32_t n = 0;
    ple(h, 0xfeedfacf);
    ple(lc, 0x19); ple(lc + 4, 72); memcpy(lc + 8, "__TEXT", 6); ple64(lc + 24, 0x100000000ull); ple64(lc + 32, 0x2000); ple64(lc + 40, 0); ple64(lc + 48, 0x2000); lc += 72; n++;
    ple(lc, 0x19); ple(lc + 4, 72); memcpy(lc + 8, "__LINKEDIT", 10); ple64(lc + 24, 0x100004000ull); ple64(lc + 32, 0x2000); ple64(lc + 40, 0x2000); ple64(lc + 48, 0x2000); lc += 72; n++;
    if (with_cs) { size_t sl = superblob(img + 0x4000 + 0x40, xml); ple(lc, 0x1d); ple(lc + 4, 16); ple(lc + 8, 0x2040 + cs_shift); ple(lc + 12, (uint32_t)sl); lc += 16; n++; }
    ple(h + 16, n); ple(h + 20, (uint32_t)(lc - h - 32));
}

int main(int argc, char **argv) {
    const char *on = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>\n\t<key>" IML "</key>\n\t<true/>\n</dict></plist>";
    const char *off = "<plist><dict><key>" IML "</key><false/></dict></plist>";
    const char *other = "<plist><dict><key>" IML "-x</key><true/><key>get-task-allow</key><true/></dict></plist>";
    const char *spaced = "<plist><dict><key>" IML "</key> <true /></dict></plist>";
    macho(1, on, 0);     ck(s2a_ent_has(img, IML) == 1, "① 签名带 IML=true → 1");
    macho(1, off, 0);    ck(s2a_ent_has(img, IML) == 0, "② 签名里 IML=false → 0");
    macho(1, other, 0);  ck(s2a_ent_has(img, IML) == 0, "③ 只有前缀相同的别的键 → 0（不误认）");
    macho(1, spaced, 0); ck(s2a_ent_has(img, IML) == 1, "④ <true /> 带空格写法 → 1");
    macho(1, NULL, 0);   ck(s2a_ent_has(img, IML) == -1, "⑤ 有签名、没有权限槽（链接器自签）→ -1");
    macho(0, NULL, 0);   ck(s2a_ent_has(img, IML) == -1, "⑥ 没有 LC_CODE_SIGNATURE → -1");
    macho(1, on, 0x3000); ck(s2a_ent_has(img, IML) == -1, "⑦ 签名偏移越出 __LINKEDIT → -1（不越界读）");
    macho(1, on, 0); img[0] ^= 1; ck(s2a_ent_has(img, IML) == -1, "⑧ 不是 64 位 Mach-O → -1");
    macho(1, on, 0); pbe(img + 0x4040, 0xdeadbeef); ck(s2a_ent_has(img, IML) == -1, "⑨ SuperBlob 魔数不对 → -1");
    { uint8_t sb[512]; size_t l = superblob(sb, on); pbe(sb + 24, (uint32_t)l); ck(s2a_ent_blob_has(sb, l, IML) == -1, "⑩ 权限槽偏移指到末尾外 → -1");
      l = superblob(sb, on); ck(s2a_ent_blob_has(sb, l - 1, IML) == -1, "⑪ 给的长度比 SuperBlob 自报的短 → -1"); }
    ck(s2a_va_jumbo(0xfc0000000ull) == 1 && s2a_va_jumbo(0x458000000ull) == 0 && s2a_va_jumbo(0x3d8000000ull) == 0 && s2a_va_jumbo(0) == -1,
       "⑫ 地址上限 63 GiB → 大档；17.4 / 15.4 GiB → 小档；0 → 读不到");
    for (int i = 1; i + 1 < argc; i += 2) {   // 真签名：make 分片把本程序用 codesign 带 / 不带权限各签一份再跑
        int want = atoi(argv[i + 1]), got = s2a_ent_has(&_mh_execute_header, argv[i]); char m[320];
        snprintf(m, sizeof m, "⑬ 本程序自身签名查 %s（期望 %d → 实测 %d）", argv[i], want, got); ck(got == want, m);
    }
    printf("%s t_imlent（真签名 %d 项）：%d 处不符\n", bad ? "✗" : "✓", (argc - 1) / 2, bad);
    return bad != 0;
}
