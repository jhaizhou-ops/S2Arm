#!/bin/bash
# 门禁覆盖：graphics/vulkan/*
# Vulkan 后端 C# 单测（10-29 基础设施线：#867 改 graphics/vulkan/core/**，这里的 C# 单测从来没有门禁跑）：只跑 CPU 侧、不要 GPU 的那几个工程，
#   12 个工程无参数跑 CPU 宿主回归，一个红整支红；不证明 GPU/设备/游戏。
#   门禁覆盖查询生命周期：query-semantics-tests 跑真 BufferedQuery/CounterQueue/CounterQueueEvent——Begin 清零、
#   超时计数不锁结果、段溢出显式失败、消费线程 Peek 留队、FlushTo 有界、Flush(true) 不持锁等超时。
#   另跑 stop_after_acquire.py --mode all（15 个 Present/Poll/租约相位）：真实 NativeLease ABI 消费方 + 受控
#   Vulkan 边界；含 #1228 回归守卫 revoke-early / revoke-early-prior（acquire 与提交之间撤销）。缺任一 PASS 即红。
#   依赖须预先准备；本入口清空包源、共享本次构建输出并串行构建，不联网下载。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf '<configuration><packageSources><clear /></packageSources></configuration>\n' > "$T/NuGet.Config"
DN=${DOTNET:-$HOME/.dotnet/dotnet}; [ -x "$DN" ] || DN=$(command -v dotnet)
bad=0; n=0
run() { n=$((n + 1)); local o r; o=$(MSBUILDDISABLENODEREUSE=1 timeout 600 "$DN" run -c Release --project "$1" --artifacts-path "$T/artifacts" -p:BuildInParallel=false -p:GeneratePackageOnBuild=false -p:CreateHardLinksForCopyFilesToOutputDirectoryIfPossible=true -p:CreateHardLinksForCopyLocalIfPossible=true -p:NuGetAudit=false -p:RestoreConfigFile="$T/NuGet.Config" 2>&1 < /dev/null); r=$?
  if [ $r = 0 ]; then echo "通 ${1#$H/}：$(tail -1 <<< "$o" | cut -c1-120)"; else echo "不通 ${1#$H/}（rc=${r}）：$(tail -3 <<< "$o" | tr '\n' ' ' | cut -c1-300)"; bad=1; fi; }
run "$H/graphics/vulkan/cache/tests/renderer/RendererProfile.Tests.csproj"
run "$H/graphics/vulkan/core/cache-tests/CacheAdmission.Tests.csproj"
run "$H/graphics/vulkan/core/fence-tests/Fence.Results.Tests.csproj"
run "$H/graphics/vulkan/core/tests/DeviceFeatures.Tests.csproj"
run "$H/graphics/vulkan/runtime/geometry-output-tests/GeometryOutput.Tests.csproj"
run "$H/graphics/vulkan/runtime/counter-tests/CounterLifetime.csproj"
run "$H/graphics/vulkan/runtime/query-semantics-tests/QuerySemantics.csproj"
run "$H/graphics/vulkan/runtime/readback-registration-tests/Host.csproj"
run "$H/graphics/vulkan/cache/tests/CodecTests.csproj"
run "$H/graphics/vulkan/runtime/control-tests/Control.Tests.csproj"
run "$H/graphics/vulkan/runtime/varying-tests/Varying.Tests.csproj"
run "$H/graphics/vulkan/runtime/tests/Runtime.Tests.csproj"
run "$H/graphics/vulkan/wsi/tests/WsiTests.csproj"
# 同族 Python 跑器（11-01 接线：分母按 tests 目录后查出没人调）：输出都放本次临时目录；本机负载 30 时合计约 45 秒。
#   run_host 要 spirv-as / spirv-val（汇编三段 SPIR-V 再跑 CodecTests 全量），utility 用 spirv-val 校验项目内嵌工具着色器
pyck() { n=$((n + 1)); if [ "$2" = 0 ]; then echo "通 ${1}：$(tail -1 <<< "$3" | cut -c1-120)"; else echo "不通 ${1}（rc=${2}）：$(tail -5 <<< "$3" | tr '\n' ' ' | cut -c1-400)"; bad=1; fi; }
PYV=${S2A_PY:-python3}; export PATH="${DN%/*}:$PATH"   # run_host / wsi 跑器按 PATH 找 dotnet：与上面工程用同一个 SDK
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/cache/tests/run_host.py" --out "$T/codec-host" 2>&1 < /dev/null); pyck cache/run_host $? "$o"
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/cache/tests/test_profile_runner.py" 2>&1 < /dev/null); pyck cache/test_profile_runner $? "$o"
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/runtime/utility-tests/run.py" --vulkan-root "$H/compat/tree/src/Ryujinx.Graphics.Vulkan" --spirv-val "$(command -v spirv-val || echo spirv-val)" --output "$T/utility" 2>&1 < /dev/null); pyck runtime/utility-tests $? "$o"
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/wsi/tests/run.py" --negative-controls --output-root "$T/wsi-run" 2>&1 < /dev/null); pyck wsi/run $? "$o"
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/wsi/tests/test_runner.py" --out "$T/wsi-test-runner" 2>&1 < /dev/null); pyck wsi/test_runner $? "$o"
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/wsi/tests/retirement_diagnostics.py" --android-window "$H/graphics/vulkan/wsi/AndroidWindow.cs" --ledger "$H/graphics/vulkan/wsi/RetirementLedger.cs" --dotnet "$DN" --output "$T/wsi-retirement" 2>&1 < /dev/null); pyck wsi/retirement_diagnostics $? "$o"
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/wsi/tests/backing_lost_replay.py" "$T/wsi-lost" 2>&1 < /dev/null); pyck wsi/backing_lost_replay $? "$o"
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/wsi/tests/backing_lost_replay.py" "$T/wsi-lost-negative" --negative 2>&1 < /dev/null); r=$?
if [ "$r" != 0 ] && [[ "$o" == *"device lost did not replay recorded zero VA"* ]]; then pyck wsi/backing_lost_negative 0 "$o"; else pyck wsi/backing_lost_negative 1 "$o"; fi
# #1228 回归守卫：撤销在 acquire 与提交之间送达时，必须走「只等不送」排空。--mode all 覆盖 15 个相位；
# 这里显式核 revoke-early / revoke-early-prior 的 PASS，模式被删或脚本没接上都会红。
run_stop_after_acquire() { local o r c; o=$(timeout 600 python3 "$H/graphics/vulkan/wsi/tests/stop_after_acquire.py" --mode all \
  --android-window "$H/graphics/vulkan/wsi/AndroidWindow.cs" \
  --ledger "$H/graphics/vulkan/wsi/RetirementLedger.cs" \
  --native-lease "$H/graphics/vulkan/wsi/NativeLease.cs" \
  --dotnet "$DN" --output "$T/stop-after-acquire" 2>&1 < /dev/null); r=$?
  c=$(grep -cE '^PASS [a-z]' <<< "$o")
  if [ $r = 0 ] && [ "$c" -ge 15 ] && grep -q '^PASS revoke-early$' <<< "$o" && grep -q '^PASS revoke-early-prior$' <<< "$o"; then
    echo "通 graphics/vulkan/wsi/tests/stop_after_acquire.py：${c} 个模式，含 revoke-early / revoke-early-prior"
  else echo "不通 graphics/vulkan/wsi/tests/stop_after_acquire.py（rc=${r}，模式=${c}）：$(tail -3 <<< "$o" | tr '\n' ' ' | cut -c1-300)"; bad=1; fi; }
run_stop_after_acquire
[ $bad = 0 ] && echo "vulkan_backend 单测全过（${n} 项：工程 + Python 跑器 + stop_after_acquire 全模式）" || { echo "vulkan_backend 单测有不通"; exit 1; }
