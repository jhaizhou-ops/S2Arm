#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Pure runner timeout contracts; never translates or runs shader cases."""
import ast
import contextlib
import io
from pathlib import Path
import re
import subprocess
import sys
import unittest
from unittest.mock import patch
import run

class BudgetTests(unittest.TestCase):
    def test_execution_keeps_short_watchdog(self):
        with patch.object(run.subprocess, 'run') as child:
            run.command(['synthetic-execution'])
        self.assertEqual(55, child.call_args.kwargs['timeout'])
        self.assertTrue(child.call_args.kwargs['check'])

    def test_build_has_explicit_wide_watchdog(self):
        tree = ast.parse(Path(run.__file__).read_text())
        build = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'build')
        calls = [n for n in ast.walk(build) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'command']
        self.assertEqual(1, len(calls))
        timeout = next((k.value for k in calls[0].keywords if k.arg == 'timeout'), None)
        self.assertIsInstance(timeout, ast.Constant)
        self.assertEqual(900, timeout.value)
        with patch.object(run.subprocess, 'run') as child:
            run.command(['dotnet', 'build'], timeout=900)
        self.assertEqual(900, child.call_args.kwargs['timeout'])

    def test_budget_is_visible_to_gate_first_five_lines(self):
        lines = (run.ROOT/'tests/shader_cases_test.sh').read_text().splitlines()[:5]
        budgets = [int(m.group(1)) for line in lines if (m := re.fullmatch(r'# 门禁预算：(\d+)', line))]
        self.assertEqual([1200], budgets)

    def test_slow_success_is_reported_not_failed(self):
        output = io.StringIO()
        with patch.object(run.time, 'monotonic', return_value=980), contextlib.redirect_stdout(output):
            run.report_elapsed(8, 0, 910)
        self.assertIn('elapsed 980.000s', output.getvalue())
        self.assertIn('build 910.000s', output.getvalue())
        self.assertIn('excluding-build 70.000s', output.getvalue())
        main = next(n for n in ast.parse(Path(run.__file__).read_text()).body if isinstance(n, ast.FunctionDef) and n.name=='main')
        self.assertFalse(any(isinstance(n, ast.Compare) and any(isinstance(v, ast.Name) and v.id=='elapsed' for v in ast.walk(n)) for n in ast.walk(main)))

    def test_real_short_timeout_still_kills_stalled_child(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            run.command([sys.executable,'-c','import time; time.sleep(2)'], timeout=0.05)
        run.command([sys.executable,'-c','pass'], timeout=5)

if __name__ == '__main__':
    unittest.main()
