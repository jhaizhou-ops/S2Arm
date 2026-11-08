// 全机 Metal 客户进程名额（总指挥 10-31：16:32 GPU 驱动 panic 时全机 216 个 MTLCompilerService）。
// 实测（出包线 10-31）：系统按「用 Metal 框架编译的进程」拉 MTLCompilerService，每个进程一两个，与进程内并发无关——单进程并发 32 份
//   newLibraryWithSource、400 条异步管线、MTL4Compiler 多线程 400 条都只多 1–2 个；xcrun metal 命令行（直连出库的 J 路）一个都不拉。
//   所以按进程拿名额，不按编译调用：建 Metal 设备前从 <运行区>/s2arm/mtl_slots/ 的 N 个锁文件里 flock 一个，持有到进程退出（进程崩了内核放锁，不漏名额）。
// 两个建设备点（gal_core.m nxgal_init、nvn_mtl.m mtl_init）都调这里；同一进程第二次调是空操作。进程级记号写在环境变量 S2A_MTL_SLOT_PID=<pid>:<fd>:<inode>：
//   复核时 pid 相同且那个 fd 还开着、还是那个锁文件才算持有。fork 出的子进程 pid 不同，自己另拿；exec 后 pid 不变但锁 fd 带 O_CLOEXEC 已关（名额已放），重拿。
// N = S2A_MTL_SLOTS（缺省本机核数），S2A_MTL_SLOTS=0 关闭；目录 S2A_MTL_SLOT_DIR（缺省 <S2A_RUN_ROOT 或 ~/.s2arm/run>/s2arm/mtl_slots）。
// 只在我方机器上生效：没设 S2A_MTL_SLOT_DIR、运行区 <…>/s2arm 也不存在（玩家装的 Mac 版）就什么都不做；iOS 不编进来。
// 没空位就等，开始等和之后每 60 秒往 stderr 打一行「等 GPU 名额」（谁在等、等了多久；持有者 pid 写在各锁文件里）。
#pragma once
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>
static inline int s2a_mtl_slot_take(const char *who) {   // → 拿到的名额号（1 起），0 = 不生效 / 已关 / 本进程已持有
    char dir[1024]; struct stat st;
    const char *held = getenv("S2A_MTL_SLOT_PID"); int hp, hfd; unsigned long long hino;
    if (held && sscanf(held, "%d:%d:%llu", &hp, &hfd, &hino) == 3 && hp == (int)getpid() && fstat(hfd, &st) == 0 && (unsigned long long)st.st_ino == hino) return 0;
    const char *ns = getenv("S2A_MTL_SLOTS"); int n = 0;
    if (ns && *ns) n = atoi(ns); else { size_t sz = sizeof n; if (sysctlbyname("hw.ncpu", &n, &sz, NULL, 0)) n = 8; }
    if (n <= 0) return 0;
    const char *d = getenv("S2A_MTL_SLOT_DIR");
    if (d && *d) snprintf(dir, sizeof dir, "%s", d);
    else {
        const char *rr = getenv("S2A_RUN_ROOT"), *home = getenv("HOME"); char run[1024];
        if (rr && *rr) snprintf(run, sizeof run, "%s/s2arm", rr); else if (home) snprintf(run, sizeof run, "%s/.s2arm/run/s2arm", home); else return 0;
        if (stat(run, &st) || !S_ISDIR(st.st_mode)) return 0;   // 没有运行区：不是我方机器
        snprintf(dir, sizeof dir, "%s/mtl_slots", run);
    }
    if (mkdir(dir, 0755) && errno != EEXIST) return 0;
    time_t t0 = time(NULL), said = 0;
    for (;;) {
        for (int k = 1; k <= n; k++) {
            char p[1100]; snprintf(p, sizeof p, "%s/%d.lock", dir, k);
            int fd = open(p, O_RDWR | O_CREAT | O_CLOEXEC, 0644); if (fd < 0) continue;
            if (flock(fd, LOCK_EX | LOCK_NB) == 0) {   // fd 不关：持有到进程退出
                char line[256]; int m = snprintf(line, sizeof line, "%d %s\n", (int)getpid(), who ? who : "?");
                if (ftruncate(fd, 0) == 0 && pwrite(fd, line, (size_t)m, 0) < 0) { /* 只是给人看的持有者记录，写不进不影响名额 */ }
                char mark[64]; struct stat fs; fstat(fd, &fs); snprintf(mark, sizeof mark, "%d:%d:%llu", (int)getpid(), fd, (unsigned long long)fs.st_ino);
                setenv("S2A_MTL_SLOT_PID", mark, 1);
                if (said) fprintf(stderr, "[Metal 名额] %s 拿到第 %d/%d 个名额（等了 %ld 秒）\n", who ? who : "?", k, n, (long)(time(NULL) - t0));
                return k;
            }
            close(fd);
        }
        if (!said || time(NULL) - said >= 60) { said = time(NULL); fprintf(stderr, "[Metal 名额] %s 等 GPU 名额：全机 %d 个都在用（持有者见 %s/*.lock），已等 %ld 秒\n", who ? who : "?", n, dir, (long)(said - t0)); }
        usleep(200000);
    }
}
#else
static inline int s2a_mtl_slot_take(const char *who) { (void)who; return 0; }
#endif
