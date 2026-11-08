// Vulkan 款直连的冷启动选择（#274）：见 direct_choice.h。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "direct_choice.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define DESCRIPTOR "direct-vulkan.txt"
#define FAIL_FILE "vulkan-direct.fail"
#define ATTEMPT_FILE "vulkan-direct.attempt"

static int join(char *out, size_t size, const char *dir, const char *name) {
    return snprintf(out, size, "%s/%s", dir, name) >= (int)size ? ENAMETOOLONG : 0;
}

int s2a_vk_descriptor_read(const char *game_dir, unsigned *skipped) {
    char path[4096], line[64];
    if (!game_dir || !*game_dir) return EINVAL;
    if (join(path, sizeof path, game_dir, DESCRIPTOR)) return ENAMETOOLONG;
    // direct-vulkan.txt 是“Vulkan 客体直连”的资格与模块合同，不是可选的减项开关：没有它就没有依据
    // 说明本包属于该前端。手动直连据此准确失败（报红），AUTO 据此回通用。
    FILE *f = fopen(path, "r");
    if (!f) return errno ? errno : ENOENT;
    unsigned mask = 0;
    int valid = fgets(line, sizeof line, f) && !strcmp(line, "S2ARM_VULKAN_DIRECT_V1\n");
    while (valid && fgets(line, sizeof line, f)) {
        size_t length = strlen(line);
        if (length != 8 || strncmp(line, "subsdk", 6) || line[6] < '0' || line[6] > '9' || line[7] != '\n') { valid = 0; break; }
        unsigned bit = 1u << (line[6] - '0');
        if (mask & bit) { valid = 0; break; }
        mask |= bit;
    }
    int read_error = ferror(f);
    fclose(f);
    if (read_error) return EIO;
    if (!valid) return EINVAL;
    if (skipped) *skipped = mask;
    return 0;
}

// Android 侧的就绪判定（direct_vk.h）：本包有有效描述即就绪；AUTO 另看上局状态（s2a_vk_auto_resolve）
int s2a_vk_lib_ready(const char *game_data) { return s2a_vk_descriptor_read(game_data, NULL) == 0; }

static void say(char *why, size_t size, const char *text) { if (why && size) snprintf(why, size, "%s", text); }

int s2a_vk_auto_resolve(const char *game_dir, const char *state_dir, char *why, size_t why_size) {
    char path[4096], text[4600];
    if (!game_dir || !*game_dir || !state_dir || !*state_dir) { say(why, why_size, "没有游戏目录或状态目录"); return 0; }
    int r = s2a_vk_descriptor_read(game_dir, NULL);
    if (r) {
        if (join(path, sizeof path, game_dir, DESCRIPTOR)) path[0] = 0;
        snprintf(text, sizeof text, "本包没有有效的 %s（%s，errno=%d）", path,
                 r == ENOENT ? "没有这个文件" : r == EINVAL ? "格式不对" : "读不了", r);
        say(why, why_size, text); return 0;
    }
    struct stat st;
    if (!join(path, sizeof path, state_dir, FAIL_FILE) && stat(path, &st) == 0) {
        char first[160] = "";
        FILE *f = fopen(path, "r");
        if (f) { if (!fgets(first, sizeof first, f)) first[0] = 0; fclose(f); }
        first[strcspn(first, "\n")] = 0;
        snprintf(text, sizeof text, "上局直连失败，留下 %s（%s）", path, first[0] ? first : "空");
        say(why, why_size, text); return 0;
    }
    if (!join(path, sizeof path, state_dir, ATTEMPT_FILE) && stat(path, &st) == 0) {
        snprintf(text, sizeof text, "上局直连没有正常结束，留下 %s", path);
        say(why, why_size, text); return 0;
    }
    if (join(path, sizeof path, game_dir, DESCRIPTOR)) path[0] = 0;
    snprintf(text, sizeof text, "就绪：%s 有效，状态目录没有 %s / %s", path, FAIL_FILE, ATTEMPT_FILE);
    say(why, why_size, text);
    return 1;
}

int s2a_vk_attempt_begin(const char *state_dir) {
    char path[4096], tmp[4200];
    if (!state_dir || !*state_dir) return EINVAL;
    if (join(path, sizeof path, state_dir, ATTEMPT_FILE)) return ENAMETOOLONG;
    if (snprintf(tmp, sizeof tmp, "%s.tmp", path) >= (int)sizeof tmp) return ENAMETOOLONG;
    // 先写临时文件再改名：标记要么完整在、要么不在，不会因写到一半被杀而误判
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return errno;
    static const char body[] = "vulkan-direct attempt\n";
    int ok = write(fd, body, sizeof body - 1) == (ssize_t)(sizeof body - 1);
    int saved = ok ? 0 : (errno ? errno : EIO);
    if (close(fd) && ok) { ok = 0; saved = errno; }
    if (ok && rename(tmp, path)) { ok = 0; saved = errno; }
    if (!ok) { unlink(tmp); return saved; }
    return 0;
}

static int remove_marker(const char *state_dir, const char *name) {
    char path[4096];
    if (!state_dir || !*state_dir) return EINVAL;
    if (join(path, sizeof path, state_dir, name)) return ENAMETOOLONG;
    return unlink(path) == 0 || errno == ENOENT ? 0 : errno;
}

int s2a_vk_attempt_end(const char *state_dir) { return remove_marker(state_dir, ATTEMPT_FILE); }

int s2a_vk_session_end(const char *state_dir, int choice, int normal, int failed_this_session) {
    if (!state_dir || !*state_dir) return EINVAL;
    if (!normal || (choice != S2A_VK_CHOICE_DIRECT && choice != S2A_VK_CHOICE_AUTO)) return 0;
    // 先清 fail 再清 attempt：中途被杀时 attempt 还在，下次 AUTO 仍回通用
    int result = choice == S2A_VK_CHOICE_DIRECT && !failed_this_session ? remove_marker(state_dir, FAIL_FILE) : 0;
    int attempt = s2a_vk_attempt_end(state_dir);
    return result ? result : attempt;
}
