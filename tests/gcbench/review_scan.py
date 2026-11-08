#!/usr/bin/env python3
"""K02 review matrix: serial fresh processes, natural runs and forced controls apart."""
import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time
from scan import BASE, digest, summarize, write_results, MIB


def control_summary(data):
    trials = data["gen1_trials"]
    valid = [t for t in trials if t["valid"] and t["generation"] == 1
             and t["count0"] == t["count1"] == 1 and t["count2"] == 0]
    pauses = [max(t["pause0_ms"], t["pause1_ms"]) for t in valid]
    return {
        "status": data["status"], "complete": (len(valid) == data["epochs"] == len(trials)
            and len({t["index"] for t in valid}) == len(valid)),
        "valid_gen1_trials": len(valid), "invalid_gen1_trials": len(trials) - len(valid),
        "max_gen1_pause_ms": max(pauses, default=0),
        "median_gen1_pause_ms": statistics.median(pauses) if pauses else 0,
        "min_promoted_mib": min((t["promoted_bytes"] / MIB for t in valid), default=0),
        "max_promoted_mib": max((t["promoted_bytes"] / MIB for t in valid), default=0),
        "min_gen2_before_mib": min((t["gen2_before_bytes"] / MIB for t in valid), default=0),
        "max_gen2_before_mib": max((t["gen2_before_bytes"] / MIB for t in valid), default=0),
        "forced_measured_collections": data["forced_measured_collections"],
        **{k.removesuffix("_bytes") + "_mib": data[k] / MIB for k in (
            "peak_virtual_bytes", "peak_resident_bytes", "peak_private_untagged_bytes",
            "peak_gc_committed_bytes", "old_allocated_bytes")},
    }


def cases(phase, frames, frame_us):
    if phase in ("large", "paced"):
        common = ["--frames", str(frames), "--frame-us", str(frame_us)]
        return [(mode, {**BASE}, common + ["--large-mode", mode])
                for mode in ("managed", "transient-native", "all-native")] + [
            ("default_loh8", {"DOTNET_GCLOHThreshold": "800000"}, common)]
    if phase == "refs":
        return [(f"old{old}_young{young}_refs{refs}",
                 {"DOTNET_GCSegmentSize": "10000000", "DOTNET_GCgen0size": "4000000"},
                 ["--reference-control", "--old-mib", str(old), "--young-mib", str(young),
                  "--references", str(refs), "--epochs", "12"])
                for old in (64, 150, 256) for young in (4, 16, 24)
                for refs in (0, 1024, 65536, 524288)]
    budgets = {
        "default": BASE,
        "gen0_8": {**BASE, "DOTNET_GCgen0size": "800000"},
        "gen0_32": {**BASE, "DOTNET_GCgen0size": "2000000"},
        "gen0_64": {**BASE, "DOTNET_GCgen0size": "4000000"},
        # Deliberate negative control: no Gen1Size key in .NET 10.0.9.
        "gen1size_requested64": {**BASE, "DOTNET_GCgen1size": "4000000"},
        "gen1max8": {**BASE, "DOTNET_GCGen1MaxBudget": "800000"},
        "gen1max4": {**BASE, "DOTNET_GCGen1MaxBudget": "400000"},
        "gen1max1": {**BASE, "DOTNET_GCGen1MaxBudget": "100000"},
    }
    return [(f"{name}_refs{refs}", env,
             ["--reference-natural", "--old-mib", "150", "--young-mib", "16",
              "--references", str(refs), "--epochs", "120"])
            for name, env in budgets.items() for refs in (0, 65536, 524288)]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--exe", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--phase", choices=("large", "paced", "refs", "budgets"), required=True)
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--frames", type=int, default=30000)
    p.add_argument("--frame-us", type=int, default=1000)
    p.add_argument("--only", help="comma-separated exact case names for explicit pilots")
    a = p.parse_args()
    if not 1 <= a.repeats <= 10:
        p.error("repeats 1..10 required")
    exe = a.exe.resolve(strict=True)
    selected = cases(a.phase, a.frames, a.frame_us)
    if a.only:
        names = a.only.split(",")
        if not set(names) <= {c[0] for c in selected} or len(names) != len(set(names)):
            p.error("unknown/duplicate case")
        selected = [c for c in selected if c[0] in names]
    a.out.mkdir(parents=True, exist_ok=False)
    env = {k: v for k, v in os.environ.items()
           if not k.lower().startswith(("dotnet_gc", "complus_gc")) and k != "S2A_GCBENCH_LATENCY"}
    manifest = {"utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "phase": a.phase, "platform": platform.platform(), "repeats": a.repeats,
                "executable_sha256": digest(exe),
                "source_sha256": {f.name: digest(f) for f in sorted(Path(__file__).parent.iterdir()) if f.is_file()},
                "cases": {name: {"environment": config, "arguments": args} for name, config, args in selected},
                "ambient_gc_keys_removed": sorted(set(os.environ) - set(env))}
    (a.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    rows = []
    for repeat in range(1, a.repeats + 1):
        for name, config, args in selected:
            stem = a.out / f"{name}-{repeat}"
            row = {"case": name, "repeat": repeat, "phase": a.phase}
            try:
                with stem.with_suffix(".json").open("wb") as stdout, stem.with_suffix(".stderr").open("wb") as stderr:
                    result = subprocess.run([str(exe), *args], env={**env, **config},
                                            stdout=stdout, stderr=stderr, timeout=300)
                row["exit_code"] = result.returncode
                data = json.loads(stem.with_suffix(".json").read_text())
                row.update(control_summary(data) if a.phase == "refs" else summarize(data))
                expected = int(args[args.index("--frames") + 1]) if "--frames" in args else int(args[-1])
                row["complete"] &= (result.returncode == 0 and data["native_aot"]
                                    and not data["server_gc"] and data["completed_frames"] == expected)
                if a.phase != "refs" and data["forced_measured_collections"] != 0:
                    row.update(status="unexpected_forced_collection", complete=False)
                row["effective_config"] = json.dumps(data["effective_config"], sort_keys=True)
            except subprocess.TimeoutExpired:
                row.update(status="timeout", complete=False)
            except (ValueError, KeyError) as e:
                row.update(status="invalid_output", complete=False, error=str(e))
            row["raw_sha256"] = digest(stem.with_suffix(".json"))
            rows.append(row)
            # Shared writer expects natural-run fields only for its optional table.
            write_results(a.out, rows)
            print(json.dumps({k: v for k, v in row.items() if k != "effective_config"}), flush=True)
    return 0 if all(r["complete"] for r in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
