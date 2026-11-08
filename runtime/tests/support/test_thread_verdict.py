# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""The real runner rejects contradictory child streams; no Android execution."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
ROOT=Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location("thread_runner",ROOT/"android/native/runtime/fault/tests/run_thread.py")
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
class Verdict(unittest.TestCase):
    def child(self,body):
        p=subprocess.run([sys.executable,"-c",body],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=5)
        return runner.valid_output(p.returncode,p.stdout,contains="PASS"),p
    def test_pass(self):
        self.assertTrue(self.child('print("PASS 4096")')[0])
    def test_fail_on_stderr_despite_pass_exit_zero(self):
        ok,p=self.child('import sys;print("PASS 4096");print("FAIL deadline",file=sys.stderr)')
        self.assertEqual(p.returncode,0);self.assertFalse(ok)
    def test_fail_on_stdout(self):
        self.assertFalse(self.child('print("FAIL deadline");print("PASS 4096")')[0])
    def test_nonzero_pass(self):
        self.assertFalse(self.child('print("PASS 4096");raise SystemExit(1)')[0])
    def test_missing_pass(self):
        self.assertFalse(self.child('print("checks=4096")')[0])
if __name__=="__main__":unittest.main()
