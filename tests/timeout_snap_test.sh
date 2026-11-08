#!/bin/bash
# 超时前抓现场包装单测（graphics/tools/timeout_snap.sh，约 160 秒）：bash tests/timeout_snap_test.sh
# 期望（按规则手写）：没超时原样返回命令退出码（0 / 3）、不写现场文件；超时（上限 12 秒，6 秒时抓现场）退出 124，现场文件有进程组 / vm_stat / sample 栈，
#   摘要一行能指出卡在 sleep 的 __semwait_signal；进程组里的孙进程（后台 sleep）一并被杀、不留残余
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
S=$H/graphics/tools/timeout_snap.sh
bash "$S" 30 "$T/a.txt" true; r=$?
ck "没超时退出 0：原样返回 0、不写现场" '[ $r = 0 ] && [ ! -e $T/a.txt ]'
bash "$S" 30 "$T/b.txt" bash -c 'exit 3'; r=$?
ck "没超时退出 3：原样返回 3" '[ $r = 3 ] && [ ! -e $T/b.txt ]'
tag=tsnap_$$_$RANDOM
# 墙钟只判下限（到上限才杀）与「远没到命令自己的 200 秒」（< 150）：10-29 列车线 mini 高负载误红类——原上限 28 / 42 / 60 秒只比期望多几秒，
#   起 bash、采 sample / vm_stat 在负载下就会超；错的写法（不按上限 / 停滞杀）要等命令自己睡满 200 秒以上
t0=$SECONDS; bash "$S" 20 "$T/c.txt" bash -c "sleep 200 & exec -a $tag sleep 201"; r=$?; dt=$((SECONDS - t0))
ck "超时：退出 124、约在上限 20 秒结束（实 ${dt} 秒）" '[ $r = 124 ] && [ $dt -ge 19 ] && [ $dt -lt 150 ]'
ck "现场文件：进程组、vm_stat、已杀进程组（不依赖 sample 能否起来）" 'grep -q "^### 进程组" $T/c.txt && grep -q "Pages free" $T/c.txt && grep -q "已杀进程组" $T/c.txt'
# 调用栈：sample 在高负载机器上可能来不及（10-23 mini 两次挡别线门禁）——每个被采进程要么有调用栈、要么有「没采到——原因」一行，二者必居其一；有栈就核内容
ck "每个被采进程：有调用栈或写明没采到的原因" 'n_ok=$(grep -c "^### sample" $T/c.txt); [ "$n_ok" -ge 1 ] && [ "$(grep -cE "^### sample .*(没采到——|）：$)" $T/c.txt)" = "$n_ok" ]'
# sample 起不来（模拟高负载：假 sample 只睡不写）：照样按时 124、现场写明每个进程「没采到——原因」、摘要记没采到、不留孤儿
mkdir -p $T/fakebin; printf '#!/bin/bash\nsleep 30\n' > $T/fakebin/sample; chmod +x $T/fakebin/sample
tagf=tsnapf_$$_$RANDOM
t0=$SECONDS; PATH=$T/fakebin:$PATH bash "$S" 20 "$T/f2.txt" bash -c "exec -a $tagf sleep 200"; rf=$?; df=$((SECONDS - t0)); sleep 1
ck "sample 起不来：退出 124、约在上限结束（实 ${df} 秒）、现场写明没采到原因、不留孤儿" '[ $rf = 124 ] && [ $df -ge 19 ] && [ $df -lt 150 ] && grep -q "没采到——" $T/f2.txt && grep -q "没采到" $T/f2.txt.digest && grep -q "已杀进程组" $T/f2.txt && ! pgrep -f "$tagf" > /dev/null && ! pgrep -f "$T/fakebin/sample" > /dev/null' 

ck "有栈时摘要能指出 sleep 卡在 __semwait_signal（没栈时摘要写「没采到」）" '{ grep -q "Call graph:" $T/c.txt && grep -q "__semwait_signal" $T/c.txt.digest; } || { ! grep -q "Call graph:" $T/c.txt && grep -q "没采到" $T/c.txt.digest; }' 
sleep 1
ck "孙进程（后台 sleep 200 与 sleep 201）不留残余" '! pgrep -f "$tag" > /dev/null && ! pgrep -f "^sleep 200$" > /dev/null'
# 按进度判（S2A_SNAP_STALL=21:<目录>，每 10 秒查一次新文件）两例并行跑：
#   d 每 2 秒在深两层的子目录里写一个新文件（判据只看目录修改时间，证明子目录里的新文件也算进度）、共 30 秒后退出 0：总上限 200，没有停滞 → 原样 0，用时约 30 秒（> 停滞 21 秒，证明进度续命生效）
#   e 写 6 秒后停写、睡 200 秒：最后产出约第 6 秒，查看最迟晚 10 秒 → 有效上限落在 [27, 37]，再加收尾 ≤ 3 秒 → 退出 124、用时 [25, 42]，现场写明按进度判
#   d2 同 d，但每次 sleep 都慢 1.25 倍（假 sleep 在 PATH 前面）：模拟满负载下看门狗每轮远不止 1 秒（10-31 mini 无缓存全套 d 例 25 秒被误杀）——
#   旧写法按「第 10 轮」查进度，10 轮 > 11 秒时查看前就过了抓现场点 → 误判停滞、124；查看须按墙钟，且到抓现场点先查一次再定 → 原样 0
mkdir -p "$T/pd/x/y" "$T/pe" "$T/pd2" "$T/slowbin"
printf '#!/bin/bash\nexec /bin/sleep "$(awk -v s="$1" '"'"'BEGIN { print s * 1.25 }'"'"')"\n' > "$T/slowbin/sleep"; chmod +x "$T/slowbin/sleep"
( t1=$SECONDS; S2A_SNAP_STALL=21:$T/pd bash "$S" 200 "$T/d.txt" bash -c "for i in \$(seq 15); do touch $T/pd/x/y/f\$i; sleep 2; done"; echo "$? $((SECONDS - t1))" > "$T/d.rc" ) &
( t1=$SECONDS; S2A_SNAP_STALL=21:$T/pe bash "$S" 200 "$T/e.txt" bash -c "for i in 1 2 3; do touch $T/pe/f\$i; sleep 2; done; exec -a ${tag}e sleep 200"; echo "$? $((SECONDS - t1))" > "$T/e.rc" ) &
( t1=$SECONDS; PATH=$T/slowbin:$PATH S2A_SNAP_STALL=21:$T/pd2 bash "$S" 200 "$T/d2.txt" bash -c "for i in \$(seq 15); do touch $T/pd2/f\$i; sleep 2; done"; echo "$? $((SECONDS - t1))" > "$T/d2.rc" ) &
wait
read rd dd < "$T/d.rc"; read re de < "$T/e.rc"; read rd2 dd2 < "$T/d2.rc"
ck "按进度：持续有新文件跑满 30 秒不被杀、原样退出 0（实 退出 ${rd}、${dd} 秒）" '[ "$rd" = 0 ] && [ "$dd" -ge 29 ] && [ ! -e $T/d.txt ]'
ck "按进度：看门狗每轮慢（负载）时持续有新文件照样不被杀、原样退出 0（实 退出 ${rd2}、${dd2} 秒）" '[ "$rd2" = 0 ] && [ "$dd2" -ge 36 ] && [ ! -e $T/d2.txt ]'
ck "按进度：停写后约停滞上限杀掉、退出 124（实 退出 ${re}、${de} 秒）" '[ "$re" = 124 ] && [ "$de" -ge 25 ] && [ "$de" -lt 150 ]'
ck "按进度：现场写明停滞秒数与最近文件" 'grep -q "按进度判：.*没有新文件，停滞上限 21 秒；最近的文件 f3" $T/e.txt'
ck "按进度：参数不合法退出 2" 'S2A_SNAP_STALL=5:$T bash "$S" 30 "$T/f.txt" true; [ $? = 2 ]'
# 嵌套：外层 timeout_snap（上限 25 秒）里跑内层 timeout_snap（上限 200 秒）里的 sleep；外层到上限杀它的组 → 内层收到 TERM 转发杀自己的命令组，不留孤儿
tagn=tsnapn_$$_$RANDOM
bash "$S" 25 "$T/g.txt" bash "$S" 200 "$T/h.txt" bash -c "exec -a $tagn sleep 300"; rg=$?
sleep 2
ck "嵌套：外层超时退出 124、内层命令（sleep 300）不留孤儿（退出 ${rg}）" '[ $rg = 124 ] && ! pgrep -f "$tagn" > /dev/null'
# 编译进程在算不算停滞（10-26 交付线：Air 上斯普拉遁3 单个大着色器 metal 编约 10 分钟、目录 590 秒没新文件被判挂死）：停滞上限 21 秒、总上限 200，
#   命令「在算」35 秒（不写文件）→ 不被杀、原样退出 0，用时约 35 秒（旧代码约第 21–31 秒判卡死退出 124）；
#   「在算」15 秒后停算睡 200 秒 → 照常按停滞杀、退出 124，现场记「编译进程在算」累计
#   「在算」用假 ps 给出（11-01 mini 无缓存全套两条红「实 退出 124、23 秒」：原先真空转，判据要每 10 秒涨 ≥ 1 秒 CPU，
#   334 步并发时空转进程分不到 10% 的核、CPU 涨不够被当停滞——调度份额随负载变，真空转测不成与负载无关的性质）：
#   开关文件在时（内容是建立时刻的 epoch 秒，不用 BSD 专有的 stat -f），假 ps 把命令进程树里每个进程的 CPU 时间报成「开关建立以来的墙钟秒数」（ps 原格式 分:秒.百分秒，照样走看门狗的解析），开关删掉即回真读数
mkdir -p $T/cd $T/ce $T/cpubin; CF=$T/cpu_on
cat > $T/cpubin/ps <<EOF
#!/bin/bash
case " \$* " in *time=*) if [ -e "$CF" ]; then s=\$(( \$(date +%s) - \$(cat "$CF") )); /bin/ps "\$@" | awk -v s="\$s" '{ printf "%s %d:%02d.00\n", \$1, int(s / 60), s % 60 }'; exit 0; fi;; esac
exec /bin/ps "\$@"
EOF
chmod +x $T/cpubin/ps
t0=$SECONDS; PATH=$T/cpubin:$PATH S2A_SNAP_STALL=21:$T/cd bash "$S" 200 "$T/cc.txt" bash -c "date +%s > $CF; sleep 35; exit 0"; rc_=$?; dc=$((SECONDS - t0)); rm -f $CF
ck "编译在算：在算 35 秒不写文件不被杀、原样退出 0（实 退出 ${rc_}、${dc} 秒）" '[ "$rc_" = 0 ] && [ "$dc" -ge 34 ] && [ ! -e $T/cc.txt ]'
t0=$SECONDS; PATH=$T/cpubin:$PATH S2A_SNAP_STALL=21:$T/ce bash "$S" 200 "$T/ce.txt" bash -c "date +%s > $CF; sleep 15; rm -f $CF; sleep 200"; rce=$?; dce=$((SECONDS - t0)); rm -f $CF
ck "在算后停算：照常按停滞杀、退出 124（实 退出 ${rce}、${dce} 秒），现场记在算累计" '[ "$rce" = 124 ] && [ "$dce" -ge 30 ] && [ "$dce" -lt 150 ] && grep -q "编译进程在算" $T/ce.txt'
[ $bad = 0 ] && echo "timeout_snap 单测全过" || echo "timeout_snap 单测有不通"
exit $bad
