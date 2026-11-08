#!/usr/bin/env python3
"""Synthetic producer-shaped host.log tests only; no device/game/30-minute evidence.

Run: python3 tests/longrun_summary_test.py
Fixtures below transcribe ios/app.m, gal_core.m thermal_log,
NxFrames.cs GcLine and gfxmode.c. Expected numbers are hand sums/differences,
not values obtained by invoking the parser. No timestamp is invented for GC/heartbeat.
"""
import importlib.util
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = Path(os.environ.get("LONGRUN_TOOL", ROOT / "tools/longrun_summary.py"))
spec = importlib.util.spec_from_file_location("longrun_summary", TOOL)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def thermal(second, state="nominal 正常", why="每 10 秒"):
    return f"[gal] 热状态 {state}（{why}，起局后 {second} 秒）\n"


def heartbeat(frame, memory, hot=0, scanned=True):   # scanned=False：11-06 起缺省不扫整窗（S2A_MEM_SPLIT=1 才扫）
    win = "客体窗口常驻 10 MB、已压缩换出 0 MB" if scanned else "客体窗口常驻 未扫（S2A_MEM_SPLIT=1 才扫）"
    return (f"[s2a] [心跳] 帧 {frame}，热状态 {hot}（0 正常 1 一般 2 严重 3 危急），"
            f"进程实占 {memory} MB，前台，持续执行档 0"
            "（1 = 系统按稳态功率限制本进程，要权限 sustained-execution），"
            "低电量模式 0，低区空洞合计 100 MB、最大一块 50 MB，"
            f"文件句柄 12 / 软上限 2560，{win}\n")


def gc(index, pause="3.00", frame=30):
    return (f"[gc] 帧 {frame} 第 {index} 次：gen1 压缩，晋升 32 KB，固定 0，停顿 {pause} ms，堆 175 MB；"
            "回收前→后 g0 4→2 KB g1 3→1 KB g2 2→1 KB 大 1→1 KB 固 0→0 KB；"
            "碎片 1 MB、内存负载 300 / 阈值 1000 MB、已提交 200 MB\n")


MODE = "[s2a] 图形模式：直连（依据 缺省；程序号 0000000000000000）\n"
FAIL = "[s2a] 【红】直连异常（不切换，继续跑）：synthetic-reason /redacted\n"


def fixture():
    # [0,300): mem 100 -> 130; GC (3+2) + 7 = 12; max collection 7, max stop 7.
    # [300,600): mem 150 -> 190; GC (8+4) = 12; max collection 12, max stop 8.
    # Direct anomaly emission interval [309.5,320.5]; the run keeps its mode.
    return (MODE + thermal(0, why="初始化") + thermal(10)
            + heartbeat(300, 100) + gc(10, "3.00 + 2.00")
            + thermal(20) + thermal(280) + heartbeat(8400, 130)
            + gc(11, "7.00", 8400) + thermal(290)
            + thermal(310, "fair 偏热") + heartbeat(9300, 150, 1, scanned=False)
            + gc(12, "8.00 + 4.00", 9300) + FAIL + thermal(320, "fair 偏热")
            + thermal(580, "serious 严重") + heartbeat(17400, 190, 2)
            + thermal(590, "serious 严重"))


def report(text):
    return mod.summarize(text.splitlines(keepends=True))


def nslog(second, text, pid=712):
    stamp = (datetime(2026, 10, 25, 13) + timedelta(seconds=second)).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    return f"{stamp} S2Arm[{pid}:a7] {text.rstrip()}\n"


def real_shape_fixture():
    # 42 heartbeats, nominal NSTimer 10s fixture; timestamps supplied explicitly.
    # [0,300): i=0..28, 2445..3789 MiB (29 samples).
    # [300,600): i=29..41, 3837..4416 MiB (13 samples).
    lines = [nslog(0, "boot synthetic")]
    for i in range(42):
        second = 10 + i * 10
        memory = 2445 + i * 48 if i < 41 else 4416
        hot = 0 if i < 14 else (1 if i < 28 else 2)
        lines.append(nslog(second, "ordinary timestamp anchor"))
        value = heartbeat((i + 1) * 200, memory, hot)
        lines.append(value if i % 2 else nslog(second, value))
        if i in (0, 20, 40):
            # This unrelated mach-clock origin must not split the PID/time axis.
            lines.append(thermal(0, state=("nominal 正常", "fair 偏热", "serious 严重")[hot], why="初始化"))
        lines.append(nslog(second + 1, "ordinary timestamp anchor"))
    return "".join(lines)


class LongrunTest(unittest.TestCase):
    def test_hand_computed_two_windows(self):
        s = report(fixture())["sessions"][0]
        a, b = s["windows"]
        self.assertEqual((a["start_second"], b["start_second"]), (0, 300))
        self.assertEqual((a["footprint_mib"]["change"], b["footprint_mib"]["change"]), (30, 40))
        self.assertEqual((a["footprint_mib"]["last"], b["footprint_mib"]["last"]), (130, 190))
        self.assertEqual((a["gc"]["observed_events"], b["gc"]["observed_events"]), (2, 1))
        self.assertEqual((a["gc"]["observed_pause_total_ms"], b["gc"]["observed_pause_total_ms"]), (12, 12))
        self.assertEqual((a["gc"]["max_observed_collection_pause_ms"], b["gc"]["max_observed_collection_pause_ms"]), (7, 12))
        self.assertEqual(b["gc"]["max_observed_stop_ms"], 8)
        self.assertEqual(b["thermal_observed_sequence"], ["fair", "serious"])
        self.assertTrue(s["observed_trends"]["footprint_increased"])
        self.assertTrue(s["observed_trends"]["thermal_worsened"])
        self.assertTrue(s["observed_trends"]["logged_gc_peak_increased"])

    def test_direct_anomaly_bounds_not_cause(self):
        s = report(fixture())["sessions"][0]
        e = s["windows"][1]["direct_anomaly_events"][0]
        self.assertEqual(e["time_bounds"], [309.5, 320.5])
        self.assertNotIn("next_launch", e)
        dumped = json.dumps(s)
        for secret in ("/redacted", "synthetic-reason", "0000000000000000"):
            self.assertNotIn(secret, dumped)

    def test_short_observation_not_real_play(self):
        s = report(fixture())["sessions"][0]
        self.assertEqual(s["observed_span_lower_bound_seconds"], 589)
        self.assertFalse(s["observed_span_at_least_30_minutes"])
        self.assertFalse(s["real_play_30_minutes_verified"])

    def test_long_clock_span_still_not_device_acceptance(self):
        s = report(thermal(0, why="初始化") + thermal(1810))["sessions"][0]
        self.assertTrue(s["observed_span_at_least_30_minutes"])
        self.assertFalse(s["real_play_30_minutes_verified"])

    def test_no_timestamp_cadence_extrapolation(self):
        s = report(heartbeat(300, 100) + gc(10) + heartbeat(600, 130))["sessions"][0]
        self.assertEqual(s["windows"], [])
        self.assertIsNone(s["observed_span_lower_bound_seconds"])
        self.assertEqual(len(s["unwindowed_observations"]), 3)

    def test_boundary_bracket_remains_unwindowed(self):
        s = report(thermal(290) + heartbeat(9000, 100) + gc(10) + FAIL + thermal(310))["sessions"][0]
        for w in s["windows"]:
            self.assertIsNone(w["footprint_mib"])
            self.assertIsNone(w["gc"])
            self.assertEqual(w["direct_anomaly_events"], [])
        hb = next(e for e in s["unwindowed_observations"] if e["kind"] == "heartbeat")
        self.assertEqual(hb["time_bounds"], [289.5, 310.5])

    def test_rounded_anchor_at_exact_boundary_not_precise(self):
        s = report(thermal(300))["sessions"][0]
        self.assertEqual(s["unwindowed_observations"][0]["time_bounds"], [299.5, 300.5])
        self.assertIsNone(s["windows"][0]["thermal_observed_sequence"])

    def test_empty_windows_are_unknown(self):
        s = report(thermal(10) + thermal(910, "未知"))["sessions"][0]
        self.assertEqual(len(s["windows"]), 4)
        self.assertIsNone(s["windows"][1]["gc"])
        self.assertIsNone(s["windows"][1]["footprint_mib"])
        self.assertIsNone(s["windows"][1]["thermal_observed_sequence"])

    def test_producer_memory_failure_zero_is_unknown(self):
        s = report(thermal(10) + heartbeat(1, 0) + thermal(20))["sessions"][0]
        self.assertIsNone(s["summary"]["footprint_mib"])
        self.assertIsNone(s["observed_trends"]["footprint_increased"])

    def test_gc_missing_indices_do_not_become_events(self):
        r = report(thermal(10) + gc(100, "2.00") + gc(105, "4.00") + thermal(20))
        g = r["sessions"][0]["windows"][0]["gc"]
        self.assertEqual((g["observed_events"], g["observed_pause_total_ms"]), (2, 6))
        self.assertIsNone(g["complete_count"])
        self.assertIsNone(g["complete_pause_total_ms"])
        self.assertEqual(r["diagnostics"][0]["missing"], 4)

    def test_gc_line_without_fragmentation_suffix_from_older_packages(self):
        # 10-24 13:35 之前的 GcLine 没有「；碎片 … 已提交」段：两次停顿 2.00 + 4.00 = 6 ms，照算
        old = lambda i, p: gc(i, p).split("；碎片")[0] + "\n"
        r = report(thermal(10) + old(20, "2.00") + old(21, "4.00") + thermal(20))
        g = r["sessions"][0]["windows"][0]["gc"]
        self.assertEqual((g["observed_events"], g["observed_pause_total_ms"]), (2, 6))

    def test_gc_duplicate_is_not_counted_twice(self):
        r = report(thermal(10) + gc(9) + gc(9) + thermal(20))
        self.assertEqual(r["sessions"][0]["summary"]["gc"]["observed_events"], 1)
        self.assertEqual(r["diagnostics"][0]["reason"], "duplicate_gc_ignored")

    def test_gc_conflict_is_diagnosed_without_guessing_pid(self):
        r = report(thermal(10) + gc(9) + gc(9, "8.00") + thermal(20))
        self.assertEqual(len(r["sessions"]), 1)
        self.assertEqual(r["diagnostics"][0]["reason"], "conflicting_gc_index")
        self.assertIsNone(next(e for e in r["sessions"][0]["unwindowed_observations"] if e["kind"] != "thermal")["time_bounds"])

    def test_repeated_heartbeat_not_weighted_as_independent(self):
        r = report(thermal(10) + heartbeat(1, 100) * 2 + thermal(20))
        self.assertEqual(r["sessions"][0]["summary"]["footprint_mib"]["samples"], 1)
        self.assertEqual(r["diagnostics"][0]["reason"], "duplicate_heartbeat_ignored")

    def test_clock_reset_and_reordering_are_timing_barriers(self):
        for tail in (thermal(20), thermal(0, why="初始化")):
            with self.subTest(tail=tail):
                r = report(thermal(600) + heartbeat(100, 100) + tail)
                self.assertEqual(len(r["sessions"]), 1)
                self.assertEqual(r["sessions"][0]["windows"][0]["start_second"], 600)
                self.assertIsNone(r["sessions"][0]["unwindowed_observations"][-1]["time_bounds"])

    def test_frame_and_gc_counter_reset_do_not_guess_new_pid(self):
        for lines in (heartbeat(100, 100) + heartbeat(1, 150), gc(100) + gc(1)):
            with self.subTest(lines=lines):
                r = report(thermal(10) + lines + thermal(20))
                self.assertEqual(len(r["sessions"]), 1)

    def test_new_mode_without_pid_is_not_a_proven_new_process(self):
        r = report(fixture() + MODE.replace("直连", "通用") + thermal(0, why="初始化") + heartbeat(1, 20))
        self.assertEqual(len(r["sessions"]), 1)
        self.assertEqual(r["sessions"][0]["summary"]["footprint_mib"]["last"], 20)
        self.assertIsNone(r["sessions"][0]["observed_trends"]["footprint_increased"])

    def test_wrong_units_partial_and_field_conflicts(self):
        bad = [
            heartbeat(1, 100).replace("100 MB", "100 GB"),
            gc(1).replace("3.00 ms", "3.00 s"),
            gc(1).replace("3.00", "-3.00"),
            gc(1).replace("3.00", "NaN"),
            heartbeat(1, 100).rstrip("\n"),
            heartbeat(1, 100).replace("100 MB", "100 MB，进程实占 900 MB"),
            thermal(10).replace("10 秒", "10 ms"),
            "[s2a] [心跳] \ufffd\n",
        ]
        for line in bad:
            with self.subTest(line=line):
                r = report(line)
                self.assertEqual(r["sessions"], [])
                self.assertTrue(r["diagnostics"])

    def test_damaged_line_prevents_bridging(self):
        r = report(thermal(10) + heartbeat(1, 100) + gc(1).replace(" ms", " s") + thermal(20))
        self.assertEqual(len(r["sessions"]), 1)
        hb = r["sessions"][0]["unwindowed_observations"][-1]
        self.assertIsNone(hb["time_bounds"])

    def test_dropped_console_notification_is_barrier(self):
        r = report(thermal(10) + heartbeat(1, 100)
                   + "[s2a] [控制台] 环满丢 3 行（host.log 照写全量）\n" + thermal(20))
        self.assertEqual(len(r["sessions"]), 1)
        self.assertEqual(r["diagnostics"][0]["reason"], "console_line_loss")

    def test_unsupported_logger_wall_and_cpu_clocks_not_aligned(self):
        for prefix in ("00:05:10.000 |I| Console ", "2026-10-25T05:10:00Z pid=72 ",
                       "[CPUmono=310] ", "pid=73 "):
            with self.subTest(prefix=prefix):
                r = report(thermal(10) + prefix + heartbeat(1, 100) + thermal(20))
                self.assertEqual(len(r["sessions"]), 1)
                self.assertTrue(all(s["summary"]["footprint_mib"] is None for s in r["sessions"]))

    def test_display_and_cpu_cadence_not_requested_fps(self):
        text = ("[s2a] [gal] 帧节拍：交换间隔 2，每帧 33.3 ms（30 帧/秒）\n"
                + thermal(10) + heartbeat(300, 100) + thermal(20))
        s = report(text)["sessions"][0]
        self.assertEqual(s["summary"]["requested_fps_observations"], [30])
        self.assertIsNone(s["windows"][0]["display_fps"])
        self.assertIsNone(s["windows"][0]["cpu_queue_present_return_fps"])
        self.assertIsNone(report(text.replace("33.3", "16.7"))["sessions"][0]["summary"]["requested_fps_observations"])

    def test_anomaly_absence_is_not_proof_no_anomaly(self):
        s = report(heartbeat(1, 100))["sessions"][0]
        self.assertEqual(s["summary"]["direct_anomaly_events"], [])
        self.assertFalse(s["real_play_30_minutes_verified"])

    def test_cli_json_text_errors_help_and_input_unchanged(self):
        with tempfile.TemporaryDirectory(prefix="longrun-") as tmp:
            path = Path(tmp) / "private-host.log"
            data = fixture().encode()
            path.write_bytes(data)
            for flags in (["--json"], []):
                p = subprocess.run([sys.executable, str(TOOL), str(path), *flags], capture_output=True, text=True)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertNotIn(str(path), p.stdout + p.stderr)
                if flags:
                    self.assertEqual(json.loads(p.stdout)["sessions"][0]["summary"]["gc"]["observed_events"], 3)
                else:
                    self.assertIn("0–5", p.stdout)
            self.assertEqual(path.read_bytes(), data)
            p = subprocess.run([sys.executable, str(TOOL), str(path.with_name("missing-private"))], capture_output=True, text=True)
            self.assertEqual(p.returncode, 2)
            self.assertNotIn("missing-private", p.stdout + p.stderr)
            path.write_text("no observations\n")
            p = subprocess.run([sys.executable, str(TOOL), str(path), "--json"], capture_output=True, text=True)
            self.assertEqual(p.returncode, 2)
            self.assertEqual(json.loads(p.stdout)["sessions"], [])
        p = subprocess.run([sys.executable, str(TOOL), "--help"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0)
        self.assertIn("--json", p.stdout)

    def test_privacy_unrecognized_lines_never_echoed(self):
        private = "secret-unrelated-path"
        r = report(fixture() + "[s2a] " + private + "\n" + heartbeat(1, 1).replace("MB", private))
        self.assertNotIn(private, json.dumps(r))
        self.assertNotIn(private, mod.text_report(r))


    def test_boot_us_suffix_keeps_requested_fps_parsers(self):
        # T141 合入线：声明行尾自带 CLOCK_BOOTTIME 微秒戳——两个消费工具读出的
        #   间隔 / 帧率必须与不带戳旧行相同；戳放回「帧节拍」前是反证（REQUESTED fullmatch 认不出）。
        fps_spec = importlib.util.spec_from_file_location("game_fps", ROOT / "tools/game_fps.py")
        fps_mod = importlib.util.module_from_spec(fps_spec)
        fps_spec.loader.exec_module(fps_mod)
        stamped = ("[gal] 帧节拍：交换间隔 2，每帧 33.3 ms（30.0 帧/秒） boot_us=1000000\n"
                   "[gal] 收局 帧节拍：交换间隔 2，每帧 33.3 ms（30.0 帧/秒） boot_us=2000000\n")
        unstamped = ("[gal] 帧节拍：交换间隔 2，每帧 33.3 ms（30.0 帧/秒）\n"
                     "[gal] 收局 帧节拍：交换间隔 2，每帧 33.3 ms（30.0 帧/秒）\n")
        for text in (unstamped, stamped):
            s = report(text)["sessions"][0]
            self.assertEqual(s["summary"]["requested_fps_observations"], [30])
            self.assertEqual(fps_mod.target(text), fps_mod.target(unstamped))
        prefixed = ("[gal] boot_us=1000000 帧节拍：交换间隔 2，每帧 33.3 ms（30.0 帧/秒）\n"
                    "[gal] 收局 boot_us=2000000 帧节拍：交换间隔 2，每帧 33.3 ms（30.0 帧/秒）\n")
        self.assertFalse(report(prefixed)["sessions"])

    def test_real_uncapped_and_rounded_requested_fps(self):
        for text, expected in (
            ("[gal] 帧节拍：交换间隔 0，每帧 0.0 ms（0 帧/秒）\n", 0),
            ("[gal] 帧节拍：交换间隔 7，每帧 116.7 ms（9 帧/秒）\n", 9)):
            with self.subTest(expected=expected):
                s = report(text)["sessions"][0]
                self.assertEqual(s["summary"]["requested_fps_observations"], [expected])
                self.assertEqual(s["windows"], [])

    def test_extreme_digits_and_clock_span_are_bounded(self):
        r = report(thermal("9" * 4000))
        self.assertEqual(r["sessions"], [])
        self.assertTrue(r["diagnostics"])
        r = report(thermal(0) + thermal(999999999999))
        self.assertLess(len(r["sessions"][0]["windows"]), 3)
        self.assertIn("sparse_clock_span_empty_windows_omitted", [d["reason"] for d in r["diagnostics"]])

    def test_explicit_unknown_thermal_signal(self):
        s = report(thermal(10, "未知") + thermal(20, "未知"))["sessions"][0]
        self.assertIsNone(s["summary"]["thermal_observed_sequence"])
        self.assertIsNone(s["observed_trends"]["thermal_worsened"])


    def test_real_producer_42_interleaved_heartbeats_hand_windows(self):
        r = report(real_shape_fixture())
        self.assertEqual(len(r["sessions"]), 1)
        s = r["sessions"][0]
        self.assertEqual(s["pid"], 712)
        self.assertEqual(s["summary"]["footprint_mib"]["samples"], 42)
        self.assertEqual((s["summary"]["footprint_mib"]["first"], s["summary"]["footprint_mib"]["last"]), (2445, 4416))
        self.assertEqual(s["summary"]["thermal_observed_sequence"], ["nominal", "fair", "serious"])
        self.assertIs(s["observed_trends"]["footprint_increased"], True)
        self.assertIs(s["observed_trends"]["thermal_worsened"], True)
        a, b = s["windows"]
        self.assertEqual((a["footprint_mib"]["samples"], a["footprint_mib"]["first"], a["footprint_mib"]["last"]), (29, 2445, 3789))
        self.assertEqual((b["footprint_mib"]["samples"], b["footprint_mib"]["first"], b["footprint_mib"]["last"]), (13, 3837, 4416))
        self.assertEqual(len(s["unwindowed_observations"]), 0)
        self.assertFalse(s["heartbeat_cadence_used_for_timestamps"])

    def test_short_nslog_session_keeps_single_memory_but_no_trend(self):
        for text in (nslog(0, "boot") + nslog(11, heartbeat(50, 2445)), nslog(11, heartbeat(50, 2445))):
            with self.subTest(text=text):
                r = report(text)
                self.assertEqual(len(r["sessions"]), 1)
                s = r["sessions"][0]
                self.assertEqual(len(s["windows"]), 1)
                self.assertEqual(s["windows"][0]["footprint_mib"]["first"], 2445)
                self.assertIsNone(s["observed_trends"]["footprint_increased"])
                self.assertIsNone(s["observed_trends"]["thermal_worsened"])

    def test_nslog_pid_separates_and_interleaving_never_guesses_raw_pid(self):
        r = report(nslog(0, heartbeat(1, 100), 111) + nslog(10, heartbeat(2, 200), 222)
                   + heartbeat(3, 999) + nslog(20, heartbeat(3, 120), 111))
        bypid = {s["pid"]: s for s in r["sessions"]}
        self.assertEqual(set(bypid), {111, 222, None})
        self.assertEqual(bypid[111]["summary"]["footprint_mib"]["samples"], 2)
        self.assertEqual(bypid[222]["summary"]["footprint_mib"]["samples"], 1)
        self.assertEqual(bypid[None]["windows"], [])
        self.assertIn("ambiguous_unprefixed_pid", [d["reason"] for d in r["diagnostics"]])

    def test_same_pid_mode_frame_and_gal_reset_never_split_session(self):
        r = report(nslog(0, MODE) + nslog(10, heartbeat(100, 100)) + thermal(600)
                   + nslog(20, MODE.replace("直连", "通用")) + thermal(0, why="初始化")
                   + nslog(30, heartbeat(1, 150)))
        self.assertEqual(len(r["sessions"]), 1)
        self.assertEqual(r["sessions"][0]["pid"], 712)
        self.assertEqual(r["sessions"][0]["summary"]["footprint_mib"]["samples"], 2)

    def test_frame_and_nominal_timer_never_manufacture_time(self):
        s = report(heartbeat(100, 100) + heartbeat(1000000, 200))["sessions"][0]
        self.assertEqual(s["windows"], [])
        self.assertIsNone(s["observed_span_lower_bound_seconds"])
        self.assertFalse(s["heartbeat_cadence_used_for_timestamps"])
        self.assertIsNone(s["observed_trends"]["footprint_increased"])

    def test_nslog_cross_window_bracket_is_unknown(self):
        s = report(nslog(0, "boot") + nslog(290, "anchor") + heartbeat(100, 100)
                   + nslog(310, "anchor"))["sessions"][0]
        self.assertEqual(s["unwindowed_observations"][0]["time_bounds"], [290, 310])
        self.assertTrue(all(w["footprint_mib"] is None for w in s["windows"]))

    def test_same_frame_at_two_explicit_timestamps_is_two_samples(self):
        s = report(nslog(0, heartbeat(100, 100)) + nslog(10, heartbeat(100, 100)))["sessions"][0]
        self.assertEqual(s["summary"]["footprint_mib"]["samples"], 2)
        self.assertFalse(s["observed_trends"]["footprint_increased"])

    def test_nslog_regression_diagnoses_clock_not_new_process(self):
        r = report(nslog(100, heartbeat(1, 100)) + nslog(90, heartbeat(2, 200)))
        self.assertEqual(len(r["sessions"]), 1)
        self.assertIsNone(r["sessions"][0]["observed_trends"]["footprint_increased"])
        self.assertIn("nslog_clock_regressed", [d["reason"] for d in r["diagnostics"]])


    def test_interleaved_explicit_pid_times_still_share_each_pid_window(self):
        r = report(nslog(0, heartbeat(1, 100), 111) + nslog(10, heartbeat(2, 900), 222)
                   + nslog(20, heartbeat(3, 120), 111))
        bypid = {s["pid"]: s for s in r["sessions"]}
        self.assertEqual(len(bypid[111]["windows"]), 1)
        self.assertEqual(bypid[111]["windows"][0]["footprint_mib"]["samples"], 2)
        self.assertEqual(bypid[111]["windows"][0]["footprint_mib"]["change"], 20)

    def test_nslog_known_offset_and_unspecified_timezone_not_aligned(self):
        r = report(nslog(0, heartbeat(1, 100)) + nslog(10, heartbeat(2, 200)).replace(".000 S2Arm", ".000+0800 S2Arm"))
        self.assertEqual(len(r["sessions"]), 1)
        self.assertIsNone(r["sessions"][0]["observed_trends"]["footprint_increased"])
        self.assertTrue(all(w["footprint_mib"] is None for w in r["sessions"][0]["windows"]))
        self.assertIn("nslog_timezone_basis_mixed", [d["reason"] for d in r["diagnostics"]])

    def test_repeated_raw_heartbeat_with_distinct_nslog_brackets_is_observed_twice(self):
        s = report(nslog(0, "anchor") + heartbeat(1, 100) + nslog(1, "anchor")
                   + nslog(10, "anchor") + heartbeat(1, 100) + nslog(11, "anchor"))["sessions"][0]
        self.assertEqual(s["windows"][0]["footprint_mib"]["samples"], 2)


    def test_nslog_forward_wall_jump_is_not_thirty_minute_duration(self):
        s = report(nslog(0, heartbeat(1, 100)) + nslog(3600, heartbeat(2, 200)))["sessions"][0]
        self.assertEqual(s["nslog_wall_observation_span_seconds"], 3600)
        self.assertIsNone(s["observed_span_lower_bound_seconds"])
        self.assertIsNone(s["observed_span_at_least_30_minutes"])
        self.assertFalse(s["real_play_30_minutes_verified"])

    def test_unwindowed_tail_does_not_turn_window_trends_true(self):
        s = report(nslog(0, "single clock anchor") + heartbeat(1, 100) + heartbeat(2, 200, 2))["sessions"][0]
        self.assertEqual(s["summary"]["footprint_mib"]["samples"], 2)
        self.assertEqual(len(s["unwindowed_observations"]), 2)
        self.assertIsNone(s["observed_trends"]["footprint_increased"])
        self.assertIsNone(s["observed_trends"]["thermal_worsened"])


if __name__ == "__main__":
    unittest.main()
