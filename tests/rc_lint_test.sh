#!/bin/bash
# 门禁覆盖：pack/*.sh pack/**/*.sh
# 纯静态合成测试：夹具里的 cp/mv 等从不交给 shell 执行；期望按返回码流手写。
set -eu
cd "$(dirname "$0")/.."
python3 - <<'PY'
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOL = Path('tools/rc_lint.py').resolve()
spec = importlib.util.spec_from_file_location('rc_lint', TOOL)
rc = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = rc
spec.loader.exec_module(rc)


class ReturnCodeLint(unittest.TestCase):
    def hits(self, source):
        return [(hit.line, hit.command) for hit in rc.scan(source)]

    def test_required_bad(self):
        self.assertEqual(self.hits('cp a b\n[ -d a ] && cp a b\nmv a b | cat\n'),
                         [(1, 'cp a b'), (2, 'cp a b'), (3, 'mv a b')])

    def test_required_good(self):
        self.assertEqual(self.hits('cp a b || fail\nif cp a b; then :; fi\n'
                                  'cp a b || { echo error; exit 1; }\n'), [])

    def test_chain_handler_and_condition(self):
        self.assertEqual(self.hits('cp a b && mv b c || return 1\n'
                                  'while cp a b; do :; done\n'
                                  'if ! cp a b; then exit 1; fi\n'), [])

    def test_errexit_boundaries(self):
        source = ('set -e\ncp a b\nset +e\ncp c d\nset -e\n'
                  '[ -d a ] && cp e f\ncp g h || true\n! cp i j\n'
                  'mv k l | cat\n')
        self.assertEqual(self.hits(source), [(4, 'cp c d'), (6, 'cp e f'),
                         (7, 'cp g h'), (8, 'cp i j'), (9, 'mv k l')])

    def test_conditional_errexit_does_not_escape(self):
        self.assertEqual(self.hits('if test -e flag; then set -e; fi\ncp a b\n'), [(2, 'cp a b')])
        self.assertEqual(self.hits('( set -e; cp a b )\ncp c d\n'), [(2, 'cp c d')])
        self.assertEqual(self.hits('set -e\nf() { cp a b; }\nf || true\n'), [(2, 'cp a b')])

    def test_function_and_time_cannot_reenable_ignored_errexit(self):
        self.assertEqual(self.hits('f() { set -e; cp a b; }\nf || true\n'), [(1, 'cp a b')])
        self.assertEqual(self.hits('set -e\ntime ! cp a b\n'), [(2, 'cp a b')])
        self.assertEqual(self.hits('if time ! cp a b; then exit 1; fi\n'), [])

    def test_errexit_option_and_process_substitution_boundaries(self):
        self.assertEqual(self.hits('set -- -e\ncp a b\n'), [(2, 'cp a b')])
        self.assertEqual(self.hits('set -o errexit\ncp a b\nset +o errexit\ncp c d\n'), [(4, 'cp c d')])
        self.assertEqual(self.hits('set -e\ncat <(cp a b)\n'), [(2, 'cp a b')])
        self.assertEqual(self.hits('! cp a b || fail\n'), [(1, 'cp a b')])
        self.assertEqual(self.hits('{ cp a b && mv b c; } || exit 1\n'), [])

    def test_unquoted_heredoc_substitution(self):
        self.assertEqual(self.hits("cat <<END\n'$(cp a b)'\nEND\n"), [(2, 'cp a b')])

    def test_swallowed_failure(self):
        self.assertEqual(self.hits('cp a b || true || exit 1\n'
                                  '{ cp c d; echo ok; } || exit 1\n'
                                  'cp e f || { test -e flag && exit 1; }\n'),
                         [(1, 'cp a b'), (2, 'cp c d'), (3, 'cp e f')])

    def test_external_wrappers_cannot_change_or_exit_parent_shell(self):
        self.assertEqual(self.hits('env set -e\ncp a b\n'), [(2, 'cp a b')])
        self.assertEqual(self.hits('cp a b || env exit 1\n'
                                  'cp c d || timeout 1 exit 1\n'
                                  'cp e f || /does-not-exist/exit 1\n'),
                         [(1, 'cp a b'), (2, 'cp c d'), (3, 'cp e f')])
        self.assertEqual(self.hits('command set -e\ncp a b\ncp c d || builtin exit 1\n'), [])

    def test_loop_control_can_bypass_handler_exit(self):
        self.assertEqual(self.hits('while true; do cp a b || { continue; exit 1; }; done\n'
                                  'while true; do cp c d || { break; exit 1; }; done\n'),
                         [(1, 'cp a b'), (2, 'cp c d')])

    def test_redirection_does_not_hide_writer_or_fake_exit(self):
        self.assertEqual(self.hits('set -e > missing/log\ncp a b\n'), [(2, 'cp a b')])
        self.assertEqual(self.hits('> log cp a b\n2> log command cp c d\n'
                                  'cp e f || exit 1 > missing/log\n'
                                  'cp g h || { exit 1; } > missing/log\n'),
                         [(1, '> log cp a b'), (2, '2 > log command cp c d'),
                          (3, 'cp e f'), (4, 'cp g h')])

    def test_subshell_exit_does_not_abort_parent(self):
        self.assertEqual(self.hits('cp a b || (exit 1)\n'
                                  'cp c d || { (exit 1); }\n'),
                         [(1, 'cp a b'), (2, 'cp c d')])

    def test_quote_comment_heredoc_data(self):
        source = ('echo "cp a b; mv c d" # cp e f\n'
                  "cat <<'END'\ncp a b\n$(mv c d)\nEND\n"
                  'cp "a; b" "c  d" # reason\n')
        self.assertEqual(self.hits(source), [(6, 'cp "a; b" "c  d"')])

    def test_shell_data_is_not_a_command(self):
        self.assertEqual(self.hits('args=(cp a b)\necho file{cp,mv}\n((cp))\n'), [])
        self.assertEqual(self.hits('cp a{b,c} d\n'), [(1, 'cp a{b,c} d')])
        self.assertEqual(self.hits('command -p cp a b\nenv -i cp c d\n'),
                         [(1, 'command -p cp a b'), (2, 'env -i cp c d')])

    def test_continuation_and_normalization(self):
        self.assertEqual(self.hits('cp   a \\\n b\n'), [(1, 'cp a b')])
        self.assertNotEqual(rc.normalize('cp "a  b" c'), rc.normalize('cp "a b" c'))

    def test_substitution_and_literal_shell(self):
        self.assertEqual(self.hits('set -e\necho "$(cp a b)"\n'
                                  "bash -c 'mv c d'\n"), [(2, 'cp a b'), (3, 'mv c d')])
        self.assertEqual(self.hits("echo '$(cp a b)'\n"), [])

    def test_wrappers_and_command_position(self):
        self.assertEqual(self.hits('A=x /bin/cp a b\ncommand cp c d\nenv A=x mv e f\n'
                                  'echo cp a b\ncommand -v cp\n'),
                         [(1, 'A=x /bin/cp a b'), (2, 'command cp c d'), (3, 'env A=x mv e f')])

    def test_all_named_writers_and_readonly_plutil(self):
        commands = ['cp', 'mv', 'ln', 'ditto', 'rsync', 'zip', 'tar', 'install']
        source = ''.join(f'{name} a b\n' for name in commands)
        source += '/usr/bin/plutil -insert x -string y z\nplutil -replace x -string y z\nplutil -extract x raw z\n'
        self.assertEqual(len(self.hits(source)), 10)

    def test_pipeline_left_is_not_caught_by_right(self):
        self.assertEqual(self.hits('mv a b | cat || exit 1\nif cp c d | cat; then :; fi\n'),
                         [(1, 'mv a b'), (2, 'cp c d')])

    def cli(self, *args, allowlist):
        env = dict(os.environ, S2A_RC_OK=str(allowlist))
        return subprocess.run([sys.executable, str(TOOL), *map(str, args)],
                              env=env, text=True, capture_output=True)

    def test_allowlist_identity_staleness_and_reason(self):
        with tempfile.TemporaryDirectory(prefix='rc-lint-') as directory:
            root = Path(directory)
            script, other, allow = root / 'case.sh', root / 'other.sh', root / 'ok.tsv'
            script.write_text('cp  "a  b" c\n', encoding='utf-8')
            allow.write_text(f'{script}\tcp "a  b" c\t待出包运维线确认\n', encoding='utf-8')
            self.assertEqual(self.cli(script, allowlist=allow).returncode, 0)
            script.write_text('# moved\n\ncp "a  b"   c\n', encoding='utf-8')
            self.assertEqual(self.cli(script, allowlist=allow).returncode, 0)
            other.write_text('cp "a  b" c\n', encoding='utf-8')
            self.assertEqual(self.cli(root, allowlist=allow).returncode, 1)  # 路径不能冒用
            script.write_text('cp "a  b" c || fail\n', encoding='utf-8')
            result = self.cli(script, allowlist=allow)
            self.assertEqual(result.returncode, 1)
            self.assertIn('过期', result.stdout)
            allow.write_text(f'{script}\tcp "a  b" c\t\n', encoding='utf-8')
            self.assertEqual(self.cli(script, allowlist=allow).returncode, 1)
            allow.write_text(f'{root / "gone.sh"}\tcp a b\t旧条目\n', encoding='utf-8')
            self.assertIn('过期', self.cli(root, allowlist=allow).stdout)

    def test_cli_never_executes_or_modifies_input(self):
        with tempfile.TemporaryDirectory(prefix='rc-lint-') as directory:
            root = Path(directory)
            script, marker, allow = root / 'untrusted.sh', root / 'must-not-run', root / 'ok.tsv'
            content = f'cp absent "{marker}"\ntouch "{marker}"\n'
            script.write_text(content, encoding='utf-8')
            allow.write_text('', encoding='utf-8')
            before = script.stat()
            result = self.cli(script, allowlist=allow)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(script.read_text(encoding='utf-8'), content)
            self.assertEqual(script.stat().st_mtime_ns, before.st_mtime_ns)
            self.assertFalse(marker.exists())

    def test_input_errors_are_not_clean_scan(self):
        with tempfile.TemporaryDirectory(prefix='rc-lint-') as directory:
            root = Path(directory)
            allow = root / 'ok.tsv'
            allow.write_text('', encoding='utf-8')
            self.assertNotEqual(self.cli(root / 'missing', allowlist=allow).returncode, 0)
            script = root / 'bad.sh'
            script.write_text('cp "unterminated\n', encoding='utf-8')
            self.assertNotEqual(self.cli(script, allowlist=allow).returncode, 0)

    def test_repository_and_empty_allowlist_negative_control(self):
        result = subprocess.run([sys.executable, str(TOOL), 'pack'], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with tempfile.TemporaryDirectory(prefix='rc-lint-') as directory:
            allow = Path(directory) / 'empty.tsv'
            allow.write_text('', encoding='utf-8')
            result = self.cli('pack', allowlist=allow)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('pack/ipa.sh:', result.stdout)
            self.assertIn('cp -cR "$SA/$d" "$W/pkg/save/"', result.stdout)


unittest.main(verbosity=2)
PY
