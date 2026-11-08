#!/bin/bash
# 门禁覆盖：tools/gate_route.py tools/gate_decl.py tests/gate_route_matrix_test.py
set -eu
cd "$(dirname "$0")/.."
python3 tests/gate_route_matrix_test.py
