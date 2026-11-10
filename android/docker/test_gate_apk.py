#!/usr/bin/env python3
"""Exercise the APK wrapper with a fake Docker process and real tracked files."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
WRAPPER = HERE / 'gate-apk.sh'


def pin_source(repo, sources, rel, line, name, version):
    """固定版本行带真 sha256，并把源码包按 sha 放进共享源码缓存（docker 准备缓存命中、不联网）。"""
    data = ('%s %s source\n' % (name, version)).encode()
    sha = hashlib.sha256(data).hexdigest()
    (repo / rel).parent.mkdir(parents=True, exist_ok=True)
    (repo / rel).write_text(line % (version, sha))
    (sources / sha).mkdir(parents=True, exist_ok=True)
    (sources / sha / (name % version)).write_bytes(data)
spec = importlib.util.spec_from_file_location('cache_identity', HERE / 'cache-identity.py')
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


class ApkWrapperTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='s2a-apk-wrapper-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / 'repo'
        directory = self.repo / 'android/docker'
        directory.mkdir(parents=True)
        shutil.copy2(WRAPPER, directory / 'gate-apk.sh')
        for name in ('prepare.sh', 'cache-identity.py'):
            shutil.copy2(HERE / name, directory / name)
        (self.repo / 'android/tools').mkdir(parents=True)
        shutil.copy2(HERE.parent / 'tools/fetch_source.sh', self.repo / 'android/tools/fetch_source.sh')
        self.sources = self.base / '.cache/s2arm-build/sources'
        pin_source(self.repo, self.sources, 'services/opus/build.sh', 'VER=%s; SHA=%s\n', 'opus-%s.tar.gz', '1.6.1')
        pin_source(self.repo, self.sources, 'android/openssl/build.sh', 'version=%s\nsha256=%s\n',
                   'openssl-%s.tar.gz', '3.5.9')
        self.write_dependency('1.15.0')
        for name in identity.REQUIRED['docker']:
            p = self.repo / name
            p.parent.mkdir(parents=True, exist_ok=True)
            if not p.exists():
                p.write_text(name)
        (self.repo / 'tracked.txt').write_text('original')
        for project in identity.PROJECTS:
            path = self.repo / project
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('<Project/>')
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), 'add', '.'], check=True)
        (self.repo / 'tracked.txt').write_text('changed working tree')
        (self.repo / 'untracked.txt').write_text('must not copy')
        recipe = hashlib.sha256((directory / 'Dockerfile').read_bytes()).hexdigest()
        self.cache = self.base / 'cache'
        self.cache.mkdir()
        self.identity = self.current_identity()
        self.receipt = self.slot(self.identity)
        self.receipt.write_text(json.dumps(self.identity, sort_keys=True, separators=(',', ':')))
        bindir = self.base / 'bin'
        bindir.mkdir()
        fake = bindir / 'docker'
        fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
base = pathlib.Path(os.environ['TEST_BASE'])
cache = base / 'cache'
def mapped(value):
    value = value.replace('/cache', str(cache))
    for arg in args:
        if arg.startswith('type=bind,source=') and ',target=/s2a-cache-identity.py' in arg:
            value = value.replace('/s2a-cache-identity.py',
                                  arg.split(',source=', 1)[1].split(',target=', 1)[0])
    return value
def run_env():
    env = os.environ.copy()
    for i, arg in enumerate(args):
        if arg == '--env':
            key, _, value = args[i + 1].partition('=')
            env[key] = mapped(value)
    return env
if args[:2] == ['image', 'inspect']:
    if os.environ.get('DOCKER_INSPECT_ERROR'): print('daemon unavailable', file=sys.stderr); sys.exit(1)
    if os.environ.get('DOCKER_MISSING'): print('Error: No such image: fixture', file=sys.stderr); sys.exit(1)
    if '--format' in args:
        print(os.environ['DOCKER_RECIPE'] if 'Config.Labels' in args[-1] else 'sha256:fixture')
    sys.exit(0)
if args[:2] == ['volume', 'inspect']:
    if os.environ.get('DOCKER_VOLUME_ERROR'): print('daemon unavailable', file=sys.stderr); sys.exit(1)
    if os.environ.get('DOCKER_VOLUME_MISSING'): print('Error: No such volume: fixture', file=sys.stderr); sys.exit(1)
    sys.exit(0)
if args[:2] == ['volume', 'create'] or (args and args[0] == 'build'):
    sys.exit(0)
if args and args[0] == 'run':
    entrypoint = args[args.index('--entrypoint') + 1] if '--entrypoint' in args else ''
    env = run_env()
    if entrypoint == 'sh':
        if os.environ.get('DOCKER_RECEIPT_ERROR'): sys.exit(125)
        script = args[args.index('-c') + 1]
        if os.environ.get('DOCKER_TOUCH_ERROR') and 'touch ' in script: sys.exit(125)
        sys.exit(subprocess.run(['sh', '-c', mapped(script)], env=env).returncode)
    if entrypoint == 'python3':
        script = args[args.index('-c') + 1]
        sys.exit(subprocess.run([sys.executable, '-c', mapped(script)], env=env).returncode)
    if entrypoint == 'du':
        print('40 /cache')
        sys.exit(0)
    if entrypoint == 'bash':
        if '--prepare-sdk' in args: sys.exit(int(os.environ.get('SDK_EXIT', '0')))
        if '--check-host' in args: sys.exit(int(os.environ.get('PROBE_EXIT', '0')))
        script = args[args.index('-c') + 1] if '-c' in args else ''
        if 's2a_apk_step' not in script:
            if 'gate-audit.py' in script: sys.exit(int(os.environ.get('PREPARE_EXIT', '0')))
            sys.exit(int(os.environ.get('RUN_EXIT', '0')))
    mount = next(x for x in args if x.startswith('type=bind,source='))
    root = pathlib.Path(mount.split(',source=', 1)[1].split(',target=', 1)[0])
    pathlib.Path(os.environ['DOCKER_LOG']).write_text(json.dumps({
        'args': args, 'contents': (root / 'tracked.txt').read_text(),
        'untracked': (root / 'untracked.txt').exists(), 'root': str(root)}))
    if os.environ.get('DOCKER_OUTPUT'): print(os.environ['DOCKER_OUTPUT'])
    sys.exit(int(os.environ.get('DOCKER_EXIT', '0')))
sys.exit(99)
''')
        fake.chmod(0o755)
        gh = bindir / 'gh'
        gh.write_text('#!/bin/sh\nprintf seed\n')
        gh.chmod(0o755)
        # 外层（门禁机）若设了 S2A_BUILD_CACHE，准备会去真缓存找源码包；单测只用临时家目录下那份。
        self.env = {k: v for k, v in os.environ.items() if k != 'S2A_BUILD_CACHE'}
        self.env.update(HOME=str(self.base), TEST_BASE=str(self.base),
                        PATH=str(bindir) + os.pathsep + self.env['PATH'],
                        DOCKER_LOG=str(self.base / 'docker.json'),
                        DOCKER_RECIPE=recipe)

    def slot(self, value):
        return self.cache / ('s2a-apk-gate-receipt-%s.json' % value['dependencies_sha256'][:12])

    def assert_no_protocol(self, result):
        self.assertNotIn('待宿主证\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertNotIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())

    def invoke(self):
        return subprocess.run(['bash', str(self.repo / 'android/docker/gate-apk.sh')],
                              env=self.env, capture_output=True, text=True)

    def prepare(self):
        return subprocess.run(['bash', str(self.repo / 'android/docker/prepare.sh')],
                              env=self.env, capture_output=True, text=True)

    def write_dependency(self, version):
        pin_source(self.repo, self.sources, 'services/vpx/build.sh', 'VER=%s; SHA=%s\n', 'libvpx-%s.tar.gz', version)

    def current_identity(self):
        recipe = hashlib.sha256((self.repo / 'android/docker/Dockerfile').read_bytes()).hexdigest()
        return identity.identity(self.repo, self.repo, 'docker',
                                 {'image_id': 'sha256:fixture', 'recipe': recipe})

    def test_offline_static_tracked_worktree_and_cleanup(self):
        import json
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertNotIn('待宿主证\t安卓宿主\tapk', result.stdout.splitlines())
        data = json.loads((self.base / 'docker.json').read_text())
        self.assertEqual(data['contents'], 'changed working tree')
        self.assertFalse(data['untracked'])
        self.assertFalse(Path(data['root']).exists())
        self.assertIn('--network', data['args'])
        self.assertEqual(data['args'][data['args'].index('--network') + 1], 'none')
        self.assertIn('S2A_BUILD_CACHE=/cache', data['args'])
        self.assertIn('S2ARM_ANDROID_CS_SERVICES=static', data['args'])
        self.assertIn('S2ARM_ANDROID_GAME_DIR=', data['args'])
        self.assertIn('RyuGpu=', data['args'])

    def test_docker_failure_is_red_and_cleanup_runs(self):
        import json
        self.env['DOCKER_EXIT'] = '37'
        result = self.invoke()
        self.assertEqual(result.returncode, 37)
        self.assertNotIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertNotIn('待宿主证\t安卓宿主\tapk', result.stdout.splitlines())
        data = json.loads((self.base / 'docker.json').read_text())
        self.assertFalse(Path(data['root']).exists())

    def test_gradle_failure_keeps_what_went_wrong(self):
        # gradle 失败：gate-step 取的第一条「> 」是阶段名，真正的报错在「* What went wrong:」段；门禁只留末 30 行，后面的 * Try: 与弃用提示会把它挤掉
        body = ['【红】APK gradle 失败（rc=1）：> Configure project :app', '> Configure project :app', 'FAILURE: Build failed with an exception.', '',
                '* What went wrong:', "A problem occurred configuring project ':app'.", '> SDK location not found: s2a_fixture_sdk', '', '* Try:',
                '> Run with --stacktrace option to get the stack trace.'] + [f'filler {i}' for i in range(40)] + ['BUILD FAILED in 1s']
        self.env.update(DOCKER_EXIT='1', DOCKER_OUTPUT='\n'.join(body))
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertIn("【红】APK gradle 失败（rc=1）：A problem occurred configuring project ':app'.", result.stderr)
        self.assertIn('> SDK location not found: s2a_fixture_sdk', '\n'.join(result.stdout.splitlines()[-15:]))

    def test_step_failure_reports_cause_before_timing_footer(self):
        script = HERE / 'gate-step.sh'
        cmd = 'source "$1"; s2a_apk_step bash -c '
        cmd += "'printf \"failure details\\nerror: missing symbol s2a_example\\n\"; exit 37'"
        result = subprocess.run(['bash', '-c', cmd, 'test', str(script)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 37)
        self.assertIn('【红】APK bash 失败（rc=37）：error: missing symbol s2a_example', result.stderr)

    def test_gate_summary_ends_with_failing_step_reason(self):
        gate_helper = HERE.parent / 'tools/gate_step.sh'
        step_helper = HERE / 'gate-step.sh'
        cmd = r'''set -euo pipefail
source "$1"
s2a_gate_init
trap 's2a_gate_finish $?' EXIT
s2a_gate_step bash -c 'source "$1"; s2a_apk_step bash -c "echo error: bad-relro; exit 7"' fixture "$2"
'''
        result = subprocess.run(['bash', '-c', cmd, 'fixture', str(gate_helper), str(step_helper)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 7)
        self.assertIn('error: bad-relro', result.stderr.splitlines()[-1])
        self.assertNotIn('墙钟', result.stderr.splitlines()[-1])

    def test_wrapper_reports_failing_step_before_earlier_negative_control(self):
        self.env['DOCKER_EXIT'] = '37'
        self.env['DOCKER_OUTPUT'] = ('【红】earlier expected negative control\n'
                                     '【红】APK python3 失败（rc=37）：bad GNU_RELRO\n'
                                     'later build output')
        result = self.invoke()
        self.assertEqual(result.returncode, 37)
        self.assertIn('bad GNU_RELRO', result.stderr.splitlines()[0])
        self.assertIn('earlier expected negative control', result.stdout)

    def test_missing_docker_is_not_run(self):
        bindir = self.base / 'no-docker-bin'
        bindir.mkdir()
        (bindir / 'dirname').symlink_to(shutil.which('dirname'))
        env = dict(self.env, PATH=str(bindir))
        result = subprocess.run(['/bin/bash', str(self.repo / 'android/docker/gate-apk.sh')],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('待宿主证\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertNotIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertIn('缺 Docker', result.stdout)

    def test_missing_image_points_to_prepare(self):
        self.env['DOCKER_MISSING'] = '1'
        result = self.invoke()
        self.assertEqual(result.returncode, 0)
        self.assertIn('待宿主证\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertNotIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertIn('缺镜像', result.stdout)
        self.assertIn('android/docker/prepare.sh', result.stdout)

    def test_missing_receipt_is_environment_not_ready(self):
        self.receipt.unlink()
        result = self.invoke()
        self.assertEqual(result.returncode, 0)
        self.assertIn('缺准备完成标记', result.stdout)
        self.assertIn('待宿主证\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertNotIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertFalse((self.base / 'docker.json').exists())

    def test_changed_dependency_without_its_slot_is_environment_not_ready(self):
        (self.repo / 'services/vpx/build.sh').write_text('changed')
        result = self.invoke()
        self.assertEqual(result.returncode, 0)
        self.assertIn('缺准备完成标记', result.stdout)
        self.assertIn('待宿主证\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertNotIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertFalse((self.base / 'docker.json').exists())
        self.env['DOCKER_RECIPE'] = 'stale-recipe'
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_protocol(result)
        self.assertIn('镜像配方不匹配', result.stderr)

    def test_corrupt_receipt_and_unreadable_dependency_are_red(self):
        self.receipt.write_text('corrupt')
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_protocol(result)
        self.assertIn('准备标记与镜像或依赖不匹配', result.stderr)
        (self.repo / 'services/vpx/build.sh').unlink()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_protocol(result)
        self.assertIn('依赖清单不可核实', result.stderr)

    def test_bad_image_label_is_red_even_without_volume(self):
        self.env.update(DOCKER_RECIPE='stale-recipe', DOCKER_VOLUME_MISSING='1')
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_protocol(result)
        self.assertIn('镜像配方不匹配', result.stderr)
        self.assertNotIn('未跑：', result.stdout)

    def test_docker_errors_are_red(self):
        for flag in ('DOCKER_INSPECT_ERROR', 'DOCKER_VOLUME_ERROR', 'DOCKER_RECEIPT_ERROR'):
            with self.subTest(flag=flag):
                self.env[flag] = '1'
                result = self.invoke()
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_protocol(result)
                self.assertNotIn('未跑：', result.stdout)
                self.assertFalse((self.base / 'docker.json').exists())
                del self.env[flag]

    def test_missing_volume_points_to_prepare_without_creating_it(self):
        self.env['DOCKER_VOLUME_MISSING'] = '1'
        result = self.invoke()
        self.assertEqual(result.returncode, 0)
        self.assertIn('缺缓存卷', result.stdout)
        self.assertIn('待宿主证\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertNotIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertIn('android/docker/prepare.sh', result.stdout)
        self.assertFalse((self.base / 'docker.json').exists())


    def test_two_dependency_identities_keep_separate_receipts(self):
        self.write_dependency('1.15.0')
        first = self.current_identity()
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        first_slot = self.slot(first)
        self.write_dependency('1.15.1')
        second = self.current_identity()
        self.assertNotEqual(first['dependencies_sha256'], second['dependencies_sha256'])
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        second_slot = self.slot(second)
        # Each tree's credential step reads its own slot: neither preparation
        # overwrites the other identity's receipt.
        self.write_dependency('1.15.0')
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())
        self.write_dependency('1.15.1')
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertTrue(first_slot.is_file())
        self.assertTrue(second_slot.is_file())
        self.assertNotEqual(first_slot, second_slot)

    def test_gate_use_protects_receipt_from_prune(self):
        # Retention must follow recent use, not just recent preparation: a main
        # identity prepares rarely but runs the gate every day, while branch
        # identities prepare in quick succession.
        slots = []
        for index in range(4):
            self.write_dependency('1.15.%d' % index)
            result = self.prepare()
            self.assertEqual(result.returncode, 0, result.stderr)
            value = self.current_identity()
            path = self.slot(value)
            self.assertTrue(path.is_file())
            stamp = 1_700_000_000_000_000_000 + index * 1_000_000_000
            os.utime(path, ns=(stamp, stamp))
            slots.append(path)
        used_before = slots[0].stat().st_mtime_ns
        self.write_dependency('1.15.0')
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())
        used_after_gate = slots[0].stat().st_mtime_ns
        self.write_dependency('1.15.4')
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        # A ran the gate after B/C/D prepared and is kept; B is now the
        # least recently used slot and is pruned when E prepares.
        self.assertTrue(slots[0].is_file())
        self.assertFalse(slots[1].exists())
        self.assertTrue(slots[2].is_file())
        self.assertTrue(slots[3].is_file())
        self.assertGreater(used_after_gate, used_before)

    def test_unwritable_receipt_slot_is_red_before_build(self):
        self.env['DOCKER_TOUCH_ERROR'] = '1'
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_protocol(result)
        self.assertIn('无法登记准备凭据使用时间', result.stderr)
        self.assertFalse((self.base / 'docker.json').exists())

    def test_receipt_slots_prune_oldest_beyond_four(self):
        dependency = self.cache / 'openssl/3.5.9-ndk29-api29/libssl.so'
        dependency.parent.mkdir(parents=True)
        dependency.write_text('dependency body')
        slots = []
        for index in range(5):
            self.write_dependency('1.15.%d' % index)
            result = self.prepare()
            self.assertEqual(result.returncode, 0, result.stderr)
            value = self.current_identity()
            path = self.slot(value)
            self.assertTrue(path.is_file())
            stamp = 1_700_000_000_000_000_000 + index * 1_000_000_000
            os.utime(path, ns=(stamp, stamp))
            slots.append(path)
        self.assertFalse(slots[0].exists())
        for path in slots[1:]:
            self.assertTrue(path.exists(), path)
        # Pruning only removes receipts, never the dependency cache entries.
        self.assertTrue(dependency.is_file())


class HostWrapperTest(unittest.TestCase):
    """The macOS host route shares docker's per-identity receipt slots."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='s2a-host-apk-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / 'repo'
        android = self.repo / 'android'
        directory = android / 'host'
        directory.mkdir(parents=True)
        shutil.copy2(HERE.parent / 'host/gate-apk.sh', directory / 'gate-apk.sh')
        shutil.copy2(HERE.parent / 'host/prepare.sh', directory / 'prepare.sh')
        (android / 'docker').mkdir(parents=True)
        shutil.copy2(HERE / 'cache-identity.py', android / 'docker/cache-identity.py')
        files = {
            'host/hostenv.sh': '''export ANDROID_HOME=$TEST_SDK ANDROID_SDK_ROOT=$TEST_SDK
export JAVAC=$TEST_JAVAC JAVA_HOME=$(dirname "$TEST_JAVAC")/..
export S2A_BUILD_CACHE=$TEST_BASE/cache NUGET_PACKAGES=$TEST_BASE/cache/nuget
export GRADLE_USER_HOME=$TEST_BASE/cache/gradle ANDROID_USER_HOME=$TEST_BASE/cache/android-user
mkdir -p "$S2A_BUILD_CACHE" "$(dirname "$JAVAC")/.."
''',
            'tools/versions.sh': '''S2A_ANDROID_NDK=29.0.14206865
S2A_ANDROID_PLATFORM=android-36 S2A_ANDROID_BUILD_TOOLS=36.0.0 S2A_ANDROID_CMAKE=3.31.6
s2a_sdkmanager_hint() { printf 'sdkmanager\\n'; }
''',
            'cs/build.sh': 'sdk_version=10.0.403\n',
            'docker/Dockerfile': 'FROM scratch\n',
            'docker/gate-step.sh': '#!/bin/sh\n',
            'docker/gate-audit.py': '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n',
            'doctor/archive_valid.py': '',
            'cs/archive_check.py': '',
            'codecs/build.sh': '#!/bin/sh\nexit 0\n',
            'openssl/build.sh': '#!/bin/sh\nexit 0\n',
            'host/build.sh': '#!/bin/sh\nexit 0\n',
            'services/opus/build.sh': '', 'services/opus/s2a_opus.c': '',
            'services/vpx/build.sh': 'VER=1.15.0; SHA=ignored\n',
            'services/vpx/s2a_vp8.c': '', 'services/vpx/s2a_vp9.c': '',
            'services/vpx/patches/0001-s2a-vp9-nvdec-hook.patch': '',
        }
        for name, text in files.items():
            path = android / name if not name.startswith('services/') else self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        shutil.copy2(HERE.parent / 'tools/ndk_toolchain.sh', android / 'tools/ndk_toolchain.sh')
        for name in identity.REQUIRED['host']:
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists():
                path.write_text(name)
        for project in identity.PROJECTS:
            path = self.repo / project
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('<Project/>')
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), 'add', '.'], check=True)
        self.sdk = self.base / 'sdk'
        self.ndk = self.sdk / 'ndk/29.0.14206865'
        (self.ndk / 'toolchains/llvm/prebuilt/darwin-arm64/bin').mkdir(parents=True)
        self.javac = self.base / 'jdk17/bin/javac'
        self.javac.parent.mkdir(parents=True)
        self.javac.write_text('#!/bin/sh\necho "javac 17.0.9"\n')
        self.javac.chmod(0o755)
        self.dotnet = self.base / 'dotnet'
        bindir = self.base / 'bin'
        bindir.mkdir()
        uname = bindir / 'uname'
        uname.write_text('#!/bin/sh\ncase "$1" in -sm) echo "Darwin arm64";; *) echo Darwin;; esac\n')
        sandbox = bindir / 'sandbox-exec'
        sandbox.write_text('#!/bin/sh\nexit "${SANDBOX_EXIT:-0}"\n')
        for path in (uname, sandbox):
            path.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.base), TEST_BASE=str(self.base), TEST_SDK=str(self.sdk),
                        TEST_JAVAC=str(self.javac), PATH=str(bindir) + os.pathsep + self.env['PATH'],
                        S2A_BUILD_CACHE=str(self.base / 'cache'))

    def slot(self, value):
        return (self.base / 'cache' /
                ('s2a-apk-gate-receipt-%s.json' % value['dependencies_sha256'][:12]))

    def prepare(self):
        return subprocess.run(['bash', str(self.repo / 'android/host/prepare.sh')],
                              env=self.env, capture_output=True, text=True)

    def invoke(self):
        return subprocess.run(['bash', str(self.repo / 'android/host/gate-apk.sh')],
                              env=self.env, capture_output=True, text=True)

    def write_dependency(self, version):
        (self.repo / 'services/vpx/build.sh').write_text('VER=%s; SHA=ignored\n' % version)

    def current_identity(self):
        return identity.identity(self.repo, self.repo, 'host', {
            'environment': identity.host_environment(self.sdk, self.ndk, self.dotnet, self.javac)})

    def test_two_host_dependency_identities_keep_separate_receipts(self):
        self.write_dependency('1.15.0')
        first = self.current_identity()
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        first_slot = self.slot(first)
        self.assertTrue(first_slot.is_file(), result.stderr)
        self.write_dependency('1.15.1')
        second = self.current_identity()
        self.assertNotEqual(first['dependencies_sha256'], second['dependencies_sha256'])
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        second_slot = self.slot(second)
        self.assertTrue(second_slot.is_file(), result.stderr)
        self.assertNotEqual(first_slot, second_slot)
        # Each tree's gate reads its own slot; neither preparation overwrote the
        # other identity's receipt.
        self.write_dependency('1.15.0')
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())
        self.write_dependency('1.15.1')
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertTrue(first_slot.is_file())
        self.assertTrue(second_slot.is_file())

    def test_host_gate_use_protects_receipt_from_prune(self):
        # Same acceptance as the docker route: retention follows recent use, not
        # only recent preparation.
        slots = []
        for index in range(4):
            self.write_dependency('1.15.%d' % index)
            result = self.prepare()
            self.assertEqual(result.returncode, 0, result.stderr)
            path = self.slot(self.current_identity())
            self.assertTrue(path.is_file(), result.stderr)
            stamp = 1_700_000_000_000_000_000 + index * 1_000_000_000
            os.utime(path, ns=(stamp, stamp))
            slots.append(path)
        used_before = slots[0].stat().st_mtime_ns
        self.write_dependency('1.15.0')
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())
        self.assertGreater(slots[0].stat().st_mtime_ns, used_before)
        self.write_dependency('1.15.4')
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        # A ran the gate after B/C/D prepared and is kept; B is now the least
        # recently used slot and is pruned when E prepares.
        self.assertTrue(slots[0].is_file())
        self.assertFalse(slots[1].exists())
        self.assertTrue(slots[2].is_file())
        self.assertTrue(slots[3].is_file())
        self.assertTrue(self.slot(self.current_identity()).is_file())

    def test_host_gate_missing_identity_slot_is_red(self):
        self.write_dependency('1.15.0')
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('缺准备完成标记', result.stderr)
        self.assertNotIn('已证宿主项\t安卓宿主\tapk', result.stdout.splitlines())


if __name__ == '__main__':
    unittest.main()