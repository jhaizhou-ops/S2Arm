#!/bin/bash
# 宏离线编译表校验。现有仓内语料暂保留兼容；公开清理见 #666，不能据此宣称已清净。
# 私有语料：S2A_MACRO_CORPUS=/仓外目录 bash graphics/tools/macrogen/regen.sh check
# import 只允许显式仓外语料；不联网、不下载。write 仍是显式维护操作，不在单测里改生产表。
set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd -P)
cmd=${1:-check}
case "$cmd" in check|write|import) ;; *) echo "用法：regen.sh check|write|import <导出目录> <组名>" >&2; exit 2;; esac
C=$ROOT/graphics/tools/macrogen/corpus
if [ "${S2A_MACRO_CORPUS+x}" ]; then
  # resolve 规范相对路径及现存父目录符号链接，不读语料内容；避免链接绕回仓库。
  C=$(python3 - "$ROOT" "$S2A_MACRO_CORPUS" <<'PY'
import pathlib, sys
root=pathlib.Path(sys.argv[1]).resolve()
raw=sys.argv[2]
if not raw or "\n" in raw or "\r" in raw:
    sys.exit("私有 corpus 路径不能为空或含换行")
p=pathlib.Path(raw).resolve()
if p == root or root in p.parents:
    sys.exit("私有 corpus 必须在仓库外（按实际路径判断）")
print(p)
PY
  ) || exit 2
fi
if [ "$cmd" = import ]; then
  [ "${S2A_MACRO_CORPUS+x}" ] || { echo "import 必须显式设置仓外 S2A_MACRO_CORPUS；禁止继续导入仓库" >&2; exit 2; }
  SRC=${2:-}; G=${3:-}
  [[ "$G" =~ ^[A-Za-z0-9_-]+$ ]] && [ -d "$SRC" ] || { echo "import 需要有效源目录与简单组名（字母/数字/_/-）" >&2; exit 2; }
  [ ! -L "$C/$G" ] || { echo "import 拒绝符号链接目标组" >&2; exit 2; }
  mkdir -p "$C/$G" || exit 2
  shopt -s nullglob
  files=("$SRC"/*.mme)
  [ ${#files[@]} -gt 0 ] || { echo "import 源目录没有 .mme" >&2; exit 2; }
  for f in "${files[@]}"; do
    [ -f "$f" ] && [ ! -L "$f" ] || { echo "import 拒绝非普通文件或链接" >&2; exit 2; }
    target="$C/$G/${f##*/}"
    [ ! -L "$target" ] || { echo "import 拒绝目标文件链接" >&2; exit 2; }
    [ -e "$target" ] || cp -n -- "$f" "$target" || exit 2
  done
  echo "私有语料已导入：${G}；未修改仓库语料或生产宏表"
  exit 0
fi
[ ! -e "$C" ] || [ -d "$C" ] || { echo "corpus 不是目录" >&2; exit 2; }
shopt -s nullglob
dirs=()
n=0
for d in "$C"/*/; do
  if [ "${S2A_MACRO_CORPUS+x}" ] && [ -L "${d%/}" ]; then
    echo "私有 corpus 拒绝子目录链接" >&2; exit 2
  fi
  files=("$d"*.mme)
  if [ "${S2A_MACRO_CORPUS+x}" ] && [ ${#files[@]} -eq 0 ]; then continue; fi
  if [ "${S2A_MACRO_CORPUS+x}" ]; then
    for f in "${files[@]}"; do
      [ -f "$f" ] && [ ! -L "$f" ] || { echo "私有 corpus 拒绝非普通宏文件或链接" >&2; exit 2; }
    done
  fi
  dirs+=("${d%/}")
  n=$((n + ${#files[@]}))
done
if [ "$cmd" = write ] && [ "$n" -eq 0 ]; then
  echo "拒绝写表：没有语料，不以空表覆盖生产注册表" >&2; exit 2
fi
if [ ${#dirs[@]} -eq 0 ]; then
  echo "SKIP：没有宏语料目录或 .mme；未执行宏表一致性验证（${C}）"
  exit 0
fi
T=$ROOT/compat/tree/src/Ryujinx.Graphics.Gpu/Engine/MME/S2AMacroTable.g.cs
OUT=$ROOT/build/macrogen
mkdir -p "$OUT" || exit 2
timeout 900 dotnet run -c Release --project "$ROOT/graphics/tools/macrogen" --artifacts-path "$OUT/art" -- "$OUT/S2AMacroTable.g.cs" "${dirs[@]}" > "$OUT/gen.log" 2>&1 || { r=$?; tail -5 "$OUT/gen.log"; echo "期望 宏语料 ⊆ 宏表 → 真结果 ✗ 生成器失败（退出 ${r}，日志 ${OUT}/gen.log）"; exit 2; }   # 末行写明失败：调用方（graphics/gate.sh）按退出码判红、末行进结论
case "$cmd" in
  write) cp "$OUT/S2AMacroTable.g.cs" "$T" || exit 2; echo "已写 ${T}（$(tail -1 "$OUT/gen.log")）";;
  check) if cmp -s "$OUT/S2AMacroTable.g.cs" "$T"; then
           echo "期望 宏语料 ⊆ 宏表 → 真结果 语料 $n 支（${#dirs[@]} 组），重生成与树内表逐字节相同 ✓"
         else echo "期望 宏语料 ⊆ 宏表 → 真结果 ✗ 语料与树内表不一致（语料 $n 支）"; exit 1; fi;;
esac
