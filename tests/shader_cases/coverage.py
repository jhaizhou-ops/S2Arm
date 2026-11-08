# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Source-derived coverage, never case-declared rule coverage.

Instruction coverage means decoded binary presence, not dynamic execution.
Pass events must come from the runner's IR observation, not a case's `rules`.
Patch attribution is intentionally unsupported: source overlap with a changed
pass does not prove the patch's semantics ran. All patches remain uncovered.
"""
import hashlib
from pathlib import Path
import re
import struct

SHADER = "compat/tree/src/Ryujinx.Graphics.Shader"


class CoverageError(ValueError):
    """Missing, malformed, or unaccountable coverage evidence."""


def _read(path):
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise CoverageError(f"cannot read coverage source {path}: {exc}") from exc


def _code(text):
    # Preserve strings (instruction encodings), remove C# comments.
    return re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/',
                  lambda m: m[0] if m[0].startswith('"') else " ", text)


def instruction_table(repo):
    text = _code(_read(repo / SHADER / "Decoders/InstTable.cs"))
    bits_match = re.search(r'\bconst\s+int\s+EncodingBits\s*=\s*(\d+)\s*;', text)
    if not bits_match or not 1 <= int(bits_match[1]) <= 16:
        raise CoverageError("InstTable EncodingBits missing or unsupported")
    bits = int(bits_match[1])
    calls = re.findall(r'\bAdd\s*\(\s*"[^;]+;', text)
    entries = []
    for call in calls:
        match = re.fullmatch(r'Add\s*\(\s*"([01x]{64})"\s*,\s*InstName\.(\w+)\s*,\s*InstEmit\.(\w+)(?:\s*,\s*InstProps\.\w+(?:\s*\|\s*InstProps\.\w+)*)?\s*\)\s*;', call)
        if not match:
            raise CoverageError(f"unsupported InstTable Add: {call[:160]}")
        encoding, name, emitter = match.groups()
        prefix = encoding[:bits]
        mask = int(''.join('0' if c == 'x' else '1' for c in prefix), 2)
        value = int(prefix.replace('x', '0'), 2)
        entries.append((mask, value, prefix.count('x'), name, emitter))
    # Catch changed registration syntax rather than silently dropping rows.
    if not entries or len(calls) != len(re.findall(r'\bInstEmit\.', text)):
        raise CoverageError("InstTable emitter registrations cannot be fully parsed")
    table = []
    for opcode in range(1 << bits):
        matches = [e for e in entries if opcode & e[0] == e[1]]
        table.append(min(matches, key=lambda e: e[2])[4] if matches else None)
    return bits, entries, table


def pass_sources(repo):
    base = repo / SHADER / "Translation"
    transform = _code(_read(base / "Transforms/TransformPasses.cs"))
    optimization = _code(_read(base / "Optimizations/Optimizer.cs"))
    names = {
        "Transforms": set(re.findall(r'\bRunPass<(\w+)>\s*\(context\)', transform)),
        "Optimizations": set(re.findall(r'\b(\w+)\.RunPass\w*\s*\(', optimization)),
    }
    result = {}
    for directory, classes in names.items():
        if not classes:
            raise CoverageError(f"no registered passes parsed in {directory}")
        for name in sorted(classes):
            source = f"{SHADER}/Translation/{directory}/{name}.cs"
            text = _code(_read(repo / source))
            if not re.search(r'\bclass\s+' + re.escape(name) + r'\b', text) or not re.search(r'\bRunPass\w*\s*\(', text):
                raise CoverageError(f"registered pass has no implementation: {source}")
            if name in result:
                raise CoverageError(f"ambiguous pass class: {name}")
            result[name] = source
    # A newly added pass must not silently disappear because its dispatcher
    # changed shape or it has not yet been wired into the known entrypoint.
    for directory, classes in names.items():
        for path in sorted((base / directory).glob("*.cs")):
            text = _code(_read(path))
            if path.stem in {"TransformPasses", "Optimizer", "ITransformPass"}:
                continue
            if re.search(r"\bpublic\s+static\s+\w+(?:<[^>]+>)?\s+RunPass\w*\s*\(", text):
                if path.stem not in classes:
                    raise CoverageError(f"pass not accounted by dispatcher: {path}")
    return result


def shader_patches(repo):
    directory = repo / "compat/patches"
    series = [line.split('#', 1)[0].strip() for line in _read(directory / "series").splitlines()]
    result = []
    seen = set()
    for name in filter(None, series):
        if Path(name).name != name or not name.endswith('.patch') or name in seen:
            raise CoverageError(f"unsupported/duplicate patch series entry: {name}")
        seen.add(name)
        text = _read(directory / name)
        headers = re.findall(r'^diff --git a/(\S+) b/(\S+)\s*$', text, re.M)
        if not headers:
            raise CoverageError(f"patch has no parseable diff headers: {name}")
        if any(path.startswith("src/Ryujinx.Graphics.Shader/") for pair in headers for path in pair):
            result.append(name)
    if not seen:
        raise CoverageError("empty patch series")
    return sorted(result)


def _metric(all_items, covered):
    all_items, covered = set(all_items), set(covered)
    return {"total": len(all_items), "count": len(covered), "covered": sorted(covered),
            "uncovered": sorted(all_items - covered)}


def collect_coverage(repo, manifest, events):
    """Consume runner-created binary manifest and observed IR event list.

    Manifest: [{id, stage: compute|vertex|fragment|geometry|tess_control|
    tess_evaluation, binary: absolute path}]. IR event: {case, kind: pass,
    name: class name, source: repository-relative path, before_ir, after_ir,
    before, after}; hashes are lowercase SHA256 UTF-8 text digests. Unchanged
    snapshots are valid observations but earn no coverage. Malformed evidence
    fails closed. This validates integrity, not authenticity of an arbitrary
    caller; only the real runner's instrumentation is an evidence producer.
    """
    repo = Path(repo)
    bits, entries, table = instruction_table(repo)
    passes = pass_sources(repo)
    patches = shader_patches(repo)
    decoded, changed, case_ids = set(), set(), set()
    for case in manifest:
        case_id = case.get("id")
        if not isinstance(case_id, str) or not case_id or case_id in case_ids:
            raise CoverageError("missing/duplicate case id")
        case_ids.add(case_id)
        stage = case.get("stage")
        if stage not in {"compute", "vertex", "fragment", "geometry", "tess_control", "tess_evaluation"}:
            raise CoverageError(f"unsupported stage for {case_id}: {stage}")
        path = Path(case.get("binary", ""))
        if not path.is_absolute():
            raise CoverageError(f"binary path must be absolute: {case_id}")
        try:
            data = path.read_bytes()
        except OSError as exc:
            raise CoverageError(f"cannot read binary for {case_id}: {exc}") from exc
        header = 0 if stage == "compute" else 0x50
        if len(data) < header + 16 or (len(data) - header) % 8:
            raise CoverageError(f"truncated shader binary: {case_id}")
        for offset in range(header, len(data), 8):
            if (offset - header) % 32 == 0:
                continue  # Scheduler word, never an instruction.
            word = struct.unpack_from("<Q", data, offset)[0]
            emitter = table[word >> (64 - bits)]
            if emitter is None:
                raise CoverageError(f"unknown Maxwell opcode: {case_id}@{offset:#x}={word:#018x}")
            decoded.add(emitter)
    for event in events:
        if event.get("case") not in case_ids:
            raise CoverageError("IR event refers to an unknown case")
        if event.get("kind") != "pass":
            raise CoverageError("patch attribution not implemented; do not infer from source overlap")
        name = event.get("name")
        if name not in passes or event.get("source") != passes[name]:
            raise CoverageError(f"unregistered pass or wrong source: {name}")
        for side in ("before", "after"):
            ir = event.get(side + "_ir")
            if not isinstance(ir, str) or not ir.strip():
                raise CoverageError(f"missing actual {side} IR: {name}")
            if event.get(side) != hashlib.sha256(ir.encode("utf-8")).hexdigest():
                raise CoverageError(f"IR {side} digest mismatch: {name}")
        if event["before_ir"] != event["after_ir"]:
            changed.add(name)
    result = {"instructions": _metric((e[4] for e in entries), decoded),
              "passes": _metric(passes, changed), "patches": _metric(patches, [])}
    result["instructions"].update(table_rows=len(entries), instruction_names=len({e[3] for e in entries}), scope="decoded presence, not execution")
    result["patches"]["limitation"] = "No patch-specific semantic attribution; all uncovered, not inferred from pass overlap."
    return result
