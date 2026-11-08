// 读自身签名里真实生效的权限（iml_probe.m 首启复核用）：进程内解析 Mach-O，不起子进程、不读描述文件（描述文件允许 ≠ 签名带上）。
//   主程序头 → LC_CODE_SIGNATURE（数据在 __LINKEDIT 里，dyld 整段映射）→ SuperBlob（0xfade0cc0，大端）→ 槽 5 权限 blob（0xfade7171）→ XML plist，查键是否 <true/>。
// 纯 C、只读内存，Mac 单测用合成 SuperBlob 与真签名的单测程序验（runtime/tests/t_imlent.c）。
#include "native.h"
#include <string.h>

#define MH_MAGIC64      0xfeedfacfu
#define LC_SEG64        0x19u
#define LC_CODESIG      0x1du
#define CS_SUPERBLOB    0xfade0cc0u
#define CS_ENT_MAGIC    0xfade7171u
#define CS_SLOT_ENT     5u

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint32_t le32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t le64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }

static const char *find(const char *h, size_t hn, const char *n, size_t nn) {
    for (size_t i = 0; nn <= hn && i <= hn - nn; i++) if (!memcmp(h + i, n, nn)) return h + i;
    return NULL;
}

int s2a_ent_xml_has(const char *xml, size_t len, const char *key) {
    char k[256]; int kn = snprintf(k, sizeof k, "<key>%s</key>", key);
    if (kn <= 0 || (size_t)kn >= sizeof k) return -1;
    const char *p = find(xml, len, k, (size_t)kn), *e = xml + len;
    if (!p) return 0;
    for (p += kn; p < e && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r'); p++) {}
    if ((size_t)(e - p) >= 7 && !memcmp(p, "<true/>", 7)) return 1;
    if ((size_t)(e - p) >= 8 && !memcmp(p, "<true />", 8)) return 1;
    return 0;
}

int s2a_ent_blob_has(const uint8_t *sb, size_t len, const char *key) {
    if (!sb || len < 12 || be32(sb) != CS_SUPERBLOB) return -1;
    uint32_t total = be32(sb + 4), n = be32(sb + 8);
    if (total < 12 || total > len || n > (total - 12) / 8) return -1;
    for (uint32_t i = 0; i < n; i++) {
        const uint8_t *ix = sb + 12 + 8 * i;
        if (be32(ix) != CS_SLOT_ENT) continue;
        uint32_t off = be32(ix + 4);
        if (off > total - 8 || be32(sb + off) != CS_ENT_MAGIC) return -1;
        uint32_t bl = be32(sb + off + 4);
        if (bl < 8 || bl > total - off) return -1;
        return s2a_ent_xml_has((const char *)sb + off + 8, bl - 8, key);
    }
    return -1;   // 有签名、没有权限槽（链接器自签 / 不带权限签名）
}

int s2a_ent_has(const void *mh, const char *key) {
    const uint8_t *h = mh;
    if (!h || le32(h) != MH_MAGIC64) return -1;
    uint32_t ncmds = le32(h + 16), sizeofcmds = le32(h + 20);
    const uint8_t *lc = h + 32, *end = lc + sizeofcmds;
    uint64_t text_vm = 0, le_vm = 0, le_off = 0, le_fsz = 0; uint32_t cs_off = 0, cs_sz = 0; int has_text = 0, has_le = 0, has_cs = 0;
    for (uint32_t i = 0; i < ncmds && lc + 8 <= end; i++) {
        uint32_t cmd = le32(lc), cs = le32(lc + 4);
        if (cs < 8 || lc + cs > end) return -1;
        if (cmd == LC_SEG64 && cs >= 72) {
            if (!strncmp((const char *)lc + 8, "__TEXT", 16)) { text_vm = le64(lc + 24); has_text = 1; }
            else if (!strncmp((const char *)lc + 8, "__LINKEDIT", 16)) { le_vm = le64(lc + 24); le_off = le64(lc + 40); le_fsz = le64(lc + 48); has_le = 1; }
        } else if (cmd == LC_CODESIG && cs >= 16) { cs_off = le32(lc + 8); cs_sz = le32(lc + 12); has_cs = 1; }
        lc += cs;
    }
    if (!has_text || !has_le || !has_cs || le_vm < text_vm) return -1;
    if (cs_off < le_off || (uint64_t)cs_off + cs_sz > le_off + le_fsz) return -1;
    // 主程序头就在 __TEXT 起点（fileoff 0）：签名在内存里 = 头 + (__LINKEDIT 虚拟地址 − __TEXT 虚拟地址) + (签名文件偏移 − __LINKEDIT 文件偏移)
    return s2a_ent_blob_has(h + (le_vm - text_vm) + (cs_off - le_off), cs_sz, key);
}

int s2a_va_jumbo(uint64_t va_top) {
    if (!va_top) return -1;
    return va_top >= (32ull << 30);   // 大地址档上限 0xfc0000000（63 GiB）；不带权限的 DEVICE_LARGE 15.4 / 17.4 GiB（R02 布局_系统版本x权限.tsv）
}
