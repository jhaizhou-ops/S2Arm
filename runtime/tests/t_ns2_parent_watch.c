// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "../../macos/ns2_parent_watch.h"
#include <assert.h>
#include <signal.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    alarm(10);
    pid_t parent = fork();
    assert(parent >= 0);
    if (!parent) {
        usleep(200 * 1000);
        _exit(0);
    }
    pid_t watcher = fork();
    assert(watcher >= 0);
    if (!watcher) _exit(s2a_ns2_wait_for_parent_exit(parent) ? 0 : 1);

    int status;
    assert(waitpid(watcher, &status, 0) == watcher);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    assert(waitpid(parent, &status, 0) == parent);
    puts("✓ t_ns2_parent_watch：父进程退出后监视返回");
    return 0;
}
