"""F3 shell_fail_shapes 的正例反例（期望按形状手写，不跑被测实现推期望）。由 tests/shell_lint_test.sh 调。"""

import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shell_fail_shapes import skip_exit0, tail_rc


def shapes(src):
    return [(line, msg[0]) for line, msg in tail_rc(src)]


class Premise(unittest.TestCase):
    def test_tail_hides_front_failure(self):
        # 规则的前提：没开 pipefail 时管道退出码是 tail 的 0；PIPESTATUS[0] 才是前段的 3
        r = subprocess.run(['bash', '-c', 'f() { echo x; return 3; }; f 2>&1 | tail -1; echo "rc=$? ps=${PIPESTATUS[0]}"'], capture_output=True, text=True)
        self.assertEqual(r.stdout, 'x\nrc=0 ps=3\n')   # 同一句里两处展开都在 echo 之前：管道退出码 0，前段 3


class TailRc(unittest.TestCase):
    def test_positive(self):
        cases = [
            # A：管道退出码被当成成败
            ('if bash check.sh | tail -1; then echo ok; fi', [(1, 'A')]),
            ('while python3 poll.py | head -1; do :; done', [(1, 'A')]),
            ('make all 2>&1 | tail -5 || exit 1', [(1, 'A')]),
            ('bash x.sh | tail -1 && echo 过', [(1, 'A')]),
            ('dotnet run 2>&1 | tail -3; rc=$?\n[ $rc = 0 ]', [(1, 'A')]),
            ('cd w\ntimeout 200 bash regen.sh check 2>&1 | tail -1', [(2, 'A')]),       # 整份脚本最后一句 = 脚本退出码
            ('v=$(bash gen.sh | tail -1) || exit 1', [(1, 'A')]),
            ('if v=$(python3 a.py 2>&1 | tail -1); then :; fi', [(1, 'A')]),
            ('v=$(bash gen.sh | tail -1)\n[ $? = 0 ] || exit 1', [(1, 'A')]),
            # B1：跑程序 2>&1 | tail 单独成句，退出码没人看（pack/stages/shaders.sh 四次收集的形状）
            ('python3 "$R/specpipe.py" "$G" 2>&1 | tail -1\nSPF=x', [(1, 'B')]),
            ('"$PY" tool.py |& head -2\nnext', [(1, 'B')]),
            ('f() {\n  bash collect.sh 2>&1 | tail -1\n  echo done\n}', [(2, 'B')]),
            # B2：赋值丢了退出码，之后只在值里 grep 到失败记号才判红（graphics/gate.sh 宏表检查的形状）
            ('mc=$(timeout 200 bash regen.sh check 2>&1 | tail -1)\nok=1\necho "$mc" | grep -q "✗" && ok=0', [(1, 'B')]),
        ]
        for src, want in cases:
            with self.subTest(src=src):
                self.assertEqual(shapes(src), want)

    def test_negative(self):
        cases = [
            # pack/stages/shaders.sh 收回那一次：tail 只缩短日志，下一句读 PIPESTATUS 判前段
            'if [ "${S2A_SHCOLLECT_RUN:-0}" = 1 ]; then\n  bash "$R/graphics/tools/shbake/shcollect.sh" "$G" 2>&1 | tail -1\n'
            '  shcollect_rc=${PIPESTATUS[0]}   # tail 只缩短日志\n  [ "$shcollect_rc" = 0 ] || exit "$shcollect_rc"\nfi',
            # services/build.mk：先收下脚本退出码，成功了才把结果交给 tail 缩短
            'v=$(mkdir -p "$B/cs" && result=$(bash services/nxaot.sh ios-arm64 2>"$B/cs/x.err") && printf \'%s\\n\' "$result" | tail -1)',
            # 替换里管道后面读 PIPESTATUS（graphics/gate.sh 修后的另一种写法）
            'mc=$(bash regen.sh check 2>&1 | tail -1; exit "${PIPESTATUS[0]}") || ok=0',
            'tests/x.sh 2>&1 | tail -40; rc=${PIPESTATUS[0]}',
            # 打开了 pipefail：管道退出码就是前段的
            'set -euo pipefail\nbash x.sh 2>&1 | tail -1 || exit 1',
            'set -o pipefail\nif make 2>&1 | tail -3; then :; fi',
            # || true / || : 明说不看成败（审计：不要把 || true 一律当红）
            'reason=$(grep -v "^$" "$log" | tail -1 || true)',
            'grep x f | head -1 || :',
            # 只是看日志：前段是文本工具、没并 stderr、或是版本探测
            'grep -c ok log | tail -1\necho done',
            'git log --oneline -3 | head\necho done',
            'make all | tail -3\necho done',
            'NTV=$("$NT" --version 2>&1 | head -1)',
            'xcrun -sdk iphoneos metal --version 2>&1 | head -1\necho',
            # 赋值后按成功记号判（失败即红）：t_pso_cache / gate_budget_test 的形状
            'pv=$("$R/archprobe" a b 2>&1 | tail -1)\n[ "$pv" = "命中 1/1" ] && echo ok || fail=1',
            'od=$(bash tools/gate.sh 2>&1 | tail -1)\n[[ "$od" == *"doc 档"* ]] || bad=1',
            # 替换里的 2>&1 | tail 是取值，不是单独成句
            'echo "负载：$(ssh host uptime 2>&1 | head -1)"',
            # heredoc 正文与注释是数据
            "cat <<'EOF'\nif bash x.sh | tail -1; then :; fi\nEOF",
            '# if bash x.sh | tail -1; then :; fi',
            # 不在最后一句、后面也没人读 $?：A 不报（B 只认 2>&1 并进管道的程序）
            'bash x.sh | tail -1\necho next',
        ]
        for src in cases:
            with self.subTest(src=src):
                self.assertEqual(shapes(src), [])


class SkipExit0(unittest.TestCase):
    def test_positive(self):
        cases = [
            ('[ "$(uname -s)" = Darwin ] || { echo "跳过：只在 macOS 上走 colima"; exit 0; }', [1]),
            ('if ! command -v llvm-objcopy; then\n  echo "跳过：无 objcopy"\n  exit 0\nfi', [3]),
            ("if [ -z \"${M:-}\" ]; then\n  echo '跳过：未设清单（未验证真实输入）'\n  exit 0\nfi", [3]),
            ('command -v sc > /dev/null || { echo "— 本机没有 spirv-cross，跳过 x_test"; exit 0; }', [1]),
            ('[ -x tool ] || { printf "SKIP: no tool\\n"; exit 0; }', [1]),
            ('f() { echo "未验证：缺设备"; exit 0; }\nf', [1]),
        ]
        for src, want in cases:
            with self.subTest(src=src):
                self.assertEqual([line for line, _ in skip_exit0(src)], want)

    def test_negative(self):
        cases = [
            '[ -x tool ] || { echo "跳过：无 tool"; exit 75; }',                    # 改好的写法
            '[ $bad = 0 ] && { echo "✓ 全过"; exit 0; }',                             # 全过退 0 是对的
            'p6=$( (unset B; [ -n "${B:-}" ] || { echo 跳过; exit 0; }; echo x) )',   # 子 shell / 命令替换里的 exit 不退单测（tests/cc_cache_test.sh）
            '( echo 跳过; exit 0 )',
            "cat > stub.sh <<'EOF'\necho 跳过; exit 0\nEOF",                         # 桩脚本正文是数据
            'if x; then echo "跳过 3 支"; fi\ncheck || exit 1\nexit 0',              # 不同列表：分支里说跳过、整份跑完再退 0（同一列表才算）
        ]
        for src in cases:
            with self.subTest(src=src):
                self.assertEqual(skip_exit0(src), [])


if __name__ == '__main__':
    unittest.main()
