#!/bin/bash
# 出包·着色器阶段（iOS 入口）：pack/stage_shaders.sh <款> [--ref <Ryujinx 缓存目录>]…
# 实现已搬进共享阶段 pack/stages/shaders.sh（J07 #183）：本文件只做两件事——
#   ① 把 iOS 的缺省目标参数交给共享阶段（共享阶段自己不含目标名）：缺省平台 ios（S2A_PACK_PLAT）、
#      缺省 GPU 架构集合（三种模式：显式 > S2A_PSO_ARCHS_ALL=1 全机型 > 我方真机）；
#      ② 原样转发命令行与退出码。
# 缺省值被调用方覆盖时行为与原实现完全一致（键里 -a 后缀的判定同原先）。
set -u
H=$(cd "$(dirname "$0")" && pwd)
# 原实现里 S2A_PACK_PLAT 缺省就是 ios（键里 -a 后缀的判据）；这里显式补齐，共享阶段不再写目标名。
export S2A_PACK_PLAT=${S2A_PACK_PLAT:-ios}
# 出哪些（GPU 架构, 系统大版本）对由 graphics/tools/shader_pack.sh 调 pack/jobs/archs.py pairs 推导（目标表 + 按用途，10-29），这里不再先解析、不导出 S2A_PSO_ARCHS
#   （导出了就成了「显式给定」，iOS 会变成架构 × S2A_PSO_OS 的笛卡尔积）
export S2A_PSO_ARCH_DEFAULT_PLAT=${S2A_PSO_ARCH_DEFAULT_PLAT:-ios}
export S2A_PSO_ARCH_DEFAULT_ARCHS=${S2A_PSO_ARCH_DEFAULT_ARCHS:-applegpu_g18p}
exec bash "$H/stages/shaders.sh" "$@"
