#!/usr/bin/env python3
"""Offline checks for false-pass prevention; these do not stand in for a device run."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import rewrite_android_compare as compare


class ComparisonTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rewrite-android-check-')
        self.addCleanup(self.temp.cleanup)
        self.left = Path(self.temp.name) / 'host'
        self.right = Path(self.temp.name) / 'android'
        self.left.mkdir()
        self.right.mkdir()
        for directory in (self.left, self.right):
            for name, data in {'patched.bin': b'\x01\x02\x03\x04', 'fixups.tsv': b'# fixups\n',
                               'gates.tsv': b'', 'sites.tsv': b'# sites\n', 'gaps.tsv': b'# gaps\n'}.items():
                (directory / f'main.{name}').write_bytes(data)

    def test_all_five_required_files(self):
        result = compare.compare(self.left, self.right)
        self.assertEqual(len(result), 5)
        self.assertEqual(result['main.gates.tsv']['sha256'],
                         'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
        self.assertEqual(result['main.patched.bin']['bytes'], 4)

    def test_changed_byte(self):
        (self.right / 'main.patched.bin').write_bytes(b'\x01\x02\x03\x05')
        with self.assertRaisesRegex(RuntimeError, 'bytes differ'):
            compare.compare(self.left, self.right)

    def test_bytes_checked_even_when_hashes_match(self):
        (self.right / 'main.patched.bin').write_bytes(b'\x01\x02\x03\x05')
        with patch.object(compare, 'sha256', return_value='same'), self.assertRaisesRegex(RuntimeError, 'bytes differ'):
            compare.compare(self.left, self.right)

    def test_missing_file_on_both_sides_is_not_equal_success(self):
        for directory in (self.left, self.right):
            (directory / 'main.gaps.tsv').unlink()
        with self.assertRaisesRegex(RuntimeError, 'missing required'):
            compare.compare(self.left, self.right)

    def test_extra_artifact_is_not_ignored(self):
        (self.right / 'main.extra.tsv').write_bytes(b'extra\n')
        with self.assertRaisesRegex(RuntimeError, 'filename sets differ'):
            compare.compare(self.left, self.right)

    def test_optional_widen_is_compared(self):
        for directory in (self.left, self.right):
            (directory / 'main.widen.tsv').write_bytes(b'# widen\n')
        self.assertEqual(len(compare.compare(self.left, self.right)), 6)
        (self.right / 'main.widen.tsv').write_bytes(b'changed\n')
        with self.assertRaisesRegex(RuntimeError, 'bytes differ'):
            compare.compare(self.left, self.right)

    def test_apple_double_requires_valid_structure_and_matching_file(self):
        sidecar = self.left / '._main.patched.bin'
        sidecar.write_bytes(bytes.fromhex('0005160700020000') + bytes(18))
        self.assertEqual(len(compare.compare(self.left, self.right)), 5)
        sidecar.write_bytes(bytes.fromhex('0005160700020000') + bytes(16) + b'\x00\x01')
        with self.assertRaisesRegex(RuntimeError, 'filename sets differ'):
            compare.compare(self.left, self.right)

    def test_unknown_dot_underscore_file_is_not_ignored(self):
        (self.left / '._main.patched.bin').write_bytes(b'not AppleDouble')
        with self.assertRaisesRegex(RuntimeError, 'filename sets differ'):
            compare.compare(self.left, self.right)

    def test_subdirectory_rejected(self):
        (self.right / 'nested').mkdir()
        with self.assertRaisesRegex(RuntimeError, 'regular files'):
            compare.compare(self.left, self.right)

    def test_device_directory_is_exactly_a_private_mktemp_result(self):
        valid = compare.DEVICE_TEMPLATE.replace('XXXXXXXX', 'Ab12CD34')
        self.assertEqual(compare.device_directory(valid), valid)
        for invalid in (valid + '/out', valid + '/../escape', valid + '; echo bad',
                        valid + '\nextra', '/wrong/' + Path(valid).name):
            with self.subTest(value=invalid), self.assertRaises(RuntimeError):
                compare.device_directory(invalid)

    def test_pfrw_requires_one_success_summary(self):
        good = 'PFRW mod=main need=2 gaps=0 fatal=0\n'
        self.assertEqual(compare.summary(good), {'need': 2, 'gaps': 0, 'fatal': 0})
        for text in ('', good + good, 'PFRW mod=main need=2 gaps=1 fatal=0\n',
                     'PFRW mod=main need=2 gaps=0 fatal=1\n'):
            with self.subTest(log=text), self.assertRaises(RuntimeError):
                compare.summary(text)


if __name__ == '__main__':
    unittest.main()
