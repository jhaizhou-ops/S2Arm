#!/usr/bin/env python3
"""native/jni_abi.py: forms it cannot match to reflection are errors, never a silently different hash."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1] / "native/jni_abi.py"


def run(source):
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp) / "X.java"
        path.write_text(source)
        return subprocess.run([sys.executable, str(TOOL), str(path)], capture_output=True, text=True)


class JniAbi(unittest.TestCase):
    def test_unsupported_forms_fail(self):
        for source in ("final class X { static native java.util.List<String> g(); }",
                       "final class X { static native int h(int a)\n throws Exception; }"):
            with self.subTest(source=source):
                r = run(source)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn("jni_abi.py:", r.stderr)

    def test_modifier_order_varargs_and_literals(self):
        r = run('final class X { native static int a(String... s); private native long b(); '
                'static String t() { return "static native int fake();"; } }')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.splitlines()[:2], ["X.a(String[])int", "X.b()long"])

    def test_c_style_array_matches_reflection(self):
        r = run("final class X { static native int c(int values[], byte[] b[]); }")
        self.assertEqual(r.stdout.splitlines()[0], "X.c(int[],byte[][])int")

    def test_no_declarations_fail(self):
        self.assertNotEqual(run("final class X { }").returncode, 0)


if __name__ == "__main__":
    unittest.main()
