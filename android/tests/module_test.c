#include "module.h"
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static char dir[] = "/tmp/s2a_module_test_XXXXXX";
static const uint64_t slots[S2A_KEY_N] = {0x188, 0x198, 0x1a8, 0x1b8};

static void write_file(const char *name, const void *data, size_t n) {
    char path[256];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "wb");
    fwrite(data, 1, n, f);
    fclose(f);
}

// fixups.tsv header as the C rewriter (runtime/rewriter/rewriter.c) writes it; `target` NULL = Apple output.
static void fixups(const char *name, const char *target, long long patch_off, unsigned long long key_page_off,
                   unsigned long long image_size, unsigned long long file_image_len) {
    char text[1024];
    int k = snprintf(text, sizeof text, "# BUILD_ID\t000102\n");
    if (target) k += snprintf(text + k, sizeof text - k, "# TARGET\t%s\n# REWRITE_ABI\tandroid-sp-safe-v1\n", target);
    k += snprintf(text + k, sizeof text - k, "# PATCH_OFF\t%s%#llx\n# KEY_PAGE_OFF\t%#llx\n# KEY_PAGE_SIZE\t0x4000\n"
                  "# TEXT_END\t0x1000\n# RO_OFF\t0x1000\n# DATA_OFF\t0x2000\n",
                  patch_off < 0 ? "-" : "", patch_off < 0 ? -patch_off : patch_off, key_page_off);
    if (image_size) k += snprintf(text + k, sizeof text - k, "# IMAGE_SIZE\t%#llx\n# FILE_IMAGE_LEN\t%#llx\n", image_size, file_image_len);
    k += snprintf(text + k, sizeof text - k, "# KEY_K18_IDX\t0\n# KEY_KTLS_IDX\t1\n# KEY_KTLR_IDX\t2\n# KEY_KGATE_IDX\t3\n");
    char file[64];
    snprintf(file, sizeof file, "%s.fixups.tsv", name);
    write_file(file, text, (size_t)k);
}

// Permissions of the mapping containing p, e.g. "r-xp".
static void perms(const void *p, char out[5]) {
    FILE *f = fopen("/proc/self/maps", "r");
    char line[512];
    uintptr_t lo, hi;
    strcpy(out, "????");
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "%" SCNxPTR "-%" SCNxPTR " %4s", &lo, &hi, out) == 3 && (uintptr_t)p >= lo && (uintptr_t)p < hi) break;
        else strcpy(out, "????");
    fclose(f);
}

static void check_key_page(const struct s2a_module *m) {
    const uint64_t *page = (const uint64_t *)(m->base + m->l.key_page_off);
    for (unsigned k = 0; k < S2A_KEY_N; k++) CHECK(page[k] == slots[k]);
}

// Optional: module_test <dir> <name> also maps real S2A_TARGET=android rewriter output.
int main(int argc, char **argv) {
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }
    char err[256], p[5];
    struct s2a_module_layout l;
    struct s2a_module m;

    // Near layout: image (text 0x1000, ro, data, key page at 0x4000) then the patch area at 0x10000.
    uint8_t *near = calloc(1, 0x10010);
    memset(near, 0xd5, 0x1000);
    memcpy(near + 0x10000, "\x1f\x20\x03\xd5patch-area", 14);
    write_file("near.patched.bin", near, 0x10010);
    fixups("near", "android", 0x10000, 0x4000, 0, 0);
    char path[256];
    snprintf(path, sizeof path, "%s/near.fixups.tsv", dir);
    CHECK(s2a_module_layout(path, &l, err, sizeof err) == 0 && l.patch_off == 0x10000 && l.key_idx[S2A_KEY_KGATE] == 3);
    CHECK(s2a_module_map(dir, "near", slots, &m, err, sizeof err) == 0);
    if (m.base) {
        CHECK(!memcmp(m.base, near, 0x1000) && !memcmp(m.base + 0x10000, near + 0x10000, 14));
        CHECK(m.patch_size == 0x4000);
        check_key_page(&m);
        perms(m.base, p); CHECK(!strcmp(p, "r-xp"));
        perms(m.base + 0x4000, p); CHECK(!strcmp(p, "r--p"));
        perms(m.base + 0x10000, p); CHECK(!strcmp(p, "r-xp"));
        s2a_module_unmap(&m);
    }

    // Far layout: file = 0x8000-byte image, then a patch area mapped 0x20000 before the base.
    uint8_t *far = calloc(1, 0x8000 + 0x20);
    memset(far, 0xaa, 0x1000);
    memcpy(far + 0x8000, "far-patch", 9);
    write_file("far.patched.bin", far, 0x8000 + 0x20);
    fixups("far", "android", -0x20000, 0xc000, 0x10000, 0x8000);
    CHECK(s2a_module_map(dir, "far", slots, &m, err, sizeof err) == 0);
    if (m.base) {
        CHECK(m.base == m.map + 0x20000 && !memcmp(m.base, far, 0x1000) && !memcmp(m.map, "far-patch", 9));
        CHECK(m.patch_size == 0x4000);
        check_key_page(&m);
        perms(m.map, p); CHECK(!strcmp(p, "r-xp"));
        perms(m.map + 0x4000, p); CHECK(!strcmp(p, "---p"));
        perms(m.base, p); CHECK(!strcmp(p, "r-xp"));
        perms(m.base + 0x8000, p); CHECK(!strcmp(p, "rw-s"));   // bss stays writable
        perms(m.base + 0xc000, p); CHECK(!strcmp(p, "r--p"));
        s2a_module_unmap(&m);
    }

    // Exact image path (A0 validated module list): split <dir>/<name> without scanning a directory.
    snprintf(path, sizeof path, "%s/near.patched.bin", dir);
    CHECK(s2a_module_map_path(path, slots, &m, err, sizeof err) == 0);
    if (m.base) { check_key_page(&m); s2a_module_unmap(&m); }
    snprintf(path, sizeof path, "%s/near.bin", dir);
    CHECK(s2a_module_map_path(path, slots, &m, err, sizeof err) == EINVAL && !m.base);
    // From memory (APK assets): the same bytes give the same mapping; a header from elsewhere is refused.
    char text[1024];
    snprintf(path, sizeof path, "%s/near.fixups.tsv", dir);
    FILE *f = fopen(path, "rb");
    size_t text_len = f ? fread(text, 1, sizeof text, f) : 0;
    if (f) fclose(f);
    CHECK(s2a_module_map_mem("asset near", text, text_len, near, 0x10010, slots, &m, err, sizeof err) == 0);
    if (m.base) {
        CHECK(!memcmp(m.base, near, 0x1000) && !memcmp(m.base + 0x10000, near + 0x10000, 14));
        CHECK(m.patch_size == 0x4000);
        check_key_page(&m);
        perms(m.base, p); CHECK(!strcmp(p, "r-xp"));
        perms(m.base + 0x4000, p); CHECK(!strcmp(p, "r--p"));
        s2a_module_unmap(&m);
    }
    const char *apple_text = "# BUILD_ID\t00\n# PATCH_OFF\t0x10000\n";
    CHECK(s2a_module_map_mem("asset apple", apple_text, strlen(apple_text), near, 0x10010, slots, &m, err, sizeof err) == ENOEXEC
          && strstr(err, "asset apple") && !m.base);
    CHECK(s2a_module_map_mem("asset empty", text, text_len, near, 0, slots, &m, err, sizeof err) == EINVAL);
    // 当前改写合同只能有一份精确目标与 ABI；不能忽略尾部、NUL 或越界 FAR 映像。
    char bad[2048];
    snprintf(bad, sizeof bad, "%.*s# LOAD_BIAS\t1000\n", (int)text_len, text);
    CHECK(s2a_module_layout_mem(bad, strlen(bad), "nonzero bias", &l, err, sizeof err) == ENOEXEC);
    snprintf(bad, sizeof bad, "%.*s# LOAD_BIAS\t0\n", (int)text_len, text);
    CHECK(s2a_module_layout_mem(bad, strlen(bad), "zero bias", &l, err, sizeof err) == 0);
    snprintf(bad, sizeof bad, "%.*s# REWRITE_ABI\tandroid-sp-safe-v1\n", (int)text_len, text);
    CHECK(s2a_module_layout_mem(bad, strlen(bad), "duplicate ABI", &l, err, sizeof err) == ENOEXEC);
    snprintf(bad, sizeof bad, "%.*s# TARGET\tandroid\n", (int)text_len, text);
    CHECK(s2a_module_layout_mem(bad, strlen(bad), "duplicate target", &l, err, sizeof err) == ENOEXEC);
    memcpy(bad, text, text_len); bad[3] = 0;
    CHECK(s2a_module_layout_mem(bad, text_len, "embedded NUL", &l, err, sizeof err) == EINVAL);
    snprintf(bad, sizeof bad, "%.*s0x100\tx18\n", (int)text_len, text);
    CHECK(s2a_module_layout_mem(bad, strlen(bad), "old table rows", &l, err, sizeof err) == EINVAL);
    snprintf(bad, sizeof bad, "%.*s# KEY_K18_IDX\t4294967296\n", (int)text_len, text);
    CHECK(s2a_module_layout_mem(bad, strlen(bad), "huge key", &l, err, sizeof err) == EINVAL);
    snprintf(bad, sizeof bad, "%.*s# PATCH_OFF\t-8000000000000000\n", (int)text_len, text);
    CHECK(s2a_module_layout_mem(bad, strlen(bad), "min signed offset", &l, err, sizeof err) == EINVAL);
    snprintf(bad, sizeof bad, "%.*s# PATCH_OFF\t-20000\n# IMAGE_SIZE\t10000\n# FILE_IMAGE_LEN\t18000\n", (int)text_len, text);
    CHECK(s2a_module_map_mem("FAR image overflow", bad, strlen(bad), near, 0x10010, slots, &m, err, sizeof err) == EINVAL && !m.base);


    // Refusals: Apple output (no TARGET line), another target, a zero slot, a missing key.
    fixups("apple", NULL, 0x10000, 0x4000, 0, 0);
    write_file("apple.patched.bin", near, 0x10010);
    CHECK(s2a_module_map(dir, "apple", slots, &m, err, sizeof err) == ENOEXEC && strstr(err, "apple") && !m.base);
    fixups("ohos", "ohos", 0x10000, 0x4000, 0, 0);
    CHECK(s2a_module_map(dir, "ohos", slots, &m, err, sizeof err) == ENOEXEC && strstr(err, "ohos"));
    const uint64_t zero[S2A_KEY_N] = {0x188, 0, 0x1a8, 0x1b8};
    CHECK(s2a_module_map(dir, "near", zero, &m, err, sizeof err) == EINVAL && strstr(err, "KTLS"));
    const char *nokey = "# TARGET\tandroid\n# REWRITE_ABI\tandroid-sp-safe-v1\n# PATCH_OFF\t0x10000\n# KEY_PAGE_OFF\t0x4000\n# KEY_PAGE_SIZE\t0x4000\n# TEXT_END\t0x1000\n"
               "# KEY_K18_IDX\t0\n# KEY_KTLS_IDX\t1\n# KEY_KTLR_IDX\t2\n";
    write_file("nokey.fixups.tsv", nokey, strlen(nokey));
    snprintf(path, sizeof path, "%s/nokey.fixups.tsv", dir);
    CHECK(s2a_module_layout(path, &l, err, sizeof err) == EINVAL);
    CHECK(s2a_module_map(dir, "missing", slots, &m, err, sizeof err) == ENOENT);

    if (argc == 3) {
        CHECK(s2a_module_map(argv[1], argv[2], slots, &m, err, sizeof err) == 0);
        if (m.base) { check_key_page(&m); perms(m.base + m.l.patch_off, p); CHECK(!strcmp(p, "r-xp")); s2a_module_unmap(&m); }
        else fprintf(stderr, "%s\n", err);
    }

    char cmd[300];
    snprintf(cmd, sizeof cmd, "rm -r '%s'", dir);
    if (system(cmd)) failures++;
    free(near); free(far);
    if (failures) return 1;
    puts("rewritten module mapping: ok");
    return 0;
}
