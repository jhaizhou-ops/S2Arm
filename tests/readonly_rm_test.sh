#!/bin/bash
# 只读 RomFS 的删除点（11-04 删除点普查）：删产物根 / 它的克隆 / 临时副本统一走 pack/roots.sh 的 _root_rm（先 chmod -R u+w 再删、软链只删链接），
#   收尾点要报错的走 _root_rm_red（删不掉只打一行【红】：路径 + 报错条数 + 首条原因）。RomFS 共享存储整棵只读（chmod -R a-w），
#   跟随软链克隆（cp -cRH）出来的副本照样只读，裸 rm -rf 删不掉、逐文件报 Permission denied、留几 GB 在临时目录。
#   ① pack/ipa.sh 只出程序：克隆出的只读 romfs 临时工作根，失败收尾（fail）后删干净；共享存储不动（仍只读、内容在）
#   ② 同上删不掉（macOS chflags uchg 锁住一个文件，chmod 解不开）：恰好 1 行【红】带临时根路径与首条原因、0 行 rm 原始报错
#   ③ pack/roots.sh _root_romfs_intern：上次残留的只读 .romfs.intern 先删干净，收进存储的身份内容 = 本次 romfs
#   ④ _root_rm_red 直测：只读树删净、返回 0、不出声；删不掉返回 1、恰好 1 行【红】（tools/quicktest/one_game.sh 的 qt_rm 即此函数，调用点由 tests/quicktest_test.sh ⑲ 覆盖）
# 负对照：ipa.sh 的 EXIT 陷阱换回原先的裸 rm -rf "$AOT" → ① 红；roots.sh 换回 rm -rf "$w/.romfs.intern" → ③ 红
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
trap 'chflags -R nouchg "$T" 2> /dev/null; chmod -R u+w "$T" 2> /dev/null; rm -rf "$T"' EXIT
chk() { if [ "$2" = "$3" ]; then echo "🟢 $1：$3"; else echo "🔴 $1：期望 $2 → 真结果 $3"; bad=1; fi; }
MAC=0; [ "$(uname -s)" = Darwin ] && MAC=1

# 产物根夹具 <S2A_ROOTS> [lock]：zz@v1 的 romfs 是指向只读存储 .romfs_store/zz/id1 的软链；有改写产物、发布口径能力清单（widen 0：宽屏核对直接过）、
#   control.nacp 标题，故意缺 s2a_caps.all.tsv——只出程序克隆完、编译前在「产物根没有包内能力清单」处 fail，走失败收尾
mkroot() {
  local r=$1 s=$1/.romfs_store/zz/id1 v=$1/zz@v1
  mkdir -p "$s/data/sub" "$v/exefs" "$v/ctl" && echo a > "$s/data/sub/a.bin" && echo b > "$s/top.bin" || return 1
  [ "${2:-}" = lock ] && chflags uchg "$s/top.bin"
  chmod -R a-w "$s" 2> /dev/null; ln -s ../.romfs_store/zz/id1 "$v/romfs"
  python3 - "$v" << 'PY'
import sys
v = sys.argv[1]
h = bytearray(0x100); h[:4] = b'NSO0'; h[0x40:0x50] = bytes(range(16)); open(v + '/exefs/main', 'wb').write(h)
n = bytearray(0x4000); t = '只读删除单测'.encode(); n[:len(t)] = t; open(v + '/ctl/control.nacp', 'wb').write(n)
open(v + '/main.patched.bin', 'wb').write(b'p'); open(v + '/s2a_caps.tsv', 'w').write('widen\t0\n')
PY
}
# macOS 的 mktemp 不带模板时不看 TMPDIR（取用户临时目录），ipa.sh 的临时工作根就落在那里：桩只把不带模板的调用落到 ${MK_DIR}，其余原样交给真 mktemp
mkdir -p "$T/bin"; cat > "$T/bin/mktemp" << 'SH'
#!/bin/bash
for a in "$@"; do case $a in -*) ;; *) exec /usr/bin/mktemp "$@";; esac; done
exec /usr/bin/mktemp "$@" "$MK_DIR/t.XXXXXX"
SH
chmod +x "$T/bin/mktemp"
ao() { mkdir -p "$1/mk" "$1/out"; env PATH="$T/bin:$PATH" MK_DIR="$1/mk" S2A_ROOTS="$1/roots" S2A_PACK_LOCKS="$1/locks" S2A_DISK_FREE_G=999 S2A_SIGN=adhoc \
  S2A_WIDEN_AUTO_RUN=0 S2A_APP_ONLY_FROM="$1/roots/zz@v1" S2A_APP_ONLY_OUT="$1/out" bash "$H/pack/ipa.sh" zz > "$1/ipa.out" 2>&1; echo $?; }
left() { find "$1/mk" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '; }

if [ $MAC = 1 ]; then
  A=$T/a; mkroot "$A/roots"; rc=$(ao "$A")
  chk "① 只出程序走到克隆之后的失败收尾（退 1、报缺包内能力清单）" "1 1" "$rc $(grep -c '【红】zz 出包：产物根没有包内能力清单' "$A/ipa.out")"
  chk "① 临时工作根删干净（剩几个）、0 行 rm 原始报错、0 行【红】删不掉" "0 0 0" "$(left "$A") $(grep -c '^rm: ' "$A/ipa.out") $(grep -c '删不掉' "$A/ipa.out")"
  chk "① 共享存储不动：仍只读、文件在" "ro yes" "$([ -w "$A/roots/.romfs_store/zz/id1/data" ] && echo rw || echo ro) $([ -f "$A/roots/.romfs_store/zz/id1/data/sub/a.bin" ] && echo yes || echo no)"
  B=$T/b; mkroot "$B/roots" lock; rc=$(ao "$B")
  chk "② 删不掉：退 1、恰好 1 行【红】带临时根路径、0 行 rm 原始报错" "1 1 0" "$rc $(grep '【红】' "$B/ipa.out" | grep -c "zz 只出程序（临时工作根）：删不掉 $B/mk/t\.") $(grep -c '^rm: ' "$B/ipa.out")"
  chk "② 删不掉：红行带首条原因（锁住的克隆文件 top.bin）" 1 "$(grep '删不掉' "$B/ipa.out" | grep -c 'top\.bin.*Operation not permitted')"
else echo "⚪ ①② pack/ipa.sh 只出程序要 Xcode（非 macOS），跳过"; fi

# ③ 收存储前残留的 .romfs.intern（上次收存储中途失败留下：顶层可写、里面整棵只读）
C=$T/c/roots; v=x; w=$C/zz@$v.tmp; mkdir -p "$w/romfs/d" "$w/.romfs.intern/old/deep"; echo new > "$w/romfs/d/n.bin"; echo old > "$w/.romfs.intern/old/deep/o.bin"
chmod -R a-w "$w/romfs" "$w/.romfs.intern/old"
rc=$(S2A_ROOTS=$C bash -c 'source "$1/pack/roots.sh"; _root_romfs_intern "$2" zz > /dev/null 2>&1; echo $?' _ "$H" "$w")
id=$(readlink "$w/romfs" 2> /dev/null); id=${id##*/}
chk "③ 残留只读 .romfs.intern：收存储退 0、残留删掉、身份内容 = 本次 romfs" "0 gone d/n.bin" \
  "$rc $([ -e "$w/.romfs.intern" ] && echo left || echo gone) $( [ -n "$id" ] && cd "$C/.romfs_store/zz/$id" 2> /dev/null && find . -type f | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"

# ④ _root_rm_red 直测
D=$T/d; mkdir -p "$D/x/y/z"; echo q > "$D/x/y/z/f"; chmod -R a-w "$D/x"
o=$(bash -c 'source "$1/pack/roots.sh"; _root_rm_red "$2" 谁; echo "rc=$?"' _ "$H" "$D/x")
chk "④ 只读树：删净、返回 0、不出声" "gone rc=0" "$([ -e "$D/x" ] && echo left || echo gone) $o"
if [ $MAC = 1 ]; then
  mkdir -p "$D/k/y"; echo q > "$D/k/y/f"; chflags uchg "$D/k/y/f"; chmod -R a-w "$D/k" 2> /dev/null
  o=$(bash -c 'source "$1/pack/roots.sh"; _root_rm_red "$2" 谁; echo "rc=$?"' _ "$H" "$D/k")
  chk "④ 删不掉：返回 1、恰好 2 行输出（1 行【红】+ rc）、红行带路径与首条原因" "rc=1 2 1" \
    "$(tail -1 <<< "$o") $(grep -c . <<< "$o") $(grep -c "^【红】谁：删不掉 $D/k（.*条报错，首条：rm: $D/k/y/f: Operation not permitted" <<< "$o")"
else echo "⚪ ④ 删不掉：本机没有 chflags（非 macOS），跳过"; fi

[ $bad = 0 ] && echo "只读删除点单测全过" || { echo "只读删除点单测有不通"; exit 1; }
