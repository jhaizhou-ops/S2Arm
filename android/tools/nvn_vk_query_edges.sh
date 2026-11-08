#!/usr/bin/env bash
# 宿主回归：遮挡查询环形页的边界（无真机、无真 Vulkan，桩提供已知结果）。
# 用法：bash android/tools/nvn_vk_query_edges.sh
# 退出 0 = 全部 case 通过；非 0 = 有 case 失败（逐条打印）。
# 覆盖：reset 范围、同批多 pass 累计换页、段日志压缩、长期不 Reset、批次被丢弃（整页作废）、会话重建，
#       以及 P0-leak ③：页池耗尽用有预算的完成等待（flush_ready），拿不到只拒绝本次分配、不进终态。
# 夹具按本支新语义重排调用顺序：nvn_vk_query_prepare（页选择/页耗尽回收，first_draw.c:2924，必须在
# 取命令缓冲之前）→ nvn_vk_query_cb_begin（只录 query pool reset，:2958）；该顺序由下面的生产接线检查锁住。
# 负控：在临时目录改生产源副本（qp_refuse → 终态 qp_fail），page_exhaust 必须变红，证明用例真的锁住语义。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cc=${CC:-cc}
py=${S2A_PY:-${PY:-python3}}
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-query-edges.XXXXXX")
trap 'rm -rf "$out"' EXIT
vkh="$repo/graphics/nvn/third_party/vulkan-headers/include"
"$cc" -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-missing-field-initializers -Wno-unused-parameter \
    -I "$repo/android/tests/query_edges/stub" \
    -I "$repo/android/tests/vkhost" -I "$vkh" \
    -I "$repo/android/native/direct" -I "$repo/android/native/nvn" \
    -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" -I "$repo/graphics/nvn/gfx" \
    -o "$out/t" "$repo/android/tests/nvn_vk_query_edges_test.c"
fail=0
for c in reset_range multipass compact cumulative abandoned abandoned_forgot session sync_retire sync_forgot page_exhaust; do
    printf '== %s ==\n' "$c"
    "$out/t" "$c" || fail=1
done
# 生产接线核对：查询模块的用例只能证明「退休接口本身对」，证明不了「同步完成入口调了它」。
# 这里直接核对 first_draw 的接线：批次前缀、后缀、整帧兜底三处都必须走 s2a_qret_*。
fd="$repo/android/native/nvn/nvn_vk_first_draw.c"
# 精确到「处数」：同步 flush 有两条批次完成分支（查状态 / 等 fence）与两条后缀分支，少接一处就漏。
check_wiring() {
    local pat="$1" what="$2" want="$3" n
    n=$(grep -c "$pat" "$fd" || true)
    if [ "$n" -ne "$want" ]; then
        echo "  接线不符：$what 期望 $want 处，实际 $n 处（${pat}）"; fail=1
    else
        printf '  %s: %d 处\n' "$what" "$n"
    fi
}
echo "== 生产接线（first_draw 各完成入口）=="
check_wiring 's2a_qret_slot(&g_fq.batch_qid\[i\]' "同步批次退休" 2
check_wiring 's2a_qret_slot(&g_fq.suffix_qid' "同步后缀退休" 3
check_wiring 's2a_qret_prefix(g_fq.batch_qid' "整帧兜底退休" 1
check_wiring 's2a_qret_slot(&q->suffix_qid' "延迟退休后缀" 1
check_wiring 's2a_qret_prefix(q->batch_qid' "延迟退休批次" 1
# 页选择/回收（prepare）必须在 fd_pass_begin 里、取命令缓冲（fd_cmd_get）之前完成：这是本支
# “真机 SIGSEGV fault 0x74”的修法（first_draw.c:2919-2933）。数量与相对顺序一起锁：只核对函数名
# 出现过不够，prepare 被挪到取缓冲之后就又会退回崩溃语义（这也是门禁这步红的根因）。
check_wiring 'nvn_vk_query_prepare(' "查询页 prepare 接线" 1
check_wiring 'nvn_vk_query_cb_begin(' "查询 reset 录制接线" 1
order=$(awk '
    /static int fd_pass_begin\(/ { f = 1 }
    f && /nvn_vk_query_prepare\(/ && !p { p = NR }
    f && /fd_cmd_get\(/ && !c { c = NR }
    f && p && /^}/ { exit }
    END { if (p && c && p < c) print "ok"; else print "bad:" p ":" c }
' "$fd")
if [ "$order" = ok ]; then
    printf '  prepare 先于取命令缓冲: ok\n'
else
    echo "  接线顺序不符：fd_pass_begin 里 prepare(${order#bad:}) 必须先于 fd_cmd_get"; fail=1
fi
# 直接调模块接口只允许出现在回调里（一处），否则接线可能被绕过
n=$(grep -c 'nvn_vk_query_batch_completed(' "$fd" || true)
[ "$n" -eq 1 ] || { echo "  直调 nvn_vk_query_batch_completed 有 $n 处（期望只有 fd_query_retire_cb 里那 1 处）"; fail=1; }

# 负控（变异构建；只改临时目录里的生产源副本，工作树不动）：page_exhaust 锁的是“页耗尽拿不到
# 完成证明时只拒绝本次分配、Q.failed 不进终态”。把 query.c 里 qp_refuse 的入口改成终态 qp_fail 后，
# page_exhaust 必须红在 Q.failed=1 这条断言上；不红就说明断言没锁住“可重试≠终态”。
# 做法与 tools/nvn_vk_ssbo_guest_test.sh 的变异构建一致。
mkdir -p "$out/mut"
"$py" - "$repo/android/native/nvn/nvn_vk_query.c" "$out/mut/nvn_vk_query.c" <<'PY'
import sys
src = open(sys.argv[1], encoding='utf-8').read()
needle = 'static int qp_refuse(const char *text, char *why, size_t why_size) {\n'
# 负控：可重试拒绝（只加 fails 统计、不置 Q.failed）被错误地改成终态 qp_fail。
mut = src.replace(needle, needle + '    return qp_fail(text, why, why_size);\n')
if mut == src:
    sys.exit('变异点未找到：nvn_vk_query.c 里找不到 qp_refuse 定义')
open(sys.argv[2], 'w', encoding='utf-8').write(mut)
PY
"$cc" -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-missing-field-initializers -Wno-unused-parameter \
    -I "$out/mut" \
    -I "$repo/android/tests/query_edges/stub" \
    -I "$repo/android/tests/vkhost" -I "$vkh" \
    -I "$repo/android/native/direct" -I "$repo/android/native/nvn" \
    -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" -I "$repo/graphics/nvn/gfx" \
    -o "$out/mut/t" "$repo/android/tests/nvn_vk_query_edges_test.c"
if "$out/mut/t" page_exhaust > "$out/mut/log" 2>&1; then
    echo "  负控未被抓到：qp_refuse→qp_fail 后 page_exhaust 仍通过（断言没锁住“可重试≠终态”）"; fail=1
elif ! grep -q 'Q.failed=1' "$out/mut/log"; then
    echo "  负控红了但不是“进终态”这条断言；输出："
    sed 's/^/    /' "$out/mut/log"
    fail=1
else
    printf '  负控：qp_refuse→qp_fail 被 page_exhaust 抓到（Q.failed=1，用例红）\n'
fi

[ "$fail" = 0 ] && echo "nvn-vk-query-edges: 通过" || { echo "nvn-vk-query-edges: 失败"; exit 1; }
