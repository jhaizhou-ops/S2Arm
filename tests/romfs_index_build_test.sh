#!/bin/bash
# 门禁只看：services/romfs_index.sh
# services/romfs_index.sh 构建失败不许当成功（T141 #937）：build 失败 → 非 0 退出、错误行到 stderr、一次都不跑 DLL；
#   build 成功 → 照常 exec 新 DLL；S2A_PREBUILT_TOOLS 预编分支不构建、直接跑那份 DLL（行为不变）。
#   增量构建「没变化」是 build rc=0（照常跑已有 DLL），和「构建失败」必须分开判——这两件混起来就是「绿着失效」。
# 桩 DOTNET：\$1=build 时按 STUB_BUILD_RC 返回并打一行 error；其余调用（跑 DLL）记一行日志、按 STUB_RUN_RC 返回。
# 脚本按自身目录定位工程与产物 → 复制到 \$T/repo/services/ 下跑，不碰仓库里真实的 bin/；不需要真 dotnet、不需要游戏数据、不联网。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; n=0; trap 'rm -rf "$T"' EXIT
ck() { n=$((n + 1)); if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }

R=$T/repo; mkdir -p "$R/services/romfs_index/bin/Release/net10.0" "$T/root/romfs"
cp "$H/services/romfs_index.sh" "$R/services/romfs_index.sh" || exit 1
S=$R/services/romfs_index.sh
DLL=$R/services/romfs_index/bin/Release/net10.0/romfs_index.dll
export STUB_BUILD_LOG=$T/build.log STUB_RUN_LOG=$T/run.log
cat > "$T/dotnet" <<'SH'
#!/bin/bash
# 桩 dotnet：build 分支只报错、不产出产物；其余分支（跑 DLL）记账
if [ "$1" = build ]; then
  echo "$*" >> "$STUB_BUILD_LOG"
  echo "Program.cs(1,1): error CS0103: 桩：故意让构建失败" >&2
  exit "${STUB_BUILD_RC:-0}"
fi
echo "$*" >> "$STUB_RUN_LOG"
echo "🟢 桩：跑了 $*"
exit "${STUB_RUN_RC:-0}"
SH
chmod +x "$T/dotnet"

go() {   # go <KEY=VAL…>：DOTNET 指桩跑脚本，stdout / stderr 分开收，rc 记 RC，跑过 DLL 记 RUNS
  ( export DOTNET="$T/dotnet"; for kv in "$@"; do export "$kv"; done
    bash "$S" "$T/root" > "$T/out" 2> "$T/err" ); RC=$?
  O=$(cat "$T/out" 2>/dev/null); E=$(cat "$T/err" 2>/dev/null); RUNS=$(cat "$STUB_RUN_LOG" 2>/dev/null)
}

# ① 构建失败：桩 build 返回 1；先放一份「上一次留下的旧 DLL」当兜底产物（bug 就是它被拿去跑）
printf 'old\n' > "$DLL"; before=$(shasum -a 256 "$DLL" | cut -d' ' -f1)
rm -f "$STUB_BUILD_LOG" "$STUB_RUN_LOG"
go STUB_BUILD_RC=1
ck "① 构建失败 → 非 0 退出（rc=${RC}）" '[ "$RC" -ne 0 ]'
ck "① 构建失败 → stderr 写明「构建失败 / 不运行旧 DLL」并带那条 error 行（$(printf %s "$E" | tr "\n" " ")）" 'grep -q "构建失败" <<< "$E" && grep -q "不运行旧 DLL" <<< "$E" && grep -q "error CS0103" <<< "$E"'
ck "① 构建失败 → stdout 里没有跑 DLL 的回显（$(printf %s "$O" | tr "\n" " ")）" '! grep -q "跑了" <<< "$O"'
ck "① 构建失败 → 桩的「运行 DLL」分支一次都没被调（[${RUNS}]）" '[ -z "$RUNS" ]'
ck "① 构建失败 → 旧 DLL 原样没被动过" '[ "$(shasum -a 256 "$DLL" | cut -d" " -f1)" = "$before" ]'

# ② 正常路径：构建成功 → 照常 exec 新 DLL（不能把正常出包改坏）
rm -f "$STUB_BUILD_LOG" "$STUB_RUN_LOG"
go STUB_BUILD_RC=0
ck "② 构建成功 → rc=0（rc=${RC}）" '[ "$RC" = 0 ]'
ck "② 构建成功 → 只构建一次（$(cat "$STUB_BUILD_LOG" 2>/dev/null)）" '[ "$(wc -l < "$STUB_BUILD_LOG" 2>/dev/null | tr -d " ")" = 1 ]'
ck "② 构建成功 → 跑的是工程下那份 DLL（[${RUNS}]）" 'grep -qF "$DLL" <<< "$RUNS"'
ck "② 构建成功 → 产物根照旧写在 <根>/（stdout 有桩回显）" 'grep -q "跑了" <<< "$O"'

# ③ 预编分支：S2A_PREBUILT_TOOLS 不构建，直接跑那份 DLL（语义不变）
mkdir -p "$T/prebuilt/romfs"; printf 'prebuilt\n' > "$T/prebuilt/romfs/romfs_index.dll"
rm -f "$STUB_BUILD_LOG" "$STUB_RUN_LOG"
go S2A_PREBUILT_TOOLS="$T/prebuilt"
ck "③ S2A_PREBUILT_TOOLS：rc=0 且跑的是预编 DLL（[${RUNS}]）" '[ "$RC" = 0 ] && grep -qF "$T/prebuilt/romfs/romfs_index.dll" <<< "$RUNS"'
ck "③ S2A_PREBUILT_TOOLS：不构建（build 一次都没调）" '[ ! -f "$STUB_BUILD_LOG" ]'

# ④ build 报成功但没产物：也属于「没换成新的」，不许拿旧 DLL 顶上
rm -f "$DLL" "$STUB_BUILD_LOG" "$STUB_RUN_LOG"
go STUB_BUILD_RC=0
ck "④ build rc=0 但没有产物 → 非 0 退出（rc=${RC}）" '[ "$RC" -ne 0 ]'
ck "④ 报「构建报告成功…没换成新的」且不跑任何 DLL（[${RUNS}]）" 'grep -q "构建报告成功" <<< "$E" && [ -z "$RUNS" ]'

# ⑤ 回归网：构建命令不许再被管道 / || true 吞掉退出码
ck "⑤ 代码行里不再用「|| true」吞构建退出码（只有注释里留着旧写法）" '! sed "s/#.*//" "$S" | grep -q "|| true"'

[ $bad = 0 ] && echo "romfs_index 构建失败单测全过（${n} 项）" || { echo "romfs_index 构建失败单测有不通"; exit 1; }
