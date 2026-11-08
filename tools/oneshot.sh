#!/bin/bash
# 一条命令：原始游戏文件 → 装进手机跑到 MARK（全新状态，逐段计时）：tools/oneshot.sh <款> <原始游戏数据目录> [--device=1|2] [--act=秒]
#   例：tools/oneshot.sh acnh ~/.s2arm/data/acnh --device=2
# 全新状态 = 新建私有产物根（不从共享现行克隆）：播种 → 改写 ‖ 系统数据 ‖ 宽屏布局（并行）→ 出包（ipa.sh 内 refresh.sh 补齐其余阶段：能力清单 → 直连配置 → RomFS 索引 → 抽取 → 直连库 → 着色器；再编 iOS + 资源包）→ 登记 → 测试机冷局跑到 MARK。
# 产物根放 ~/.s2arm/run/s2arm/roots_priv/oneshot_<时刻>（gc 24 小时没动就清）；本树须干净（出包核提交号）。各段一行「段 秒 结果」，末行总用时。
# 不算「全新」的部分照实写：各工具自己的编译缓存（C# / NativeAOT / metal .air）缺省不清——那是开发机常驻缓存，玩家侧没有这一步；
#   要量「全新首次」：在新工作树里跑，并把 S2A_CS_CACHE / S2A_VPX_CACHE 指到空目录（整机缓存不动）。
set -u
G=${1:?款}; SRC=${2:?原始游戏数据目录}; shift 2; DEV=2; ACT=120
for a in "$@"; do case $a in --device=*) DEV=${a#*=};; --act=*) ACT=${a#*=};; esac; done
H=$(cd "$(dirname "$0")/.." && pwd); . "$H/tools/machine.sh"; TS=$(date +%m%d%H%M%S)
export S2A_ROOTS=$HOME/.s2arm/run/s2arm/roots_priv/oneshot_$TS S2A_ROOTS_NO_BOOT=1
# 管线归档只出目标机那一个系统大版本（帧率能耗线 8272445：GPU 二进制绑系统大版本，全版本会让管线段翻倍）：读目标机 ProductVersion 传 S2A_PSO_OS
UD=$(S2A_DEVICE_NO_USB_CHECK=1 bash -c "source '$H/tools/devices.sh'; s2a_device $DEV > /dev/null 2>&1 && echo \$SW_IOS_UDID")
if [ "$DEV" = 1 ]; then PV=$(ideviceinfo -u "$UD" -k ProductVersion 2>/dev/null); else PV=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "${S2A_MINI:-${S2A_MINI_DEFAULT:-}}" "PATH=/opt/homebrew/bin:\$PATH ideviceinfo -u $(printf %q "$UD") -k ProductVersion" 2>/dev/null); fi
[ -n "$PV" ] && export S2A_PSO_OS=${PV%%.*} || echo "【黄】读不到测试机${DEV}的系统版本，管线归档按 shader_pack 缺省（本机最新 SDK 大版本）"
# GPU 架构同理（总指挥 10-23：归档 / 函数体动态库按架构出，对不上整份不命中）：读机型号，查所用 Xcode 自带的设备特征库（pack/jobs/target.py）
if [ "$DEV" = 1 ]; then PT=$(ideviceinfo -u "$UD" -k ProductType 2>/dev/null); else PT=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "${S2A_MINI:-${S2A_MINI_DEFAULT:-}}" "PATH=/opt/homebrew/bin:\$PATH ideviceinfo -u $(printf %q "$UD") -k ProductType" 2>/dev/null); fi
GA=; [ -z "$PT" ] || GA=$(DEVELOPER_DIR=${S2A_DEVELOPER_DIR:-$(xcode-select -p)} python3 "$H/pack/jobs/target.py" arch "$PT" 2>&1) || { echo "【红】${PT}：${GA}"; exit 1; }
[ -n "$GA" ] && export S2A_PSO_ARCHS=$GA || echo "【黄】读不到测试机${DEV}的机型号，GPU 架构按 shader_pack 缺省（applegpu_g18p）"
T0=$SECONDS; SUM=
step() { local name=$1; shift; local s0=$SECONDS out rc; out=$("$@" 2>&1); rc=$?
  printf '%-14s %4d 秒  %s\n' "$name" $((SECONDS - s0)) "$(echo "$out" | tail -1 | cut -c1-160)"; SUM="$SUM $name=$((SECONDS - s0))"
  [ $rc = 0 ] || { echo "🔴 停在「${name}」（rc=${rc}）；产物根 $S2A_ROOTS"; exit 1; }; }
echo "一条命令：$G 从 $SRC 起（本树 $(git -C "$H" rev-parse --short HEAD)，产物根 ${S2A_ROOTS}，目标测试机${DEV} iOS ${PV:-?} ${PT:-?} ${GA:-?}）"
step 播种 bash "$H/pack/seed_root.sh" "$G" "seed$TS" "$SRC"
par3() {   # 改写 ‖ 系统数据 ‖ 界面布局并行（同 pack/refresh.sh：产物互不重叠，提交冲突按 ROOT_REPLAY 重放）
  local L s rc=0; L=$(mktemp -d); for s in rewrite sysdata uilayout; do ( bash "$H/pack/stage_$s.sh" "$G" > "$L/$s" 2>&1; echo $? > "$L/$s.rc" ) & done; wait
  for s in rewrite sysdata uilayout; do echo "${s}：$(tail -1 "$L/$s" | cut -c1-60)"; [ "$(cat "$L/$s.rc")" = 0 ] || rc=1; done | tr '\n' ' '; for s in rewrite sysdata uilayout; do [ "$(cat "$L/$s.rc")" = 0 ] || rc=1; done; rm -rf "$L"; return $rc; }
step 改写‖系统‖布局 par3
# RomFS 索引与着色器不在这里单独预跑（审计 P1-53）：ipa.sh 里的 refresh.sh 按依赖顺序一次做完；这里先跑全量烘焙，直连刷新的懒路径会把非 direct 产物删掉，白做几十分钟
step 出包 bash "$H/pack/ipa.sh" "$G" --register
step 登记核对 bash -c "bash '$H/tools/sched.sh' status | sed -n '/^登记：/,/^最近：/p' | grep ' $G ' | grep -q ' $(git -C "$H" rev-parse --short=9 HEAD) ' && echo 登记 = 本树提交"
step 入队 env MERGE_OWNER=测试出包 bash "$H/tools/sched.sh" submit "$G" --mode=cold --device="$DEV" --act="$ACT" "一条命令全流程 os$TS"
# 派出后等局结束（once 对远端设备派完即返回）：按作业目录里的结论行判，墙钟上限 1500 秒
s0=$SECONDS; JF=
while [ -z "$JF" ] && [ $((SECONDS - s0)) -lt 1500 ]; do   # 设备被别的局占着时 once 一个都不派、立即返回：反复派到认出本次作业为止（按标签认，同款别的线的局可能同时在跑）
  timeout 1500 bash "$H/tools/sched.sh" once > /dev/null 2>&1
  JF=$(grep -l "os$TS" "$HOME/.s2arm/run/s2arm/sched/jobs/${G}_"*.job 2>/dev/null | head -1); [ -n "$JF" ] || sleep 15
done
[ -n "$JF" ] || { echo "🔴 没有派出本次装机跑局作业（os${TS}），不能当成成功"; exit 1; }
J=${JF%.job}/
for i in $(seq 1 150); do grep -q '^RESULT=' "${J}r.txt" 2>/dev/null && break; sleep 10; done
r=$(grep -a '^RESULT=' "${J}r.txt" 2>/dev/null | tail -1 | cut -c1-200); mk=$(grep -a '用时' "${J}r.txt" 2>/dev/null | tail -1 | sed 's/.*= //')
printf '%-14s %4d 秒  %s\n' 装机跑局 $((SECONDS - s0)) "${r:-没有结论行}"; SUM="$SUM 装机跑局=$((SECONDS - s0))"
echo "装机跑局拆账（取锁等待 / 装包 / 推送 / 起局到首帧 / 首帧到 MARK / MARK 到收局 / 拉回 / 合计）：${mk:-无}"
echo "总用时 $((SECONDS - T0)) 秒（${SUM# }）；局目录 ${J}"
# dev_run.sh 的成功终态只有 done；跳过、冒烟、只部署或未知值都不等于本条冷局成功。
case "$r" in
  RESULT=done|RESULT=done\ *) ;;
  *) echo "🔴 装机跑局没有成功结论：${r:-没有结论行}"; exit 1;;
esac
