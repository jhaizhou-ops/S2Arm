#!/bin/bash
# 宽屏第二层启用点跨版本移植单测（graphics/widen/scan/widen_sig.py，合成平铺映像，约 2 秒）：bash tests/widen_sig_test.sh
# 合成「旧版」main（4096 字，伪随机字，用确定的线性同余数列；不含跳转类编码以免被屏蔽规则误伤）里放三个点：
#   A 0x1000 aspdiv：fdiv s0,s0,s1 = 0x1e211800，前一字 bl #+0x40（0x94000010）、后两字 adrp x8,#0x1000（0x90000008）
#   B 0x2000 f32：数据 1920.0f = 0x44f00000
#   C 0x3000 movz：movz w8,#0x780 = 0x5280f008
# 「新版」= 前面多插 100 字（新偏移 = 旧 + 0x190）；A 前的 bl 立即数改成 #+0x80（0x94000020）、adrp 页改成 #0x3000（0xb0000008）——跳转量 / 页地址随版本变；
#   C 所在的前后 49 字原样再复制一份到末尾（新版里 C 的特征不唯一）。期望（手算，不跑被测实现）：
#   ① make：3 个点都有特征；② port：A → main:0x1190、B → main:0x2190 成功，C 不唯一，输出点集「main:0x1190,main:0x2190」、退出码 1；
#   ③ 新候选表里去掉 B 的新偏移 → B 判「不在新候选表里」，点集只剩 A
set -u
R=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/old" "$T/new"
"$PY" - "$T" <<'EOF'
import struct, sys
T = sys.argv[1]
x, w = 12345, []
for _ in range(4096):
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF; v = x | 0x01000000
    w.append(v & 0xE7FFFFFF if (v >> 26) in (0x05, 0x25) else v)   # 避开 B / BL 编码
def fix(a):   # 去掉会被屏蔽规则命中的编码（伪随机里偶然出现的），保证特征只由我们放的那几条决定
    out = []
    for v in a:
        if (v & 0xFF000010) == 0x54000000 or (v & 0x7E000000) in (0x34000000, 0x36000000) or (v & 0x1F000000) == 0x10000000 or (v & 0x3B000000) == 0x18000000: v ^= 0x08000000
        if (v >> 26) in (0x05, 0x25): v ^= 0x20000000
        out.append(v & 0xFFFFFFFF)
    return out
w = fix(w)
A, B, C = 0x1000 // 4, 0x2000 // 4, 0x3000 // 4
w[A - 1], w[A], w[A + 1], w[A + 2] = 0x94000010, 0x1e211800, 0x90000008, 0x90000008
w[B] = 0x44f00000; w[C] = 0x5280f008
open(f'{T}/old/main', 'wb').write(struct.pack(f'<{len(w)}I', *w))
n = fix([(i * 2654435761) & 0xFFFFFFFF for i in range(100)]) + list(w)
n[100 + A - 1], n[100 + A + 1] = 0x94000020, 0xb0000008
n += n[100 + C - 24:100 + C + 25]
open(f'{T}/new/main', 'wb').write(struct.pack(f'<{len(n)}I', *n))
open(f'{T}/old_sites.tsv', 'w').write('模块\t偏移\t种类\t证据\nmain\t0x1000\taspdiv\t1e211800\nmain\t0x2000\tf32\t1920.0,1080.0\nmain\t0x3000\tmovz\t5280f008\n')
open(f'{T}/new_sites.tsv', 'w').write('模块\t偏移\t种类\t证据\nmain\t0x1190\taspdiv\t1e211800\nmain\t0x2190\tf32\t1920.0,1080.0\nmain\t0x3190\tmovz\t5280f008\n')
open(f'{T}/new_sites_noB.tsv', 'w').write('模块\t偏移\t种类\t证据\nmain\t0x1190\taspdiv\t1e211800\nmain\t0x3190\tmovz\t5280f008\n')
EOF
S=$R/graphics/widen/scan/widen_sig.py; fail=0; ok() { echo "✓ $1"; }; bad() { echo "✗ $1"; fail=1; }
"$PY" "$S" make "$T/old" main:0x1000,main:0x2000,main:0x3000 "$T/old_sites.tsv" "$T/sig.tsv" 2> "$T/make.err"
[ "$(($(wc -l < "$T/sig.tsv") - 1))" = 3 ] && ok "① 3 个点都有特征" || { bad "① 特征数 $(($(wc -l < "$T/sig.tsv") - 1))，期望 3"; cat "$T/make.err"; }
LC_ALL=C /usr/bin/grep -q '1e211800' "$T/sig.tsv" && ! LC_ALL=C /usr/bin/grep -q '94000010' "$T/sig.tsv" && ok "① 特征只存摘要和点本身原字（不存前后代码）" || bad "① 特征文件里有前后代码字"
out=$("$PY" "$S" port "$T/new" "$T/sig.tsv" "$T/new_sites.tsv" 2> "$T/port.err"); rc=$?
[ "$out" = "main:0x1190,main:0x2190" ] && [ $rc = 1 ] && ok "② A / B 移植成功（跳转量、页地址变了也认），C 不唯一：点集 ${out}、退出码 $rc" || { bad "② 点集「${out}」退出码 ${rc}，期望 main:0x1190,main:0x2190 / 1"; cat "$T/port.err"; }
LC_ALL=C /usr/bin/grep -q '0x3000（movz）：新版本里不唯一' "$T/port.err" && ok "② C 判不唯一" || { bad "② C 没判不唯一"; cat "$T/port.err"; }
out=$("$PY" "$S" port "$T/new" "$T/sig.tsv" "$T/new_sites_noB.tsv" 2> "$T/port2.err")
[ "$out" = "main:0x1190" ] && LC_ALL=C /usr/bin/grep -q '0x2000（f32） → 0x2190：不在新候选表里' "$T/port2.err" && ok "③ 新偏移不在候选表里不算移植成功" || { bad "③ 点集「${out}」"; cat "$T/port2.err"; }
# 以下只生成合成映像与候选，不导入被测模块或拿其摘要 / 匹配结果反推期望。
# 80 字底图：第 32 字是 movz，其他字为 0x1000 + 下标。复制中心前后各 2 字，
# 两处 5 字相同、外侧第 3 字不同，所以 make 最小唯一半窗口 = 3。
# port 另用未复制的旧图（n0 = 2），新版前插 16 字并加同样的 5 字副本：
# 真点 32 + 16 = 48 字（0xc0），假点 16 + 80 + 32 + 2 = 130 字（0x208）；
# 两者在 n=2 重复，只有 0xc0 的 n=3 仍与旧图相同，必须升级窗口而非取首解。
"$PY" - "$S" "$T" <<'EOF' || fail=1
from pathlib import Path
import struct
import subprocess
import sys

tool, root = Path(sys.argv[1]), Path(sys.argv[2]) / 'contract'
old, new = root / 'old', root / 'new'
old.mkdir(parents=True)
new.mkdir()


def image(path, words):
    path.write_bytes(struct.pack(f'<{len(words)}I', *words))


def sites(path, rows):
    path.write_text('模块\t偏移\t种类\t证据\n' + ''.join(
        f'{module}\t{offset:#x}\t{kind}\tsynthetic\n'
        for module, offset, kind in rows), encoding='utf-8')


def cli(label, args, expected_rc, expected_out=None, error=None):
    result = subprocess.run([sys.executable, str(tool), *map(str, args)],
                            capture_output=True, text=True)
    if (result.returncode != expected_rc
            or (expected_out is not None and result.stdout != expected_out)
            or (error is not None and error not in result.stderr)):
        raise AssertionError(
            f'{label}: 期望 rc={expected_rc}, stdout={expected_out!r}, stderr含{error!r}; '
            f'实得 rc={result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r}')


def make(label, words, kind, expected_half):
    image(old / 'main', words)
    sites(root / 'old.tsv', [('main', 0x80, kind)])
    cli(label, ['make', old, 'main:0x80', root / 'old.tsv', root / 'sig.tsv'], 0, '')
    rows = (root / 'sig.tsv').read_text(encoding='utf-8').splitlines()
    if len(rows) != 2 or rows[1].split('\t')[3] != str(expected_half):
        raise AssertionError(f'{label}: 期望仅 1 点、最小半窗口 {expected_half}，实得 {rows!r}')


def port(label, rc, output, error=None):
    cli(label, ['port', new, root / 'sig.tsv', root / 'new.tsv'], rc, output, error)


words = [0x1000 + i for i in range(80)]
words[32] = 0x5280f008
padding = [0x3000 + i for i in range(32)]
tail = [0x4000 + i for i in range(32)]
copy = words[30:35]
make('④ make 扩窗', words + padding + copy + tail, 'movz', 3)
print('✓ ④ 旧图最小窗口重复，make 选择手算唯一半窗口 3')

make('⑤ port 扩窗前提', words, 'movz', 2)
shifted = [0x2000 + i for i in range(16)] + words + padding + copy + tail
image(new / 'main', shifted)
sites(root / 'new.tsv', [('main', 0xc0, 'movz'), ('main', 0x208, 'movz')])
port('⑤ port 扩窗', 0, 'main:0xc0\n')
print('✓ ⑤ 新图 n=2 两解、n=3 唯一，port 只移植到 main:0xc0')

sites(root / 'new.tsv', [('main', 0xc0, 'f32')])
port('⑥ 候选种类保护', 1, '\n', '不在新候选表里（f32）')
print('✓ ⑥ 唯一字节匹配但候选种类不同，点集为空、退出码 1')

sites(root / 'new.tsv', [('main', 0xc0, 'movz'), ('sdk', 0xc0, 'movz')])
(new / 'main').rename(new / 'sdk')
port('⑦ 模块身份保护', 1, '\n', '新版本没有模块 main')
(new / 'sdk').rename(new / 'main')
print('✓ ⑦ main 缺失，sdk 中相同字节和候选不能替代，点集为空、退出码 1')

# 数据类的中心值分别为 1920.0f、16/9、整数 1920。相邻数据字恰好像 BL：
# 0x94000010 → 0x94000020；代码类会屏蔽其位移，但数据类必须逐字匹配。
# 每类先验证只平移时成功，再仅改该邻字，最小窗口已不等，期望无匹配。
for kind, centre in [('f32', 0x44f00000), ('aspf', 0x3fe38e39), ('i32', 1920)]:
    data = [0x1000 + i for i in range(80)]
    data[31], data[32] = 0x94000010, centre
    make(f'⑧ {kind} make', data, kind, 2)
    shifted = [0x2000 + i for i in range(16)] + data
    image(new / 'main', shifted)
    sites(root / 'new.tsv', [('main', 0xc0, kind)])
    port(f'⑧ {kind} 仅平移', 0, 'main:0xc0\n')
    shifted[47] = 0x94000020
    image(new / 'main', shifted)
    port(f'⑧ {kind} 数据变化', 1, '\n', '新版本里找不到')
    print(f'✓ ⑧ {kind} 平移成功；似指令的数据变化不屏蔽，点集为空、退出码 1')

# 单独覆盖 port 的「中心原字」防线：人工候选用代码类 movz，但中心刻意填 BL，
# 仅测试调用方给定表的防御契约，不声称 wide_scan 会把 BL 认成 movz。
# 中心 BL 的位移变化在摘要中被屏蔽，仍有唯一匹配；原字不同必须拒绝。
words = [0x1000 + i for i in range(80)]
words[32] = 0x94000010
make('⑨ 原字保护前提', words, 'movz', 2)
shifted = [0x2000 + i for i in range(16)] + words
shifted[48] = 0x94000020
image(new / 'main', shifted)
sites(root / 'new.tsv', [('main', 0xc0, 'movz')])
port('⑨ 中心原字保护', 1, '\n', '原字 94000020 ≠ 旧 94000010')
print('✓ ⑨ 屏蔽后唯一匹配但中心原字改变，点集为空、退出码 1')
EOF
[ $fail = 0 ] && echo "✓ widen_sig_test" || echo "✗ widen_sig_test"
exit $fail
