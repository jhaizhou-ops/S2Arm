#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Public-synthetic QA comparison tests; no game or device inputs."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from direct_library_test import make_request, make_result, identity, CLOSURE, PROFILE, TOOLS

sys.path.insert(0, str(TOOLS))
import direct_qa_compare as qa


class CompareTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.left, self.right = self.root / 'capture', self.root / 'replay'
        self.compiler = self.root / 'compiler.json'
        self.compiler.write_text(json.dumps({'schema': 's2a-direct-identity-v1',
                                            'translatorClosure': CLOSURE}))
        self.seed(self.left)
        self.seed(self.right)

    def seed(self, root):
        root.mkdir()
        entries = []
        for number, kind in enumerate(('graphics', 'compute')):
            request = make_request(kind=kind)
            (root / f'r{number}.json').write_text(json.dumps(request))
            (root / f'p{number}.json').write_bytes(make_result(request))
            entries.append({'identity': identity(str(number)), 'request': f'r{number}.json',
                            'result': f'p{number}.json'})
        self.manifest(root, {'schema': 's2a-direct-capture-v1', 'directABI': 1,
                            'translatorClosure': CLOSURE, 'sourceParserVersion': 1,
                            'profileHash': PROFILE, 'entries': entries})

    def manifest(self, root, doc=None):
        path = root / 'capture.v1.json'
        if doc is None:
            return json.loads(path.read_text())
        path.write_text(json.dumps(doc))

    def run_tool(self):
        return subprocess.run([sys.executable, str(TOOLS / 'direct_qa_compare.py'),
                               '--capture', str(self.left), '--replay', str(self.right),
                               '--compiler-identity', str(self.compiler),
                               '--scope', 'public-synthetic'],
                              capture_output=True, text=True)

    def check_bad(self, code, failed_keys=None):
        result = self.run_tool()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertIn(code, json.dumps(report))
        self.assertEqual(result.stderr, '')
        if failed_keys is not None:
            expected = {hashlib.sha256(bytes.fromhex(key)).hexdigest() for key in failed_keys}
            self.assertEqual(report['failed'], len(expected))
            self.assertEqual({item['keyHash'] for item in report['results']
                              if item['status'] == 'fail'}, expected)
            self.assertEqual(report['errors'], [])
            self.assertTrue(all(item['code'] == code for item in report['results']
                                if item['status'] == 'fail'))
        return report

    def test_equal_and_read_only(self):
        before = {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual((report['passed'], report['failed'], report['keys']), (2, 0, 2))
        self.assertEqual(report['scope'], 'public-synthetic')
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()})
        self.assertNotIn(str(self.root), result.stdout)
        self.assertNotIn('codeSource', result.stdout)

    def test_missing_key(self):
        doc = self.manifest(self.right)
        doc['entries'].pop()
        (self.right / 'r1.json').unlink()
        (self.right / 'p1.json').unlink()
        self.manifest(self.right, doc)
        self.check_bad('KEY_SET')

    def test_duplicate_identity(self):
        doc = self.manifest(self.right)
        doc['entries'][1]['identity'] = doc['entries'][0]['identity']
        self.manifest(self.right, doc)
        self.check_bad('MANIFEST')

    def test_reused_result(self):
        doc = self.manifest(self.right)
        doc['entries'][1]['result'] = doc['entries'][0]['result']
        self.manifest(self.right, doc)
        self.check_bad('MANIFEST')

    def test_profile_cohort(self):
        doc = self.manifest(self.right)
        doc['profileHash'] = 'sha256-' + 'e' * 64
        self.manifest(self.right, doc)
        self.check_bad('COHORT')

    def test_both_manifests_profile_disagrees_with_requests(self):
        for root in (self.left, self.right):
            doc = self.manifest(root)
            doc['profileHash'] = 'sha256-' + 'e' * 64
            self.manifest(root, doc)
        self.check_bad('COHORT', [identity('0'), identity('1')])

    def test_both_manifests_and_compiler_closure_disagree_with_requests(self):
        closure = 'another-valid-closure'
        for root in (self.left, self.right):
            doc = self.manifest(root)
            doc['translatorClosure'] = closure
            self.manifest(root, doc)
        self.compiler.write_text(json.dumps({'schema': 's2a-direct-identity-v1',
                                            'translatorClosure': closure}))
        self.check_bad('COHORT', [identity('0'), identity('1')])

    def test_compiler_closure(self):
        self.compiler.write_text(json.dumps({'schema': 's2a-direct-identity-v1',
                                            'translatorClosure': 'wrong-closure'}))
        self.check_bad('COHORT')

    def test_swapped_results(self):
        a, b = self.right / 'p0.json', self.right / 'p1.json'
        av, bv = a.read_bytes(), b.read_bytes()
        a.write_bytes(bv)
        b.write_bytes(av)
        self.check_bad('RESULT')

    def test_transport(self):
        path = self.right / 'p0.json'
        path.write_bytes(path.read_bytes().replace(b'"session":1', b'"session":2'))
        self.check_bad('TRANSPORT')

    def test_transport_bool(self):
        path = self.right / 'p0.json'
        path.write_bytes(path.read_bytes().replace(b'"session":1', b'"session":true'))
        self.check_bad('TRANSPORT')

    def test_payload_bytes_not_semantic_json(self):
        path = self.right / 'p0.json'
        path.write_bytes(b' ' + path.read_bytes())
        self.check_bad('PAYLOAD')

    def test_request_exact_bytes(self):
        path = self.right / 'r0.json'
        path.write_bytes(path.read_bytes() + b' ')
        self.check_bad('REQUEST_BYTES')

    def test_same_profile_hash_different_profile(self):
        for root in (self.left, self.right):
            path = root / 'r1.json'
            doc = json.loads(path.read_bytes())
            doc['profile']['extraFact'] = True
            path.write_text(json.dumps(doc))
        self.check_bad('PROFILE_CONTENT')

    def test_source_digest(self):
        path = self.right / 'r0.json'
        request = make_request()
        request['program']['stages'][0]['code'] = 'YWJjZA=='
        path.write_text(json.dumps(request))
        # A request change must never be called a payload comparison pass.
        self.check_bad('RESULT')

    def test_bad_payload_digest(self):
        (self.right / 'p0.json').write_bytes(make_result(make_request(), corrupt='content_hash'))
        self.check_bad('RESULT')

    def test_bad_json_redacted(self):
        (self.right / 'r0.json').write_bytes(b'PRIVATE_GAME_BYTES_NOT_FOR_OUTPUT')
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('PRIVATE_GAME', result.stdout + result.stderr)
        self.assertNotIn(str(self.root), result.stdout + result.stderr)

    def test_link_and_fifo(self):
        path = self.right / 'r0.json'
        path.unlink()
        path.symlink_to(self.left / 'r0.json')
        self.check_bad('FILE_SET')
        path.unlink()
        os.mkfifo(path)
        self.check_bad('READ')

    def test_traversal(self):
        doc = self.manifest(self.right)
        doc['entries'][0]['request'] = '../capture/r0.json'
        self.manifest(self.right, doc)
        self.check_bad('MANIFEST')

    def test_duplicate_json_keys(self):
        path = self.right / 'capture.v1.json'
        path.write_bytes(path.read_bytes().replace(b'"directABI": 1', b'"directABI": 1, "directABI": 1'))
        self.check_bad('MANIFEST')

    def test_unlisted_payload(self):
        (self.right / 'unlisted.program.json').write_text('private')
        self.check_bad('FILE_SET')

    def test_same_capture_is_not_replay(self):
        self.right = self.left
        self.check_bad('SAME_INPUT')


    def test_hardlink_across_roots(self):
        # Link the first sorted key: it must not poison the later independent key.
        entries = sorted(self.manifest(self.right)['entries'], key=lambda e: e['identity'])
        first, second = entries
        path = self.right / first['result']
        path.unlink()
        os.link(self.left / first['result'], path)
        report = self.check_bad('SAME_INPUT', [first['identity']])
        self.assertEqual((report['passed'], report['failed'], report['keys']), (1, 1, 2))
        self.assertEqual(report['results'][1], {
            'keyHash': hashlib.sha256(bytes.fromhex(second['identity'])).hexdigest(),
            'status': 'pass'})

    def test_cross_key_hardlink_both_directions(self):
        # Distinct producer identities may contain equal valid bytes. Do not
        # assume mismatched request/result validation will catch cross-key links.
        entries = sorted(self.manifest(self.left)['entries'], key=lambda e: e['identity'])
        first, second = entries
        for source, target in ((self.left, self.right), (self.right, self.left)):
            with self.subTest(source=source.name):
                request = make_request()
                payload = make_result(request)
                for root in (self.left, self.right):
                    for entry in entries:
                        (root / entry['request']).write_text(json.dumps(request))
                        (root / entry['result']).write_bytes(payload)
                path = target / second['result']
                path.unlink()
                os.link(source / first['result'], path)
                report = self.check_bad('SAME_INPUT', [second['identity']])
                self.assertEqual((report['passed'], report['failed']), (1, 1))
                # Unlink before the next direction so fixture writes stay independent.
                path.unlink()
                path.write_bytes(payload)

    def test_hardlinked_manifests(self):
        path = self.right / 'capture.v1.json'
        path.unlink()
        os.link(self.left / 'capture.v1.json', path)
        report = self.check_bad('SAME_INPUT')
        self.assertEqual(report['errors'], ['SAME_INPUT'])
        self.assertEqual(report['results'], [])

    def test_hardlink_within_root(self):
        path = self.right / 'p1.json'
        path.unlink()
        os.link(self.right / 'p0.json', path)
        self.check_bad('READ')

    def test_nested_symlink(self):
        (self.right / 'nested').symlink_to(self.left, target_is_directory=True)
        self.check_bad('FILE_SET')

    def test_inaccessible_inventory(self):
        original = qa.os.walk
        def denied(*args, **kwargs):
            kwargs['onerror'](PermissionError('PRIVATE_PATH'))
            yield from original(*args, **kwargs)
        with patch.object(qa.os, 'walk', denied):
            report = qa.compare(self.left, self.right, self.compiler, 'public-synthetic')
        self.assertEqual(report['errors'], ['FILE_SET'])
        self.assertFalse(report['ok'])

    def test_budget_before_read(self):
        reader = qa.Reader(self.left)
        with patch.object(qa, 'MAX_TOTAL', 1):
            with self.assertRaises(qa.Rejected) as caught:
                reader.read('r0.json', 100000)
        self.assertEqual(caught.exception.code, 'BUDGET')
        self.assertEqual(reader.total, 0)

    def test_file_limit(self):
        reader = qa.Reader(self.left)
        with self.assertRaises(qa.Rejected) as caught:
            reader.read('r0.json', 1)
        self.assertEqual(caught.exception.code, 'READ')

    def test_malformed_compiler_identity(self):
        self.compiler.write_text('PRIVATE_BAD_COMPILER_IDENTITY')
        report = self.check_bad('COMPILER_IDENTITY')
        self.assertNotIn('PRIVATE_BAD', json.dumps(report))

    def test_missing_transport(self):
        path = self.right / 'p0.json'
        path.write_bytes(path.read_bytes().replace(b'"generation":1,', b''))
        self.check_bad('TRANSPORT')

    def test_extra_transport(self):
        path = self.right / 'p0.json'
        path.write_bytes(path.read_bytes().replace(b'"generation":1,', b'"generation":1,"private":1,'))
        self.check_bad('TRANSPORT')

    def test_argument_redaction(self):
        result = subprocess.run([sys.executable, str(TOOLS / 'direct_qa_compare.py'),
                                 '--unknown-PRIVATE', 'PRIVATE_SECRET'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn('PRIVATE', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
