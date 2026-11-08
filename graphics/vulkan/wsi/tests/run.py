#!/usr/bin/env python3
"""Offline W6 host tests with immutable attempt directories and an atomic current receipt.

Linux adds the unchanged pthread lease producer. Other hosts report that gate NOT RUN.
--prebuilt accepts the AnyCPU WsiTests.dll plus its adjacent runtimeconfig/deps files;
Linux then needs a .NET 10 runtime and C compiler, not a .NET SDK.
"""

import argparse
from datetime import datetime, timezone
import fcntl
import functools
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import traceback
import uuid


HERE = Path(__file__).resolve().parent
MODULE = HERE.parent
REPO = MODULE.parents[2]
NATIVE = REPO / "android/native"
MANAGED = [MODULE / "RetirementLedger.cs", MODULE / "NativeLease.cs",
           HERE / "Program.cs", HERE / "WsiTests.csproj"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def atomic_json(path, report):
    """Only replace a receipt after its complete JSON has been flushed."""
    fd, temporary = tempfile.mkstemp(prefix=".result-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(report, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)  # this invocation's exclusive temporary file only


def publish(root, output, report, starting=False):
    atomic_json(output / "result.json", report)
    # Protect read/check/replace when two explicit invocations overlap. An older attempt's
    # completion must not replace the newer attempt's RUNNING/FAIL with its own PASS.
    with (root / ".receipt.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = root / "result.json"
        old = json.loads(current.read_text()) if current.exists() else None
        if starting and old is not None and "attempt_id" not in old:
            legacy = root / ("legacy-result-" + sha(current) + ".json")
            if not legacy.exists():
                legacy.write_bytes(current.read_bytes())
        if starting or old is None or old.get("attempt_id") == report["attempt_id"]:
            atomic_json(current, report)


def call(command, log, env, expect=0, history=None):
    entry = {"argv": list(map(str, command)), "expected_exit": expect, "log": str(log)}
    try:
        result = subprocess.run(command, env=env, text=True, capture_output=True)
    except OSError as error:
        stdout, stderr = "", str(error) + "\n"
        entry.update(returncode=None, launch_error=type(error).__name__)
        result = None
    else:
        stdout, stderr = result.stdout, result.stderr
        entry["returncode"] = result.returncode
    log.write_text(stdout + stderr)
    stdout_path, stderr_path = Path(str(log) + ".stdout"), Path(str(log) + ".stderr")
    stdout_path.write_text(stdout)
    stderr_path.write_text(stderr)
    entry.update(stdout_sha256=sha(stdout_path), stderr_sha256=sha(stderr_path))
    if history is not None:
        history.append(entry)
    if result is None or result.returncode != expect:
        print(log.read_text(), file=sys.stderr)
        raise RuntimeError(f"exit {entry['returncode']}, expected {expect}: {command}")
    return result


def build(source, output, env, dotnet, run):
    run([dotnet, "build", str(HERE / "WsiTests.csproj"), "-c", "Release",
         "--artifacts-path", str(output), "--configfile", str(HERE / "NuGet.Config"),
         "-p:NuGetAudit=false", f"-p:WsiSource={source}"], output.parent / "build.log", env)
    dll = output / "bin/WsiTests/release/WsiTests.dll"
    inputs = {str(p.relative_to(MODULE)): sha(source / p.name if p.parent == MODULE else p)
              for p in MANAGED}
    artifacts = {p.name: sha(p) for p in [dll, dll.with_suffix(".deps.json"),
                                         dll.with_suffix(".runtimeconfig.json")]}
    atomic_json(dll.parent / "wsi-source.json", {"inputs": inputs, "artifacts": artifacts})
    return dll


def execute(args, output, report):
    linux = platform.system() == "Linux"
    if args.require_native and not linux:
        raise ValueError("the unchanged production pthread lease requires Linux; no clock shim is used")
    if args.prebuilt and args.negative_controls:
        raise ValueError("negative controls rebuild source; do not combine with --prebuilt")
    env = os.environ.copy()
    env.update(DOTNET_CLI_HOME=str(output / "dotnet-home"), DOTNET_NOLOGO="1",
               DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1", DOTNET_CLI_TELEMETRY_OPTOUT="1",
               NUGET_PACKAGES=str(output / "packages"))
    dotnet = os.environ.get("DOTNET", "dotnet")
    compiler = os.environ.get("CC", "cc")
    fixture = HERE / "lease_fixture.c"
    run = functools.partial(call, history=report["commands"])
    common = [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(NATIVE)]
    sources = [MODULE / "RetirementLedger.cs", MODULE / "NativeLease.cs", MODULE / "README.md", fixture,
               HERE / "Program.cs", HERE / "WsiTests.csproj", HERE / "NuGet.Config", Path(__file__),
               NATIVE / "wsi_lease.c", NATIVE / "wsi_lease.h"]
    report["source_sha256"] = {str(p.relative_to(REPO)): sha(p) for p in sources}
    report["stage"] = "c_header_abi"
    run(common + ["-DLAYOUT_ONLY", str(fixture), "-o", str(output / "abi-layout")],
        output / "abi-build.log", env)
    run([str(output / "abi-layout")], output / "abi-layout.txt", env)
    report["stage"] = "managed_build_or_prebuilt_identity"
    dll = args.prebuilt.resolve() if args.prebuilt else build(MODULE, output / "dotnet", env, dotnet, run)
    identity = json.loads((dll.parent / "wsi-source.json").read_text())
    if identity["inputs"] != {str(p.relative_to(MODULE)): sha(p) for p in MANAGED} or \
            identity["artifacts"] != {p.name: sha(p) for p in
                                      [dll, dll.with_suffix(".deps.json"), dll.with_suffix(".runtimeconfig.json")]}:
        raise RuntimeError("prebuilt assembly/source identity mismatch; rebuild the frozen sources")
    report.update(managed_dll_sha256=sha(dll), managed_dll=str(dll),
                  managed_identity_sha256=sha(dll.parent / "wsi-source.json"))
    command = [dotnet, str(dll), str(output / "abi-layout.txt")]
    if linux:
        report["stage"] = "native_lease_build"
        shared = output / "libwsi_lease_fixture.so"
        run(common + ["-D_POSIX_C_SOURCE=200809L", "-fPIC", "-shared", "-pthread",
                      str(NATIVE / "wsi_lease.c"), str(fixture), "-o", str(shared)],
            output / "native-build.log", env)
        command.append(str(shared))
    report["stage"] = "host_tests"
    result = run(command, output / "tests.log", env)
    print(result.stdout, end="")
    report["native_lease"] = "PASS" if linux else "NOT RUN: Linux required"
    report["tests_log_sha256"] = sha(output / "tests.log")
    mutations = report["negative_controls"]
    if args.negative_controls:
        report["stage"] = "negative_controls"
        original = (MODULE / "RetirementLedger.cs").read_text()
        controls = {
            "submit-is-not-present": (
                "record.SubmitDone = true;",
                "record.SubmitDone = true; record.PresentDone = true;"),
            "image-not-frame-slot": (
                "AcquireRecord? previous = record.Swapchain.Images[image];",
                "AcquireRecord? previous = record.Swapchain.Images[0];"),
        }
        for name, (before, after) in controls.items():
            if original.count(before) != 1:
                raise RuntimeError(f"negative-control anchor changed: {name}")
            directory = output / name
            directory.mkdir()
            (directory / "RetirementLedger.cs").write_text(original.replace(before, after))
            shutil.copyfile(MODULE / "NativeLease.cs", directory / "NativeLease.cs")
            broken = build(directory, directory / "dotnet", env, dotnet, run)
            run([dotnet, str(broken), str(output / "abi-layout.txt")], directory / "tests.log", env, expect=1)
            mutations[name] = {"expected_exit": 1, "log": str((directory / "tests.log").relative_to(output)),
                               "source_sha256": sha(directory / "RetirementLedger.cs")}
            print(f"negative control {name}: expected FAIL")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prebuilt", type=Path, help="previously built AnyCPU WsiTests.dll")
    parser.add_argument("--require-native", action="store_true", help="fail unless real Linux lease runs")
    parser.add_argument("--negative-controls", action="store_true", help="compile two broken ledger copies; SDK required")
    parser.add_argument("--output-root", type=Path, help="private receipt root; default module build/<host>")
    args = parser.parse_args()
    root = (args.output_root or MODULE / "build" / platform.system().lower()).resolve()
    root.mkdir(parents=True, exist_ok=True)
    attempt = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ-") + uuid.uuid4().hex[:12]
    output = root / "attempts" / attempt
    output.mkdir(parents=True)
    report = {"schema": 1, "attempt_id": attempt, "attempt_dir": str(output),
              "started_utc": datetime.now(timezone.utc).isoformat(), "status": "RUNNING",
              "host": platform.platform(), "native_lease": "NOT RUN", "gpu": "NOT RUN",
              "production_renderer_connected": False, "commands": [], "negative_controls": {},
              "stage": "preflight"}
    # The current pointer loses any preceding PASS before a compiler or identity check starts.
    publish(root, output, report, starting=True)
    exit_code = 1
    try:
        execute(args, output, report)
        report.update(status="PASS", stage="complete")
        exit_code = 0
    except BaseException as error:
        report.update(status="FAIL", error={"type": type(error).__name__, "message": str(error)})
        (output / "failure.log").write_text(traceback.format_exc())
        print(traceback.format_exc(), file=sys.stderr, end="")
    finally:
        report["finished_utc"] = datetime.now(timezone.utc).isoformat()
        publish(root, output, report)
        print(f"evidence: {output / 'result.json'}")
        print(f"current: {root / 'result.json'}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
