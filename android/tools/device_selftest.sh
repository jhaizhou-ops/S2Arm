#!/bin/bash
# On-device rewrite self-test: rewrites tools/selftest_nso.py's synthetic module with the
# current runtime/rewriter (S2A_TARGET=android), imports it into the installed debug app's
# files/selftest through run-as, restarts the app and prints its "Rewrite self-test" line.
#   SERIAL=<serial> PY=<python with capstone + lz4> [ADB=adb] bash android/tools/device_selftest.sh
# The device is named explicitly and logcat is never cleared. On a shared phone, get access
# first. The script touches only org.s2arm.android.
set -euo pipefail
: "${SERIAL:?set SERIAL to the device serial}"
ADB=${ADB:-adb}; PY=${PY:-python3}; PKG=org.s2arm.android
R=$(cd "$(dirname "$0")/../.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
a() { "$ADB" -s "$SERIAL" "$@"; }
"$PY" "$R/android/tools/selftest_nso.py" "$T/selftest.nso"
REW=$("$PY" "$R/pack/rewriter.py" c-path)   # C 改写器（10-31 删 Python 改写器）
S2A_TARGET=android "$REW" "$T/selftest.nso" "$T/out" selftest > "$T/rewrite.log" \
  || { tail -5 "$T/rewrite.log"; exit 1; }
a shell run-as "$PKG" mkdir -p files/selftest
for f in patched.bin fixups.tsv gates.tsv; do
  # adb joins arguments into one device command line: quote the redirect so it runs under run-as
  a exec-in "run-as $PKG sh -c 'cat > files/selftest/selftest.$f'" < "$T/out/selftest.$f"
  want=$(sha256sum < "$T/out/selftest.$f" | cut -c1-64)
  got=$(a exec-out run-as "$PKG" sha256sum "files/selftest/selftest.$f" | cut -c1-64)
  [ "$want" = "$got" ] || { echo "import of selftest.$f is corrupt"; exit 1; }
done
since=$(a shell date "+%m-%d\ %H:%M:%S.000" | tr -d '\r')
a shell am start -S -W -n "$PKG/.MainActivity" > /dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  line=$(a logcat -d -T "$since" -s S2Arm:I | tr -d '\r' | grep -m1 'Rewrite self-test' || true)
  [ -n "$line" ] && break; sleep 1
done
crash=$(a logcat -d -b crash -T "$since" | tr -d '\r' | grep -m3 -E 'Fatal signal|#0[0-3] pc' || true)
[ -z "$crash" ] || echo "$crash"
echo "${line:-no self-test line in logcat}"
[[ $line == *"Rewrite self-test (S2A_TARGET=android): "*" ok"* ]]
