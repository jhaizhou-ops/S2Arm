#!/bin/bash
# tools/alt_report.py 单测（同局交替开关窗口报表）：造 4 段（关 / 开 / 关 / 开）各 30 帧 + 每段边界功耗采样，期望全按造数手算：
#   关段每帧 33333 µs、读回 1000 µs、功耗 4.0 W；开段每帧 30000 µs、读回 0、功耗 3.5 W（段内 a→b 两次采样之间；护边里的 9.0 W 不得算进去）；MARK 前 5 帧 alt = 0 不计
#   汇总关：读回 30.0 ms/秒、帧率 30.00；汇总开：读回 0.0、帧率 33.33；相邻差只有第 1 段（第 3 段右侧没有关段）：读回 −30.0、帧率 +3.33、功耗 −0.50 W
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
python3 - "$T" <<'PY'
import plistlib, sys, os
o = sys.argv[1]
with open(os.path.join(o, 'frames.tsv'), 'w') as f:
    f.write('frame\twall_us\trb_us\tdraw_n\talt\n'); n = 0
    for _ in range(5): n += 1; f.write(f'{n}\t50000\t9999\t10\t0\n')
    for seg in range(4):
        on = seg % 2 == 1
        for _ in range(30): n += 1; f.write(f'{n}\t{30000 if on else 33333}\t{0 if on else 1000}\t{3000 if on else 3100}\t{2 if on else 1}\n')
acc = 0; cnt = 0
def dump(name):
    plistlib.dump({'IORegistry': {'PowerTelemetryData': {'AccumulatedSystemLoad': acc, 'SystemLoadAccumulatorCount': cnt}}}, open(os.path.join(o, name), 'wb'))
for k in range(4):   # 每段 a / b 两次采样之间 10 次累计：关段 4000、开段 3500（毫瓦）；段与段之间（护边里）另有 3 次 9000 的累计，必须不算进任何一段
    acc += 9000 * 3; cnt += 3; dump(f'pwalt_{k}a.plist')
    acc += (3500 if k % 2 else 4000) * 10; cnt += 10; dump(f'pwalt_{k}b.plist')
PY
out=$(python3 "$H/tools/alt_report.py" "$T" --fps=30)
echo "$out" | sed 's/^/    /'
ck "汇总关：读回 30.0 ms/秒、帧率 30.00、功耗 4.0 W" 'echo "$out" | grep -q "汇总 关：2 段，读回 30.0 ms/秒，帧率 30.00.*功耗 4.0 W"'
ck "汇总开：读回 0.0、帧率 33.33、功耗 3.5 W" 'echo "$out" | grep -q "汇总 开：2 段，读回 0.0 ms/秒，帧率 33.33.*功耗 3.5 W"'
ck "相邻差：1 组，读回 −30.0、帧率 +3.33、功耗 −0.50 W" 'echo "$out" | grep -q "相邻差（开段 − 前后关段平均，1 组）：读回 -30.0 ms/秒，帧率 +3.33，功耗 -0.50 W"'
ck "MARK 前（alt = 0）的帧不算：第 0 段 30 帧" 'echo "$out" | grep -q "^ 0 关     30"'
rm -f "$T/pwalt_1b.plist"
ck "缺第 1 段 b 采样：那段功耗未测、相邻差功耗未测" 'o3=$(python3 "$H/tools/alt_report.py" "$T" --fps=30); echo "$o3" | grep -q "^ 1 开.*None$" && echo "$o3" | grep -q "功耗 未测"'
rm -f "$T/frames.tsv"; printf 'frame\twall_us\trb_us\tdraw_n\n1\t1\t0\t0\n' > "$T/frames.tsv"
ck "没有 alt 列：报没有交替段、退出 1" 'python3 "$H/tools/alt_report.py" "$T" > "$T/o2" 2>&1; [ $? = 1 ] && grep -q "没有交替段" "$T/o2"'
[ $bad = 0 ] && echo "✓ alt_report_test 全过" || echo "✗ alt_report_test 有不通"
exit $bad
