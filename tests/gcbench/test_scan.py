#!/usr/bin/env python3
"""Offline regression checks for evidence accounting, not timing assertions."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from scan import summarize
from review_scan import control_summary


class AccountingTests(unittest.TestCase):
    def fixture(self):
        return {
            "collections": [{"index": 2, "generation": 2, "concurrent": False,
                "compacted": True, "pause0_ms": 6.0, "pause1_ms": 7.0,
                "before_bytes": 100, "after_bytes": 97}],
            "status": "ok", "count0": 1, "count1": 1, "count2": 1,
            "record_overflow": 0, "total_pause_ms": 13, "peak_virtual_bytes": 1024,
            "initial_virtual_bytes": 1024, "peak_resident_bytes": 512,
            "peak_private_untagged_bytes": 512,
            "observer_allocated_bytes": 0, "allocated_bytes": 1024,
            "forced_measured_collections": 0, "completed_frames": 10, "elapsed_s": 1,
        }

    def test_individual_pause_is_not_sum_of_two_stops(self):
        r = summarize(self.fixture())
        self.assertEqual(r["max_pause_ms"], 7)
        self.assertEqual(r["max_gc_pause_sum_ms"], 13)
        self.assertTrue(r["complete"])
        self.assertEqual(r["near_unchanged_compactions"], 1)

    def test_missing_gen2_invalidates_small_observed_maximum(self):
        d = self.fixture()
        d["count0"] = d["count1"] = d["count2"] = 2
        r = summarize(d)
        self.assertFalse(r["complete"])
        self.assertEqual(r["missing_gen2"], 1)

    def test_missing_ephemeral_also_invalidates_coverage(self):
        d = self.fixture()
        d["count0"] += 1
        self.assertFalse(summarize(d)["complete"])

    def test_overflow_and_oom_do_not_pass(self):
        d = self.fixture()
        d["record_overflow"] = 1
        self.assertFalse(summarize(d)["complete"])
        d["record_overflow"] = 0
        d["status"] = "oom"
        self.assertFalse(summarize(d)["complete"])

    def test_duplicate_gc_index_rejected(self):
        d = self.fixture()
        d["collections"].append(copy.deepcopy(d["collections"][0]))
        with self.assertRaises(ValueError):
            summarize(d)

    def test_cross_kind_collision_reconciles_counts_and_total_pause(self):
        d = self.fixture()
        stale = copy.deepcopy(d["collections"][0])
        stale.update(concurrent=True, pause0_ms=0.1, pause1_ms=0.2)
        d["collections"].append(stale)
        r = summarize(d)
        self.assertTrue(r["complete"])
        self.assertEqual(r["cross_kind_collisions"], 1)
        self.assertEqual(r["blocking_compacting"], 1)
        self.assertEqual(r["background"], 0)

    def test_incompatible_cross_kind_collision_rejected(self):
        d = self.fixture()
        other = copy.deepcopy(d["collections"][0])
        other.update(generation=0, compacted=False)
        d["collections"].append(other)
        with self.assertRaises(ValueError):
            summarize(d)

    def test_unattributed_pause_keeps_conservative_upper_bound(self):
        d = self.fixture()
        d["total_pause_ms"] += 5
        r = summarize(d)
        self.assertEqual(r["max_pause_upper_ms"], 12)
        self.assertEqual(r["unattributed_pause_ms"], 5)

    def test_snapshot_pause_overcount_does_not_pass(self):
        d = self.fixture()
        d["total_pause_ms"] = 3
        self.assertFalse(summarize(d)["complete"])

    def test_background_and_blocking_types_stay_distinct(self):
        d = self.fixture()
        d["collections"][0]["concurrent"] = True
        r = summarize(d)
        self.assertEqual(r["background"], 1)
        self.assertEqual(r["blocking_compacting"], 0)
        self.assertEqual(r["near_unchanged_compactions"], 0)

    def test_gen1_only_does_not_include_gen2_promotion(self):
        d = self.fixture()
        event = copy.deepcopy(d["collections"][0])
        event.update(index=3, generation=1, pause0_ms=4, pause1_ms=0)
        d["collections"].append(event)
        d.update(count0=2, count1=2, total_pause_ms=17)
        r = summarize(d)
        self.assertTrue(r["complete"])
        self.assertEqual(r["observed_gen1_only"], 1)
        self.assertEqual(r["max_gen1_pause_ms"], 4)

    def test_invalid_forced_preparation_is_not_a_gen1_result(self):
        t = {"valid": False, "generation": 1, "count0": 1, "count1": 1, "count2": 0}
        d = {"gen1_trials": [t], "status": "ok", "epochs": 1,
             "forced_measured_collections": 3, "peak_virtual_bytes": 1,
             "peak_resident_bytes": 1, "peak_private_untagged_bytes": 1,
             "peak_gc_committed_bytes": 1, "old_allocated_bytes": 1}
        r = control_summary(d)
        self.assertFalse(r["complete"])
        self.assertEqual(r["valid_gen1_trials"], 0)

    def test_generation_upgrade_cannot_pass_gen1_control(self):
        t = {"valid": True, "generation": 2, "count0": 1, "count1": 1, "count2": 1}
        d = {"gen1_trials": [t], "status": "ok", "epochs": 1,
             "forced_measured_collections": 3, "peak_virtual_bytes": 1,
             "peak_resident_bytes": 1, "peak_private_untagged_bytes": 1,
             "peak_gc_committed_bytes": 1, "old_allocated_bytes": 1}
        self.assertFalse(control_summary(d)["complete"])

    def test_runner_preserves_failed_exit_with_invalid_json(self):
        # Fault-inject the subprocess protocol only; this is not GC evidence.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            exe = root / "broken"
            exe.write_text("#!/usr/bin/env python3\nimport sys\nprint('broken JSON')\nsys.exit(7)\n")
            exe.chmod(0o700)
            out = root / "results"
            p = subprocess.run([sys.executable, str(Path(__file__).with_name("scan.py")),
                "--exe", str(exe), "--out", str(out), "--cases", "seg32",
                "--frames", "1", "--repeats", "1"], capture_output=True, text=True)
            self.assertEqual(p.returncode, 1)
            row = json.loads((out / "summary.json").read_text())[0]
            self.assertEqual(row["exit_code"], 7)
            self.assertFalse(row["complete"])
            self.assertEqual(row["status"], "invalid_output")


if __name__ == "__main__":
    unittest.main()
