"""Offline integration test using real NativeAOT allocations and LLDB.

python3 tests/aot_heap/verify.py --dotnet /path/to/dotnet --nuget-packages /path/to/packages
Pass --binary /path/to/HeapFixture to reuse this fixture's existing AOT publish.
The SDK, NativeAOT 10.0.12 NuGet packages and LLDB must already be installed.
No package sources are enabled and no game or device is used.
Native linker search settings (for example LIBRARY_PATH) are inherited.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def verify_slots(data, expected_nodes):
    require(data["schema"] == 2, "Reference-slot metadata requires snapshot schema 2")
    rows = data["types"]
    # These totals follow the fixture's fields and lengths, including every null
    # slot. They do not depend on GCDesc's encoding or on counting non-null values.
    expected = {"AuditNode": (expected_nodes, expected_nodes * 2),
                "AuditReferences": (1, 10), "AuditTarget": (4, 9),
                "AuditMixed": (3, 2 + 5 * 2 + 2 * 3 * 2),
                "AuditAllReferences": (1, 7 * 2), "AuditFields": (1, 2)}
    for name, (count, slots) in expected.items():
        matching = [row for row in rows if row["typeNameConfirmed"] and name in row["typeName"]]
        require(sum(row["count"] for row in matching) == count, f"Wrong real allocation count for {name}")
        require(sum(row["gcReferenceSlots"] for row in matching) == slots, f"Wrong GC reference slots for {name}")
    for marker, slots in (("__Array<HeapFixture_AuditMixed>", 10),
                          ("__MDArray<HeapFixture_AuditMixed,2>", 12),
                          ("Boxed_HeapFixture_AuditMixed", 2)):
        matching = [row for row in rows if row["typeNameConfirmed"] and marker in row["typeName"]]
        require(len(matching) == 1 and matching[0]["count"] == 1 and matching[0]["gcReferenceSlots"] == slots,
                f"Wrong GC reference slots for {marker}")
    for name in ("vtable for __Array<UInt8>", "vtable for __Array<Int32>", "vtable for String"):
        matching = [row for row in rows + data["frozenTypes"] if row["typeNameConfirmed"] and row["typeName"] == name]
        require(matching and all(row["gcReferenceSlots"] == 0 for row in matching), f"Expected confirmed zero-reference type: {name}")


def run_lldb(tool, binary, directory, max_objects, stop_after=0):
    snapshots = directory / "snapshots"
    exit_path = directory / "exit.json"
    commands = directory / "commands.lldb"
    # LLDB only interprets these commands; subprocess never invokes a shell.
    commands.write_text("\n".join([
        "settings set target.disable-aslr false",
        f"command script import {shlex.quote(str(tool))}",
        # Import alone must not install the census breakpoint.
        "script assert lldb.debugger.GetSelectedTarget().GetNumBreakpoints() == 0",
        f"aot-heap --output {shlex.quote(str(snapshots))} --runtime-version 10.0.12 --max-objects {max_objects} --stop-after {stop_after}",
        "run",
        "script import json; p = lldb.debugger.GetSelectedTarget().GetProcess(); "
        f"open({str(exit_path)!r}, 'x').write(json.dumps(dict(state=p.GetState(), exitStatus=p.GetExitStatus(), exited=p.GetState()==lldb.eStateExited, stopped=p.GetState()==lldb.eStateStopped)))",
        "",
    ]), encoding="utf-8")
    completed = subprocess.run(["lldb", "-x", "--batch", "-s", str(commands), str(binary)],
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    (directory / "lldb.log").write_text(completed.stdout, encoding="utf-8")
    require(completed.returncode == 0, f"LLDB failed: {directory / 'lldb.log'}")
    require(exit_path.exists(), f"Missing process exit evidence: {directory / 'lldb.log'}")
    return snapshots, json.loads(exit_path.read_text(encoding="utf-8"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dotnet", default="dotnet")
    parser.add_argument("--nuget-packages", type=Path)
    parser.add_argument("--binary", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    build = repo / "build"
    build.mkdir(exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="aot-heap-test-", dir=build))
    binary = args.binary.resolve() if args.binary else output / "publish" / "HeapFixture"
    if not args.binary:
        require(platform.system() == "Darwin" and platform.machine() == "arm64", "Publishing is tested only on macOS arm64")
        config = ET.Element("configuration")
        ET.SubElement(ET.SubElement(config, "packageSources"), "clear")
        config_path = output / "NuGet.Config"
        ET.ElementTree(config).write(config_path, encoding="utf-8", xml_declaration=True)
        env = os.environ.copy()
        if args.nuget_packages:
            env["NUGET_PACKAGES"] = str(args.nuget_packages.resolve())
        command = [args.dotnet, "publish", str(Path(__file__).with_name("HeapFixture.csproj")),
                   "-c", "Release", "-r", "osx-arm64", "--configfile", str(config_path),
                   "-p:BaseIntermediateOutputPath=" + str(output / "obj") + "/",
                   "-p:BaseOutputPath=" + str(output / "bin") + "/",
                   "-o", str(output / "publish")]
        completed = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        (output / "publish.log").write_text(completed.stdout, encoding="utf-8")
        require(completed.returncode == 0, f"Offline publish failed: {output / 'publish.log'}")
    require(binary.is_file(), f"Fixture executable is missing: {binary}")
    success = output / "success"
    success.mkdir()
    snapshots, status = run_lldb(repo / "tools" / "aot_heap.py", binary, success, 10000000)
    require(status["exited"] and status["exitStatus"] == 0, f"Fixture did not exit successfully: {status}")
    require(not list(snapshots.glob("failure-*.json")), "Census reported a failure")
    files = sorted(snapshots.glob("heap-*.json"))
    require(len(files) == 3, f"Expected three snapshots, got {len(files)}")
    previous_index = 0
    success_files = files
    for path, expected in zip(files, (100, 150, 0)):
        data = json.loads(path.read_text(encoding="utf-8"))
        verify_slots(data, expected)
        require(data["status"] == "complete" and data["generation"] == 2 and not data["concurrent"] and not data["backgroundRunning"], "Invalid snapshot boundary")
        require(data["gcIndex"] > previous_index, "GC indexes are not increasing")
        previous_index = data["gcIndex"]
        rows = data["types"]
        nodes = [row for row in rows if row["typeNameConfirmed"] and "AuditNode" in row["typeName"]]
        require(sum(row["count"] for row in nodes) == expected, f"Wrong node count in {path}")
        require(sum(row["shallowBytes"] for row in nodes) == expected * 32, f"Wrong node size in {path}")
        arrays = [row for row in rows if row["typeNameConfirmed"] and row["typeName"] == "vtable for __Array<UInt8>"]
        payloads = [size for row in arrays for size in row["sizeHistogram"] if size["shallowBytes"] == 1024]
        require(sum(size["count"] for size in payloads) == expected, f"Wrong byte[1000] count in {path}")
        require(any(segment["frozen"] for segment in data["segments"]) and data["frozenTypes"], "Frozen objects were not separately reported")
        require(all("firstGenerationChain" in segment and "generation" not in segment for segment in data["segments"]), "Segment chain was mislabeled as object generation")
    completed = subprocess.run(["python3", str(repo / "tools" / "aot_heap_summary.py"),
                                *(str(path) for path in success_files), "--top", "100000"],
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    summary_path = success / "summary.json"
    summary_path.write_text(completed.stdout, encoding="utf-8")
    summary = json.loads(completed.stdout)
    for sample, path in zip(summary["samples"], success_files):
        data = json.loads(path.read_text(encoding="utf-8"))
        require(sample["dynamicGcReferenceSlots"] == sum(row["gcReferenceSlots"] for row in data["types"]), "Summary dynamic slot total differs from real snapshot")
        require(sample["frozenGcReferenceSlots"] == sum(row["gcReferenceSlots"] for row in data["frozenTypes"]), "Summary frozen slot total differs from real snapshot")
    roots = [row for row in summary["topTypes"] if row["typeNameConfirmed"] and "AuditReferences" in row["typeName"]]
    require(len(roots) == 1 and roots[0]["gcReferenceSlots"] == [10, 10, 10] and roots[0]["deltaGcReferenceSlots"] == 0, "Summary did not preserve real reference-slot history")
    stopped = output / "stop-after"
    stopped.mkdir()
    snapshots, status = run_lldb(repo / "tools" / "aot_heap.py", binary, stopped, 10000000, stop_after=1)
    require(status["stopped"] and not status["exited"], f"--stop-after 1 did not leave the target stopped: {status}")
    files = sorted(snapshots.glob("heap-*.json"))
    require(len(files) == 1 and not list(snapshots.glob("failure-*.json")), "--stop-after 1 did not publish exactly one complete snapshot")
    data = json.loads(files[0].read_text(encoding="utf-8"))
    verify_slots(data, 100)
    require(data["status"] == "complete" and data["generation"] == 2 and not data["concurrent"] and not data["backgroundRunning"], "--stop-after sampled an invalid GC boundary")
    nodes = [row for row in data["types"] if row["typeNameConfirmed"] and "AuditNode" in row["typeName"]]
    require(sum(row["count"] for row in nodes) == 100 and sum(row["shallowBytes"] for row in nodes) == 3200, "--stop-after 1 did not stop at the first real fixture stage")
    failure = output / "failure"
    failure.mkdir()
    snapshots, status = run_lldb(repo / "tools" / "aot_heap.py", binary, failure, 1)
    failures = list(snapshots.glob("failure-*.json"))
    require(status["stopped"] and not status["exited"], "Failure callback did not leave the target stopped")
    require(len(failures) == 1 and not list(snapshots.glob("heap-*.json")), "Failure published a partial success or omitted failure evidence")
    data = json.loads(failures[0].read_text(encoding="utf-8"))
    require(data["status"] == "failed" and data["targetRemainsStopped"] and "Object limit exceeded" in data["error"], "Wrong failure evidence")
    print(f"PASS: real NativeAOT objects 100 -> 150 -> 0; node=32 B/2 slots, byte[1000]=1024 B/0 slots; null/reference arrays, mixed/all-reference struct arrays, boxed structs, multidimensional arrays, split fields and strings; summary slot totals/history; --stop-after 1 publishes one snapshot and stops; failure stops target. Evidence: {output}")


if __name__ == "__main__":
    main()
