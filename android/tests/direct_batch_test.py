#!/usr/bin/env python3
"""W2.4 宿主回归：请求集 → 批编 → 装库（direct_batch.py）。

覆盖：
  * 不给设备编译结果（capture 只有 request，没有 result），库由宿主批编产出；
  * 同一输入重出库逐字节一致；verify 复检通过；
  * 负例：manifest closure 不是本机编译器构建身份 → 拒绝，且不留库；
  * 负例：请求的 profile 与 manifest 不符 → 拒绝；
  * 负例：程序编译失败 → 整批失败、不留半成品库。

需要 dotnet 与真实编译器（与本仓 compiler/check.sh 同一实现）；缺 dotnet 时跳过，
不把"没跑"写成通过。
"""
import base64
import hashlib
import functools
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BATCH = REPO / 'android/tools/direct_batch.py'
CLI = REPO / 'graphics/tools/direct/compiler/cli'
TESTS = REPO / 'graphics/tools/direct/tests/compiler'
CONTENT_ROOT = 'sha256-' + 'a' * 64
MODULE_DIGEST = 'sha256-' + 'b' * 64
TITLE_ID = '0100000000000000'


def run(cmd, **kwargs):
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


def checked(cmd):
    proc = run(cmd, cwd=str(REPO))
    if proc.returncode != 0:
        raise AssertionError(f'{cmd!r} failed ({proc.returncode}):\n{proc.stdout}\n{proc.stderr}')
    return proc.stdout


def build_jobs():
    value = os.environ.get('S2A_JOBS', '1')
    if not value.isascii() or not value.isdecimal() or int(value) < 1:
        raise ValueError('S2A_JOBS must be a positive integer')
    return str(int(value))


def build_project(project):
    # dotnet run does not forward MSBuild node switches. Build the complete project
    # (including references), then query its actual TargetPath in the same config.
    jobs = build_jobs()
    checked(['dotnet', 'build', str(project), '-c', 'Release', f'-m:{jobs}', '--nologo'])
    target = Path(checked(['dotnet', 'msbuild', str(project), '-p:Configuration=Release',
                           f'-m:{jobs}', '-nologo', '-getProperty:TargetPath']).strip())
    if not target.is_absolute() or not target.is_file() or target.suffix != '.dll':
        raise AssertionError(f'built TargetPath is not an existing absolute DLL: {target}')
    return target


def assert_identity(expected, actual):
    for key in ('schema', 'rule', 'translatorClosure', 'sourcesDigest', 'sources', 'bytes'):
        if actual.get(key) != expected[key]:
            raise AssertionError(f'compiler identity {key} is not current: '
                                 f'{actual.get(key)!r} != {expected[key]!r}')


def assert_deployment(compiler_dll, executables):
    digest = hashlib.sha256(compiler_dll.read_bytes()).digest()
    for executable in executables:
        deployed = executable.parent / compiler_dll.name
        if hashlib.sha256(deployed.read_bytes()).digest() != digest:
            raise AssertionError(f'compiler deployment is not this build: {deployed}')


@functools.cache
def built_tools():
    """One complete Release build per executable for this test process, no old DLL scan."""
    tests = build_project(TESTS / 'DirectCompiler.Tests.csproj')
    cli = build_project(CLI / 'S2A.DirectCompiler.Cli.csproj')
    compiler = CLI.parent / 'S2A.DirectCompiler.csproj'
    properties = json.loads(checked([
        'dotnet', 'msbuild', str(compiler), '-p:Configuration=Release',
        f'-m:{build_jobs()}', '-nologo', '-target:DirectClosurePaths',
        '-getProperty:TargetPath,DirectClosureList,DirectClosureCs']))['Properties']
    closure_path = CLI.parent / 'closure.py'
    checked([sys.executable, str(closure_path), '--root', str(REPO),
             '--list', properties['DirectClosureList'], '--check', properties['DirectClosureCs']])
    spec = importlib.util.spec_from_file_location('direct_batch_test_closure', closure_path)
    closure = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(closure)
    options = closure.cs_options(Path(properties['DirectClosureCs']).read_text(encoding='utf-8'))
    expected = json.loads(checked([sys.executable, str(closure_path), '--root', str(REPO),
                                   '--list', properties['DirectClosureList'], '--json',
                                   '--options', options]))
    # Both runners must carry the exact just-built compiler, not an older copied dependency.
    compiler_dll = Path(properties['TargetPath'])
    assert_deployment(compiler_dll, (tests, cli))
    identity = json.loads(checked(['dotnet', str(cli), 'identity']))
    assert_identity(expected, identity)
    print(f"direct batch: Release -m:{build_jobs()}, "
          f"compiler sha256={hashlib.sha256(compiler_dll.read_bytes()).hexdigest()}, "
          f"closure={identity['translatorClosure']}", file=sys.stderr)
    return tests, cli, identity


class BuildInvocationTest(unittest.TestCase):
    """调用合同与失败负控不需要 SDK；真实宿主回归仍在下列两类运行。"""

    def test_build_once_then_exact_target(self):
        with tempfile.TemporaryDirectory() as directory:
            dll = Path(directory) / 'exact.dll'
            dll.write_bytes(b'synthetic contract fixture, not a real compiler')
            results = [subprocess.CompletedProcess([], 0, 'built', ''),
                       subprocess.CompletedProcess([], 0, str(dll), '')]
            with mock.patch.dict(os.environ, {'S2A_JOBS': '3'}), \
                    mock.patch(__name__ + '.run', side_effect=results) as call:
                self.assertEqual(build_project(CLI / 'S2A.DirectCompiler.Cli.csproj'), dll)
            self.assertEqual(call.call_args_list[0].args[0],
                             ['dotnet', 'build', str(CLI / 'S2A.DirectCompiler.Cli.csproj'),
                              '-c', 'Release', '-m:3', '--nologo'])
            self.assertEqual(call.call_args_list[1].args[0],
                             ['dotnet', 'msbuild', str(CLI / 'S2A.DirectCompiler.Cli.csproj'),
                              '-p:Configuration=Release', '-m:3', '-nologo',
                              '-getProperty:TargetPath'])

    def test_failed_build_is_red_and_never_executes_stale_artifact(self):
        with mock.patch(__name__ + '.run', return_value=
                        subprocess.CompletedProcess([], 7, '', 'build broke')) as call:
            with self.assertRaisesRegex(AssertionError, 'build broke'):
                build_project(CLI / 'S2A.DirectCompiler.Cli.csproj')
        self.assertEqual(call.call_count, 1)

    def test_jobs_rejects_invalid_values_before_subprocess(self):
        for value in ('0', '-1', 'two', '1.5', '', '1;other'):
            with self.subTest(value=value), mock.patch.dict(os.environ, {'S2A_JOBS': value}), \
                    mock.patch(__name__ + '.run') as call:
                with self.assertRaisesRegex(ValueError, 'S2A_JOBS'):
                    build_project(CLI / 'S2A.DirectCompiler.Cli.csproj')
                call.assert_not_called()

    def test_defaults_to_one_node(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(build_jobs(), '1')

    def test_missing_target_does_not_fall_back_to_old_dll(self):
        with tempfile.TemporaryDirectory() as directory:
            old = Path(directory) / 'old.dll'
            old.write_bytes(b'old artifact')
            results = [subprocess.CompletedProcess([], 0, '', ''),
                       subprocess.CompletedProcess([], 0, str(Path(directory) / 'absent.dll'), '')]
            with mock.patch(__name__ + '.run', side_effect=results):
                with self.assertRaisesRegex(AssertionError, 'TargetPath'):
                    build_project(CLI / 'S2A.DirectCompiler.Cli.csproj')

    def test_old_deployed_compiler_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compiler = root / 'compiler.dll'
            compiler.write_bytes(b'new compiler build')
            (root / 'cli').mkdir()
            deployed = root / 'cli/compiler.dll'
            deployed.write_bytes(compiler.read_bytes())
            assert_deployment(compiler, [root / 'cli/runner.dll'])
            deployed.write_bytes(b'old compiler build')
            with self.assertRaisesRegex(AssertionError, 'not this build'):
                assert_deployment(compiler, [root / 'cli/runner.dll'])

    def test_batch_uses_explicit_built_dll(self):
        with tempfile.TemporaryDirectory() as directory:
            case = DirectBatchTest('test_builds_library_from_request_set')
            case.base = Path(directory)
            case.cli = case.base / 'built-cli.dll'
            with mock.patch(__name__ + '.run', return_value=
                            subprocess.CompletedProcess([], 0, '', '')) as call:
                case.build({}, 'contract')
            command = call.call_args.args[0]
            self.assertEqual(command[command.index('--cli') + 1], str(case.cli))
            self.assertEqual(command[:3], [sys.executable, str(BATCH), 'build'])

    def test_stale_identity_rejected(self):
        expected = {'schema': 's2a-direct-identity-v1', 'rule': 's2a-direct-closure-v2',
                    'translatorClosure': 's2a-dc1-' + 'a' * 64,
                    'sourcesDigest': 'sha256-' + 'a' * 64, 'sources': 2, 'bytes': 30}
        assert_identity(expected, dict(expected))
        for key in expected:
            with self.subTest(key=key):
                stale = dict(expected)
                stale[key] = 'old'
                with self.assertRaisesRegex(AssertionError, key):
                    assert_identity(expected, stale)


@unittest.skipUnless(shutil.which('dotnet'), 'dotnet is not installed')
class DirectBatchTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        tests, cls.cli, cls.identity = built_tools()
        cls.base = Path(tempfile.mkdtemp(prefix='s2a-direct-batch-test-')).resolve()
        cls.addClassCleanup(shutil.rmtree, cls.base, ignore_errors=True)
        cls.requests = cls.base / 'requests'
        checked(['dotnet', str(tests), '--emit-requests', str(cls.requests)])
        (cls.base / 'identity.json').write_text(json.dumps(cls.identity), encoding='utf-8')
        cls.profile_hash = json.loads((cls.requests / 'graphics.json').read_bytes())['profile']['profileHash']

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.base, ignore_errors=True)

    def manifest(self, names=('graphics.json', 'compute.json', 'c2vspos.json'), closure=None,
                 profile_hash=None, subdir='requests'):
        entries = []
        for name in names:
            raw = (self.base / subdir / name).read_bytes()
            entries.append({'identity': hashlib.sha256(raw).hexdigest(),
                            'request': subdir + '/' + name})
        return {'schema': 's2a-direct-programs-v1', 'directABI': 1,
                'translatorClosure': closure or self.identity['translatorClosure'],
                'profileHash': profile_hash or self.profile_hash,
                'sourceParserVersion': 1, 'entries': entries}

    def build(self, manifest, tag):
        path = self.base / f'programs-{tag}.json'
        path.write_text(json.dumps(manifest, indent=1), encoding='utf-8')
        library = self.base / f'lib-{tag}'
        descriptor = self.base / f'graphics-{tag}.json'
        proc = run([sys.executable, str(BATCH), 'build', '--programs', str(path),
                    '--out', str(library), '--descriptor', str(descriptor),
                    '--title-id', TITLE_ID, '--identity', str(self.base / 'identity.json'),
                    '--game-content-root', CONTENT_ROOT, '--module-set-digest', MODULE_DIGEST,
                    '--cli', str(self.cli), '--jobs', '2',
                    '--report', str(self.base / f'batch-{tag}.json')], cwd=str(REPO))
        return proc, library, descriptor

    def test_builds_library_from_request_set(self):
        proc, library, descriptor = self.build(self.manifest(), 'ok')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(descriptor.is_file(), 'descriptor missing')
        report = json.loads((self.base / 'batch-ok.json').read_text())
        self.assertEqual((report['compiled'], report['deferred'], report['failed']), (3, 0, 0))
        self.assertEqual(report['library']['descriptor'], str(descriptor))
        programs = sorted(library.rglob('*.program'))
        self.assertEqual(len(programs), 3, programs)
        verify = run([sys.executable, str(BATCH), 'verify', '--lib', str(library),
                      '--descriptor', str(descriptor)], cwd=str(REPO))
        self.assertEqual(verify.returncode, 0, verify.stderr)
        # 同一输入重出库逐字节一致（库文件名含身份，内容不含时间/路径）。
        proc2, library2, descriptor2 = self.build(self.manifest(), 'again')
        self.assertEqual(proc2.returncode, 0, proc2.stderr)
        for first in programs:
            second = library2 / first.relative_to(library)
            self.assertEqual(first.read_bytes(), second.read_bytes(), f'{first.name} differs')
        self.assertEqual(descriptor.read_bytes(), descriptor2.read_bytes())

    def test_imported_requests_compile_and_verify(self):
        capture = self.base / 'device-dump'
        capture.mkdir()
        # Opaque synthetic identities exercise transport, not device provenance.
        identities = ['1' * 64, '2' * 64, '3' * 64]
        for name, identity in zip(('graphics.json', 'compute.json', 'c2vspos.json'), identities):
            raw = (self.requests / name).read_bytes()
            request_id = json.loads(raw)['requestId']
            (capture / f'{request_id}-{identity}.compile-request.json').write_bytes(raw)
        imported = self.base / 'imported'
        proc = run([sys.executable, str(BATCH), 'import-requests', '--capture', str(capture),
                    '--out', str(imported)], cwd=str(REPO))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        manifest = json.loads((imported / 'programs.v1.json').read_bytes())
        self.assertEqual([e['identity'] for e in manifest['entries']], identities)
        library, descriptor = self.base / 'import-lib', self.base / 'import-graphics.json'
        proc = run([sys.executable, str(BATCH), 'build', '--programs', str(imported / 'programs.v1.json'),
                    '--out', str(library), '--descriptor', str(descriptor), '--title-id', TITLE_ID,
                    '--identity', str(self.base / 'identity.json'), '--cli', str(self.cli), '--jobs', '1',
                    '--game-content-root', CONTENT_ROOT, '--module-set-digest', MODULE_DIGEST], cwd=str(REPO))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(list(library.rglob('*.program'))), 3)
        proc = run([sys.executable, str(BATCH), 'verify', '--lib', str(library),
                    '--descriptor', str(descriptor)], cwd=str(REPO))
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_rejects_foreign_closure(self):
        proc, library, _ = self.build(self.manifest(closure='s2a-dc1-' + '0' * 64), 'closure')
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('translatorClosure', proc.stderr)
        self.assertFalse(library.exists(), 'a rejected batch must not leave a library')

    def test_rejects_profile_mismatch(self):
        proc, library, _ = self.build(self.manifest(profile_hash='sha256-' + 'c' * 64), 'profile')
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('profile', proc.stderr)
        self.assertFalse(library.exists(), 'a rejected batch must not leave a library')

    def test_compile_failure_leaves_nothing(self):
        # 把一条请求的着色器代码改坏（不是 0x50 字节的 Maxwell 头）：编译器报错，整批失败。
        broken = self.base / 'broken'
        shutil.copytree(self.requests, broken)
        doc = json.loads((broken / 'c2vspos.json').read_bytes())
        doc['program']['stages'][0]['code'] = base64.b64encode(b'\x00' * 8).decode('ascii')
        (broken / 'c2vspos.json').write_text(json.dumps(doc), encoding='utf-8')
        proc, library, descriptor = self.build(self.manifest(subdir='broken'), 'broken')
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('compilation failed', proc.stderr)
        self.assertFalse(library.exists(), 'a failed batch must not leave a library')
        self.assertFalse(descriptor.exists(), 'a failed batch must not leave a descriptor')


class BatchReportTest(unittest.TestCase):
    """Report publication, using real batch/library validation and a compiler stub.

    Public synthetic request/result bytes exercise packaging only, not compilation
    or device adoption. No SDK, GPU, game data or private cache is used.
    """
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        sys.path.insert(0, str(REPO / 'android/tools'))
        sys.path.insert(0, str(REPO / 'android/tests'))
        import direct_batch
        from direct_library_test import make_request, make_result
        self.batch = direct_batch
        self.make_request = make_request
        self.make_result = make_result

    def case(self, name):
        root = self.base / name
        root.mkdir()
        request = self.make_request()
        (root / 'request.json').write_text(json.dumps(request), encoding='utf-8')
        (root / 'identity.json').write_text(json.dumps({
            'schema': 's2a-direct-identity-v1',
            'translatorClosure': request['translatorClosure']}), encoding='utf-8')
        (root / 'programs.json').write_text(json.dumps({
            'schema': 's2a-direct-programs-v1', 'directABI': request['directABI'],
            'translatorClosure': request['translatorClosure'],
            'profileHash': request['profile']['profileHash'], 'sourceParserVersion': 1,
            'entries': [{'identity': '1' * 64, 'request': 'request.json'}]}), encoding='utf-8')
        (root / 'index.tsv').write_text('modules/main.nso\t1\t' + 'c' * 64 + '\n',
                                       encoding='utf-8')
        return root

    def compile_fixture(self, command, entry, staging):
        # Only the compiler is replaced. The production capture, container,
        # descriptor, digest checks and final verify are all real.
        result = staging / 'fixture-result.json'
        result.write_bytes(self.make_result(json.loads(entry['request'].read_bytes())))
        return {'index': entry['index'], 'status': 'compiled', 'result': result}

    def build(self, root, report, **kwargs):
        return self.batch.build(root / 'programs.json', root / 'library',
                                root / 'graphics.json', TITLE_ID, root / 'identity.json',
                                'unused-compiler.dll', 1, report_path=report,
                                game_content_root=CONTENT_ROOT, module_set_digest=MODULE_DIGEST,
                                **kwargs)

    def assert_rejected_before_compile(self, root, report):
        with mock.patch.object(self.batch, 'compile_one', side_effect=self.compile_fixture) as compile_call:
            with self.assertRaises((self.batch.BatchError, OSError)):
                self.build(root, report)
        compile_call.assert_not_called()
        self.assertFalse((root / 'library').exists())
        self.assertFalse((root / 'graphics.json').exists())

    def test_report_cannot_replace_descriptor(self):
        root = self.case('descriptor')
        self.assert_rejected_before_compile(root, root / 'graphics.json')

    def test_report_cannot_change_or_pollute_library(self):
        for name in ('library.v1.json', 'report.json'):
            with self.subTest(name=name):
                root = self.case(name)
                self.assert_rejected_before_compile(root, root / 'library' / name)

    def test_report_cannot_overwrite_inputs(self):
        for name in ('programs.json', 'request.json', 'identity.json', 'index.tsv'):
            with self.subTest(name=name):
                root = self.case(name)
                before = (root / name).read_bytes()
                self.assert_rejected_before_compile(root, root / name)
                self.assertEqual((root / name).read_bytes(), before)

    def test_existing_report_is_preserved(self):
        root = self.case('existing')
        report = root / 'report.json'
        report.write_bytes(b'existing report')
        self.assert_rejected_before_compile(root, report)
        self.assertEqual(report.read_bytes(), b'existing report')

    def test_missing_report_parent_is_rejected_before_compile(self):
        root = self.case('missing-parent')
        self.assert_rejected_before_compile(root, root / 'missing' / 'report.json')

    def test_report_symlink_to_descriptor_is_rejected(self):
        root = self.case('symlink')
        report = root / 'report.json'
        report.symlink_to(root / 'graphics.json')
        self.assert_rejected_before_compile(root, report)
        self.assertTrue(report.is_symlink())

    def test_report_parent_alias_cannot_replace_descriptor(self):
        root = self.case('parent-alias')
        alias = root / 'alias'
        alias.symlink_to(root, target_is_directory=True)
        self.assert_rejected_before_compile(root, alias / 'graphics.json')

    def test_report_cannot_be_an_output_ancestor(self):
        root = self.case('ancestor')
        with mock.patch.object(self.batch, 'compile_one', side_effect=self.compile_fixture) as call:
            with self.assertRaises((self.batch.BatchError, OSError)):
                self.batch.build(root / 'programs.json', root / 'publish' / 'library',
                                 root / 'publish' / 'graphics.json', TITLE_ID,
                                 root / 'identity.json', 'unused-compiler.dll', 1,
                                 report_path=root / 'publish', game_content_root=CONTENT_ROOT,
                                 module_set_digest=MODULE_DIGEST)
        call.assert_not_called()
        self.assertFalse((root / 'publish').exists())

    def test_late_report_failure_retains_verified_outputs_and_reports_failure(self):
        root = self.case('late-failure')
        report = root / 'report.json'
        with mock.patch.object(self.batch, 'compile_one', side_effect=self.compile_fixture), \
                mock.patch.object(self.batch.os, 'fsync', side_effect=OSError('synthetic disk full')):
            with self.assertRaisesRegex(self.batch.BatchError, 'report publication failed') as error:
                self.build(root, report)
        message = str(error.exception)
        self.assertIn('retained', message)
        self.assertIn(str(root / 'library'), message)
        self.assertIn(str(root / 'graphics.json'), message)
        self.assertFalse(report.exists())
        self.assertFalse(list(root.glob('.direct-batch-report-*')))
        self.batch.direct_library.verify_library(
            root / 'library', self.batch.direct_library.load_descriptor(root / 'graphics.json'))

    def test_cli_late_report_failure_returns_one_without_success_output(self):
        root = self.case('cli-failure')
        report = root / 'report.json'
        arguments = ['build', '--programs', str(root / 'programs.json'),
                     '--out', str(root / 'library'), '--descriptor', str(root / 'graphics.json'),
                     '--title-id', TITLE_ID, '--identity', str(root / 'identity.json'),
                     '--cli', 'unused-compiler.dll', '--jobs', '1', '--report', str(report),
                     '--game-content-root', CONTENT_ROOT, '--module-set-digest', MODULE_DIGEST]
        with mock.patch.object(self.batch, 'compile_one', side_effect=self.compile_fixture), \
                mock.patch.object(self.batch.os, 'fsync', side_effect=OSError('synthetic disk full')), \
                mock.patch('sys.stdout', new_callable=io.StringIO) as stdout, \
                mock.patch('sys.stderr', new_callable=io.StringIO) as stderr:
            self.assertEqual(self.batch.main(arguments), 1)
        self.assertEqual(stdout.getvalue(), '')
        self.assertIn('report publication failed', stderr.getvalue())
        self.assertIn('completed library retained at ' + str(root / 'library'), stderr.getvalue())
        self.assertIn('completed descriptor retained at ' + str(root / 'graphics.json'), stderr.getvalue())
        self.assertFalse(report.exists())
        self.batch.direct_library.verify_library(
            root / 'library', self.batch.direct_library.load_descriptor(root / 'graphics.json'))

    def test_report_publication_race_preserves_other_writer(self):
        root = self.case('race')
        report = root / 'report.json'
        link = os.link
        def competing_link(source, destination):
            self.assertEqual(Path(destination), report)
            report.write_bytes(b'other writer')
            return link(source, destination)
        with mock.patch.object(self.batch, 'compile_one', side_effect=self.compile_fixture), \
                mock.patch.object(self.batch.os, 'link', side_effect=competing_link):
            with self.assertRaisesRegex(self.batch.BatchError, 'report publication failed'):
                self.build(root, report)
        self.assertEqual(report.read_bytes(), b'other writer')
        self.batch.direct_library.verify_library(
            root / 'library', self.batch.direct_library.load_descriptor(root / 'graphics.json'))

    def test_cleanup_failure_after_link_is_not_publication_failure(self):
        root = self.case('cleanup')
        report = root / 'report.json'
        unlink = os.unlink
        def fail_report_temp(path, *args, **kwargs):
            if Path(path).name.startswith('.direct-batch-report-'):
                raise OSError('synthetic cleanup failure')
            return unlink(path, *args, **kwargs)
        with mock.patch.object(self.batch, 'compile_one', side_effect=self.compile_fixture), \
                mock.patch.object(self.batch.os, 'unlink', side_effect=fail_report_temp), \
                mock.patch('sys.stderr', new_callable=io.StringIO) as stderr:
            result = self.build(root, report)
        self.assertIn('report published;', stderr.getvalue())
        self.assertEqual(json.loads(report.read_bytes()), result)
        self.batch.direct_library.verify_library(
            root / 'library', self.batch.direct_library.load_descriptor(root / 'graphics.json'))

    def test_no_report_keeps_existing_build_contract(self):
        root = self.case('no-report')
        with mock.patch.object(self.batch, 'compile_one', side_effect=self.compile_fixture):
            result = self.build(root, None)
        self.assertEqual(result['compiled'], 1)
        self.batch.direct_library.verify_library(
            root / 'library', self.batch.direct_library.load_descriptor(root / 'graphics.json'))

    def test_external_report_and_library_verify(self):
        root = self.case('success')
        report = root / 'report.json'
        with mock.patch.object(self.batch, 'compile_one', side_effect=self.compile_fixture):
            result = self.build(root, report)
        self.assertEqual(result['compiled'], 1)
        self.assertEqual(json.loads(report.read_bytes()), result)
        self.batch.direct_library.verify_library(
            root / 'library', self.batch.direct_library.load_descriptor(root / 'graphics.json'))


class RequestImportTest(unittest.TestCase):
    """Original synthetic transport fixtures, not executable shader goldens."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.capture = self.base / 'dump'
        self.capture.mkdir()
        self.out = self.base / 'imported'
        sys.path.insert(0, str(REPO / 'android/tools'))
        sys.path.insert(0, str(REPO / 'android/tests'))
        import direct_batch
        from direct_library_test import make_request
        self.batch = direct_batch
        self.request = make_request()

    def write_request(self, identity='a' * 64, request=None, prefix=None):
        doc = request or self.request
        name = (prefix or doc['requestId']) + '-' + identity + '.compile-request.json'
        path = self.capture / name
        path.write_text(json.dumps(doc), encoding='utf-8')
        return path

    def test_roundtrip_preserves_named_identity_and_bytes(self):
        source = self.write_request()
        self.batch.import_requests(self.capture, self.out)
        manifest = self.batch.load_programs(self.out / 'programs.v1.json')
        self.assertEqual(manifest['entries'][0]['identity'], 'a' * 64)
        self.assertNotEqual(hashlib.sha256(source.read_bytes()).hexdigest(), 'a' * 64)
        self.assertEqual(manifest['entries'][0]['request'].read_bytes(), source.read_bytes())
        other = self.base / 'again'
        self.batch.import_requests(self.capture, other)
        self.assertEqual((self.out / 'programs.v1.json').read_bytes(),
                         (other / 'programs.v1.json').read_bytes())

    def test_mixed_profile_closure_abi_parser_rejected(self):
        self.write_request()
        for field in ('profileHash', 'translatorClosure', 'directABI', 'sourceParserVersion'):
            with self.subTest(field=field):
                doc = json.loads(json.dumps(self.request))
                value = ('sha256-' if field == 'profileHash' else 's2a-dc1-') + 'b' * 64
                if field in ('directABI', 'sourceParserVersion'): value = 2
                if field != 'profileHash': doc[field] = value
                if field != 'sourceParserVersion': doc['profile'][field] = value
                second = self.write_request('b' * 64, doc)
                with self.assertRaises((self.batch.BatchError, self.batch.direct_library.LibraryError)):
                    self.batch.import_requests(self.capture, self.out)
                self.assertFalse(self.out.exists())
                second.unlink()

    def test_malformed_names_and_wrong_request_id_rejected(self):
        for name in ('bad.compile-request.json', 'x-' + 'g' * 64 + '.compile-request.json',
                     'wrong-' + 'a' * 64 + '.compile-request.json'):
            with self.subTest(name=name):
                path = self.capture / name
                path.write_text(json.dumps(self.request))
                with self.assertRaises(self.batch.BatchError):
                    self.batch.import_requests(self.capture, self.out)
                self.assertFalse(self.out.exists())
                path.unlink()

    def test_duplicate_identity_rejected(self):
        self.write_request()
        doc = json.loads(json.dumps(self.request)); doc['requestId'] = 'different'
        self.write_request(request=doc)
        with self.assertRaisesRegex(self.batch.BatchError, 'duplicate identity'):
            self.batch.import_requests(self.capture, self.out)
        self.assertFalse(self.out.exists())

    def test_bad_json_and_symlink_rejected(self):
        path = self.write_request(); path.write_text('{')
        with self.assertRaises(self.batch.direct_library.LibraryError):
            self.batch.import_requests(self.capture, self.out)
        path.unlink(); path.symlink_to(self.base / 'outside')
        with self.assertRaises(self.batch.BatchError):
            self.batch.import_requests(self.capture, self.out)
        self.assertFalse(self.out.exists())

    def test_write_failure_removes_only_new_output(self):
        source = self.write_request()
        original = source.read_bytes()
        open_path = Path.open
        def fail_manifest(path, *args, **kwargs):
            if path.name == 'programs.v1.json': raise OSError('synthetic write failure')
            return open_path(path, *args, **kwargs)
        with mock.patch.object(Path, 'open', fail_manifest):
            with self.assertRaisesRegex(OSError, 'synthetic write failure'):
                self.batch.import_requests(self.capture, self.out)
        self.assertFalse(self.out.exists())
        self.assertEqual(source.read_bytes(), original)

    def test_replaced_fifo_rejected_without_blocking(self):
        if not hasattr(os, 'mkfifo') or not hasattr(os, 'O_NONBLOCK'):
            self.skipTest('FIFO race requires POSIX nonblocking open')
        source = self.write_request()
        open_fd = os.open
        def swap_to_fifo(path, flags):
            # Check the safety property before entering a potentially blocking syscall.
            self.assertTrue(flags & os.O_NONBLOCK)
            source.unlink(); os.mkfifo(source)
            return open_fd(path, flags)
        with mock.patch.object(self.batch.os, 'open', swap_to_fifo):
            with self.assertRaisesRegex(self.batch.BatchError, 'type/size'):
                self.batch.import_requests(self.capture, self.out)
        self.assertFalse(self.out.exists())

    def test_empty_capture_and_existing_output_rejected(self):
        with self.assertRaises(self.batch.BatchError):
            self.batch.import_requests(self.capture, self.out)
        self.write_request(); self.out.mkdir(); marker = self.out / 'keep'
        marker.write_text('unchanged')
        with self.assertRaises(self.batch.BatchError):
            self.batch.import_requests(self.capture, self.out)
        self.assertEqual(marker.read_text(), 'unchanged')


class CaptureIdentityTest(unittest.TestCase):
    """W2.3：出包生产者只认编译器构建身份，不接受来自别处的 closure。"""

    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix='s2a-direct-capture-'))

    def tearDown(self):
        shutil.rmtree(self.base, ignore_errors=True)

    def _identity(self, closure):
        path = self.base / f'identity-{closure[-8:]}.json'
        path.write_text(json.dumps({'schema': 's2a-direct-identity-v1', 'rule': 'x',
                                    'translatorClosure': closure, 'sourcesDigest': 'sha256-' + '0' * 64}),
                        encoding='utf-8')
        return path

    @unittest.skipUnless(shutil.which('dotnet'), 'dotnet is not installed')
    def test_capture_must_match_compiler_identity(self):
        sys.path.insert(0, str(REPO / 'android/tools'))
        import direct_library

        tests, cli, identity = built_tools()
        requests = self.base / 'requests'
        checked(['dotnet', str(tests), '--emit-requests', str(requests)])
        closure = identity['translatorClosure']

        compiled = self.base / 'compiled'
        proc = run(['dotnet', str(cli), 'compile',
                    '--request', str(requests / 'graphics.json'), '--output', str(compiled)], cwd=str(REPO))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        profile_hash = json.loads((requests / 'graphics.json').read_bytes())['profile']['profileHash']

        capture = self.base / 'capture'
        (capture / 'requests').mkdir(parents=True)
        (capture / 'results').mkdir(parents=True)
        shutil.copyfile(requests / 'graphics.json', capture / 'requests/0000.json')
        shutil.copyfile(compiled / 'program.json', capture / 'results/0000.json')
        (capture / 'capture.v1.json').write_text(json.dumps({
            'schema': direct_library.CAPTURE_SCHEMA, 'directABI': 1,
            'translatorClosure': closure, 'sourceParserVersion': 1, 'profileHash': profile_hash,
            'entries': [{'identity': hashlib.sha256((requests / 'graphics.json').read_bytes()).hexdigest(),
                         'request': 'requests/0000.json', 'result': 'results/0000.json'}]}), encoding='utf-8')
        good = self._identity(closure)
        foreign = self._identity('s2a-dc1-' + '0' * 64)

        out = self.base / 'lib-good'
        direct_library.build(str(capture), str(out), str(self.base / 'g-good.json'), TITLE_ID,
                             game_content_root=CONTENT_ROOT, module_set_digest=MODULE_DIGEST,
                             identity=str(good))
        self.assertTrue((self.base / 'g-good.json').is_file())

        with self.assertRaises(direct_library.LibraryError) as caught:
            direct_library.build(str(capture), str(self.base / 'lib-bad'), str(self.base / 'g-bad.json'),
                                 TITLE_ID, game_content_root=CONTENT_ROOT,
                                 module_set_digest=MODULE_DIGEST, identity=str(foreign))
        self.assertIn('not this compiler build', str(caught.exception))
        self.assertFalse((self.base / 'lib-bad').exists())


if __name__ == '__main__':
    unittest.main()
