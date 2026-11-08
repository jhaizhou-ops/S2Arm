#!/bin/bash
# 收集器拷贝失败单测（graphics/tools/shbake/shcollect.sh；审计 #806 第 3 条 F-shcollect-partial：四个 cp 不看退出码，拷失败照样 rm -rf 旧指纹目录、mv 临时目录顶上）：
#   S2A.ShBake guest-new 用桩（同 shcollect_pkg_test.sh：按缓存目录里 progs 文件的程序集合做差）。显式给一份候选缓存目录 c（程序 {a b c}，基准包 {a b}）。
#   ① 首轮：收进 <收集目录>/<程序号>/<指纹>/，四个缓存文件齐
#   ② 把那份的 shared.toc 换成标记「旧的完整一份」；预先放一个只读（555）的空 .tmp_<指纹>/，让第二轮四个 cp 都失败（同卷满 / 源中途不可读时 cp 失败；
#     只读文件不行：macOS cp -c 先删目标再克隆，10-28 实测照样成功）
#   期望（修后语义）：第二轮旧目录原样留着（shared.toc 仍是标记、四个文件都在）、临时目录删掉、输出有【红】点名拷失败、末行（出包只看 tail -1）报拷失败 1 份、退出非 0
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'chmod -R u+w "$T" 2> /dev/null; rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkc() { local d=$1; shift; mkdir -p $d; for f in shared.toc shared.data guest.toc guest.data; do echo "$d $f" > $d/$f; done; printf '%s\n' "$@" > $d/progs; }
cat > $T/sb <<'SB'
#!/bin/bash
[ "$1" = guest-new ] || exit 2
[ "${2:-}" = --code ] && shift
[ -f "$2/shared.toc" ] || { echo "没有 shared.toc"; exit 1; }
c=$2; shift 2; have=$(for h in "$@"; do cat "$h/progs" 2>/dev/null; done | sort -u)
n=0; m=0; while read -r p; do [ -n "$p" ] || continue; m=$((m + 1)); grep -qx "$p" <<< "$have" || n=$((n + 1)); done < "$c/progs"; echo "新 $n 总 $m"
SB
chmod +x $T/sb
TID=0100aaaa00000000; mkc $T/base/shaders/shcache/$TID a b; mkc $T/cand a b c
export S2A_SCHED_DIR=$T/sched S2A_SHBAKE=$T/sb S2A_SHCOLLECT_BASE=$T/base S2A_SHCOLLECT=$T/col
D=$T/col/g/$TID
o1=$(bash $H/graphics/tools/shbake/shcollect.sh g $T/cand 2>&1); fp=$(ls "$D" 2> /dev/null | head -1)
ck "① 首轮收进一份、四个缓存文件齐（指纹 ${fp:-无}）" '[ -n "$fp" ] && ( for f in shared.toc shared.data guest.toc guest.data; do [ -f "$D/$fp/$f" ] || exit 1; done )'
[ -n "$fp" ] || { echo "收集器拷贝失败单测有不通（首轮没收进）"; echo "$o1" | sed "s#$T/##g"; exit 1; }
echo "旧的完整一份" > "$D/$fp/shared.toc"
mkdir -p "$D/.tmp_$fp"; chmod 555 "$D/.tmp_$fp"
o2=$(bash $H/graphics/tools/shbake/shcollect.sh g $T/cand 2>&1); r2=$?
ck "② 拷失败：旧目录留着（shared.toc = 标记：$(cat "$D/$fp/shared.toc" 2> /dev/null || echo 不在)）" '[ "$(cat "$D/$fp/shared.toc" 2> /dev/null)" = "旧的完整一份" ]'
ck "② 拷失败：旧目录四个缓存文件都在（$(ls "$D/$fp" 2> /dev/null | tr '\n' ' ')）" '( for f in shared.toc shared.data guest.toc guest.data; do [ -f "$D/$fp/$f" ] || exit 1; done )'
ck "② 拷失败：临时目录 .tmp_${fp} 删掉" '[ ! -e "$D/.tmp_$fp" ]'
ck "② 拷失败：输出有【红】点名" 'grep -q "【红】shcollect：.*拷.*失败" <<< "$o2"'
ck "② 末行报拷失败 1 份（$(tail -1 <<< "$o2" | sed "s#$T/##g")）" 'tail -1 <<< "$o2" | grep -q "拷贝失败 1"'
ck "② 有拷失败时退出非 0（rc=${r2}）" '[ $r2 != 0 ]'
[ $bad = 0 ] && echo "收集器拷贝失败单测全过" || { echo "收集器拷贝失败单测有不通"; echo "$o2" | sed "s#$T/##g"; exit 1; }
