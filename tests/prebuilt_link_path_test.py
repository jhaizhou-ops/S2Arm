# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""预编库返回值直接进 make 链接参数，必须保持单个路径且不改变校验。"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "services/prebuilt_lib.sh"


class PrebuiltLinkPath(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", HOME=str(self.root), TMPDIR=str(self.root))

    def fixture(self, parent, name="vpx", rid="ios-arm64"):
        lib = parent / "libs" / name / rid / f"libs2a_{name}.a"
        lib.parent.mkdir(parents=True)
        lib.write_bytes(b"synthetic archive\x00")
        (lib.parent / "build.txt").write_text("key=fixture\nlib_sha256=" + hashlib.sha256(lib.read_bytes()).hexdigest() + "\n")
        return lib

    def run_helper(self, parent, name="vpx", rid="ios-arm64", key="fixture"):
        return subprocess.run(["/bin/bash", "-c", 'source "$1"; s2a_prebuilt_lib "$2" "$3" "$4" "$5"',
                               "test", str(HELPER), name, rid, key, f"libs2a_{name}.a"],
                              cwd=self.root, env=dict(self.env, S2A_PREBUILT_TOOLS=str(parent)), capture_output=True, text=True)

    def assert_make_argument(self, path, lib):
        probe = self.root / "probe.py"
        probe.write_text("import sys,json; print(json.dumps(sys.argv[1:]))\n")
        makefile = self.root / "Makefile"
        makefile.write_text(f"LIB := {path}\nall:\n\t@{sys.executable} {probe} $(LIB)\n")
        result = subprocess.run(["/usr/bin/make", "-s", "-f", str(makefile)], env=self.env, text=True, capture_output=True, check=True)
        args = json.loads(result.stdout)
        self.assertEqual(len(args), 1, "make 将预编库路径拆成多个参数")
        self.assertEqual(Path(args[0]).resolve(), lib.resolve())
        self.assertEqual(Path(args[0]).read_bytes(), b"synthetic archive\x00")

    def test_space_path_four_library_platform_pairs(self):
        for name in ("vpx", "dav1d"):
            for rid in ("ios-arm64", "osx-arm64"):
                with self.subTest(name=name, rid=rid):
                    parent = self.root / "Application Support/中文引擎/Prepare"
                    lib = self.fixture(parent, name, rid)
                    result = self.run_helper(parent, name, rid)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assert_make_argument(result.stdout.strip(), lib)

    def test_no_space_path_unchanged(self):
        parent = self.root / "Prepare"
        lib = self.fixture(parent)
        result = self.run_helper(parent)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(lib))
        self.assert_make_argument(result.stdout.strip(), lib)

    def test_relative_space_path_is_resolved_before_aliasing(self):
        parent = self.root / "Application Support/relative"
        lib = self.fixture(parent)
        result = self.run_helper(parent.relative_to(self.root))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_make_argument(result.stdout.strip(), lib)

    def test_integrity_failures_still_stop_without_path(self):
        parent = self.root / "Application Support/Prepare"
        lib = self.fixture(parent)
        wrong_key = self.run_helper(parent, key="wrong")
        self.assertNotEqual(wrong_key.returncode, 0)
        self.assertIn("构建键", wrong_key.stderr)
        self.assertEqual(wrong_key.stdout, "")
        lib.write_bytes(b"corrupt")
        corrupt = self.run_helper(parent)
        self.assertNotEqual(corrupt.returncode, 0)
        self.assertIn("sha256", corrupt.stderr)
        self.assertEqual(corrupt.stdout, "")
        lib.unlink()
        missing = self.run_helper(parent)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("没有", missing.stderr)
        self.assertEqual(missing.stdout, "")
        self.assertFalse((self.root / "s2a-nospace").exists(), "校验失败不得进入路径输出")

    def test_unset_prebuilt_keeps_source_build_contract(self):
        result = subprocess.run(["/bin/bash", "-c", 'source "$1"; s2a_prebuilt_lib vpx ios-arm64 fixture libs2a_vpx.a',
                                 "test", str(HELPER)], env=self.env, capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout), (0, ""))
        self.assertFalse((self.root / "s2a-nospace").exists())


if __name__ == "__main__":
    unittest.main()
