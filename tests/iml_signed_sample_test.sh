#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/iml_check.py pack/iml_formats.py tests/iml_signed_sample_test.py tests/fixtures/iml_signed/*
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$H/tests/iml_signed_sample_test.py"
