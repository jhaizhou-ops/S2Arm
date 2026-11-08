#!/usr/bin/env python3
"""Exercise the actual W6 runner: PASS -> compiler FAIL -> prebuilt-identity FAIL.

Requires the same installed offline host tools as run.py. All test inputs/outputs are private.
No runner helper is mocked/imported, and no lease/retirement source is modified.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


HERE = Path(__file__).resolve().parent


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(ok, message):
    if not ok:
        raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="new absolute private test directory")
    args = parser.parse_args()
    out = args.out
    if not out.is_absolute() or out.exists():
        parser.error("--out must be a new absolute directory")
    out.mkdir(parents=True)
    out = out.resolve()
    root = out / "receipts"
    env = os.environ.copy()
    compiler = shutil.which(env.get("CC", "cc"))
    check(compiler is not None, "installed C compiler required")
    command = [sys.executable, str(HERE / "run.py"), "--output-root", str(root)]
    attempts = []

    def finish(process, name, expected):
        try:
            stdout, stderr = process.communicate(timeout=180)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                stdout, stderr = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                stdout, stderr = process.communicate()
            raise AssertionError("actual runner timed out: " + name)
        (out / (name + ".stdout")).write_text(stdout)
        (out / (name + ".stderr")).write_text(stderr)
        check((process.returncode == 0) == (expected == "PASS"), "runner exit does not match " + expected)
        current = read(root / "result.json")
        check(current["status"] == expected, "current receipt retained stale status")
        folder = Path(current["attempt_dir"])
        check(read(folder / "result.json") == current, "attempt and current receipts differ")
        check(folder.is_relative_to(root / "attempts"), "evidence escaped attempt directory")
        check(current["attempt_id"] not in {a["attempt_id"] for a in attempts}, "attempt ID reused")
        attempts.append(current)
        return current, folder

    first, first_dir = finish(subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE,
                                              stderr=subprocess.PIPE), "success", "PASS")
    first_hash = digest(first_dir / "result.json")
    first_log_hash = digest(first_dir / "tests.log")
    check(first["tests_log_sha256"] == first_log_hash, "real managed/native stdout receipt mismatch")

    # A deliberate invalid option is sent to the real compiler. Pause first so the parent
    # observes RUNNING while this attempt is still executing, before the compiler fails.
    release = out / "release-compiler"
    wrapper = out / "compiler-failure"
    wrapper.write_text(
        "#!" + sys.executable + "\nimport os, pathlib, time\n"
        + "release = pathlib.Path(" + repr(str(release)) + ")\n"
        + "print('compiler failure gate entered', flush=True)\n"
        + "deadline = time.monotonic() + 15\n"
        + "while not release.exists() and time.monotonic() < deadline: time.sleep(.02)\n"
        + "os.execv(" + repr(compiler) + ", [" + repr(compiler)
        + ", '--wsi-runner-negative-invalid-option'] + __import__('sys').argv[1:])\n"
    )
    wrapper.chmod(0o700)
    failed_env = dict(env, CC=str(wrapper))
    process = subprocess.Popen(command, env=failed_env, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 15
        running = None
        while time.monotonic() < deadline and process.poll() is None:
            candidate = read(root / "result.json")
            if candidate["attempt_id"] != first["attempt_id"] and candidate["status"] == "RUNNING":
                running = candidate
                break
            time.sleep(.02)
        check(running is not None, "new attempt did not replace old PASS with RUNNING")
    finally:
        release.touch()
    second, second_dir = finish(process, "compiler-failure", "FAIL")
    check(second["stage"] == "c_header_abi", "failure was not the actual compiler step")
    check(second["commands"][-1]["returncode"] != 0, "compiler failure not retained")
    actual_error = Path(str(second_dir / "abi-build.log") + ".stderr").read_text()
    check("wsi-runner-negative-invalid-option" in actual_error, "real compiler stderr missing")
    check((second_dir / "failure.log").exists(), "failure traceback missing")
    check(digest(first_dir / "result.json") == first_hash and digest(first_dir / "tests.log") == first_log_hash,
          "compiler failure changed historical PASS evidence")

    # Use the real successful AnyCPU assembly and its companion files, only changing the
    # supplied source identity. The actual runner must reject before executing that assembly.
    prebuilt = out / "wrong-prebuilt"
    prebuilt.mkdir()
    dll = Path(first["managed_dll"])
    for name in (dll.name, dll.with_suffix(".deps.json").name,
                 dll.with_suffix(".runtimeconfig.json").name, "wsi-source.json"):
        shutil.copyfile(dll.parent / name, prebuilt / name)
    identity_path = prebuilt / "wsi-source.json"
    identity = read(identity_path)
    identity["inputs"]["NativeLease.cs"] = "0" * 64
    identity_path.write_text(json.dumps(identity) + "\n")
    third, third_dir = finish(subprocess.Popen(command + ["--prebuilt", str(prebuilt / dll.name)],
                                              env=env, text=True, stdout=subprocess.PIPE,
                                              stderr=subprocess.PIPE), "identity-failure", "FAIL")
    check(third["stage"] == "managed_build_or_prebuilt_identity", "wrong failure stage")
    check("prebuilt assembly/source identity mismatch" in third["error"]["message"], "identity check was bypassed")
    check(not (third_dir / "tests.log").exists(), "wrong-identity assembly was executed")
    check(digest(first_dir / "result.json") == first_hash and digest(first_dir / "tests.log") == first_log_hash,
          "identity failure changed historical PASS evidence")
    check(len(list((root / "attempts").iterdir())) == 3, "attempt evidence was overwritten or lost")
    report = {"status": "PASS", "runner": str(HERE / "run.py"), "runner_sha256": digest(HERE / "run.py"),
              "cases": [{"attempt_id": a["attempt_id"], "status": a["status"], "dir": a["attempt_dir"]}
                        for a in attempts], "observed_running_before_compiler_failure": True,
              "gpu_executed": False, "production_renderer_connected": False}
    (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PASS: actual runner PASS -> RUNNING/real compiler FAIL -> prebuilt identity FAIL; history retained")
    print("evidence: " + str(out / "result.json"))


if __name__ == "__main__":
    main()
