#!/usr/bin/env python3
"""Test preparation orchestration without network or Docker state changes."""
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROXY_ENV = ('HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'NO_PROXY',
             'https_proxy', 'http_proxy', 'all_proxy', 'no_proxy')


def pin_sources(repo, sources, vpx='1.15.0'):
    """固定版本行带真 sha256；sources（共享源码缓存目录）不为 None 时按 sha 放好源码包（缓存命中）。"""
    pins = {}
    for key, rel, line, name in (
            ('vpx', 'services/vpx/build.sh', 'VER=%s; SHA=%s\n', 'libvpx-%s.tar.gz'),
            ('opus', 'services/opus/build.sh', 'VER=%s; SHA=%s\n', 'opus-%s.tar.gz'),
            ('openssl', 'android/openssl/build.sh', 'version=%s\nsha256=%s\n', 'openssl-%s.tar.gz')):
        version = {'vpx': vpx, 'opus': '1.6.1', 'openssl': '3.5.9'}[key]
        data = ('%s-%s source\n' % (key, version)).encode()
        sha = hashlib.sha256(data).hexdigest()
        path = repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(line % (version, sha))
        if sources is not None:
            (sources / sha).mkdir(parents=True, exist_ok=True)
            (sources / sha / (name % version)).write_bytes(data)
        pins[key] = (name % version, sha, data)
    return pins
spec = importlib.util.spec_from_file_location('cache_identity', HERE / 'cache-identity.py')
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


class PrepareTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='s2a-prepare-test-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.repo = self.base / 'repo'
        docker = self.repo / 'android/docker'
        docker.mkdir(parents=True)
        for name in ('prepare.sh', 'cache-identity.py'):
            shutil.copy2(HERE / name, docker / name)
        (docker / 'Dockerfile').write_text('FROM scratch\n')
        (self.repo / 'android/tools').mkdir(parents=True)
        shutil.copy2(HERE.parent / 'tools/fetch_source.sh', self.repo / 'android/tools/fetch_source.sh')
        self.sources = self.base / '.cache/s2arm-build/sources'
        self.pins = pin_sources(self.repo, self.sources)
        for name in identity.REQUIRED['docker']:
            p = self.repo / name
            p.parent.mkdir(parents=True, exist_ok=True)
            if not p.exists():
                p.write_text(name)
        for project in identity.PROJECTS:
            path = self.repo / project
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('<Project/>')
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), 'add', '.'], check=True)
        bindir = self.base / 'bin'
        bindir.mkdir()
        fake = bindir / 'docker'
        fake.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
base = pathlib.Path(os.environ['TEST_BASE'])
with (base / 'docker.log').open('a') as out: out.write(' '.join(args) + '\\n')
if args[:2] == ['image', 'inspect']:
    if '--format' in args and (base / 'image').exists():
        if 'Config.Labels' in args[-1]: print((base / 'image').read_text())
        elif '.Id' in args[-1]: print('sha256:fixture')
        else: print('123')
    sys.exit(0 if (base / 'image').exists() else 1)
if args and args[0] == 'build':
    (base / 'image').write_text(args[args.index('--label') + 1].split('=', 1)[1])
    sys.exit(int(os.environ.get('BUILD_EXIT', '0')))
if args[:2] == ['volume', 'create']:
    print(args[2])
    sys.exit(0)
if args and args[0] == 'run':
    entrypoint = args[args.index('--entrypoint') + 1] if '--entrypoint' in args else ''
    marker = None
    if entrypoint == 'sh':
        for arg in args:
            if arg.startswith('S2A_APK_RECEIPT_PATH='):
                marker = base / pathlib.Path(arg.split('=', 1)[1]).name
        if marker is not None:
            marker.unlink(missing_ok=True)
        (base / 's2a-apk-gate-receipt.json').unlink(missing_ok=True)
        sys.exit(0)
    if entrypoint == 'python3':
        value = next(x.split('=', 1)[1] for x in args if x.startswith('S2A_APK_RECEIPT='))
        path = next(x.split('=', 1)[1] for x in args if x.startswith('S2A_APK_RECEIPT_PATH='))
        (base / pathlib.Path(path).name).write_text(value)
        sys.exit(0)
    if entrypoint == 'du':
        print('40 /cache')
        sys.exit(0)
    for arg in args:
        if arg.startswith('type=bind,source=') and arg.endswith(',target=/cache/sources'):
            sources = pathlib.Path(arg.split(',source=', 1)[1].split(',target=', 1)[0])
            names = sorted(p.name for p in sources.glob('*/*'))
            assert names == ['libvpx-1.15.0.tar.gz', 'openssl-3.5.9.tar.gz', 'opus-1.6.1.tar.gz'], names
    if '--check-host' in args:
        sys.exit(int(os.environ.get('PROBE_EXIT', '0')))
    if '--prepare-sdk' in args:
        sys.exit(int(os.environ.get('SDK_EXIT', '0')))
    if os.environ.get('MUTATE_REPO'):
        (base / 'repo/services/vpx/build.sh').write_text('changed while preparing')
    sys.exit(int(os.environ.get('RUN_EXIT', '0')))
sys.exit(99)
''')
        fake.chmod(0o755)
        # 下载命令桩：记账；FAKE_SOURCE_DIR 给了就按 URL 末段吐那份字节，否则失败（「网络不通」）。
        for tool in ('gh', 'curl'):
            path = bindir / tool
            path.write_text('#!/bin/sh\necho "%s $*" >> "$TEST_BASE/net.log"\n'
                            'for a; do last=$a; done\n'
                            '[ -n "${FAKE_SOURCE_DIR:-}" ] && [ -f "$FAKE_SOURCE_DIR/${last##*/}" ] '
                            '&& exec cat "$FAKE_SOURCE_DIR/${last##*/}"\n'
                            'echo "%s: network unreachable" >&2; exit 7\n' % (tool, tool))
            path.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if k not in PROXY_ENV and k != 'S2A_BUILD_CACHE'}
        self.env.update(HOME=str(self.base), TEST_BASE=str(self.base),
                        PATH=str(bindir) + os.pathsep + self.env['PATH'],
                        S2ARM_ANDROID_IMAGE='test-image:1', S2ARM_ANDROID_CACHE='test-cache')

    def run_prepare(self):
        return subprocess.run(['bash', str(self.repo / 'android/docker/prepare.sh')],
                              env=self.env, capture_output=True, text=True)

    def receipt_slot(self):
        recipe = hashlib.sha256((self.repo / 'android/docker/Dockerfile').read_bytes()).hexdigest()
        value = identity.identity(self.repo, self.repo, 'docker',
                                  {'image_id': 'sha256:fixture', 'recipe': recipe})
        return self.base / ('s2a-apk-gate-receipt-%s.json' % value['dependencies_sha256'][:12])

    def openssl_fixture(self, configure):
        android = self.repo / 'android'
        shutil.copy2(HERE.parent / 'openssl/build.sh', android / 'openssl/build.sh')
        helper = android / 'tools/ndk_toolchain.sh'
        helper.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(HERE.parent / 'tools/ndk_toolchain.sh', helper)
        shutil.copy2(HERE.parent / 'tools/versions.sh', android / 'tools/versions.sh')
        shutil.copy2(HERE.parent / 'tools/fetch_source.sh', android / 'tools/fetch_source.sh')
        for line in (HERE.parent / 'docker/Dockerfile').read_text().splitlines():
            if line.startswith('ARG SDK_PACKAGES='):
                (docker := self.repo / 'android/docker/Dockerfile').write_text(
                    docker.read_text() + line + '\n')
                break
        sdk = self.base / 'sdk'
        (sdk / 'ndk/29.0.14206865/toolchains/llvm/prebuilt/linux-x86_64/bin').mkdir(parents=True)
        bindir = self.base / 'bin'
        configure_path = self.base / 'Configure.extra'
        configure_path.write_text(configure)
        # 源码包走共用下载（gh 桩吐 openssl-3.5.9.tar.gz 的字节）；sha256sum 桩：清单校验一律过、
        # 对文件给出 openssl/build.sh 钉的 sha（源码包是假的），对 stdin 照真算（配方摘要）。
        fake_sources = self.base / 'fake-sources'
        fake_sources.mkdir()
        (fake_sources / 'openssl-3.5.9.tar.gz').write_bytes(b'x')
        pinned = next(line.split('=', 1)[1] for line in (android / 'openssl/build.sh').read_text().splitlines()
                      if line.startswith('sha256='))
        commands = {
            'sha256sum': '#!/bin/sh\ncase "$1" in -c) cat >/dev/null; exit 0;; "") exec /usr/bin/shasum -a 256;; esac\n'
                         'printf "%s  %s\\n" "$FAKE_FILE_SHA" "$1"\n',
            'tar': '#!/bin/sh\nmkdir -p "$4/openssl-3.5.9"; cp "$CONFIGURE_EXTRA" "$4/openssl-3.5.9/Configure"; chmod +x "$4/openssl-3.5.9/Configure"; printf license > "$4/openssl-3.5.9/LICENSE.txt"\n',
            'make': '#!/bin/sh\nprintf ssl > libssl.so; printf crypto > libcrypto.so\n',
            'llvm-strip': '#!/bin/sh\ncp "$4" "$3"\n',
        }
        for name, text in commands.items():
            path = bindir / name; path.write_text(text); path.chmod(0o755)
        env = dict(self.env, ANDROID_HOME=str(sdk), S2A_BUILD_CACHE=str(self.base / 'cache'),
                   CONFIGURE_EXTRA=str(configure_path), FAKE_SOURCE_DIR=str(fake_sources),
                   FAKE_FILE_SHA=pinned)
        return android, env, sdk

    def test_openssl_relative_entry_survives_source_working_directory(self):
        android, env, _ = self.openssl_fixture('#!/bin/sh\nexit 0\n')
        result = subprocess.run(['bash', 'openssl/build.sh'], cwd=android, env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.repo / 'build/android-cs/jniLibs/arm64-v8a/libssl.so').read_text(), 'ssl')
        self.assertEqual((self.repo / 'build/android-cs/jniLibs/arm64-v8a/libcrypto.so').read_text(), 'crypto')

    def test_openssl_buildinfo_is_pinned_and_recipe_enters_cache_key(self):
        # buildinf 的时刻与编译参数必须可复现；改配方必须换缓存键，否则旧缓存会盖住新参数。
        log = self.base / 'configure.log'
        android, env, sdk = self.openssl_fixture(
            '#!/bin/sh\nprintf "epoch=%s\\n" "${SOURCE_DATE_EPOCH-unset}" >> "$CONFIGURE_LOG"\n'
            'printf "cflags=%s\\n" "$CFLAGS" >> "$CONFIGURE_LOG"\nexit 0\n')
        env = dict(env, CONFIGURE_LOG=str(log))
        first = subprocess.run(['bash', 'openssl/build.sh'], cwd=android, env=env,
                               capture_output=True, text=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        script = android / 'openssl/build.sh'
        script.write_text(script.read_text() + '\n# recipe change\n')
        second = subprocess.run(['bash', 'openssl/build.sh'], cwd=android, env=env,
                                capture_output=True, text=True)
        self.assertEqual(second.returncode, 0, second.stderr)
        lines = log.read_text().splitlines()
        epochs = [line for line in lines if line.startswith('epoch=')]
        self.assertEqual(epochs, ['epoch=1761868800', 'epoch=1761868800'])
        self.assertEqual(len(list((self.base / 'cache/openssl').iterdir())), 2, lines)
        # NDK 版本也在键里：只改版本表（配方内容不变）也不得复用上一版缓存。
        dockerfile = self.repo / 'android/docker/Dockerfile'
        dockerfile.write_text(dockerfile.read_text().replace('ndk;29.0.14206865', 'ndk;99.0.0'))
        (sdk / 'ndk/99.0.0/toolchains/llvm/prebuilt/linux-x86_64/bin').mkdir(parents=True)
        third = subprocess.run(['bash', 'openssl/build.sh'], cwd=android, env=env,
                               capture_output=True, text=True)
        self.assertEqual(third.returncode, 0, third.stderr)
        self.assertEqual(len(list((self.base / 'cache/openssl').iterdir())), 3)

    def test_managed_publish_maps_repo_path_for_reproducible_type_names(self):
        # Roslyn 给 [GeneratedRegex] 的 file 局部类型名带源文件路径哈希；仓库根必须映射成固定虚拟路径，
        # 否则同一路换挂载目录 / 两路之间类型名都不同（APK 里 .rodata 随之错位）。
        script = (HERE.parent / 'cs/build.sh').read_text()
        self.assertIn('pathmap=$repo_dir=/_/s2a', script)
        publishes = [line for line in script.splitlines() if '"$dotnet" publish' in line]
        self.assertEqual(len(publishes), 3, publishes)
        self.assertEqual(script.count('-p:PathMap="$pathmap"'), 3)

    def test_repeated_run_reuses_image_and_cleans_scratch(self):
        self.assertEqual(self.run_prepare().returncode, 0)
        self.assertEqual(self.run_prepare().returncode, 0)
        lines = (self.base / 'docker.log').read_text().splitlines()
        self.assertEqual(sum(line.startswith('build ') for line in lines), 1)
        self.assertTrue(any('source=test-cache,target=/cache' in line for line in lines))
        self.assertTrue(any('S2A_BUILD_CACHE=/cache' in line for line in lines))
        sdk = next(i for i, line in enumerate(lines) if '--prepare-sdk' in line)
        probe = next(i for i, line in enumerate(lines) if '--check-host' in line)
        build = next(i for i, line in enumerate(lines) if 'target=/cache/sources' in line)
        self.assertIn('--env RyuGpu=', lines[build])
        self.assertLess(sdk, probe)
        self.assertLess(probe, build)
        self.assertIn('--platform linux/amd64', lines[probe])
        self.assertIn('--network none', lines[probe])
        self.assertEqual(list(self.base.glob('s2a-apk-prepare.*')), [])
        self.assertTrue(self.receipt_slot().is_file())

    def test_failure_is_red_and_scratch_is_removed(self):
        self.receipt_slot().write_text('stale')
        self.env['RUN_EXIT'] = '23'
        result = self.run_prepare()
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertFalse(self.receipt_slot().exists())
        self.assertEqual(list(self.base.glob('s2a-apk-prepare.*')), [])

    def test_changed_dependencies_while_preparing_leave_no_receipt(self):
        self.env['MUTATE_REPO'] = '1'
        result = self.run_prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.receipt_slot().exists())

    def test_dotnet_probe_failure_prevents_long_build(self):
        self.receipt_slot().write_text('stale')
        self.env['PROBE_EXIT'] = '42'
        result = self.run_prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('【红】', result.stderr)
        self.assertIn('Rosetta', result.stderr)
        lines = (self.base / 'docker.log').read_text().splitlines()
        self.assertTrue(any('--prepare-sdk' in line for line in lines))
        self.assertTrue(any('--check-host' in line for line in lines))
        self.assertFalse(any('target=/cache/sources' in line for line in lines))
        self.assertFalse(self.receipt_slot().exists())

    def test_sdk_download_failure_is_not_misreported_as_emulation_failure(self):
        self.env['SDK_EXIT'] = '17'
        result = self.run_prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Rosetta', result.stderr)
        lines = (self.base / 'docker.log').read_text().splitlines()
        self.assertFalse(any('--check-host' in line or 'target=/cache/sources' in line for line in lines))

    def test_actual_cs_probe_calls_version_and_project_evaluation(self):
        dotnet = self.base / 'dotnet'
        log = self.base / 'dotnet.log'
        dotnet.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_DOTNET_LOG"\n'
                          'case "$1" in --version) echo 10.0.403;;'
                          ' msbuild) exit "${MSBUILD_EXIT:-0}";; esac\n')
        dotnet.chmod(0o755)
        env = dict(self.env, S2A_ANDROID_DOTNET=str(dotnet), TEST_DOTNET_LOG=str(log), MSBUILD_EXIT='31')
        script = HERE.parent / 'cs/build.sh'
        result = subprocess.run(['bash', str(script), '--check-host'], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 31, result.stderr)
        lines = log.read_text().splitlines()
        self.assertEqual(lines[0], '--version')
        msbuild = [line for line in lines if line.startswith('msbuild ')]
        self.assertEqual(len(msbuild), 1, lines)
        self.assertIn('S2A.Android.Probe.csproj', msbuild[0])
        self.assertIn('-getProperty:TargetFramework', msbuild[0])
        self.assertIn('-p:RuntimeIdentifier=linux-bionic-arm64', msbuild[0])

    def test_cached_sources_need_no_proxy_and_no_download(self):
        # 没有任何代理环境、下载命令一调就失败：源码包已按 sha 在共享缓存里 → 准备照样走完、一次下载都不发起。
        self.assertFalse(any(k in self.env for k in PROXY_ENV))
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.base / 'net.log').exists(), (self.base / 'net.log').read_text()
                         if (self.base / 'net.log').exists() else '')
        self.assertTrue(self.receipt_slot().is_file())

    def test_missing_source_is_fetched_once_into_shared_cache(self):
        shutil.rmtree(self.sources)
        fake = self.base / 'fake-sources'
        fake.mkdir()
        # 桩按 URL 末段找字节：libvpx 的 GitHub 地址末段是 v<版本>.tar.gz，其余与文件名相同。
        tails = {'vpx': 'v1.15.0.tar.gz', 'opus': 'opus-1.6.1.tar.gz', 'openssl': 'openssl-3.5.9.tar.gz'}
        for key, (_, _, data) in self.pins.items():
            (fake / tails[key]).write_bytes(data)
        self.env['FAKE_SOURCE_DIR'] = str(fake)
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        for name, sha, data in self.pins.values():
            self.assertEqual((self.sources / sha / name).read_bytes(), data)
        calls = (self.base / 'net.log').read_text().splitlines()
        # GitHub 两包走 gh api，opus（xiph）走 curl；各一次。
        self.assertEqual(sorted(c.split()[0] for c in calls), ['curl', 'gh', 'gh'], calls)
        (self.base / 'net.log').unlink()
        self.assertEqual(self.run_prepare().returncode, 0)
        self.assertFalse((self.base / 'net.log').exists())

    def test_unreachable_source_is_red_before_container_build(self):
        shutil.rmtree(self.sources)
        result = self.run_prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('【红】下载失败 https://github.com/webmproject/libvpx/archive/refs/tags/v1.15.0.tar.gz', result.stderr)
        self.assertIn('network unreachable', result.stderr)
        lines = (self.base / 'docker.log').read_text().splitlines()
        self.assertFalse(any('target=/cache/sources' in line for line in lines))
        self.assertFalse(self.receipt_slot().exists())

    def test_mismatched_image_recipe_is_rebuilt(self):
        (self.base / 'image').write_text('stale')
        self.assertEqual(self.run_prepare().returncode, 0)
        lines = (self.base / 'docker.log').read_text().splitlines()
        self.assertEqual(sum(line.startswith('build ') for line in lines), 1)


if __name__ == '__main__':
    unittest.main()
