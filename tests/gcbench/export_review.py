#!/usr/bin/env python3
# 门禁手动：辅助脚本，复核并导出评审证据（要传 --input 扫描结果 / --output-prefix），本身不是单测
"""Recheck and export synthetic review evidence; never publishes raw host paths/logs."""
import argparse
import csv
import json
from pathlib import Path
from accounting import canonical_collections
from review_scan import control_summary
from scan import digest, summarize, MIB


def write_csv(path, rows):
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, list(dict.fromkeys(k for row in rows for k in row)))
        writer.writeheader()
        writer.writerows(rows)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--input", type=Path, nargs="+", required=True)
    p.add_argument("--output-prefix", type=Path, required=True)
    a = p.parse_args()
    rows, events, receipts = [], [], {}
    for root in a.input:
        manifest = json.loads((root / "manifest.json").read_text())
        records = json.loads((root / "summary.json").read_text())
        expected = len(manifest["cases"]) * manifest["repeats"]
        if len(records) != expected:
            raise ValueError(f"Unfinished phase {root.name}: {len(records)}/{expected}")
        receipts[root.name] = {**manifest, "manifest_sha256": digest(root / "manifest.json")}
        for record in records:
            case, repeat = record["case"], record["repeat"]
            raw = root / f"{case}-{repeat}.json"
            if digest(raw) != record["raw_sha256"]:
                raise ValueError(f"Raw digest changed: {raw.name}")
            row = {"phase": root.name, "case": case, "repeat": repeat,
                   "exit_code": record.get("exit_code", "unrecorded"),
                   "raw_sha256": digest(raw)}
            try:
                data = json.loads(raw.read_text())
                row.update(control_summary(data) if manifest["phase"] == "refs" else summarize(data))
                row["complete"] &= record["complete"] and record.get("exit_code") == 0
                row["effective_gen0_max_mib"] = data["effective_config"]["GCGen0MaxBudget"] / MIB
                row["effective_loh_threshold_bytes"] = data["effective_config"]["LOHThreshold"]
                if manifest["phase"] == "refs":
                    for trial in data["gen1_trials"]:
                        events.append({"phase": root.name, "case": case, "repeat": repeat,
                                       "mode": data["mode"], "references": data["old_to_young_references"], **trial})
                elif manifest["phase"] == "budgets":
                    for event in canonical_collections(data)[0]:
                        if event["generation"] == 1:
                            events.append({"phase": root.name, "case": case, "repeat": repeat,
                                           "mode": data["mode"], "references": data["old_to_young_references"],
                                           **event})
            except (ValueError, KeyError) as e:
                row.update(status="invalid_output", complete=False, error=str(e))
            rows.append(row)
    a.output_prefix.parent.mkdir(parents=True, exist_ok=True)
    write_csv(Path(str(a.output_prefix) + "_results.csv"), rows)
    write_csv(Path(str(a.output_prefix) + "_gen1_events.csv"), events)
    Path(str(a.output_prefix) + "_receipts.json").write_text(json.dumps(receipts, indent=2) + "\n")
    print(f"Exported {len(rows)} runs ({sum(r['complete'] for r in rows)} complete), {len(events)} gen1 records")


if __name__ == "__main__":
    main()
