#!/bin/bash
# contrib_check 参数回归：执行真实脚本，临时仓库中的 doctor 仅标记是否越过参数检查。
# 不联网、不运行实际体检或门禁；每次子进程有 30 秒上限，旧缺参循环不能挂住测试（原 2 秒：10-26 #477 自检 mini 并行负载高时
#   正常一次就超 2 秒抛 TimeoutExpired，「FAILED (errors=1)」；防死循环 30 秒照样够）。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$H" "$BASH" <<'PY'
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

shell = sys.argv.pop()
source = pathlib.Path(sys.argv.pop()) / 'tools/contrib_check.sh'


class ContribArgsTests(unittest.TestCase):
    def run_args(self, args):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'tools').mkdir()
            shutil.copyfile(source, root / 'tools/contrib_check.sh')
            shutil.copyfile(source.parent / 'idle_timeout.sh', root / 'tools/idle_timeout.sh')   # contrib_check 按无进展收门禁（11-04）
            shutil.copyfile(source.parent / 'gate_plan.sh', root / 'tools/gate_plan.sh')   # 档位 / 第二层判定共用规则（10-27）
            # 参数正确时才可进入体检。缺 bash 5 使真实脚本在该阶段立即结束，避免检查真实环境。
            (root / 'tools/doctor.sh').write_text(
                "echo reached > doctor-seen\necho '缺：bash 5'\nexit 1\n")
            result = subprocess.run(
                [shell, 'tools/contrib_check.sh', *args], cwd=root,
                capture_output=True, text=True, timeout=30)
            return result, (root / 'doctor-seen').exists()

    def test_host_only_local_or_mini(self):
        # --host（10-25 派 mini）：只认 local / mini，别的值在体检前就拒；合法值照常走到体检
        for args in (['--host', 'pi'], ['--host'], ['--host=']):
            with self.subTest(args=args):
                result, doctor = self.run_args(args)
                self.assertEqual(result.returncode, 2)
                self.assertIn('--host 只认 local / mini / auto', result.stdout)
                self.assertFalse(doctor)
        # 10-28 Air 退出门禁池：--host air 在体检前拒（退出 2，写明用 mini / auto）
        for args in (['--host', 'air'], ['--host=air']):
            with self.subTest(args=args):
                result, doctor = self.run_args(args)
                self.assertEqual(result.returncode, 2)
                self.assertIn('自检不在 Air 跑', result.stdout)
                self.assertFalse(doctor)
        for args in (['--host', 'mini'], ['--host=local']):
            with self.subTest(args=args):
                result, doctor = self.run_args(args)
                self.assertTrue(doctor)

    def test_missing_empty_or_option_value_is_rejected_before_doctor(self):
        for args in (['--base'], ['--base', ''], ['--base', '--help'],
                     ['--base', '-h'], ['--base='], ['--base=--help']):
            with self.subTest(args=args):
                result, doctor = self.run_args(args)
                self.assertEqual(result.returncode, 2)
                self.assertIn('--base <分支或提交>', result.stderr)
                self.assertFalse(doctor)

    def test_valid_base_forms_reach_doctor(self):
        for args in (['--base', 'origin/main'], ['--base=origin/main'],
                     ['--base', 'HEAD~1']):
            with self.subTest(args=args):
                result, doctor = self.run_args(args)
                self.assertEqual(result.returncode, 2)  # fixture doctor 报缺工具
                self.assertTrue(doctor)
                self.assertNotIn('--base <分支或提交>', result.stderr)

    def test_help_exits_without_doctor(self):
        for flag in ('-h', '--help'):
            with self.subTest(flag=flag):
                result, doctor = self.run_args([flag])
                self.assertEqual(result.returncode, 0)
                self.assertIn('--base', result.stdout)
                self.assertFalse(doctor)

    def test_unknown_option_still_fails_without_doctor(self):
        result, doctor = self.run_args(['--unknown'])
        self.assertEqual(result.returncode, 2)
        self.assertIn('认不得参数', result.stdout)
        self.assertFalse(doctor)


unittest.main(verbosity=2)
PY
