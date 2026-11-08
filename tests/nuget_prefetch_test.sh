#!/bin/bash
# 门禁覆盖：tools/nuget_prefetch.py tools/remote.sh
# 离线门禁 NuGet 包预备（tools/nuget_prefetch.py，11-07 #1639 门禁退出 75 整批留队后加）：假 dotnet，不联网，约 1 秒
#   ① 离线还原失败 → 走联网还原 → 从 obj/project.assets.json 收包（含传递依赖与运行时包下载项）→ 列出包目录、记下清单
#   ② 指纹没变、包都在 → 直接用记录，不调 dotnet restore
#   ③ 工程文件改了（加包）→ 指纹变 → 重新还原
#   ④ 联网还原也失败 → rc=1、报红
set -u
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
mkdir -p "$T/proj" "$T/cache" "$T/run" "$T/bin"
printf '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><PackageReference Include="A.B" Version="1.0.0"/></ItemGroup></Project>\n' > "$T/proj/x.csproj"
cat > "$T/bin/dotnet" << 'D'
#!/bin/bash
echo "$*" >> "$LOG"
[ "$1" = --version ] && { echo 10.0.400; exit 0; }
case " $* " in *" --source "*) exit 1;; esac       # 离线还原：缓存里没有 → 失败
[ -n "${FAIL_ONLINE:-}" ] && { echo "network down"; exit 1; }
proj=$2; mkdir -p "$(dirname "$proj")/obj" "$NUGET_PACKAGES/a.b/1.0.0" "$NUGET_PACKAGES/dep.c/2.0.0" "$NUGET_PACKAGES/microsoft.netcore.app.ref/10.0.0"
printf '{"libraries":{"A.B/1.0.0":{"type":"package"},"Dep.C/2.0.0":{"type":"package"},"Proj/1.0.0":{"type":"project"}},"project":{"frameworks":{"net10.0":{"downloadDependencies":[{"name":"Microsoft.NETCore.App.Ref","version":"[10.0.0, 10.0.0]"}]}}}}' > "$(dirname "$proj")/obj/project.assets.json"
D
chmod +x "$T/bin/dotnet"
export S2A_DOTNET=$T/bin/dotnet NUGET_PACKAGES=$T/cache S2A_RUN_ROOT=$T/run LOG=$T/log
run() { python3 -B tools/nuget_prefetch.py "$T/proj" > "$T/out" 2> "$T/err"; }
ok() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
: > "$T/log"; run; rc=$?
ok "① 离线失败→联网补齐→列 3 个包目录（含运行时包下载项、不含工程引用）" '[ $rc = 0 ] && [ "$(wc -l < "$T/out")" -eq 3 ] && grep -qx "~/.nuget/packages/microsoft.netcore.app.ref/10.0.0" "$T/out" && ! grep -q proj/ "$T/out" && grep -q "restore .*--disable-parallel$" "$T/log"'
: > "$T/log"; run; rc=$?
ok "② 指纹没变、包都在 → 用记录、不调 restore" '[ $rc = 0 ] && [ "$(wc -l < "$T/out")" -eq 3 ] && ! grep -q restore "$T/log"'
perl -pi -e 's#</ItemGroup>#<PackageReference Include="E.F" Version="3.0.0"/></ItemGroup>#' "$T/proj/x.csproj"
: > "$T/log"; run; rc=$?
ok "③ 工程文件改了 → 重新还原" '[ $rc = 0 ] && grep -q restore "$T/log"'
perl -pi -e 's#E\.F#G.H#' "$T/proj/x.csproj"; rm -rf "$T/proj/obj"
FAIL_ONLINE=1 run; rc=$?
ok "④ 联网还原也失败 → rc=1 报红" '[ $rc = 1 ] && grep -q "【红】联网还原" "$T/err"'
[ $bad = 0 ] && echo "nuget_prefetch 单测全过" || { echo "nuget_prefetch 单测有不通"; exit 1; }
