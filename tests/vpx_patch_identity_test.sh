#!/usr/bin/env bash
# 门禁覆盖：services/vpx/** tests/vpx_patch_identity/* tests/data/vp9_synth/*
# libvpx 的 S2Arm 补丁（services/vpx/patches，Nvdec VP9 作业接口）不调钩子时不改变解码结果：同一配方的打补丁（ship）与不打补丁（nopatch）
# 两份 libvpx，用公开 API 解合成 VP9 码流与 VP8 官方向量，单线程 / 3 线程（行级并行）逐帧 FNV-1a 必须一致。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd -P)
[ "$(uname -s)" = Darwin ] || { echo "vpx_patch_identity：只在 macOS 上跑（苹果配方），本机 $(uname -s)" >&2; exit 75; }
command -v xcrun >/dev/null || { echo 'missing Xcode' >&2; exit 75; }
RID=osx-$( [ "$(uname -m)" = arm64 ] && echo arm64 || echo x64 )
ship=$(bash "$H/services/vpx/build.sh" "$RID" | tail -1); ship=${ship%/*/*}
plain=$(S2A_VPX_VARIANT=nopatch bash "$H/services/vpx/build.sh" "$RID" | tail -1); plain=${plain%/*}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for v in ship plain; do
    d=${!v}
    xcrun clang -std=c11 -O2 -I"$d/include" "$H/tests/vpx_patch_identity/hashdec.c" "$d/libvpx.a" -o "$W/hashdec-$v"
done
fails=0; frames=0
for f in "$H"/tests/data/vp9_synth/*.ivf "$H/services/S2A.Services.Tests/data/vp80-00-comprehensive-001.ivf"; do
    for t in 1 3; do
        "$W/hashdec-ship" "$f" "$t" > "$W/a"; "$W/hashdec-plain" "$f" "$t" > "$W/b"
        n=$(wc -l < "$W/a" | tr -d ' '); frames=$((frames + n))
        if [ "$n" -gt 0 ] && cmp -s "$W/a" "$W/b"; then echo "通 ${f##*/} 线程 ${t}：$n 帧一致"
        else echo "🔴 ${f##*/} 线程 ${t}：打补丁与不打补丁的输出不同（或没出帧）"; fails=$((fails + 1)); fi
    done
done
[ "$fails" = 0 ] && echo "vpx_patch_identity 单测全过（$frames 帧）" || { echo "vpx_patch_identity：$fails 组不一致"; exit 1; }
