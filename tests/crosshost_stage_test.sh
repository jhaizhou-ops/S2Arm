#!/bin/bash
# 门禁覆盖：pack/stage_extract.sh pack/stages/unpack.sh pack/refresh.sh pack/stages/romfsidx.sh pack/roots.sh services/romfs_index.sh pack/seed_root.sh pack/stages/sysdata.sh pack/stages/aoc.sh tools/clonedir.py pack/crosshost/*
# Original synthetic inputs only; Linux local checks are not a Mac comparison.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
python3 "$R/tests/crosshost_stage_test.py"
