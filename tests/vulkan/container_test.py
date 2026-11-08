#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Routing/exit-code contracts using explicit fake Docker; not container execution."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class Routing(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='vulkan-routing-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'repo with spaces'
        for name in ('tests/vulkan',):
            shutil.copytree(ROOT / name, self.root / name)
        for name in ('tests/shader_cases_test.sh', 'android/tests/vk/run.sh'):
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, p)
        self.bin = Path(self.tmp.name) / 'bin'
        self.bin.mkdir()
        self.log = Path(self.tmp.name) / 'calls.jsonl'
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        FAKE_LOG=str(self.log), FAKE_OS='Darwin',
                        S2A_VULKAN_CACHE=str(Path(self.tmp.name) / 'cache'))
        self.script('uname', '#!/bin/sh\nprintf "%s\\n" "$FAKE_OS"\n')
        h = hashlib.sha256()
        for name in ('Dockerfile', 'entrypoint.sh', 'result.sh'):
            h.update(name.encode() + b'\0' + (self.root / 'tests/vulkan' / name).read_bytes() + b'\0')
        self.env['FAKE_LABEL'] = h.hexdigest()
        self.env['FAKE_IMAGE'] = 'sha256:' + 'a' * 64
        self.git_init(self.root)

    def git_init(self, root):
        subprocess.run(['git','init','-q',str(root)],check=True)
        subprocess.run(['git','-C',str(root),'-c','user.name=fixture',
                        '-c','user.email=fixture@example.invalid','commit',
                        '--allow-empty','-qm','synthetic source identity'],check=True)

    def script(self, name, text):
        p = self.bin / name
        p.write_text(text)
        p.chmod(0o755)

    def docker(self):
        self.script('docker', '''#!/usr/bin/python3
import json, os, sys
args=sys.argv[1:]
with open(os.environ['FAKE_LOG'],'a') as f: f.write(json.dumps(args)+'\\n')
if args[:2]==['--context','colima']: args=args[2:]
if args==['info']: sys.exit(int(os.getenv('FAKE_INFO_RC','0')))
if args[:2]==['image','inspect']:
    if os.getenv('FAKE_NO_IMAGE'): sys.exit(1)
    print(os.environ['FAKE_LABEL'] if 'Labels' in args[3] else os.environ['FAKE_IMAGE'])
    sys.exit(0)
if args[0]=='build': sys.exit(0)
if args[0]=='run': sys.exit(int(os.getenv('FAKE_RUN_RC','0')))
sys.exit(99)
''')

    def run_entry(self, path='tests/shader_cases_test.sh', *args):
        return subprocess.run(['/bin/bash', str(self.root / path), *args], env=self.env,
                              capture_output=True, text=True)   # 不设每例墙钟（11-05 不稳定项 #12）：宿主原生跑每例 <1 秒，挂死交门禁步预算

    def calls(self):
        return [json.loads(s) for s in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_dockerfile_pins_amd64_manifest_selection(self):
        lines = (self.root / 'tests/vulkan/Dockerfile').read_text().splitlines()
        source = next(line for line in lines if line.startswith('FROM '))
        self.assertTrue(source.startswith('FROM --platform=linux/amd64 '), source)
        self.assertIn('@sha256:de4fe90a98845d75910b9769662465c84de1a934665c431279d1382b2bddc02b', source)

    def test_prepare_explicitly_builds_amd64(self):
        self.docker()
        p = self.run_entry('tests/vulkan/prepare.sh')
        self.assertEqual(0, p.returncode, p.stderr)
        build = next(args for args in self.calls() if 'build' in args)
        self.assertEqual('linux/amd64', build[build.index('--platform') + 1])
        self.assertFalse(any('run' in args or 'pull' in args for args in self.calls()))

    def test_missing_engine_is_75(self):
        # This test's isolated PATH has no docker, even if the real host has one.
        for name, target in [('bash','/bin/bash'),('dirname',shutil.which('dirname')),('python3',sys.executable)]:
            (self.bin / name).symlink_to(target)
        self.env['PATH'] = str(self.bin)
        p = self.run_entry()
        self.assertEqual(75, p.returncode, p.stderr)
        self.assertIn('环境未就绪', p.stderr)

    def test_stopped_engine_is_75_without_start(self):
        self.docker(); self.env['FAKE_INFO_RC'] = '1'
        self.assertEqual(75, self.run_entry().returncode)
        self.assertEqual([['--context', 'colima', 'info']], self.calls())

    def test_missing_image_is_75_without_pull_or_build(self):
        self.docker(); self.env['FAKE_NO_IMAGE'] = '1'
        self.assertEqual(75, self.run_entry().returncode)
        self.assertFalse(any('run' in a or 'pull' in a or 'build' in a for a in self.calls()))

    def test_wrong_image_identity_is_75(self):
        self.docker(); self.env['FAKE_LABEL'] = 'wrong'
        self.assertEqual(75, self.run_entry().returncode)
        self.assertFalse(any('run' in a for a in self.calls()))

    def test_shader_entry_uses_inspected_id_and_offline_mount(self):
        self.docker()
        self.assertEqual(0, self.run_entry().returncode)
        args = self.calls()[-1]
        self.assertEqual('linux/amd64', args[args.index('--platform') + 1])
        self.assertIn('--network=none', args)
        self.assertIn('--pull=never', args)
        self.assertIn('type=bind,source=' + str(self.root) + ',target=/src', args)
        self.assertEqual([self.env['FAKE_IMAGE'], 'tests/shader_cases_test.sh'], args[-2:])
        self.assertNotIn('--privileged', args)

    def test_linked_worktree_head_without_external_git_mount(self):
        self.docker()
        linked = Path(self.tmp.name) / 'linked worktree'
        subprocess.run(['git','-C',str(self.root),'worktree','add','--detach',str(linked)],
                       check=True, capture_output=True)
        for name in ('tests','platforms'):
            shutil.copytree(self.root / name, linked / name)
        self.root = linked
        self.assertTrue((linked / '.git').is_file())
        head = subprocess.check_output(['git','-C',str(linked),'rev-parse','HEAD'],text=True).strip()
        p = self.run_entry()
        self.assertEqual(0,p.returncode,p.stderr)
        args = self.calls()[-1]
        self.assertIn('S2A_TEST_SOURCE_HEAD='+head,args)
        mounts = [args[i + 1] for i, a in enumerate(args) if a == '--mount']
        self.assertEqual(['type=bind,source=' + str(linked) + ',target=/src',
                          'type=bind,source=' + str(Path(self.tmp.name) / 'cache') + ',target=/cache'], mounts)

    def test_android_entry_shares_image_and_arguments(self):
        self.docker()
        self.assertEqual(0, self.run_entry('android/tests/vk/run.sh', '--asan').returncode)
        self.assertEqual([self.env['FAKE_IMAGE'], 'android/tests/vk/run.sh', '--asan'], self.calls()[-1][-3:])
        self.assertEqual('linux/amd64', self.calls()[-1][self.calls()[-1].index('--platform') + 1])

    def test_test_failure_is_not_environment_skip(self):
        self.docker(); self.env['FAKE_RUN_RC'] = '1'
        self.assertEqual(1, self.run_entry().returncode)

    def test_container_launch_failure_is_75(self):
        self.docker(); self.env['FAKE_RUN_RC'] = '125'
        self.assertEqual(75, self.run_entry().returncode)

    def test_real_child_exit_and_validation_contract(self):
        log = Path(self.tmp.name) / 'test.log'
        helper = self.root / 'tests/vulkan/result.sh'
        for rc, expected in [(0,0),(1,1),(2,2),(75,75),(125,1),(126,1),(127,1)]:
            log.write_text('ordinary test output\n')
            with self.subTest(rc=rc):
                p = subprocess.run(['/bin/bash','-c','source "$1"; s2a_vulkan_result "$2" "$3"',
                                    '_',str(helper),str(rc),str(log)],capture_output=True,text=True)
                self.assertEqual(expected,p.returncode,p.stderr)
        for text in ('Validation Error: synthetic contract', 'VUID-synthetic-contract'):
            log.write_text(text)
            p = subprocess.run(['/bin/bash','-c','source "$1"; s2a_vulkan_result 0 "$2"',
                                '_',str(helper),str(log)],capture_output=True,text=True)
            self.assertEqual(1,p.returncode,p.stderr)

    def test_linux_does_not_invoke_docker(self):
        self.docker(); self.env['FAKE_OS'] = 'Linux'
        self.script('python3', '#!/bin/sh\nexit 42\n')
        self.assertEqual(42, self.run_entry().returncode)
        self.assertEqual([], self.calls())


if __name__ == '__main__':
    unittest.main()
