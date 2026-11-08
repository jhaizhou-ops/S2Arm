// Controlled Android asset boundary only. Production mounting/translation stays real.
#include <stdint.h>
static int64_t result = -2; // ENOENT: deliberately absent synthetic asset.
void s2a_test_asset_result(int64_t value) { result = value; }
int64_t s2a_android_copy_asset(const char *name, const char *path) {
    (void)name; (void)path;
    return result;
}
