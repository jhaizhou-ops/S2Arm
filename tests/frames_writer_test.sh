#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：graphics/nvn/host_adapt.m tests/frames_writer_test.py
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 "$ROOT/tests/frames_writer_test.py"
