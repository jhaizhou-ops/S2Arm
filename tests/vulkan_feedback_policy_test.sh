#!/bin/bash
# #1360 深度反馈环拆通道策略：宿主 C# 用例 + 负控。
# 只编策略文件（S2AFeedbackLoopPolicy.cs），不需要 Vulkan 设备 / 游戏。
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
DN=${DOTNET:-$HOME/.dotnet/dotnet}
[ -x "$DN" ] || DN=$(command -v dotnet)
if [ -z "$DN" ] || ! "$DN" --list-sdks 2>/dev/null | grep -q '^10\.'; then
    echo "缺少 .NET 10 SDK；未执行反馈环策略用例（不自动下载）" >&2
    exit 2
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
P="$H/tests/vulkan_feedback_policy/FeedbackPolicy.csproj"
"$DN" restore "$P" --configfile "$H/tests/vulkan_feedback_policy/NuGet.Config" \
    --artifacts-path "$T" -p:NuGetAudit=false >/dev/null 2>&1 || {
    echo "【红】反馈环策略用例 restore 失败"; exit 1; }
OUT=$("$DN" run --project "$P" --no-restore -c Release --artifacts-path "$T" 2>&1)
RC=$?
echo "$OUT"
PASS=$(grep -c '^PASS ' <<< "$OUT")
NEG=$(grep -c '^negative-controls=2$' <<< "$OUT")
if [ $RC = 0 ] && [ "$PASS" -ge 8 ] && [ "$NEG" = 1 ] && ! grep -q '^FAIL ' <<< "$OUT"; then
    echo "通 vulkan_feedback_policy：${PASS} 个用例，负控 2 个"
    exit 0
fi
echo "不通 vulkan_feedback_policy（rc=${RC}，PASS=${PASS}，负控=${NEG}）"
exit 1
