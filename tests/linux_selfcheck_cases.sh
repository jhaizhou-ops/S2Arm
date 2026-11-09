#!/bin/bash
# Linux 无 Xcode：真实 gate / contrib，隔离合成仓库；不冒充 macOS 验收。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
[ "$(uname -s)" = Linux ] || exit 0
python3 - "$H" <<'PYTEST'
import os, pathlib, shutil, subprocess, sys, tempfile, unittest
H = pathlib.Path(sys.argv.pop())
class LinuxSelfcheck(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.r = pathlib.Path(self.tmp.name)
        for d in ('tools/bin', 'tests', 'runtime', 'android'):
            (self.r / d).mkdir(parents=True, exist_ok=True)
        for f in ('gate.sh', 'contrib_check.sh', 'gate_plan.sh', 'idle_timeout.sh'):
            shutil.copyfile(H / 'tools' / f, self.r / 'tools' / f)
        self.write('tools/toolchain.env', 'test fixture\n')
        self.write('tools/toolchain.sh', 'export PATH="$PWD/tools/bin:$PATH"; echo "🔴 Xcode-unavailable" >&2; return 1\n')
        # 只测真实 gate/contrib 的路由与 PATH；不执行 timeout 的进程组清理。
        self.write('tools/bin/timeout', '#!/bin/bash\nshift; exec "$@"\n')
        (self.r/'tools/bin/timeout').chmod(0o755)
        self.write('tools/doctor.sh', 'echo "缺：Xcode"\n')
        self.write('tools/contrib_tools.tsv', 'iOS 全量编译\tXcode\n钩子 runtime/gate.sh\tXcode\n')
        self.write('tools/contrib_layer2.tsv', '')
        self.write('runtime/build.mk', '# fixture\n')
        self.write('runtime/gate.sh', 'echo wrongly-ran-Apple >> apple-ran; exit 1\n')
        self.write('tools/gate_ios.sh', 'echo wrongly-ran-iOS >> apple-ran; exit 1\n')
        self.write('android/gate.sh', 'echo portable-hook-ran; exit 0\n')
        self.write('tests/portable_test.sh', 'echo portable-ran; exit "${PORTABLE_RC:-0}"\n')
        self.write('.gitignore', 'build/\n__pycache__/\n*.pyc\n')
        self.git('init', '-q'); self.git('add', '.'); self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD').stdout.strip()
        self.write('runtime/change.c', '// routing full\n')
        self.git('add', '.'); self.git('commit', '-qm', 'change')
    def write(self, name, text): (self.r / name).write_text(text)
    def git(self, *args):
        return subprocess.run(['git', '-c', 'user.name=test', '-c', 'user.email=test@example.invalid', *args], cwd=self.r, capture_output=True, text=True, check=True)
    def run_script(self, script, *args, **env):
        return subprocess.run(['bash', script, *args], cwd=self.r, capture_output=True, text=True, timeout=30,
          env={**os.environ, 'S2A_TRAIN_DIR': str(self.r/'no-train'), 'S2A_GATE_CPU_IDLE_MIN':'0', 'GATE_HOST':'local', 'CONTRIB_HOST':'local', **env})
    def test_doc_list_does_not_load_toolchain(self):
        self.write('tools/public_repo_scan.py', '# synthetic scanner presence only\n')
        self.write('tools/toolchain.sh', 'echo wrongly-loaded >> toolchain-loaded; return 1\n')
        for tier in ('doc', 'full'):
            with self.subTest(tier=tier):
                p=self.run_script('tools/gate.sh', GATE_LIST='1', GATE_TIER=tier,
                                  GATE_CHANGED='docs/example.md')
                self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
                self.assertEqual(p.stdout, '公开仓扫描\n')
                self.assertEqual(p.stderr, '')
                self.assertFalse((self.r/'toolchain-loaded').exists())
    def test_linux_list_preserves_local_stderr_and_apple_stdout(self):
        shutil.copyfile(H / 'tools' / 'gate_decl.py', self.r / 'tools' / 'gate_decl.py')   # 本机步声明在各自文件头（tools/gate_decl.py local）
        self.write('tests/portable_test.sh', '# 门禁本机：fixture\n' + (self.r / 'tests/portable_test.sh').read_text())
        self.write('runtime/gate.sh', '# 门禁本机：* fixture\n' + (self.r / 'runtime/gate.sh').read_text())
        p=self.run_script('tools/gate.sh', GATE_LIST='1')
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertIn('单测 portable_test\n', p.stdout)
        self.assertIn('钩子 runtime/gate.sh\t需苹果工具链\n', p.stdout)
        self.assertNotIn('路由：', p.stdout)
        self.assertIn('路由：单测 portable_test［本机］\n', p.stderr)
        self.assertIn('路由：钩子 runtime/gate.sh［本机］\n', p.stderr)
    def test_step_uses_repository_timeout_and_visible_toolchain_failure(self):
        self.write('tests/portable_test.sh', 'test "$(command -v timeout)" = "$PWD/tools/bin/timeout" || exit 1\necho timeout-path-ok\n')
        p=self.run_script('tools/gate.sh', GATE_RERUN='单测 portable_test')
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertIn('🟢 单测 portable_test', p.stdout)
        self.assertIn('工具链提示：🔴 Xcode-unavailable', p.stderr)
    def test_toolchain_diagnostics_keep_each_line_and_shell_path(self):
        self.write('tools/toolchain.sh', 'export PATH="$PWD/tools/bin:$PATH"; printf "🔴 first\\n  second\\t detail\\nlast\\n" >&2; return 1\n')
        p=self.run_script('tools/gate.sh', GATE_LIST='1')
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertEqual(p.stderr, '工具链提示：🔴 first\n工具链提示：  second\t detail\n工具链提示：last\n')
    def test_apple_classification_uses_table_first_match(self):
        # 删除原生分类应立即生效；新增任意可移植步骤分类也必须生效。
        self.write('tools/contrib_tools.tsv', '单测 portable*\t.NET 10 SDK,Xcode\niOS 全量编译\tXcode\n')
        p=self.run_script('tools/gate.sh', GATE_LIST='1')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('钩子 runtime/gate.sh\n', p.stdout)
        self.assertIn('单测 portable_test\t需苹果工具链', p.stdout)
        self.write('tools/contrib_tools.tsv', '单测 portable_test\t.NET 10 SDK\n单测 portable*\tXcode\n')
        p=self.run_script('tools/gate.sh', GATE_LIST='1')
        self.assertIn('单测 portable_test\n', p.stdout)
    def test_real_toolchain_sets_repository_timeout_before_xcode_failure(self):
        # 真实仓库 source 身份检查：只解析 command -v，绝不执行 timeout。
        p=subprocess.run(['bash', '-uc', 'source "$1/tools/toolchain.sh" 2>/dev/null; rc=$?; test "$rc" = 1 || exit 3; command -v timeout', '_', str(H)],
            capture_output=True, text=True, timeout=10,
            env={**os.environ, 'S2A_DEVELOPER_DIR':str(self.r/'absent-xcode'), 'S2A_TC_RESOLVED':'0', 'PATH':'/usr/bin:/bin'})
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertEqual(p.stdout.strip(), str(H/'tools/bin/timeout'))
    def test_partial_results_count_only_finished_steps(self):
        # 真实 contrib；假 gate 列三步但仅返回一步绿，退出 0 也必须不完整。
        self.write('tools/gate.sh', 'if [ "${GATE_LIST:-}" = 1 ]; then printf "语法\\n单测 one\\n单测 two\\n"; else echo "🟢 语法"; fi\n')
        self.git('add', '.'); self.git('commit', '-qm', 'partial results fixture')
        p=self.run_script('tools/contrib_check.sh', '--base', self.base)
        self.assertEqual(p.returncode, 2, p.stdout+p.stderr)
        self.assertIn('应跑 3 步、跑了 1 步；绿 1、红 0', p.stdout)
        self.assertIn('结论：**不完整**', p.stdout)
        self.assertIn('只出 1 个结论', p.stdout)
    def test_non_linux_helper_is_silent(self):
        (self.r/'bin').mkdir()
        self.write('bin/uname', '#!/bin/sh\necho Darwin\n')
        (self.r/'bin/uname').chmod(0o755)
        for helper in ('linux_selfcheck_cases.sh', 'timeout_linux_cases.sh'):
            p=self.run_script(str(H/'tests'/helper), PATH=str(self.r/'bin')+os.pathsep+os.environ['PATH'])
            self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
            self.assertEqual(p.stdout+p.stderr, '')
    def test_apple_layer2_is_not_counted_as_missing_layer1(self):
        self.write('tools/contrib_layer2.tsv', '钩子 runtime/gate.sh\t要金样\n')
        self.git('add', '.'); self.git('commit', '-qm', 'layer2 fixture')
        p=self.run_script('tools/contrib_check.sh', '--base', self.base)
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertIn('应跑 3 步、跑了 3 步', p.stdout)
        second=next(line for line in p.stdout.splitlines() if line.startswith('- 第二层'))
        mac=next(line for line in p.stdout.splitlines() if line.startswith('- 待 Mac 证'))
        self.assertIn('钩子 runtime/gate.sh（要金样）', second)
        self.assertNotIn('钩子 runtime/gate.sh', mac)
        self.assertIn('iOS 全量编译', mac)
        self.assertNotIn('- 缺工具没跑', p.stdout)
    def test_list_without_xcode(self):
        p=self.run_script('tools/gate.sh', GATE_LIST='1')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('iOS 全量编译\t需苹果工具链', p.stdout)
        self.assertIn('钩子 runtime/gate.sh\t需苹果工具链', p.stdout)
        self.assertIn('单测 portable_test\n', p.stdout)
        self.assertFalse((self.r/'apple-ran').exists())
    def test_portable_runs_and_apple_goes_to_mac(self):
        # 多宿主（10-30）：本机能证的（语法、可移植单测、安卓钩子）照跑照判；苹果步不跑、不算不完整，列「待 Mac 证」
        p=self.run_script('tools/contrib_check.sh', '--base', self.base)
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertIn('应跑 3 步、跑了 3 步', p.stdout)
        self.assertIn('绿 3、红 0', p.stdout)
        self.assertIn('🟢 钩子 android/gate.sh', p.stdout)
        mac=next(line for line in p.stdout.splitlines() if line.startswith('- 待 Mac 证'))
        self.assertIn('iOS 全量编译', mac); self.assertIn('钩子 runtime/gate.sh', mac)
        self.assertIn('结论：**本机已证绿，待 Mac 证 2 步**', p.stdout)
        self.assertIn('工具链提示：🔴 Xcode-unavailable', p.stdout)
        self.assertFalse((self.r/'apple-ran').exists())
    def test_portable_failure_wins(self):
        p=self.run_script('tools/contrib_check.sh', '--base', self.base, PORTABLE_RC='1')
        self.assertEqual(p.returncode, 1, p.stdout+p.stderr)
        self.assertIn('结论：**红**', p.stdout)
        self.assertIn('红 1', p.stdout)
    def test_darwin_list_bytes_match_baseline_fixture(self):
        # uname/toolchain 是桩：只验证未改动分支，真实 macOS 对照仍需协作者。
        (self.r/'bin').mkdir()
        self.write('bin/uname', '#!/bin/sh\n echo Darwin\n')
        (self.r/'bin/uname').chmod(0o755)
        self.write('tools/toolchain.sh', 'return 0\n')
        env={'GATE_LIST':'1', 'PATH':str(self.r/'bin')+os.pathsep+os.environ['PATH']}
        b=self.run_script('tools/gate.sh', **env)
        self.assertEqual(b.returncode, 0, b.stderr)
        # 改前 main 的固定夹具字节，不依赖本地保留历史提交。
        self.assertEqual(b.stdout.encode(), ('语法\n单测 portable_test\niOS 全量编译\n'
            '钩子 android/gate.sh\n钩子 runtime/gate.sh\n').encode())
    def test_remote_selection_keeps_toolchain_preflight(self):
        p=self.run_script('tools/gate.sh', GATE_RERUN='单测 portable_test', GATE_HOST='gate-host')
        self.assertEqual(p.returncode, 2)
    def test_apple_budget_probe_is_not_executed_on_linux(self):
        self.write('runtime/gate.sh', '# 门禁预算：--budget\necho bad >> apple-ran\nexit 1\n')
        p=self.run_script('tools/gate.sh', GATE_LIST='1')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse((self.r/'apple-ran').exists())
    def test_unknown_rerun_is_not_zero_step_green(self):
        for selected in ('不存在', '语法\t不存在', '\t', '语法\n不存在', '语法\t\n不存在', '语法\r不存在'):
            with self.subTest(selected=selected):
                p=self.run_script('tools/gate.sh', GATE_RERUN=selected)
                self.assertEqual(p.returncode, 2, p.stdout+p.stderr)
                self.assertNotIn('门禁 绿', p.stdout)
    def test_routed_out_apple_is_rejected_before_filtering(self):
        p=self.run_script('tools/gate.sh', GATE_TIER='tool', GATE_RERUN='钩子 runtime/gate.sh')
        self.assertEqual(p.returncode, 2, p.stdout+p.stderr)
        self.assertNotIn('门禁 绿', p.stdout)
    def test_budget_query_remains_nonexecuting(self):
        p=self.run_script('tools/gate.sh', GATE_BUDGET_Q='1', GATE_RERUN='不存在')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, '0\n')
        self.assertFalse((self.r/'apple-ran').exists())
    def test_direct_gate_runs_portable_and_lists_mac(self):
        # 直接跑整份门禁：可移植步本机跑、照判；苹果步逐条「交 Mac 门禁」，机读行列全，末行不许是「门禁 绿」
        p=self.run_script('tools/gate.sh')
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertIn('⏭ iOS 全量编译：本机无苹果工具链，交 Mac 门禁', p.stdout)
        self.assertIn('⏭ 钩子 runtime/gate.sh：本机无苹果工具链，交 Mac 门禁', p.stdout)
        self.assertIn('🟢 单测 portable_test', p.stdout)
        self.assertIn('🟢 钩子 android/gate.sh', p.stdout)
        self.assertIn('待Mac证\tiOS 全量编译\t钩子 runtime/gate.sh\n', p.stdout)
        last=p.stdout.strip().splitlines()[-1]
        self.assertTrue(last.startswith('门禁 本机绿、待 Mac 证：'), last)
        self.assertIn('待 Mac 证 2 步', last)
        self.assertFalse((self.r/'apple-ran').exists())
        r=self.run_script('tools/gate.sh', PORTABLE_RC='1')
        self.assertEqual(r.returncode, 1, r.stdout+r.stderr)
        self.assertTrue(r.stdout.strip().splitlines()[-1].startswith('门禁 红：'))
    def test_selected_apple_goes_to_mac_not_green(self):
        p=self.run_script('tools/gate.sh', GATE_RERUN='钩子 runtime/gate.sh')
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertNotIn('门禁 绿', p.stdout)
        self.assertIn('待Mac证\t钩子 runtime/gate.sh\n', p.stdout)
        self.assertFalse((self.r/'apple-ran').exists())
    def pre_fixture(self, portable_rc='0', bad_script=False):
        # 列车入队预检（tools/train.sh pre）在没有苹果工具链的宿主上：合并树 = origin/main + 本支
        # 列车脚本是维护方工具，公开检出没有（同 tools/docs_consistency.py train_source）
        private = os.environ.get('S2A_PRIVATE_TOOLS')
        train = pathlib.Path(private) / 'train.sh' if private else H / 'tools/train.sh'
        if not train.exists():
            self.skipTest('公开检出没有列车脚本')
        shutil.copyfile(train, self.r / 'tools/train.sh')
        self.write('tools/gate_route.py', 'import glob, subprocess, sys\nc = sys.argv[1]\n'
                   'if c == "why": print("fixture")\nelif c == "tests": print("\\n".join(sorted(glob.glob("tests/*_test.sh"))))\n'
                   'elif c == "ios": print("yes")\nelif c == "hooks": print("runtime/gate.sh\\nandroid/gate.sh")\n')
        self.git('add', '.'); self.git('commit', '-qm', 'pre fixture'); self.git('branch', '-M', 'main')
        bare = self.r.parent / (self.r.name + '-origin.git')
        subprocess.run(['git', 'clone', '-q', '--bare', str(self.r), str(bare)], check=True)
        self.git('remote', 'add', 'origin', str(bare)); self.git('fetch', '-q', 'origin')
        self.git('checkout', '-qb', 'feat')
        self.write('runtime/change2.c', '// feat\n'); self.write('tests/portable_test.sh', f'echo portable-ran; exit {portable_rc}\n')
        if bad_script: self.write('tools/broken.sh', 'if then fi (\n')
        self.git('add', '.'); self.git('commit', '-qm', 'feat'); self.git('checkout', '-q', 'main')
        (self.r / 'home').mkdir()
        return self.run_script('tools/train.sh', 'pre', 'feat', S2A_REPO=str(self.r), S2A_TRAIN_DIR=str(self.r / 'train'),
                               S2A_TRAIN_WT=str(self.r / 'wt'), HOME=str(self.r / 'home'))
    # 预检自 f04541462 起只做确定性快检查（合 main 冲突 + 改动脚本语法 + 三项快检单测）；
    # 本支单测与钩子交列车门禁（gate-host 上跑，本机单测红在那里拒收），预检本机不跑。
    def test_pre_quick_checks_only_hands_tests_to_train(self):
        p=self.pre_fixture()
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        line=next(l for l in p.stdout.splitlines() if l.startswith('入队预检：'))
        self.assertIn('无冲突', line)
        self.assertIn('确定性快检查 1 步绿（改动脚本语法', line)   # 夹具没有三项快检单测，只剩语法 1 步
        self.assertIn('其余单测与钩子交列车门禁', line)
        self.assertNotIn('portable-ran', p.stdout+p.stderr)
        self.assertNotIn('portable-hook-ran', p.stdout+p.stderr)
        self.assertFalse((self.r/'apple-ran').exists())
    def test_pre_test_red_is_left_to_train(self):
        p=self.pre_fixture(portable_rc='1')
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertNotIn('拒绝入队', p.stdout)
    def test_pre_syntax_red_still_rejects(self):
        p=self.pre_fixture(bad_script=True)
        self.assertEqual(p.returncode, 1, p.stdout+p.stderr)
        self.assertIn('拒绝入队 feat', p.stdout)
        self.assertIn('语法错 tools/broken.sh', p.stdout)
unittest.main()
PYTEST
