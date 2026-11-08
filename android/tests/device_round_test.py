#!/usr/bin/env python3
"""Offline negative-path checks for the opt-in E04 runner; never contacts ADB."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

SPEC = importlib.util.spec_from_file_location(
    "device_round", Path(__file__).resolve().parents[1] / "tools/device_round.py"
)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class EvidenceTests(unittest.TestCase):
    def test_partial_and_other_process_lines_cannot_satisfy_checkpoint(self):
        log = "1792754720.339 42 43 I S2Arm : native ok\n"
        log += "1792754720.339 99 43 I S2Arm : unrelated\n"
        log += "1792754720.339 42 43 I S2Arm : incomplete"
        self.assertEqual(runner.records(log, "42"), [("43", "native ok")])

    def test_release_before_press_does_not_pass(self):
        pressed = "input: buttons=0x0001 L=(0,0) R=(0,0)"
        self.assertFalse(runner.input_pair([runner.ZERO, pressed], pressed))
        self.assertTrue(runner.input_pair([pressed, runner.ZERO], pressed))

    def test_newest_layout_must_be_complete_and_inside_current_display(self):
        names = (*runner.BUTTONS, "LSTICK", "RSTICK")
        layout = "touchpad layout: " + " ".join(f"{n}=(100,200,r20)" for n in names)
        self.assertEqual(runner.controls_from_log([layout], (2400, 1080))["A"], (100, 200, 20))
        with self.assertRaises(runner.CheckFailed):
            runner.controls_from_log([layout, "touchpad layout: A=(100,200,r20)"], (2400, 1080))
        with self.assertRaises(runner.CheckFailed):
            runner.controls_from_log([layout], (100, 200))

    def test_fallback_cannot_cross_rotation_or_resolution(self):
        document = {"display": [2400, 1080], "rotation": 1, "controls": {}}
        for size, rotation in (((1080, 2400), 1), ((2400, 1080), 3)):
            with self.assertRaises(runner.CheckFailed):
                runner.fallback_controls(document, size, rotation)

    def test_app_beneath_credential_lock_is_not_visible(self):
        app = f'<node package="{runner.PACKAGE}" />'
        self.assertTrue(runner.visible_app(app))
        self.assertFalse(runner.visible_app(app + '<node text="Emergency call" />'))
        self.assertFalse(runner.visible_app('<node package="com.android.launcher" />'))


class CleanupTests(unittest.TestCase):
    def make_round(self, out):
        args = SimpleNamespace(out=out, runtime_commit="a" * 40, serial="private-device")
        return runner.Round(args, None)

    def test_touch_failure_does_not_prevent_app_stop_and_setting_restore(self):
        with tempfile.TemporaryDirectory() as directory:
            round_ = self.make_round(Path(directory))
            round_.owns_app = round_.changed_awake = True
            round_.original_awake = "2"
            commands = []

            def shell(*parts):
                commands.append(parts)
                return "2" if parts[:2] == ("settings", "get") else ""

            def failed_release():
                raise RuntimeError("injection unavailable")

            round_.shell = shell
            round_.release_touch = failed_release
            round_.cleanup()
            self.assertIn(("am", "force-stop", runner.PACKAGE), commands)
            self.assertIn(("settings", "put", "global", "stay_on_while_plugged_in", "2"), commands)
            self.assertEqual(
                [x["status"] for x in round_.report["cleanup"]], ["fail", "pass", "pass"]
            )

    def test_failed_preflight_never_stops_app_or_claims_device_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            round_ = self.make_round(out)

            def failed_preflight():
                raise runner.CheckFailed("Installed APK differs")

            def forbidden_shell(*_parts):
                self.fail("Preflight failure must not mutate the app")

            round_.preflight = failed_preflight
            round_.shell = forbidden_shell
            self.assertEqual(round_.run(), 1)
            report = json.loads((out / "results.json").read_text())
            self.assertEqual(report["status"], "fail")
            self.assertTrue(all(c["status"] == "not_run" for c in report["cases"]))

    def test_restore_readback_failure_is_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            round_ = self.make_round(Path(directory))
            round_.changed_awake, round_.original_awake = True, "2"
            round_.shell = lambda *_parts: "15"
            round_.cleanup()
            self.assertEqual(round_.report["cleanup"][-1]["status"], "fail")


if __name__ == "__main__":
    unittest.main()
