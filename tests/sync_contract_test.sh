#!/bin/bash
# 门禁覆盖：graphics/nvn/gfx/nvn/nvn_obj.h
# Linux pthread regression: actual production header; no Metal or device claim.
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
CC=${CC:-clang}
INC="$H/graphics/nvn/gfx/nvn"
compile() {
  "$CC" -std=c11 -D_XOPEN_SOURCE=700 -O2 -Wall -Wextra -Werror -pthread \
    -I "$1" -I "$INC" -I "$INC/include" "${@:3}" "$H/tests/sync_contract_litmus.c" -o "$2"
}
compile "$INC" "$T/positive"
"$T/positive"
# Mutation is confined to an isolated copy; production files are never modified.
python3 - "$INC/nvn_obj.h" "$T" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
root = pathlib.Path(sys.argv[2])
old = '''    __atomic_store_n(&s->fence, fence, __ATOMIC_RELAXED);
    __atomic_store_n(&s->ext_ev, ev, __ATOMIC_RELAXED); __atomic_store_n(&s->ext_val, v, __ATOMIC_RELAXED);
    __atomic_store_n(&s->fenced, 1u, __ATOMIC_RELEASE);'''
assert source.count(old) == 1, 'production helper changed; review controls'
mutations = {
    'old_order': '''    __atomic_store_n(&s->fenced, 1u, __ATOMIC_RELEASE);
    old_order_pause();
    __atomic_store_n(&s->fence, fence, __ATOMIC_RELAXED);
    __atomic_store_n(&s->ext_ev, ev, __ATOMIC_RELAXED); __atomic_store_n(&s->ext_val, v, __ATOMIC_RELAXED);''',
    'drop_zero': '    if (!fence) return;\n' + old,
    'first_only': '    if (__atomic_load_n(&s->fenced, __ATOMIC_ACQUIRE)) return;\n' + old,
}
for name, replacement in mutations.items():
    d = root / name
    d.mkdir()
    (d / 'nvn_obj.h').write_text(source.replace(old, replacement))
PY
for control in old_order drop_zero first_only; do
  flags=()
  [ "$control" != old_order ] || flags=(-DSYNC_CONTRACT_OLD_ORDER)
  compile "$T/$control" "$T/$control.bin" ${flags[@]+"${flags[@]}"}
  set +e
  "$T/$control.bin" > "$T/$control.log" 2>&1
  rc=$?
  set -e
  [ "$rc" = 1 ] || { cat "$T/$control.log"; echo "FAIL: $control expected assertion exit 1, got $rc"; exit 1; }
  case "$control" in
    old_order) expected='first publication must not expose unwritten zero';;
    *) expected='serialized publication including zero and decreasing values';;
  esac
  grep -Fx "FAIL: $expected" "$T/$control.log"
  echo "PASS: negative $control rejected by expected assertion (exit 1)"
done
