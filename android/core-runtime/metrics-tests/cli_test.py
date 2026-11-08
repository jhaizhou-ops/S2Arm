#!/usr/bin/env python3
"""执行实际 metrics.py CLI；只替换 subprocess ADB 边界，不访问设备。"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / "metrics.py"
sys.path.insert(0, str(SOURCE.parent))
spec = importlib.util.spec_from_file_location("android_metrics", SOURCE)
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)
ACTIVE = "metrics-9-42-" + "a" * 32
STATE = "files/state"
LOG = "host-9-42-Ab3.log"


class ExportTests(unittest.TestCase):
    def invoke(self, action, output, *, status="completed", duplicate=False, fail_read=False, wrong_id=False,
               library="apk", library_pid=42, extra=(), boot=None, corrupt=False, host_id=None, fail_control=False):
        commands = []
        metadata = json.dumps({"id": "wrong" if wrong_id else ACTIVE, "status": status, "startBootUs": 100,
                               "lastFrameBootUs": 200, "endBootUs": 1200, "frames": 1,
                               "clock": "CLOCK_BOOTTIME", "frameSource": "guest-present",
                               "markFrame": -1, "markBootUs": -1}).encode()
        def remote(command, **kwargs):
            self.assertEqual(command[:3], ["not-real-adb", "-s", "transport"])
            if command[3] == "shell":
                self.assertEqual(command[3:7], ["shell", "-T", "run-as", "org.s2arm.game.t0100000000abcdef"])
                args = command[7:]
                if fail_control: raise subprocess.CalledProcessError(1, command)
            else:
                self.assertEqual(command[3:6], ["exec-out", "run-as", "org.s2arm.game.t0100000000abcdef"])
                args = command[6:]
                if fail_control:
                    # exec-out cannot carry a remote shell exit status: the old control falsely succeeds.
                    return SimpleNamespace(stdout=b"Permission denied\n")
            commands.append(args)
            if args == ["cat", STATE + "/metrics-active.txt"]: data = (ACTIVE + "\n").encode()
            elif args == ["cat", STATE + "/" + ACTIVE + "/runtime-metrics.json"]: data = metadata
            elif args == ["ls", "-1", STATE]:
                data = (LOG + "\n" + ("host-9-42-Cd4.log\n" if duplicate else "unrelated.log\n")).encode()
            elif args == ["ls", STATE]:
                data = (LOG + "  unrelated.log\n").encode()  # The actual owner-reported multi-column red case.
            elif args == ["cat", STATE + "/" + ACTIVE + "/frames.tsv"]: data = (b"frame\twall_us\talloc_b\tgc0\tgc1\tgc2\tgc_pause_us\tboot_us\n"
                    + (b"0\n" if corrupt else b"0\t0\t0\t0\t0\t0\t0\t200\n"))
            elif args == ["cat", STATE + "/runtime-library.json"]:
                if library is None:
                    if command[3] == "exec-out": return SimpleNamespace(stdout=b"cat: runtime-library.json: No such file or directory\n")
                    raise subprocess.CalledProcessError(1, command)
                if isinstance(library, bytes): data = library
                else:
                    record = {"kind": "apk"} if library == "apk" else {"kind": "dev-override", "sha256": "1a" * 32}
                    data = json.dumps({"pid": library_pid, "sessionId": "s", "runtimeLibrary": record}).encode()
            elif args == ["cat", "cache/boot-spec-0100000000ABCDEF.json"]:
                if boot is None:
                    if command[3] == "exec-out": return SimpleNamespace(stdout=b"cat: boot-spec: No such file or directory\n")
                    raise subprocess.CalledProcessError(1, command)
                data = json.dumps(boot).encode()
            elif args == ["cat", STATE + "/" + LOG]:
                if fail_read: raise subprocess.CalledProcessError(1, command)
                data = (f"[Android metrics] id={host_id or ACTIVE}; clock=CLOCK_BOOTTIME\noriginal host log\r\n").encode()
            elif args in (["touch", STATE + "/metrics.enable"], ["rm", STATE + "/metrics.enable"],
                          ["touch", STATE + "/" + ACTIVE + "/mark.request"]): data = b""
            else: raise AssertionError(args)
            return SimpleNamespace(stdout=data)
        argv = [str(SOURCE), action, "--adb", "not-real-adb", "--serial", "transport", "--package", "org.s2arm.game.t0100000000abcdef",
                "--state-dir", STATE, "--output", str(output), *extra]
        with patch.object(sys, "argv", argv), patch.object(metrics.subprocess, "run", remote), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            metrics.main()
        return commands, metadata

    def test_export_exact_raw_files_and_single_column_listing(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / "export"
            commands, metadata = self.invoke("export", out)
            self.assertIn(["ls", "-1", STATE], commands)
            self.assertEqual(set(p.name for p in out.iterdir()),
                             {"host.log", "frames.tsv", "runtime-metrics.json", "runtime-library.json"})
            self.assertEqual((out / "runtime-metrics.json").read_bytes(), metadata)
            self.assertEqual((out / "host.log").read_bytes(),
                             (f"[Android metrics] id={ACTIVE}; clock=CLOCK_BOOTTIME\noriginal host log\r\n").encode())

    def test_incomplete_wrong_session_or_ambiguous_log_rejected(self):
        for kwargs in ({"status": "capturing"}, {"status": "failed"}, {"duplicate": True}, {"wrong_id": True}, {"fail_read": True}):
            with self.subTest(kwargs=kwargs), tempfile.TemporaryDirectory() as temp:
                out = Path(temp) / "export"
                with self.assertRaises(SystemExit) as error: self.invoke("export", out, **kwargs)
                self.assertEqual(error.exception.code, 2)
                self.assertFalse(out.exists())

    def test_development_runtime_is_no_reading(self):
        new_boot = {"diagnostics": {"logDir": "/x", "runtimeLibrary": {"kind": "apk"}}}
        for kwargs in ({"library": "dev"}, {"library_pid": 7}, {"library": None, "boot": new_boot},
                       {"library": b"[]"}, {"library": b'{"pid": 42, "runtimeLibrary": "apk"}'}, {"library": b"{not json"}):
            with self.subTest(kwargs=kwargs), tempfile.TemporaryDirectory() as temp:
                out = Path(temp) / "export"
                with self.assertRaises(SystemExit) as error: self.invoke("export", out, **kwargs)
                self.assertEqual(error.exception.code, 2)
                self.assertFalse(out.exists())
        for boot in (None, {"diagnostics": {"logDir": "/x"}}):   # earlier APKs: no record, BootSpec without the field
            with self.subTest(legacy_boot=boot), tempfile.TemporaryDirectory() as temp:
                out = Path(temp) / "export"
                self.invoke("export", out, library=None, boot=boot)
                self.assertEqual(set(p.name for p in out.iterdir()), {"host.log", "frames.tsv", "runtime-metrics.json"})
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / "export"
            self.invoke("export", out, library="dev", extra=("--allow-dev-run",))
            self.assertIn("不作读数", (out / "NOT-A-READING.txt").read_text(encoding="utf-8"))
            self.assertEqual(json.loads((out / "runtime-library.json").read_text())["runtimeLibrary"]["kind"], "dev-override")

    def test_production_contract_rejects_corruption_and_foreign_host(self):
        for kwargs in ({"corrupt": True}, {"host_id": "metrics-9-43-" + "b" * 32}):
            with self.subTest(kwargs=kwargs), tempfile.TemporaryDirectory() as temp:
                out = Path(temp) / "export"
                with self.assertRaises(SystemExit) as error: self.invoke("export", out, **kwargs)
                self.assertEqual(error.exception.code, 2)
                self.assertFalse(out.exists())

    def test_write_failure_leaves_no_published_directory(self):
        original = Path.write_bytes
        def fail_host(path, data):
            if path.name == "host.log": raise OSError("synthetic write failure")
            return original(path, data)
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / "export"
            with patch.object(Path, "write_bytes", fail_host), self.assertRaises(SystemExit) as error:
                self.invoke("export", out)
            self.assertEqual(error.exception.code, 2)
            self.assertFalse(out.exists(), "an incomplete capture must never be published")

    def test_control_remote_failure_is_not_success(self):
        with tempfile.TemporaryDirectory() as temp:
            for action in ("enable", "disable"):
                with self.subTest(action=action):
                    with self.assertRaises(SystemExit) as error:
                        self.invoke(action, Path(temp) / "unused", fail_control=True)
                    self.assertEqual(error.exception.code, 2)

    def test_optional_power_transport_and_manifest_are_carried_unchanged(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            power = root / "battery.tsv"; power.write_bytes(b"boot_us\tcurrent_ua\n100\t-123\r\n")
            info = Path(str(power) + ".source.json")
            info.write_text(json.dumps({"serial": "transport", "scope": "battery", "clock": "CLOCK_BOOTTIME"}))
            manifest = root / "manifest.json"; manifest.write_bytes(b'{"unchanged":true}\r\n')
            extra = ("--power-samples", str(power), "--run-manifest", str(manifest))
            self.invoke("export", root / "good", extra=extra)
            for name, original in (("battery.tsv", power), ("battery-source.json", info), ("run-manifest.json", manifest)):
                self.assertEqual((root / "good" / name).read_bytes(), original.read_bytes())
            info.write_text(json.dumps({"serial": "another-transport"}))
            with self.assertRaises(SystemExit) as error: self.invoke("export", root / "bad", extra=extra)
            self.assertEqual(error.exception.code, 2)
            self.assertFalse((root / "bad").exists())

    def test_existing_output_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            (out / "owned").write_text("preserve")
            with self.assertRaises(SystemExit): self.invoke("export", out)
            self.assertEqual((out / "owned").read_text(), "preserve")

    def test_controls_do_not_launch_or_install(self):
        with tempfile.TemporaryDirectory() as temp:
            for action in ("enable", "disable", "mark"):
                commands, _ = self.invoke(action, Path(temp) / "unused", status="capturing")
                self.assertFalse(any(c[0] in ("am", "install", "ls") for c in commands))

    def test_mark_rejects_a_foreign_capture(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(SystemExit) as error:
                self.invoke("mark", Path(temp) / "unused", status="capturing", wrong_id=True)
            self.assertEqual(error.exception.code, 2)

    def test_state_path_boundary(self):
        for bad in ("/files/a", "files/../a", "files//a", "files/./a", "files/a;id"):
            with self.assertRaises(ValueError): metrics.safe_state(bad)
        self.assertEqual(metrics.safe_state("files/state/user-1"), "files/state/user-1")


if __name__ == "__main__": unittest.main()
