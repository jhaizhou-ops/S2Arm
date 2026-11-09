# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Real Git histories for the public CI README fast path; no network or SDKs."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('ci_readme_plan', ROOT / 'tools/ci_readme_plan.py')
plan = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(plan)


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'CI fixture')
        self.git('config', 'user.email', 'ci@example.invalid')
        self.git('config', 'core.autocrlf', 'false')
        self.git('config', 'core.filemode', 'true')
        self.git('config', 'core.hooksPath', str(self.repo / 'no-hooks'))
        self.write('README.md', 'English\n')
        self.write('README.zh-CN.md', 'Chinese\n')
        self.write('runtime/example.c', 'int original;\n')
        self.base = self.commit()

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode().strip()

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding='utf-8')

    def commit(self):
        self.git('add', '-A')
        self.git('commit', '-qm', 'synthetic fixture')
        return self.git('rev-parse', 'HEAD')

    def event(self, head, base=None, name='pull_request'):
        base = self.base if base is None else base
        if name == 'pull_request':
            return {'pull_request': {'base': {'sha': base}, 'head': {'sha': head}}}
        return {'before': base, 'after': head}

    def classify(self, head, base=None, name='pull_request'):
        return plan.readme_only(self.repo, name, self.event(head, base, name))

    def test_one_readme_is_lightweight(self):
        self.write('README.md', 'Edited English\n')
        self.assertTrue(self.classify(self.commit()))

    def test_both_readmes_are_lightweight_on_pr_and_push(self):
        self.write('README.md', 'Edited English\n')
        self.write('README.zh-CN.md', 'Edited Chinese\n')
        head = self.commit()
        self.assertTrue(self.classify(head))
        self.assertTrue(self.classify(head, name='push'))

    def test_readme_plus_other_path_is_full(self):
        for path in ('runtime/example.c', '.github/workflows/ci.yml', 'tools/example.py',
                     'docs/note.md', 'skills/example/SKILL.md', 'README.other.md',
                     'nested/README.md', 'unknown file name'):
            with self.subTest(path=path):
                self.git('reset', '--hard', self.base)
                self.write('README.md', 'Edited English\n')
                self.write(path, 'changed\n')
                self.assertFalse(self.classify(self.commit()))

    def test_lowercase_readme_is_not_in_allowlist(self):
        # Two moves also create the intended Git path on case-insensitive hosts.
        self.git('mv', 'README.md', 'temporary-name')
        self.git('mv', 'temporary-name', 'readme.md')
        before = self.commit()
        self.write('readme.md', 'Edited lowercase file\n')
        self.assertFalse(self.classify(self.commit(), base=before))

    def test_readme_delete_is_full(self):
        (self.repo / 'README.md').unlink()
        self.assertFalse(self.classify(self.commit()))

    def test_readme_add_is_full(self):
        (self.repo / 'README.md').unlink()
        without = self.commit()
        self.write('README.md', 'Restored\n')
        self.assertFalse(self.classify(self.commit(), base=without))

    def test_rename_readme_to_code_is_full(self):
        self.git('mv', 'README.md', 'runtime/renamed.c')
        self.assertFalse(self.classify(self.commit()))

    def test_rename_between_allowed_names_is_full(self):
        (self.repo / 'README.zh-CN.md').unlink()
        before = self.commit()
        self.git('mv', 'README.md', 'README.zh-CN.md')
        self.assertFalse(self.classify(self.commit(), base=before))

    def test_executable_readme_is_full(self):
        self.write('README.md', 'Edited English\n')
        self.git('add', 'README.md')
        self.git('update-index', '--chmod=+x', 'README.md')
        self.git('commit', '-qm', 'mode change')
        self.assertFalse(self.classify(self.git('rev-parse', 'HEAD')))

    def test_symlink_readme_is_full(self):
        result = subprocess.run(['git', '-C', str(self.repo), 'hash-object', '-w', '--stdin'],
                                input=b'runtime/example.c', check=True, stdout=subprocess.PIPE)
        oid = result.stdout.decode().strip()
        self.git('update-index', '--cacheinfo', f'120000,{oid},README.md')
        self.git('commit', '-qm', 'symlink fixture')
        self.assertFalse(self.classify(self.git('rev-parse', 'HEAD')))

    def test_removing_executable_mode_is_also_full(self):
        self.git('update-index', '--chmod=+x', 'README.md')
        self.git('commit', '-qm', 'executable baseline')
        before = self.git('rev-parse', 'HEAD')
        self.git('update-index', '--chmod=-x', 'README.md')
        self.git('commit', '-qm', 'regular again')
        self.assertFalse(self.classify(self.git('rev-parse', 'HEAD'), base=before))

    def test_pr_base_advancement_does_not_import_unrelated_code(self):
        self.git('checkout', '-qb', 'topic')
        self.write('README.md', 'Topic edit\n')
        topic = self.commit()
        self.git('checkout', '--detach', self.base)
        self.write('runtime/example.c', 'int changed_on_base;\n')
        advanced_base = self.commit()
        self.assertTrue(self.classify(topic, base=advanced_base))

    def test_push_uses_before_after_without_merge_base(self):
        self.git('checkout', '-qb', 'topic')
        self.write('README.md', 'Topic edit\n')
        topic = self.commit()
        self.git('checkout', '--detach', self.base)
        self.write('runtime/example.c', 'int changed_on_base;\n')
        advanced_base = self.commit()
        self.assertFalse(self.classify(topic, base=advanced_base, name='push'))

    def test_empty_diff_is_full(self):
        self.assertFalse(self.classify(self.base))

    def test_manual_and_unknown_events_are_full(self):
        self.write('README.md', 'Edited English\n')
        event = self.event(self.commit())
        for name in ('workflow_dispatch', 'schedule', '', 'pull_request_target'):
            with self.subTest(event=name):
                self.assertFalse(plan.readme_only(self.repo, name, event))

    def test_missing_or_invalid_event_is_full(self):
        for event in ({}, None, [], {'pull_request': {}}, {'pull_request': {'base': None}}):
            with self.subTest(event=event):
                self.assertFalse(plan.readme_only(self.repo, 'pull_request', event))

    def test_zero_invalid_and_missing_objects_are_full(self):
        self.write('README.md', 'Edited English\n')
        head = self.commit()
        for base in ('0' * 40, 'f' * 40, '--help', 'HEAD', ''):
            with self.subTest(base=base):
                self.assertFalse(self.classify(head, base=base))

    def test_git_failure_and_timeout_are_full(self):
        for error in (OSError('synthetic error'), subprocess.TimeoutExpired('git', 10),
                      subprocess.CalledProcessError(1, 'git')):
            with self.subTest(error=type(error).__name__), \
                    mock.patch.object(plan, 'git', side_effect=error):
                self.assertFalse(self.classify(self.base))

    def test_cli_reads_event_and_writes_exact_output(self):
        self.write('README.md', 'Edited English\n')
        event_path = self.repo / 'event.json'
        event_path.write_text(json.dumps(self.event(self.commit())), encoding='utf-8')
        output_path = self.repo / 'output'
        env = {**os.environ, 'GITHUB_EVENT_NAME': 'pull_request',
               'GITHUB_EVENT_PATH': str(event_path), 'GITHUB_OUTPUT': str(output_path)}
        result = subprocess.run([sys.executable, str(ROOT / 'tools/ci_readme_plan.py')],
                                cwd=self.repo, env=env, capture_output=True, check=True)
        self.assertEqual(output_path.read_text(encoding='utf-8'), 'readme_only=true\n')
        self.assertIn(b'README', result.stdout)

    def test_cli_missing_event_file_falls_back_to_full(self):
        output_path = self.repo / 'output'
        env = {**os.environ, 'GITHUB_EVENT_NAME': 'pull_request',
               'GITHUB_EVENT_PATH': str(self.repo / 'missing.json'),
               'GITHUB_OUTPUT': str(output_path)}
        subprocess.run([sys.executable, str(ROOT / 'tools/ci_readme_plan.py')],
                       cwd=self.repo, env=env, capture_output=True, check=True)
        self.assertEqual(output_path.read_text(encoding='utf-8'), 'readme_only=false\n')


if __name__ == '__main__':
    unittest.main(verbosity=2)
