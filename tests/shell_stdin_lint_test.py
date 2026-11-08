#!/usr/bin/env python3
"""Hand-written F1 fixtures; inspected ssh commands are NEVER executed."""
import hashlib
import importlib.util
import shutil
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
MODULE = Path(os.environ.get("S2A_STDIN_LINT_MODULE", HERE / "shell_stdin_lint.py"))
spec = importlib.util.spec_from_file_location("shell_stdin_lint", MODULE)
scanner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = scanner
spec.loader.exec_module(scanner)


BAD = {
    "time_compound": ('time while read x; do ssh host true; done', [1]),
    "continued_keywords": ('whi\\\nle read x; d\\\no\n ssh host true\ndone', [4]),
    "continued_heredoc_delimiter": ('while read x; do cat <<EO\\\nF\n$(ssh host true)\nEOF\ndone', [3]),
    "direct": ('while read x; do\n ssh host true\ndone\n', [2]),
    "ifs": ('while IFS= read -r x; do ssh host true; done < list\n', [1]),
    "inline": ('while read x; do ssh host true; done', [1]),
    "condition_newline": ('while\n read x\ndo\n ssh host true\ndone', [4]),
    "quoted_executable": ('while read x; do "/usr/bin/ssh" host true; done', [1]),
    "remote": ('while read x; do bash tools/remote.sh -- true; done', [1]),
    "remote_path": ('while read x; do "$ROOT/tools/remote.sh" -- true; done', [1]),
    "remote_no_n_option": ('while read x; do bash tools/remote.sh -n -- true; done', [1]),
    "command_p": ('while read x; do command -p ssh host true; done', [1]),
    "exec_options": ('while read x; do exec -a label ssh host true; done', [1]),
    "time_options": ('while read x; do time -p ssh host true; done', [1]),
    "wrapped": ('while read x; do A=x timeout "$N" env B=y command ssh host true; done', [1]),
    "stdout_not_stdin": ('while read x; do ssh host true >/dev/null 2>&1; done', [1]),
    "stderr_input": ('while read x; do ssh host true 2</dev/null; done', [1]),
    "literal_null_argument": ('while read x; do ssh host "</dev/null"; done', [1]),
    "remote_n_argument": ('while read x; do ssh host printf -n; done', [1]),
    "option_n_value": ('while read x; do ssh -o "ProxyCommand=cat -n" host true; done', [1]),
    "ssh_option_takes_n": ('while read x; do ssh -i -n host true; done', [1]),
    "commented_redirect": ('while read x; do\n ssh host true # </dev/null\ndone', [2]),
    "continued": ('while read x; do\n ssh \\\n host true\ndone', [2]),
    "nested_for": ('while read x; do for y in a b; do\n ssh host true\ndone; done', [2]),
    "outer_after_inner": ('while read x; do while read y; do :; done < other\n ssh host true\ndone', [2]),
    "nested_if_case": ('while read x; do if true; then case "$x" in a) ssh host true;; esac; fi; done', [1]),
    "substitution": ('while read x; do y="$(ssh host true)"; done', [1]),
    "backtick": ('while read x; do y=`ssh host true`; done', [1]),
    "nested_substitution": ('while read x; do y="$(printf "%s" "$(ssh host true)")"; done', [1]),
    "outer_simple_redirect": ('while read x; do echo "$(ssh host true)" </dev/null; done', [1]),
    "heredoc_expansion": ('while read x; do cat <<END\n$(ssh host true)\nEND\ndone', [2]),
    "process_substitution": ('while read x; do cat < <(ssh host true); done', [1]),
    "pipe_left": ('while read x; do ssh host true | cat; done', [1]),
    "stdin_alias": ('while read x; do ssh host true </dev/stdin; done', [1]),
    "fd_zero_alias": ('while read x; do ssh host true 0<&0; done', [1]),
    "read_self_duplicate": ('while read x <&0; do ssh host true; done', [1]),
    "read_stdin_alias": ('while read x </dev/stdin; do ssh host true; done', [1]),
    "read_fd_path_alias": ('while read x </dev/fd/0; do ssh host true; done', [1]),
    "read_duplicate_fd3": ('while read x <&3; do ssh host true <&3; done 3<list', [1]),
    "read_fd3_aliases_stdin": ('while read x <&3; do ssh host true; done 3<&0', [1]),
    "read_group_duplicate": ('while { read x; } <&3; do ssh host true <&3; done 3<list', [1]),
    "read_redirect_restores_source": ('while read x </dev/null <&3; do ssh host true <&3; done 3<list', [1]),
    "heredoc_before_null": ('while read x; do cat <<END </dev/null\n$(ssh host true)\nEND\ndone', [2]),
    "heredoc_restore_before_expansion": ('while read x; do cat 3<&0 </dev/null <&3 <<END\n$(ssh host true)\nEND\ndone', [2]),
    "unquoted_fd_continuation": ('while read x; do ssh host true 2\\\n</dev/null; done', [1]),
    "fd3_read_redirect": ('while read -u3 x; do ssh host true <&3; done 3<list', [1]),
    "redirection_order_restore": ('while read x; do ssh host true 3<&0 </dev/null 0<&3; done', [1]),
    "group_restored": ('while read x; do { ssh host true 0<&3; } 3<&0 </dev/null; done', [1]),
    "dynamic_redirect": ('while read x; do ssh host true <"$INPUT"; done', [1]),
    "array_substitution": ('while read x; do a=("$(ssh host true)"); done', [1]),
    "arithmetic_substitution": ('while read x; do ((n=$(ssh host true))); done', [1]),
    "loop_in_substitution": ('x=$(while read x; do ssh host true; done)', [1]),
    "pipe_loop": ('printf "%s\\n" a b | while read x; do ssh host true; done', [1]),
}
GOOD = {
    "command_lookup": 'while read x; do command -v ssh; done',
    "builtin_not_external": 'while read x; do builtin ssh host true; done',
    "bash_syntax_only": 'while read x; do bash -n tools/remote.sh; done',
    "stdin_output_only": 'while read x; do ssh host true 0>/dev/null; done',
    "not_in_loop": 'ssh host true',
    "not_read_loop": 'while true; do ssh host true; done',
    "read_argument_not_command": 'while printf read; do ssh host true; done',
    "null": 'while read x; do ssh host true </dev/null; done',
    "null_fd": 'while read x; do 0< /dev/null ssh host true; done',
    "quoted_null": 'while read x; do ssh host true <"/dev/null"; done',
    "input_file": 'while read x; do ssh host true <payload.txt; done',
    "closed_stdin": 'while read x; do ssh host true <&-; done',
    "n": 'while read x; do ssh -n host true; done',
    "combined_n": 'while read x; do ssh -Tn host true; done',
    "f_implies_n": 'while read x; do ssh -f host true; done',
    "stdin_null_option": 'while read x; do ssh -o StdinNull=yes host true; done',
    "stdin_null_attached": 'while read x; do ssh -oStdinNull=yes host true; done',
    "remote_null": 'while read x; do bash tools/remote.sh -- true </dev/null; done',
    "comment": '# while read x; do ssh host true; done\n',
    "comment_loop": 'while read x; do\n # ssh host true\n :\ndone',
    "single_quote": "while read x; do echo 'ssh host true'; done",
    "double_quote": 'while read x; do echo "ssh host true"; done',
    "quoted_keywords": 'echo "while read x; do ssh host true; done"',
    "escaped_substitution": r'while read x; do echo "\$(ssh host true)"; done',
    "here_string": 'while read x; do ssh host true <<< "$x"; done',
    "heredoc": 'while read x; do ssh host true <<END\ninput\nEND\ndone',
    "quoted_heredoc": "cat <<'END'\nwhile read x; do ssh host true; done\n$(ssh host true)\nEND\n",
    "tab_heredoc": 'while read x; do cat <<-"END"\n\tssh host true\n\tEND\ndone',
    "two_heredocs": 'cat <<A <<\'B\'\nssh host true\nA\nwhile read x; do ssh host true; done\nB\n',
    "group_null": 'while read x; do { ssh host true; } </dev/null; done',
    "subshell_null": 'while read x; do (ssh host true) </dev/null; done',
    "substitution_group_null": 'while read x; do { echo "$(ssh host true)"; } </dev/null; done',
    "pipe_right": 'while read x; do printf x | ssh host true; done',
    "read_other_fd": 'while read -u3 x; do ssh host true; done 3<list',
    "read_own_input": 'while read x <list; do ssh host true; done',
    "read_duplicate_different_fd": 'while read x <&3; do ssh host true; done 3<list',
    "read_redirect_isolates_source": 'while read x <&3 </dev/null; do ssh host true <&3; done 3<list',
    "heredoc_after_null": 'while read x; do cat </dev/null <<END\n$(ssh host true)\nEND\ndone',
    "heredoc_after_prior_heredoc": 'while read x; do cat <<FIRST <<SECOND\nsafe\nFIRST\n$(ssh host true)\nSECOND\ndone',
    "quoted_digit_argument": "while read x; do ssh host true '2'</dev/null; done",
    "double_quoted_digit_argument": 'while read x; do ssh host true "2"</dev/null; done',
    "escaped_digit_argument": 'while read x; do ssh host true \\2</dev/null; done',
    "partly_quoted_digit_argument": "while read x; do ssh host true 2''</dev/null; done",
    "non_ascii_digit_argument": 'while read x; do ssh host true ٢</dev/null; done',
    "read_in_pipeline": 'while printf x | read x; do ssh host true; done',
    "loop_ended": 'while read x; do :; done\nssh host true',
    "definition_not_call": 'while read x; do later() { ssh host true; }; done',
    "array_data": 'while read x; do a=(ssh host true); done',
    "fd_order_safe": 'while read x; do ssh host true 0<&0 </dev/null; done',
    "exec_redirect": 'while read x; do exec </dev/null; ssh host true; done',
    "for_arithmetic": 'for ((i=0;i<2;i++)); do ssh host true; done',
    "case_subshell": '(case x in a) echo x;; *) echo y;; esac)',
    "case_optional_paren": 'case x in (a|b) echo x;; esac',
}


class StdinLintTests(unittest.TestCase):
    def test_bad_fixtures(self):
        for name, (source, expected) in BAD.items():
            with self.subTest(name=name):
                self.assertEqual([line for line, _ in scanner.lint(source)], expected)

    def test_good_fixtures(self):
        for name, source in GOOD.items():
            with self.subTest(name=name):
                self.assertEqual(scanner.lint(source), [])

    def test_bash_syntax_of_all_fixtures(self):
        for name, source in [(n, s) for n, (s, _) in BAD.items()] + list(GOOD.items()):
            with self.subTest(name=name):
                r = subprocess.run(['bash', '-n'], input=source, text=True, capture_output=True)
                self.assertEqual(r.returncode, 0, r.stderr)

    def test_wrapper_provenance(self):
        for path, names in scanner.WRAPPERS.items():
            for name in names:
                source = f'while read x; do {name} true; done'
                self.assertEqual([line for line, _ in scanner.lint(source, path)], [1])
                self.assertEqual(scanner.lint(source, 'tests/unrelated.sh'), [])
                self.assertEqual(scanner.lint(source.replace('true;', 'true </dev/null;'), path), [])

    def test_lexical_error_is_not_success(self):
        for source in ['while read x; do ssh host true', 'echo "unfinished', "cat <<END\nmissing"]:
            with self.subTest(source=source):
                with self.assertRaises(scanner.ScanError):
                    scanner.lint(source)

    def test_cli_exit_and_line(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / 'example.sh'
            p.write_text(BAD['direct'][0])
            result = subprocess.run([sys.executable, str(MODULE), str(p)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn(f'{p}:2: F1:', result.stdout)
            self.assertIn('</dev/null', result.stdout)
            p.write_text(GOOD['null'])
            result = subprocess.run([sys.executable, str(MODULE), str(p)], text=True, capture_output=True)
            self.assertEqual((result.returncode, result.stdout), (0, ''))
            p.write_bytes(b'\xff')
            result = subprocess.run([sys.executable, str(MODULE), str(p)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('未完成', result.stderr)

    def test_shared_entry_fixtures(self):
        entry = Path(os.environ.get("S2A_STDIN_LINT_ENTRY", HERE / "shell_lint_test.sh"))
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / 'tests').mkdir()
            (root / 'scripts').mkdir()
            subprocess.run(['git', 'init', '-q', td], check=True)
            shutil.copy2(entry, root / 'tests/shell_lint_test.sh')
            shutil.copy2(MODULE, root / 'tests/shell_stdin_lint.py')
            # F2 is a separate owner's rule; copy its exact dependencies if the
            # selected shared entry has them. Never emulate or bypass its tests.
            for name in ('shell_timeout_env.py', 'shell_timeout_env_test.py'):
                dependency = entry.parent / name
                if dependency.exists():
                    shutil.copy2(dependency, root / 'tests' / name)
            # F3（shell_fail_shapes）同理：规则、它的正反例，和它读自动收单测名单用的 tools/gate_route.py
            for name in ('tests/shell_fail_shapes.py', 'tests/shell_fail_shapes_test.py', 'tools/gate_route.py'):
                dependency = entry.parent.parent / name
                if dependency.exists():
                    (root / name).parent.mkdir(exist_ok=True)
                    shutil.copy2(dependency, root / name)
            fixture = root / 'scripts/example.sh'
            fixture.write_text(':\n')
            subprocess.run(['git', '-C', td, 'add', 'tests', 'scripts'], check=True)
            cases = [('bad_' + name, BAD[name][0], BAD[name][1])
                     for name in ('direct', 'remote', 'outer_simple_redirect', 'heredoc_expansion',
                                  'read_self_duplicate', 'read_stdin_alias', 'read_duplicate_fd3',
                                  'heredoc_before_null')]
            cases += [('good_' + name, GOOD[name], [])
                      for name in ('null', 'quoted_heredoc', 'substitution_group_null', 'pipe_right',
                                   'heredoc_after_null', 'quoted_digit_argument')]
            for name, source, lines in cases:
                with self.subTest(name=name):
                    fixture.write_text(source + '\n# Never execute the inspected source.\ntouch EXECUTED\n')
                    before = (hashlib.sha256(fixture.read_bytes()).digest(), fixture.stat().st_mtime_ns)
                    result = subprocess.run(['bash', str(root / 'tests/shell_lint_test.sh')],
                                            cwd=root, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 1 if lines else 0, result.stdout + result.stderr)
                    for line in lines:
                        self.assertIn(f'scripts/example.sh:{line}: F1:', result.stdout)
                    self.assertFalse((root / 'EXECUTED').exists())
                    self.assertEqual(before, (hashlib.sha256(fixture.read_bytes()).digest(), fixture.stat().st_mtime_ns))

    def test_real_local_stdin_behavior(self):
        # No ssh binary, remote host, network, or external inputs are involved.
        cases = [
            ('while read x; do echo "$x"; cat >/dev/null; done', 'A\n'),
            ('while read x; do echo "$x"; cat </dev/null >/dev/null; done', 'A\nB\nC\n'),
            ('while read x; do echo "$x$(cat >/dev/null)" </dev/null; done', 'A\n'),
            ('while read x; do { echo "$x$(cat >/dev/null)"; } </dev/null; done', 'A\nB\nC\n'),
            ('while read x <&0; do echo "$x"; cat >/dev/null; done', 'A\n'),
            ('while read x </dev/stdin; do echo "$x"; cat >/dev/null; done', 'A\n'),
            ('while read x <&3; do echo "$x"; cat <&3 >/dev/null; done 3<&0', 'A\n'),
            ('while read x <&3; do echo "$x"; cat >/dev/null; done 3<&0', 'A\n'),
            ('while read x <&3; do echo "$x"; cat </dev/null >/dev/null; done 3<&0', 'A\nB\nC\n'),
            ('while read x; do echo "$x"; cat </dev/null <<END >/dev/null\n$(cat >/dev/null)\nEND\ndone', 'A\nB\nC\n'),
            ('while read x; do echo "$x"; cat <<END </dev/null >/dev/null\n$(cat >/dev/null)\nEND\ndone', 'A\n'),
            # The local shell consumes stdin via cat: unquoted 2 redirects its
            # stderr; quoted 2 is an argument followed by a stdin redirect.
            ('''while read x; do printf '%s\\n' "$x"; bash -c 'cat >/dev/null' 2</dev/null; done''', 'A\n'),
            ('''while read x; do printf '%s\\n' "$x"; bash -c 'cat >/dev/null' '2'</dev/null; done''', 'A\nB\nC\n'),
        ]
        for source, expected in cases:
            with self.subTest(source=source):
                # timeout 只防挂死、不参与判定：输入有限，正常毫秒级；10-31 mini 无缓存全套满负载下 5 秒误红
                result = subprocess.run(['bash', '-c', source], input='A\nB\nC\n',
                                        text=True, capture_output=True, timeout=60)
                self.assertEqual((result.returncode, result.stdout), (0, expected))


if __name__ == '__main__':
    unittest.main()
