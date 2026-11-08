#!/usr/bin/env python3
"""D1 基准采集：把一个局目录归一化成 d1.json。

只读 frames.tsv / host.log / shots/*.png，不跑游戏、不猜读数；同一份 d1.json 可以在 Linux 上复核。
局目录由 runtime/run_mac.sh 产出（见 README）。
"""
import argparse
import hashlib
import json
import os
import platform
import struct
import subprocess
import sys
from pathlib import Path

SCHEMA = "s2arm.d1.v1"
COUNTERS = ["upload_n", "rb_us", "draw_n", "pass_n", "rw_kb", "shader_miss", "pso_n", "pso_us", "gpuq_us"]
CONFIG_KEYS = ["S2A_FPS", "S2A_ALT", "S2A_RUN_S", "DM_NVN_PRODUCER_COVER", "DM_NVN_DEFER_AB"]


class CaptureError(ValueError):
    pass


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()


def png_pixel_hash(path):
    """只哈希 IHDR+IDAT：忽略 PNG 元数据（时间戳一类），同一帧内容可重复。"""
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "raw:" + sha256_file(path).split(":", 1)[1]
    off, ihdr, idat = 8, None, bytearray()
    while off + 8 <= len(data):
        length = struct.unpack(">I", data[off:off + 4])[0]
        ctype = data[off + 4:off + 8]
        payload = data[off + 8:off + 8 + length]
        if ctype == b"IHDR":
            ihdr = payload
        elif ctype == b"IDAT":
            idat += payload
        elif ctype == b"IEND":
            break
        off += 12 + length
    if ihdr is None:
        return "raw:" + sha256_file(path).split(":", 1)[1]
    h = hashlib.sha256()
    h.update(b"IHDR")
    h.update(ihdr)
    h.update(idat)
    return "png:" + h.hexdigest()


def parse_frames(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        head = f.readline().rstrip("\n").split("\t")
        if "frame" not in head or "wall_us" not in head:
            raise CaptureError(f"{path}: 表头缺 frame / wall_us")
        idx = {k: i for i, k in enumerate(head)}
        rows = []
        for lineno, line in enumerate(f, 2):
            line = line.rstrip("\n")
            if not line:
                continue
            cols = line.split("\t")
            if len(cols) < len(head):
                cols += [""] * (len(head) - len(cols))
            row = {}
            for k in ("frame", "wall_us"):
                try:
                    row[k] = int(cols[idx[k]] or 0)
                except ValueError:
                    raise CaptureError(f"{path}:{lineno}: {k} 不是整数")
            for k in COUNTERS:
                i = idx.get(k)
                if i is None:
                    row[k] = 0
                    continue
                try:
                    row[k] = int(cols[i] or 0)
                except ValueError:
                    raise CaptureError(f"{path}:{lineno}: {k} 不是整数")
            rows.append(row)
    if not rows:
        raise CaptureError(f"{path}: 没有数据行")
    return rows


def percentile(vals, p):
    if not vals:
        return 0
    vals = sorted(vals)
    if p <= 0:
        return vals[0]
    if p >= 100:
        return vals[-1]
    # nearest-rank：第 ceil(p/100 * n) 个（1 基）
    k = int((p / 100.0) * len(vals) + 0.999999)
    return vals[min(max(k, 1), len(vals)) - 1]


def summarize_frames(rows, slow_us=None):
    wall = [r["wall_us"] for r in rows]
    median = percentile(wall, 50.0)
    if slow_us is None:
        slow_us = max(2 * median, 1)
    slow_n = sum(1 for v in wall if v > slow_us)
    return {
        "count": len(rows),
        "median": median,
        "p95": percentile(wall, 95.0),
        "p99": percentile(wall, 99.0),
        "max": max(wall),
        "slow_us": slow_us,
        "slow_pct": round(100.0 * slow_n / len(wall), 3),
    }


def summarize_counters(rows):
    n = len(rows)
    out = {}
    for k in COUNTERS:
        total = sum(r[k] for r in rows)
        out[k] = {"sum": total, "per_frame": round(total / n, 6)}
    return out


def git_state(repo):
    def run(*args):
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    try:
        commit = run("rev-parse", "HEAD").stdout.strip()
        dirty = bool(run("status", "--porcelain", "-uno").stdout.strip())
        return commit or "unknown", dirty
    except OSError:
        return "unknown", False


def config_snapshot():
    return {k: os.environ[k] for k in CONFIG_KEYS if k in os.environ}


def build_capture(run_dir, *, game, device, mode, metal_api, label="", commit=None, repo=None, slow_us=None):
    run_dir = Path(run_dir)
    frames_path = run_dir / "frames.tsv"
    if not frames_path.exists():
        raise CaptureError(f"{run_dir}: 缺 frames.tsv（runtime/run_mac.sh 没设置 S2A_FRAMES_TSV？）")
    rows = parse_frames(frames_path)
    if commit is None or commit == "auto":
        commit, dirty = git_state(repo or Path.cwd())
    else:
        dirty = False
    if not game:
        raise CaptureError("缺 --game（同一款游戏的两次采集才能比）")
    if metal_api not in (3, 4):
        raise CaptureError("--metal-api 只能是 3 或 4")
    shots = {}
    for p in sorted((run_dir / "shots").glob("*.png")):
        shots[str(p.relative_to(run_dir))] = png_pixel_hash(p)
    files = {"frames_sha256": sha256_file(frames_path)}
    host = run_dir / "host.log"
    if host.exists():
        files["host_log_sha256"] = sha256_file(host)
    wall = summarize_frames(rows, slow_us)
    return {
        "schema": SCHEMA,
        "label": label,
        "environment": {
            "commit": commit,
            "dirty": dirty,
            "os": platform.platform(),
            "arch": platform.machine(),
            "machine": platform.node(),
            "game": game,
            "device": device,
            "mode": mode,
            "metal_api": metal_api,
            "config": config_snapshot(),
        },
        "run": {"frames": len(rows), "seconds": round(sum(r["wall_us"] for r in rows) / 1e6, 3)},
        "frames": {"wall_us": wall},
        "counters": summarize_counters(rows),
        "pixels": shots,
        "files": files,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="把一个 Mac 局目录归一化成 D1 基准 JSON")
    ap.add_argument("run_dir")
    ap.add_argument("--out", required=True)
    ap.add_argument("--game", required=True)
    ap.add_argument("--device", default="unknown")
    ap.add_argument("--mode", choices=("direct", "generic"), default="direct")
    ap.add_argument("--metal-api", type=int, choices=(3, 4), default=4)
    ap.add_argument("--label", default="")
    ap.add_argument("--commit", default="auto")
    ap.add_argument("--repo", default=None)
    ap.add_argument("--slow-us", type=int, default=None)
    args = ap.parse_args(argv)
    try:
        out = build_capture(args.run_dir, game=args.game, device=args.device, mode=args.mode,
                            metal_api=args.metal_api, label=args.label, commit=args.commit,
                            repo=args.repo, slow_us=args.slow_us)
    except CaptureError as e:
        print(f"【红】D1 采集失败：{e}", file=sys.stderr)
        return 2
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print(f"D1 采集：{out['run']['frames']} 帧 / {out['run']['seconds']} 秒，像素 {len(out['pixels'])} 张 → {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
