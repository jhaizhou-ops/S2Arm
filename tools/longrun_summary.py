#!/usr/bin/env python3
"""L03/#205: read-only, standard-library, five-minute host.log observation report.

python3 tools/longrun_summary.py host.log [--json]
Exit 0 means report produced, NOT device/play acceptance; 2 means unreadable/no observations.

Producer sources: ios/app.m (heartbeat: phys_footprint >> 20; failure=0),
graphics/metal/cs/NxFrames.cs GcLine (latest GC Index, one/two pauses; may miss collections),
graphics/metal/gal_core.m thermal_log (mach clock since first call, rounded seconds),
graphics/nvn/host_adapt.m s2a_direct_fail (direct anomaly red line; no mode switch since 10-26).
LOG/GLOG have no universal timestamp: runtime/src/native.h and gal_internal.h.

NSLog prefixes provide a PID and wall-clock emission timestamp. Windows are relative
to that PID's first observed NSLog timestamp, NOT launch or active play time.
Unprefixed records between same-PID timestamps get emission-order bounds; missing
bounds or multi-PID ambiguity stay unknown. GAL rounded seconds remain a separate
fallback clock only where no NSLog clock is available. Heartbeat NSTimer is nominally
10 seconds; delay/loss means cadence and frame numbers never synthesize timestamps.
Counters/mode changes/damaged lines are timing barriers, never guessed new PIDs.
GC totals/counts cover printed events only; no display FPS from frames/QueuePresent.
Output contains only allowlisted numeric/state/line fields, no input paths/text.
"""
import argparse
import calendar
from datetime import datetime, timezone
import json
import re
import sys
from pathlib import Path

WINDOW = 300
NUM = r"(?:0|[1-9]\d{0,14})(?:\.\d{1,15})?"
THERMAL = re.compile(
    r"\[gal\] 热状态 (nominal 正常|fair 偏热|serious 严重|critical 危急|未知)"
    r"（(初始化|每 10 秒|变化)，起局后 (\d{1,15}) 秒）")
HEARTBEAT = re.compile(
    r"\[s2a\] \[心跳\] 帧 (\d{1,15})，热状态 ([0-3])"
    r"（0 正常 1 一般 2 严重 3 危急），进程实占 (\d{1,15}) MB，"
    r"(前台|前台失焦|后台)，持续执行档 [01]"
    r"（1 = 系统按稳态功率限制本进程，要权限 sustained-execution），"
    r"低电量模式 [01]，低区空洞合计 \d{1,15} MB、最大一块 \d{1,15} MB，"
    r"文件句柄 \d{1,15} / 软上限 \d{1,15}，客体窗口常驻 (?:\d{1,15} MB、已压缩换出 \d{1,15} MB|未扫（S2A_MEM_SPLIT=1 才扫）)")   # 11-06 起缺省不扫整窗
HOT = re.compile(r"\[s2a\] \[热\] 热状态变为 ([0-3])（0 正常 1 一般 2 严重 3 危急），帧 (\d{1,15})")
GC = re.compile(
    rf"\[gc\] 帧 (\d{{1,15}}) 第 (\d{{1,15}}) 次：gen([0-2])(?: 压缩)?(?: 并发)?，"
    rf"晋升 \d{{1,15}} KB，固定 \d{{1,15}}，停顿 ({NUM})(?: \+ ({NUM}))? ms，堆 (\d{{1,15}}) MB；"
    r"回收前→后 g0 \d{1,15}→\d{1,15} KB g1 \d{1,15}→\d{1,15} KB g2 \d{1,15}→\d{1,15} KB"
    r" 大 \d{1,15}→\d{1,15} KB 固 \d{1,15}→\d{1,15} KB"
    # 「；碎片 / 内存负载 / 已提交」段是 10-24 13:35（92da7d287）才加的，之前出的包里的 [gc] 行没有它，照认
    r"(?:；碎片 \d{1,15} MB、内存负载 \d{1,15} / 阈值 \d{1,15} MB、已提交 \d{1,15} MB)?")
MODE = re.compile(r"\[s2a\] 图形模式：(直连|通用)（依据 [^\r\n]+；程序号 [0-9a-f]{16}）")
ANOMALY = re.compile(r"\[s2a\] 【红】直连异常（不切换，继续跑）：[^\r\n]+")
REQUESTED = re.compile(rf"(?:\[s2a\] )?\[gal\] 帧节拍：交换间隔 (\d{{1,15}})，每帧 ({NUM}) ms（({NUM}) 帧/秒）(?: boot_us=\d{{1,15}})?")
TOKENS = ("[心跳]", "[gc]", "[热] 热状态变为", "[gal] 热状态", "图形模式：", "直连异常（不切换，继续跑）：", "[gal] 帧节拍")
STATES = ["nominal", "fair", "serious", "critical"]


def parse_record(line):
    """Whole producer lines only; unknown units/suffixes must not become readings."""
    if m := THERMAL.fullmatch(line):
        state = m[1].split()[0]
        return dict(kind="thermal", state=None if state == "未知" else state,
                    second=int(m[3]), initialization=m[2] == "初始化")
    if m := HEARTBEAT.fullmatch(line):
        return dict(kind="heartbeat", frame=int(m[1]), state=STATES[int(m[2])],
                    footprint_mib=int(m[3]) or None)
    if m := HOT.fullmatch(line):
        return dict(kind="hot", state=STATES[int(m[1])], frame=int(m[2]))
    if m := GC.fullmatch(line):
        pauses = [float(m[4])] + ([float(m[5])] if m[5] else [])
        return dict(kind="gc", frame=int(m[1]), index=int(m[2]), generation=int(m[3]),
                    pause_ms=sum(pauses), max_stop_ms=max(pauses), heap_mib=int(m[6]))
    if m := MODE.fullmatch(line):
        return dict(kind="mode", mode="direct" if m[1] == "直连" else "generic")
    if ANOMALY.fullmatch(line):
        return dict(kind="direct_anomaly")
    if m := REQUESTED.fullmatch(line):
        interval, period, fps = int(m[1]), float(m[2]), float(m[3])
        if interval == 0 and period == 0 and fps == 0:
            return dict(kind="requested_fps", fps=0)  # producer's uncapped sentinel, not 0 display FPS
        if 1 <= interval <= 7 and fps > 0 and period > .05 and abs(1000 / period - fps) <= .55:
            return dict(kind="requested_fps", fps=fps)
    return None


def aggregate(records):
    mem = [e["footprint_mib"] for e in records if e["kind"] == "heartbeat" and e["footprint_mib"] is not None]
    gc = [e for e in records if e["kind"] == "gc"]
    states = [e["state"] for e in records if e.get("state") is not None]
    seq = [s for i, s in enumerate(states) if i == 0 or s != states[i - 1]]
    return dict(
        footprint_mib=None if not mem else dict(samples=len(mem), first=mem[0], last=mem[-1],
            minimum=min(mem), maximum=max(mem), change=mem[-1] - mem[0]),
        gc=None if not gc else dict(observed_events=len(gc),
            observed_pause_total_ms=round(sum(e["pause_ms"] for e in gc), 6),
            max_observed_collection_pause_ms=max(e["pause_ms"] for e in gc),
            max_observed_stop_ms=max(e["max_stop_ms"] for e in gc),
            complete_count=None, complete_pause_total_ms=None),
        thermal_observed_sequence=seq or None,
        requested_fps_observations=[e["fps"] for e in records if e["kind"] == "requested_fps"] or None,
        direct_anomaly_events=[dict(line=e["line"], time_bounds=e["time_bounds"])
            for e in records if e["kind"] == "direct_anomaly"])


NSLOG = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3,6}(?:[+-]\d{4})?) "
    r"S2Arm\[([1-9]\d{0,14}):[0-9a-fA-F]{1,16}\] (.*)$")


def console_prefix(line):
    """Only the documented NSLog S2Arm prefix; no guessed CPU/logger clocks."""
    match = NSLOG.fullmatch(line)
    if not match:
        return None
    try:
        dt = (datetime.strptime(match[1], "%Y-%m-%d %H:%M:%S.%f%z")
              if re.search(r"[+-]\d{4}$", match[1]) else datetime.fromisoformat(match[1]))
        basis = "offset_aware" if dt.tzinfo is not None else "local_unspecified"
        if dt.tzinfo is not None:
            dt = dt.astimezone(timezone.utc).replace(tzinfo=None)
        # Integer microseconds: no local timezone conversion or large-float rounding.
        stamp = calendar.timegm(dt.timetuple()) * 1000000 + dt.microsecond
    except (ValueError, OverflowError):
        return None
    return int(match[2]), stamp, match[3], basis


def summarize(lines):
    entries, issues, prefixes, barriers = [], [], [], []
    for n, raw in enumerate(lines, 1):
        if len(raw) > 65536 or not raw.endswith("\n") or "\ufffd" in raw or "\x00" in raw:
            issues.append(dict(line=n, reason="partial_oversized_or_invalid_line"))
            barriers.append(n)
            continue
        line = raw.rstrip("\r\n")
        prefix = console_prefix(line)
        pid, stamp = (prefix[:2] if prefix else (None, None))
        body = prefix[2] if prefix else line
        if prefix:
            prefixes.append((n, pid, stamp, prefix[3]))
        event = parse_record(body)
        if event is None:
            if any(token in body for token in TOKENS):
                issues.append(dict(line=n, reason="unrecognized_or_conflicting_producer_line"))
                barriers.append(n)
            elif "[控制台] 环满丢 " in body:
                issues.append(dict(line=n, reason="console_line_loss"))
                barriers.append(n)
            continue
        event.update(line=n, pid=pid, _stamp=stamp)
        entries.append(event)

    pids = {pid for _, pid, _, _ in prefixes}
    groups = {}
    for event in entries:
        if event["pid"] is None and pids:
            left = next((p for p in reversed(prefixes) if p[0] < event["line"]), None)
            right = next((p for p in prefixes if p[0] > event["line"]), None)
            if len(pids) == 1 or (left and right and left[1] == right[1]):
                event["pid"] = next(iter(pids)) if len(pids) == 1 else left[1]
                event["pid_source"] = "single_observed_pid" if len(pids) == 1 else "same_pid_prefix_bracket"
            else:
                event["pid_source"] = "unknown_interleaved_pids"
                issues.append(dict(line=event["line"], reason="ambiguous_unprefixed_pid"))
        elif event["pid"] is not None:
            event["pid_source"] = "nslog_prefix"
        else:
            event["pid_source"] = "unknown_no_pid"
        groups.setdefault(event["pid"], []).append(event)

    output = []
    for pid, events in groups.items():
        ns = [(n, stamp) for n, p, stamp, _ in prefixes if p == pid] if pid is not None else []
        mixed_basis = len({basis for _, p, _, basis in prefixes if p == pid}) > 1
        if mixed_basis:
            issues.append(dict(line=events[0]["line"], reason="nslog_timezone_basis_mixed"))
        # An intervening process prefix cannot bracket an unprefixed record's time.
        cuts = sorted(set(barriers))
        last_frame = last_gc = last_heartbeat = None
        gc_seen, filtered = {}, []
        for event in events:
            k = event["kind"]
            data = {key: value for key, value in event.items() if key not in ("line", "pid", "pid_source", "_stamp")}
            if k == "heartbeat" and last_frame is not None and event["frame"] < last_frame:
                issues.append(dict(line=event["line"], reason="frame_counter_reset_or_reordered"))
                if not ns:
                    cuts.append(event["line"])
            if k == "gc" and last_gc is not None and event["index"] < last_gc:
                issues.append(dict(line=event["line"], reason="gc_counter_reset_or_reordered"))
                gc_seen = {}
                if not ns:
                    cuts.append(event["line"])
            if k == "gc" and event["index"] in gc_seen:
                reason = "duplicate_gc_ignored" if gc_seen[event["index"]] == data else "conflicting_gc_index"
                issues.append(dict(line=event["line"], reason=reason))
                # Same latest collection cannot become a second observed collection.
                if reason == "conflicting_gc_index":
                    cuts.append(event["line"])
                continue
            if k == "heartbeat" and last_heartbeat == data and event["_stamp"] is None and not ns:
                issues.append(dict(line=event["line"], reason="duplicate_heartbeat_ignored"))
                continue
            if k == "gc":
                if last_gc is not None and event["index"] > last_gc + 1:
                    issues.append(dict(line=event["line"], reason="gc_indices_missing", missing=event["index"] - last_gc - 1))
                last_gc = event["index"]
                gc_seen[event["index"]] = data
            if k == "heartbeat":
                last_frame, last_heartbeat = event["frame"], data
            filtered.append(event)
        events = filtered
        if not events:
            continue

        # NSLog time is its own emission clock; never align GAL's mach-clock origin.
        origin = ns[0][1] if ns else None
        clock_resets = [ns[i][0] for i in range(1, len(ns)) if ns[i][1] < ns[i - 1][1]]
        for n in clock_resets:
            issues.append(dict(line=n, reason="nslog_clock_regressed"))
        cuts.extend(clock_resets)
        if not ns:
            last_anchor = None
            for event in events:
                if event["kind"] == "thermal":
                    if last_anchor is not None and (event["initialization"] or event["second"] < last_anchor):
                        issues.append(dict(line=event["line"], reason="thermal_clock_reset_or_reordered"))
                        cuts.append(event["line"])
                    last_anchor = event["second"]
                if event["kind"] == "mode" and event is not events[0]:
                    cuts.append(event["line"])
        cuts = sorted(set(cuts))
        def segment(n):
            return sum(c <= n for c in cuts)
        anchors = ns if ns else [(e["line"], e["second"]) for e in events if e["kind"] == "thermal"]
        windows, used_segments = {}, set()
        for event in events:
            n, bounds = event["line"], None
            seg = segment(n)
            if ns and event["_stamp"] is not None:
                second = (event["_stamp"] - origin) / 1000000
                # After wall clock regression, do not mix the new clock with old bins.
                if not mixed_basis and second >= 0 and not any(c <= n for c in clock_resets):
                    bounds = [second, second]
                source = "nslog_emission_timestamp"
            else:
                same = [(line, value) for line, value in anchors if segment(line) == seg]
                left = next(((line, value) for line, value in reversed(same) if line <= n), None)
                right = next(((line, value) for line, value in same if line >= n), None)
                if left and right:
                    if ns:
                        lo, hi = (left[1] - origin) / 1000000, (right[1] - origin) / 1000000
                    else:
                        lo, hi = max(0, left[1] - .5), right[1] + .5
                    if not mixed_basis and lo >= 0 and hi >= lo and not any(c <= n for c in clock_resets):
                        bounds = [lo, hi]
                source = "nslog_same_pid_emission_order_bounds" if ns else "gal_rounded_emission_order_bounds"
            event.pop("_stamp")
            event.update(time_bounds=bounds, timing_source=source, clock_segment=seg, window_start_second=None)
            if bounds is not None and int(bounds[0] // WINDOW) == int(bounds[1] // WINDOW):
                w = int(bounds[0] // WINDOW)
                windows.setdefault((0 if ns else seg, w), []).append(event)
                used_segments.add(seg)
                event["window_start_second"] = w * WINDOW
        # Preserve bounded empty-window visibility, separately for each timing segment.
        for seg in {segment(n) for n, _ in anchors}:
            vals = [((v - origin) / 1000000 if ns else v) for n, v in anchors if segment(n) == seg]
            vals = [v for v in vals if v >= 0]
            if vals:
                first, last = int(min(vals) // WINDOW), int(max(vals) // WINDOW)
                if last - first > 10000:
                    issues.append(dict(line=events[-1]["line"], reason="sparse_clock_span_empty_windows_omitted"))
                else:
                    for i in range(first, last + 1):
                        windows.setdefault((0 if ns else seg, i), [])
        result_windows = []
        for (seg, i), obs in sorted(windows.items()):
            window = dict(start_second=i * WINDOW, end_second=(i + 1) * WINDOW, clock_segment=seg,
                          display_fps=None, cpu_queue_present_return_fps=None,
                          observation_lines=[e["line"] for e in obs])
            window.update(aggregate(obs))
            result_windows.append(window)
        peaks = [w["gc"]["max_observed_collection_pause_ms"] for w in result_windows if w["gc"] is not None]
        full = aggregate(events)
        timed = aggregate([e for e in events if e["window_start_second"] is not None])
        mem, states = timed["footprint_mib"], timed["thermal_observed_sequence"]
        clock_safe = bool(anchors) and not mixed_basis and not clock_resets and (pid is not None or not pids) and (bool(ns) or len({segment(n) for n, _ in anchors}) <= 1)
        span = wall_span = None
        if clock_safe and len(anchors) >= 2:
            vals = [v for _, v in anchors]
            if ns:
                wall_span = (max(vals) - min(vals)) / 1000000
            else:
                span = max(0, max(vals) - min(vals) - 1)
        output.append(dict(session=len(output) + 1, pid=pid, end_reason="end_of_input",
            clock="nslog_wall_emission_since_first_observed_prefix" if ns else "gal_thermal_since_first_call_rounded_seconds",
            timing="emission timestamps/bounds only; wall-clock adjustments and writer lag are not capture timing" if ns else "emission_order_bounds_only; PID unknown",
            heartbeat_timer_nominal_seconds=10, heartbeat_cadence_used_for_timestamps=False,
            nslog_wall_observation_span_seconds=wall_span,
            observed_span_lower_bound_seconds=span,
            observed_span_at_least_30_minutes=None if span is None else span >= 1800,
            real_play_30_minutes_verified=False, summary=full, windows=result_windows,
            unwindowed_observations=[e for e in events if e["window_start_second"] is None],
            observed_trends_basis="window_assigned_emission_observations_only; unwindowed samples excluded",
            observed_trends=dict(
                logged_gc_peak_increased=None if not clock_safe or len(peaks) < 2 else peaks[-1] > peaks[0],
                footprint_increased=None if not clock_safe or mem is None or mem["samples"] < 2 else mem["change"] > 0,
                thermal_worsened=None if not clock_safe or not states or len(states) < 2 else STATES.index(states[-1]) > STATES.index(states[0]))))
    return dict(schema_version=2, window_seconds=WINDOW, sessions=output, diagnostics=issues,
        limitations=[
            "Session identity comes from NSLog PID only. Without PID there is one unknown-identity group, not proof of one process; PID reuse cannot be detected without a launch identity.",
            "Unprefixed records use same-PID neighboring emission timestamps; ambiguous multi-PID lines or missing/cross-window bounds stay unwindowed. Single observed PID attribution is explicit inference, not proof no other process was omitted.",
            "NSLog wall emission time is relative to the first observed prefix, not launch/active play. Wall-clock forward adjustments and scheduling/writer lag are unmeasured; regression is diagnosed, not a new process.",
            "GAL rounded relative clock is a separate fallback; no cross-clock alignment. NSTimer nominal 10 seconds may be delayed or lost; cadence/frame numbers never manufacture a timestamp.",
            "Memory is sampled phys_footprint in MiB (producer says MB); zero unknown due to failure sentinel.",
            "Window GC peaks compare logged observations only, not normalized rates or complete coverage. GC reports latest collections only; gaps/absence are not zero; complete count/total pause unknown.",
            "Display FPS and CPU QueuePresent return cadence unknown; requested FPS is rounded configuration (0 = uncapped).",
            "Direct anomaly lines are red-line observations only; the run keeps the same mode, and no image cause, player action or prompt is inferred.",
            "Trends use only observations assigned to windows on one emission time axis; unwindowed numeric samples remain in summary but cannot turn trends true.",
            "NSLog wall observation span is not a monotonic duration lower bound; relative-clock span is separately labeled. Neither is active play duration, real-device testing or acceptance."])


def text_report(report):
    rows = ["长局趋势：每300秒；NSLog PID/写出壁钟优先，GAL相对钟仅独立回退；未知=未测。"]
    for s in report["sessions"]:
        rows.append(f"会话 {s['session']}：PID {s['pid'] if s['pid'] is not None else '未知'}，壁钟观测跨度 {s['nslog_wall_observation_span_seconds']} 秒；相对钟跨度下界 {s['observed_span_lower_bound_seconds']} 秒；30分钟实玩未验证")
        for w in s["windows"]:
            rows.append(f"  {w['start_second'] // 60}–{w['end_second'] // 60} 分：" + json.dumps(
                {k: w[k] for k in ("footprint_mib", "gc", "thermal_observed_sequence", "direct_anomaly_events")}, ensure_ascii=False))
        rows.append("  未归窗观测：" + str(len(s["unwindowed_observations"])) + "；显示FPS/CPU QueuePresent返回节拍：未知")
        rows.append("  观测趋势：" + json.dumps(s["observed_trends"], ensure_ascii=False))
    rows.append("诊断：" + json.dumps(report["diagnostics"], ensure_ascii=False))
    rows.extend(report["limitations"])
    return "\n".join(rows)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("host_log", help="host.log；按NSLog PID分组，未知身份明确保留；不修改输入")
    p.add_argument("--json", action="store_true", help="JSON写stdout，缺测为null")
    args = p.parse_args(argv)
    try:
        with Path(args.host_log).open(encoding="utf-8", errors="replace", newline="") as f:
            report = summarize(f)
    except OSError:
        print("输入不可读（不回显输入路径）", file=sys.stderr)
        return 2
    print(json.dumps(report, ensure_ascii=False, indent=2) if args.json else text_report(report))
    return 0 if report["sessions"] else 2


if __name__ == "__main__":
    sys.exit(main())
