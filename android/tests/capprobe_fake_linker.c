/* capprobe_fake_linker.c — stand-in for /system/bin/linker64 in host
 * tests (capprobe_spawn_test.c). Bionic's linker runs an executable given
 * as its first argument, including "<apk>!/<entry>" zip paths; this fake
 * mirrors just enough of that contract:
 *   1. appends its argv, one item per line, to CAPPROBE_LINKER_LOG so the
 *      test can assert the launch contract (exec target = the linker,
 *      argv[1] = the "<apk>!/lib/..." in-APK spec);
 *   2. resolves "<archive>!/<entry>" to "<archive>/<entry>" — the test
 *      lays out a directory standing in for the APK — and execs it with
 *      argv[1..] passed through, like the real linker (the loaded
 *      program's argv[0] is the spec). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *log = getenv("CAPPROBE_LINKER_LOG");
    if (log && *log) {
        FILE *f = fopen(log, "a");
        if (f) {
            for (int i = 0; i < argc; i++)
                fprintf(f, "argv[%d]=%s\n", i, argv[i]);
            fclose(f);
        }
    }
    if (argc < 2) return 64;
    const char *spec = argv[1];
    char resolved[4096];
    const char *bang = strstr(spec, "!/");
    if (bang)
        snprintf(resolved, sizeof resolved, "%.*s/%s",
                 (int)(bang - spec), spec, bang + 2);
    else
        snprintf(resolved, sizeof resolved, "%s", spec);
    /* The loaded program's argv is the spec plus the helper arguments —
     * the same shape the real linker produces. */
    char **inner = calloc((size_t)argc, sizeof(char *));
    if (!inner) return 127;
    for (int i = 1; i < argc; i++) inner[i - 1] = argv[i];
    inner[argc - 1] = NULL;
    execv(resolved, inner);
    return 127;
}
