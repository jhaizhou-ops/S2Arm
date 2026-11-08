#!/usr/bin/env bash
# Standalone read-only Android doctor. Does not source any build/install script.
set -euo pipefail
android_dir=$(cd "$(dirname "$0")" && pwd)
exec python3 -B "$android_dir/doctor/doctor.py" "$@"
