#!/bin/bash
# services/test.sh 的构建步骤：成败只看命令自己的退出码，输出筛选不改变成功状态（#414）。
# 用合成编译命令替身跑生产同一份 services/build_output.sh（不复制一份管道），覆盖 6 类受控输出 / 状态：
#   英文成功、中文成功、合法空输出成功、英文失败、中文失败诊断、无英文汇总的超时诊断。
# 每组都验三件事：最终退出码（失败要原码）、后续步骤是否真的继续（标记行）、诊断是否还在输出里。
# 只验纯宿主合成输出与退出码：不跑真实 dotnet 构建、不还原依赖、不装 timeout、不起游戏、不碰设备。
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fix" "$T/out"

# 合成编译命令替身：打印固定输出，按固定退出码退出（替代 dotnet build 的位置）
cat > "$T/bin/cc" <<'SH'
#!/bin/bash
name=${1:?}; shift
cat "${S2A_BUILD_CASE_DIR}/${name}.out"
exit "$(cat "${S2A_BUILD_CASE_DIR}/${name}.rc")"
SH
chmod +x "$T/bin/cc"
export S2A_BUILD_CASE_DIR="$T/fix"

put() { printf '%s' "$2" > "${S2A_BUILD_CASE_DIR}/$1.out"; printf '%s\n' "$3" > "${S2A_BUILD_CASE_DIR}/$1.rc"; }
put en_ok '  已成功生成 /x/S2A.Services.Tests.dll -> /x/bin/Release/net10.0/
    0 Error(s)

Time Elapsed 00:00:03.21' 0
put zh_ok '  已成功生成 /x/S2A.Services.Tests.dll -> /x/bin/Release/net10.0/
    0 个错误

已用时间 00:00:03.21' 0
put empty_ok '' 0
put en_fail '  /x/Foo.cs(12,5): error CS0103: 当前上下文中不存在名称 Foo
    1 Error(s)

Time Elapsed 00:00:01.04' 7
put zh_fail '  /x/Foo.cs(12,5): 错误 CS0103：当前上下文中不存在名称 Foo
    生成失败

已用时间 00:00:01.04' 42
put timeout '命令超时：240 秒内没有生成汇总
（没有英文汇总行）' 124

n=0; pass=0; fail=0
ck() {  # $1 = 0/1 是否通过，$2 = 用例名
  n=$((n + 1))
  if [ "$1" = 0 ]; then printf '通 %s\n' "$2"; pass=$((pass + 1)); else printf '红 %s\n' "$2"; fail=$((fail + 1)); fi
}
ckeq() { if [ "$1" = "$2" ]; then ck 0 "$3"; else ck 1 "$3"; fi; }          # $1 实际，$2 期望
ckhas() { if printf '%s\n' "$1" | grep -qF "$2"; then ck 0 "$3"; else ck 1 "$3"; fi; }
cknot() { if printf '%s\n' "$1" | grep -qF "$2"; then ck 1 "$3"; else ck 0 "$3"; fi; }

# 生产写法：set -euo pipefail 下「build_output.sh … || exit $?」，后面接一行继续执行标记
probe() {
  set -euo pipefail
  bash "$R/services/build_output.sh" run "$T/out/$1.log" "$T/bin/cc" "$1" || exit $?
  echo MARK
}

run_case() {  # $1 = 用例，$2 = 期望退出码，$3 = 期望有标记(yes/no)，$4 = 输出里必须出现的片段
  local name=$1 want_rc=$2 want_marker=$3 must=$4 out rc
  out=$(probe "$name" 2>&1) && rc=0 || rc=$?
  ckeq "$rc" "$want_rc" "${name}：最终退出码 ${want_rc}（实际 ${rc}）"
  if [ "$want_marker" = yes ]; then
    ckhas "$out" MARK "${name}：后续步骤继续执行"
  else
    cknot "$out" MARK "${name}：后续步骤不执行"
  fi
  if [ -n "$must" ]; then ckhas "$out" "$must" "${name}：输出保留「${must}」"; fi
}

run_case en_ok 0 yes '0 Error(s)'
run_case zh_ok 0 yes ''
run_case empty_ok 0 yes ''
run_case en_fail 7 no 'error CS0103'
run_case zh_fail 42 no '错误 CS0103'
run_case timeout 124 no '命令超时'

# 成功的三类不许打红（筛不出英文汇总 ≠ 失败）；失败的三类必须打出诊断标题
for name in en_ok zh_ok empty_ok; do
  out=$(probe "$name" 2>&1) || true
  cknot "$out" '🔴' "${name}：成功不打红标题"
done
for name in en_fail zh_fail timeout; do
  out=$(probe "$name" 2>&1) || true
  ckhas "$out" '🔴' "${name}：失败打出诊断标题"
done

# show 子命令：命令已跑完时复用同一套判定（原退出码与诊断一致）
out=$(bash "$R/services/build_output.sh" show 42 "${S2A_BUILD_CASE_DIR}/zh_fail.out" 2>&1) && rc=0 || rc=$?
ckeq "$rc" 42 "show：传入退出码原样返回（实际 ${rc}）"
ckhas "$out" '错误 CS0103' 'show：诊断转到输出'
out=$(bash "$R/services/build_output.sh" 2>&1) && rc=0 || rc=$?
ckeq "$rc" 2 "用法错误返回 2（实际 ${rc}）"

# 接线：services/test.sh 的构建步骤走这份判定，且不再把构建直接接进筛选管道
ckhas "$(cat "$R/services/test.sh")" 'build_output.sh" run' 'services/test.sh 构建步骤走 build_output.sh'
if grep -q 'build -c Release -nologo -v q 2>&1 | grep' "$R/services/test.sh"; then r=1; else r=0; fi
ck "$r" 'services/test.sh 不再把构建接进 grep 管道'

echo "services 构建输出：期望 ${n} 项全过 → 真结果 ${pass} 过 / ${fail} 红"
[ "$fail" = 0 ]
