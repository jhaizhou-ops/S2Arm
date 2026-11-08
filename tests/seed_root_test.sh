#!/bin/bash
# Generated text fixtures only: no game, keys, firmware or player caches.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
export S2A_ROOTS=$T/roots S2A_ROOTS_SHARED=$T/shared S2A_ROOTS_NO_BOOT=1
mkdir -p "$S2A_ROOTS" "$S2A_ROOTS_SHARED" "$T/source/exefs" "$T/source/romfs" "$T/source/ctl" "$T/source/aoc/1"
printf 'program' > "$T/source/exefs/main"; printf 'resource' > "$T/source/romfs/data"
printf 'control' > "$T/source/ctl/control.nacp"; printf 'fixture DLC' > "$T/source/aoc/1/data"
printf 'idx\ttitle_id\tversion\tfiles\tbytes\n1\t0000000000001001\t0\t1\t11\n' > "$T/source/aoc.tsv"
source "$R/pack/roots.sh"
# Default seeding must retain the previous layout, even with DLC inputs present.
unset S2A_SEED_AOC
bash "$R/pack/seed_root.sh" fixture default "$T/source" > /dev/null
current=$(root_cur fixture)
[ ! -e "$current/aoc" ] && [ ! -e "$current/aoc.tsv" ]
# Explicit private-root opt-in carries the index and matching cloned content.
S2A_SEED_AOC=1 bash "$R/pack/seed_root.sh" fixture opted-in "$T/source" > /dev/null
current=$(root_cur fixture)
cmp "$T/source/aoc.tsv" "$current/aoc.tsv"
printf 'changed clone' > "$current/aoc/1/data"
[ "$(cat "$T/source/aoc/1/data")" = 'fixture DLC' ]
# The dedicated aoc stage's existing replacement/replay contract still wins.
W=$(root_begin fixture dedicated)
rm -rf "$W/aoc"; mkdir -p "$W/aoc/2"; printf replacement > "$W/aoc/2/data"
printf 'idx\ttitle_id\tversion\tfiles\tbytes\n' > "$W/aoc.tsv"
printf dedicated > "$W/.stage_aoc"
ROOT_REPLAY='aoc aoc.tsv .stage_aoc' root_commit fixture dedicated
current=$(root_cur fixture)
[ -f "$current/aoc/2/data" ] && [ ! -e "$current/aoc/1" ]
# Root cloning/publication and package verification handle the extra index.
W=$(root_begin fixture copied); root_commit fixture copied
current=$(root_cur fixture)
python3 "$R/pack/pack.py" "$T/pack" aoc="$current/aoc" aoc.tsv="$current/aoc.tsv" > /dev/null
python3 "$R/pack/verify.py" "$T/pack" aoc="$current/aoc" aoc.tsv="$current/aoc.tsv" > /dev/null
[ -f "$current/aoc.tsv" ] && [ -f "$T/source/aoc.tsv" ]
[ ! -d "$S2A_ROOTS/fixture@default" ]
# 开关打开再播一次，现行里先放好追加内容阶段的产物：.stage_aoc / aoc.log 清掉、aoc.tsv 是源的（stage_aoc 才会按原始包重建，不混搭）
current=$(root_cur fixture); printf stale > "$current/.stage_aoc"; printf log > "$current/aoc.log"; printf 'idx\n' > "$current/aoc.tsv"
S2A_SEED_AOC=1 bash "$R/pack/seed_root.sh" fixture reseed "$T/source" > /dev/null
current=$(root_cur fixture)
{ [ ! -e "$current/.stage_aoc" ] && [ ! -e "$current/aoc.log" ] && cmp -s "$T/source/aoc.tsv" "$current/aoc.tsv" && [ -f "$current/aoc/1/data" ] && [ ! -e "$current/aoc/2" ]; } || { echo "重播追加内容没清旧阶段键 / 产物" >&2; exit 1; }
# #459：只出通用（S2A_DUAL=0）播种也带解包元数据 unpack.tsv（程序号 / 名称 / 版本），直连推导输入不带；旧根里的过期 unpack.tsv 不留
printf 'title_id\t0100aaaa00000000\n' > "$T/source/unpack.tsv"; printf '{}' > "$T/source/direct-profile-input.json"
S2A_DUAL=0 bash "$R/pack/seed_root.sh" fixture generic "$T/source" > /dev/null
current=$(root_cur fixture)
{ cmp -s "$T/source/unpack.tsv" "$current/unpack.tsv" && [ ! -e "$current/direct-profile-input.json" ]; } || { echo "只出通用播种没带 unpack.tsv（或带了直连推导输入）" >&2; exit 1; }
rm "$T/source/unpack.tsv"; S2A_DUAL=0 bash "$R/pack/seed_root.sh" fixture generic2 "$T/source" > /dev/null
[ ! -e "$(root_cur fixture)/unpack.tsv" ] || { echo "源里没有 unpack.tsv，旧根的却留下了" >&2; exit 1; }
# #1233 P1-45: reseeding unchanged main plus changed subsdk/NRO must not inherit rewrite products.
W=$(root_begin fixture stale-rewrite)
rewrite_products=(.stage_rewrite .stage_rewrite.deps main.patched.bin subsdk0.patched.bin nro0.patched.bin main.fixups.tsv main.gates.tsv main.sites.tsv main.gaps.tsv nro_modules.tsv)
for name in "${rewrite_products[@]}"; do printf stale > "$W/$name"; done
printf keep > "$W/.stage_sysdata"
root_commit fixture stale-rewrite
previous=$(root_cur fixture)
printf module-B > "$T/source/exefs/subsdk0"
mkdir -p "$T/source/romfs/deep"; printf nro-B > "$T/source/romfs/deep/plugin.nro"
bash "$R/pack/seed_root.sh" fixture changed-modules "$T/source" > /dev/null
current=$(root_cur fixture)
remaining=0
for name in "${rewrite_products[@]}"; do
  if [ -e "$current/$name" ]; then echo "不通 重播仍继承改写产物 ${name}" >&2; remaining=$((remaining + 1)); fi
done
[ "$remaining" = 0 ] || exit 1
cmp "$T/source/exefs/main" "$current/exefs/main"
cmp "$T/source/exefs/subsdk0" "$current/exefs/subsdk0"
cmp "$T/source/romfs/deep/plugin.nro" "$current/romfs/deep/plugin.nro"
[ "$(cat "$current/.stage_sysdata")" = keep ]
[ -f "$previous/main.patched.bin" ]
echo "seed_rewrite_invalidation: ${#rewrite_products[@]} stale paths removed; raw source, unrelated stage and previous root preserved"

# 清旧补丁失败时必须中止新版，不能把错误当成功发布原始输入与旧补丁的混合根。
W=$(root_begin fixture cleanup-before)
printf stale > "$W/main.patched.bin"; printf stale > "$W/.stage_rewrite"
root_commit fixture cleanup-before
before_failure=$(root_cur fixture)
mkdir -p "$T/deny-rm"
REAL_RM=$(command -v rm)
cat > "$T/deny-rm/rm" <<'RM'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in */.stage_rewrite) echo injected > "$S2A_TEST_CLEANUP_TRACE"; exit 7;; esac
done
exec "$S2A_TEST_REAL_RM" "$@"
RM
chmod +x "$T/deny-rm/rm"
if PATH="$T/deny-rm:$PATH" S2A_TEST_REAL_RM="$REAL_RM" S2A_TEST_CLEANUP_TRACE="$T/cleanup-trace"     bash "$R/pack/seed_root.sh" fixture cleanup-fails "$T/source" > "$T/cleanup-failure.log" 2>&1; then
  [ ! -f "$T/cleanup-trace" ] || echo '已触发真实子进程 rm 失败桩（退出7）' >&2
  echo '不通：清理失败仍返回成功并发布新版' >&2; exit 1
fi
[ -f "$T/cleanup-trace" ]
[ "$(root_cur fixture)" = "$before_failure" ]
[ -f "$before_failure/main.patched.bin" ]
failed_transaction=$(_root_dir fixture cleanup-fails)
[ ! -e "${failed_transaction}.tmp" ]
echo 'seed_cleanup_failure: rm7 -> seed1, previous current root retained and new transaction aborted'

# 11-04 c1104_r2 超级马力欧兄弟 惊奇：提交后版本目录被并发的另一个出包（停批没停干净的旧 one_game 收尾 rm -rf 工作目录）删掉，
#   现行软链悬空、root_cur 取到空串，seed_root 照样打「🟢 … 产物根 → ：」退 0，一键出包往下刷新才报「没有现行产物根」。
#   用 S2A_PYTHON 桩在 root_commit 发布资源键那一步（版本已改名、现行还没切）删掉刚提交的版本目录，模拟并发删根。
#   期望（手写，不跑被测实现）：退出非 0、有【红】行、没有 🟢 行
mkdir -p "$T/del-root"
cat > "$T/del-root/py" <<'PY'
#!/bin/bash
[ "${2:-}" = --root-publish ] && { chmod -R u+w "$3"; rm -rf "$3"; }
exit 0
PY
chmod +x "$T/del-root/py"
: > "$T/key-once"
if S2A_PYTHON="$T/del-root/py" S2A_RESOURCE_KEY_ONCE_FILE="$T/key-once" bash "$R/pack/seed_root.sh" fixture deleted-after-commit "$T/source" > "$T/deleted.log" 2>&1; then
  echo "不通：提交后现行解析不出仍退 0（$(tail -1 "$T/deleted.log")）" >&2; exit 1
fi
grep -q '【红】' "$T/deleted.log" || { echo "不通：现行解析不出没打【红】行（$(tail -1 "$T/deleted.log")）" >&2; exit 1; }
! grep -q '🟢' "$T/deleted.log" || { echo "不通：现行解析不出仍打 🟢（$(grep '🟢' "$T/deleted.log")）" >&2; exit 1; }
echo 'seed_current_missing: 提交后版本被删 -> 退非0 + 【红】，无 🟢'

echo 'Seed default layout, explicit DLC cloning, stage replacement, retention and packaging passed'
