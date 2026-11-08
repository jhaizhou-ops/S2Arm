#!/usr/bin/env python3
"""Read-only survey of complete NVN direct-library MSL files (issue #58 E2).

Inputs: LABEL=/path/to/mac/b-<chain>, at least two distinct games, same chain.
Only aggregate TSVs go to --out. --evidence holds private paths/file hashes.
Neither output directory may exist or be inside an input directory.
"""

import argparse
import collections
import csv
import hashlib
import itertools
import json
from pathlib import Path
import re


SOURCE = re.compile(r"([0-9a-f]{16})_(b|bf|bv|bg[0-4v]|b_t[012]|ft)\.metal")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def signature(path):
    st = path.stat()
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns


def read_tracked(path, inventory):
    require(path.is_file() and not path.is_symlink(), f"not a regular input: {path}")
    before = signature(path)
    data = path.read_bytes()
    require(before == signature(path), f"input changed while reading: {path}")
    digest = hashlib.sha256(data).hexdigest()
    inventory[path] = (before, digest)
    return data, digest


def scan(label, root, representatives):
    require(re.fullmatch(r"b-[0-9a-f]{12}", root.name), f"not a chain directory: {root}")
    inventory = {}
    stamp_data, _ = read_tracked(root / "inputs.tsv", inventory)
    stamp = {}
    for row in csv.reader(stamp_data.decode("utf-8").splitlines(), delimiter="\t"):
        if not row or row[0].startswith("#"):
            continue
        require(len(row) == 2 and row[0] not in stamp, f"invalid inputs.tsv: {root}")
        stamp[row[0]] = row[1]
    require(re.fullmatch(r"[0-9a-fA-F]{16}", stamp.get("game", "")), f"missing game ID: {root}")
    require(re.fullmatch(r"[0-9a-f]{12}", stamp.get("inputs", "")), f"missing profile digest: {root}")
    build_data, _ = read_tracked(root / "_b_build.json", inventory)
    build = json.loads(build_data)
    require(isinstance(build, list) and build, f"empty or invalid build manifest: {root}")
    keys = []
    for row in build:
        require(isinstance(row, dict) and re.fullmatch(r"[0-9a-f]{16}", row.get("key", "")),
                f"invalid key in build manifest: {root}")
        require(row.get("st") == "ok" and not row.get("err"), f"build manifest has failures: {root}")
        keys.append(row["key"])
    require(len(keys) == len(set(keys)), f"duplicate build keys: {root}")
    keys = set(keys)
    paths = sorted(root.glob("*.metal"))
    primary = {p.name[:-8] for p in paths if p.name.endswith("_b.metal")}
    require(primary == keys, f"primary MSL set differs from build manifest: {root}")
    counts = {s: collections.Counter() for s in ("primary", "all")}
    sizes = {s: 0 for s in counts}
    variants = collections.Counter()
    conventions = collections.Counter()
    stages = collections.Counter()
    for path in paths:
        match = SOURCE.fullmatch(path.name)
        require(match is not None and match[1] in keys, f"unaccounted MSL file: {path}")
        variant = match[2]
        data, digest = read_tracked(path, inventory)
        require(data, f"empty MSL file: {path}")
        # A hash match is only a candidate; confirm identical complete bytes.
        previous = representatives.setdefault(digest, path)
        if previous != path:
            require(previous.read_bytes() == data, f"hash collision or changed input: {path}")
        variants[variant] += 1
        counts["all"][digest] += 1
        sizes["all"] += len(data)
        if variant == "b":
            counts["primary"][digest] += 1
            sizes["primary"] += len(data)
            meta_data, _ = read_tracked(path.with_suffix(".json"), inventory)
            meta = json.loads(meta_data)
            require(isinstance(meta, dict) and isinstance(meta.get("stage"), str)
                    and isinstance(meta.get("chain_metal"), str) and meta["chain_metal"],
                    f"missing stage or compile convention: {path.with_suffix('.json')}")
            require(meta.get("chain") == root.name[2:], f"reflection chain mismatch: {path.with_suffix('.json')}")
            stages[meta["stage"]] += 1
            conventions[meta["chain_metal"]] += 1
    return dict(label=label, root=root, game=stamp["game"].lower(), inputs=stamp["inputs"],
                chain=root.name[2:], counts=counts, sizes=sizes, variants=variants,
                conventions=conventions, stages=stages, paths=paths, inventory=inventory)


def write_tsv(path, header, rows):
    with path.open("x", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
        writer.writerow(header)
        writer.writerows(rows)


def percent(numerator, denominator):
    return f"{100 * numerator / denominator:.6f}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("samples", nargs="+", metavar="LABEL=CHAIN_DIR")
    parser.add_argument("--out", required=True, type=Path, help="new directory for public aggregate TSVs")
    parser.add_argument("--evidence", required=True, type=Path, help="new PRIVATE directory for file identities")
    args = parser.parse_args()
    specs = []
    for item in args.samples:
        label, separator, directory = item.partition("=")
        require(separator and re.fullmatch(r"[A-Za-z0-9_-]+", label) and label != "ALL", "use LABEL=CHAIN_DIR")
        specs.append((label, Path(directory).resolve(strict=True)))
    require(len(specs) >= 2, "at least two samples required")
    require(len({label for label, _ in specs}) == len(specs), "duplicate sample labels")
    require(len({p for _, p in specs}) == len(specs), "duplicate input directories")
    require(len({p.name for _, p in specs}) == 1, "samples must use the same translation chain")
    out, evidence = args.out.resolve(), args.evidence.resolve()
    require(not out.exists() and not evidence.exists(), "output directories must not exist")
    require(out != evidence and out not in evidence.parents and evidence not in out.parents,
            "public and private outputs must be separate directories")
    for dest in (out, evidence):
        require(all(root != dest and root not in dest.parents for _, root in specs), "output would modify an input directory")
    representatives = {}
    samples = [scan(label, root, representatives) for label, root in specs]
    require(len({s["game"] for s in samples}) == len(samples), "samples must be distinct games")
    # Recheck every consumed file after the full scan, not only each local read.
    for sample in samples:
        require(sorted(sample["root"].glob("*.metal")) == sample["paths"], "MSL file set changed")
        for path, (before, _) in sample["inventory"].items():
            require(not path.is_symlink() and signature(path) == before, f"input changed during survey: {path}")
    out.mkdir(parents=True)
    evidence.mkdir(parents=True)
    identities, variants, summary, pairs = [], [], [], []
    for s in samples:
        rows = [(p.name, before[2], digest, *before) for p, (before, digest) in sorted(s["inventory"].items())]
        write_tsv(evidence / f'{s["label"]}-files.tsv',
                  ["file", "bytes", "sha256", "device", "inode", "size", "mtime_ns", "ctime_ns"], rows)
        content_id = hashlib.sha256("".join(f"{r[0]}\t{r[1]}\t{r[2]}\n" for r in rows).encode()).hexdigest()
        identities.append([s["label"], s["game"], s["chain"], s["inputs"], len(s["inventory"]), content_id])
        variants.extend([s["label"], variant, n] for variant, n in sorted(s["variants"].items()))
    for scope in ("primary", "all"):
        combined = collections.Counter()
        membership = collections.Counter()
        for s in samples:
            c = s["counts"][scope]
            n = c.total()
            summary.append([scope, s["label"], n, len(c), n - len(c), percent(n - len(c), n), s["sizes"][scope]])
            combined.update(c)
            membership.update(c.keys())
        n = combined.total()
        summary.append([scope, "ALL", n, len(combined), n - len(combined), percent(n - len(combined), n),
                        sum(s["sizes"][scope] for s in samples)])
        for a, b in itertools.combinations(samples, 2):
            left, right = set(a["counts"][scope]), set(b["counts"][scope])
            shared, union = len(left & right), len(left | right)
            pairs.append([scope, a["label"], b["label"], shared, union, percent(shared, union),
                          len(left) + len(right), percent(shared, len(left) + len(right))])
        shared = sum(n > 1 for n in membership.values())
        sum_unique = membership.total()
        pairs.append([scope, "ALL", "ALL", shared, len(combined), percent(shared, len(combined)),
                      sum_unique, percent(sum_unique - len(combined), sum_unique)])
    write_tsv(out / "samples.tsv", ["sample", "game_id", "chain", "profile_inputs", "tracked_files", "content_inventory_sha256"], identities)
    write_tsv(out / "variants.tsv", ["sample", "variant", "files"], variants)
    write_tsv(out / "summary.tsv", ["scope", "sample", "files", "unique_texts", "duplicate_files", "duplicate_pct", "bytes"], summary)
    write_tsv(out / "cross.tsv", ["scope", "left", "right", "shared_unique", "union_unique", "shared_union_pct", "sum_per_game_unique", "merge_reduction_pct"], pairs)
    private = [{"sample": s["label"], "root": str(s["root"]), "primary_stages": dict(s["stages"]),
                "primary_compile_conventions": dict(s["conventions"])} for s in samples]
    (evidence / "inputs.json").write_text(json.dumps(private, indent=2) + "\n", encoding="utf-8")
    print(f"PASS samples={len(samples)} primary={sum(s['counts']['primary'].total() for s in samples)} "
          f"all={sum(s['counts']['all'].total() for s in samples)}; aggregate TSVs: {out}")


if __name__ == "__main__":
    main()
