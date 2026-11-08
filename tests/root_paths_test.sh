#!/bin/bash
# First-run and symlink aliases must preserve pack/roots.sh shared-write guard.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
source "$R/pack/roots.sh"
expect() {
  local expected=$1 actual=1; shift
  if ( S2A_ROOTS=$1 S2A_ROOTS_SHARED=$2; _root_shared ); then actual=0; fi
  [ "$actual" = "$expected" ] || { echo "Unexpected root classification: $* ($actual)" >&2; exit 1; }
}
# Both absent: different paths must stay private, the same path stays guarded.
expect 1 "$T/private/new" "$T/shared/new"
expect 0 "$T/shared/new" "$T/shared/new"
mkdir -p "$T/physical" "$T/other"
ln -s "$T/physical" "$T/alias"
expect 0 "$T/alias" "$T/physical"
expect 0 "$T/alias/not-yet-created" "$T/physical/not-yet-created"
expect 1 "$T/physical" "$T/other"
# Relative links, absent targets and .. after a symlink resolve physically.
ln -s physical/not-yet-created "$T/dangling"
expect 0 "$T/dangling" "$T/physical/not-yet-created"
expect 0 "$T/alias/../shared/new" "$T/shared/new"
( cd "$T"; expect 0 alias/new physical/new )
# A cycle must not bypass the guard or hang.
ln -s loop "$T/loop"
expect 0 "$T/loop" "$T/shared"
# The frequent predicate needs no Python process.
( python3() { echo 'unexpected Python invocation' >&2; return 99; }
  S2A_ROOTS=$T/alias/new S2A_ROOTS_SHARED=$T/physical/new _root_shared )
# 包身份（pack/ipa.sh：共享 = 正式 io.s2arm.<款>，私有 = 实验 io.s2arm-exp.<款>；10-21 实验包冒充正式身份覆盖过测试机正式 App）。测试出包线 10-23 要求逐格写死（0 = 共享）：
#   S2A_ROOTS 不设（缺省 = 共享目录，存在）→ 0；共享目录不存在、S2A_ROOTS 不设 → 0（缺省配置即共享，两边同一路径）；
#   指向共享目录的软链 / 尾斜杠 / 含 .. → 0；存在的私有目录 → 1；不存在的私有目录 → 1
mkdir -p "$T/id/shared" "$T/id/priv"; ln -s "$T/id/shared" "$T/id/shlink"
dflt() { ( unset S2A_ROOTS; S2A_ROOTS_SHARED=$1; source "$R/pack/roots.sh"; _root_shared ) && echo 0 || echo 1; }
[ "$(dflt "$T/id/shared")" = 0 ] || { echo "包身份：不设 S2A_ROOTS 应为共享" >&2; exit 1; }
[ "$(dflt "$T/id/noshared")" = 0 ] || { echo "包身份：共享目录不存在且不设 应为共享" >&2; exit 1; }
expect 0 "$T/id/shlink" "$T/id/shared"
expect 0 "$T/id/shared/" "$T/id/shared"
expect 0 "$T/id/priv/../shared" "$T/id/shared"
expect 1 "$T/id/priv" "$T/id/shared"
expect 1 "$T/id/priv2" "$T/id/shared"
# 守卫与包身份安全方向相反（测试出包线 10-23）：循环软链 → 守卫判共享（0）、包身份判实验（1）；
#   悬空软链能解析出目标路径，按目标算：指向共享根 → 两个都共享，指向别处 → 两个都私有
ident() { ( S2A_ROOTS=$1 S2A_ROOTS_SHARED=$2; _root_identity_shared ) && echo 0 || echo 1; }
expect 0 "$T/loop" "$T/id/shared"; [ "$(ident "$T/loop" "$T/id/shared")" = 1 ] || { echo "包身份：循环软链应判实验" >&2; exit 1; }
ln -s "$T/id/shared/later" "$T/id/dang_sh"; ln -s "$T/id/elsewhere" "$T/id/dang_x"
expect 0 "$T/id/dang_sh" "$T/id/shared/later"; [ "$(ident "$T/id/dang_sh" "$T/id/shared/later")" = 0 ] || { echo "包身份：悬空软链指向共享根应判共享" >&2; exit 1; }
expect 1 "$T/id/dang_x" "$T/id/shared"; [ "$(ident "$T/id/dang_x" "$T/id/shared")" = 1 ] || { echo "包身份：悬空软链指向别处应判实验" >&2; exit 1; }
for c in "$T/id/shlink:$T/id/shared:0" "$T/id/shared/:$T/id/shared:0" "$T/id/priv/../shared:$T/id/shared:0" "$T/id/priv:$T/id/shared:1" "$T/id/priv2:$T/id/shared:1"; do
  IFS=: read -r a b w <<< "$c"; [ "$(ident "$a" "$b")" = "$w" ] || { echo "包身份：$a 对 $b 应为 $w" >&2; exit 1; }
done
echo 'Root classification: first-run paths, physical aliases, dangling links and cycles passed'
