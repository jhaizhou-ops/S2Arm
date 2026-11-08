#!/bin/bash
# 出包·RomFS 预建索引阶段（对外入口不变）：pack/stage_romfsidx.sh <款>
# 实现已搬进共享阶段 pack/stages/romfsidx.sh（J07 #183）：本文件只原样转发参数与退出码，产物路径 / 阶段键不变。
set -u
H=$(cd "$(dirname "$0")" && pwd)
exec bash "$H/stages/romfsidx.sh" "$@"
