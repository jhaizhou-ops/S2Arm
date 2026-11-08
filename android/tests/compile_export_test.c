#define _POSIX_C_SOURCE 200809L
#include "direct/compile_export.h"
#include <assert.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static int publish(const char *root, const char *id, const unsigned char sha[32], const char *body) {
    return s2a_compile_export_request(root, 11, 12, 1, 1, "closure", "profile", id, sha, body, strlen(body));
}
int main(int argc, char **argv) {
    assert(argc == 2);
    assert(!s2a_compile_export_allowed(0, 0));
    assert(s2a_compile_export_allowed(1, 0));
    assert(s2a_compile_export_allowed(0, 1));
    char selected[256];
    assert(!s2a_compile_export_directory(0, "/private/state", "/external/diag", selected, sizeof selected));
    assert(!strcmp(selected, "/private/state/direct-diagnostics"));
    assert(!s2a_compile_export_directory(1, "/private/state", "/external/diag", selected, sizeof selected));
    assert(!strcmp(selected, "/external/diag"));
    assert(s2a_compile_export_directory(0, "relative", "/external/diag", selected, sizeof selected));
    assert(s2a_compile_export_directory(0, "/private/state", "/external/diag", selected, 3));
    assert(!setenv("S2A_DIRECT_DIAG_DIR", "/stale", 1));
    assert(!s2a_compile_export_configure(0, 0, "/private/state", "/external/diag"));
    assert(!getenv("S2A_DIRECT_DIAG_DIR"));
    assert(!s2a_compile_export_configure(1, 0, "/private/state", "/external/diag"));
    assert(!strcmp(getenv("S2A_DIRECT_DIAG_DIR"), "/private/state/direct-diagnostics"));
    assert(!s2a_compile_export_configure(1, 1, "/private/state", "/external/diag"));
    assert(!strcmp(getenv("S2A_DIRECT_DIAG_DIR"), "/external/diag"));
    assert(s2a_compile_export_configure(1, 0, "relative", "/external/diag"));
    assert(!getenv("S2A_DIRECT_DIAG_DIR"));
    const char *root = argv[1];
    unsigned char sha[32] = {1};
    pid_t children[12];
    for (int i = 0; i < 12; i++) {
        children[i] = fork(); assert(children[i] >= 0);
        if (!children[i]) { char id[32]; snprintf(id, sizeof id, "request-%d", i); _exit(publish(root, id, sha, "first") ? 1 : 0); }
    }
    for (int i = 0; i < 12; i++) { int status; assert(waitpid(children[i], &status, 0) > 0); assert(WIFEXITED(status) && WEXITSTATUS(status) == 0); }
    DIR *outer = opendir(root); assert(outer);
    struct dirent *e; char path[1024] = {0};
    while ((e = readdir(outer))) if (!strncmp(e->d_name, "requests-", 9)) snprintf(path, sizeof path, "%s/%s", root, e->d_name);
    closedir(outer); assert(*path);
    DIR *inner = opendir(path); assert(inner);
    int count = 0; char published[1300] = {0};
    while ((e = readdir(inner))) if (strstr(e->d_name, ".compile-request.json")) { count++; snprintf(published, sizeof published, "%s/%s", path, e->d_name); }
    closedir(inner); assert(count == 1);
    struct stat before, after; assert(!stat(published, &before));
    assert(!publish(root, "different-request", sha, "second"));
    assert(!stat(published, &after)); assert(before.st_mtime == after.st_mtime && before.st_size == after.st_size);
    FILE *f = fopen(published, "rb"); assert(f); char data[16] = {0}; assert(fread(data, 1, 5, f) == 5); fclose(f); assert(!strcmp(data, "first"));
    sha[0] = 2; assert(!publish(root, "other", sha, "third"));
    assert(publish(root, "../invalid", sha, "bad") != 0);
    // Sparse file consumes the configured logical byte budget without consuming 256 MiB of disk.
    char budget[1300]; snprintf(budget, sizeof budget, "%s/budget.tmp", path);
    int fd = open(budget, O_CREAT | O_EXCL | O_WRONLY, 0600); assert(fd >= 0);
    assert(!ftruncate(fd, 256LL << 20)); assert(!close(fd));
    sha[0] = 3; assert(publish(root, "over-budget", sha, "fourth") != 0);
    assert(!unlink(budget)); assert(!publish(root, "retry-after-budget", sha, "fourth"));
    // Three published files exist; 4093 small artifacts fill the per-set file budget.
    char limit_file[1300];
    for (int i = 0; i < 4093; i++) {
        snprintf(limit_file, sizeof limit_file, "%s/limit-%04d.tmp", path, i);
        int limit_fd = open(limit_file, O_CREAT | O_EXCL | O_WRONLY, 0600); assert(limit_fd >= 0); assert(!close(limit_fd));
    }
    sha[0] = 4; assert(publish(root, "over-file-budget", sha, "fifth") != 0);
    assert(!unlink(limit_file)); assert(!publish(root, "retry-file-budget", sha, "fifth"));

    assert(!s2a_compile_export_request(root, 11, 12, 1, 1, "other-closure", "profile", "cohort", sha, "x", 1));
    assert(!s2a_compile_export_request(root, 11, 13, 1, 1, "closure", "profile", "session", sha, "x", 1));
    assert(!s2a_compile_export_request(root, 11, 12, 1, 1, "closure", "other-profile", "profile", sha, "x", 1));
    outer = opendir(root); assert(outer); int sets = 0;
    while ((e = readdir(outer))) if (!strncmp(e->d_name, "requests-", 9)) sets++;
    closedir(outer); assert(sets == 4);
    puts("compile export: policy, concurrent identity dedupe, first bytes, distinct identity, invalid name passed");
    return 0;
}
