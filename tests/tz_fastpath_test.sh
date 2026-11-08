#!/bin/bash
# 门禁覆盖：pack/stage_keys.sh tools/app_only.sh pack/stages/sysdata.sh
# 真实快道与阶段键入口；其余阶段及 IPA 构建用不含游戏数据的合成桩。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
R=$T/repo; mkdir -p "$R/tools" "$R/pack" "$T/roots/game@pkg-base" "$T/sched/pkgs" "$T/snapshot/pack" "$T/bin"
cp "$H/tools/app_only.sh" "$R/tools/"; cp "$H/pack/stage_keys.sh" "$R/pack/"
for s in rewrite caps uilayout aoc romfsidx shaders; do
  printf '#!/bin/bash\nprintf "%%s\\t%%s\\n" "%s" fixed >> "$S2A_STAGE_KEYS"\n' "$s" > "$R/pack/stage_$s.sh"
  printf 'fixed\n' > "$T/roots/game@pkg-base/.stage_$s"
done
printf '#!/bin/bash\nprintf "sysdata\\t%%s\\n" "$(cat "$S2A_FIXTURE_TZ_KEY")" >> "$S2A_STAGE_KEYS"\n' > "$R/pack/stage_sysdata.sh"
printf 'old-tz\n' > "$T/roots/game@pkg-base/.stage_sysdata"; printf 'new-tz\n' > "$T/tz-key"
printf old > "$T/snapshot/game.ipa"; printf old-resource > "$T/snapshot/pack/data"
printf 'COMMIT=base\nPKG=%q\n' "$T/snapshot" > "$T/sched/pkgs/game.env"
printf '#!/bin/bash\nmkdir -p "$S2A_APP_ONLY_OUT"; printf new > "$S2A_APP_ONLY_OUT/$1.ipa"; : > "$S2A_APP_ONLY_OUT/timing.tsv"; : > "$S2A_APP_ONLY_OUT/build.log"; echo fixture\n' > "$T/ipa"
chmod +x "$T/ipa"
if [ "$(uname -s)" = Linux ]; then
  cat > "$T/bin/cp" <<'COPY'
#!/bin/bash
args=(); for arg in "$@"; do case "$arg" in -c) ;; -cR) args+=(-R);; *) args+=("$arg");; esac; done
exec /bin/cp "${args[@]}"
COPY
  chmod +x "$T/bin/cp"; export PATH="$T/bin:$PATH"
fi
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@invalid
git -C "$R" init -q --template=; git -C "$R" add pack tools; git -C "$R" commit -qm fixture
export S2A_SCHED_DIR="$T/sched" S2A_ROOTS_SHARED="$T/roots" S2A_APP_ONLY_DIR="$T/out" S2A_APP_ONLY_IPA="$T/ipa" S2A_FIXTURE_TZ_KEY="$T/tz-key"
rc=0; bash "$R/tools/app_only.sh" game > "$T/changed.log" 2>&1 || rc=$?
if [ "$rc" != 3 ] || ! grep -q sysdata "$T/changed.log"; then
  echo "不通：tzdata 来源变化后 app-only 未拒绝旧资源（rc=${rc}，期望 3）"; exit 1
fi
printf 'old-tz\n' > "$T/tz-key"
bash "$R/tools/app_only.sh" game > "$T/same.log" 2>&1
rev=$(git -C "$R" rev-parse --short=9 HEAD)
[ "$(cat "$T/out/game-$rev/pkg/pack/data")" = old-resource ]
echo '通：tzdata 来源变化拒绝旧资源；来源不变复用'
# 主线新增 caps 阶段必须仍参与快道，且与时区键同时存在。
printf 'old-caps\n' > "$T/roots/game@pkg-base/.stage_caps"
rc=0; bash "$R/tools/app_only.sh" game > "$T/caps-changed.log" 2>&1 || rc=$?
if [ "$rc" != 3 ] || ! grep -q caps "$T/caps-changed.log"; then
  echo "不通：caps 阶段键变化后 app-only 未拒绝旧资源（rc=${rc}，期望 3）"; exit 1
fi
printf 'fixed\n' > "$T/roots/game@pkg-base/.stage_caps"
echo '通：caps 与 sysdata 阶段键同时参与快道'
# 只算键的 sysdata 阶段若无输出也必须失败，不能只靠其退出码放行旧资源。
printf '#!/bin/bash\nexit 0\n' > "$R/pack/stage_sysdata.sh"
rc=0; bash "$R/tools/app_only.sh" game > "$T/missing-key.log" 2>&1 || rc=$?
if [ "$rc" = 0 ] || ! grep -q '算阶段键失败' "$T/missing-key.log"; then
  echo "不通：系统数据键缺失时快道未拒绝（rc=${rc}）"; exit 1
fi
echo '通：系统数据阶段无键时拒绝复用'
