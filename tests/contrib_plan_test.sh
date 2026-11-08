#!/bin/bash
# contrib_check 步骤清单回归（#58 空计划误绿）：临时仓库里执行真实脚本，doctor / gate 换成假的。
# 假 gate 按 FAKE_LIST（ok / empty / fail / l2only）决定 GATE_LIST=1 时列什么，按 FAKE_RUN_RC 决定真跑时的退出码；每次调用记进 gate-calls。
# 不联网、不跑真实体检或门禁；子进程标准输入接 /dev/null，不设墙钟上限（11-02 合入线：原先每次 20 秒，mini 无缓存全套 361 步并发时
#   这一步 8 条用例本来就要 90–128 秒、单次 contrib_check 13 秒上下，满载时过 20 秒报 TimeoutExpired；被测的只有本地假体检 / 假门禁、
#   给了 --base 不拉远端，没有会等外部的点，真死循环由门禁每步的时限兜住）。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$H" "$BASH" <<'PY'
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

shell = sys.argv.pop()
source = pathlib.Path(sys.argv.pop()) / 'tools/contrib_check.sh'

FAKE_GATE = r'''#!/bin/bash
echo "list=${GATE_LIST:-} tier=${GATE_TIER:-} layer=${GATE_LAYER-无} rerun=${GATE_RERUN:-}" >> gate-calls
if [ "${GATE_LIST:-}" = 1 ]; then
  if [ "${GATE_TIER:-}" = doc ] && [ "${FAKE_LIST:-ok}" = ok ]; then echo '公开仓扫描'; exit 0; fi
  case ${FAKE_LIST:-ok} in
    fail) echo '🔴 统一工具链 /Applications/Xcode-27.1.app/Contents/Developer 不在本机（tools/toolchain.env）' >&2; exit 2;;
    empty) exit 0;;
    l2only) echo '路由：假'; echo '钩子 graphics/gate.sh'; exit 0;;
    *) echo '路由：假'; echo '语法'; echo '单测 foo_test'; exit 0;;
  esac
fi
if [ "${GATE_TIER:-}" = doc ]; then echo '🟢 公开仓扫描'; echo '门禁 绿：跑了 1 步 / 应跑 1 步'; exit 0; fi
echo '🟢 语法'
if [ "${FAKE_RUN_RC:-0}" = 0 ]; then echo '🟢 单测 foo_test'; echo '门禁 绿：跑了 2 步 / 应跑 2 步'
else echo '🔴 单测 foo_test'; echo '门禁 红：1 步红'; fi
exit "${FAKE_RUN_RC:-0}"
'''


def git(root, *args):
    subprocess.run(['git', '-C', str(root), '-c', 'user.name=t', '-c', 'user.email=t@t',
                    *args], check=True, capture_output=True)


class ContribPlanTests(unittest.TestCase):
    def run_check(self, changed, **env):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            git(root, 'init', '-q')
            (root / 'tools').mkdir()
            (root / 'docs').mkdir()
            shutil.copyfile(source, root / 'tools/contrib_check.sh')
            shutil.copyfile(source.parent / 'idle_timeout.sh', root / 'tools/idle_timeout.sh')   # contrib_check 按无进展收门禁（11-04）
            shutil.copyfile(source.parent / 'gate_plan.sh', root / 'tools/gate_plan.sh')   # 档位 / 第二层判定共用规则（10-27）
            (root / 'tools/doctor.sh').write_text("echo '✅ 假体检'\n")
            (root / 'tools/gate.sh').write_text(FAKE_GATE)
            (root / 'tools/contrib_layer2.tsv').write_text('钩子 graphics/gate.sh\t要金样\n')
            (root / 'tools/contrib_tools.tsv').write_text('iOS 全量编译\tXcode\n')
            (root / '.gitignore').write_text('build/\ngate-calls\n')
            (root / changed).write_text('base\n')
            git(root, 'add', '-A')
            git(root, 'commit', '-q', '-m', 'base')
            base = subprocess.run(['git', '-C', str(root), 'rev-parse', 'HEAD'],
                                  capture_output=True, text=True, check=True).stdout.strip()
            # 上一次自检残留的绿日志：不许被本次计数
            (root / 'build/contrib_check').mkdir(parents=True)
            (root / 'build/contrib_check/gate.log').write_text('🟢 旧步骤\n')
            (root / changed).write_text('changed\n')
            git(root, 'commit', '-q', '-am', 'change')
            result = subprocess.run(
                [shell, 'tools/contrib_check.sh', '--base', base], cwd=root,
                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                env={**os.environ, **env})
            calls = root / 'gate-calls'
            calls = calls.read_text() if calls.exists() else ''
            summary = (root / 'build/contrib_check/summary.md').read_text()
            return result, calls, summary

    def test_list_failure_keeps_reason_and_is_incomplete(self):
        result, calls, summary = self.run_check('tools/x.sh', FAKE_LIST='fail')
        self.assertEqual(result.returncode, 2)
        self.assertIn('Xcode-27.1.app', result.stdout)
        self.assertIn('退出 2', result.stdout)
        self.assertIn('Xcode-27.1.app', summary)
        self.assertIn('结论：**不完整**', summary)
        self.assertNotIn('**绿**', summary)
        self.assertIn('门禁列步骤失败，不知道有哪些', summary)
        self.assertEqual(result.stdout.count('Xcode-27.1.app'), 2)  # 终端报一次 + 摘要门禁结论行一次
        self.assertIn('绿 0、红 0', summary)  # 旧 gate.log 不计数
        self.assertEqual(calls.count('list=1'), 1)
        self.assertNotIn('list= ', calls)  # 列不出来就不真跑

    def test_empty_list_for_tool_tier_is_not_green(self):
        result, calls, summary = self.run_check('tools/x.sh', FAKE_LIST='empty')
        self.assertEqual(result.returncode, 2)
        self.assertIn('列出 0 步', summary)
        self.assertIn('结论：**不完整**', summary)
        self.assertNotIn('list= ', calls)

    def test_empty_list_for_full_tier_is_not_green(self):
        result, _, summary = self.run_check('x.c', FAKE_LIST='empty')
        self.assertIn('档位：full', summary)
        self.assertEqual(result.returncode, 2)
        self.assertIn('结论：**不完整**', summary)

    def test_only_layer2_steps_is_not_green(self):
        result, calls, summary = self.run_check('tools/x.sh', FAKE_LIST='l2only')
        self.assertEqual(result.returncode, 2)
        self.assertIn('第一层 0 步', summary)
        self.assertIn('钩子 graphics/gate.sh（要金样）', summary)
        self.assertNotIn('list= ', calls)

    def test_doc_tier_lists_and_runs_scanner(self):
        result, calls, summary = self.run_check('docs/a.md')
        self.assertEqual(result.returncode, 0)
        self.assertIn('档位：doc', summary)
        self.assertIn('应跑 1 步、跑了 1 步', summary)
        self.assertIn('结论：**绿**', summary)
        self.assertIn('list=1', calls)
        self.assertIn('rerun=公开仓扫描', calls)

    def test_doc_tier_cannot_skip_failed_or_empty_plan(self):
        for mode in ['fail', 'empty']:
            result, calls, summary = self.run_check('docs/a.md', FAKE_LIST=mode)
            self.assertEqual(result.returncode, 2)
            self.assertIn('结论：**不完整**', summary)
            self.assertNotIn('list= ', calls)

    def test_normal_plan_runs_layer1_and_is_green(self):
        result, calls, summary = self.run_check('tools/x.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('档位：tool', summary)
        self.assertIn('应跑 2 步、跑了 2 步；绿 2、红 0', summary)
        self.assertIn('门禁结论行：门禁 绿', summary)
        self.assertIn('结论：**绿**', summary)
        self.assertIn('rerun=语法\t单测 foo_test', calls)

    def test_layer_defaults_to_pre_and_empty_means_all(self):
        # 自检缺省只跑合入前层（11-05 门禁精简）：列步与真跑都带 GATE_LAYER=pre；显式 GATE_LAYER= 空 → 全跑（不带层）
        env = {k: v for k, v in os.environ.items() if k != 'GATE_LAYER'}
        saved = dict(os.environ); os.environ.clear(); os.environ.update(env)
        try:
            _, calls, _ = self.run_check('tools/x.sh')
            _, calls_all, _ = self.run_check('tools/x.sh', GATE_LAYER='')
        finally:
            os.environ.clear(); os.environ.update(saved)
        self.assertEqual(calls.count('layer=pre'), 2, calls)
        self.assertNotIn('layer=pre', calls_all)
        self.assertEqual(calls_all.count('layer= '), 2, calls_all)

    def test_normal_plan_with_red_step_is_red(self):
        result, _, summary = self.run_check('tools/x.sh', FAKE_RUN_RC='1')
        self.assertEqual(result.returncode, 1)
        self.assertIn('绿 1、红 1', summary)
        self.assertIn('结论：**红**', summary)


unittest.main(verbosity=2)
PY

# Linux 工具链 / 真跑子集回归复用本入口，不新增门禁步骤名（Mac 清单字节保持不变）。
bash "$H/tests/linux_selfcheck_cases.sh"
# Linux 真进程专项不另增自动枚举步骤，Mac 静默。
bash "$H/tests/timeout_linux_cases.sh"
