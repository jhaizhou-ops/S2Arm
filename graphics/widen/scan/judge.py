#!/usr/bin/env python3
"""J02: validate read-only replay evidence, then consult the user's Claude CLI.

Usage: python3 graphics/widen/scan/judge.py INPUT [--timeout 180]
JSON on stdout only; never writes a widen_full table. See skills/widen-judge/.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import shutil
import struct
import subprocess
import sys
import zlib

VERSION = "s2a-widen-judge/1"
CHECKS = ("stretch", "alignment", "ui_bounds", "bright_bands", "flicker", "side_content")
METRIC_KEYS = (
    "hole_side_fraction_max", "center_psnr_db_min", "ui_width_ratio_min",
    "ui_width_ratio_max", "ui_height_ratio_min", "ui_height_ratio_max",
    "flicker_excess_luma_max",
)
ESTABLISHED_LIMITS = {
    "hole_side_fraction_max": (0.0, 0.005),
    "center_psnr_db_min": (30.0, 999.0),
}

MAX_IMAGE = 16 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
SKILL = Path(__file__).resolve().parents[3] / "skills/widen-judge"


def strict_json(text):
    def pairs(items):
        out = {}
        for key, value in items:
            if key in out:
                raise ValueError("duplicate JSON key")
            out[key] = value
        return out
    def constant(_):
        raise ValueError("non-finite JSON value")
    return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)


def exact(obj, keys, where):
    if not isinstance(obj, dict) or set(obj) != set(keys):
        raise ValueError(f"{where}: unexpected or missing fields")


def integer(value):
    return type(value) is int and value >= 0


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def png_size(data):
    """Check framing, CRC, dimensions and bounded decompression of pixel data."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not PNG")
    offset, size, seen_data, compressed = 8, None, False, []
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 8 + length
        if end + 4 > len(data):
            raise ValueError("truncated PNG")
        payload = data[offset + 8:end]
        if zlib.crc32(kind + payload) & 0xffffffff != struct.unpack(">I", data[end:end + 4])[0]:
            raise ValueError("PNG CRC mismatch")
        if size is None:
            if kind != b"IHDR" or length != 13:
                raise ValueError("missing PNG header")
            w, h, bits, color, comp, filt, interlace = struct.unpack(">IIBBBBB", payload)
            if not (0 < w <= 8192 and 0 < h <= 8192 and bits in (1, 2, 4, 8, 16)
                    and w * h <= 16 * 1024 * 1024 and bits == 8
                    and color in (0, 2, 4, 6) and comp == filt == interlace == 0):
                raise ValueError("unsupported PNG header")
            size = (w, h)
        elif kind == b"IHDR":
            raise ValueError("duplicate PNG header")
        if kind == b"IDAT":
            compressed.append(payload)
        seen_data |= kind == b"IDAT" and length > 0
        offset = end + 4
        if kind == b"IEND":
            if length != 0 or offset != len(data) or not seen_data:
                raise ValueError("incomplete PNG")
            channels = {0: 1, 2: 3, 4: 2, 6: 4}[color]
            row = 1 + w * channels
            expected = h * row
            inflater = zlib.decompressobj()
            pixels = inflater.decompress(b"".join(compressed), expected + 1)
            if (len(pixels) != expected or not inflater.eof or inflater.unused_data
                    or inflater.unconsumed_tail or any(pixels[y * row] > 4 for y in range(h))):
                raise ValueError("invalid PNG pixel stream")
            return size
    raise ValueError("missing PNG end")


def read_evidence(root):
    metric_path = root / "metrics.json"
    if metric_path.is_symlink() or not metric_path.is_file() or metric_path.stat().st_size > 1024 * 1024:
        raise ValueError("missing/oversized/symlink metrics.json")
    raw = metric_path.read_bytes()
    doc = strict_json(raw)
    exact(doc, ("version", "capture", "key_frames", "continuous_frames", "mark", "metrics"), "metrics.json")
    if doc["version"] != VERSION:
        raise ValueError("unsupported metrics protocol; no auto_table JSON adapter assumed")
    capture = doc["capture"]
    exact(capture, ("replay_sha256", "fps"), "capture")
    if not isinstance(capture["replay_sha256"], str) or len(capture["replay_sha256"]) != 64 or any(
            c not in "0123456789abcdef" for c in capture["replay_sha256"]):
        raise ValueError("missing replay SHA256")
    fps = capture["fps"]
    if type(fps) is not int or not 1 <= fps <= 120:
        raise ValueError("fps must be integer 1..120")
    keys, frames = doc["key_frames"], doc["continuous_frames"]
    if not isinstance(keys, list) or len(keys) != 4:
        raise ValueError("need exactly four paired key frames")
    if not isinstance(frames, list) or len(frames) != 2 * fps + 1:
        raise ValueError("need inclusive, consecutive two-second frames")
    tracked = {"metrics.json": digest(raw)}
    sizes, total = {}, len(raw)
    def read_pair(pair):
        nonlocal total
        exact(pair, ("frame", "orig", "wide"), "frame pair")
        if not integer(pair["frame"]):
            raise ValueError("invalid frame number")
        for side in ("orig", "wide"):
            item = pair[side]
            exact(item, ("file", "sha256"), "image")
            file = item["file"]
            if not isinstance(file, str):
                raise ValueError("image path must be a string")
            rel = PurePosixPath(file)
            if (rel.is_absolute() or len(rel.parts) != 2 or rel.parts[0] != side
                    or rel.name in ("", ".", "..") or rel.suffix != ".png"
                    or str(rel) != file or "\\" in file):
                raise ValueError("image path must be directly under orig/ or wide/")
            path = root / file
            if (path.is_symlink() or path.parent.is_symlink() or not path.is_file()
                    or path.stat().st_size > MAX_IMAGE):
                raise ValueError("missing/oversized/symlink image")
            data = path.read_bytes()
            sha = digest(data)
            if sha != item["sha256"]:
                raise ValueError("image SHA256 does not match producer metrics")
            size = png_size(data)
            if side in sizes and size != sizes[side]:
                raise ValueError("image dimensions change within capture")
            sizes[side] = size
            if file not in tracked:
                total += len(data)
            tracked[file] = sha
            if total > MAX_TOTAL:
                raise ValueError("evidence exceeds 256 MiB")
    for pair in keys + frames + [doc["mark"]]:
        read_pair(pair)
    ids = [p["frame"] for p in keys]
    if ids != sorted(set(ids)):
        raise ValueError("key frames must be distinct and chronological")
    ids = [p["frame"] for p in frames]
    if ids != list(range(ids[0], ids[0] + len(ids))):
        raise ValueError("continuous frames must be consecutive and chronological")
    w0, h0 = sizes["orig"]
    w1, h1 = sizes["wide"]
    if h0 != h1 or w1 <= w0 or abs(w0 - h0 * 16 / 9) > 1:
        raise ValueError("orig must be 16:9 and wide must add columns at equal height")
    metrics = doc["metrics"]
    exact(metrics, METRIC_KEYS, "metrics")
    if any(not number(value) for value in metrics.values()):
        raise ValueError("metrics must be finite numbers, never booleans")
    if not (0 <= metrics["hole_side_fraction_max"] <= 1 and
            0 <= metrics["center_psnr_db_min"] <= 999 and
            0 <= metrics["flicker_excess_luma_max"] <= 1):
        raise ValueError("metrics outside physical range")
    for axis in ("width", "height"):
        lo, hi = metrics[f"ui_{axis}_ratio_min"], metrics[f"ui_{axis}_ratio_max"]
        if not 0 < lo <= hi:
            raise ValueError("UI ratio range must be positive and ordered")
    identity = digest(json.dumps(tracked, sort_keys=True).encode())
    return doc, tracked, identity


def tool_verdict(metrics, policy=None):
    limits = dict(ESTABLISHED_LIMITS)
    if policy is not None:
        tol = policy["ui_ratio_tolerance"]
        limits.update({key: (1 - tol, 1 + tol) for key in METRIC_KEYS if key.startswith("ui_")})
        limits["flicker_excess_luma_max"] = (0.0, policy["flicker_excess_luma_max"])
    return {key: {"value": metrics[key], "min": lo, "max": hi,
                  "pass": lo <= metrics[key] <= hi}
            for key, (lo, hi) in limits.items()}


def read_policy(path, root):
    if path is None:
        return None
    path = Path(path).resolve(strict=True)
    # An evidence producer or image prompt cannot choose the release thresholds.
    if path.is_relative_to(root) or path.stat().st_size > 16384:
        raise ValueError("policy must be caller-selected and outside evidence")
    doc = strict_json(path.read_bytes())
    exact(doc, ("version", "ui_ratio_tolerance", "flicker_excess_luma_max", "basis"), "policy")
    if doc["version"] != VERSION or not isinstance(doc["basis"], str) or not doc["basis"].strip():
        raise ValueError("policy needs a confirmed threshold basis")
    for key in ("ui_ratio_tolerance", "flicker_excess_luma_max"):
        if not number(doc[key]) or not 0 <= doc[key] < 1:
            raise ValueError("invalid caller threshold")
    return doc


def response_schema():
    check = {"type": "object", "additionalProperties": False,
             "properties": {"pass": {"type": "boolean"}, "reason": {"type": "string", "minLength": 1}},
             "required": ["pass", "reason"]}
    return {"type": "object", "additionalProperties": False,
            "properties": {"version": {"const": VERSION}, "input_sha256": {"type": "string"},
                           "checks": {"type": "object", "additionalProperties": False,
                                      "properties": {key: check for key in CHECKS}, "required": list(CHECKS)},
                           "evidence_complete": {"type": "boolean"},
                           "uncertain": {"type": "boolean"},
                           "inspected_files": {"type": "array", "items": {"type": "string"}, "uniqueItems": True}},
            "required": ["version", "input_sha256", "checks", "evidence_complete", "uncertain", "inspected_files"]}


def validate_ai(doc, identity, files):
    exact(doc, ("version", "input_sha256", "checks", "evidence_complete", "uncertain", "inspected_files"), "AI result")
    if doc["version"] != VERSION or doc["input_sha256"] != identity:
        raise ValueError("AI result does not match evidence")
    if type(doc["evidence_complete"]) is not bool or type(doc["uncertain"]) is not bool:
        raise ValueError("AI certainty must be boolean")
    inspected = doc["inspected_files"]
    if (not isinstance(inspected, list) or any(not isinstance(x, str) for x in inspected)
            or len(inspected) != len(set(inspected)) or set(inspected) != set(files)):
        raise ValueError("AI did not confirm every input artifact")
    exact(doc["checks"], CHECKS, "AI checks")
    for check in doc["checks"].values():
        exact(check, ("pass", "reason"), "AI check")
        if (type(check["pass"]) is not bool or not isinstance(check["reason"], str)
                or not 1 <= len(check["reason"].strip()) <= 400):
            raise ValueError("AI check needs boolean and a short reason")
    return doc["evidence_complete"] and not doc["uncertain"] and all(x["pass"] for x in doc["checks"].values())


def call_claude(root, identity, files, timeout, cli):
    # Only trusted repository skill text is a system instruction. Screenshot text
    # and metrics are untrusted evidence; no shell, edit, MCP or plugin tools.
    prompt = "\n\n".join((SKILL / f).read_text() for f in (
        "SKILL.md", "references/criteria.md", "references/protocol.md"))
    request = json.dumps({"task": "逐一读取下列全部原/宽关键帧、连续帧和 MARK，以及 metrics.json；仅输出符合 schema 的判定。",
                          "input_sha256": identity, "files": sorted(files)}, ensure_ascii=False)
    args = [cli, "-p", "--restricted", "--safe-mode", "--tools", "Read",
            "--allowedTools", "Read", "--permission-mode", "dontAsk",
            "--setting-sources", "", "--settings", '{"disableAllHooks":true}',
            "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
            "--disallowedTools", "mcp__*", "--disable-slash-commands",
            "--no-session-persistence", "--output-format", "json",
            "--json-schema", json.dumps(response_schema()), "--system-prompt", prompt]
    env = dict(os.environ, DISABLE_AUTOUPDATER="1", CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1")
    proc = subprocess.run(args, input=request, text=True, cwd=root, env=env,
                          capture_output=True, timeout=timeout, check=False)
    # Never echo CLI stderr/stdout on failure: they can include auth/account data.
    if proc.returncode:
        return None, {"state": "missing", "reason": "cli_failed_or_not_logged_in", "cli_exit": proc.returncode}
    if len(proc.stdout) > 1024 * 1024:
        raise ValueError("oversized AI output")
    envelope = strict_json(proc.stdout)
    if not isinstance(envelope, dict):
        raise ValueError("CLI output is not a result object")
    if envelope.get("is_error") is True or str(envelope.get("subtype", "")).startswith("error"):
        return None, {"state": "missing", "reason": "cli_error_or_not_logged_in"}
    if envelope.get("type") != "result" or envelope.get("subtype") != "success":
        raise ValueError("CLI did not finish successfully")
    if "structured_output" not in envelope:
        raise ValueError("CLI did not return structured_output")
    return envelope["structured_output"], {"state": "returned", "reason": "validated_below"}


def judge(root, timeout=180, policy=None):
    result = {"version": VERSION, "status": "输入错误", "allow_widen_full": False,
              "input_sha256": None, "tools": {}, "ai": {"state": "not_run"}}
    try:
        root = Path(root).resolve(strict=True)
        doc, files, identity = read_evidence(root)
    except (OSError, ValueError, TypeError, KeyError, OverflowError, zlib.error) as exc:
        result["reason"] = f"invalid_evidence: {type(exc).__name__}"
        return result, 2
    result["input_sha256"] = identity
    result["tools"] = tool_verdict(doc["metrics"])
    try:
        policy = read_policy(policy, root)
    except (OSError, ValueError, TypeError):
        result["reason"] = "invalid_threshold_policy"
        return result, 2
    result["tools"] = tool_verdict(doc["metrics"], policy)
    if not all(c["pass"] for c in result["tools"].values()):
        result.update(status="不过", reason="tool_failed")
        return result, 1
    result["policy"] = policy
    if os.environ.get("S2A_WIDEN_AI") == "0":
        result.update(status="缺判官", reason="disabled")
        return result, 3
    cli = shutil.which("claude")
    if cli is None:
        result.update(status="缺判官", reason="cli_not_found")
        return result, 3
    if policy is None:
        result.update(status="待确认判据", reason="unverified_policy")
        return result, 5
    try:
        answer, state = call_claude(root, identity, files, timeout, cli)
        result["ai"] = state
        if answer is None:
            result.update(status="缺判官", reason=state["reason"])
            return result, 3
        passed = validate_ai(answer, identity, files)
        # Bind the result to the evidence and fail closed if producer changes it
        # while the AI is reading; never chmod or mutate the producer directory.
        _, _, after = read_evidence(root)
        if after != identity:
            raise ValueError("input changed during AI review")
        result["ai"] = {"state": "validated", "result": answer}
        result.update(status="过" if passed else "不过", reason="ai_passed" if passed else "ai_rejected",
                      allow_widen_full=passed)
        return result, 0 if passed else 1
    except subprocess.TimeoutExpired:
        result.update(status="缺判官", reason="cli_timeout")
        return result, 3
    except OSError:
        result.update(status="缺判官", reason="cli_could_not_start")
        return result, 3
    except (ValueError, KeyError, TypeError, OverflowError, zlib.error):
        result.update(status="判官错误", reason="invalid_ai_result_or_changed_evidence")
        return result, 4


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="read-only evidence directory with metrics.json")
    parser.add_argument("--timeout", type=float, default=180, help="Claude timeout seconds (1..600)")
    parser.add_argument("--policy", help="caller-approved UI/flicker thresholds outside input directory")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 1 <= args.timeout <= 600:
        parser.error("--timeout must be 1..600 seconds")
    result, code = judge(args.input, args.timeout, args.policy)
    print(json.dumps(result, ensure_ascii=False, allow_nan=False))
    return code


if __name__ == "__main__":
    sys.exit(main())
