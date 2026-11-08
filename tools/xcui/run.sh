#!/bin/bash
# 真机交互运行器：bash tools/xcui/run.sh <设备 UDID> <计划.json> [输出目录]
#   生成工程（xcodegen，build/xcui，不入库）→ 自动签名构建 → 装到设备 → 照计划附着 App 点按（计划格式见 Runner/Plan.swift）。
#   签名团队：S2A_XCUI_TEAM，没给就取 Xcode 里登录的第一个付费团队（免费团队 7 天过期、装机数有限，不用）。
#   工具链：S2A_DEVELOPER_DIR（与出包同一个 Xcode；设备系统版本新时要用新 Xcode）。
#   只点不判：判据看宿主日志 / devicectl 截屏。输出目录里留 xcodebuild.log 与 steps.log（「[xcui] …」行）
set -u
UD=${1:?设备 UDID} PLAN=${2:?计划 JSON} O=${3:-$(mktemp -d "${TMPDIR:-/tmp}/xcui.XXXXXX")}
H=$(cd "$(dirname "$0")/../.." && pwd); B=$H/build/xcui; mkdir -p "$O" "$B"
[ -n "${S2A_DEVELOPER_DIR:-}" ] && export DEVELOPER_DIR=$S2A_DEVELOPER_DIR
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PLAN" || { echo "🔴 计划不是合法 JSON：$PLAN"; exit 2; }
TEAM=${S2A_XCUI_TEAM:-$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | awk '/isFreeProvisioningTeam = 0/{f=1} f && /teamID =/{gsub(/[ ;]/,"",$3); print $3; exit}')}
[ -n "$TEAM" ] || { echo "🔴 没有付费签名团队：给 S2A_XCUI_TEAM 或在 Xcode 里登录"; exit 2; }
P=$(base64 < "$PLAN" | tr -d '\n')
mkdir -p "$B/gen"; printf '// run.sh 生成：本次计划（base64）\nlet XCUIEmbeddedPlan = "%s"\n' "$P" > "$B/gen/PlanData.swift"   # TEST_RUNNER_ 到不了真机 UI 测试进程，计划随构建带进去
S2A_XCUI_TEAM=$TEAM xcodegen generate --quiet --spec "$H/tools/xcui/project.yml" --project "$B" || { echo "🔴 xcodegen 生成失败"; exit 2; }
xcodebuild test -project "$B/S2AXCUI.xcodeproj" -scheme S2AXCUIRunner -destination "id=$UD" -derivedDataPath "$B/dd" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" TEST_RUNNER_S2A_XCUI_PLAN="$P" > "$O/xcodebuild.log" 2>&1; rc=$?
grep -a '\[xcui\]' "$O/xcodebuild.log" > "$O/steps.log"
cat "$O/steps.log"; [ $rc = 0 ] && echo "🟢 点按完成（$(grep -c . "$O/steps.log") 行；${O}）" || echo "🔴 xcodebuild rc=${rc}：$(grep -aE 'error:|failed|XCTAssert' "$O/xcodebuild.log" | tail -3 | tr '\n' ' ' | cut -c1-300)（全文 $O/xcodebuild.log）"
exit $rc
