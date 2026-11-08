#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 tests/shader_batch_sim_test.py
