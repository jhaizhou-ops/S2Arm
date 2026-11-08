# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Synthetic unit tests: no translator, GPU, or game assets are used here."""
import hashlib
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("shader_case_coverage", Path(__file__).with_name("coverage.py"))
coverage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(coverage)


class CoverageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.shader = self.root / coverage.SHADER
        self.write("Decoders/InstTable.cs", '''const int EncodingBits = 4;
Add("1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", InstName.Broad, InstEmit.Broad);
Add("1010xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", InstName.Specific, InstEmit.Specific);
Add("1010xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", InstName.Alias, InstEmit.Alias);
''')
        self.write("Translation/Transforms/TransformPasses.cs", "RunPass<TransformA>(context);")
        self.write("Translation/Transforms/TransformA.cs", "class TransformA : ITransformPass { public static void RunPass() {} }")
        self.write("Translation/Optimizations/Optimizer.cs", "Fold.RunPass(operation);")
        self.write("Translation/Optimizations/Fold.cs", "class Fold { public static void RunPass() {} }")
        patches = self.root / "compat/patches"
        patches.mkdir(parents=True)
        (patches / "series").write_text("one.patch\ntwo.patch\n")
        (patches / "one.patch").write_text("diff --git a/src/Ryujinx.Graphics.Shader/a.cs b/src/Ryujinx.Graphics.Shader/a.cs\n--- a/src/Ryujinx.Graphics.Shader/a.cs\n+++ b/src/Ryujinx.Graphics.Shader/a.cs\n@@ -1 +1 @@\n-old\n+new\n")
        (patches / "two.patch").write_text("diff --git a/README b/README\n--- a/README\n+++ b/README\n@@ -1 +1 @@\n-x\n+y\n")
        self.binary = self.root / "case.bin"
        # Schedule encodes another opcode, but must not count. A wins over Broad;
        # Alias is shadowed by first equal-specificity table entry, just as C#.
        self.binary.write_bytes(struct.pack("<QQQ", 0x8000000000000000, 0xA000000000000001, 0xB000000000000000))
        self.manifest = [{"id": "test/a", "stage": "compute", "binary": str(self.binary)}]

    def write(self, name, text):
        path = self.shader / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def event(self, before="Copy r1, 2", after="Copy r1, 3"):
        return {"case": "test/a", "kind": "pass", "name": "Fold", "source": coverage.SHADER + "/Translation/Optimizations/Fold.cs", "before_ir": before, "after_ir": after,
                "before": hashlib.sha256(before.encode()).hexdigest(), "after": hashlib.sha256(after.encode()).hexdigest()}

    def test_denominators_decode_and_changed_ir(self):
        result = coverage.collect_coverage(self.root, self.manifest, [self.event()])
        self.assertEqual(result["instructions"]["total"], 3)
        self.assertEqual(result["instructions"]["covered"], ["Broad", "Specific"])
        self.assertEqual(result["passes"]["total"], 2)
        self.assertEqual(result["passes"]["covered"], ["Fold"])
        self.assertEqual(result["patches"]["total"], 1)
        self.assertEqual(result["patches"]["covered"], [])

    def test_declarations_and_unchanged_ir_do_not_count(self):
        self.manifest[0]["rules"] = ["TransformA", "one.patch"]
        result = coverage.collect_coverage(self.root, self.manifest, [self.event("same", "same")])
        self.assertEqual(result["passes"]["covered"], [])
        self.assertEqual(result["patches"]["covered"], [])

    def test_forged_hash_unknown_case_and_wrong_source_fail(self):
        for key, value in [("after", "0" * 64), ("case", "absent"), ("source", "another.cs")]:
            event = self.event()
            event[key] = value
            with self.subTest(key=key), self.assertRaises(coverage.CoverageError):
                coverage.collect_coverage(self.root, self.manifest, [event])

    def test_graphics_header_and_schedule_are_not_instructions(self):
        self.binary.write_bytes(b"\x80" * 0x50 + struct.pack("<QQ", 0x8000000000000000, 0xA000000000000000))
        self.manifest[0]["stage"] = "vertex"
        result = coverage.collect_coverage(self.root, self.manifest, [])
        self.assertEqual(result["instructions"]["covered"], ["Specific"])

    def test_broken_sources_fail_not_zero_success(self):
        self.write("Decoders/InstTable.cs", 'const int EncodingBits = 4; Add("broken", InstName.X, InstEmit.X);')
        with self.assertRaises(coverage.CoverageError):
            coverage.collect_coverage(self.root, self.manifest, [])

    def test_unknown_opcode_and_partial_word_fail(self):
        for data in [struct.pack("<QQ", 0, 0), b"\0" * 9]:
            self.binary.write_bytes(data)
            with self.assertRaises(coverage.CoverageError):
                coverage.collect_coverage(self.root, self.manifest, [])

    def test_new_unwired_pass_is_not_silently_omitted(self):
        self.write("Translation/Optimizations/NewPass.cs", "class NewPass { public static void RunPass() {} }")
        with self.assertRaises(coverage.CoverageError):
            coverage.collect_coverage(self.root, self.manifest, [])

    def test_schedule_opcode_does_not_inflate_coverage(self):
        self.binary.write_bytes(struct.pack("<QQ", 0x8000000000000000, 0xA000000000000000))
        result = coverage.collect_coverage(self.root, self.manifest, [])
        self.assertEqual(result["instructions"]["covered"], ["Specific"])

    def test_patch_claim_without_attribution_fails(self):
        event = self.event()
        event.update(kind="patch", name="one.patch")
        with self.assertRaises(coverage.CoverageError):
            coverage.collect_coverage(self.root, self.manifest, [event])


if __name__ == "__main__":
    unittest.main()
