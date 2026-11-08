#!/usr/bin/env python3
"""Offline two-run PNG comparison, macOS ImageIO + Python standard library."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import zlib
from datetime import datetime, timezone

MAX_BYTES = 128 * 1024 * 1024
SSIM_VARIANT = ("RGB mean; non-overlapping uniform blocks; population moments; "
                "edge area weighted; K1=.01 K2=.03 L=255")
DEFAULTS = dict(pixel_delta=8, equal_fraction=.001, large_fraction=.25,
                min_ssim=.995, block_size=8, feature_max=.08, feature_margin=.01,
                near_black=16, content_variance=64., content_fraction=.10,
                black_fraction=.05, missing_fraction=.02)


class Invalid(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Invalid(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_bytes(path, limit):
    require(path.is_file(), "not a regular file: " + path.name)
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    require(len(data) <= limit, "input exceeds size limit: " + path.name)
    return data


def validate_png(data):
    require(data.startswith(b"\x89PNG\r\n\x1a\n"), "not PNG data")
    offset, header, pixels, ended = 8, False, False, False
    compressed, dimensions = [], None
    while offset < len(data):
        require(offset + 12 <= len(data), "truncated PNG chunk")
        length, kind = struct.unpack_from(">I4s", data, offset)
        end = offset + length + 12
        require(end <= len(data), "truncated PNG payload")
        payload = data[offset + 8:end - 4]
        require(zlib.crc32(kind + payload) & 0xffffffff ==
                struct.unpack_from(">I", data, end - 4)[0], "PNG CRC mismatch")
        if not header:
            require(kind == b"IHDR" and length == 13, "PNG missing IHDR")
        if kind == b"IHDR":
            require(not header and length == 13, "duplicate/invalid IHDR")
            header = True
            w, h, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            require(0 < w <= 16384 and 0 < h <= 16384 and w * h <= 16777216, "PNG dimension limit")
            require(depth == 8 and color in (0, 2, 3, 4, 6) and compression == 0 and filtering == 0
                    and interlace == 0, "requires noninterlaced 8-bit PNG")
            channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
            dimensions = h, w * channels + 1
        elif kind == b"acTL":
            raise Invalid("animated PNG unsupported")
        elif kind == b"IDAT":
            pixels = True
            compressed.append(payload)
        elif kind == b"IEND":
            require(length == 0 and end == len(data), "PNG IEND/trailing data")
            ended = True
        offset = end
    require(header and pixels and ended, "PNG incomplete")
    rows, stride = dimensions
    expected = rows * stride
    try:
        stream = zlib.decompressobj()
        raw = stream.decompress(b"".join(compressed), expected + 1)
    except zlib.error as error:
        raise Invalid("invalid PNG deflate stream") from error
    require(len(raw) == expected and stream.eof and not stream.unused_data and not stream.unconsumed_tail,
            "invalid PNG decoded byte count/stream")
    require(all(raw[row * stride] <= 4 for row in range(rows)), "invalid PNG row filter")


def codec(binary, action, images, *args):
    for image in images:
        validate_png(image)
    wire = b"".join(struct.pack(">I", len(data)) + data for data in images)
    result = subprocess.run([str(binary), action, *map(str, args)], input=wire,
                            capture_output=True, timeout=120, check=False)
    require(result.returncode == 0, "PNG measurement failed: " +
            result.stderr.decode("utf-8", "replace").strip())
    return json.loads(result.stdout)


def relative_file(root, name):
    require(isinstance(name, str) and bool(name) and not Path(name).is_absolute()
            and ".." not in Path(name).parts and name.lower().endswith(".png"),
            "frame path must be a relative PNG without ..")
    path = (root / name).resolve()
    require(path.is_relative_to(root), "frame escapes run directory")
    return path


def strict_int(value):
    return type(value) is int


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def load_run(directory, binary):
    root = Path(directory).resolve()
    manifest_path = (root / "direct_compare.json").resolve()
    require(manifest_path.is_relative_to(root), "manifest escapes run")
    raw = read_bytes(manifest_path, 4 * 1024 * 1024)
    manifest = json.loads(raw, object_pairs_hook=unique_object)
    require(isinstance(manifest, dict) and set(manifest) ==
            {"version", "game", "build", "route", "capture", "mode", "frames"},
            "invalid manifest fields")
    require(strict_int(manifest["version"]) and manifest["version"] == 1, "unsupported manifest version")
    for key in ["game", "build", "route", "capture"]:
        value = manifest[key]
        require(isinstance(value, str) and 0 < len(value.strip()) <= 256, "invalid identity: " + key)
    require(manifest["mode"] in ("direct", "generic"), "mode must be direct or generic")
    require(isinstance(manifest["frames"], list) and 1 <= len(manifest["frames"]) <= 4096,
            "require 1...4096 frames")
    frames, paths, previous, dimensions = [], set(), -1, None
    for item in manifest["frames"]:
        require(isinstance(item, dict) and set(item) == {"id", "file"}, "invalid frame entry")
        require(strict_int(item["id"]) and previous < item["id"] <= 1_000_000_000,
                "frame ids must be nonnegative and strictly increasing in manifest order")
        previous = item["id"]
        path = relative_file(root, item["file"])
        require(path not in paths, "duplicate frame file")
        paths.add(path)
        data = read_bytes(path, MAX_BYTES)
        info = codec(binary, "inspect", [data])
        size = info["width"], info["height"]
        dimensions = size if dimensions is None else dimensions
        require(size == dimensions, "run changes image dimensions")
        frames.append(dict(item, path=path, sha256=digest(data), feature=info["feature"]))
    return dict(root=root, manifest=manifest, manifestSHA256=digest(raw),
                frames=frames, dimensions=dimensions)


def classify(metrics, policy):
    if (metrics["changedFraction"] <= policy["equal_fraction"] and metrics["ssimRGB"] >= policy["min_ssim"]
            and not any(b["changedPixels"] > 0 and b["ssimRGB"] < policy["min_ssim"] for b in metrics.get("blocks", []))):
        return "一致"
    return "大面积不一致" if metrics["changedFraction"] >= policy["large_fraction"] else "局部不一致"


def align(left, right, method, radius, policy):
    matches, last = [], -1
    by_id = {frame["id"]: j for j, frame in enumerate(right)}
    for i, frame in enumerate(left):
        if method == "frame":
            j = by_id.get(frame["id"])
            matches.append(dict(left=i, right=j, reason="exact-frame-id" if j is not None else "missing-frame-id",
                                distance=None, runnerUp=None))
            continue
        candidates = []
        for j, other in enumerate(right):
            if j <= last or abs(frame["id"] - other["id"]) > radius:
                continue
            distance = sum(abs(a - b) for a, b in zip(frame["feature"], other["feature"])) / 192
            candidates.append((distance, j))
        candidates.sort()
        best = candidates[0] if candidates else None
        second = candidates[1][0] if len(candidates) > 1 else None
        reason = ("no-candidate" if best is None else "feature-too-far" if best[0] > policy["feature_max"]
                  else "ambiguous-feature" if second is not None and second - best[0] < policy["feature_margin"]
                  else "feature-nearest")
        j = best[1] if reason == "feature-nearest" else None
        if j is not None:
            last = j
        matches.append(dict(left=i, right=j, reason=reason, distance=best[0] if best else None, runnerUp=second))
    return matches


def validate_policy(p):
    require(0 <= p["pixel_delta"] <= 254, "pixel-delta must be 0...254")
    require(p["block_size"] == 8, "calibrated comparison requires block-size=8")
    require(0 <= p["near_black"] <= 254, "near-black must be 0...254")
    for key in ["content_variance", "content_fraction", "black_fraction", "missing_fraction"]:
        require(math.isfinite(p[key]), key + " must be finite")
    require(0 < p["content_variance"] <= 16256.25, "content-variance must be (0,16256.25]")
    require(0 <= p["black_fraction"] < p["content_fraction"] <= 1, "require black-fraction < content-fraction in [0,1]")
    require(0 < p["missing_fraction"] <= .02, "missing-fraction must be (0,.02]; cannot weaken owner area gate")
    for key in ["equal_fraction", "large_fraction", "min_ssim", "feature_max", "feature_margin"]:
        require(math.isfinite(p[key]), key + " must be finite")
    require(0 <= p["equal_fraction"] < p["large_fraction"] <= 1, "require 0 <= equal-fraction < large-fraction <= 1")
    require(0 < p["min_ssim"] <= 1, "min-ssim must be (0,1]")
    require(0 <= p["feature_max"] <= 1 and 0 < p["feature_margin"] <= 1, "invalid feature thresholds")


def index_run(args):
    root = Path(args.run).resolve()
    require(not Path(args.frames).is_absolute() and ".." not in Path(args.frames).parts, "invalid frames directory")
    directory = (root / args.frames).resolve()
    require(directory.is_relative_to(root), "frames directory escapes run")
    frames = []
    for path in directory.iterdir():
        if path.suffix.lower() != ".png":
            continue
        match = re.fullmatch(r"f_([0-9]+)\.png", path.name)
        require(match is not None, "cannot infer frame id: " + path.name + "; use explicit manifest")
        frame_id = int(match[1])
        require(frame_id <= 1_000_000_000, "frame id too large")
        frames.append(dict(id=frame_id, file=str(Path(args.frames) / path.name)))
    frames.sort(key=lambda f: f["id"])
    require(1 <= len(frames) <= 4096 and len({f["id"] for f in frames}) == len(frames), "empty or duplicate frames")
    result = dict(version=1, frames=frames)
    for key in ["game", "build", "route", "capture", "mode"]:
        value = getattr(args, key)
        require(0 < len(value.strip()) <= 256, "invalid identity: " + key)
        result[key] = value
    return result


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, allow_nan=False) + "\n").encode("utf-8")


def pair_images(frames):
    images = [read_bytes(f["path"], MAX_BYTES) for f in frames]
    require(all(digest(data) == f["sha256"] for data, f in zip(images, frames)), "input frame changed")
    return images


def verify_manifests(runs):
    for run in runs:
        require(digest(read_bytes(run["root"] / "direct_compare.json", 4 * 1024 * 1024)) ==
                run["manifestSHA256"], "manifest changed")


def missing_side(block, p):
    # Independent of dynamic masking and SSIM: luminance is Rec.709 on sRGB bytes.
    for content, black in [("left", "right"), ("right", "left")]:
        if (block[content + "LumaVariance"] >= p["content_variance"]
                and block[content + "NonBlackFraction"] >= p["content_fraction"]
                and block[black + "NonBlackFraction"] <= p["black_fraction"]):
            return black
    return None


def blank_side(block, p):
    # Low-texture disappearance cannot be certified as normal motion or missing content.
    for content, black in [("left", "right"), ("right", "left")]:
        if (block[content + "NonBlackFraction"] >= p["content_fraction"] and
                block[black + "NonBlackFraction"] <= p["black_fraction"]):
            return black
    return None


def grid_png(path, dimensions, colors):
    # One RGB row at a time, including partial edge tiles; no image dependency.
    w, h = dimensions
    columns = (w + 7) // 8
    compressor, packed = zlib.compressobj(), []
    for y in range(h):
        row = b"\0" + b"".join(bytes(colors[(y // 8) * columns + x // 8]) for x in range(w))
        packed.append(compressor.compress(row))
    packed.append(compressor.flush())
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
                     chunk(b"IDAT", b"".join(packed)) + chunk(b"IEND", b""))


def calibration(binary, runs, p):
    a, b = runs
    require(a["root"] != b["root"] and a["manifest"]["capture"] != b["manifest"]["capture"],
            "calibration requires two distinct captures")
    require(all(a["manifest"][k] == b["manifest"][k] for k in ["game", "build", "route", "mode"]),
            "calibration game/build/route/mode differs")
    require(a["dimensions"] == b["dimensions"], "calibration dimensions differ")
    require([f["id"] for f in a["frames"]] == [f["id"] for f in b["frames"]],
            "calibration requires complete exact frame-id pairs; no heuristic alignment")
    mask, areas, pairs, reasons = None, None, [], []
    for left, right in zip(a["frames"], b["frames"]):
        m = codec(binary, "compare", pair_images([left, right]), "-", p["pixel_delta"], 8, p["near_black"])
        blocks = m.pop("blocks")
        if mask is None:
            mask = [False] * len(blocks)
            areas = [v["width"] * v["height"] for v in blocks]
        dynamic, missing = 0, 0
        for i, v in enumerate(blocks):
            changed = v["changedPixels"] > 0 or v["ssimRGB"] < p["min_ssim"]
            mask[i] |= changed
            dynamic += areas[i] if changed else 0
            missing += areas[i] if missing_side(v, p) else 0
        if any(all(v[side + "NonBlackFraction"] == 0 for v in blocks) for side in ["left", "right"]):
            reasons.append("calibration-blank-reference")
        ambiguous = sum(area for v, area in zip(blocks, areas) if blank_side(v, p) and not missing_side(v, p))
        if ambiguous / sum(areas) > p["missing_fraction"]:
            reasons.append("calibration-low-texture-one-sided-black")
        fraction = missing / sum(areas)
        if fraction > p["missing_fraction"]:
            reasons.append("calibration-one-sided-missing-content")
        pairs.append(dict(leftFrame=left["id"], rightFrame=right["id"], leftSHA256=left["sha256"],
                          rightSHA256=right["sha256"], alignment="exact-frame-id", rawMetrics=m,
                          dynamicPixels=dynamic, missingFraction=fraction, ambiguousBlackFraction=ambiguous / sum(areas)))
    masked = sum(area for area, dynamic in zip(areas, mask) if dynamic)
    if masked / sum(areas) > .5:
        reasons.append("dynamic-mask-over-50-percent")
    verify_manifests(runs)
    return dict(version=2, kind="same-mode-dynamic-calibration", blockSize=8, policy=p,
                sourceDirectories=[str(r["root"]) for r in runs],
                identities=[r["manifest"] for r in runs], manifestSHA256=[r["manifestSHA256"] for r in runs],
                dimensions=list(a["dimensions"]), mask=mask, maskedPixels=masked,
                maskedFraction=masked / sum(areas), staticPixels=sum(areas) - masked,
                coverage=dict(leftFrames=len(a["frames"]), rightFrames=len(b["frames"]), paired=len(pairs),
                              leftFraction=1., rightFraction=1.), pairs=pairs,
                status="unverified" if reasons else "calibrated", reasons=sorted(set(reasons)))


def compare_runs(args):
    p = {key: getattr(args, key) for key in DEFAULTS}
    validate_policy(p)
    require(0 <= (args.radius or 0) <= 10000, "radius must be 0...10000")
    require((args.align == "feature") == (args.radius is not None), "feature requires --radius; frame mode forbids it")
    require(bool(args.calibrate) != bool(args.calibration), "require exactly one of --calibrate A B or --calibration report.json")
    binary = Path(args.codec).resolve()
    require(binary.is_file() and os.access(binary, os.X_OK), "codec not built; run tools/direct_compare/build_png_metrics.sh")
    a, b = load_run(args.left, binary), load_run(args.right, binary)
    require(a["root"] != b["root"] and a["manifest"]["capture"] != b["manifest"]["capture"], "require distinct captures")
    require(all(a["manifest"][key] == b["manifest"][key] for key in ["game", "build", "route"]), "game/build/route differs")
    require(a["dimensions"] == b["dimensions"], "run dimensions differ; no resize/crop")
    saved = None
    if args.calibration:
        saved = json.loads(read_bytes(Path(args.calibration).resolve(), 64 * 1024 * 1024), object_pairs_hook=unique_object)
        require(isinstance(saved, dict) and saved.get("version") == 2 and saved.get("policy") == p,
                "calibration version/policy differs")
        require(isinstance(saved.get("sourceDirectories"), list) and len(saved["sourceDirectories"]) == 2,
                "invalid calibration sources")
    sources = args.calibrate or saved["sourceDirectories"]
    c, d = [load_run(source, binary) for source in sources]
    for run in [c, d]:
        require(all(run["manifest"][k] == a["manifest"][k] for k in ["game", "build", "route"]),
                "calibration identity differs from evaluation")
        require(run["dimensions"] == a["dimensions"], "calibration dimensions differ from evaluation")
        require(run["manifest"]["mode"] in [a["manifest"]["mode"], b["manifest"]["mode"]], "calibration mode absent from evaluation")
        for evaluated in [a, b]:
            require(run["manifest"]["capture"] != evaluated["manifest"]["capture"] and
                    not {f["path"] for f in run["frames"]}.intersection(f["path"] for f in evaluated["frames"]),
                    "calibration and evaluation must use independent captures/files")
    calibrated_ids = {f["id"] for f in c["frames"]}
    require(all(f["id"] in calibrated_ids for r in [a, b] for f in r["frames"]),
            "calibration does not cover evaluation frame IDs; no extrapolation to unsampled frames")
    cal = calibration(binary, [c, d], p)
    require(saved is None or saved == cal, "calibration stale/tampered: source hashes or computed mask differ")
    out = Path(args.out).resolve()
    require(not out.exists(), "output already exists; choose a new directory")
    for run in [a, b, c, d]:
        require(not out.is_relative_to(run["root"]) and not run["root"].is_relative_to(out), "output overlaps input")
    matches = align(a["frames"], b["frames"], args.align, args.radius or 0, p)
    out.mkdir()
    cal_data = json_bytes(cal)
    (out / "calibration.json").write_bytes(cal_data)
    (out / "mask.bin").write_bytes(bytes(cal["mask"]))
    grid_png(out / "dynamic-mask.png", a["dimensions"], [(0, 0, 255) if v else (0, 0, 0) for v in cal["mask"]])
    pairs, used, worst, evaluation_reasons = [], set(), "未验证", []
    persistent_missing, flagged_pairs = None, 0
    order = {"未验证": -1, "一致": 0, "局部不一致": 1, "大面积不一致": 2, "缺内容": 3}
    for match in matches:
        frame = a["frames"][match["left"]]
        pair = dict(leftFrame=frame["id"], leftFile=frame["file"], leftSHA256=frame["sha256"],
                    alignment=match["reason"], featureDistance=match["distance"], runnerUpDistance=match["runnerUp"],
                    rightFrame=None, metrics=None)
        if match["right"] is not None:
            j = match["right"]
            other = b["frames"][j]
            heat = f"heat-{match['left']}-{frame['id']}-{other['id']}.png"
            raw = codec(binary, "compare", pair_images([frame, other]), out / heat, p["pixel_delta"], 8,
                        p["near_black"], out / "mask.bin")
            blocks = raw.pop("blocks")
            if all(v["leftNonBlackFraction"] == 0 and v["rightNonBlackFraction"] == 0 for v in blocks):
                evaluation_reasons.append("both-evaluation-frames-near-black")
            static, missing, ambiguous, missing_colors = [], [], [], []
            for i, block in enumerate(blocks):
                block["dynamic"] = cal["mask"][i]
                block["missingSide"] = missing_side(block, p)
                block["ambiguousBlackSide"] = (blank_side(block, p) if block["dynamic"] and not block["missingSide"] else None)
                if block["ambiguousBlackSide"]:
                    ambiguous.append(block)
                if not block["dynamic"]:
                    static.append(block)
                if block["missingSide"]:
                    missing.append(block)
                missing_colors.append((255, 0, 0) if block["missingSide"] == "left" else
                                      (0, 255, 0) if block["missingSide"] == "right" else (255, 255, 0) if block["ambiguousBlackSide"] else (0, 0, 0))
            sides = [v["missingSide"] for v in blocks]
            persistent_missing = sides if persistent_missing is None else [
                old if old == new else None for old, new in zip(persistent_missing, sides)]
            area = lambda block: block["width"] * block["height"]
            pixels = sum(map(area, static))
            metrics = dict(width=raw["width"], height=raw["height"], staticPixels=pixels,
                           maskedFraction=cal["maskedFraction"],
                           changedPixels=sum(v["changedPixels"] for v in static),
                           changedFraction=sum(v["changedPixels"] for v in static) / pixels if pixels else None,
                           ssimRGB=sum(v["ssimRGB"] * area(v) for v in static) / pixels if pixels else None,
                           mae=sum(v["mae"] * area(v) for v in static) / pixels if pixels else None,
                           maxDelta=max((v["maxDelta"] for v in static), default=None),
                           badBlocks=sum(v["changedPixels"] > 0 and v["ssimRGB"] < p["min_ssim"] for v in static),
                           worstBlockSSIM=min((v["ssimRGB"] for v in static), default=None),
                           missingBlocks=len(missing), missingPixels=sum(map(area, missing)),
                           missingFraction=sum(map(area, missing)) / (raw["width"] * raw["height"]),
                           ambiguousBlackBlocks=len(ambiguous),
                           ambiguousBlackFraction=sum(map(area, ambiguous)) / (raw["width"] * raw["height"]),
                           rawMetrics=raw)
            if metrics["ambiguousBlackFraction"] > p["missing_fraction"]:
                evaluation_reasons.append("masked-low-texture-one-sided-black")
            metrics["staticClassification"] = classify(dict(metrics, blocks=static), p) if pixels else "未验证"
            metrics["missingClassification"] = "缺内容" if metrics["missingFraction"] > p["missing_fraction"] else "未检出"
            flagged_pairs += metrics["missingClassification"] == "缺内容"
            metrics["classification"] = ("缺内容" if metrics["missingClassification"] == "缺内容" else
                                         metrics["staticClassification"])
            missing_heat = f"missing-{match['left']}.png"
            grid_png(out / missing_heat, a["dimensions"], missing_colors)
            block_name = f"blocks-{match['left']}-{frame['id']}-{other['id']}.json"
            block_data = json_bytes(blocks)
            (out / block_name).write_bytes(block_data)
            pair.update(rightFrame=other["id"], rightFile=other["file"], rightSHA256=other["sha256"],
                        metrics=metrics, heatmap=heat, missingHeatmap=missing_heat,
                        blocksFile=block_name, blocksSHA256=digest(block_data))
            if metrics["classification"] != "未验证":
                worst = max(worst, metrics["classification"], key=order.get)
            used.add(j)
        pairs.append(pair)
    verify_manifests([a, b, c, d])
    count = len(used)
    unused = [f["id"] for j, f in enumerate(b["frames"]) if j not in used]
    complete = count == len(a["frames"]) and not unused and cal["status"] == "calibrated" and not evaluation_reasons
    persistent_pixels = 0
    if persistent_missing is not None:
        w, h = a["dimensions"]
        columns = (w + 7) // 8
        persistent_pixels = sum(min(8, w - (i % columns) * 8) * min(8, h - (i // columns) * 8)
                                for i, side in enumerate(persistent_missing) if side)
    report = dict(version=2, tool="direct-compare/2", status="compared" if complete else "incomplete",
                  classification=worst if complete else "未验证", observedClassification=worst if count else "未验证",
                  unverifiedReasons=sorted(set(cal["reasons"] + evaluation_reasons + ([] if count == len(a["frames"]) and not unused else ["incomplete-evaluation-alignment"]))),
                  createdUTC=datetime.now(timezone.utc).isoformat(),
                  identities=dict(left=a["manifest"], right=b["manifest"]),
                  manifestSHA256=dict(left=a["manifestSHA256"], right=b["manifestSHA256"]),
                  comparisonKind="same-mode-evaluation" if a["manifest"]["mode"] == b["manifest"]["mode"] else "cross-mode",
                  calibration=dict(file="calibration.json", sha256=digest(cal_data), mask="dynamic-mask.png",
                                   maskedFraction=cal["maskedFraction"], staticPixels=cal["staticPixels"],
                                   status=cal["status"], reasons=cal["reasons"], independentCaptures=True),
                  missingContent=dict(evaluatedPairs=count, flaggedPairs=flagged_pairs,
                                      persistentMissingBlocks=sum(bool(v) for v in persistent_missing or []),
                                      persistentMissingPixels=persistent_pixels,
                                      persistentMissingFraction=persistent_pixels / (a["dimensions"][0] * a["dimensions"][1]),
                                      persistence=("unverified" if not count else "single-pair-only" if count == 1 else
                                                   "persistent-across-all-pairs" if persistent_pixels else
                                                   "intermittent" if flagged_pairs else "not-detected")),
                  policy=p, policyValidatedOnRealGames=False,
                  pixelPolicy="opaque 8-bit PNG, ImageIO -> sRGB, top-left row-major RGB; no resize/crop/registration",
                  ssimVariant=SSIM_VARIANT,
                  alignment=dict(method=args.align, radiusFrameIDs=args.radius or 0, monotonicOneToOne=True),
                  coverage=dict(leftFrames=len(a["frames"]), rightFrames=len(b["frames"]), paired=count,
                                leftFraction=count / len(a["frames"]), rightFraction=count / len(b["frames"]),
                                unusedRightFrameIDs=unused), pairs=pairs,
                  limitations=["listed sample frames only; persistence means sampled pairs, not unseen gameplay",
                               "capture/save/time/route assertions cannot prove independent real recordings",
                               "missing-content is a one-sided near-black heuristic, not semantic proof; inspect heatmaps",
                               "feature matching may hide transient faults; calibration uses exact frame IDs only",
                               "thresholds provisional; two-real-game and direct/delivery review pending; no WP1/board integration"])
    (out / "report.json").write_bytes(json_bytes(report))
    (out / "summary.md").write_text(
        f"# 直连 / 通用抽帧对比\n\n状态：{report['status']}；判断：{report['classification']}；"
        f"已配对部分最差：{report['observedClassification']}\n\n"
        f"配对 {count} / 左 {len(a['frames'])} / 右 {len(b['frames'])}；对齐 {args.align}。\n\n"
        f"动态掩码 {cal['maskedFraction']:.6%}；静态像素 {cal['staticPixels']}；校准 {cal['status']}。\n\n"
        f"未验证原因：{', '.join(report['unverifiedReasons']) or '无'}。\n\n"
        "静态 SSIM 与全屏缺内容检测分别报告；阈值待真实两款校准。真实图像和热图只留持有者本地。\n", encoding="utf-8")
    print(json.dumps(dict(status=report["status"], classification=report["classification"], paired=count,
                          report=str(out / "report.json")), ensure_ascii=False))
    return 0 if complete and worst == "一致" else 1 if complete else 2


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("left")
    p.add_argument("right")
    p.add_argument("--out", required=True, help="new report directory; never inside input")
    p.add_argument("--codec", default=os.environ.get("DIRECT_COMPARE_CODEC", "build/direct_compare/png-metrics"))
    calibration_options = p.add_mutually_exclusive_group()
    calibration_options.add_argument("--calibrate", nargs=2, metavar=("RUN_A", "RUN_B"), help="two independent same-mode calibration runs")
    calibration_options.add_argument("--calibration", help="saved calibration.json; sources must remain available and are recomputed")
    p.add_argument("--align", choices=["frame", "feature"], default="frame")
    p.add_argument("--radius", type=int, help="feature candidate radius in frame IDs, 0...10000")
    for key, value in DEFAULTS.items():
        p.add_argument("--" + key.replace("_", "-"), type=type(value), default=value)
    return p


def main():
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "index":
            p = argparse.ArgumentParser(description="Index rec/f_<frame>.png; identity fields are user assertions.")
            p.add_argument("run")
            for key in ["game", "build", "route", "capture", "mode"]:
                p.add_argument("--" + key, required=True, choices=["direct", "generic"] if key == "mode" else None)
            p.add_argument("--frames", default="rec")
            print(json.dumps(index_run(p.parse_args(sys.argv[2:])), ensure_ascii=False, indent=2))
            return 0
        return compare_runs(parser().parse_args())
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps(dict(status="error", classification="未验证", error=str(error)), ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
