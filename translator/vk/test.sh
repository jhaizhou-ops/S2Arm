#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
python3 "$HERE/check_passes.py"
python3 "$HERE/check_passes.py" --negative-controls
