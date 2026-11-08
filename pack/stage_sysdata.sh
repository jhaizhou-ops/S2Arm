#!/bin/bash
# 出包·系统数据阶段（对外入口不变）：pack/stage_sysdata.sh <款>
# 实现已搬进共享阶段 pack/stages/sysdata.sh（J07 #183）：本文件只原样转发参数与退出码，产物路径 / 阶段语义不变。
set -u
H=$(cd "$(dirname "$0")" && pwd)
exec bash "$H/stages/sysdata.sh" "$@"
