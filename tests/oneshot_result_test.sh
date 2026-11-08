#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：tools/oneshot.sh
# 完整生产脚本 + 私有假根/外部命令桩；不连设备、不改 HOME、不等真实的1500秒。
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=${S2A_ONESHOT_SCRIPT:-$H/tools/oneshot.sh}
[ -f "$SCRIPT" ] || { echo '不通：找不到被测 oneshot 脚本'; exit 1; }
TIMEOUT=$(command -v timeout) || { echo '不通：缺 timeout'; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root/tools" "$TMP/root/pack" "$TMP/bin"
cp "$SCRIPT" "$TMP/root/tools/oneshot.sh"
printf ':\n' > "$TMP/root/tools/machine.sh"
cat > "$TMP/root/tools/devices.sh" <<'EOF'
s2a_device() { SW_IOS_UDID=synthetic-device; }
EOF
for file in seed_root.sh stage_rewrite.sh stage_sysdata.sh stage_uilayout.sh stage_romfsidx.sh stage_shaders.sh ipa.sh refresh.sh; do
  cat > "$TMP/root/pack/$file" <<'EOF'
#!/bin/bash
printf '%s\n' "${0##*/}" >> "$S2A_ONESHOT_TEST_DIR/trace"
[ "${0##*/}" != seed_root.sh ] || [ "$S2A_ONESHOT_MODE" != seed_fail ] || exit 7
# 照真链路转调（P1-53）：ipa.sh 刷新产物根 → refresh.sh 跑 RomFS 索引与着色器阶段
case ${0##*/} in
  ipa.sh) bash "${0%/*}/refresh.sh" "$1" || exit 1;;
  refresh.sh) for s in romfsidx shaders; do bash "${0%/*}/stage_$s.sh" "$1" || exit 1; done;;
esac
echo '合成阶段完成'
EOF
done
# 桩的转调关系必须与真脚本一致，否则「着色器只做一次」的断言就是空转
/usr/bin/grep -q 'bash "$H/refresh.sh" "$G"' "$H/pack/ipa.sh" || { echo '不通：pack/ipa.sh 不再调 refresh.sh，桩链路过时'; exit 1; }
/usr/bin/grep -q 'stage_shaders.sh' "$H/pack/refresh.sh" || { echo '不通：pack/refresh.sh 不再调着色器阶段，桩链路过时'; exit 1; }
cat > "$TMP/root/tools/sched.sh" <<'EOF'
#!/bin/bash
printf 'sched:%s\n' "$1" >> "$S2A_ONESHOT_TEST_DIR/trace"
case $1 in
  status) printf '登记：\n fixture 012345678 \n最近：\n';;
  submit) echo '合成已入队';;
  once)
    case $S2A_ONESHOT_MODE in no_job) exit 0;; once_fail) exit 4;; esac
    mkdir -p "$S2A_ONESHOT_TEST_DIR/jobs/fixture_current"
    echo 'os0101120000' > "$S2A_ONESHOT_TEST_DIR/jobs/fixture_current.job"
    if [ "$S2A_ONESHOT_MODE" != missing_file ]; then
      printf '%s\n' "$S2A_ONESHOT_RESULT" > "$S2A_ONESHOT_TEST_DIR/jobs/fixture_current/r.txt"
    fi
    ;;
  *) echo '不通：意外调度命令'; exit 97;;
esac
EOF
cat > "$TMP/bin/date" <<'EOF'
#!/bin/bash
echo 0101120000
EOF
cat > "$TMP/bin/git" <<'EOF'
#!/bin/bash
case "$*" in *rev-parse*) echo 012345678;; *) exit 97;; esac
EOF
cat > "$TMP/bin/ideviceinfo" <<'EOF'
#!/bin/bash
printf 'ideviceinfo\n' >> "$S2A_ONESHOT_TEST_DIR/trace"
case "$*" in *ProductVersion*) echo 27.0;; *ProductType*) :;; *) exit 97;; esac
EOF
cat > "$TMP/bin/ssh" <<'EOF'
#!/bin/bash
echo '不通：夹具不允许远端连接' >&2
exit 97
EOF
# 只重定向生产脚本的作业发现 I/O 到合成目录，其他 grep 真正执行。
# sleep 的虚拟等待仅跳过超时墙钟；生产判断、输入文件和退出码原样运行。
cat > "$TMP/mock-env" <<'EOF'
sleep() { SECONDS=$((SECONDS + 1501)); }
timeout() { shift; "$@"; }
grep() {
  if [ "${1:-}" = -l ] && [ "$#" = 3 ] && [[ "$3" == "$HOME/.s2arm/run/s2arm/sched/jobs/"* ]]; then
    /usr/bin/grep -l "$2" "$S2A_ONESHOT_TEST_DIR/jobs/"*.job
  else
    /usr/bin/grep "$@"
  fi
}
EOF
chmod +x "$TMP/bin/"*
count=0; failed=0
run_case() {
  local name=$1 mode=$2 expected=$3 result=$4 casedir rc
  count=$((count + 1)); casedir=$TMP/case$count; mkdir -p "$casedir/jobs"
  # 60 秒只防挂死：每例要起完整 oneshot.sh + 7 个阶段桩，本机约 0.4 秒；11-01 无缓存实跑 321 支同跑、mini 满载时一例超过原 10 秒，退出 124 判红
  "$TIMEOUT" 60 env PATH="$TMP/bin:$PATH" BASH_ENV="$TMP/mock-env" \
    S2A_ONESHOT_TEST_DIR="$casedir" S2A_ONESHOT_MODE="$mode" S2A_ONESHOT_RESULT="$result" \
    bash "$TMP/root/tools/oneshot.sh" fixture "$casedir/input" --device=1 > "$casedir/output" 2>&1
  rc=$?
  if [ "$rc" != "$expected" ]; then
    echo "不通：${name} 期望退出${expected} 实际${rc}"
    failed=$((failed + 1))
  elif [ "$mode" != seed_fail ] && ! /usr/bin/grep -q '^sched:once$' "$casedir/trace"; then
    echo "不通：${name} 未执行实际调度桩，不能算结果路径验证"
    failed=$((failed + 1))
  elif [ "$mode" != seed_fail ] && [ "$(/usr/bin/grep -c '^stage_shaders.sh$' "$casedir/trace")" != 1 ]; then
    # P1-53：着色器阶段整条只许出现一次（只经 ipa.sh 的刷新）；oneshot 自己预跑全量烘焙会被直连刷新的懒路径删掉，白做几十分钟
    echo "不通：${name} 着色器阶段跑了 $(/usr/bin/grep -c '^stage_shaders.sh$' "$casedir/trace") 次（应只经出包刷新 1 次）"
    failed=$((failed + 1))
  else
    echo "通：${name} 退出${rc}"
  fi
  if [ "$rc" = 124 ] || [ "$rc" = 137 ] || [ "$rc" = 97 ]; then
    echo "夹具基础设施失败：${name}（${rc}）"
  fi
}
run_case 无本次作业 no_job 1 ''
run_case 派发失败且无作业 once_fail 1 ''
run_case 有作业无结果文件 missing_file 1 ''
run_case 空结果文件 result 1 ''
run_case 结果文件缺结论行 result 1 '仍在等待，尚无结论'
for verdict in red suspect skip lock install push deployed smoke-ok smoke unknown done-extra donebad; do
  run_case "拒绝${verdict}" result 1 "RESULT=$verdict out=synthetic"
done
run_case 非行首的伪结论 result 1 'prefix RESULT=done out=synthetic'
run_case 成功后以失败收尾 result 1 $'RESULT=done out=synthetic\nRESULT=red out=synthetic'
run_case 失败说明含成功字样 result 1 'RESULT=red reason=RESULT=done'
run_case 完整成功结论 result 0 'RESULT=done out=synthetic'
run_case 成功结论无附加字段 result 0 'RESULT=done'
run_case 失败后最终成功 result 0 $'RESULT=red out=synthetic\nRESULT=done out=synthetic'
run_case 原播种失败仍失败 seed_fail 1 'RESULT=done out=synthetic'
printf 'oneshot_result: %d cases, %d failed\n' "$count" "$failed"
[ "$failed" = 0 ]
