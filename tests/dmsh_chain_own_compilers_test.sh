#!/bin/bash
# 门禁覆盖：translator/dmsh_chain.py graphics/tools/direct/direct_lib.sh tests/dmsh_chain_own_compilers_test.sh
# 直连整份出库前核工具（dmsh_chain.py --build-env → own_compilers）：Xcode 与锁不同的机器照常出包（11-02 合入线对照 #1：C# 迁移删了 own_compilers.py 后每款出库前退出）。约 1 秒：bash tests/dmsh_chain_own_compilers_test.sh
#   期望（手写）：只有 metal_macosx / metal_iphoneos 版本不同 → 全放行、照停为空；编译器缺失（actual missing）→ 照停；spirv-cross / 翻译器 dll / 翻译器源码不符 → 照停；混合时各归各
#   不同编译器编的库不会被复用由 graphics/tools/direct/tests/t_unity.py ⑦ 实测（假 xcrun 报另一版本 → 新编、换回 → 命中）
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
cd "$H/translator" && exec python3 - <<'PY'
import dmsh_chain
import os, subprocess, sys, tempfile
from pathlib import Path
M = 'metal_macosx: lock Apple metal version 32023.921 (metalfe-32023.921.6) / actual Apple metal version 32023.883 (metalfe-32023.883)'
I = 'metal_iphoneos: lock Apple metal version 32023.921 (metalfe-32023.921.6) / actual Apple metal version 32100.1 (metalfe-32100.1)'
MISS = 'metal_iphoneos: lock Apple metal version 32023.921 (metalfe-32023.921.6) / actual missing'
SC = 'spirv-cross: lock 1.4.363.0 / actual 1.4.400.0'; DLL = 'dmsh_xlate.dll: lock 047a08dc50dca83f / actual 0000000000000000'
SRC = 'the translator was not built from the in-repo source: embedded source a / in repo b (rebuild dmsh_xlate_bin)'
bad = checks = 0
def ck(name, got, want):
    global bad, checks
    checks += 1
    ok = got == want; bad += not ok; print(('✓ ' if ok else '✗ ') + name + ('' if ok else f'：期望 {want}，实际 {got}'))
ck('两个 Metal 编译器版本都不同 → 全放行', dmsh_chain.own_compilers([M, I]), ([M, I], []))
ck('Metal 编译器缺失 → 照停', dmsh_chain.own_compilers([MISS]), ([], [MISS]))
ck('spirv-cross 不符 → 照停', dmsh_chain.own_compilers([SC]), ([], [SC]))
ck('翻译器 dll / 源码不符 → 照停', dmsh_chain.own_compilers([DLL, SRC]), ([], [DLL, SRC]))
ck('混合：Metal 放行、其余照停', dmsh_chain.own_compilers([M, SC, MISS]), ([M], [SC, MISS]))
ck('全符 → 都空', dmsh_chain.own_compilers([]), ([], []))
# 真跑 direct_lib.sh 的生产取值 / 校验块；工具边界只提供合成 stdout、stderr 与退出码。
root = Path(dmsh_chain.HERE).parent
source = (root / 'graphics/tools/direct/direct_lib.sh').read_text()
start = source.index('BE=$(')
block = source[start:source.index('\nSPVC=', start)]
expected = 'c7a4970bffe5\t0100ABCD00000000\tsynthetic-inputs'
note = "note: built with this Mac's compilers\ncompiler versions differ"
fatal = '[RED] translation chain tools do not match the lock file: synthetic translator'
with tempfile.TemporaryDirectory(prefix='s2a-chain-env-') as tmp:
    base = Path(tmp); nx = base / 'engine with spaces'; tools = nx / 'graphics/tools'
    tools.mkdir(parents=True)
    (tools / 'dmsh_chain.py').write_text(
        "import os, sys\n"
        "mode = os.environ['CHAIN_TEST_MODE']\n"
        "if mode in ('note', 'mismatch'): print(os.environ['CHAIN_TEST_NOTE'], file=sys.stderr)\n"
        "row = os.environ['CHAIN_TEST_ROW']\n"
        "if mode == 'mismatch': row = '000000000000' + row[12:]\n"
        "print(row)\n"
        "if mode == 'error': print(os.environ['CHAIN_TEST_ERROR'], file=sys.stderr); sys.exit(7)\n")
    for mode in ('normal', 'note', 'error', 'mismatch'):
        work = base / mode; work.mkdir()
        env = dict(os.environ, NX=str(nx), W=str(work), PY=sys.executable,
                   V='c7a4970bffe5', CHAIN_TEST_MODE=mode, CHAIN_TEST_NOTE=note,
                   CHAIN_TEST_ROW=expected, CHAIN_TEST_ERROR=fatal)
        shell = 'say() { printf "[直连库] %s\\n" "$*"; }\n' + block
        shell += '\nprintf "accepted\\t%s\\t%s\\t%s\\n" "$BV" "$BG" "$BI"\n'
        r = subprocess.run(['/bin/bash', '-u', '-c', shell], env=env, capture_output=True, text=True)
        ck(f'生产接线 {mode}：退出码', r.returncode, 0 if mode in ('normal', 'note') else 1)
        if mode in ('normal', 'note'):
            ck(f'生产接线 {mode}：三个字段保持原样', r.stdout.strip(), 'accepted\t' + expected)
        if mode in ('note', 'mismatch'):
            ck(f'生产接线 {mode}：提示保留在诊断输出', note in r.stderr, True)
        if mode == 'error':
            ck('工具退出非零：保留错误、拒绝其 stdout 中看似有效的结果', fatal in r.stdout + r.stderr and 'accepted\t' not in r.stdout, True)
        if mode == 'mismatch':
            ck('真实链号不符仍拒绝', '链号前后不一（c7a4970bffe5 / 000000000000）' in r.stdout, True)
print(f'dmsh_chain_own_compilers：{checks} 项，失败 {bad}'); raise SystemExit(1 if bad else 0)
PY
