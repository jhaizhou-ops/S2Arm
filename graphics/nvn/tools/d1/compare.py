#!/usr/bin/env python3
"""D1 对比：同一版本的重复性，或基线/候选的 A/B。

退出码：0 通过；1 判定不过；2 输入/环境不合法（不能拿不同款、不同 Metal 档或不同设备硬比）。
"""
import argparse
import json
import sys

SCHEMA = "s2arm.d1.v1"
COUNTERS = ["upload_n", "rb_us", "draw_n", "pass_n", "rw_kb", "shader_miss", "pso_n", "pso_us", "gpuq_us"]
METRIC_LABELS = {
    "upload_n": "上传次数/帧", "rb_us": "读回 us/帧", "draw_n": "绘制数/帧", "pass_n": "通道数/帧",
    "rw_kb": "读写 KB/帧", "shader_miss": "缺着色器/帧", "pso_n": "现建管线/帧",
    "pso_us": "现建管线 us/帧", "gpuq_us": "命令环反压 us/帧",
}


class Invalid(ValueError):
    pass


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except OSError as e:
        raise Invalid(f"{path}: {e}")
    except json.JSONDecodeError as e:
        raise Invalid(f"{path}: JSON 坏了：{e}")
    if doc.get("schema") != SCHEMA:
        raise Invalid(f"{path}: schema = {doc.get('schema')!r}，期望 {SCHEMA}")
    for key in ("environment", "run", "frames", "counters"):
        if key not in doc:
            raise Invalid(f"{path}: 缺 {key}")
    return doc


def pct_delta(base, cand):
    if base == 0:
        return 0.0 if cand == 0 else float("inf")
    return (cand - base) * 100.0 / base


def add(checks, name, base, cand, delta, limit, ok, kind="stat"):
    checks.append({"name": name, "base": base, "cand": cand, "delta": delta, "limit": limit, "ok": bool(ok), "kind": kind})


def compare(base, cand, mode, *, max_median_pct=5.0, max_p95_pct=10.0, max_slow_pp=1.0,
            max_rate_pct=2.0, allow_pixels_diff=False, allow_device_diff=False):
    if mode not in ("repeatability", "ab"):
        raise Invalid("mode 只能是 repeatability / ab")
    eb, ec = base["environment"], cand["environment"]
    if eb["game"] != ec["game"]:
        raise Invalid(f"不同款：base={eb['game']} cand={ec['game']}")
    if eb["mode"] != ec["mode"]:
        raise Invalid(f"不同出图路径：base={eb['mode']} cand={ec['mode']}")
    if eb["metal_api"] != ec["metal_api"]:
        raise Invalid(f"不同 Metal 档：base={eb['metal_api']} cand={ec['metal_api']}")
    if not allow_device_diff and eb.get("device") != ec.get("device"):
        raise Invalid(f"不同设备：base={eb.get('device')} cand={ec.get('device')}（真机基准必须同机）")
    warnings = []
    if mode == "repeatability":
        if eb["commit"] != ec["commit"]:
            raise Invalid(f"重复性要求同一提交：base={eb['commit']} cand={ec['commit']}")
        if ec.get("dirty"):
            warnings.append("候选采集时工作区是脏的：重复性结论只对这份二进制有效")

    checks = []
    bw, cw = base["frames"]["wall_us"], cand["frames"]["wall_us"]
    d = pct_delta(bw["median"], cw["median"])
    add(checks, "帧时中位", bw["median"], cw["median"], d, f"±{max_median_pct}%",
        abs(d) <= max_median_pct if mode == "repeatability" else d <= max_median_pct)
    d = pct_delta(bw["p95"], cw["p95"])
    add(checks, "帧时 p95", bw["p95"], cw["p95"], d, f"±{max_p95_pct}%",
        abs(d) <= max_p95_pct if mode == "repeatability" else d <= max_p95_pct)
    slow_d = cw["slow_pct"] - bw["slow_pct"]
    add(checks, "慢帧占比 pp", bw["slow_pct"], cw["slow_pct"], slow_d, f"±{max_slow_pp}pp",
        abs(slow_d) <= max_slow_pp if mode == "repeatability" else slow_d <= max_slow_pp)

    for k in COUNTERS:
        b = base["counters"].get(k, {}).get("per_frame", 0.0)
        c = cand["counters"].get(k, {}).get("per_frame", 0.0)
        d = pct_delta(b, c)
        add(checks, METRIC_LABELS[k], b, c, d, f"±{max_rate_pct}%", abs(d) <= max_rate_pct, "rate")

    bp, cp = base.get("pixels", {}), cand.get("pixels", {})
    missing = sorted(set(bp) ^ set(cp))
    if missing:
        checks.append({"name": "像素集合", "base": len(bp), "cand": len(cp),
                       "delta": len(missing), "limit": "同一批截图", "ok": False, "kind": "pixels"})
    changed = [k for k in sorted(set(bp) & set(cp)) if bp[k] != cp[k]]
    pixels_ok = not missing and not changed
    if allow_pixels_diff and mode == "ab":
        pixels_ok = True
    checks.append({"name": "像素", "base": len(bp), "cand": len(cp), "delta": len(changed),
                   "limit": "逐张哈希一致" if not allow_pixels_diff else "允许差异", "ok": pixels_ok, "kind": "pixels"})
    if changed and not allow_pixels_diff:
        warnings.append("像素不同的截图：" + "、".join(changed[:6]) + (" …" if len(changed) > 6 else ""))
    if allow_pixels_diff:
        warnings.append("--allow-pixels-diff：像素差异未判红（只应在确认是预期变化时使用）")

    ok = all(c["ok"] for c in checks)
    return {"ok": ok, "mode": mode, "checks": checks, "warnings": warnings}


def format_report(result, base_path, cand_path):
    head = "重复性" if result["mode"] == "repeatability" else "A/B"
    lines = [f"D1 {head}：{'通过' if result['ok'] else '不通过'}", "",
             f"base = {base_path}", f"cand = {cand_path}", "",
             "| 指标 | base | cand | 变化 | 限 | 结果 |", "|---|---:|---:|---:|---:|---|"]
    for c in result["checks"]:
        delta = "—" if c["delta"] in (float("inf"), float("-inf")) else f"{c['delta']:+.2f}"
        lines.append(f"| {c['name']} | {c['base']} | {c['cand']} | {delta} | {c['limit']} | {'✅' if c['ok'] else '❌'} |")
    for w in result["warnings"]:
        lines.append(f"\n> {w}")
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description="D1 重复性 / A/B 对比")
    ap.add_argument("--mode", choices=("repeatability", "ab"), required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--cand", required=True)
    ap.add_argument("--max-median-pct", type=float, default=5.0)
    ap.add_argument("--max-p95-pct", type=float, default=10.0)
    ap.add_argument("--max-slow-pp", type=float, default=1.0)
    ap.add_argument("--max-rate-pct", type=float, default=2.0)
    ap.add_argument("--allow-pixels-diff", action="store_true")
    ap.add_argument("--allow-device-diff", action="store_true")
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args(argv)
    try:
        base, cand = load(args.base), load(args.cand)
        result = compare(base, cand, args.mode, max_median_pct=args.max_median_pct,
                         max_p95_pct=args.max_p95_pct, max_slow_pp=args.max_slow_pp,
                         max_rate_pct=args.max_rate_pct, allow_pixels_diff=args.allow_pixels_diff,
                         allow_device_diff=args.allow_device_diff)
    except Invalid as e:
        print(f"【红】D1 输入不合法：{e}", file=sys.stderr)
        return 2
    print(format_report(result, args.base, args.cand))
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
