#!/usr/bin/env python3
"""tools/dev_runtime.py without a device: the ELF / JNI ABI checks of `manifest`, and `push` against a fake
adb (a script that answers pm path / sha256sum / run-as / logcat and records every call)."""
import hashlib
import importlib.util
import json
import shutil
import struct
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ANDROID = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("dev_runtime", ANDROID / "tools/dev_runtime.py")
dev_runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev_runtime)


def elf(align=16384, soname=b"libs2arm_android.so", payload=b""):
    """AArch64 ELF64: one LOAD over the file, PT_DYNAMIC with DT_STRTAB / DT_SONAME, then payload."""
    dyn, = (64 + 2 * 56,)
    strtab = dyn + 3 * 16
    names = b"\0" + soname + b"\0"
    size = strtab + len(names) + len(payload)
    b = bytearray(size)
    b[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<H", b, 18, 183)
    struct.pack_into("<Q", b, 32, 64)
    struct.pack_into("<HH", b, 54, 56, 2)
    struct.pack_into("<IIQQQQQQ", b, 64, 1, 5, 0, 0, 0, size, size, align)
    struct.pack_into("<IIQQQQQQ", b, 120, 2, 6, dyn, dyn, dyn, 48, 48, 8)
    struct.pack_into("<qQqQqQ", b, dyn, 5, strtab, 14 if soname else 0, 1, 0, 0)
    b[strtab:strtab + len(names)] = names
    b[strtab + len(names):] = payload
    return bytes(b)


FAKE_ADB = textwrap.dedent('''\
    #!/usr/bin/env python3
    import json, sys
    state = json.load(open(sys.argv[1]))
    args = sys.argv[4:]          # fake-adb <state> -s <serial> ...
    with open(state["log"], "a") as log: log.write(json.dumps(args) + "\\n")
    command = " ".join(args)
    if args[0] == "push": sys.exit(0)
    if "pm path" in command: print("package:/data/app/x/base.apk")
    elif "sha256sum /data/app/x/base.apk" in command: print(state["installed"] + "  /data/app/x/base.apk")
    elif "sha256sum files/dev-runtime" in command: print(state["lib"] + "  f")
    elif "pidof" in command: sys.exit(1)
    elif "logcat -d" in command: print("W S2Arm : runtime-library: dev-override sha256=" + state["lib"] + " base-apk=x")
''')


GIT = shutil.which("git")   # the manifest records the source identity from git


class DevRuntime(unittest.TestCase):
    def test_elf_checks_match_the_app(self):
        with tempfile.TemporaryDirectory() as temp:
            for data, problem in ((elf(), None), (elf(align=4096), "16 KB"), (elf(soname=b"libs2arm_androix.so"), "DT_SONAME"),
                                  (elf(soname=b""), "DT_SONAME"), (b"\x7fELF\x01" + bytes(100), "AArch64")):
                path = Path(temp) / "lib.so"
                path.write_bytes(data)
                got = dev_runtime.elf_problem(path)
                self.assertEqual(got is None, problem is None, got)
                if problem:
                    self.assertIn(problem, got)

    @unittest.skipUnless(GIT, "dev_runtime.py manifest needs git (source identity); no git on PATH")
    def test_manifest_requires_this_trees_jni_abi(self):
        with tempfile.TemporaryDirectory() as temp:
            t = Path(temp)
            (t / "app.apk").write_bytes(b"apk")
            (t / "old.so").write_bytes(elf(payload=b"0" * 64))
            r = dev_runtime.main(["manifest", "--lib", str(t / "old.so"), "--apk", str(t / "app.apk"), "--out", str(t / "o1")])
            self.assertEqual(r, 2)
            self.assertFalse((t / "o1").exists())
            (t / "new.so").write_bytes(elf(payload=dev_runtime.jni_abi().encode()))
            self.assertEqual(dev_runtime.main(["manifest", "--lib", str(t / "new.so"), "--apk", str(t / "app.apk"),
                                               "--out", str(t / "o2")]), 0)
            doc = json.loads((t / "o2/dev-runtime.json").read_text())
            self.assertEqual(doc["libSha256"], hashlib.sha256((t / "new.so").read_bytes()).hexdigest())
            self.assertEqual(doc["baseApkSha256"], hashlib.sha256(b"apk").hexdigest())
            self.assertRegex(doc["sourceCommit"], r"^[0-9a-f]{40}$")
            self.assertIsInstance(doc["dirty"], bool)

    def push(self, temp, installed=None):
        t = Path(temp)
        lib = elf(payload=dev_runtime.jni_abi().encode())
        (t / "app.apk").write_bytes(b"apk")
        (t / "lib.so").write_bytes(lib)
        dev_runtime.main(["manifest", "--lib", str(t / "lib.so"), "--apk", str(t / "app.apk"), "--out", str(t / "out")])
        state = {"log": str(t / "calls.jsonl"), "lib": hashlib.sha256(lib).hexdigest(),
                 "installed": installed or hashlib.sha256(b"apk").hexdigest()}
        (t / "state.json").write_text(json.dumps(state))
        (t / "adb.py").write_text(FAKE_ADB)
        rc = dev_runtime.main(["push", "--serial", "S1", "--package", "org.s2arm.game.t0100000000abcdef",
                               "--console-mode", "docked", "--lib-dir", str(t / "out"), "--clean",
                               "--adb", f"{sys.executable} {t / 'adb.py'} {t / 'state.json'}"])
        calls = [json.loads(l) for l in (t / "calls.jsonl").read_text().splitlines()]
        return rc, calls, state

    @unittest.skipUnless(GIT, "the pushed manifest is made with git; no git on PATH")
    def test_push_installs_read_only_and_starts_with_the_extra(self):
        with tempfile.TemporaryDirectory() as temp:
            rc, calls, state = self.push(temp)
            self.assertEqual(rc, 0)
            shell = [" ".join(c[1:]) for c in calls if c[0] == "shell"]
            copy = next(c for c in shell if "files/dev-runtime/" + state["lib"] in c and "chmod 0555" in c)
            self.assertIn("chmod 0444", copy)
            self.assertIn('chmod -R u+w "$x"; rm -rf "$x"', copy)
            start = next(c for c in shell if c.startswith("am start -W"))
            self.assertIn(f"--es s2arm.dev_runtime {state['lib']} --es s2arm.console_mode docked", start)

    @unittest.skipUnless(GIT, "the pushed manifest is made with git; no git on PATH")
    def test_push_refuses_another_installed_apk(self):
        with tempfile.TemporaryDirectory() as temp:
            rc, calls, _ = self.push(temp, installed="99" * 32)
            self.assertEqual(rc, 2)
            self.assertFalse(any(c[0] == "push" for c in calls), "nothing pushed")
            self.assertFalse(any("am start -W" in " ".join(c) for c in calls), "nothing started")


if __name__ == "__main__":
    sys.exit(unittest.main())
