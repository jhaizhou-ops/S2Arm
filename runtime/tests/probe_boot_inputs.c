// Compile the real loader in this translation unit to reach its private input
// readers. No provider, clock, allocator or file API is replaced. Existing
// directories cause real fstat/read and stdio errors; no module data is made up.
#include "../src/loader.c"

int s2a_session_try_boot(void (*)(void *), void *);
struct module_case { const char *directory; const char **names; int count; };
static void load_existing_modules(void *arg) {
    struct module_case *input = arg;
    load_modules(input->directory, input->names, input->count);
}
struct input_case { const char *directory; int table; };
static void read_directory(void *arg) {
    struct input_case *input = arg;
    if (input->table) {
        module_t module = {0};
        strlcpy(module.name, "input", sizeof module.name);
        read_layout(&module, input->directory);
    } else {
        size_t length;
        uint8_t *raw = slurp(input->directory, &length);
        free(raw);
    }
}
int main(int argc, char **argv) {
    // Put the real module directory first, as the production constructor reads
    // its NPDM before main. Never replace the required address-window guard.
    if (argc >= 4 && !strcmp(argv[2], "modules")) {
        if (!s2a_window_ok()) return 2;
        struct module_case input = {argv[1], (const char **)&argv[3], argc - 3};
        int before, after; uint64_t soft, hard;
        s2a_fd_usage(&before, &soft, &hard);
        int result = s2a_session_try_boot(load_existing_modules, &input);
        s2a_fd_usage(&after, &soft, &hard);
        printf("existing modules: boot result=%d, loaded=%d, open fds before=%d after=%d; no guest/services/GPU\n", result, g_nmod, before, after);
        return result || g_nmod != input.count || before != after;
    }
    if (argc != 3 || (strcmp(argv[1], "raw") && strcmp(argv[1], "table"))) return 2;
    char *existing = realpath(argv[2], NULL);
    struct stat info;
    if (!existing || stat(existing, &info) || !S_ISDIR(info.st_mode)) return 2;
    char temporary[] = "/tmp/s2a-boot-inputs-XXXXXX", link[1024];
    struct input_case input = {.directory = existing, .table = !strcmp(argv[1], "table")};
    if (input.table) {
        if (!mkdtemp(temporary)) return 2;
        snprintf(link, sizeof link, "%s/input.fixups.tsv", temporary);
        if (symlink(existing, link)) { rmdir(temporary); free(existing); return 2; }
        input.directory = temporary;
    }
    int before, after; uint64_t soft, hard;
    s2a_fd_usage(&before, &soft, &hard);
    int result = s2a_session_try_boot(read_directory, &input);
    s2a_fd_usage(&after, &soft, &hard);
    if (input.table) { unlink(link); rmdir(temporary); }
    free(existing);
    printf("%s input: real boot result=%d, open fds before=%d after=%d\n", argv[1], result, before, after);
    // No guest, service or mapping was started. This checks only the actual
    // input descriptor after returning from the production fatal boundary.
    return result != -1 || before != after;
}
