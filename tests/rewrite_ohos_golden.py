#!/usr/bin/env python3
# 门禁手动：要游戏 exefs 与鸿蒙金样目录（不进仓库），本地对拍工具
"""Compare C rewriter S2A_TARGET=ohos output to a golden program dir."""
from __future__ import annotations
import hashlib, os, subprocess, sys, tempfile
from pathlib import Path

def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: rewrite_ohos_golden.py <game-exefs-dir> <golden-dir> [rewriter-binary]", file=sys.stderr)
        return 2
    game, gold = Path(argv[1]), Path(argv[2])
    rew = Path(argv[3]) if len(argv) > 3 else Path(os.environ.get("S2A_REWRITER_C", ""))
    if not rew.is_file():
        print(f"rewriter binary missing: {rew}", file=sys.stderr)
        return 1
    out = Path(os.environ.get("OUT_DIR") or tempfile.mkdtemp(prefix="ohos-golden-"))
    out.mkdir(parents=True, exist_ok=True)
    spin = os.environ.get("S2A_REWRITE_SPIN", "0")
    bad = 0
    compared = 0
    files = ("patched.bin", "fixups.tsv", "gates.tsv", "sites.tsv", "gaps.tsv")
    for mod in ("main", "sdk", "subsdk0"):
        src = game / mod
        if not src.is_file():
            print(f"skip missing input module: {mod}")
            continue
        exp_bin = gold / f"{mod}.patched.bin"
        if not exp_bin.is_file():
            print(f"golden missing {mod}.patched.bin under {gold}", file=sys.stderr)
            bad = 1
            continue
        mod_out = out / mod
        mod_out.mkdir(parents=True, exist_ok=True)
        print(f"rewrite {mod} ...")
        env = os.environ.copy()
        env["S2A_TARGET"] = "ohos"
        env["S2A_REWRITE_SPIN"] = spin
        r = subprocess.run([str(rew), str(src), str(mod_out), mod], env=env)
        if r.returncode != 0:
            print(f"rewriter rc={r.returncode} for {mod}", file=sys.stderr)
            bad = 1
            continue
        for f in files:
            got, exp = mod_out / f"{mod}.{f}", gold / f"{mod}.{f}"
            if not exp.is_file():
                if got.is_file():
                    print(f"MISS golden {mod}.{f} (but rewriter produced it)", file=sys.stderr)
                    bad = 1
                continue
            if not got.is_file():
                print(f"MISS output {mod}.{f}", file=sys.stderr)
                bad = 1
                continue
            compared += 1
            hs, hg = sha256(got), sha256(exp)
            if hs == hg:
                print(f"OK  {mod}.{f}  {hs}")
            else:
                print(f"DIFF {mod}.{f}  got={hs}  golden={hg}", file=sys.stderr)
                bad = 1
    if bad:
        print(f"rewrite_ohos_golden: mismatches (OUT={out})", file=sys.stderr)
        return 1
    if not compared:
        print(f"rewrite_ohos_golden: compared 0 files (OUT={out})", file=sys.stderr)
        return 1
    print(f"rewrite_ohos_golden: {compared} compared files match (OUT={out})")
    return 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
