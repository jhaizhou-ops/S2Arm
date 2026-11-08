#!/bin/bash
# 只测成员 read()；不依赖 index_entries，不读游戏，不联网。
# 门禁覆盖：graphics/tools/shbake/pkz.py
set -eu
cd "$(dirname "$0")/.."
PY=${S2A_PY:-${PY:-$HOME/.s2arm/venv/bin/python3}}
"$PY" -B - <<'PY'
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path('graphics/tools/shbake').resolve()))
import pkz


class ReadTests(unittest.TestCase):
    def test_equal_length_unknown_method_is_rejected(self):
        def no_decoder(*args):
            self.fail('Stored or unsupported members must not invoke a decoder')

        data = b'headabc'
        stored = pkz.Member('x.dat', 'None', 3, 4, 3)
        self.assertEqual(pkz.read(data, stored, no_decoder), b'abc')
        unknown = pkz.Member('x.dat', 'OodleKraken', 3, 4, 3)
        with self.assertRaises(pkz.FormatError):
            pkz.read(data, unknown, no_decoder)


unittest.main()
PY
