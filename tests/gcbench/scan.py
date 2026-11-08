#!/usr/bin/env python3
"""Sequential, isolated NativeAOT GC scan. Standard library only; never uses game data."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import time
from accounting import canonical_collections

MIB = 1 << 20
BASE = {"DOTNET_GCSegmentSize": "2000000"}
# All numeric GC environment values are hexadecimal, including gen0 / hard limit.
CASES = {
    "seg32": BASE,
    "default_segment": {},
    "seg64": {"DOTNET_GCSegmentSize": "4000000"},
    "seg128": {"DOTNET_GCSegmentSize": "8000000"},
    "seg32_gen0_8": {**BASE, "DOTNET_GCgen0size": "800000"},
    "seg32_gen0_32": {**BASE, "DOTNET_GCgen0size": "2000000"},
    "seg32_gen0_64": {**BASE, "DOTNET_GCgen0size": "4000000"},
    "seg32_conserve1": {**BASE, "DOTNET_GCConserveMemory": "1"},
    "seg32_conserve5": {**BASE, "DOTNET_GCConserveMemory": "5"},
    "seg32_conserve9": {**BASE, "DOTNET_GCConserveMemory": "9"},
    "seg32_conserve7": {**BASE, "DOTNET_GCConserveMemory": "7"},
    "seg32_conserve9_gen0_32": {**BASE, "DOTNET_GCConserveMemory": "9", "DOTNET_GCgen0size": "2000000"},
    "seg32_conserve9_gen0_64": {**BASE, "DOTNET_GCConserveMemory": "9", "DOTNET_GCgen0size": "4000000"},
    "server4_control": {**BASE, "DOTNET_gcServer": "1", "DOTNET_GCHeapCount": "4"},
    "seg32_retain": {**BASE, "DOTNET_GCRetainVM": "1"},
    "seg32_gen0_32_retain": {**BASE, "DOTNET_GCgen0size": "2000000", "DOTNET_GCRetainVM": "1"},
    "seg64_gen0_32": {"DOTNET_GCSegmentSize": "4000000", "DOTNET_GCgen0size": "2000000"},
    "seg64_conserve7": {"DOTNET_GCSegmentSize": "4000000", "DOTNET_GCConserveMemory": "7"},
    "seg64_conserve9": {"DOTNET_GCSegmentSize": "4000000", "DOTNET_GCConserveMemory": "9"},
    "seg128_conserve7": {"DOTNET_GCSegmentSize": "8000000", "DOTNET_GCConserveMemory": "7"},
    "seg128_conserve9": {"DOTNET_GCSegmentSize": "8000000", "DOTNET_GCConserveMemory": "9"},
    "seg32_sustained": {**BASE, "S2A_GCBENCH_LATENCY": "sustained"},
    "seg32_conserve7_sustained": {**BASE, "DOTNET_GCConserveMemory": "7", "S2A_GCBENCH_LATENCY": "sustained"},
    "seg32_conserve9_sustained": {**BASE, "DOTNET_GCConserveMemory": "9", "S2A_GCBENCH_LATENCY": "sustained"},
    "seg32_loh2": {**BASE, "DOTNET_GCLOHThreshold": "200000"},
    "seg32_loh4": {**BASE, "DOTNET_GCLOHThreshold": "400000"},
    "seg32_loh8": {**BASE, "DOTNET_GCLOHThreshold": "800000"},
    "seg64_loh8": {"DOTNET_GCSegmentSize": "4000000", "DOTNET_GCLOHThreshold": "800000"},
    "seg128_loh8": {"DOTNET_GCSegmentSize": "8000000", "DOTNET_GCLOHThreshold": "800000"},
    "default_loh8": {"DOTNET_GCLOHThreshold": "800000"},
    "seg32_loh8_sustained": {**BASE, "DOTNET_GCLOHThreshold": "800000", "S2A_GCBENCH_LATENCY": "sustained"},
    "seg32_loh8_conserve9": {**BASE, "DOTNET_GCLOHThreshold": "800000", "DOTNET_GCConserveMemory": "9"},
    "seg32_loh8_conserve5": {**BASE, "DOTNET_GCLOHThreshold": "800000", "DOTNET_GCConserveMemory": "5"},
    "seg32_loh8_conserve7": {**BASE, "DOTNET_GCLOHThreshold": "800000", "DOTNET_GCConserveMemory": "7"},
    "seg64_loh8_conserve9": {"DOTNET_GCSegmentSize": "4000000", "DOTNET_GCLOHThreshold": "800000", "DOTNET_GCConserveMemory": "9"},
    "seg128_loh8_conserve9": {"DOTNET_GCSegmentSize": "8000000", "DOTNET_GCLOHThreshold": "800000", "DOTNET_GCConserveMemory": "9"},
    "compiled_server4_seg16": {"DOTNET_GCHeapCount": "4", "DOTNET_GCSegmentSize": "1000000"},
    "compiled_server4_seg16_loh8": {"DOTNET_GCHeapCount": "4", "DOTNET_GCSegmentSize": "1000000", "DOTNET_GCLOHThreshold": "800000"},
    "compiled_server8_seg8_loh8": {"DOTNET_GCHeapCount": "8", "DOTNET_GCSegmentSize": "800000", "DOTNET_GCLOHThreshold": "800000"},
    "compiled_server4_seg32_loh8": {"DOTNET_GCHeapCount": "4", "DOTNET_GCSegmentSize": "2000000", "DOTNET_GCLOHThreshold": "800000"},
    # Capability negative control: Apple builds disable USE_REGIONS at compile time.
    "region_request_unsupported": {**BASE, "DOTNET_GCRegionSize": "400000", "DOTNET_GCRegionRange": "80000000"},
    "batch_control": {**BASE, "DOTNET_gcConcurrent": "0"},
}


def summarize(data):
    """Exact counts come from CollectionCount; types and pauses from deduplicated snapshots."""
    events, collisions = canonical_collections(data)
    g2 = [e for e in events if e["generation"] == 2]
    g1 = [e for e in events if e["generation"] == 1]
    slow_g1 = max(g1, key=lambda e: max(e["pause0_ms"], e["pause1_ms"]), default=None)
    compact = [e for e in g2 if not e["concurrent"] and e["compacted"]]
    bg = sum(e["concurrent"] for e in g2)
    missing = data["count0"] - len(events)
    missing2 = data["count2"] - len(g2)
    missing1 = data["count1"] - sum(e["generation"] >= 1 for e in events)
    pause_delta = data["total_pause_ms"] - sum(e["pause0_ms"] + e["pause1_ms"] for e in events)
    complete = (data["status"] == "ok" and missing == 0 and missing1 == 0 and missing2 == 0
                and pause_delta >= -0.01
                and data["record_overflow"] == 0)
    max_pause = max((max(e["pause0_ms"], e["pause1_ms"]) for e in events), default=0)
    # A maximum with incomplete observations is a lower bound, never a pass.
    return {
        "status": data["status"], "complete": complete,
        "count0": data["count0"], "count1": data["count1"], "count2": data["count2"],
        "observed_gen2": len(g2), "background": bg, "blocking_compacting": len(compact),
        "blocking_noncompacting": len(g2) - bg - len(compact),
        "missing_gc": missing, "missing_gen2": missing2,
        "missing_gen1": missing1, "cross_kind_collisions": collisions,
        "unattributed_pause_ms": max(pause_delta, 0),
        "max_pause_ms": max_pause,
        "max_pause_upper_ms": max_pause + max(pause_delta, 0),
        "max_gen2_pause_ms": max((max(e["pause0_ms"], e["pause1_ms"]) for e in g2), default=0),
        "observed_gen1_only": len(g1),
        "max_gen1_pause_ms": max((max(e["pause0_ms"], e["pause1_ms"]) for e in g1), default=0),
        "slowest_gen1_promoted_mib": slow_g1.get("promoted_bytes", 0) / MIB if slow_g1 else 0,
        "slowest_gen1_gen2_before_mib": slow_g1.get("gen2_before_bytes", 0) / MIB if slow_g1 else 0,
        "max_gen0_pause_ms": max((max(e["pause0_ms"], e["pause1_ms"]) for e in events if e["generation"] == 0), default=0),
        "max_gc_pause_sum_ms": max((e["pause0_ms"] + e["pause1_ms"] for e in events), default=0),
        "near_unchanged_compactions": sum(e["before_bytes"] > 0 and
            e["after_bytes"] / e["before_bytes"] >= 0.95 for e in compact),
        "total_pause_ms": data["total_pause_ms"],
        "peak_virtual_mib": data["peak_virtual_bytes"] / MIB,
        "initial_virtual_mib": data["initial_virtual_bytes"] / MIB,
        "peak_resident_mib": data["peak_resident_bytes"] / MIB,
        "peak_private_untagged_mib": data["peak_private_untagged_bytes"] / MIB,
        "observer_allocated_kib": data["observer_allocated_bytes"] / 1024,
        "allocated_mib": data["allocated_bytes"] / MIB,
        "forced_measured_collections": data["forced_measured_collections"],
        "completed_frames": data["completed_frames"], "elapsed_s": data["elapsed_s"],
        **{k.removesuffix("_bytes") + "_mib": data[k] / MIB for k in (
            "peak_private_untagged_accessible_bytes", "peak_private_untagged_noaccess_bytes",
            "peak_gc_committed_bytes", "peak_native_live_bytes", "native_allocated_bytes") if k in data},
    }


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_results(out, rows):
    (out / "summary.json").write_text(json.dumps(rows, indent=2) + "\n")
    if rows:
        with (out / "summary.csv").open("w", newline="") as f:
            fields = list(dict.fromkeys(k for row in rows for k in row))
            writer = csv.DictWriter(f, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)
    lines = ["| case | repeat | status / coverage | max pause ms | gen2 B/C/N | unchanged C | VM MiB | RSS MiB |",
             "|---|---:|---|---:|---|---:|---:|---:|"]
    for r in rows:
        if "max_pause_ms" not in r:
            lines.append(f'| {r["case"]} | {r["repeat"]} | {r["status"]} | — | — | — | — | — |')
            continue
        lines.append(f'| {r["case"]} | {r["repeat"]} | {r["status"]} / {r["complete"]} '
                     f'| {r["max_pause_ms"]:.3f} | {r["background"]}/{r["blocking_compacting"]}/'
                     f'{r["blocking_noncompacting"]} | {r["near_unchanged_compactions"]} '
                     f'| {r["peak_virtual_mib"]:.1f} | {r["peak_resident_mib"]:.1f} |')
    (out / "table.md").write_text("\n".join(lines) + "\n")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--exe", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True, help="new output directory; never overwritten")
    p.add_argument("--cases", default=",".join(n for n in CASES if not n.startswith("compiled_server")))
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--frames", type=int, default=6000)
    p.add_argument("--frame-us", type=int, default=1000, help="16667 approximates 60 fps; 1000 accelerates")
    p.add_argument("--hard-limit-mib", type=int, default=384, help="0 = unset; proxy, not real address exhaustion")
    p.add_argument("--timeout-s", type=int, default=300)
    p.add_argument("--forced-control", action="store_true")
    p.add_argument("--large-mode", choices=("managed", "transient-native", "all-native"), default="managed")
    a = p.parse_args()
    names = a.cases.split(",")
    if any(n not in CASES for n in names) or len(names) != len(set(names)):
        p.error("unknown or duplicate case")
    if not 1 <= a.repeats <= 20 or not 0 <= a.hard_limit_mib <= 2048:
        p.error("repeats 1..20, hard limit 0..2048 MiB required")
    exe = a.exe.resolve(strict=True)
    a.out.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parent
    env = {k: v for k, v in os.environ.items()
           if not (k.lower().startswith(("dotnet_gc", "complus_gc"))) and k != "S2A_GCBENCH_LATENCY"}
    common = {"DOTNET_GCHeapHardLimit": f"{a.hard_limit_mib * MIB:x}"} if a.hard_limit_mib else {}
    command = [str(exe), "--frames", str(a.frames), "--frame-us", str(a.frame_us), "--large-mode", a.large_mode]
    if a.forced_control:
        command.append("--forced-control")
    manifest = {
        "schema": "s2a.gcbench.scan.v1", "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(), "machine": platform.machine(), "frames": a.frames,
        "frame_us": a.frame_us, "repeats": a.repeats, "hard_limit_mib": a.hard_limit_mib,
        "forced_control": a.forced_control, "executable_sha256": digest(exe),
        "large_mode": a.large_mode,
        "source_sha256": {f.name: digest(f) for f in sorted(root.iterdir()) if f.is_file()},
        "cases": {n: {**common, **CASES[n]} for n in names},
        "ambient_gc_keys_removed": sorted(set(os.environ) - set(env)),
    }
    (a.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    rows = []
    # Round-robin repeats reduce temporal bias; each row is a fresh process.
    for repeat in range(1, a.repeats + 1):
        for name in names:
            stem = a.out / f"{name}-{repeat}"
            row = {"case": name, "repeat": repeat}
            try:
                with stem.with_suffix(".json").open("wb") as stdout, stem.with_suffix(".stderr").open("wb") as stderr:
                    result = subprocess.run(command, env={**env, **common, **CASES[name]},
                                            stdout=stdout, stderr=stderr, timeout=a.timeout_s)
                row["exit_code"] = result.returncode
                data = json.loads(stem.with_suffix(".json").read_text())
                row.update(summarize(data))
                row["complete"] &= result.returncode == 0 and data["completed_frames"] == a.frames
                if CASES[name].get("S2A_GCBENCH_LATENCY") == "sustained" and data["latency_mode"] != "SustainedLowLatency":
                    row.update(status="unsupported_configuration", complete=False)
                if name.startswith("compiled_server") and not data["server_gc"]:
                    row.update(status="unsupported_configuration", complete=False)
            except subprocess.TimeoutExpired:
                row.update(status="timeout", complete=False)
            except (ValueError, KeyError) as e:
                row.update(status="invalid_output", complete=False, error=str(e))
            rows.append(row)
            write_results(a.out, rows)
            print(json.dumps(row), flush=True)
    return 0 if all(r["complete"] for r in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
