#!/bin/bash
# 出包子步计时包装器不改子进程区域（秒级）：bash tests/tm_locale_test.sh
# 背景：Python 3 在 C 区域下给子进程塞 LC_CTYPE=C.UTF-8（区域强制），pack/ipa.sh 经 tools/tm.py 起的 bash 全进 UTF-8，
#   各线脚本里「美元符 + 变量名 + 全角字符」被读进变量名、set -u 炸（10-20 自动正式局：nxaot.sh 行 21、shader_pack.sh 行 64）。
# 期望（不跑被测实现即可知）：C 区域下用 ipa.sh 里的 TM() 定义包一个「K=1; echo 美元K）」的 bash → 退出 0、子进程看到的 LC_CTYPE 为空；
#   反证：不带 PYTHONCOERCECLOCALE=0 的旧写法 → 退出非 0。直接核子进程 LC_CTYPE，
#   不依赖 Bash 对全角字符是否当作变量名（不同 Bash 版本会不同，解析成功也不能掩盖环境被改）。
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
L=$(grep -m1 '^TM() ' "$H/pack/ipa.sh"); [ -n "$L" ] || { echo "🔴 pack/ipa.sh 里找不到 TM() 定义"; exit 1; }   # 函数而不是串（引擎在带空格目录时串会被拆，10-25）
printf 'K=1; echo "a$K\xef\xbc\x89b"; echo "LC_CTYPE=${LC_CTYPE:-}"; [ -z "${LC_CTYPE:-}" ]\n' > "$T/u.sh"
C0=(env -u LANG -u LC_ALL -u LC_CTYPE)
new=$("${C0[@]}" bash -c "R='$H'; $L"$'\n''TM 新 "$1/log" -- bash -u "$1/u.sh"' _ "$T" 2>&1); rn=$?
old=$("${C0[@]}" python3 "$H/tools/tm.py" 旧 "$T/log" -- bash -u "$T/u.sh" 2>&1); ro=$?
echo "期望 ipa.sh 的 TM 包装 → 退出 0、LC_CTYPE 空；真结果 退出 ${rn}，$(echo "$new" | tail -1)"
echo "期望 旧写法（反证）→ 退出非 0；真结果 退出 ${ro}（$(echo "$old" | tail -1)）"
[ $rn = 0 ] && [ "$(echo "$new" | tail -1)" = "LC_CTYPE=" ] && [ $ro != 0 ]
