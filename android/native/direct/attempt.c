// direct attempt / failure 持久锁实现，见 attempt.h。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "attempt.h"

#include "json.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static int hex_lower_64(const char *text) {
    if (!text || strlen(text) != 64) return 0;
    for (int i = 0; i < 64; i++)
        if (!((text[i] >= '0' && text[i] <= '9') || (text[i] >= 'a' && text[i] <= 'f'))) return 0;
    return 1;
}

static int hex_lower_32(const char *text) {
    if (!text || strlen(text) != 32) return 0;
    for (int i = 0; i < 32; i++)
        if (!((text[i] >= '0' && text[i] <= '9') || (text[i] >= 'a' && text[i] <= 'f'))) return 0;
    return 1;
}

static int safe_text(const char *text, size_t max) {
    if (!text) return 0;
    size_t n = strlen(text);
    if (n >= max) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)text[i];
        if (c < 0x20 && c != '\t') return 0;
        if (c == 0x7f) return 0;
        if (c == '"' || c == '\\') return 0;
    }
    return 1;
}

int s2a_direct_attempt_path(const char *state_dir, const char *implementation_key,
                            const char *name, char *out, size_t capacity) {
    if (!state_dir || state_dir[0] != '/' || !hex_lower_64(implementation_key) ||
        !name || !out || !capacity) return S2A_ATTEMPT_ARGUMENT;
    if (strchr(name, '/') || strchr(name, '\\') || !strcmp(name, ".") || !strcmp(name, ".."))
        return S2A_ATTEMPT_ARGUMENT;
    int n = snprintf(out, capacity, "%s/graphics/direct/%s/%s", state_dir, implementation_key, name);
    if (n < 0 || (size_t)n >= capacity || (size_t)n >= S2A_ATTEMPT_DIR_MAX)
        return S2A_ATTEMPT_LIMIT;
    return S2A_ATTEMPT_OK;
}

#ifdef S2A_DIRECT_TEST_FAULTS
// 仅测试编译：0 无故障；1 写文件；2 fsync(file)；3 rename；4 fsync(dir)；5 mkdir；
// 6/7 在 fsync_path 内注入 EINVAL/EIO，覆盖真实的同步结果判定，不在调用前短路。
static int g_fault = -1;
void s2a_direct_attempt_fault(int point) { g_fault = point; }
#define FAULT(point) (g_fault == (point))
#else
#define FAULT(point) 0
#endif

static int fsync_path(const char *path, int dir) {
    int flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW;
#ifdef O_DIRECTORY
    if (dir) flags |= O_DIRECTORY;
#endif
    int fd = open(path, flags);
    if (fd < 0) return S2A_ATTEMPT_IO;
    int rc;
    if (FAULT(6) || FAULT(7)) {
        errno = FAULT(6) ? EINVAL : EIO;
        rc = -1;
    } else {
        rc = fsync(fd);
    }
    close(fd);
    return rc ? S2A_ATTEMPT_IO : S2A_ATTEMPT_OK;
}

static int write_atomic(const char *dir_path, const char *name, const char *text) {
    char path[S2A_ATTEMPT_DIR_MAX + 64], temp[S2A_ATTEMPT_DIR_MAX + 96];
    int n = snprintf(path, sizeof path, "%s/%s", dir_path, name);
    if (n < 0 || (size_t)n >= sizeof path) return S2A_ATTEMPT_LIMIT;
    n = snprintf(temp, sizeof temp, "%s.tmp.%ld", path, (long)getpid());
    if (n < 0 || (size_t)n >= sizeof temp) return S2A_ATTEMPT_LIMIT;
    if (FAULT(1)) return S2A_ATTEMPT_IO;
    int fd = open(temp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return S2A_ATTEMPT_IO;
    size_t bytes = strlen(text), done = 0;
    while (done < bytes) {
        ssize_t w = write(fd, text + done, bytes - done);
        if (w <= 0) { close(fd); unlink(temp); return S2A_ATTEMPT_IO; }
        done += (size_t)w;
    }
    if (FAULT(2) || fsync(fd)) { close(fd); unlink(temp); return S2A_ATTEMPT_IO; }
    if (close(fd)) { unlink(temp); return S2A_ATTEMPT_IO; }
    if (FAULT(3) || rename(temp, path)) { unlink(temp); return S2A_ATTEMPT_IO; }
    if (FAULT(4) || fsync_path(dir_path, 1)) return S2A_ATTEMPT_IO;
    return S2A_ATTEMPT_OK;
}

// 最近一次 IO 失败原因的 errno：锁写失败时给上层一个可定位的数字，而不是只有 "unavailable"。
static int g_last_errno;
int s2a_direct_attempt_last_errno(void) { return g_last_errno; }
static int io_fail(int err) { g_last_errno = err ? err : EIO; return S2A_ATTEMPT_IO; }
// 失败时把具体路径打到 stderr（Android 上会进会话日志）；只在出错时输出，不刷屏。
static int io_fail_path(const char *path, int err) {
    fprintf(stderr, "[s2a] direct attempt dir failed: %s (errno=%d)\n", path ? path : "(null)", err);
    return io_fail(err);
}

// 逐级确保目录存在（包含 state_dir 自己缺失的情况）。
// 用 stat 而不是 lstat：Android 的 /data/user/0 这类系统前缀对 App 是链接/受保护视图，
// lstat 会把它当"不是目录"直接判 ENOTDIR（设备上实测 -2 errno=20）；外壳已保证
// 玩家数据路径本身不含链接（GameSession.prepareState），这里只拒绝"存在但不是目录"。
static int ensure_dir(const char *state_dir, const char *key, char *dir_path, size_t cap) {
    int n = snprintf(dir_path, cap, "%s/graphics/direct/%s", state_dir, key);
    if (n < 0 || (size_t)n >= cap) return S2A_ATTEMPT_LIMIT;
    char partial[S2A_ATTEMPT_DIR_MAX];
    size_t length = strlen(dir_path);
    if (length >= sizeof partial) return S2A_ATTEMPT_LIMIT;
    memcpy(partial, dir_path, length + 1);
    struct stat st;
    for (char *p = partial + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        if (stat(partial, &st)) {
            int stat_err = errno;
            if (stat_err != ENOENT) return io_fail_path(partial, stat_err);
            if (FAULT(5)) return io_fail(EIO);
            if (mkdir(partial, 0700)) return io_fail(errno);
            if (chmod(partial, 0700)) return io_fail(errno);
        } else if (!S_ISDIR(st.st_mode)) return io_fail_path(partial, ENOTDIR);
        *p = '/';
    }
    if (stat(dir_path, &st)) {
        int stat_err = errno;
        if (stat_err != ENOENT) return io_fail_path(dir_path, stat_err);
        if (FAULT(5)) return io_fail(EIO);
        if (mkdir(dir_path, 0700)) return io_fail(errno);
        if (chmod(dir_path, 0700)) return io_fail(errno);
    } else if (!S_ISDIR(st.st_mode)) return io_fail_path(dir_path, ENOTDIR);
    g_last_errno = 0;
    return S2A_ATTEMPT_OK;
}

static const char *phase_text(uint32_t phase) {
    switch (phase) {
    case S2A_ATTEMPT_PREPARED: return "prepared";
    case S2A_ATTEMPT_COMMITTED: return "committed";
    case S2A_ATTEMPT_ACTIVE: return "active";
    case S2A_ATTEMPT_STOPPING: return "stopping";
    default: return NULL;
    }
}

static int phase_value(const char *text, uint32_t *out) {
    for (uint32_t p = 0; p <= S2A_ATTEMPT_STOPPING; p++)
        if (!strcmp(text, phase_text(p))) { *out = p; return 0; }
    return -1;
}

static int json_escape(const char *in, char *out, size_t cap) {
    size_t used = 0;
    for (; *in; in++) {
        unsigned char c = (unsigned char)*in;
        if (c == '"' || c == '\\') {
            if (used + 2 >= cap) return -1;
            out[used++] = '\\'; out[used++] = (char)c;
        } else if (c < 0x20) {
            if (used + 6 >= cap) return -1;
            int n = snprintf(out + used, cap - used, "\\u%04x", c);
            if (n != 6) return -1;
            used += (size_t)n;
        } else {
            if (used + 1 >= cap) return -1;
            out[used++] = (char)c;
        }
    }
    out[used] = 0;
    return 0;
}

static int state_ok(const char *state_dir) {
    return state_dir && state_dir[0] == '/' && strlen(state_dir) < S2A_ATTEMPT_DIR_MAX - 300;
}

int s2a_direct_attempt_write(const char *state_dir, const struct s2a_direct_attempt_v1 *attempt) {
    if (!state_ok(state_dir) || !attempt || !hex_lower_32(attempt->attempt_id) || !hex_lower_64(attempt->implementation_key) ||
        !attempt->session || !phase_text(attempt->phase) || !safe_text(attempt->reason, sizeof attempt->reason))
        return S2A_ATTEMPT_ARGUMENT;
    char dir[S2A_ATTEMPT_DIR_MAX], reason[320];
    int rc = ensure_dir(state_dir, attempt->implementation_key, dir, sizeof dir);
    if (rc) return rc;
    if (json_escape(attempt->reason, reason, sizeof reason)) return S2A_ATTEMPT_LIMIT;
    char text[1024];
    int n = snprintf(text, sizeof text,
        "{\"schema\":\"%s\",\"attemptId\":\"%s\",\"session\":%llu,\"implementationKey\":\"%s\","
        "\"phase\":\"%s\",\"reason\":\"%s\"}\n",
        S2A_ATTEMPT_SCHEMA, attempt->attempt_id, (unsigned long long)attempt->session,
        attempt->implementation_key, phase_text(attempt->phase), reason);
    if (n < 0 || (size_t)n >= sizeof text) return S2A_ATTEMPT_LIMIT;
    return write_atomic(dir, "attempt.json", text);
}

int s2a_direct_failure_write(const char *state_dir, const struct s2a_direct_failure_v1 *failure) {
    if (!state_ok(state_dir) || !failure || !hex_lower_32(failure->attempt_id) || !hex_lower_64(failure->implementation_key) ||
        !failure->session || !phase_text(failure->phase) || failure->error >= 0 ||
        !safe_text(failure->reason, sizeof failure->reason)) return S2A_ATTEMPT_ARGUMENT;
    char dir[S2A_ATTEMPT_DIR_MAX], reason[400];
    int rc = ensure_dir(state_dir, failure->implementation_key, dir, sizeof dir);
    if (rc) return rc;
    if (json_escape(failure->reason, reason, sizeof reason)) return S2A_ATTEMPT_LIMIT;
    char text[1280];
    int n = snprintf(text, sizeof text,
        "{\"schema\":\"%s\",\"attemptId\":\"%s\",\"session\":%llu,\"implementationKey\":\"%s\","
        "\"phase\":\"%s\",\"error\":%d,\"reason\":\"%s\"}\n",
        S2A_FAILURE_SCHEMA, failure->attempt_id, (unsigned long long)failure->session,
        failure->implementation_key, phase_text(failure->phase), failure->error, reason);
    if (n < 0 || (size_t)n >= sizeof text) return S2A_ATTEMPT_LIMIT;
    return write_atomic(dir, "failure.json", text);
}

static int read_json(const char *state_dir, const char *key, const char *name,
                     s2a_json_object *object, char *err, size_t err_size) {
    char path[S2A_ATTEMPT_DIR_MAX + 64];
    int rc = s2a_direct_attempt_path(state_dir, key, name, path, sizeof path);
    if (rc) return rc;
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return errno == ENOENT ? S2A_ATTEMPT_NOT_FOUND : S2A_ATTEMPT_IO;
    uint8_t buffer[4096];
    ssize_t bytes = read(fd, buffer, sizeof buffer);
    int extra = bytes == (ssize_t)sizeof buffer;
    close(fd);
    if (bytes < 0) return S2A_ATTEMPT_IO;
    if (extra) return S2A_ATTEMPT_LIMIT;
    if (s2a_json_parse_object(buffer, (size_t)bytes, object, err, err_size)) return S2A_ATTEMPT_CORRUPT;
    return S2A_ATTEMPT_OK;
}

static int field_string(const s2a_json_object *object, const char *key, char *out, size_t cap) {
    const s2a_json_field *f = s2a_json_get(object, key);
    if (!f || f->kind != S2A_JSON_STRING || f->text_bytes >= cap) return -1;
    memcpy(out, f->text, f->text_bytes + 1);
    return 0;
}

int s2a_direct_attempt_read(const char *state_dir, const char *implementation_key,
                            struct s2a_direct_attempt_v1 *out) {
    if (!state_ok(state_dir) || !out || !hex_lower_64(implementation_key)) return S2A_ATTEMPT_ARGUMENT;
    s2a_json_object object;
    char err[96];
    int rc = read_json(state_dir, implementation_key, "attempt.json", &object, err, sizeof err);
    if (rc) return rc;
    memset(out, 0, sizeof *out);
    char schema[32];
    const s2a_json_field *session = s2a_json_get(&object, "session");
    if (field_string(&object, "schema", schema, sizeof schema) || strcmp(schema, S2A_ATTEMPT_SCHEMA) ||
        field_string(&object, "attemptId", out->attempt_id, sizeof out->attempt_id) ||
        !hex_lower_32(out->attempt_id) ||
        field_string(&object, "implementationKey", out->implementation_key, sizeof out->implementation_key) ||
        strcmp(out->implementation_key, implementation_key) ||
        !session || session->kind != S2A_JSON_NUMBER || !session->is_unsigned || !session->unsigned_value ||
        field_string(&object, "phase", schema, sizeof schema) || phase_value(schema, &out->phase) ||
        field_string(&object, "reason", out->reason, sizeof out->reason))
        return S2A_ATTEMPT_CORRUPT;
    out->session = session->unsigned_value;
    return S2A_ATTEMPT_OK;
}

int s2a_direct_attempt_pending(const char *state_dir, const char *implementation_key) {
    if (!state_ok(state_dir) || !hex_lower_64(implementation_key)) return 0;
    char path[S2A_ATTEMPT_DIR_MAX + 64];
    if (s2a_direct_attempt_path(state_dir, implementation_key, "attempt.json", path, sizeof path)) return 0;
    struct stat st;
    if (!lstat(path, &st) && S_ISREG(st.st_mode)) return 1;
    if (s2a_direct_attempt_path(state_dir, implementation_key, "failure.json", path, sizeof path)) return 0;
    return !lstat(path, &st) && S_ISREG(st.st_mode) ? 1 : 0;
}

int s2a_direct_attempt_clear(const char *state_dir, const char *implementation_key) {
    if (!state_ok(state_dir) || !hex_lower_64(implementation_key)) return S2A_ATTEMPT_ARGUMENT;
    char path[S2A_ATTEMPT_DIR_MAX + 64];
    int rc = s2a_direct_attempt_path(state_dir, implementation_key, "failure.json", path, sizeof path);
    if (rc) return rc;
    if (unlink(path) && errno != ENOENT) return S2A_ATTEMPT_IO;
    rc = s2a_direct_attempt_path(state_dir, implementation_key, "attempt.json", path, sizeof path);
    if (rc) return rc;
    if (unlink(path) && errno != ENOENT) return S2A_ATTEMPT_IO;
    char dir[S2A_ATTEMPT_DIR_MAX];
    int n = snprintf(dir, sizeof dir, "%s/graphics/direct/%s", state_dir, implementation_key);
    if (n < 0 || (size_t)n >= sizeof dir) return S2A_ATTEMPT_LIMIT;
    return fsync_path(dir, 1);
}
