#!/usr/bin/env python3
"""Failure summaries must identify the failing child, not earlier red controls."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'android/tools/gate_step.sh'
GATE = ROOT / 'android/gate.sh'


class GateFailureSummaryTest(unittest.TestCase):
    def run_steps(self, failing):
        script = r'''set -euo pipefail
source "$1"
s2a_gate_init
trap 's2a_gate_finish $?' EXIT
s2a_gate_step bash -c 'echo "【红】earlier expected negative control"; exit 0'
s2a_gate_step bash -c "$2"
'''
        return subprocess.run(['bash', '-c', script, 'fixture', str(HELPER), failing],
                              text=True, capture_output=True)

    def test_first_red_of_failing_child_is_final_line_and_rc_is_preserved(self):
        result = self.run_steps('echo "【红】actual failing child" >&2; echo "【红】later detail"; echo "success-looking output"; exit 7')
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(result.stderr.splitlines()[-1], '【红】actual failing child')
        self.assertIn('earlier expected negative control', result.stdout)
        self.assertIn('success-looking output', result.stdout)

    def test_unmarked_failure_stays_red_and_includes_child_rc(self):
        result = self.run_steps('echo "compiler failed" >&2; exit 9')
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertIn('rc=9', result.stderr.splitlines()[-1])
        self.assertIn('compiler failed', result.stderr.splitlines()[-1])

    def test_failing_child_overrides_earlier_informational_note(self):
        # 11-07 mini：先有一条「仅 Linux 未运行」说明，之后视频工厂合同那一步 rc=75；摘要必须是 rc=75 那一步，不是说明
        script = r'''set -euo pipefail
source "$1"
s2a_gate_init
trap 's2a_gate_finish $?' EXIT
s2a_gate_note "W2 dispatch snapshot / record chain：未运行（仅 Linux 主机 libvulkan.so.1 组件测试）"
s2a_gate_step bash -c 'echo "PASS earlier"; echo "missing repository-pinned .NET SDK" >&2; exit 75'
s2a_gate_note "later informational note"
'''
        result = subprocess.run(['bash', '-c', script, 'fixture', str(HELPER)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 75, result.stderr)
        last = result.stderr.splitlines()[-1]
        self.assertIn('rc=75', last)
        self.assertIn('missing repository-pinned .NET SDK', last)
        self.assertNotIn('W2 dispatch', last)

    def test_note_alone_before_exit_stays_the_summary(self):
        script = r'''source "$1"; s2a_gate_init; trap 's2a_gate_finish $?' EXIT
s2a_gate_note "🔴 门禁找不到 JDK 17 的 javac"; exit 1'''
        result = subprocess.run(['bash', '-c', script, 'fixture', str(HELPER)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stderr.splitlines()[-1], '🔴 门禁找不到 JDK 17 的 javac')

    def test_success_has_no_failure_summary(self):
        script = 'set -euo pipefail; source "$1"; s2a_gate_init; trap \'s2a_gate_finish $?\' EXIT; s2a_gate_step bash -c "echo ok"'
        result = subprocess.run(['bash', '-c', script, 'fixture', str(HELPER)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'ok')
        self.assertEqual(result.stderr, '')

    def test_real_gate_preflight_keeps_red_as_last_line(self):
        with tempfile.TemporaryDirectory(prefix='s2a-gate-summary-') as temp:
            env = dict(os.environ, HOME=temp, S2A_PY=str(Path(temp) / 'missing-python'))
            result = subprocess.run(['bash', str(GATE)], env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('安卓门禁 Python 解释器无效', result.stderr.splitlines()[-1])


class MacHostGateTest(unittest.TestCase):
    def run_gate(self, colima=False, linux_fails=False, skip=False, host='Darwin', extra_env=None):
        with tempfile.TemporaryDirectory(prefix='s2a-mac-host-gate-') as temp:
            root = Path(temp)
            def write(name, content, executable=False):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
                if executable:
                    path.chmod(0o755)
                return path

            for name in ('android/gate.sh', 'android/tools/gate_step.sh'):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(ROOT / name, path)
            bindir = root / 'bin'
            bindir.mkdir()
            write('bin/uname', '#!/bin/sh\necho ' + host + '\n', True)
            write('bin/cmake', '#!/bin/sh\nexit 0\n', True)
            fake_python = write('bin/python3', '#!/bin/sh\nif [ "$1" = - ]; then cat >/dev/null; echo fixture; fi\nexit 0\n', True)
            if colima:
                write('bin/colima', '#!/bin/sh\nexit 0\n', True)
            java = root / 'jdk'
            write('jdk/include/jni.h', '')
            write('jdk/bin/javac', '#!/bin/sh\necho "    java.home = ' + str(java) + '" >&2\n', True)
            write('android/tools/jdk17.sh', '#!/bin/sh\necho ' + str(java / 'bin/javac') + '\n')
            write('android/test.sh', '#!/bin/sh\necho HOST_TEST_RAN VKREAL_SKIP=${S2A_ANDROID_SKIP_VKREAL:-0}\n')
            write('android/tests/nvn_vk_real_teardown_test.sh', '#!/bin/sh\necho TEARDOWN_RAN\n')
            write('android/linux_ctest.sh', '#!/bin/sh\necho LINUX_CTEST_RAN\nexit ' + ('1' if linux_fails else '0') + '\n')
            write('android/docker/gate-apk.sh', '#!/bin/sh\necho DOCKER_APK_GATE_RAN\n')
            # 与真实 host/gate-apk.sh 一致：非 Darwin 直接过、不出声。
            write('android/host/gate-apk.sh', '#!/bin/sh\n[ "$(uname -s)" = Darwin ] || exit 0\necho HOST_APK_GATE_RAN\n')
            env = dict(os.environ, PATH=str(bindir) + ':/usr/bin:/bin', S2A_PY=str(fake_python))
            env.pop('GATE_ONLY', None)
            env.pop('GATE_SKIP', None)
            if skip:
                env['GATE_SKIP'] = 'linux'
            if host != 'Darwin':
                # Linux 分支还调 tracking / 双 guest 测试，夹具只证 APK 路由。
                env['GATE_ONLY'] = 'apk'
            env.update(extra_env or {})
            return subprocess.run(['/bin/bash', str(root / 'android/gate.sh')], cwd=root,
                                  env=env, text=True, capture_output=True)

    def test_vkreal_skipped_on_remote_and_run_on_local(self):
        # 11-07：真 Vulkan 收尾探针在 macOS 上要 docker，mini 没有 → 每次自报 75、整步退回本机补跑。
        # 期望：GATE_SKIP 含 vkreal（派 mini 那份）→ test.sh 拿到跳过标记、探针不跑；GATE_ONLY=vkreal（本机另跑）→ 只跑探针
        r = self.run_gate(colima=True, extra_env={'GATE_SKIP': 'linux apk vkreal'})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('HOST_TEST_RAN VKREAL_SKIP=1', r.stdout + r.stderr)
        self.assertNotIn('TEARDOWN_RAN', r.stdout + r.stderr)
        r = self.run_gate(colima=True, extra_env={'GATE_ONLY': 'vkreal'})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('TEARDOWN_RAN', r.stdout + r.stderr)
        self.assertNotIn('HOST_TEST_RAN', r.stdout + r.stderr)

    def test_missing_colima_is_pending_and_apk_still_runs(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('待宿主证\t安卓宿主\tlinux', result.stdout.splitlines())
        # #1299：Darwin 只走宿主原生 APK 门禁，不在 arm64 上模拟 amd64 跑 docker。
        self.assertIn('HOST_APK_GATE_RAN', result.stdout)
        self.assertIn('macOS 跳过 docker 镜像构建', result.stdout)
        self.assertNotIn('DOCKER_APK_GATE_RAN', result.stdout + result.stderr)
        self.assertNotIn('LINUX_CTEST_RAN', result.stdout + result.stderr)

    def test_available_colima_and_failing_ctest_stays_red(self):
        result = self.run_gate(colima=True, linux_fails=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('LINUX_CTEST_RAN', result.stdout + result.stderr)
        self.assertNotIn('DOCKER_APK_GATE_RAN', result.stdout + result.stderr)
        self.assertNotIn('待宿主证\t安卓宿主\tlinux', result.stdout)

    def test_skip_linux_keeps_existing_behavior(self):
        result = self.run_gate(colima=True, linux_fails=True, skip=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('HOST_APK_GATE_RAN', result.stdout)
        self.assertNotIn('DOCKER_APK_GATE_RAN', result.stdout + result.stderr)
        self.assertNotIn('LINUX_CTEST_RAN', result.stdout + result.stderr)
        self.assertNotIn('待宿主证\t安卓宿主\tlinux', result.stdout)

    def test_linux_host_still_runs_docker_apk_gate(self):
        result = self.run_gate(host='Linux')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('DOCKER_APK_GATE_RAN', result.stdout)
        self.assertNotIn('HOST_APK_GATE_RAN', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
