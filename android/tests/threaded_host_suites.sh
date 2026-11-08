#!/usr/bin/env bash
# 拆线程主机套件（PR #498）：默认门禁只跑主机可跑、分钟级的套件。
# 跨平台：counter-tests、audio-lifetime-tests、metrics-tests、Runtime.Tests。
# Linux：run_lifecycle（macOS 没有 clock_nanosleep / GNU ld 的 --wrap，自动跳过）。
# 不在默认门禁的 control-tests 十连、writers-gate、run_thread 登记在 tests/gate_not_default.tsv。
set -euo pipefail
android_dir=$(cd "$(dirname "$0")/.." && pwd -P)
repo_dir=$(cd "$android_dir/.." && pwd -P)
test_python=${S2A_PY:-python3}
dotnet_bin=${DOTNET:-$(command -v dotnet || true)}
[ -n "$dotnet_bin" ] || { echo "🔴 拆线程主机套件：找不到 dotnet（需要 .NET 10 SDK；可设 DOTNET=<路径>）"; exit 1; }
dotnet_ver=$("$dotnet_bin" --version 2>/dev/null || true)
dotnet_major=${dotnet_ver%%.*}
case $dotnet_major in ''|*[!0-9]*) echo "🔴 拆线程主机套件：读不到 dotnet 版本（${dotnet_ver:-空}）"; exit 1;; esac
[ "$dotnet_major" -ge 10 ] || { echo "🔴 拆线程主机套件：需要 .NET 10+，当前 ${dotnet_ver}"; exit 1; }
export DOTNET_PROCESSOR_COUNT=${DOTNET_PROCESSOR_COUNT:-2}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/s2a-threaded-host.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
run() { echo "== $1"; shift; "$@"; }

run counter-tests "$test_python" "$repo_dir/graphics/vulkan/runtime/counter-tests/run.py" \
    --dotnet "$dotnet_bin" --out "$tmp/counter"
run audio-lifetime-tests "$test_python" "$repo_dir/android/core-runtime/audio-lifetime-tests/run.py" \
    --dotnet "$dotnet_bin" --out "$tmp/audio"
run metrics-tests "$test_python" "$repo_dir/android/core-runtime/metrics-tests/run.py" \
    --dotnet "$dotnet_bin" --output "$tmp/metrics"
run android-shutdown-thread bash "$repo_dir/android/core-runtime/tests/run_shutdown_thread.sh" "$tmp/shutdown" "$dotnet_bin"
# run_shutdown_thread.sh 已在 "$shared" 里编好 S2A.Services / Ryujinx / S2A.Android.Aot（Release）。下面的 C# 主机测试都编进同一个
# 产物目录，依赖不再各编一遍、只编测试工程本身（#894：本机实测这五支单编合计约 176 秒，共用后约 25 秒）。
shared="$tmp/shutdown"
echo "== direct-tests"; DOTNET="$dotnet_bin" bash "$android_dir/core-runtime/direct-tests/run.sh" "$shared"
echo "== android-services"; DOTNET="$dotnet_bin" bash "$android_dir/core-runtime/tests/run_services.sh" "$shared"
echo "== touch-tests"; DOTNET="$dotnet_bin" bash "$android_dir/core-link/runtime-tests/touch/run.sh" "$shared"

# Runtime.Tests 编译生产 Runtime 的 BackingChecks，必须用仓库外输出目录；构建后直接跑 DLL。
rt="$tmp/runtime-tests"; mkdir -p "$rt"
printf '%s\n' '<configuration><packageSources><clear /></packageSources></configuration>' > "$rt/NuGet.Config"
echo "== runtime-tests"
"$dotnet_bin" build "$repo_dir/graphics/vulkan/runtime/tests/Runtime.Tests.csproj" \
    --configfile "$rt/NuGet.Config" -p:ArtifactsPath="$rt/art" -v:q
rt_dll="$rt/art/bin/Runtime.Tests/debug/Runtime.Tests.dll"
[ -f "$rt_dll" ] || { echo "🔴 runtime-tests：找不到 $rt_dll"; exit 1; }
# The production mount test calls the Android asset boundary. Use the same
# controllable asset fixture as Runtime.Tests.csproj, without a real APK.
rt_bin=$(dirname "$rt_dll")
if [ "$(uname -s)" = Darwin ]; then
    "${CC:-cc}" -dynamiclib "$repo_dir/graphics/vulkan/runtime/tests/asset_fixture.c" -o "$rt_bin/libs2arm_android.dylib"
else
    "${CC:-cc}" -shared -fPIC "$repo_dir/graphics/vulkan/runtime/tests/asset_fixture.c" -o "$rt_bin/libs2arm_android.so"
fi
"$dotnet_bin" "$rt_dll"

# #868 带进来的两支直连 C# 自测（Exe 工程，自报「ok (N checks)」，失败退出非 0）：输出放仓库外再直接跑 DLL；同样编进 "$shared"，DLL 只在各自的 bin 子目录里找
for proj in android/core-runtime/direct-abi-tests/DirectAbi.Tests.csproj graphics/tools/direct/tests/compiler/DirectCompiler.Tests.csproj; do
    name=$(basename "$proj" .csproj); art="$shared"
    echo "== $name"
    # 编译失败打出编译器的错误行（10-30 列车线：原先不查退出码，编不过时只剩「找不到构建产物」）
    # 不用 -p:ArtifactsPath：它把 obj 一起搬进共享目录，DirectCompiler.Tests 这种「直连工程 → ryujinx 闭包」形状下 NuGet 恢复图坍缩成单节点，transitive 引用全丢报 CS0246（偶发）；OutputPath 只挪 bin、obj 留默认位，恢复图正常
    "$dotnet_bin" build "$repo_dir/$proj" -c Release -p:OutputPath="$art/bin/$name/" -v:q > "$tmp/$name.build.log" 2>&1 || { echo "🔴 ${name}：编译失败"; grep -E ' error ' "$tmp/$name.build.log" | sort -u | head -20; exit 1; }
    dll=$(find "$art/bin/$name" -name "*.Tests.dll" | head -1)
    [ -n "$dll" ] || { echo "🔴 ${name}：找不到构建产物"; exit 1; }
    "$dotnet_bin" "$dll"
done

if [ "$(uname -s)" = Linux ]; then
    run lifecycle-tests "$test_python" "$repo_dir/android/native/runtime/platform/tests/run_lifecycle.py" \
        --out "$tmp/lifecycle"
else
    echo "== lifecycle-tests：跳过（需 Linux ARM64；单跑命令见 android/tests/gate_not_default.tsv）"
fi

echo "拆线程主机套件 期望 全过 → 真结果 通过"
