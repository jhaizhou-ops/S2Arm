#!/usr/bin/env python3
"""Offline J02 behavioral tests. CLI transport doubles are NEVER AI evidence."""
import argparse
from copy import deepcopy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import widen_judge_samples as samples
spec = importlib.util.spec_from_file_location("widen_judge", ROOT / "graphics/widen/scan/judge.py")
judge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(judge)
CACHE = None


class JudgeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sample_dir = CACHE / "samples"
        samples.generate(cls.sample_dir)
        cls.policy = cls.sample_dir / "test-policy.json"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=CACHE)
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.good = self.sample_dir / "correct"

    def run_judge(self, root=None, policy=True, answer=None):
        with patch.dict(os.environ, {"S2A_WIDEN_AI": "1"}):
            with patch.object(judge.shutil, "which", return_value="protocol-double"):
                with patch.object(judge, "call_claude", return_value=(answer, {"state": "missing", "reason": "test_double"})) as call:
                    result, rc = judge.judge(root or self.good, policy=self.policy if policy else None)
        return result, rc, call

    def ai(self):
        _, files, identity = judge.read_evidence(self.good)
        return {"version": judge.VERSION, "input_sha256": identity,
                "checks": {c: {"pass": True, "reason": "protocol double only"} for c in judge.CHECKS},
                "evidence_complete": True, "uncertain": False, "inspected_files": sorted(files)}

    def changed(self, edit):
        root = self.work / "evidence"
        shutil.copytree(self.good, root)
        doc = json.loads((root / "metrics.json").read_text())
        edit(doc, root)
        (root / "metrics.json").write_text(json.dumps(doc))
        return root

    def test_five_real_pixel_sample_metrics_before_AI(self):
        rows = []
        for case in samples.CASES:
            result, rc, call = self.run_judge(self.sample_dir / case)
            expected = 3 if case == "correct" else 1
            self.assertEqual(rc, expected, case)
            self.assertFalse(result["allow_widen_full"])
            self.assertEqual(call.call_count, int(case == "correct"))
            rows.append({"sample": case, "visual_expected": "过" if case == "correct" else "不过",
                         "tool_expected": "过" if case == "correct" else "不过",
                         "tool_actual": "过" if all(x["pass"] for x in result["tools"].values()) else "不过",
                         "protocol_double_result": result["status"], "exit": rc})
        (CACHE / "expected-actual-offline.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")

    def test_good_with_missing_real_cli(self):
        with patch.dict(os.environ, {"S2A_WIDEN_AI": "1"}), patch.object(judge.shutil, "which", return_value=None):
            result, rc = judge.judge(self.good, policy=self.policy)
        self.assertEqual((rc, result["status"], result["reason"]), (3, "缺判官", "cli_not_found"))

    def test_disabled_never_calls_cli_or_which(self):
        with patch.dict(os.environ, {"S2A_WIDEN_AI": "0"}), patch.object(judge.shutil, "which") as cli:
            result, rc = judge.judge(self.good, policy=self.policy)
        self.assertEqual(rc, 3)
        self.assertEqual(result["reason"], "disabled")
        cli.assert_not_called()

    def test_missing_policy_does_not_create_default_pass(self):
        result, rc, call = self.run_judge(policy=False)
        self.assertEqual(rc, 5)
        self.assertEqual(result["status"], "待确认判据")
        self.assertEqual(result["reason"], "unverified_policy")
        call.assert_not_called()

    def test_input_cannot_supply_its_own_threshold_policy(self):
        result, rc = judge.judge(self.good, policy=self.good / "metrics.json")
        self.assertEqual(rc, 2)
        self.assertEqual(result["reason"], "invalid_threshold_policy")

    def test_tool_failure_precedes_disabled_and_missing_cli(self):
        with patch.dict(os.environ, {"S2A_WIDEN_AI": "0"}), patch.object(judge.shutil, "which") as cli:
            result, rc = judge.judge(self.sample_dir / "stretch_1_22", policy=self.policy)
        self.assertEqual(rc, 1)
        cli.assert_not_called()

    def test_strict_AI_complete_all_pass(self):
        result, rc, _ = self.run_judge(answer=self.ai())
        self.assertEqual(rc, 0)
        self.assertTrue(result["allow_widen_full"])
        self.assertEqual(result["status"], "过")

    def test_every_AI_check_independently_vetoes(self):
        for key in judge.CHECKS:
            answer = self.ai()
            answer["checks"][key]["pass"] = False
            result, rc, _ = self.run_judge(answer=answer)
            self.assertEqual(rc, 1, key)
            self.assertFalse(result["allow_widen_full"])

    def test_uncertain_or_incomplete_never_pass(self):
        for key, value in (("uncertain", True), ("evidence_complete", False)):
            answer = self.ai(); answer[key] = value
            result, rc, _ = self.run_judge(answer=answer)
            self.assertEqual(rc, 1)
            self.assertFalse(result["allow_widen_full"])

    def test_bad_AI_schema_and_stale_evidence(self):
        edits = [lambda a: a.update(input_sha256="stale"),
                 lambda a: a["checks"].pop("stretch"),
                 lambda a: a["checks"]["stretch"].update(**{"pass": "true"}),
                 lambda a: a["checks"]["stretch"].update(reason=" "),
                 lambda a: a.update(uncertain="false"),
                 lambda a: a["inspected_files"].pop(),
                 lambda a: a.update(extra=True)]
        for edit in edits:
            answer = self.ai(); edit(answer)
            result, rc, _ = self.run_judge(answer=answer)
            self.assertEqual(rc, 4)
            self.assertFalse(result["allow_widen_full"])

    def test_bad_metrics_and_missing_frames_skip_AI(self):
        edits = [lambda d, r: d["metrics"].pop("center_psnr_db_min"),
                 lambda d, r: d["metrics"].update(center_psnr_db_min=True),
                 lambda d, r: d["metrics"].update(center_psnr_db_min=float("nan")),
                 lambda d, r: d["metrics"].update(hole_side_fraction_max=-1),
                 lambda d, r: d["metrics"].update(ui_width_ratio_min=1.1, ui_width_ratio_max=1.0),
                 lambda d, r: d["continuous_frames"].pop(),
                 lambda d, r: d["continuous_frames"][1].update(frame=999),
                 lambda d, r: d["key_frames"].reverse(),
                 lambda d, r: (r / d["mark"]["wide"]["file"]).unlink(),
                 lambda d, r: d.update(version="unknown")]
        for n, edit in enumerate(edits):
            with self.subTest(n=n):
                root = self.work / str(n)
                shutil.copytree(self.good, root)
                doc = json.loads((root / "metrics.json").read_text()); edit(doc, root)
                (root / "metrics.json").write_text(json.dumps(doc))
                result, rc, call = self.run_judge(root)
                self.assertEqual(rc, 2)
                call.assert_not_called()

    def test_bound_hash_prevents_replacing_pixels(self):
        root = self.changed(lambda d, r: (r / d["mark"]["wide"]["file"]).write_bytes(b"not matching hash"))
        _, rc, call = self.run_judge(root)
        self.assertEqual(rc, 2); call.assert_not_called()

    def test_symlink_and_traversal_rejected(self):
        for escape in ("../outside.png", "/outside.png", "orig/../outside.png"):
            root = self.work / str(len(escape))
            shutil.copytree(self.good, root)
            doc = json.loads((root / "metrics.json").read_text()); doc["mark"]["orig"]["file"] = escape
            (root / "metrics.json").write_text(json.dumps(doc))
            _, rc, call = self.run_judge(root)
            self.assertEqual(rc, 2); call.assert_not_called()
        root = self.changed(lambda d, r: None)
        target = root / "orig/key_0010.png"; target.unlink(); target.symlink_to(self.good / "orig/key_0010.png")
        _, rc, call = self.run_judge(root)
        self.assertEqual(rc, 2); call.assert_not_called()


    def test_PNG_CRC_and_pixel_stream_are_checked(self):
        raw = (self.good / "orig/key_0010.png").read_bytes()
        with self.assertRaises(ValueError):
            judge.png_size(raw[:-1])
        broken = bytearray(raw); broken[20] ^= 1
        with self.assertRaises(ValueError):
            judge.png_size(bytes(broken))
        bad_stream = (raw[:33] + samples.chunk(b"IDAT", b"bad zlib") + samples.chunk(b"IEND", b""))
        with self.assertRaises((ValueError, judge.zlib.error)):
            judge.png_size(bad_stream)

    def test_tool_boundaries_are_inclusive(self):
        metrics = {"hole_side_fraction_max": 0.005, "center_psnr_db_min": 30,
                   "ui_width_ratio_min": 0.99, "ui_width_ratio_max": 1.01,
                   "ui_height_ratio_min": 0.99, "ui_height_ratio_max": 1.01,
                   "flicker_excess_luma_max": 2/255}
        self.assertTrue(all(v["pass"] for v in judge.tool_verdict(metrics, samples.TEST_POLICY).values()))
        for key in metrics:
            changed = dict(metrics)
            changed[key] += -0.00001 if key.endswith("_min") else 0.00001
            self.assertFalse(judge.tool_verdict(changed, samples.TEST_POLICY)[key]["pass"])

    def test_duplicate_JSON_keys(self):
        with self.assertRaises(ValueError):
            judge.strict_json('{"pass":false,"pass":true}')

    def test_changed_input_during_AI_review(self):
        root = self.changed(lambda d, r: None)
        def mutate(*args):
            doc = json.loads((root / "metrics.json").read_text()); doc["capture"]["replay_sha256"] = "f" * 64
            (root / "metrics.json").write_text(json.dumps(doc))
            return self.ai(), {"state": "returned"}
        # Return a matching identity first; then change bytes while AI is running.
        answer = self.ai(); _, files, identity = judge.read_evidence(root)
        answer.update(input_sha256=identity, inspected_files=sorted(files))
        def change(*args):
            mutate(); return answer, {"state": "returned"}
        with patch.dict(os.environ, {"S2A_WIDEN_AI": "1"}), patch.object(judge.shutil, "which", return_value="double"), patch.object(judge, "call_claude", side_effect=change):
            result, rc = judge.judge(root, policy=self.policy)
        self.assertEqual(rc, 4); self.assertFalse(result["allow_widen_full"])

    def test_timeout_and_spawn_failure(self):
        for exc, reason in ((subprocess.TimeoutExpired("claude", 1), "cli_timeout"), (OSError(), "cli_could_not_start")):
            with patch.dict(os.environ, {"S2A_WIDEN_AI": "1"}), patch.object(judge.shutil, "which", return_value="double"), patch.object(judge, "call_claude", side_effect=exc):
                result, rc = judge.judge(self.good, policy=self.policy)
            self.assertEqual(rc, 3); self.assertEqual(result["reason"], reason)

    def test_transport_restricts_tools_and_passes_trusted_skill(self):
        answer = self.ai(); _, files, identity = judge.read_evidence(self.good)
        envelope = {"type": "result", "subtype": "success", "structured_output": answer}
        proc = subprocess.CompletedProcess([], 0, json.dumps(envelope), "")
        with patch.object(judge.subprocess, "run", return_value=proc) as run:
            parsed, _ = judge.call_claude(self.good, identity, files, 10, "double")
        args, kwargs = run.call_args
        cmd = args[0]
        for flag in ("--restricted", "--safe-mode", "--no-session-persistence", "--disable-slash-commands", "--strict-mcp-config"):
            self.assertIn(flag, cmd)
        self.assertEqual(cmd[cmd.index("--tools") + 1], "Read")
        self.assertEqual(cmd[cmd.index("--permission-mode") + 1], "dontAsk")
        self.assertEqual(kwargs["cwd"], self.good)
        self.assertIn("只读视觉审查员", cmd[cmd.index("--system-prompt") + 1])
        self.assertEqual(parsed, answer)

    def test_unlogged_CLI_errors_do_not_echo_secrets(self):
        _, files, identity = judge.read_evidence(self.good)
        for rc, out in ((1, "secret auth body"), (0, '{"type":"result","is_error":true}')):
            proc = subprocess.CompletedProcess([], rc, out, "secret stderr")
            with patch.object(judge.subprocess, "run", return_value=proc):
                answer, state = judge.call_claude(self.good, identity, files, 10, "double")
            self.assertIsNone(answer)
            self.assertNotIn("secret", json.dumps(state))

    def test_malformed_CLI_result_rejected(self):
        _, files, identity = judge.read_evidence(self.good)
        for out in ("```json\n{}\n```", "[]", '{}', '{"type":"result","subtype":"success"}', '{"type":"result","type":"result"}'):
            proc = subprocess.CompletedProcess([], 0, out, "")
            with patch.object(judge.subprocess, "run", return_value=proc), self.assertRaises(ValueError):
                judge.call_claude(self.good, identity, files, 10, "double")

    def test_inputs_and_source_not_modified(self):
        def hashes():
            return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.good.rglob("*") if p.is_file()}
        before = hashes()
        self.run_judge(answer=self.ai())
        self.assertEqual(hashes(), before)
        self.assertFalse(list(self.good.rglob("widen_full*")))

    def test_real_subprocess_protocol_double_is_not_visual_evidence(self):
        # Actually invoke our CLI through a toy executable. It never calls a model.
        cli = self.work / "claude"
        cli.write_text(f"#!{sys.executable}\n" + '''import json, sys
q=json.load(sys.stdin)
checks={k:{"pass":True,"reason":"TRANSPORT DOUBLE - NOT CLAUDE EVIDENCE"} for k in ("stretch","alignment","ui_bounds","bright_bands","flicker","side_content")}
a={"version":"s2a-widen-judge/1","input_sha256":q["input_sha256"],"checks":checks,"evidence_complete":True,"uncertain":False,"inspected_files":q["files"]}
print(json.dumps({"type":"result","subtype":"success","structured_output":a}))
''')
        cli.chmod(0o755)
        env = dict(os.environ, PATH=str(self.work) + os.pathsep + os.environ["PATH"], S2A_WIDEN_AI="1")
        proc = subprocess.run([sys.executable, str(ROOT / "graphics/widen/scan/judge.py"), str(self.good), "--policy", str(self.policy)], env=env, text=True, capture_output=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("TRANSPORT DOUBLE", proc.stdout)
        self.assertEqual(json.loads(proc.stdout)["status"], "过")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", help="explicit caller-owned cache root")
    args = parser.parse_args()
    CACHE = Path(args.output).resolve()
    CACHE.mkdir(parents=True, exist_ok=True)
    unittest.main(argv=[sys.argv[0]], verbosity=2)
