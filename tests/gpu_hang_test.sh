#!/bin/bash
# GPU 卡死签名增量扫单测（tools/gpu_hang.sh，约 5 秒，临时写 64 MB）：bash tests/gpu_hang_test.sh
# 期望（按契约手写）：
#   ① 没签名 → 返回 1；追加一行签名 → 返回 0、打出那行
#   ② 增量：第一次扫完后，把签名「原地」写进已扫过的前段（文件大小不变）→ 不再读前段、返回 1；之后追加的新签名照样命中
#   ③ 在 $(…) 子 shell 里连续调用，偏移照样带到下一次（状态在文件里）
#   ④ 文件变短（轮转 / 整份重写）→ 从头扫，命中新文件里的签名
#   ⑤ 签名正好跨在上次扫到的位置（前半已扫、后半新写）→ 回看 4 KB，不漏
#   ⑥ 大文件：64 MB 已扫过后只追加 1 行 → 命中；两次用时打出来看（不按耗时判）
# 门禁覆盖：tools/gpu_hang.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export S2A_GPU_HANG_STATE_DIR=$T/st; mkdir -p "$T/st"
source "$H/tools/gpu_hang.sh"
SIG='[s2a] 【红】GPU 挂死安全停：这局停在这里（Caused GPU Hang Error (00000003:kIOGPUCommandBufferCallbackErrorHang)）'
f=$T/a.log; printf '帧 1\n帧 2\n' > "$f"
s2a_gpu_hang "$f" > /dev/null; r1=$?
echo "$SIG" >> "$f"; o=$(s2a_gpu_hang "$f"); r2=$?
ck "① 没签名 → 1（实 ${r1}）；追加签名 → 0 且打出该行（实 ${r2}）" '[ $r1 = 1 ] && [ $r2 = 0 ] && [[ $o == *GPU\ 挂死安全停* ]]'
g=$T/b.log; python3 -c 'import sys; open(sys.argv[1],"w").write("x" * 20000 + "\n")' "$g"
o=$(s2a_gpu_hang "$g"); r1=$?
python3 -c 'import sys; f=open(sys.argv[1],"r+b"); f.seek(100); f.write(b"GPU Hang"); f.close()' "$g"   # 原地改前段、大小不变
o=$(s2a_gpu_hang "$g"); r2=$?
echo "kIOGPUCommandBufferCallbackErrorPageFault" >> "$g"; o=$(s2a_gpu_hang "$g"); r3=$?
ck "② 已扫前段原地写签名 → 不读前段（实 ${r2}，期望 1）；新追加签名 → 命中（实 ${r3}，「${o:0:40}」）" '[ $r1 = 1 ] && [ $r2 = 1 ] && [ $r3 = 0 ] && [[ $o == *PageFault* ]]'
ck "③ 上面三次都在 \$(…) 子 shell 里调，偏移照样带过去（② 成立即证）" '[ $r2 = 1 ]'
printf '新文件\n%s\n' "$SIG" > "$g"; o=$(s2a_gpu_hang "$g"); r4=$?
ck "④ 文件变短（整份重写）→ 从头扫、命中（实 ${r4}）" '[ $r4 = 0 ]'
h=$T/c.log; printf '%s' "前文 [s2a] 【红】GPU 挂" > "$h"; o=$(s2a_gpu_hang "$h"); r5=$?
printf '%s\n' "死安全停：跨交界" >> "$h"; o=$(s2a_gpu_hang "$h"); r6=$?
ck "⑤ 签名跨在上次位置两侧 → 第一次 1（实 ${r5}）、第二次命中（实 ${r6}）" '[ $r5 = 1 ] && [ $r6 = 0 ] && [[ $o == *GPU\ 挂死安全停* ]]'
k=$T/big.log; python3 -c 'import sys
with open(sys.argv[1], "w") as f:
    line = "[s2a] 心跳 帧 123456 GPU 慢一点 正常 " + "y" * 200 + "\n"
    for _ in range(64 * 1024 * 1024 // len(line)): f.write(line)' "$k"
t0=$(python3 -c 'import time; print(time.time())'); s2a_gpu_hang "$k" > /dev/null; t1=$(python3 -c 'import time; print(time.time())')
echo "$SIG" >> "$k"; o=$(s2a_gpu_hang "$k"); r7=$?; t2=$(python3 -c 'import time; print(time.time())')
d1=$(python3 -c "print(round($t1 - $t0, 3))"); d2=$(python3 -c "print(round($t2 - $t1, 3))")
ck "⑥ 64 MB：首扫 ${d1} 秒、追加 1 行后再扫 ${d2} 秒（读数只打出来看；只读新增部分由 ② 按事件证明，不按耗时判，免得负载高时偶发）、命中（实 ${r7}）" '[ $r7 = 0 ]'
[ $bad = 0 ] && echo "gpu_hang 单测全过" || { echo "gpu_hang 单测有不通"; exit 1; }
