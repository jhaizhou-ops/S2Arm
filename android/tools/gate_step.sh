#!/usr/bin/env bash
# Gate-only child isolation: preserve the failing child's first red, not red
# negative controls printed by earlier successful children.
s2a_gate_init() {
    S2A_GATE_SUMMARY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/s2a-android-gate-summary.XXXXXXXX")
    S2A_GATE_SUMMARY_FILE="$S2A_GATE_SUMMARY_DIR/failure"
    export S2A_GATE_SUMMARY_DIR S2A_GATE_SUMMARY_FILE
}

# 说明行（s2a_gate_note）也占摘要位（gate.sh 里「🔴 找不到 JDK」之类说明后紧跟 exit 1，它就是红因），但只是「暂占」：
#   之后有子项返回非零，以那一步的诊断为准（11-07：mini 上安卓钩子返回 75，摘要却是更早一条「W2 … 未运行（仅 Linux）」说明，
#   真正返回 75 那一步的诊断被盖掉，门禁和总指挥都看不到原因）。子项红之后的说明不覆盖子项红
s2a_gate_note() {
    printf '%s\n' "$1" >&2
    if [ -n "${S2A_GATE_SUMMARY_FILE:-}" ] && [ ! -s "$S2A_GATE_SUMMARY_FILE" ]; then
        printf '%s\n' "$1" > "$S2A_GATE_SUMMARY_FILE"
        : > "$S2A_GATE_SUMMARY_FILE.note"
    fi
}

s2a_gate_step() {
    # Direct test.sh users retain its original stdout/stderr and exit semantics.
    if [ -z "${S2A_GATE_SUMMARY_FILE:-}" ]; then "$@"; return $?; fi
    local log rc first last
    local -a status
    log=$(mktemp "$S2A_GATE_SUMMARY_DIR/step.XXXXXXXX")
    rc=0
    "$@" 2>&1 | tee "$log" || {
        status=("${PIPESTATUS[@]}")
        rc=${status[0]}
        [ "$rc" -ne 0 ] || rc=${status[1]}
    }
    if [ "$rc" -ne 0 ] && { [ ! -s "$S2A_GATE_SUMMARY_FILE" ] || [ -e "$S2A_GATE_SUMMARY_FILE.note" ]; }; then
        rm -f "$S2A_GATE_SUMMARY_FILE.note"
        first=$(grep -m1 -E '【红】|🔴' "$log" || true)
        if [ -z "$first" ]; then
            last=$(grep -v '^[[:space:]]*$' "$log" | tail -1 || true)
            first="【红】安卓门禁子项失败（rc=${rc}，${1##*/}）：${last:-无诊断输出}"
        fi
        printf '%s\n' "$first" > "$S2A_GATE_SUMMARY_FILE"
    fi
    rm -f "$log"
    return "$rc"
}

s2a_gate_finish() {
    local rc=$1
    trap - EXIT
    if [ "$rc" -ne 0 ]; then
        if [ -s "$S2A_GATE_SUMMARY_FILE" ]; then
            cat "$S2A_GATE_SUMMARY_FILE" >&2
        else
            printf '【红】安卓门禁失败（rc=%s；子项没有诊断输出）\n' "$rc" >&2
        fi
    fi
    rm -rf "$S2A_GATE_SUMMARY_DIR"
    exit "$rc"
}
