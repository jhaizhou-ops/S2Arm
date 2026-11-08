#!/usr/bin/env bash
# Device-free synthetic doctor contract suite; requires Python standard library only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
: "${TMPDIR:?set TMPDIR to an owned external cache directory}"
exec python3 -B "$here/test_doctor.py"
