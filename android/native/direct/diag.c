#include "diag.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "sha256.h"

#define DIAG_NAME_MAX 200
#define DIAG_MANIFEST_MAX_FILES 8192

static void setwhy(char *why, size_t n, const char *text) { if (why && n) snprintf(why, n, "%s", text); }

static char g_diag_root[4096];

int s2a_direct_diag_set_dir(const char *dir) {
    if (!dir || dir[0] != '/') return EINVAL;
    if (strlen(dir) + sizeof "/direct-diagnostics" > sizeof g_diag_root) return ENAMETOOLONG;
    snprintf(g_diag_root, sizeof g_diag_root, "%s", dir);
    return 0;
}

int s2a_direct_diag_dir(const char *state_dir, char *out, size_t out_size, char *why, size_t why_size) {
    if (!out || out_size == 0) { setwhy(why, why_size, "diag: no output buffer"); return -1; }
    out[0] = 0;
    const char *root = g_diag_root[0] ? g_diag_root : state_dir;
    if (!root || !root[0]) { setwhy(why, why_size, "diag: session state directory is missing"); return -1; }
    if (root[0] != '/') { setwhy(why, why_size, "diag: session state directory is not absolute"); return -1; }
    size_t len = strlen(root);
    if (len > out_size - 32) { setwhy(why, why_size, "diag: session state directory is too long"); return -1; }
    int n = snprintf(out, out_size, "%s%sdirect-diagnostics", root,
                     root[len - 1] == '/' ? "" : "/");
    if (n < 0 || (size_t)n >= out_size) {
        out[0] = 0;
        setwhy(why, why_size, "diag: diagnostics path is too long");
        return -1;
    }
    return 0;
}

static int safe_name(const char *name) {
    if (!name || !name[0]) return 0;
    size_t len = strlen(name);
    if (len >= DIAG_NAME_MAX) return 0;
    if (!strcmp(name, ".") || !strcmp(name, "..")) return 0;
    for (const char *p = name; *p; p++)
        if (*p == '/' || *p == '\\') return 0;
    return 1;
}

static int ensure_dir(const char *dir, char *why, size_t why_size) {
    if (!dir || !dir[0]) { setwhy(why, why_size, "diag: no diagnostics directory"); return -1; }
    if (mkdir(dir, 0700) == 0) return 0;
    if (errno == EEXIST) {
        struct stat st;
        if (stat(dir, &st) == 0 && S_ISDIR(st.st_mode)) return 0;
        setwhy(why, why_size, "diag: diagnostics path exists but is not a directory");
        return -1;
    }
    char msg[192];
    snprintf(msg, sizeof msg, "diag: creating the diagnostics directory failed (errno=%d)", errno);
    setwhy(why, why_size, msg);
    return -1;
}

int s2a_direct_diag_write(const char *dir, const char *name, const void *data, size_t len,
                          char *why, size_t why_size) {
    if (!safe_name(name)) { setwhy(why, why_size, "diag: unsafe diagnostic file name"); return -1; }
    if (!data && len) { setwhy(why, why_size, "diag: no diagnostic data"); return -1; }
    if (ensure_dir(dir, why, why_size)) return -1;
    char path[1200];
    int n = snprintf(path, sizeof path, "%s/%s", dir, name);
    if (n < 0 || (size_t)n >= sizeof path) { setwhy(why, why_size, "diag: diagnostic path is too long"); return -1; }
    FILE *f = fopen(path, "wb");
    if (!f) {
        char msg[192];
        snprintf(msg, sizeof msg, "diag: opening the diagnostic file failed (errno=%d)", errno);
        setwhy(why, why_size, msg);
        return -1;
    }
    size_t wrote = len ? fwrite(data, 1, len, f) : 0;
    int bad = wrote != len || fflush(f) != 0;
    if (fclose(f) != 0) bad = 1;
    if (bad) { setwhy(why, why_size, "diag: writing the diagnostic file failed"); return -1; }
    return 0;
}

static int name_cmp(const void *a, const void *b) { return strcmp(*(const char *const *)a, *(const char *const *)b); }

static int file_sha(const char *path, uint8_t out[32], uint64_t *size, char *why, size_t why_size) {
    FILE *f = fopen(path, "rb");
    if (!f) { setwhy(why, why_size, "diag manifest: opening a file failed"); return -1; }
    s2a_sha256 ctx;
    s2a_sha256_init(&ctx);
    uint8_t buf[1 << 16];
    uint64_t total = 0;
    int bad = 0;
    for (;;) {
        size_t got = fread(buf, 1, sizeof buf, f);
        if (got) { s2a_sha256_update(&ctx, buf, got); total += got; }
        if (got < sizeof buf) { if (ferror(f)) bad = 1; break; }
    }
    fclose(f);
    if (bad) { setwhy(why, why_size, "diag manifest: reading a file failed"); return -1; }
    s2a_sha256_final(&ctx, out);
    if (size) *size = total;
    return 0;
}

int s2a_direct_diag_manifest(const char *dir, char *digest_hex, size_t digest_size,
                             uint32_t *files, uint64_t *bytes, char *why, size_t why_size) {
    if (!digest_hex || digest_size < 65) { setwhy(why, why_size, "diag manifest: digest buffer too small"); return -1; }
    digest_hex[0] = 0;
    if (files) *files = 0;
    if (bytes) *bytes = 0;
    if (!dir || !dir[0]) { setwhy(why, why_size, "diag manifest: no directory"); return -1; }

    DIR *d = opendir(dir);
    if (!d) {
        char msg[192];
        snprintf(msg, sizeof msg, "diag manifest: opening the directory failed (errno=%d)", errno);
        setwhy(why, why_size, msg);
        return -1;
    }
    char **names = NULL;
    size_t count = 0, cap = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (count == DIAG_MANIFEST_MAX_FILES) {
            closedir(d);
            for (size_t i = 0; i < count; i++) free(names[i]);
            free(names);
            setwhy(why, why_size, "diag manifest: too many files");
            return -1;
        }
        if (count == cap) {
            size_t next = cap ? cap * 2 : 64;
            char **grown = (char **)realloc(names, next * sizeof *names);
            if (!grown) {
                closedir(d);
                for (size_t i = 0; i < count; i++) free(names[i]);
                free(names);
                setwhy(why, why_size, "diag manifest: out of memory");
                return -1;
            }
            names = grown;
            cap = next;
        }
        size_t len = strlen(e->d_name);
        names[count] = (char *)malloc(len + 1);
        if (!names[count]) {
            closedir(d);
            for (size_t i = 0; i < count; i++) free(names[i]);
            free(names);
            setwhy(why, why_size, "diag manifest: out of memory");
            return -1;
        }
        memcpy(names[count], e->d_name, len + 1);
        count++;
    }
    closedir(d);
    qsort(names, count, sizeof *names, name_cmp);

    s2a_sha256 ctx;
    s2a_sha256_init(&ctx);
    uint32_t nfiles = 0;
    uint64_t nbytes = 0;
    int rc = 0;
    char path[1400];
    for (size_t i = 0; i < count; i++) {
        int n = snprintf(path, sizeof path, "%s/%s", dir, names[i]);
        if (n < 0 || (size_t)n >= sizeof path) { rc = -1; setwhy(why, why_size, "diag manifest: path is too long"); break; }
        struct stat st;
        if (stat(path, &st) != 0) { rc = -1; setwhy(why, why_size, "diag manifest: stat failed"); break; }
        if (!S_ISREG(st.st_mode)) continue;   // 只对普通文件取身份；子目录不属于 revision 文件清单
        uint8_t digest[32];
        uint64_t size = 0;
        if (file_sha(path, digest, &size, why, why_size)) { rc = -1; break; }
        char hex[65];
        s2a_sha256_hex(digest, hex);
        char line[512];
        int ln = snprintf(line, sizeof line, "%s\t%llu\t%s\n", names[i], (unsigned long long)size, hex);
        if (ln < 0 || (size_t)ln >= sizeof line) { rc = -1; setwhy(why, why_size, "diag manifest: entry is too long"); break; }
        s2a_sha256_update(&ctx, line, (size_t)ln);
        nfiles++;
        nbytes += size;
    }
    for (size_t i = 0; i < count; i++) free(names[i]);
    free(names);
    if (rc) return -1;
    uint8_t final[32];
    s2a_sha256_final(&ctx, final);
    s2a_sha256_hex(final, digest_hex);
    if (files) *files = nfiles;
    if (bytes) *bytes = nbytes;
    return 0;
}
