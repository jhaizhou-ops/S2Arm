"""Self-owned shell sources; run real bash/timeout/env, never replace commands."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from shell_timeout_env import violations


class TimeoutEnvTest(unittest.TestCase):
    def test_actual_commands(self):
        # 时长参数只是语义（timeout N 变量=值 命令 会不会把「变量=值」当命令执行），取 600 与负载无关；
        #   原先取 5：11-01 mini 无缓存实跑 300 多步并发时 timeout 垫片 + printenv 超 5 秒退 124，确定性步骤红致整轮早停
        cases = [
            ('timeout 600 S2A_F2_VALUE=ok printenv S2A_F2_VALUE', 127, '', [(1, 'S2A_F2_VALUE')]),
            ('timeout 600 env S2A_F2_VALUE=ok printenv S2A_F2_VALUE', 0, 'ok\n', []),
            ('S2A_F2_VALUE=ok timeout 600 printenv S2A_F2_VALUE', 0, 'ok\n', []),
            ('timeout --signal TERM --kill-after=1 600 S2A_F2_VALUE=ok true', 127, '', [(1, 'S2A_F2_VALUE')]),
            ('timeout \\\n  600 \\\n  S2A_F2_VALUE="two words" true', 127, '', [(3, 'S2A_F2_VALUE')]),
            ('timeout 600 env S2A_F2_VALUE="two words" printenv S2A_F2_VALUE', 0, 'two words\n', []),
        ]
        for source, code, output, findings in cases:
            with self.subTest(source=source):
                result = subprocess.run(['bash', '-c', source], text=True, capture_output=True, timeout=120, env={**os.environ, 'LC_ALL': 'C'})   # 只防挂死
                print(f'actual command: {source!r} -> rc={result.returncode} stdout={result.stdout!r} stderr={result.stderr.strip()!r}')
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(result.stdout, output)
                self.assertEqual(list(violations(source)), findings)

    def test_literal_data_and_comments(self):
        source = '''# timeout 5 WRONG=1 true
echo timeout 5 WRONG=1 true
printf '%s\\n' 'timeout 5 WRONG=1 true'
message="timeout 5 WRONG=1 true"
cat <<'TEXT'
timeout 5 WRONG=1 true
TEXT
cat <<-TEXT
\ttimeout 5 WRONG=1 true
\tTEXT
timeout 5 env RIGHT=1 true # timeout 5 WRONG=1 true
'''
        self.assertEqual(list(violations(source)), [])

    def test_command_positions_and_lines(self):
        cases = [
            ('if timeout 5 A=1 true; then :; fi', [(1, 'A')]),
            ('while timeout 5 B=1 true; do :; done', [(1, 'B')]),
            ('f() { timeout 5 C=1 true; }', [(1, 'C')]),
            ('value=$(timeout 5 D=1 true)', [(1, 'D')]),
            ('true && timeout 5 E=1 true', [(1, 'E')]),
            ('printf x | timeout 5 F=1 true', [(1, 'F')]),
            ('command /usr/bin/timeout -- 0.5s G=1 true', [(1, 'G')]),
            ('exec timeout -k 1 -s TERM 5 H=1 true', [(1, 'H')]),
            ('\n\ntimeout 5 I=1 true', [(3, 'I')]),
            ('cat <<END\ntimeout 5 WRONG=1 true\nEND\ntimeout 5 J=1 true', [(4, 'J')]),
            ('printf "%s\\n" "multi\nline"\ntimeout 5 K=1 true', [(3, 'K')]),
        ]
        for source, findings in cases:
            with self.subTest(source=source):
                self.assertEqual(list(violations(source)), findings)

    def test_read_only_cli(self):
        with tempfile.TemporaryDirectory(prefix='s2arm-f2-') as name:
            directory = Path(name)
            source = directory / 'input.sh'
            marker = directory / 'must-not-run'
            content = f'touch "{marker}"\ntimeout 5 CHECK=1 true\n'
            source.write_text(content)
            before = source.stat()
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('shell_timeout_env.py')), str(source)], text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(f'{source}:2:', result.stdout)
            self.assertIn('timeout N env CHECK=', result.stdout)
            self.assertEqual(source.read_text(), content)
            self.assertEqual(source.stat().st_mtime_ns, before.st_mtime_ns)
            self.assertFalse(marker.exists())
            source.write_text('timeout 5 env CHECK=1 true\n')
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('shell_timeout_env.py')), str(source)], text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
