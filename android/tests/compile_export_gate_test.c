#include "direct/compile_export.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>

static const char *env_value = "0", *export_value = "0";
int __system_property_get(const char *name, char *out) {
    const char *v = !strcmp(name, "debug.s2a.debug_env") ? env_value :
                    !strcmp(name, "debug.s2a.compile_export") ? export_value : "";
    strcpy(out, v);
    return (int)strlen(v);
}
int main(void) {
    assert(!s2a_compile_export_open());
    env_value = "1";
#ifdef S2A_ANDROID_DEBUG_ENV
    assert(s2a_compile_export_open());
#else
    assert(!s2a_compile_export_open());
#endif
    env_value = "0"; export_value = "1"; assert(s2a_compile_export_open());
    export_value = "10"; assert(!s2a_compile_export_open());
    puts("Android export gate matrix passed");
    return 0;
}
