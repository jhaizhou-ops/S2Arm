# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""T199: per-job IPA intent, budget and subprocess isolation (no device claims)."""
import contextlib
import json
from pathlib import Path
import os
import sys
import subprocess
import unittest
from unittest.mock import patch

from jobcase import JobCase, ROOT
from core import Context, Failure
import build
import library
import ipa
import milestones
import cache_retention

sys.path.insert(0, str(ROOT))
from pack.contracts.validate import validate, ContractError


class IpaGraphics(JobCase):
    def context(self, suffix, **extra):
        return Context(self.request | dict(taskId='graphics-' + suffix, operation='ipa', gameId='0100000000000000') | extra)

    def test_generic_then_default_are_isolated_and_snapshot_environment(self):
        with patch.dict(os.environ, S2A_DUAL='1'):
            original = dict(os.environ)
            generic = self.context('generic', graphicsMode='generic')
            default = self.context('default')
            self.assertFalse(library.task_direct_on(generic))
            self.assertTrue(library.task_direct_on(default))
            self.assertEqual(generic.env()['S2A_DUAL'], '0')
            self.assertEqual(default.env()['S2A_DUAL'], '1')
            self.assertEqual(dict(os.environ), original)
            with patch.dict(os.environ, S2A_DUAL='0'):
                self.assertTrue(library.task_direct_on(default))
                self.assertEqual(default.env()['S2A_DUAL'], '1')
            generic.emit('heartbeat')
            event = json.loads(generic.events.read_text().splitlines()[-1])
            self.assertEqual(event['requestedGraphicsMode'], 'generic')
            self.assertEqual(json.loads(generic.jobpath.read_text())['requestedGraphicsMode'], 'generic')
            self.assertNotIn('graphicsMode', event)
            self.assertNotIn('requestedGraphicsMode', default.job)
            resumed = Context(json.loads(generic.requestpath.read_text()))
            self.assertEqual(resumed.job['requestedGraphicsMode'], 'generic')
            self.assertEqual(resumed.env()['S2A_DUAL'], '0')
            self.assertEqual(resumed.job['attemptNo'], 2)

    def test_community_graphics_dictionary_keeps_original_contract(self):
        request = self.request | dict(operation='save', graphics={'synthetic': True})
        c = Context(request)
        validate('request', request | dict(contract='s2a.job-request.v1'))
        self.assertNotIn('requestedGraphicsMode', c.job)
        with patch.dict(os.environ, S2A_DUAL='0'):
            self.assertFalse(library.direct_on())
        with patch.dict(os.environ, S2A_DUAL='1'):
            self.assertTrue(library.direct_on())

    def test_versioned_event_keeps_intent_and_actual_result_distinct(self):
        from pack.contracts.protocol import event_fields
        request = self.request | dict(contract='s2a.job-request.v1', targetId='ios',
                                      taskId='versioned-mode', operation='ipa',
                                      gameId='0100000000000000', graphicsMode='generic')
        c = Context(request)
        extra = dict(state='succeeded', result={'graphicsMode': 'direct'})
        c.emit('result', 'synthetic result', **(extra | event_fields(
            'result', 'synthetic result', c.stage, None, extra)))
        for line in c.events.read_text().splitlines():
            event = json.loads(line)
            validate('event', event)
            self.assertEqual(event['requestedGraphicsMode'], 'generic')
        self.assertEqual(event['result']['graphicsMode'], 'direct')
        with self.assertRaises(ContractError):
            validate('event', event | dict(requestedGraphicsMode=None))
        with self.assertRaises(ContractError):
            validate('event', event | dict(result={'graphicsMode': None}))

    def test_default_respects_legacy_explicit_generic_switch(self):
        with patch.dict(os.environ, S2A_DUAL='0'):
            c = self.context('legacy')
        self.assertFalse(library.task_direct_on(c))
        self.assertEqual(c.env()['S2A_DUAL'], '0')

    def test_budget_uses_same_mode_without_changing_process(self):
        game = {'packages': [dict(type='base', version=0, sha256='synthetic', size=10_700_000_000)]}
        with patch.dict(os.environ, S2A_DUAL='1'):
            generic = library.space_budget(self.context('budget-g', graphicsMode='generic'), game)
            default = library.space_budget(self.context('budget-d'), game)
        self.assertEqual(generic['volumes'][0]['needBytes'], 21_400_000_000 + (10 << 30))
        self.assertEqual(default['volumes'][0]['needBytes'] - generic['volumes'][0]['needBytes'], 4_000_000_000)

    def test_invalid_intent_is_rejected_before_task_is_registered(self):
        for value in (None, '', 'direct', 0, False, [], {}):
            with self.subTest(value=value), self.assertRaises(Failure):
                self.context('invalid', graphicsMode=value)
        with self.assertRaises(Failure):
            self.context('rest', graphicsMode='generic', rest=True)
        with self.assertRaises(Failure):
            self.context('build', operation='build', graphicsMode='generic')
        self.assertFalse((self.c.private / 'jobs/graphics-invalid.json').exists())

    def test_worker_plan_target_and_child_env_follow_request_not_process(self):
        gid = '0100000000000000'
        game = dict(id=gid, packages=[])
        seen = []
        # External packaging is synthetic. The worker itself resolves the mode,
        # stages, env and delivered result; this is not an IPA/device test.
        def run(args, log=None, env=None, **kwargs):
            child = subprocess.run([sys.executable, '-c', "import os; print(os.environ.get('S2A_DUAL', '1'))"], env=env, capture_output=True, text=True, check=True)
            seen.append((dict(env), child.stdout.strip()))
            out = Path(args[args.index('--out') + 1])
            artifact = out / 'synthetic.ipa'
            artifact.write_bytes(b'synthetic')
            events = Path(args[args.index('--events') + 1])
            events.write_text(json.dumps(dict(ev='result', ok=True, ipa=str(artifact),
                                             graphics_mode='generic', build_id='fixture')) + '\n')
        with patch.dict(os.environ, S2A_DUAL='1'):
            for suffix, extra, expected_plan, expected_dual in (
                    ('run-g', {'graphicsMode': 'generic'}, 'ipa', '0'),
                    ('run-d-first', {}, 'ipa_dual', '1'),
                    ('run-g-last', {'graphicsMode': 'generic'}, 'ipa', '0'),
                    ('run-d', {}, 'ipa_dual', '1')):
                c = self.context(suffix, **extra)
                budget_game = {'packages': [dict(type='base', version=0, sha256='synthetic', size=10_700_000_000)]}
                need = library.space_budget(c, budget_game)['volumes'][0]['needBytes']
                self.assertEqual(need, 21_400_000_000 + (10 << 30) + (4_000_000_000 if expected_dual == '1' else 0))
                with contextlib.ExitStack() as stack:
                    for obj, name, value in (
                        (c, 'catalog', {'games': [game]}), (c, 'fonts_dir', self.root),
                        (library, 'require_game', None), (library, 'check_pack_space', None),
                        (library, 'prune_build', None),
                        (build, 'ensure_extract', self.root), (build, 'seed_from_sibling', False),
                        (ipa, 'dotnet_sdk', (self.root, self.root / 'dotnet')),
                        (cache_retention, 'trim', dict(accountingComplete=True, evictionErrors=0,
                                                     diskErrors=0, pressureRemaining=False, keepTitles=3, retainedBytes=0, removedEntries=0, freeBytes=100, minFreeBytes=0))):
                        stack.enter_context(patch.object(obj, name, return_value=value))
                    stack.enter_context(patch.object(c, 'run', side_effect=run))
                    plan = stack.enter_context(patch.object(milestones, 'plan', wraps=milestones.plan))
                    target = stack.enter_context(patch.object(ipa, 'resolve_target',
                                return_value={'gpuArch': 'applegpu_g17p', 'os': 26}))
                    stack.enter_context(patch.object(ipa, '_iml_device_hint'))
                    result = ipa.build(c)
                self.assertEqual(plan.call_args.args[2], expected_plan)
                self.assertEqual(target.call_args.kwargs['required'], expected_dual == '0')
                self.assertEqual(seen[-1][1], expected_dual)
                self.assertEqual(seen[-1][0]['S2A_DUAL'], expected_dual)
                if expected_dual == '0':
                    self.assertEqual(seen[-1][0]['S2A_PSO_ARCHS'], 'applegpu_g17p')
                    self.assertEqual(seen[-1][0]['S2A_PSO_OS'], '26')
                else:
                    self.assertNotIn('S2A_PSO_ARCHS', seen[-1][0])
                    self.assertNotIn('S2A_PSO_OS', seen[-1][0])
                # Actual result, even when not equal to default/request intent.
                self.assertEqual(result['graphicsMode'], 'generic')
                self.assertEqual(os.environ['S2A_DUAL'], '1')

    def test_invalid_intent_cli_returns_structured_rejection_without_fake_job(self):
        for operation, graphics in (('ipa', 'direct'), ('ipa', None), ('build', 'generic')):
            with self.subTest(operation=operation, graphicsMode=graphics):
                request = self.request | dict(operation=operation, taskId='invalid-cli', graphicsMode=graphics)
                path = self.root / 'invalid-request.json'
                path.write_text(json.dumps(request))
                path.chmod(0o600)
                result = subprocess.run([sys.executable, '-I', '-B', str(ROOT / 'pack/jobs/main.py'),
                                         '--request', str(path)], capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn('Traceback', result.stderr)
                rejection = json.loads(result.stdout)
                self.assertEqual(set(rejection), {'error', 'code'})
                self.assertEqual(rejection['code'], 'job_failed')
                self.assertIn('graphics', rejection['error'])
                self.assertFalse((self.c.private / 'jobs/invalid-cli.json').exists())
                self.assertFalse((self.c.private / 'jobs/invalid-cli.request.json').exists())

    def test_contract_rejects_invalid_values_and_non_ipa(self):
        request = self.request | dict(contract='s2a.job-request.v1', operation='ipa', gameId='0100000000000000', graphicsMode='generic')
        validate('request', request)
        validate('request', {k: v for k, v in request.items() if k != 'graphicsMode'})
        for value in (None, '', 'direct', 0, False, [], {}):
            with self.subTest(value=value), self.assertRaises(ContractError):
                validate('request', request | dict(graphicsMode=value))
        with self.assertRaises(ContractError):
            validate('request', request | dict(operation='build'))
        with self.assertRaises(ContractError):
            validate('request', request | dict(rest=True))


if __name__ == '__main__':
    unittest.main()
