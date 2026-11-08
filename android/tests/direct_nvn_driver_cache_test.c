// 驱动管线缓存文件层回归（宿主/ARM64 同一实现）：
//   * 正常写→读回字节一致、名字带 UUID/版本；
//   * 不同 UUID 互不读取；
//   * 损坏（magic/版本/长度/SHA/短读）一律拒绝；
//   * 覆盖写原子生效；空/超限拒绝。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "nvn/nvn_vk_driver_cache.h"

static int fails;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); fails++; } } while (0)

static void uuid_fill(uint8_t uuid[16], uint8_t seed) { for (int i = 0; i < 16; i++) uuid[i] = (uint8_t)(seed + i * 7); }

static long file_size(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 ? (long)st.st_size : -1;
}

static int write_raw(const char *path, const void *data, size_t bytes) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t n = fwrite(data, 1, bytes, f);
    fclose(f);
    return n == bytes ? 0 : -1;
}

int main(void) {
    const char *tmp = getenv("TMPDIR");
    char dir[512];
    snprintf(dir, sizeof dir, "%s/s2a-driver-cache-XXXXXX", tmp && *tmp ? tmp : "/tmp");
    if (!mkdtemp(dir)) { printf("FAIL: mkdtemp\n"); return 1; }
    uint8_t uuid_a[16], uuid_b[16];
    uuid_fill(uuid_a, 1);
    uuid_fill(uuid_b, 99);

    char name[NVK_DRIVER_CACHE_NAME];
    CHECK(nvk_driver_cache_name(uuid_a, name) == 0, "name");
    CHECK(strstr(name, "-v1.bin") != NULL, "name carries the format version");
    char name_b[NVK_DRIVER_CACHE_NAME];
    CHECK(nvk_driver_cache_name(uuid_b, name_b) == 0 && strcmp(name, name_b) != 0, "different UUIDs have different names");

    uint8_t payload[4096];
    for (size_t i = 0; i < sizeof payload; i++) payload[i] = (uint8_t)(i * 31 + 5);
    char why[160] = "";

    CHECK(nvk_driver_cache_write(dir, uuid_a, payload, sizeof payload, why, sizeof why) == 0, "write");
    void *got = NULL;
    size_t got_bytes = 0;
    CHECK(nvk_driver_cache_read(dir, uuid_a, &got, &got_bytes, why, sizeof why) == 0, "read back");
    CHECK(got && got_bytes == sizeof payload && memcmp(got, payload, sizeof payload) == 0, "payload round-trips");
    free(got);
    got = NULL;
    CHECK(nvk_driver_cache_read(dir, uuid_b, &got, &got_bytes, why, sizeof why) == 1 && !got && !got_bytes,
          "other UUID sees no cache (not an error)");

    // 覆盖写：第二次内容生效。
    uint8_t payload2[300];
    memset(payload2, 0xA5, sizeof payload2);
    CHECK(nvk_driver_cache_write(dir, uuid_a, payload2, sizeof payload2, why, sizeof why) == 0, "overwrite");
    CHECK(nvk_driver_cache_read(dir, uuid_a, &got, &got_bytes, why, sizeof why) == 0, "read overwrite");
    CHECK(got && got_bytes == sizeof payload2 && !memcmp(got, payload2, sizeof payload2), "overwrite content wins");
    free(got);

    // 路径：<dir>/<uuid>-v1.bin，头 48 字节 + 负载。
    char path[600];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    CHECK(file_size(path) == (long)(48 + sizeof payload2), "file layout is 48-byte header + payload");

    // 损坏：改一个负载字节 → SHA 不符。
    uint8_t *raw = (uint8_t *)malloc((size_t)file_size(path));
    FILE *f = fopen(path, "rb");
    size_t raw_bytes = f ? fread(raw, 1, (size_t)file_size(path), f) : 0;
    if (f) fclose(f);
    CHECK(raw_bytes == (size_t)file_size(path), "read raw file");
    raw[raw_bytes - 1] ^= 0xFF;
    CHECK(write_raw(path, raw, raw_bytes) == 0, "write corrupt payload");
    got = NULL;
    CHECK(nvk_driver_cache_read(dir, uuid_a, &got, &got_bytes, why, sizeof why) < 0 && !got, "corrupt payload rejected");

    // 损坏：magic。
    raw[raw_bytes - 1] ^= 0xFF;
    memcpy(raw, "XXXX", 4);
    CHECK(write_raw(path, raw, raw_bytes) == 0, "write bad magic");
    CHECK(nvk_driver_cache_read(dir, uuid_a, &got, &got_bytes, why, sizeof why) < 0, "bad magic rejected");

    // 损坏：版本。
    memcpy(raw, "S2AP", 4);
    raw[4] = 2;
    CHECK(write_raw(path, raw, raw_bytes) == 0, "write bad version");
    CHECK(nvk_driver_cache_read(dir, uuid_a, &got, &got_bytes, why, sizeof why) < 0, "bad version rejected");

    // 损坏：声明的 payload 长度与文件不符。
    raw[4] = 1;
    raw[8] = 0xFF;
    CHECK(write_raw(path, raw, raw_bytes) == 0, "write bad length");
    CHECK(nvk_driver_cache_read(dir, uuid_a, &got, &got_bytes, why, sizeof why) < 0, "bad length rejected");

    // 短文件（只剩头）。
    CHECK(write_raw(path, raw, 48) == 0, "write short file");
    CHECK(nvk_driver_cache_read(dir, uuid_a, &got, &got_bytes, why, sizeof why) < 0, "short file rejected");

    // 空/超限写拒绝。
    CHECK(nvk_driver_cache_write(dir, uuid_a, payload, 0, why, sizeof why) < 0, "empty cache rejected");
    CHECK(nvk_driver_cache_write(dir, uuid_a, payload, NVK_DRIVER_CACHE_MAX + 1u, why, sizeof why) < 0, "oversized cache rejected");

    free(raw);
    unlink(path);
    rmdir(dir);
    if (fails) { printf("driver cache test: %d FAILED\n", fails); return 1; }
    printf("driver cache test: ok (round-trip, isolation, corruption, atomic overwrite)\n");
    return 0;
}
