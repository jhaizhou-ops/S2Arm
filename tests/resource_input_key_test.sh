#!/bin/bash
# 资源内容键同款跨根摘要缓存单测（pack/resource_input_key.py：克隆根复用、改内容重采、别款不借、本根原地改字节且 mtime 改回必重采）
# 门禁覆盖：pack/resource_input_key.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$R/tests/resource_input_key_test.py" "$@"
