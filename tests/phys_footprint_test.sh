#!/bin/bash
# 快测内存判据（runtime/run_mac.sh 按物理足迹判，tools/phys_footprint.py 取 proc_pid_rusage ri_phys_footprint，与 iOS 判杀同口径）单测
# 门禁覆盖：runtime/run_mac.sh tools/phys_footprint.py
# 期望值由用例构造决定，不跑被测实现推：① 只读映射并读满 300 MB 文件的进程：常驻页集 ≥ 250 MB、足迹 < 100 MB；② 写满 300 MB 匿名内存的进程：足迹 ≥ 250 MB；
#   ③ 真 run_mac.sh（依赖打桩、上限 150 MB）：①那种假宿主不被杀、正常收局；②那种被杀，红字同时有「物理足迹」与「常驻页集」两个读数
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'kill $A $B 2>/dev/null; rm -rf "$T"' EXIT; bad=0; A=; B=
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${S2A_PY:-python3}
dd if=/dev/urandom of="$T/big.bin" bs=1m count=300 2>/dev/null
cat > "$T/fake.py" <<'P'
import mmap, os, sys, time
mode, path, hold = sys.argv[1], sys.argv[2], float(sys.argv[3])
if mode == 'map':
    f = open(path, 'rb'); m = mmap.mmap(f.fileno(), 0, prot=mmap.PROT_READ); s = 0
    for i in range(0, len(m), 16384): s += m[i]
else:
    b = bytearray(300 << 20)
    for i in range(0, len(b), 16384): b[i] = 1
print('ready', flush=True); time.sleep(hold)
P
"$PY" "$T/fake.py" map "$T/big.bin" 30 > "$T/a.out" & A=$!
"$PY" "$T/fake.py" dirty x 30 > "$T/b.out" & B=$!
for i in $(seq 1 60); do grep -q ready "$T/a.out" && grep -q ready "$T/b.out" && break; sleep 0.5; done
read fa ra <<< "$("$PY" -B "$H/tools/phys_footprint.py" $A --rss)"; read fb rb <<< "$("$PY" -B "$H/tools/phys_footprint.py" $B --rss)"
ck "① 只读映射 300 MB：常驻页集 ${ra} KB ≥ 250 MB、足迹 ${fa} KB < 100 MB" '[ "${ra:-0}" -ge 256000 ] && [ "${fa:-999999999}" -lt 102400 ]'
ck "② 写满 300 MB 匿名内存：足迹 ${fb} KB ≥ 250 MB" '[ "${fb:-0}" -ge 256000 ]'
"$PY" -B "$H/tools/phys_footprint.py" 999999 > /dev/null 2>&1; r=$?
ck "取不到（进程不在）退出 1（rc=${r}）" '[ $r = 1 ]'
kill $A $B 2>/dev/null; wait $A $B 2>/dev/null; A=; B=
# ③ 真 run_mac.sh：依赖打桩
R=$T/repo; mkdir -p $R/native $R/tools $R/build $T/in; cp "$H/runtime/run_mac.sh" $R/runtime/; cp "$H/tools/phys_footprint.py" "$H/tools/host_build.sh" $R/tools/; : > $T/in/main.patched.bin
printf 'import sys\nsys.exit(0)\n' > $R/tools/mac_chain_check.py
echo 'mac_save_prep() { :; }' > $R/tools/mac_save.sh; printf 'mac_slot_acquire() { :; }\nmac_slot_release() { :; }\n' > $R/tools/mac_slot.sh; cp $H/tools/mac_slot_frozen.sh $H/tools/s2a_machine.sh $R/tools/; export S2A_MAC_SLOT_BIN=$R/tools/mac_slot.sh; echo 'cost_log() { :; }' > $R/tools/cost_log.sh
printf 'host:\n\t@true\n' > $R/Makefile
printf '#!/bin/bash\nexec %s %s "$FAKE_MODE" %s 6\n' "$PY" "$T/fake.py" "$T/big.bin" > $R/build/s2arm-host; chmod +x $R/build/s2arm-host
o=$(FAKE_MODE=map S2A_PY=$PY S2A_MEM_MB=150 S2A_IN=$T/in S2A_SAVE_DIR= bash $R/runtime/run_mac.sh fake $T/d1 20 2>&1); r=$?
ck "③ 常驻页集超 150 MB 而足迹不超：不被杀、正常收局（rc=${r}）" '[ $r = 0 ] && ! grep -q "超上限" "$T/d1/host.log" && grep -q "收局 rc=0" <<< "$o"'
o=$(FAKE_MODE=dirty S2A_PY=$PY S2A_MEM_MB=150 S2A_IN=$T/in S2A_SAVE_DIR= bash $R/runtime/run_mac.sh fake $T/d2 20 2>&1); r=$?
ck "③ 足迹超 150 MB：被杀判红，两个读数都打（$(grep -o '物理足迹.*' "$T/d2/host.log" | head -1)）" '[ $r = 1 ] && grep -q "物理足迹 [0-9]* KB 超上限 153600 KB（常驻页集 [0-9]* KB）" "$T/d2/host.log"'
[ $bad = 0 ] && echo "✓ phys_footprint_test：全部通过" || { echo "✗ phys_footprint_test：有不通"; exit 1; }
