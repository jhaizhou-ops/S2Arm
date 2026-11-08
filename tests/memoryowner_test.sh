#!/bin/bash
# MemoryOwner 真实 API 单测（tests/memoryowner/test.sh：编真 compat/tree/src/Ryujinx.Common/Memory/MemoryOwner.cs，等长 / 跨线程 / 跨大小复用与后备字节、份数边界；本机负载 30 时约 15 秒）
# 11-01 接线：扫描分母按 tests 目录后查出原先没有门禁调它。产物放本次临时目录，跑完删。
# 门禁覆盖：tests/memoryowner/* compat/tree/src/Ryujinx.Common/Memory/MemoryOwner.cs
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
bash "$H/tests/memoryowner/test.sh" "$T/out"
