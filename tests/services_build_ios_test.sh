#!/bin/bash
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/bash" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$S2A_BUILD_TEST_CALLS"
printf '/fake/library.a\n'
SH
chmod +x "$T/bin/bash"
cat > "$T/test.mk" <<'MK'
BUILD := build
.DEFAULT_GOAL := host
include $(S2A_BUILD_TEST_ROOT)/services/build.mk
.PHONY: ios host ios-ns2pro ios-vamm-check
ios:
	@printf '%s\n' '$(IOS_LIBS)' > /dev/null
host:
	@printf '%s\n' '$(HOST_LIBS)' > /dev/null
ios-ns2pro ios-vamm-check:
	@true
MK
export PATH="$T/bin:$PATH" S2A_BUILD_TEST_ROOT="$R" S2A_BUILD_TEST_CALLS="$T/calls"
check() {
  local mac=$1 ios=$2; shift 2
  : > "$T/calls"
  make -s -C "$T" -f test.mk S2A_CS=1 "$@"
  if [ "$mac" = yes ]; then grep -q 'osx-arm64' "$T/calls"; else ! grep -q 'osx-arm64' "$T/calls"; fi
  if [ "$ios" = yes ]; then grep -q 'ios-arm64' "$T/calls"; else ! grep -q 'ios-arm64' "$T/calls"; fi
}
check no yes ios
check no no ios-ns2pro ios-vamm-check
check yes no host
check yes no
check yes yes ios host
echo 'Service build target regression checks passed.'
