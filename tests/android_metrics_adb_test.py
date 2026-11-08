#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Synthetic producer contract and atomic export checks; ADB CLI checks live in cli_test.py."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "android"))
import collect_run
from metrics_contract import runtime_files

ACTIVE = "metrics-9-42-" + "a" * 32
HEADER = "frame\twall_us\talloc_b\tgc0\tgc1\tgc2\tgc_pause_us\tboot_us\n"
FRAMES = HEADER + "0\t0\t0\t0\t0\t0\t0\t200\n1\t100\t12\t1\t0\t0\t3\t300\n"


class ContractTests(unittest.TestCase):
    def capture(self, root):
        source = root / "source"
        source.mkdir()
        (source / "frames.tsv").write_text(FRAMES, encoding="utf-8")
        (source / "host.log").write_bytes((f"[Android metrics] id={ACTIVE}; clock=CLOCK_BOOTTIME\r\n"
                                         "S2A 标记 MARK：帧 1\r\n原始日志\r\n").encode())
        metadata = {"id": ACTIVE, "status": "completed", "clock": "CLOCK_BOOTTIME", "frameSource": "guest-present",
                    "frames": 2, "startBootUs": 100, "lastFrameBootUs": 300, "endBootUs": 1300,
                    "markFrame": 1, "markBootUs": 300, "error": None}
        (source / "runtime-metrics.json").write_text(json.dumps(metadata), encoding="utf-8")
        return source, metadata

    def files(self, source):
        return {name: source / name for name in ("host.log", "frames.tsv", "runtime-metrics.json")}

    def test_raw_bytes_and_real_stop_clock_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source, meta = self.capture(root)
            files = self.files(source)
            for name, data in {"runtime-library.json": json.dumps({"pid": 42, "runtimeLibrary": {"kind": "apk"}}),
                               "run-manifest.json": '{"producer": "synthetic"}',
                               "battery.tsv": "raw\r\n", "battery-source.json": '{"scope":"battery"}'}.items():
                (source / name).write_bytes(data.encode()); files[name] = source / name
            collect_run.collect(root / "run", files)
            runtime_files(root / "run", root / "run/host.log")
            self.assertEqual(set(p.name for p in (root / "run").iterdir()), set(files))
            for name, original in files.items():
                self.assertEqual((root / "run" / name).read_bytes(), original.read_bytes())
            self.assertGreater(meta["endBootUs"], meta["lastFrameBootUs"])

    def test_bad_rows_never_publish_or_leave_staging(self):
        corruptions = ["0\n", FRAMES.replace("\t100\t12", "\t²\t12"),
                       FRAMES.replace("\t100\t12", "\t-1\t12"), FRAMES.replace("1\t100", "2\t100"),
                       FRAMES.replace("1\t100", "1\t101"), FRAMES.replace("0\t0\t0", "0\t1\t0", 1),
                       FRAMES.replace("gc0\tgc1", "gc0\tgc0"), FRAMES + "2\t100\n",
                       FRAMES.replace("12", ""), FRAMES + "\textra\n"]
        for data in corruptions:
            with self.subTest(data=data), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); source, _ = self.capture(root)
                (source / "frames.tsv").write_text(data, encoding="utf-8")
                with self.assertRaises(ValueError): collect_run.collect(root / "run", self.files(source))
                self.assertEqual({p.name for p in root.iterdir()}, {"source"})

    def test_metadata_shape_type_and_bounds_are_checked(self):
        changes = [{"id": None}, {"status": "capturing"}, {"clock": "MONOTONIC"}, {"frameSource": "synthetic"},
                   {"frames": True}, {"frames": 1}, {"startBootUs": 201}, {"startBootUs": -1},
                   {"lastFrameBootUs": 301}, {"endBootUs": 299}, {"endBootUs": "1300"},
                   {"markFrame": -2}, {"markFrame": 2}, {"markBootUs": 301}, {"error": "write failed"}]
        for change in changes:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); source, meta = self.capture(root)
                meta.update(change); (source / "runtime-metrics.json").write_text(json.dumps(meta))
                with self.assertRaises(ValueError): runtime_files(source, source / "host.log")
        for value in ([], None, 1):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as tmp:
                source, _ = self.capture(Path(tmp))
                (source / "runtime-metrics.json").write_text(json.dumps(value))
                with self.assertRaises(ValueError): runtime_files(source, source / "host.log")

    def test_host_identity_and_mark_are_not_guessed(self):
        for change in (lambda s: s.replace(ACTIVE, "metrics-9-43-" + "b" * 32),
                       lambda s: s + f"[Android metrics] id={ACTIVE};\n",
                       lambda s: s + "S2A 标记 MARK：帧 1\n",
                       lambda s: s.replace("MARK：帧 1", "MARK：帧 0")):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                source, _ = self.capture(Path(tmp)); host = source / "host.log"
                host.write_text(change(host.read_text()))
                with self.assertRaises(ValueError): runtime_files(source, host)

    def test_completed_capture_without_mark_is_valid_but_not_a_power_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, meta = self.capture(Path(tmp))
            meta.update(markFrame=-1, markBootUs=-1)
            (source / "runtime-metrics.json").write_text(json.dumps(meta))
            (source / "host.log").write_text(f"[Android metrics] id={ACTIVE};\n")
            runtime_files(source, source / "host.log")

    def test_runtime_pid_and_development_marker_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source, _ = self.capture(root)
            library = source / "runtime-library.json"
            library.write_text(json.dumps({"pid": 42, "runtimeLibrary": {"kind": "dev-override"}}))
            with self.assertRaises(ValueError): runtime_files(source, source / "host.log")
            marker = source / "NOT-A-READING.txt"; marker.write_text("不作读数\n")
            files = {**self.files(source), library.name: library, marker.name: marker}
            collect_run.collect(root / "dev", files)
            self.assertEqual((root / "dev" / marker.name).read_bytes(), marker.read_bytes())
            library.write_text(json.dumps({"pid": 43, "runtimeLibrary": {"kind": "apk"}}))
            with self.assertRaises(ValueError): collect_run.collect(root / "wrong-pid", files)
            self.assertFalse((root / "wrong-pid").exists())

    def test_copy_failure_cleans_staging_without_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source, _ = self.capture(root)
            copy = collect_run.shutil.copyfile
            def fail_later(src, dest):
                if Path(src).name == "runtime-metrics.json": raise OSError("synthetic copy failure")
                return copy(src, dest)
            with patch.object(collect_run.shutil, "copyfile", fail_later), self.assertRaises(OSError):
                collect_run.collect(root / "run", self.files(source))
            self.assertEqual({p.name for p in root.iterdir()}, {"source"})

    def test_existing_output_and_broken_symlink_are_not_replaced(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source, _ = self.capture(root)
            output = root / "run"; output.mkdir(); (output / "owned").write_text("keep")
            with self.assertRaises(ValueError): collect_run.collect(output, self.files(source))
            self.assertEqual((output / "owned").read_text(), "keep")
            link = root / "link"; link.symlink_to(root / "missing")
            with self.assertRaises(ValueError): collect_run.collect(link, self.files(source))
            self.assertTrue(link.is_symlink())

    def test_unlisted_filename_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source, _ = self.capture(root)
            with self.assertRaises(ValueError):
                collect_run.collect(root / "run", {**self.files(source), "unrelated.bin": source / "host.log"})
            self.assertFalse((root / "run").exists())

    def test_local_cli_reexport_keeps_runtime_identity_and_development_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source, _ = self.capture(root)
            (source / "runtime-library.json").write_text(json.dumps({"pid": 42, "runtimeLibrary": {"kind": "dev-override"}}))
            (source / "NOT-A-READING.txt").write_text("不作读数\n")
            args = ["collect_run.py", "--output", str(root / "run"), "--host-log", str(source / "host.log"),
                    "--metrics-directory", str(source)]
            with patch.object(sys, "argv", args), contextlib.redirect_stdout(io.StringIO()): collect_run.main()
            for name in ("runtime-library.json", "NOT-A-READING.txt"):
                self.assertEqual((root / "run" / name).read_bytes(), (source / name).read_bytes())

    def test_validated_helper_to_collector_keeps_development_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source, _ = self.capture(root)
            (source / "runtime-library.json").write_text(json.dumps({"pid": 42, "runtimeLibrary": {"kind": "dev-override"}}))
            (source / "NOT-A-READING.txt").write_text("不作读数\n")
            files = {"host.log": source / "host.log", **runtime_files(source, source / "host.log")}
            collect_run.collect(root / "run", files)
            for name in ("runtime-library.json", "NOT-A-READING.txt"):
                self.assertTrue((root / "run" / name).is_file(), "validated identity must travel with the payload")
                self.assertEqual((root / "run" / name).read_bytes(), (source / name).read_bytes())


if __name__ == "__main__":
    unittest.main()
