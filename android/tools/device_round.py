#!/usr/bin/env python3
"""Manual E04 diagnostic round; requires an explored, unlocked, idle Android device.

Uses the installed diagnostic APK and device_selftest.sh's synthetic guest only.
No installation, dependency download, game resource access, or gate registration.
Local output is private evidence, not an automatically redacted public report.
"""

import argparse
import hashlib
import json
import re
import shlex
import signal
import struct
import subprocess
import time
from pathlib import Path

PACKAGE = "org.s2arm.android"
ZERO = "input: buttons=0x0000 L=(0,0) R=(0,0)"
BUTTONS = ("A", "B", "X", "Y", "LS", "RS", "L", "R", "ZL", "ZR", "+", "−")
CASES = ("native-probes", "buttons", "sticks", "rotation", "home-reset", "finish-reopen")
LINE = re.compile(r"^\s*\d+\.\d+\s+(\d+)\s+(\d+)\s+[VDIWEF]\s+S2Arm\s*:\s*(.*)$")


class CheckFailed(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise CheckFailed(message)


def records(text, pid):
    """Only complete lines from the current app process can satisfy a checkpoint."""
    found = []
    for line in text.splitlines(keepends=True):
        match = LINE.match(line)
        if line.endswith("\n") and match and match[1] == pid:
            found.append((match[2], match[3]))
    return found


def input_pair(messages, pressed):
    """A release must follow the matching press; an earlier zero is insufficient."""
    for i, message in enumerate(messages):
        if message == pressed:
            return ZERO in messages[i + 1 :]
    return False


def controls_from_log(messages, size):
    lines = [m for m in messages if m.startswith("touchpad layout:")]
    require(lines, "No live touchpad layout; use an explicitly verified --fallback-layout")
    controls = {
        name: tuple(map(int, (x, y, radius)))
        for name, x, y, radius in re.findall(r"([^\s=]+)=\((\d+),(\d+),r(\d+)\)", lines[-1])
    }
    validate_controls(controls, size)
    return controls


def validate_controls(controls, size):
    require(all(k in controls for k in (*BUTTONS, "LSTICK", "RSTICK")), "Incomplete layout")
    require(
        all(0 <= x < size[0] and 0 <= y < size[1] and r > 0 for x, y, r in controls.values()),
        "Layout outside the current display",
    )


def fallback_controls(document, size, rotation):
    require(document["display"] == list(size), "Fallback display does not match")
    require(document["rotation"] == rotation, "Fallback rotation does not match")
    controls = document["controls"]
    validate_controls(controls, size)
    return controls


def visible_app(hierarchy):
    # ADB screenshots/currentPackageName can still name the app under a credential lock.
    locked = re.search(r"keyguard|紧急呼叫|Emergency call|请用图案密码", hierarchy, re.I)
    return not locked and f'package="{PACKAGE}"' in hierarchy


class Round:
    def __init__(self, args, device):
        self.args, self.device = args, device
        self.pid = ""
        self.owns_app = False
        self.changed_awake, self.original_awake, self.held = False, "", None
        self.log_process = self.log_file = self.log_error = None
        self.report = {
            "schema": 1,
            "runtimeCommit": args.runtime_commit,
            "cases": [],
            "cleanup": [],
        }

    def adb(self, *parts, check=True, binary=False):
        result = subprocess.run(
            [self.args.adb, "-s", self.args.serial, *map(str, parts)],
            capture_output=True,
            timeout=30,
        )
        if check and result.returncode:
            # Keep command failures local; do not echo the serial or host paths.
            raise CheckFailed(f"ADB {parts[0]} failed ({result.returncode})")
        return result.stdout if binary else result.stdout.decode(errors="replace").strip()

    def shell(self, *parts, **kwargs):
        return self.adb("shell", shlex.join(list(map(str, parts))), **kwargs)

    def wait(self, predicate, description):
        until = time.monotonic() + self.args.timeout
        while time.monotonic() < until:
            value = predicate()
            if value:
                return value
            time.sleep(0.2)
        raise CheckFailed("Timed out: " + description)

    def messages(self):
        path = self.args.out / "app-logcat.txt"
        return records(path.read_text(errors="replace") if path.exists() else "", self.pid)

    def texts(self, cursor=0):
        return [message for _, message in self.messages()[cursor:]]

    def expect(self, pattern, cursor=0):
        return self.wait(lambda: re.search(pattern, "\n".join(self.texts(cursor))), pattern)

    def app_visible(self):
        require(
            visible_app(self.device.dump_hierarchy()), "App not visible/unlocked; unlock on device"
        )

    def current_pid(self):
        value = self.shell("pidof", PACKAGE, check=False)
        require(bool(re.fullmatch(r"\d+", value)), "Expected exactly one diagnostic app process")
        return value

    def launch(self, orientation="landscape", panel="off", finish=False):
        command = ["am", "start", "-W", "-n", PACKAGE + "/.MainActivity"]
        for key, value in (
            ("orientation", orientation),
            ("panel", panel),
            ("touchpad", "on"),
            ("touchlog", "on"),
        ):
            command += ["--es", "s2arm." + key, value]
        if finish:
            command += ["--ez", "s2arm.finish", "true"]
        require("Status: ok" in self.shell(*command), "Activity did not start")

    def layout(self):
        size = self.device.window_size()
        try:
            return controls_from_log(self.texts(), size)
        except CheckFailed:
            if not self.args.fallback_layout:
                raise
            document = json.loads(self.args.fallback_layout.read_text())
            return fallback_controls(document, size, self.device.info["displayRotation"])

    def screenshot(self, name, rotation):
        self.wait(
            lambda: (
                self.device.info["displayRotation"] == rotation
                and self.device.window_size() == (2400, 1080)
            ),
            "landscape display configuration",
        )
        self.app_visible()
        # Callbacks precede the compositor animation. This is a bounded settle, not a pixel verdict.
        time.sleep(1.2)
        data = self.adb("exec-out", "screencap", "-p", binary=True)
        require(data[:8] == b"\x89PNG\r\n\x1a\n", "Invalid screenshot")
        require(struct.unpack(">II", data[16:24]) == (2400, 1080), "Screenshot in transition")
        (self.args.out / (name + ".png")).write_bytes(data)

    def preflight(self):
        require(self.adb("get-state") == "device", "Device not authorized")
        apk_hash = hashlib.sha256(self.args.apk.read_bytes()).hexdigest()
        installed = self.shell("pm", "path", PACKAGE).splitlines()
        require(
            len(installed) == 1 and installed[0].startswith("package:"),
            "Diagnostic APK missing/split",
        )
        actual = self.shell("sha256sum", installed[0][8:]).split()[0]
        require(actual == apk_hash, "Installed APK differs from --apk; no app mutation performed")
        self.report["apkSha256"] = apk_hash
        self.report["device"] = {
            key: self.shell("getprop", key)
            for key in ("ro.product.model", "ro.product.device", "ro.build.version.release")
        }
        require(
            self.shell("run-as", PACKAGE, "ls", "files/selftest/selftest.patched.bin", check=False),
            "Import the existing device_selftest.sh fixture first",
        )
        self.original_awake = self.shell("settings", "get", "global", "stay_on_while_plugged_in")
        require(
            bool(re.fullmatch(r"\d+|null", self.original_awake)), "Cannot preserve stay-awake value"
        )
        if self.args.keep_awake:
            self.changed_awake = True  # Also restore if the setting command partly fails.
            self.shell("svc", "power", "stayon", "true")
        self.log_file = (self.args.out / "app-logcat.txt").open("wb")
        self.log_error = (self.args.out / "logcat-stderr.txt").open("wb")
        self.log_process = subprocess.Popen(
            [
                self.args.adb,
                "-s",
                self.args.serial,
                "logcat",
                "-v",
                "epoch",
                "-T",
                "1",
                "-s",
                "S2Arm:I",
            ],
            stdout=self.log_file,
            stderr=self.log_error,
        )

    def native_probes(self):
        self.owns_app = True
        self.shell("am", "force-stop", PACKAGE)
        self.launch()
        self.pid = self.current_pid()
        self.expect(r"6 rewrite kinds x 2 guest threads ok")
        for text in (
            "Shared-memory alias: available",
            "39-bit / 64 GiB address window: available",
            "thread-isolated",
            "SA_ONSTACK 14/14 on alt stack",
            "write / read distinguishable",
        ):
            self.wait(lambda text=text: text in "\n".join(self.texts()), text)
        self.expect(r"HostApi display 2400x1080 rotation 1")
        self.expect(r"Vulkan present: .*frames, interval avg")
        self.screenshot("landscape", 1)
        self.layout()

    def buttons(self):
        controls = self.layout()
        for bit, name in enumerate(BUTTONS):
            cursor = len(self.messages())
            self.wait(
                lambda name=name: self.device.jsonrpc.click(*controls[name][:2]), "tap accepted"
            )
            pressed = f"input: buttons=0x{1 << bit:04x} L=(0,0) R=(0,0)"
            self.wait(
                lambda cursor=cursor, pressed=pressed: input_pair(self.texts(cursor), pressed),
                f"{name} press then release",
            )

    def sticks(self):
        controls = self.layout()
        for name, axis in (("LSTICK", "L"), ("RSTICK", "R")):
            x, y, radius = controls[name]
            cursor = len(self.messages())
            self.device.swipe(x, y, x + int(radius * 0.8), y - int(radius * 0.4), duration=0.45)
            match = self.expect(axis + r"=\([1-9]\d*,[1-9]\d*\)", cursor)
            self.wait(
                lambda match=match, cursor=cursor: any(
                    match[0] in m and ZERO in self.texts(cursor)[i + 1 :]
                    for i, m in enumerate(self.texts(cursor))
                ),
                "stick returns to zero",
            )

    def rotation(self):
        for orientation, rotation, transform in (
            ("reverse-landscape", 3, "8"),
            ("landscape", 1, "2"),
        ):
            cursor = len(self.messages())
            self.launch(orientation)
            self.expect(f"HostApi display 2400x1080 rotation {rotation}", cursor)
            self.expect(f"Vulkan present: swapchain .*transform 0x{transform}", cursor)
            self.screenshot(orientation, rotation)
            require(self.current_pid() == self.pid, "Rotation restarted the process")

    def home_reset(self):
        x, y, _ = self.layout()["A"]
        cursor = len(self.messages())
        self.held = (x, y)
        try:
            self.device.touch.down(x, y)
            self.expect(r"input: buttons=0x0001", cursor)
            self.device.press("home")
            self.wait(
                lambda: input_pair(self.texts(cursor), "input: buttons=0x0001 L=(0,0) R=(0,0)"),
                "held A resets after HOME",
            )
            self.expect(r"Surface generation \d+ detached in \d+ ms", cursor)
        finally:
            self.release_touch()
        cursor = len(self.messages())
        self.launch()
        self.expect(r"Vulkan surface generation \d+ offered", cursor)
        self.expect(r"Vulkan present: surface generation", cursor)
        require(self.current_pid() == self.pid, "HOME restarted the process")
        self.screenshot("home-restored", 1)

    def finish_reopen(self):
        tids = [tid for tid, m in self.messages() if m.startswith("Vulkan present:")]
        require(tids, "No render-thread identity")
        cursor = len(self.messages())
        self.launch(finish=True)
        self.expect(r"Surface generation \d+ detached in \d+ ms", cursor)
        path = f"/proc/{self.pid}/task/{tids[-1]}"
        self.wait(
            lambda: (
                self.shell("sh", "-c", f"if test -d {path}; then echo present; else echo gone; fi")
                == "gone"
            ),
            "old render thread exits",
        )
        cursor = len(self.messages())
        self.launch(panel="on")
        require(self.current_pid() == self.pid, "Reopen restarted the diagnostic process")
        self.expect(r"Vulkan present: surface generation", cursor)
        self.screenshot("reopened-diagnostics", 1)

    def release_touch(self):
        if self.held is not None:
            self.device.touch.up(*self.held)
            self.held = None

    def cleanup(self):
        steps = [("release-touch", self.release_touch)]
        if self.owns_app:
            steps.append(("stop-diagnostic-app", lambda: self.shell("am", "force-stop", PACKAGE)))
        if self.changed_awake:
            steps.append(("restore-stay-awake", self.restore_awake))
        for name, action in steps:
            try:
                action()
                self.report["cleanup"].append({"name": name, "status": "pass"})
            except Exception as error:
                self.report["cleanup"].append(
                    {"name": name, "status": "fail", "error": type(error).__name__}
                )
        if self.log_process:
            self.log_process.terminate()
            try:
                self.log_process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.log_process.kill()  # Only this script's own logcat child.
                self.log_process.wait(timeout=3)
        for file in (self.log_file, self.log_error):
            if file:
                file.close()

    def restore_awake(self):
        parts = (
            ("delete", "global", "stay_on_while_plugged_in")
            if self.original_awake == "null"
            else ("put", "global", "stay_on_while_plugged_in", self.original_awake)
        )
        self.shell("settings", *parts)
        require(
            self.shell("settings", "get", "global", "stay_on_while_plugged_in")
            == self.original_awake,
            "Stay-awake restoration did not persist",
        )

    def run(self):
        try:
            self.preflight()
            if self.device is None:
                import uiautomator2 as u2

                self.device = u2.connect(self.args.serial)
            for name, method in zip(
                CASES,
                (
                    self.native_probes,
                    self.buttons,
                    self.sticks,
                    self.rotation,
                    self.home_reset,
                    self.finish_reopen,
                ),
                strict=True,
            ):
                item = {"name": name, "status": "fail"}
                self.report["cases"].append(item)
                try:
                    if self.pid:
                        self.app_visible()
                    method()
                    item["status"] = "pass"
                    print("PASS", name, flush=True)
                except BaseException as error:
                    item["error"] = str(error).replace(self.args.serial, "<device>")
                    raise
        except (Exception, KeyboardInterrupt) as error:
            self.report["error"] = str(error).replace(self.args.serial, "<device>")
        finally:
            self.cleanup()
            for name in CASES[len(self.report["cases"]) :]:
                self.report["cases"].append({"name": name, "status": "not_run"})
            self.report["status"] = (
                "pass"
                if all(c["status"] == "pass" for c in self.report["cases"] + self.report["cleanup"])
                else "fail"
            )
            (self.args.out / "results.json").write_text(
                json.dumps(self.report, ensure_ascii=False, indent=2) + "\n"
            )
        return 0 if self.report["status"] == "pass" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument(
        "--apk", required=True, type=Path, help="Exact locally built diagnostic APK"
    )
    parser.add_argument(
        "--runtime-commit", required=True, help="Caller-recorded 40-character runtime source commit"
    )
    parser.add_argument("--out", required=True, type=Path, help="New private evidence directory")
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--timeout", type=float, default=15)
    parser.add_argument(
        "--keep-awake",
        action="store_true",
        help="Temporarily keep awake while charging; restore on exit",
    )
    parser.add_argument(
        "--fallback-layout", type=Path, help="Explicitly verified display/rotation/controls JSON"
    )
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.runtime_commit) or not 1 <= args.timeout <= 60:
        parser.error("Expected a full source commit and timeout between 1 and 60 seconds")
    args.out.mkdir(parents=True, mode=0o700)  # Refuse to overwrite evidence from a previous round.

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt("Interrupted; cleanup requested")

    signal.signal(signal.SIGTERM, interrupted)
    return Round(args, None).run()


if __name__ == "__main__":
    raise SystemExit(main())
