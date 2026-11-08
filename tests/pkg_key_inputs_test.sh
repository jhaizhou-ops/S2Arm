#!/bin/bash
# 包键覆盖全部进包输入单测（审计 P1-54，11-03 #1417：只换字体 / 0802 / 0823，包键不变、完成页「现行已是包」装上旧包）：bash tests/pkg_key_inputs_test.sh
# 夹具是一份带齐所有进包输入的产物根（资源包：main.npdm、romfs、romfs 索引、control.nacp、systemdata 的字体 / 时区 / 0802 / 0823、aoc.tsv、aoc；
#   App：随包表 s2a_caps / addr_need / widen_verified / widen_enable.handheld、产物根图标、图标目录里的重抽图标、宽屏自动表目录里的表）。
# 期望按规则手写，不经实现推：夹具里**每一个**进包文件逐个改一个字节（大小不变、修改时间改回原值，审计说的「路径 + 大小 + 修改时间」都不变）→ 包键都变；
#   改回原字节 → 键回到原值（键只由内容定）；什么都不改连算两次 → 同键。分母 = 夹具里的进包文件数，全部打印
# 原件进键（pack/srcs.sh，一键解包键 / 追加内容源键共用）：src_sample 同大小同修改时间换了首部 / 尾部字节 → 变、挪到别的路径 → 不变；
#   src_ident 换成另一份同大小的文件并把修改时间改回 → 变（ctime / inode）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
source "$H/pack/ipa_key.sh"
G=kfix; W=$T/root; IC=$T/icons; AU=$T/auto; BID=00112233445566778899aabbccddeeff
mkdir -p "$W/exefs" "$W/romfs/sub" "$W/ctl" "$W/systemdata/fonts" "$W/systemdata/0100000000000802" "$W/systemdata/0100000000000823" "$W/systemdata/010000000000080E" "$W/aoc/0100000000001001" "$IC" "$AU/${G}_$BID"
python3 - "$W/exefs/main" "$BID" <<'PY'
import sys; b = bytearray(0x200); b[0x40:0x50] = bytes.fromhex(sys.argv[2]); open(sys.argv[1], 'wb').write(b)
PY
w() { printf '%s-%s\n' "$2" "0123456789abcdef" > "$1"; }   # 每个文件内容各不相同
w "$W/exefs/main.npdm" npdm; w "$W/romfs/a.bin" romfs-a; w "$W/romfs/sub/b.bin" romfs-b; w "$W/romfs.s2aidx" idx; w "$W/ctl/control.nacp" nacp
w "$W/systemdata/fonts/FontStandard.bfttf" font; w "$W/systemdata/0100000000000802/mii.bin" mii; w "$W/systemdata/0100000000000823/ng.bin" ngword
w "$W/systemdata/010000000000080E/tz.bin" tz; w "$W/aoc.tsv" aoc-list; w "$W/aoc/0100000000001001/dlc.bin" dlc
w "$W/s2a_caps.tsv" caps; w "$W/addr_need.tsv" addr; w "$W/widen_verified.tsv" verified; w "$W/widen_enable.docked.tsv" enable-docked; w "$W/icon.jpg" icon-root
w "$IC/$G.jpg" icon-fresh; w "$AU/${G}_$BID/widen_enable.handheld.tsv" enable-auto; printf '过\thandheld\n' > "$AU/${G}_$BID/handheld.status"
for s in rewrite shaders uilayout romfsidx sysdata; do printf '%s fixture\n' "$s" > "$W/.stage_$s"; done
export S2A_ICONS=$IC S2A_WIDEN_AUTO=$AU S2A_WIDEN_DIR=$T/no_repo_tables; unset CFLAGS S2A_DUAL
export IPA_APP_TABLES="$(make -s --no-print-directory -C "$H" print-app-tables)"   # 随包表清单（runtime/build.mk）取一次，逐项算键复用
key() { ipa_pkg_key c1 "$W" "$G"; }
k0=$(key) || { echo "不通 夹具算不出包键"; exit 1; }; k0b=$(key)
ck "不改任何东西连算两次 → 同键" '[ -n "$k0" ] && [ "$k0" = "$k0b" ]'
# 进包文件：夹具里除阶段戳、派生缓存与产物根图标（图标目录有重抽的就不进 App，下面单独验）外的全部文件，加图标目录、自动表目录里的
files=$( { find "$W" -type f ! -name '.stage_*' ! -name icon.jpg ! -path '*/.resource-input-cache/*'; find "$IC" "$AU" -type f -name '*.jpg' -o -type f -name 'widen_*.tsv'; } | LC_ALL=C sort)
n=0; miss=
for f in $files; do
  n=$((n + 1)); cp -p "$f" "$T/orig"
  python3 - "$f" <<'PY'
import sys; p = sys.argv[1]; b = bytearray(open(p, 'rb').read()); b[0] ^= 1; open(p, 'wb').write(b)
PY
  touch -r "$T/orig" "$f"; k=$(key)
  [ "$k" != "$k0" ] || miss="$miss ${f#$T/}"
  cp -p "$T/orig" "$f"
done
ck "逐个改 ${n} 个进包文件的一个字节（大小、修改时间不变）→ 包键都变（没变的：${miss:-无}）" '[ $n -ge 18 ] && [ -z "$miss" ]'
k1=$(key); ck "全部改回原字节 → 键回到原值" '[ "$k1" = "$k0" ]'
# 图标两个来源：图标目录有重抽的就用它（产物根的不进 App）；删掉后退回产物根的那张 → 键变
w "$W/icon.jpg" icon-root-2; k2a=$(key); ck "图标目录有重抽图标时，只改产物根图标（不进 App）→ 键不变" '[ "$k2a" = "$k0" ]'
rm "$IC/$G.jpg"; k2=$(key); ck "图标目录的重抽图标去掉（退回产物根图标）→ 键变" '[ "$k2" != "$k0" ]'
w "$W/icon.jpg" icon-root-3; k3=$(key); ck "退回产物根图标后改它 → 键变" '[ "$k3" != "$k2" ]'
# ── 原件进键 ──────────────────────────────────────────────────────────────
source "$H/pack/srcs.sh" 2> /dev/null
S=$T/src; mkdir -p "$S"; python3 -c "import os,sys; open(sys.argv[1],'wb').write(os.urandom(300000))" "$S/game.nsp"; cp -p "$S/game.nsp" "$T/game.orig"
s0=$(src_sample "$S/game.nsp"); i0=$(src_ident "$S/game.nsp")
python3 - "$S/game.nsp" <<'PY'
import sys; p = sys.argv[1]; b = bytearray(open(p, 'rb').read()); b[100] ^= 1; open(p, 'r+b').write(b)
PY
touch -r "$T/game.orig" "$S/game.nsp"; s1=$(src_sample "$S/game.nsp")
python3 - "$S/game.nsp" <<'PY'
import sys; p = sys.argv[1]; b = bytearray(open(p, 'rb').read()); b[100] ^= 1; b[-5] ^= 1; open(p, 'r+b').write(b)
PY
touch -r "$T/game.orig" "$S/game.nsp"; s2=$(src_sample "$S/game.nsp")
ck "src_sample：同大小同修改时间改首部一字节 / 尾部一字节 → 都变（「${s0%%	*}」字节）" '[ -n "$s0" ] && [ "$s1" != "$s0" ] && [ "$s2" != "$s0" ] && [ "$s2" != "$s1" ]'
cp -p "$T/game.orig" "$S/moved.nsp"; ck "src_sample：同内容挪到别的路径 → 不变（挪位置不重解）" '[ "$(src_sample "$S/moved.nsp")" = "$s0" ]'
cp "$T/game.orig" "$T/other"; python3 -c "import sys; p=sys.argv[1]; b=bytearray(open(p,'rb').read()); b[150000]^=1; open(p,'wb').write(b)" "$T/other"
mv "$T/other" "$S/game.nsp"; touch -r "$T/game.orig" "$S/game.nsp"; i1=$(src_ident "$S/game.nsp")
ck "src_ident：换成另一份同大小文件、修改时间改回原值 → 变（${i0} → ${i1}）" '[ -n "$i0" ] && [ "$i1" != "$i0" ] && [ "${i1%% *}" = "${i0%% *}" ]'
i2=$(src_ident "$S/game.nsp"); python3 -c "import sys; p=sys.argv[1]; b=bytearray(open(p,'rb').read()); b[7]^=1; open(p,'r+b').write(b)" "$S/game.nsp"; touch -r "$T/game.orig" "$S/game.nsp"; i3=$(src_ident "$S/game.nsp")
ck "src_ident：原地改写（inode 不变）、修改时间改回 → 变（ctime 纳秒）" '[ "${i3##* }" = "${i2##* }" ] && [ "$i3" != "$i2" ]'
[ $bad = 0 ] && echo "进包输入键单测全过（分母 ${n} 个进包文件）" || echo "进包输入键单测有不通"
exit $bad
