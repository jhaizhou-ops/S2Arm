#!/bin/bash
# 门禁覆盖：graphics/metal/mtl_slot.h graphics/metal/gal_core.m graphics/nvn/gfx/nvn/nvn_mtl.m tests/mtl_slot_test.sh
# 全机 Metal 客户进程名额（graphics/metal/mtl_slot.h）单测，约 5 秒，不起 Metal、不碰真运行区（名额目录都在临时目录）。期望按规则手算：
#   ① N=2：两个持有者各拿到不同名额、take 不阻塞；第三个在两人都持有时才起，take 阻塞到有人退出才拿到 1..2（按事件判，不比起跑时刻）
#      （10-31 只比相对时刻仍会误红：11-02 mini 负载高时第一个持有者退出后第三个才起来、不阻塞，改成等两人都拿到再起第三个）
#   ② 同一进程调两次：第二次返回 0（空操作），N=1 时也不自锁
#   ③ exec：pid 不变、锁 fd 随 exec 关掉（名额已放），新程序重拿到 1，不是空操作 0；fork：子进程 pid 不同、继承父的锁，N=2 时自己另拿到 2
#   ④ S2A_MTL_SLOTS=0：返回 0、不建目录
#   ⑤ 没设 S2A_MTL_SLOT_DIR、HOME 下也没有 .s2arm/run/s2arm（玩家机器）：返回 0、什么都不建
#   ⑥ 持有者被 kill -9：名额由内核放回，N=1 时后来者拿名额不阻塞（量 take 本身，不含起进程）
#   ⑦ 接线：gal_core.m 的 nxgal_init、nvn_mtl.m 的 mtl_init 都在 MTLCreateSystemDefaultDevice 之前调 s2a_mtl_slot_take
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
cat > "$T/p.c" <<'C'
#include "mtl_slot.h"
#include <sys/time.h>
#include <sys/wait.h>
static double now(void) { struct timeval t; gettimeofday(&t, NULL); return t.tv_sec + t.tv_usec / 1e6; }
int main(int argc, char **argv) {
    // P_READY：拿名额前先建这个文件，测试据此知道本进程已经走到 take（按事件判，不赌起进程要多久）
    const char *ready = getenv("P_READY"); if (ready) { FILE *f = fopen(ready, "w"); if (f) fclose(f); }
    double t0 = atof(argv[1]), ta = now(); int k = s2a_mtl_slot_take("t"); double tk = now() - ta;   // tk：拿名额这一步本身阻塞了多久（不含起进程）
    if (argc > 2 && !strcmp(argv[2], "twice")) { printf("%d %d\n", k, s2a_mtl_slot_take("t")); return 0; }
    if (argc > 2 && !strcmp(argv[2], "exec")) { printf("%d\n", k); fflush(stdout); execl(argv[0], argv[0], argv[1], "plain", (char *)NULL); return 9; }
    if (argc > 2 && !strcmp(argv[2], "fork")) { printf("%d\n", k); fflush(stdout); pid_t c = fork(); if (!c) { printf("%d\n", s2a_mtl_slot_take("c")); return 0; } int w; waitpid(c, &w, 0); return 0; }
    printf("%d %.2f %.2f\n", k, now() - t0, tk); fflush(stdout);
    // 第 4 个参数是「go:<文件>」时一直持有到那个文件出现（测试放行才退出）；否则按秒数持有
    if (argc > 3 && !strncmp(argv[3], "go:", 3)) { while (access(argv[3] + 3, F_OK)) usleep(20000); }
    else if (argc > 3) usleep((useconds_t)(atof(argv[3]) * 1e6));
    return 0;
}
C
clang -O1 -I"$H/graphics/metal" -o "$T/p" "$T/p.c" || { echo "不通 编译"; exit 1; }
now() { python3 -c 'import time; print(time.time())'; }
D=$T/slots
# ①（11-02 改按事件判：原先三个进程同时起、按相对时刻判；mini 负载高时第一个拿到名额、持有 1 秒退出后第三个才起来，不阻塞也拿到，读数「1 0.31 0.00 1…」误红）
#   11-03 再改：上面的写法仍赌「第三个 4 秒内走到 take」，mini 无缓存全套时第三个起来就花了 4 秒多（读数「1 …55.93 0.00」）。
#   现在两个持有者一直持有到 go 文件出现；第三个走到 take 前先建 ready 文件，测试见到 ready 再等 0.6 秒才放 go——
#   第三个的 take 阻塞时长一定 ≥0.6 秒（持有者没放手），与起进程快慢、机器负载无关；DL 秒只防挂死
DL=${MTL_TEST_WAIT_S:-300}; wait_ev() { local dl=$((SECONDS + DL)); until eval "$1"; do [ $SECONDS -ge $dl ] && return 1; sleep 0.1; done; }
for i in 1 2; do S2A_MTL_SLOTS=2 S2A_MTL_SLOT_DIR=$D "$T/p" 0 hold "go:$T/go" > "$T/o$i" & done
wait_ev '[ -s "$T/o1" ] && [ -s "$T/o2" ]'
P_READY=$T/ready S2A_MTL_SLOTS=2 S2A_MTL_SLOT_DIR=$D "$T/p" 0 > "$T/o3" & P3=$!
wait_ev '[ -e "$T/ready" ]'; sleep 0.6; touch "$T/go"; wait
r=$(cat "$T/o1" "$T/o2" "$T/o3" | tr '\n' ' ')
ck "① N=2：两个持有者各拿到不同名额且没等（第 3 列 <0.5），第三个在两人都持有时起、take 阻塞 ≥0.5 秒后拿到 1..2（${r}）" "cat '$T/o1' '$T/o2' '$T/o3' | awk '{k[NR]=\$1; w[NR]=\$3} END {exit !(w[1] < 0.5 && w[2] < 0.5 && k[1] != k[2] && k[1] >= 1 && k[1] <= 2 && k[2] >= 1 && k[2] <= 2 && w[3] >= 0.5 && k[3] >= 1 && k[3] <= 2)}'"
# ②
o=$(S2A_MTL_SLOTS=1 S2A_MTL_SLOT_DIR=$D timeout 5 "$T/p" 0 twice)
ck "② 同一进程两次：第二次 0、不自锁（${o}）" '[ "$o" = "1 0" ]'
# ③
o=$(S2A_MTL_SLOTS=2 S2A_MTL_SLOT_DIR=$D timeout 5 "$T/p" 0 exec | awk '{print $1}' | tr '\n' ' ')
ck "③ exec：锁随 exec 放掉、新程序重拿到 1（${o}）" '[ "$o" = "1 1 " ]'
o=$(S2A_MTL_SLOTS=2 S2A_MTL_SLOT_DIR=$D timeout 5 "$T/p" 0 fork | awk '{print $1}' | tr '\n' ' ')
ck "③ fork：子进程 pid 不同、另拿到 2（${o}）" '[ "$o" = "1 2 " ]'
# ④
o=$(S2A_MTL_SLOTS=0 S2A_MTL_SLOT_DIR=$T/off "$T/p" 0 | awk '{print $1}')
ck "④ S2A_MTL_SLOTS=0：返回 0、不建目录（${o}）" '[ "$o" = 0 ] && [ ! -e "$T/off" ]'
# ⑤
mkdir -p "$T/home"; o=$(env -u S2A_MTL_SLOT_DIR -u S2A_RUN_ROOT -u S2A_MTL_SLOTS HOME=$T/home "$T/p" 0 | awk '{print $1}')
ck "⑤ 没有运行区（玩家机器）：返回 0、不建东西（${o}）" '[ "$o" = 0 ] && [ -z "$(ls -A "$T/home")" ]'
# ⑥
S2A_MTL_SLOTS=1 S2A_MTL_SLOT_DIR=$T/k "$T/p" 0 hold 30 > /dev/null & h=$!; sleep 0.5; kill -9 $h; wait $h 2> /dev/null
t=$(now); o=$(S2A_MTL_SLOTS=1 S2A_MTL_SLOT_DIR=$T/k timeout 5 "$T/p" "$t")
# ⑥ 判「拿名额这一步」的阻塞时长（第 3 列），不判从 shell 记时到拿到（第 2 列含起 python + 起被测程序，11-02 mini 负载 200+ 时 1.17 秒误红）
ck "⑥ 持有者 kill -9 后名额放回：拿名额不阻塞（<1 秒）（${o}）" "echo '$o' | awk '\$1==1 && \$3<1 {ok=1} END {exit !ok}'"
# ⑦
ck "⑦ 接线：nxgal_init 与 mtl_init 都在建设备前拿名额" \
  'grep -B1 "g_gdev = MTLCreateSystemDefaultDevice()" "$H/graphics/metal/gal_core.m" | grep -q s2a_mtl_slot_take && grep -B1 "g_dev = MTLCreateSystemDefaultDevice()" "$H/graphics/nvn/gfx/nvn/nvn_mtl.m" | grep -q s2a_mtl_slot_take'
[ $bad = 0 ] && echo "mtl_slot 单测全过" || { echo "mtl_slot 单测有不通"; exit 1; }
