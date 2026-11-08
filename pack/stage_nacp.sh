#!/bin/bash
# 出包·元数据阶段（对外入口不变）：pack/stage_nacp.sh <款> <xci / nsp 文件…>
# 实现已搬进共享阶段 pack/stages/nacp.sh（J07 #183）：本文件只原样转发参数与退出码，产物路径 / 阶段语义不变。
set -u
H=$(cd "$(dirname "$0")" && pwd)
exec bash "$H/stages/nacp.sh" "$@"
