"""Shared synthetic identity contract; never read local Switch key files."""
from collections import defaultdict
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import redact

CASES = Path(__file__).parent / 'fixtures' / 'redact_cases.tsv'
CATEGORIES = {'email', 'team', 'bundle', 'udid', 'udid_legacy', 'device_name'}


def load_cases(path=CASES):
    lines = path.read_text(encoding='utf-8').splitlines()
    if not lines or lines[0] != 'category\tinput\texpected':
        raise ValueError('invalid redaction fixture header')
    rows = []
    for number, line in enumerate(lines[1:], 2):
        if not line or line.startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) != 3 or fields[0] not in CATEGORIES:
            raise ValueError(f'invalid redaction fixture line {number}')
        rows.append((number, *fields))
    return rows


class RedactCasesTests(unittest.TestCase):
    def test_shared_cases(self):
        coverage = defaultdict(list)
        with patch.object(redact, 'load_key_values', side_effect=AssertionError('must not read keys')):
            for number, category, original, expected in load_cases():
                with self.subTest(line=number, category=category):
                    self.assertEqual(redact.redact_text(original, key_values=()), expected)
                    self.assertEqual(redact.redact_text(original, key_values=(), preserve_identity=True), expected)
                coverage[category].append(original != expected)
        self.assertEqual(set(coverage), CATEGORIES)
        for category, values in coverage.items():
            with self.subTest(coverage=category):
                self.assertGreaterEqual(len(values), 2)
                self.assertIn(True, values)
                self.assertIn(False, values)

    def test_legacy_context_does_not_cross_lines(self):
        value = '0123456789abcdef0123456789abcdef01234567'
        for newline in ('\n', '\r', '\r\n'):
            original = 'device connected' + newline + 'commit ' + value
            self.assertEqual(redact.redact_identity(original), original)
            original = 'device ' + value + newline + 'commit ' + value
            self.assertEqual(redact.redact_identity(original),
                             'device [DEVICE_ID]' + newline + 'commit ' + value)

    def test_unquoted_secret_keeps_bracket_inside_the_value(self):
        # A literal ']' is not a delimiter in an unquoted secret token.
        for key in ('password', 'token', 'serial'):
            with self.subTest(key=key):
                self.assertEqual(redact.redact_assignments(key + '=ab]PrivateTail'),
                                 key + '=[REDACTED]')
                self.assertEqual(redact.redact_text(key + '=ab]PrivateTail', key_values=()),
                                 key + '=[REDACTED]')

    def test_known_key_values_still_win(self):
        known = 'synth@example.invalid'
        self.assertEqual(redact.redact_text(known, key_values={known}), '[REDACTED]')


if __name__ == '__main__':
    unittest.main()
