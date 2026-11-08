#!/usr/bin/env python3
"""Offline contract tests; all corpus bytes are authored test placeholders."""
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "graphics/tools/macrogen/regen.sh"

class PrivateCorpus(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "repo"
        self.tool = self.root / "graphics/tools/macrogen"
        self.tool.mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.tool / "regen.sh")
        self.private = Path(self.tmp.name) / "private corpus"
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        # Fake compilation only tests shell routing. Real compiler tests are separate.
        dotnet = self.bin / "dotnet"
        dotnet.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$ARGS"\nwhile [ "$1" != -- ]; do shift; done\nshift\nprintf "original synthetic table\\n" > "$1"\nexit "${COMPILER_RC:-0}"\n')
        dotnet.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin)+":"+os.environ["PATH"],
                        ARGS=str(Path(self.tmp.name)/"args"), S2A_MACRO_CORPUS=str(self.private))
        target = self.root / "compat/tree/src/Ryujinx.Graphics.Gpu/Engine/MME/S2AMacroTable.g.cs"
        target.parent.mkdir(parents=True)
        target.write_text("original synthetic table\n")
        self.target = target

    def run_cmd(self, *args):
        return subprocess.run(["bash", str(self.tool/"regen.sh"), *args],
                              env=self.env, text=True, capture_output=True)

    def corpus(self):
        p=self.private/"authored"
        p.mkdir(parents=True)
        (p/"constant.mme").write_bytes(bytes.fromhex("9101100009000000"))
        return p

    def test_explicit_private_check_routes_space_path(self):
        self.corpus()
        r=self.run_cmd("check")
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertIn(str((self.private/"authored").resolve()),Path(self.env["ARGS"]).read_text().splitlines())
        self.assertIn("1 支",r.stdout)

    def test_unicode_adjacent_variables_are_braced(self):
        # Bash versions differ in which UTF-8 bytes they accept in names.
        self.assertIsNone(re.search(r"\$[A-Za-z_][A-Za-z_0-9]*[^\x00-\x7f]", SCRIPT.read_text()))

    def test_missing_private_visible_skip(self):
        r=self.run_cmd("check")
        self.assertEqual(r.returncode,0)
        self.assertIn("SKIP",r.stdout)
        self.assertFalse(Path(self.env["ARGS"]).exists())

    def test_invalid_command_not_skip(self):
        self.assertEqual(self.run_cmd("typo").returncode,2)

    def test_compile_failure_not_skip(self):
        self.corpus()
        self.env["COMPILER_RC"]="7"
        self.assertEqual(self.run_cmd("check").returncode,2)

    def test_mismatch_red(self):
        self.corpus()
        self.target.write_text("different authored table\n")
        self.assertEqual(self.run_cmd("check").returncode,1)

    def test_import_requires_private(self):
        self.env.pop("S2A_MACRO_CORPUS")
        src=Path(self.tmp.name)/"src";src.mkdir()
        (src/"authored.mme").write_bytes(b"synthetic")
        self.assertEqual(self.run_cmd("import",str(src),"authored").returncode,2)
        self.assertFalse((self.tool/"corpus").exists())

    def test_private_must_outside_repo(self):
        self.env["S2A_MACRO_CORPUS"]=str(self.root/"private")
        self.assertEqual(self.run_cmd("check").returncode,2)

    def test_import_traversal_rejected(self):
        src=Path(self.tmp.name)/"src";src.mkdir()
        (src/"authored.mme").write_bytes(b"synthetic")
        self.assertEqual(self.run_cmd("import",str(src),"../escape").returncode,2)
        self.assertFalse((Path(self.tmp.name)/"escape").exists())

    def test_legacy_default_check_preserved(self):
        self.env.pop("S2A_MACRO_CORPUS")
        p=self.tool/"corpus/authored";p.mkdir(parents=True)
        (p/"authored.mme").write_bytes(b"synthetic")
        r=self.run_cmd("check")
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertIn(str(p.resolve()),Path(self.env["ARGS"]).read_text().splitlines())


    def test_relative_path(self):
        self.corpus()
        self.env["S2A_MACRO_CORPUS"]=os.path.relpath(self.private)
        self.assertEqual(self.run_cmd("check").returncode,0)

    def test_root_symlink_into_repo(self):
        inside=self.root/"secret";inside.mkdir()
        self.private.symlink_to(inside, target_is_directory=True)
        self.assertEqual(self.run_cmd("check").returncode,2)

    def test_group_symlink_into_repo(self):
        self.private.mkdir()
        inside=self.root/"secret";inside.mkdir()
        (inside/"authored.mme").write_bytes(b"synthetic")
        (self.private/"group").symlink_to(inside,target_is_directory=True)
        self.assertEqual(self.run_cmd("check").returncode,2)
        self.assertFalse(Path(self.env["ARGS"]).exists())

    def test_file_symlink_rejected(self):
        group=self.corpus()
        (group/"link.mme").symlink_to(self.target)
        self.assertEqual(self.run_cmd("check").returncode,2)
        self.assertFalse(Path(self.env["ARGS"]).exists())

    def test_missing_write_refuses_empty_table(self):
        before=self.target.read_bytes()
        self.assertEqual(self.run_cmd("write").returncode,2)
        self.assertEqual(self.target.read_bytes(),before)

    def test_existing_file_not_missing_skip(self):
        self.private.write_text("not directory")
        self.assertEqual(self.run_cmd("check").returncode,2)

    def test_import_private_preserves_existing(self):
        group=self.corpus()
        before=(group/"constant.mme").read_bytes()
        src=Path(self.tmp.name)/"src";src.mkdir()
        (src/"constant.mme").write_bytes(b"not overwrite")
        (src/"new.mme").write_bytes(b"new authored placeholder")
        self.assertEqual(self.run_cmd("import",str(src),"authored").returncode,0)
        self.assertEqual((group/"constant.mme").read_bytes(),before)
        self.assertEqual((group/"new.mme").read_bytes(),b"new authored placeholder")
        self.assertFalse((self.tool/"corpus").exists())

    def test_empty_override_rejected(self):
        self.env["S2A_MACRO_CORPUS"]=""
        self.assertEqual(self.run_cmd("check").returncode,2)


    def test_legacy_empty_group_still_checks_table(self):
        self.env.pop("S2A_MACRO_CORPUS")
        p=self.tool/"corpus/empty";p.mkdir(parents=True)
        self.target.write_text("not the generated authored table")
        self.assertEqual(self.run_cmd("check").returncode,1)
        self.assertTrue(Path(self.env["ARGS"]).exists())


    def test_legacy_empty_group_write_refused(self):
        self.env.pop("S2A_MACRO_CORPUS")
        p=self.tool/"corpus/empty";p.mkdir(parents=True)
        before=self.target.read_bytes()
        self.assertEqual(self.run_cmd("write").returncode,2)
        self.assertEqual(self.target.read_bytes(),before)
        self.assertFalse(Path(self.env["ARGS"]).exists())

if __name__=="__main__": unittest.main()
