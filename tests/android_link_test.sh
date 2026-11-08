#!/usr/bin/env bash
# Run the Android link-symbol fixture in the shared test gate.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 android/core-link/tests/t_link_symbols.py
