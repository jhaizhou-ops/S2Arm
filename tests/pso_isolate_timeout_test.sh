#!/bin/bash
# 管线隔离超时单测（graphics/tools/shbake/pso_isolate.py、pso_chunk.sh；审计 #806 第 4 条 F-pso-iso-orphan，约 20 秒）：
#   原先 subprocess.run(timeout=600) 超时 → 当「这一半编不过」继续劈、劈到单条记进坏清单（好管线被丢、运行时现编），且只杀直接子进程，编译器拉起的孙进程被过继后继续占核。
#   假 applegpu-nt（桩）：脚本里有 BAD 标签的立即退出 1；有 SLOW 标签的起一个带唯一标记的孙进程 sleep 300 再自己 sleep 301（模拟编不完）；其余写出归档退出 0。
#   隔离试编上限 PSO_ISO_TIMEOUT=10；外层再包 40 秒（仓库 tools/bin/timeout），修前（写死 600 秒）在这里被截住、判红。
#   ① 首次试编就超时（G1 G2 SLOW G3）：退出 1（按整片失败）、输出说明超时、坏清单不写 SLOW、试编只 1 次、超时后带标记的孙进程不留、总用时 < 40 秒
#   ② 二分途中超时（BAD G1 SLOW G2）：同样退出 1、坏清单不写 SLOW、孙进程不留（超时不等于这支坏，劈到哪儿都一样）
#   ③ 回归：没有超时（G1 BAD G2 G3）照旧隔离出 BAD、其余编成归档、退出 0
#   ④ graphics/tools/shbake/pso_chunk.sh 整片编译就超时（SLOW G1；PATH 前放一个把上限 600 换成 10 秒的 timeout 替身，内部仍是仓库 perl 版）：
#     期望写 .fail、不进隔离（试编只有整片那 1 次、日志没有 pso_isolate 行、有 pso_chunk 的「整片编译超时」行）、没有 .bad、孙进程不留——原先进隔离再白等一轮上限
#   ④–⑧ 半截归档（审计 #872 F-pso-timeout-partial）：桩在出错前先往 -o 写一截（SLOW 写 4096 字节再睡、BAD 写 100 字节再退 1），模拟编译器写到一半被杀 / 崩。
#     原先 pso_chunk.sh 直接编到正式归档名，失败只写 .fail 不删半截，shader_pack 把它当这片的归档收进部分包、阶段键记下后不再重烘。
#     期望每种失败形态都是「.fail 在、产物目录里没有这片的归档、不留临时件」：④ 整片超时；⑤ 单条管线的片编译崩；⑥ 多条管线、隔离也失败（PSO_ISO_MAX_BAD=0）；
#     ⑦ Metal 3 老格式（PSO_M3=1，PATH 前放假 xcrun：metal-tt 写一截后退 1）；⑧ 回归：编成功 → 正式归档名下是桩写的内容、没有 .fail、不留临时件
set -u; R=$(cd "$(dirname "$0")/.." && pwd); ISO=$R/graphics/tools/shbake/pso_isolate.py; TO=$R/tools/bin/timeout; T=$(mktemp -d); bad=0
TAG=psoiso_$$_$(date +%s)
reap() { local p; for p in $(pgrep -f "$TAG" 2> /dev/null); do kill -KILL "$p" 2> /dev/null; done; }   # 只杀带本测试唯一标记的进程（按进程号）
trap 'reap; rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
alive() { pgrep -f "$TAG" > /dev/null; }
cat > $T/nt <<NT
#!/bin/bash
while [ \$# -gt 0 ]; do case \$1 in -N) S=\$2; shift;; -o) O=\$2; shift;; esac; shift; done
echo x >> "$T/tries"
grep -q '"lbl:BAD"' "\$S" && { head -c 100 /dev/zero > "\$O"; echo "LLVM ERROR: Failed to encode" >&2; exit 1; }
grep -q '"lbl:SLOW"' "\$S" && { head -c 4096 /dev/zero > "\$O"; (exec -a $TAG sleep 300) & exec sleep 301; }
echo arc > "\$O"; exit 0
NT
chmod +x $T/nt
mk() { python3 - "$@" <<'PY'
import json, sys
out, labs = sys.argv[1], sys.argv[2:]
json.dump({'function_descriptors': {'library_function_descriptors': [{'label': l, 'name': 'fn_' + l} for l in labs]},
           'pipeline_descriptors': {'render_pipeline_descriptors': [{'vertex_function_descriptor': 'lbl:' + l} for l in labs], 'compute_pipeline_descriptors': []}}, open(out, 'w'))
PY
}
# 上限：要测超时的例（带 SLOW）用 10 秒（SLOW 睡 301 秒，上限多大都分得开；上限要盖住的是桩从起进程到记下「试编 1 次」这段，
#   11-02 mini 普查并发时 2 秒不够：桩还没写进 tries 就被杀，① 实得 0 次假红）；不带 SLOW 的回归例用 ISO_TO=30——2 秒对它们没有要证明的东西，只会在满负载机器上误伤（10-31 合入线：mini 全套并发时 ③ 试编超 2 秒红）
run() { rm -f $T/tries $T/out $T/bad; s=$SECONDS; o=$(PSO_ISO_TIMEOUT=${ISO_TO:-10} $TO 40 python3 "$ISO" $T/$1.json $T/out $T/bad -- $T/nt 2>&1); r=$?; d=$((SECONDS - s)); sleep 1
  nt=$(wc -l < $T/tries 2> /dev/null | tr -d ' '); bl=$(cat $T/bad 2> /dev/null | tr '\n' ' '); }
mk $T/a.json G1 G2 SLOW G3; run a
ck "① 首次试编超时：退出 1（rc=${r}，${d} 秒）" '[ $r = 1 ]'
ck "① 输出说明是超时、不记坏管线（$(tail -1 <<< "$o")）" 'grep -q "超时" <<< "$o"'
ck "① 坏清单不写 SLOW（坏清单：${bl:-空}）" '! grep -q fn_SLOW $T/bad 2> /dev/null'
ck "① 超时后不再二分：试编 1 次（实得 ${nt:-0}）" '[ "${nt:-0}" = 1 ]'
ck "① 超时后孙进程（带标记的 sleep 300）不留" '! alive'
ck "① 总用时 < 40 秒（隔离自己的上限生效，没被外层截住）（${d} 秒）" '[ $r != 124 ] && [ $d -lt 40 ]'
reap
mk $T/b.json BAD G1 SLOW G2; run b
ck "② 二分途中超时：退出 1（rc=${r}，${d} 秒，试编 ${nt:-0} 次）" '[ $r = 1 ]'
ck "② 坏清单不写 SLOW（坏清单：${bl:-空}）" '! grep -q fn_SLOW $T/bad 2> /dev/null'
ck "② 超时后孙进程不留" '! alive'
reap
mk $T/c.json G1 BAD G2 G3; ISO_TO=30 run c
ck "③ 无超时：退出 0、坏清单只有 BAD、归档写出（rc=${r}，坏清单：${bl:-空}）" '[ $r = 0 ] && [ "$bl" = "fn_BAD " ] && [ -s $T/out ]'
reap
mkdir -p $T/tb $T/w $T/o; printf '#!/bin/bash\nshift; exec "%s" "${CHUNK_TO:-10}" "$@"\n' "$TO" > $T/tb/timeout; chmod +x $T/tb/timeout
mk $T/w/pso.30.mtl4-json SLOW G1; rm -f $T/tries; s=$SECONDS
PATH=$T/tb:$PATH PSO_ISO_TIMEOUT=10 PSO_NT=$T/nt PSO_A=g PSO_PLAT=ios PSO_M=27 PSO_SV=27.0 PSO_SP=/x PSO_NTV=v1 PSO_SIG=s PSO_PC=$T/pc PSO_O=$T/o PSO_W=$T/w \
  $TO 60 bash $R/graphics/tools/shbake/pso_chunk.sh $T/w/pso.30.mtl4-json > $T/chunk.out 2>&1; r=$?; d=$((SECONDS - s)); sleep 1
nt=$(wc -l < $T/tries 2> /dev/null | tr -d ' '); lg=$(cat $T/w/pso_g.ios27.30.log 2> /dev/null)
ck "④ 整片超时：退出 0、写 .fail、没有 .bad、没有归档（rc=${r}，${d} 秒）" '[ $r = 0 ] && [ -e $T/w/pso_g.ios27.30.fail ] && [ ! -e $T/w/pso_g.ios27.30.bad ] && [ ! -e $T/o/gal_pso.g.ios27.30.bin ]'
ck "④ 不进隔离：试编只有整片 1 次（实得 ${nt:-0}）、日志没有 pso_isolate 行" '[ "${nt:-0}" = 1 ] && ! grep -q "pso_isolate：" <<< "$lg"'
ck "④ 日志是 pso_chunk 报的整片超时（$(tail -1 <<< "$lg")）" 'grep -q "pso_chunk：整片编译超时" <<< "$lg"'
ck "④ 超时后孙进程不留" '! alive'
ck "④ 不留半截归档与临时件（产物目录：$(ls -A $T/o | tr '\n' ' ')；工作目录：$(ls -A $T/w | tr '\n' ' ')）" '[ -z "$(ls -A $T/o)" ] && ! ls -A $T/w | grep -q "\.bin"'
reap
# ⑤–⑧：都不带 SLOW，整片与隔离上限给 30 秒（同上，不按秒数赌负载）；每片用干净的产物 / 工作目录跑一次 pso_chunk.sh；chunk <分片文件名> [VAR=值…]（分片内容先由 mk 写到 $T/next.json）
chunk() { local f=$1; shift; rm -rf $T/o $T/w2; mkdir -p $T/o $T/w2; mv $T/next.json $T/w2/$f; rm -f $T/tries
  env PATH=$T/tb:$PATH CHUNK_TO=30 PSO_ISO_TIMEOUT=30 PSO_NT=$T/nt PSO_A=g PSO_PLAT=ios PSO_M=27 PSO_SV=27.0 PSO_SP=/x PSO_NTV=v1 PSO_SIG=s PSO_PC=$T/pc PSO_O=$T/o PSO_W=$T/w2 "$@" \
    $TO 60 bash $R/graphics/tools/shbake/pso_chunk.sh $T/w2/$f > $T/chunk.out 2>&1; r=$?
  left="产物目录：$(ls -A $T/o | tr '\n' ' ')；工作目录：$(ls -A $T/w2 | tr '\n' ' ')"; }
noarc() { [ -z "$(ls -A $T/o)" ] && ! ls -A $T/w2 | grep -q '\.bin'; }   # 产物目录空、工作目录里没有归档临时件
mk $T/next.json BAD; chunk pso.31.mtl4-json
ck "⑤ 单条管线的片编译崩：退出 0、写 .fail、不留半截归档（rc=${r}；${left}）" '[ $r = 0 ] && [ -e $T/w2/pso_g.ios27.31.fail ] && noarc'
mk $T/next.json BAD G1; chunk pso.32.mtl4-json PSO_ISO_MAX_BAD=0
ck "⑥ 隔离也失败：退出 0、写 .fail、没有 .bad、不留半截归档（rc=${r}；${left}）" '[ $r = 0 ] && [ -e $T/w2/pso_g.ios27.32.fail ] && [ ! -e $T/w2/pso_g.ios27.32.bad ] && noarc'
printf '#!/bin/bash\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && head -c 64 /dev/zero > "$2"; shift; done; exit 1\n' > $T/tb/xcrun; chmod +x $T/tb/xcrun
mk $T/next.json G1; chunk pso.33.mtlp-json PSO_M3=1 PSO_M3VER=27.0
ck "⑦ Metal 3 老格式编失败：退出 0、写 .fail、不留半截归档（rc=${r}；${left}）" '[ $r = 0 ] && [ -e $T/w2/pso_g.ios27.33.fail ] && noarc'
mk $T/next.json G1 G2; chunk pso.34.mtl4-json
ck "⑧ 回归：编成功 → 正式归档是桩写的内容、没有 .fail、不留临时件（rc=${r}；${left}）" '[ $r = 0 ] && [ "$(cat $T/o/gal_pso.g.ios27.34.bin 2> /dev/null)" = arc ] && [ ! -e $T/w2/pso_g.ios27.34.fail ] && ! ls -A $T/w2 | grep -q "\.bin"'
[ $bad = 0 ] && echo "管线隔离超时单测全过" || { echo "管线隔离超时单测有不通"; echo "$o"; exit 1; }
