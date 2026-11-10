#!/usr/bin/env bash
# 门禁手动：重新生成入库的合成测试码流，要 ffmpeg（libvpx-vp9）与一份带 VP9 编码器的 libvpx 构建，结果入库、门禁只读结果
# 重新生成合成 VP9 测试码流（不含任何游戏数据；不是构建或门禁的一部分，结果入库）。
# 需要：带 libvpx-vp9 的 ffmpeg；resize.ivf 另要一份带 VP9 编码器的 libvpx 1.17.0 构建（LIBVPX_SRC = 源码目录，LIBVPX_BUILD = 构建目录，
#   configure --disable-vp8 --enable-vp9-encoder --disable-vp9-decoder --disable-examples --disable-tools --disable-unit-tests）。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
two_pass() {   # <lavfi source> <output> <ffmpeg vp9 options...>
    local src=$1 out=$2; shift 2
    ffmpeg -v error -y -f lavfi -i "$src" -frames:v 48 -c:v libvpx-vp9 -threads 1 "$@" -pass 1 -passlogfile "$W/p" -f null -
    ffmpeg -v error -y -f lavfi -i "$src" -frames:v 48 -c:v libvpx-vp9 -threads 1 "$@" -pass 2 -passlogfile "$W/p" -f ivf "$out"
}
# 1280x720，4 列 tile，后向自适应（frame-parallel 0），隐藏 alt-ref，复合预测，每 16 帧一个关键帧
two_pass "testsrc2=size=1280x720:rate=30,format=yuv420p" "$HERE/adapt_720.ivf" \
    -b:v 1200k -tile-columns 2 -frame-parallel 0 -auto-alt-ref 1 -lag-in-frames 16 -g 16 -cpu-used 4
# 350x198（不是 8 的倍数），frame-parallel 1（P4G 的设置），隐藏 alt-ref
two_pass "mandelbrot=size=350x198:rate=30,format=yuv420p" "$HERE/fp_ragged.ivf" \
    -b:v 250k -frame-parallel 1 -auto-alt-ref 1 -lag-in-frames 16 -g 16 -cpu-used 4
# 640x360 → 480x272，不插关键帧（缩放参考帧）
cc -O2 -I"$LIBVPX_SRC" -I"$LIBVPX_BUILD" "$HERE/resize_enc.c" "$LIBVPX_BUILD/libvpx.a" -lm -o "$W/resize_enc"
"$W/resize_enc" "$HERE/resize.ivf"
ls -l "$HERE"/*.ivf
