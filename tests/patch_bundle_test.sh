#!/bin/bash
# 补丁库随启动器发版（tools/patch_bundle.py；合成补丁库，不碰真补丁，约 1 秒）：bash tests/patch_bundle_test.sh
# 门禁覆盖：tools/patch_bundle.py launchers/macos/build_app.py
# 期望手写：
#   ① 甲款文件头 verified_builds 一个 32 位构建号 → 收；INDEX.tsv 一行，sha256 = 原文件的 sha256
#   ② 乙款没有 verified_builds → 跳过，不出目录
#   ③ 丙款 verified_builds 写在 [caps] 段里（不是文件头）→ 跳过
#   ④ 目录名不是 16 位程序号 / 没有 patch.tsv → 不看
#   ⑤ 丁款 program 与目录名不一致 → 报红退出 1
#   ⑥ 戊款 verified_builds 有 31 位的 → 报红退出 1
#   ⑦ 空库 → INDEX.tsv 只有表头（启动器按它在不在判补丁库）
set -u
R=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PYTHON:-python3}; T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=$((bad + 1)); fi; }
B=d1ed438c8bdaf4368b30daec53ed8e9b
mk() { mkdir -p "$T/$1/$2"; printf "$3" > "$T/$1/$2/patch.tsv"; }
mk lib 0100000000AAA000 "schema\t1\nprogram\t0100000000AAA000\nverified_builds\t$B\n[caps]\nwiden\t1\n"
mk lib 0100000000BBB000 "schema\t1\nprogram\t0100000000BBB000\n[caps]\nwiden\t1\n"
mk lib 0100000000CCC000 "schema\t1\nprogram\t0100000000CCC000\n[caps]\nverified_builds\t$B\n"
mkdir -p "$T/lib/grokbot_x" "$T/lib/0100000000DDD000"; echo x > "$T/lib/批量报告.tsv"
out=$("$PY" "$R/tools/patch_bundle.py" "$T/lib" "$T/out"); rc=$?
ck "① 甲款收进、② 乙款 ③ 丙款跳过、④ 杂目录不看（rc=${rc}，${out}）" '[ $rc = 0 ] && [ -f $T/out/0100000000AAA000/patch.tsv ] && [ ! -e $T/out/0100000000BBB000 ] && [ ! -e $T/out/0100000000CCC000 ] && [ "$out" = "补丁库：收 1 款，跳过 2 款（没验过）" ]'
sha=$(shasum -a 256 < "$T/lib/0100000000AAA000/patch.tsv" | cut -c1-64)
ck "① INDEX.tsv 一行：程序号 / 构建号 / sha256" '[ "$(sed -n 2p $T/out/INDEX.tsv)" = "$(printf "0100000000AAA000\t%s\t%s" $B $sha)" ] && [ $(wc -l < $T/out/INDEX.tsv) = 2 ]'
mk bad1 0100000000EEE000 "schema\t1\nprogram\t0100000000FFF000\nverified_builds\t$B\n"
out=$("$PY" "$R/tools/patch_bundle.py" "$T/bad1" "$T/o1"); rc=$?
ck "⑤ program 与目录名不一致 → 报红退出 1（${out}）" '[ $rc = 1 ] && [[ "$out" == *不一致* ]]'
mk bad2 0100000000EEE000 "schema\t1\nprogram\t0100000000EEE000\nverified_builds\t${B%b}\n"
out=$("$PY" "$R/tools/patch_bundle.py" "$T/bad2" "$T/o2"); rc=$?
ck "⑥ 构建号 31 位 → 报红退出 1（${out}）" '[ $rc = 1 ] && [[ "$out" == *32\ 位* ]]'
mkdir -p "$T/empty"; "$PY" "$R/tools/patch_bundle.py" "$T/empty" "$T/o3" > /dev/null
ck "⑦ 空库 → INDEX.tsv 只有表头" '[ "$(cat $T/o3/INDEX.tsv)" = "$(printf "程序号\t已验构建号\tsha256")" ]'
rm -rf "$T"; [ $bad = 0 ] && echo "patch_bundle 单测全过" || { echo "patch_bundle 单测有不通"; exit 1; }
