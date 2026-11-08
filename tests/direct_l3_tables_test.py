#!/usr/bin/env python3
"""Synthetic files through the real direct_lib.sh table-collection block.

No shader compiler, game input, GPU, signing, or complete package execution.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "graphics/tools/direct/direct_lib.sh"
L3 = "fps_l3_results.tsv"
EXISTING = (
    "game.tsv", "shader_map.tsv", "shader_facts.tsv", "shader_pairs.tsv",
    "bf_want.tsv", "pso_manifest.tsv", "c1_full.tsv", "cb_extent.tsv",
    "shader_map.tsv.conflicts.tsv",
)
L3_BYTES = b"# original synthetic L3 fixture\r\n0100ABCD00000000\tok\r\n"


def collection_block():
    """Execute the producer's statements, not a second implementation/list."""
    source = SCRIPT.read_text(encoding="utf-8")
    blocks = re.findall(
        r'^for f in game\.tsv [^\n]*; do\n'
        r'  \[ -f "\$W/profile/\$TID/\$f" \] && cp "\$W/profile/\$TID/\$f" "\$OS/\$f"\n'
        r'done$', source, re.MULTILINE,
    )
    if len(blocks) != 1:
        raise AssertionError("expected exactly one production table-collection block")
    return blocks[0]


class DirectL3Tables(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s2a_l3_tables_")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.work = self.root / "work"
        self.profile = self.work / "profile/0100ABCD00000000"
        self.output = self.root / "package/shaders/direct"
        self.profile.mkdir(parents=True)
        self.output.mkdir(parents=True)
        for name in EXISTING:
            (self.profile / name).write_bytes(("# synthetic " + name + "\n").encode())
        (self.profile / "unlisted-control.tsv").write_bytes(b"not a shipped table\n")

    def collect(self, block=None):
        result = subprocess.run(
            ["bash", "-u"], input=collection_block() if block is None else block,
            env=dict(os.environ, W=str(self.work), TID="0100ABCD00000000", OS=str(self.output)),
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_l3_shipped(self):
        target = self.output / L3
        self.assertTrue(target.is_file(), "L3 table missing from shaders/direct")
        self.assertEqual(target.read_bytes(), L3_BYTES)

    def test_supplied_l3_reaches_package_path_byte_for_byte(self):
        (self.profile / L3).write_bytes(L3_BYTES)
        self.collect()
        self.assert_l3_shipped()
        self.assertEqual((self.profile / L3).read_bytes(), L3_BYTES)

    def test_existing_tables_unchanged_and_unlisted_file_excluded(self):
        (self.profile / L3).write_bytes(L3_BYTES)
        self.collect()
        for name in EXISTING:
            with self.subTest(table=name):
                self.assertEqual((self.output / name).read_bytes(), (self.profile / name).read_bytes())
        self.assertFalse((self.output / "unlisted-control.tsv").exists())

    def test_missing_optional_l3_preserves_existing_behavior(self):
        self.collect()
        self.assertFalse((self.output / L3).exists())
        self.assertEqual({p.name for p in self.output.iterdir()}, set(EXISTING))

    def test_removing_l3_from_real_collection_list_is_detected(self):
        block = collection_block()
        self.assertEqual(block.splitlines()[0].split().count(L3), 1)
        # Mutate only a private in-memory copy; leave the production source intact.
        before = SCRIPT.read_bytes()
        missing_l3 = block.replace(" " + L3, "", 1)
        (self.profile / L3).write_bytes(L3_BYTES)
        self.collect(missing_l3)
        with self.assertRaisesRegex(AssertionError, "L3 table missing"):
            self.assert_l3_shipped()
        self.assertEqual(SCRIPT.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
