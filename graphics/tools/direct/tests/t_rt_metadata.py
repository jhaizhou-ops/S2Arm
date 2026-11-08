#!/usr/bin/env python3
"""R3 three-table metadata contract, using independent public synthetic values."""
import copy
import ctypes
import errno
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
TOOL = Path(os.environ.get("RT_METADATA_TOOL", HERE.parent / "rt_metadata.py"))
TID = "0100ABCDEF123456"
VERSION = "1.2.0"
A, B, C = "000000000000000a", "000000000000000b", "000000000000000c"
CHAIN = "012345abcdef"
SENTINEL = b"private_shader_source_do_not_export_89147"
# These expected bytes are hand-written from the public R1 table contract.
TABLES = {
    "rt_keys.tsv": "# 键\t阶段\t链版本（设备上兜底现编过的，rt_collect.py）\n"
                   f"{A}\tvs\t{CHAIN}\n{B}\tps\t{CHAIN}\n",
    "rt_fout.tsv": "# 键\t无符号掩码\t有符号掩码（输出类型变体）\n"
                   f"{B}\t1\t2\n{B}\t80\t0\n",
    "rt_vt.tsv": "# 键（曲面前顶点核）\n" + C + "\n",
}
DOCUMENT = {
    "schema_version": 1,
    "program_id": TID,
    "game_version": VERSION,
    "keys": [{"key": A, "stage": "vs", "chain": CHAIN},
             {"key": B, "stage": "ps", "chain": CHAIN}],
    "fout": [{"key": B, "unsigned": 1, "signed": 2},
             {"key": B, "unsigned": 128, "signed": 0}],
    "vt": [C],
}


class MetadataTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="rt-metadata-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "source with spaces"
        self.source.mkdir()
        for name, data in TABLES.items():
            (self.source / name).write_text(data, encoding="utf-8")
        self.bundle = self.root / (TID + ".rt-metadata.json")
        self.output = self.root / "imported"

    def command(self, mode, *, success=True, **overrides):
        args = {"program-id": TID, "game-version": VERSION}
        if mode == "export":
            args.update(source=self.source, output=self.bundle)
        else:
            args.update(input=self.bundle, output=self.output)
        args.update(overrides)
        cmd = [sys.executable, str(TOOL), mode]
        for name, value in args.items():
            cmd.extend(("--" + name, str(value)))
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=20)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("Traceback", result.stderr)
        return result

    def document(self, data=None):
        self.bundle.write_text(json.dumps(DOCUMENT if data is None else data), encoding="utf-8")

    def assert_tables(self, directory):
        self.assertEqual(sorted(p.name for p in directory.iterdir()), sorted(TABLES))
        for name, data in TABLES.items():
            self.assertEqual((directory / name).read_bytes(), data.encode())

    def module(self):
        sys.path.insert(0, str(HERE.parent))
        self.addCleanup(sys.path.remove, str(HERE.parent))
        spec = importlib.util.spec_from_file_location("rt_metadata_publication_probe", TOOL)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_export_exact_independent_document_and_determinism(self):
        self.command("export", **{"program-id": TID.lower()})
        self.assertEqual(json.loads(self.bundle.read_text()), DOCUMENT)
        other = self.root / "second.json"
        self.command("export", output=other)
        self.assertEqual(self.bundle.read_bytes(), other.read_bytes())

    def test_import_handwritten_document_exact_tables(self):
        self.document()
        self.command("import", **{"program-id": TID.lower()})
        self.assert_tables(self.output)

    def test_roundtrip_matches_local_r1_tables_byte_for_byte(self):
        self.command("export")
        self.command("import")
        self.assert_tables(self.output)
        for name in TABLES:
            self.assertEqual((self.output / name).read_bytes(), (self.source / name).read_bytes())

    def test_only_fixed_metadata_tables_are_read_and_comments_not_copied(self):
        for name in ("shader.metal", "shader.bin", "arbitrary.json", "pso_user.tsv"):
            (self.source / name).write_bytes(SENTINEL)
        # A directory named like a source artifact also must not be opened.
        (self.source / "ignored_b.json").mkdir()
        with (self.source / "rt_keys.tsv").open("a") as f:
            f.write("# " + SENTINEL.decode() + "\n")
        self.command("export")
        self.assertNotIn(SENTINEL, self.bundle.read_bytes())
        self.assertEqual(json.loads(self.bundle.read_text()), DOCUMENT)

    def test_wrong_program_id_or_version_rejected_without_output(self):
        self.document()
        for option in ({"program-id": "0100000000000002"}, {"game-version": "1.2.1"}):
            with self.subTest(option=option):
                self.command("import", success=False, **option)
                self.assertFalse(self.output.exists())

    def test_schema_and_identity_are_strict(self):
        mutations = [("schema_version", True), ("schema_version", 2),
                     ("program_id", "../" + TID), ("program_id", 1),
                     ("game_version", ""), ("game_version", "../1.2.0"),
                     ("game_version", "1\n2"), ("game_version", "x" * 65),
                     ("keys", {}), ("fout", None), ("vt", "not a list")]
        for field, value in mutations:
            with self.subTest(field=field, value=value):
                doc = copy.deepcopy(DOCUMENT); doc[field] = value
                self.document(doc)
                self.command("import", success=False)
                self.assertFalse(self.output.exists())

    def test_unknown_fields_and_missing_fields_rejected(self):
        for location in ("top", "keys", "fout"):
            for add in (True, False):
                with self.subTest(location=location, add=add):
                    doc = copy.deepcopy(DOCUMENT)
                    target = doc if location == "top" else doc[location][0]
                    if add:
                        target["shader_code"] = SENTINEL.decode()
                    else:
                        target.pop(next(iter(target)))
                    self.document(doc)
                    self.command("import", success=False)
                    self.assertFalse(self.output.exists())

    def test_duplicate_json_object_keys_rejected(self):
        raw = json.dumps(DOCUMENT)
        for text in (raw.replace('"schema_version": 1', '"schema_version": 2, "schema_version": 1'),
                     raw.replace('"stage": "vs"', '"stage": "ps", "stage": "vs"')):
            self.bundle.write_text(text)
            self.command("import", success=False)
            self.assertFalse(self.output.exists())

    def test_bad_rows_and_types_rejected(self):
        cases = [("keys", "key", "a" * 15), ("keys", "key", "A" * 16),
                 ("keys", "stage", "pixel"), ("keys", "stage", SENTINEL.decode()),
                 ("keys", "chain", "a" * 13), ("fout", "unsigned", -1),
                 ("fout", "unsigned", 256), ("fout", "signed", True),
                 ("fout", "signed", "2"), ("fout", "signed", 2.0)]
        for table, field, value in cases:
            with self.subTest(table=table, field=field, value=value):
                doc = copy.deepcopy(DOCUMENT); doc[table][0][field] = value
                self.document(doc)
                self.command("import", success=False)
                self.assertFalse(self.output.exists())
        for value in ("z" * 16, {}, None):
            doc = copy.deepcopy(DOCUMENT); doc["vt"] = [value]
            self.document(doc); self.command("import", success=False)

    def test_duplicate_rows_deduplicate_but_key_conflicts_fail(self):
        doc = copy.deepcopy(DOCUMENT)
        for field in ("keys", "fout", "vt"):
            doc[field] += copy.deepcopy(doc[field])
        self.document(doc); self.command("import")
        self.assert_tables(self.output)
        for field, value in (("stage", "ps"), ("chain", "abcdef012345")):
            bad = copy.deepcopy(doc); bad["keys"][-2][field] = value
            self.document(bad)
            dest = self.root / ("conflict-" + field)
            self.command("import", success=False, output=dest)
            self.assertFalse(dest.exists())

    def test_source_rows_reject_extra_columns_bad_masks_and_conflicts(self):
        cases = [("rt_keys.tsv", f"{A}\tvs\t{CHAIN}\textra\n"),
                 ("rt_keys.tsv", f"{A}\tcs\t{CHAIN}\n"),
                 ("rt_fout.tsv", f"{B}\t100\t0\n"),
                 ("rt_fout.tsv", f"{B}\t-1\t0\n"),
                 ("rt_vt.tsv", C + "\tshader_code\n")]
        for name, extra in cases:
            with self.subTest(name=name, extra=extra):
                (self.source / name).write_text(TABLES[name] + extra)
                self.command("export", success=False)
                self.assertFalse(self.bundle.exists())
                (self.source / name).write_text(TABLES[name])

    def test_missing_table_and_symlink_table_rejected(self):
        path = self.source / "rt_keys.tsv"
        path.unlink()
        self.command("export", success=False)
        self.assertFalse(self.bundle.exists())
        external = self.root / "external.tsv"
        external.write_text(TABLES["rt_keys.tsv"])
        path.symlink_to(external)
        self.command("export", success=False)
        self.assertFalse(self.bundle.exists())
        self.assertEqual(external.read_text(), TABLES["rt_keys.tsv"])

    def test_existing_outputs_never_overwritten(self):
        self.bundle.write_bytes(SENTINEL)
        self.command("export", success=False)
        self.assertEqual(self.bundle.read_bytes(), SENTINEL)
        self.document()
        self.output.mkdir()
        self.command("import", success=False)
        self.assertEqual(list(self.output.iterdir()), [])
        keep = self.output / "keep"; keep.write_bytes(SENTINEL)
        self.command("import", success=False)
        self.assertEqual(keep.read_bytes(), SENTINEL)

    def test_output_symlink_and_input_symlink_rejected(self):
        target = self.root / "keep"; target.write_bytes(SENTINEL)
        self.bundle.symlink_to(target)
        self.command("export", success=False)
        self.command("import", success=False)
        self.assertEqual(target.read_bytes(), SENTINEL)
        self.bundle.unlink(); self.document()
        self.output.symlink_to(self.root / "does-not-exist")
        self.command("import", success=False)
        self.assertTrue(self.output.is_symlink())
        self.assertFalse((self.root / "does-not-exist").exists())

    def test_export_inside_source_rejected(self):
        self.command("export", success=False, output=self.source / "new.json")
        self.assertEqual(sorted(p.name for p in self.source.iterdir()), sorted(TABLES))

    def test_malformed_json_oversize_and_row_budget_rejected(self):
        for content in (b"{", b"\xff", b"[" * 1500, b" " * (16 * 1024 * 1024 + 1)):
            with self.subTest(size=len(content)):
                self.bundle.write_bytes(content)
                self.command("import", success=False)
                self.assertFalse(self.output.exists())
        doc = copy.deepcopy(DOCUMENT); doc["vt"] = [C] * 100001
        self.document(doc); self.command("import", success=False)
        self.assertFalse(self.output.exists())

    def test_empty_tables_are_valid_metadata_not_game_validation(self):
        for name in TABLES:
            (self.source / name).write_text("# empty\n")
        self.command("export"); self.command("import")
        self.assertEqual(json.loads(self.bundle.read_text()), {
            "schema_version": 1, "program_id": TID, "game_version": VERSION,
            "keys": [], "fout": [], "vt": [],
        })
        for path in self.output.iterdir():
            self.assertTrue(path.read_text().startswith("#"))
            self.assertEqual(len(path.read_text().splitlines()), 1)

    def test_write_failure_does_not_publish_partial_tables(self):
        self.document()
        module = self.module()
        before = sorted(p.name for p in self.root.iterdir())

        def fail_after_first_table(out, *_args):
            Path(out).mkdir()
            (Path(out) / "rt_keys.tsv").write_text(TABLES["rt_keys.tsv"])
            raise OSError("synthetic write failure after one table")

        with mock.patch.object(module, "write_tables", side_effect=fail_after_first_table):
            with self.assertRaisesRegex(OSError, "synthetic write failure"):
                module.import_metadata(self.bundle, self.output, TID, VERSION)
        self.assertFalse(self.output.exists())
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), before)

    def test_final_path_absent_until_complete_directory_is_published(self):
        self.document()
        module = self.module()
        real_publish = module.publish

        def inspect_then_publish(stage, output):
            self.assertFalse(os.path.lexists(output))
            self.assert_tables(Path(stage))
            real_publish(stage, output)

        with mock.patch.object(module, "publish", side_effect=inspect_then_publish):
            module.import_metadata(self.bundle, self.output, TID, VERSION)
        self.assert_tables(self.output)

    def test_prepublication_failure_leaves_no_output_and_retry_works(self):
        self.document()
        module = self.module()

        def fail_before_publish(stage, output):
            self.assertFalse(os.path.lexists(output))
            self.assert_tables(Path(stage))
            raise OSError("synthetic publish failure")

        with mock.patch.object(module, "publish", side_effect=fail_before_publish):
            with self.assertRaisesRegex(OSError, "synthetic publish failure"):
                module.import_metadata(self.bundle, self.output, TID, VERSION)
        self.assertFalse(os.path.lexists(self.output))
        self.assertEqual(list(self.root.glob(".rt-metadata-*")), [])
        self.command("import")
        self.assert_tables(self.output)

    def test_hard_exit_before_publish_leaves_no_empty_output_and_retry_works(self):
        self.document()
        code = """
import importlib.util, os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location('crash_probe', sys.argv[2])
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
def crash(stage, output):
    assert not os.path.lexists(output)
    assert sorted(p.name for p in Path(stage).iterdir()) == ['rt_fout.tsv', 'rt_keys.tsv', 'rt_vt.tsv']
    os._exit(73)
module.publish = crash
module.import_metadata(sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
"""
        result = subprocess.run([sys.executable, "-c", code, str(HERE.parent), str(TOOL),
                                 str(self.bundle), str(self.output), TID, VERSION],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
        self.assertFalse(os.path.lexists(self.output))
        # SIGKILL/os._exit cannot clean private temporary files; they are not a
        # published output and must not block a normal retry under the same name.
        self.assertEqual(len(list(self.root.glob(".rt-metadata-*"))), 1)
        self.command("import")
        self.assert_tables(self.output)

    def test_concurrent_empty_foreign_target_is_not_replaced(self):
        self.document()
        module = self.module()
        real_publish = module.publish
        original = []

        def create_foreign_target(stage, output):
            Path(output).mkdir()
            original.append(Path(output).stat().st_ino)
            real_publish(stage, output)

        with mock.patch.object(module, "publish", side_effect=create_foreign_target):
            with self.assertRaises(FileExistsError):
                module.import_metadata(self.bundle, self.output, TID, VERSION)
        self.assertEqual(self.output.stat().st_ino, original[0])
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertEqual(list(self.root.glob(".rt-metadata-*")), [])

    def test_publication_unsupported_platform_and_missing_primitive_fail_closed(self):
        module = self.module()
        with mock.patch.object(module.sys, "platform", "unsupported"):
            with self.assertRaisesRegex(ValueError, "不支持"):
                module.publish(self.source, self.output)
        with mock.patch.object(module.ctypes, "CDLL", return_value=object()):
            with self.assertRaisesRegex(ValueError, "本机缺"):
                module.publish(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_darwin_abi_shape_only_not_mac_execution(self):
        module = self.module()
        function = mock.Mock(return_value=0)
        library = mock.Mock(renamex_np=function)
        with mock.patch.object(module.sys, "platform", "darwin"), \
             mock.patch.object(module.ctypes, "CDLL", return_value=library):
            module.publish(self.source, self.output)
        function.assert_called_once_with(os.fsencode(self.source), os.fsencode(self.output), 4)
        self.assertEqual(function.argtypes, [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint])
        self.assertEqual(function.restype, ctypes.c_int)
        self.assertFalse(self.output.exists())  # This is not Darwin execution.

    def test_unsupported_filesystem_has_no_unsafe_fallback(self):
        module = self.module()
        function = mock.Mock(return_value=-1)
        library = mock.Mock(renameat2=function, renamex_np=function)
        with mock.patch.object(module.ctypes, "CDLL", return_value=library), \
             mock.patch.object(module.ctypes, "get_errno", return_value=errno.EOPNOTSUPP), \
             mock.patch.object(module.os, "rename", side_effect=AssertionError("unsafe fallback")):
            with self.assertRaisesRegex(ValueError, "文件系统不支持"):
                module.publish(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_concurrent_import_has_one_publisher_and_complete_tables(self):
        self.document()
        args = [sys.executable, str(TOOL), "import", "--input", str(self.bundle),
                "--output", str(self.output), "--program-id", TID, "--game-version", VERSION]
        children = [subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    for _ in range(2)]
        results = []
        try:
            for process in children:
                output = process.communicate(timeout=20)
                results.append((process.returncode, output))
        finally:
            for process in children:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        self.assertEqual(sorted(code for code, _ in results), [0, 1], results)
        self.assert_tables(self.output)
        self.assertEqual(list(self.root.glob(".rt-metadata-*")), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
