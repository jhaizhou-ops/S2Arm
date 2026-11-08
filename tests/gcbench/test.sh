#!/bin/bash
# 门禁手动：要联网：tests/gcbench/build.sh 要先 --restore 恢复 NuGet（离线跑报 NETSDK1004 assets 文件不存在）；其中离线记账单测 test_scan.py 已单独接进 tests/gcbench_test.sh
# Offline accounting tests + real NativeAOT forced-GC instrumentation control.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
python3 "$ROOT/tests/gcbench/test_scan.py"
bash "$ROOT/tests/gcbench/build.sh"
OUT=${S2A_GCBENCH_BUILD:-$ROOT/build/195-gcbench/aot}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
"$OUT/publish/GcBench" --frames 1000 --frame-us 0 --small-mb 8 --loh-mb 2 \
  --poh-mb 1 --ring-mb 1 --forced-control > "$TMP/control.json"
python3 - "$ROOT/tests/gcbench" "$TMP/control.json" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from scan import summarize
x = json.load(open(sys.argv[2]))
s = summarize(x)
assert x['native_aot'] and x['completed_frames'] == 1000
assert x['forced_measured_collections'] == 1
assert s['complete'] and s['blocking_compacting'] >= 1, s
assert x['peak_resident_bytes'] > 0 and x['peak_virtual_bytes'] > 0
assert x['peak_private_untagged_bytes'] >= x['initial_private_untagged_bytes'] > 0
print('NativeAOT control: counts, compaction, pauses and VM accounting passed')
PY
if "$OUT/publish/GcBench" --frames 0 > "$TMP/invalid.json" 2> "$TMP/invalid.stderr"; then
  echo 'invalid workload unexpectedly accepted' >&2; exit 1
fi
S2A_GCBENCH_LATENCY=sustained "$OUT/publish/GcBench" --frames 10 --frame-us 0 \
  --small-mb 1 --loh-mb 1 --poh-mb 1 --ring-mb 1 > "$TMP/sustained.json"
python3 - "$TMP/sustained.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['latency_mode'] == 'SustainedLowLatency'
print('SustainedLowLatency: actual runtime mode verified')
PY
if S2A_GCBENCH_LATENCY=unknown "$OUT/publish/GcBench" --frames 1 \
    > "$TMP/bad-mode.json" 2> "$TMP/bad-mode.stderr"; then
  echo 'unknown latency mode unexpectedly accepted' >&2; exit 1
fi
for mode in transient-native all-native; do
  "$OUT/publish/GcBench" --large-mode "$mode" --frames 20 --frame-us 0 \
    --small-mb 1 --loh-mb 2 --poh-mb 1 --ring-mb 1 > "$TMP/$mode.json"
done
python3 - "$TMP" <<'PY'
import json, sys
from pathlib import Path
for mode in ('transient-native', 'all-native'):
    x = json.loads((Path(sys.argv[1]) / (mode + '.json')).read_text())
    assert x['workload']['large_mode'] == mode
    assert x['native_allocated_bytes'] > 0 and x['peak_native_live_bytes'] > 0
    assert x['forced_measured_collections'] == 0 and x['completed_frames'] == 20
    assert x['peak_private_untagged_accessible_bytes'] > 0
    assert x['peak_gc_committed_bytes'] > 0
print('Native buffers: both paths executed, touched and disposed with balanced accounting')
PY
