#!/usr/bin/env python3
"""Read-only NSO A64 CFG cycle inventory. See docs/arm64_loops.md.

Reuses the repository's bounded NSO reader, fixed dependencies and exception
barriers. Never executes input, follows indirect targets, or writes patches.
"""

import argparse
import hashlib
import json
import os
import stat
import struct
import sys

from arm64_aspect_locator import _branch_target, _dependencies, _exception_barrier, _segments


def components(nodes, edges):
    """Iterative Kosaraju: no recursion limit proportional to input size."""
    seen, order = set(), []
    for start in sorted(nodes):
        if start in seen:
            continue
        seen.add(start)
        stack = [(start, iter(edges[start]))]
        while stack:
            node, it = stack[-1]
            nxt = next(it, None)
            if nxt is None:
                order.append(node)
                stack.pop()
            elif nxt not in seen:
                seen.add(nxt)
                stack.append((nxt, iter(edges[nxt])))
    reverse = {n: [] for n in nodes}
    for a in nodes:
        for b in edges[a]:
            reverse[b].append(a)
    seen, result = set(), []
    for start in reversed(order):
        if start in seen:
            continue
        todo, group = [start], set()
        seen.add(start)
        while todo:
            n = todo.pop()
            group.add(n)
            for p in reverse[n]:
                if p not in seen:
                    seen.add(p)
                    todo.append(p)
        result.append(group)
    return result, reverse


def canonical(name):
    # Match storage aliases, not arithmetic width. Keep Capstone's stable
    # fp/lr/sp names in reports; W writes overlap but zero-extend that storage.
    if name.startswith("w") and name[1:].isdigit():
        name = "x" + name[1:]
    return {"x29": "fp", "x30": "lr", "wsp": "sp"}.get(name, name)


def stride(register, members, header, latches, edges, instructions, capstone):
    """Equal affine delta on ALL header-to-backedge paths, otherwise unknown.

    Remove backedges to header. Remaining cycles (nested loops), calls, unknown
    instructions and non-affine writes are intentionally not guessed.
    """
    unknown = {"bytes_per_iteration": None, "reason": "not_proven"}
    pred = {n: [] for n in members}
    for n in members:
        for nxt in edges[n]:
            if nxt in members and nxt != header:
                pred[nxt].append(n)
    indegree = {n: len(p) for n, p in pred.items()}
    todo = sorted(n for n in members if not indegree[n])
    done = 0
    after = {}
    while todo:
        n = todo.pop()
        done += 1
        incoming = [after[p] for p in pred[n]] if n != header else [0]
        value = incoming[0] if incoming and all(v == incoming[0] for v in incoming) else None
        ins = instructions[n]
        if ins.group(capstone.CS_GRP_CALL):
            value = None
        writes = [ins.reg_name(r) for r in ins.regs_access()[1]]
        if any(canonical(w) == register for w in writes):
            ops = ins.operands
            delta = None
            a = capstone.arm64
            if (
                ins.mnemonic in ("add", "sub", "adds", "subs")
                and len(ops) == 3
                and ops[0].type == a.ARM64_OP_REG
                and ops[1].type == a.ARM64_OP_REG
                and ops[2].type == a.ARM64_OP_IMM
                and ins.reg_name(ops[0].reg) == register
                and ins.reg_name(ops[1].reg) == register
            ):
                delta = ops[2].imm << ops[2].shift.value
                if ins.mnemonic.startswith("sub"):
                    delta = -delta
            # Loads/stores with writeback: reject destination/base alias and
            # register post-index forms; only a single base write is affine.
            mem = [o for o in ops if o.type == a.ARM64_OP_MEM]
            if ins.writeback and len(mem) == 1 and ins.reg_name(mem[0].mem.base) == register:
                aliases = [
                    o
                    for o in ops
                    if o.type == a.ARM64_OP_REG and canonical(ins.reg_name(o.reg)) == register
                ]
                if not aliases and not mem[0].mem.index:
                    delta = mem[0].mem.disp
                    if ops[-1].type == a.ARM64_OP_IMM:
                        delta = ops[-1].imm
            value = value + delta if value is not None and delta is not None else None
        after[n] = value
        for nxt in edges[n]:
            if nxt in members and nxt != header:
                indegree[nxt] -= 1
                if indegree[nxt] == 0:
                    todo.append(nxt)
    if done != len(members):
        return {"bytes_per_iteration": None, "reason": "nested_cycle"}
    deltas = [after[n] for n in latches]
    if not deltas or deltas[0] is None or any(v != deltas[0] for v in deltas):
        return unknown
    return {"bytes_per_iteration": deltas[0], "reason": "equal_affine_delta_all_backedge_paths"}


def analyze(raw, *, max_bytes=64 * 1024 * 1024, max_instructions=200000, max_region=2048):
    if not 1 <= max_instructions <= 2000000 or not 1 <= max_region <= 4096 or max_bytes < 1:
        raise ValueError("invalid analysis budget")
    cs, lz4 = _dependencies()
    text = _segments(raw, max_bytes, lz4)[0]
    if len(text.data) // 4 > max_instructions:
        raise ValueError("instruction budget exceeded; no partial report")
    md = cs.Cs(cs.CS_ARCH_ARM64, cs.CS_MODE_LITTLE_ENDIAN)
    md.detail = True
    instructions, edges, unresolved, memory = {}, {}, [], {}
    call_entries = set()
    for offset in range(0, len(text.data), 4):
        pc = text.address + offset
        word = struct.unpack_from("<I", text.data, offset)[0]
        ins = next(md.disasm(text.data[offset : offset + 4], pc, count=1), None)
        if ins is None or ins.mnemonic == "udf":
            unresolved.append({"address": pc, "kind": "undecodable_or_udf"})
            continue
        instructions[pc] = ins
        successors = []
        target = _branch_target(word, pc)
        if _exception_barrier(word):
            unresolved.append({"address": pc, "kind": "exception_transfer"})
        elif ins.group(cs.CS_GRP_CALL):
            successors.append(pc + 4)
            if target is not None:
                call_entries.add(target)
            unresolved.append({"address": pc, "kind": "call_not_inlined", "target": target})
        elif target is not None:
            successors.append(target)
            if word & 0xFC000000 != 0x14000000:
                successors.append(pc + 4)
        elif ins.group(cs.CS_GRP_RET) or ins.mnemonic.startswith("ret"):
            pass
        elif ins.group(cs.CS_GRP_JUMP) or word & 0xFE000000 == 0xD6000000:
            unresolved.append({"address": pc, "kind": "indirect_transfer"})
        else:
            successors.append(pc + 4)
        edges[pc] = successors
        accesses = []
        for op in ins.operands:
            if op.type == cs.arm64.ARM64_OP_MEM:
                accesses.append(
                    {
                        "base": ins.reg_name(op.mem.base) or None,
                        "index": ins.reg_name(op.mem.index) or None,
                        "displacement": op.mem.disp,
                    }
                )
        if word & 0x3B000000 == 0x18000000:  # LDR literal / PRFM literal
            displacement = (word >> 5) & 0x7FFFF
            if displacement & 0x40000:
                displacement -= 0x80000
            accesses.append(
                {
                    "base": None,
                    "index": None,
                    "displacement": displacement * 4,
                    "literal_address": pc + displacement * 4,
                }
            )
        if accesses:
            memory[pc] = {
                "address": pc,
                "instruction": ins.mnemonic + " " + ins.op_str,
                "operands": accesses,
                "writeback": bool(ins.writeback),
            }
    for pc in edges:
        for target in edges[pc]:
            if target not in instructions and target != text.address + len(text.data):
                unresolved.append(
                    {"address": pc, "kind": "target_outside_decoded_text", "target": target}
                )
        edges[pc] = sorted(set(n for n in edges[pc] if n in instructions))
    groups, predecessors = components(instructions, edges)
    loops, regions = [], []
    for group in groups:
        if len(group) == 1 and next(iter(group)) not in edges[next(iter(group))]:
            continue
        if len(group) > max_region:
            raise ValueError("cyclic region budget exceeded; no partial report")
        entries = sorted(n for n in group if any(p not in group for p in predecessors[n]))
        # The text start is an entry even if it has a backedge. Other source
        # components have no proven entry: do not manufacture a loop header.
        entries = sorted(set(entries) | (group & (call_entries | {text.address})))
        region = {
            "nodes": sorted(group),
            "entries": entries,
            "internal_edges": [[n, t] for n in sorted(group) for t in edges[n] if t in group],
            "memory": [memory[n] for n in sorted(group) if n in memory],
            "kind": "single_entry" if len(entries) == 1 else "multiple_or_unknown_entry",
        }
        regions.append(region)
        if not entries:
            continue
        # Dominators in this SCC with a virtual root pointing at every entry.
        dom = {n: ({n} if n in entries else set(group)) for n in group}
        changed = True
        while changed:
            changed = False
            for n in sorted(group - set(entries)):
                ps = [p for p in predecessors[n] if p in group]
                d = set.intersection(*(dom[p] for p in ps)) | {n}
                if d != dom[n]:
                    dom[n] = d
                    changed = True
        by_header = {}
        for tail in sorted(group):
            for header in edges[tail]:
                if header in dom[tail]:
                    by_header.setdefault(header, []).append(tail)
        for header, tails in sorted(by_header.items()):
            members = {header}
            stack = [n for n in tails if n != header]
            while stack:
                n = stack.pop()
                if n in members:
                    continue
                members.add(n)
                stack.extend(p for p in predecessors[n] if p in group and p not in members)
            mem = [memory[n] for n in sorted(members) if n in memory]
            bases = sorted(
                {canonical(op["base"]) for m in mem for op in m["operands"] if op["base"]}
            )
            loops.append(
                {
                    "header": header,
                    "back_edges": [[n, header] for n in tails],
                    "nodes": sorted(members),
                    "memory": mem,
                    "base_strides": {
                        r: stride(r, members, header, tails, edges, instructions, cs) for r in bases
                    },
                }
            )
    return {
        "schema": "s2arm.arm64-loops.v1",
        "input_sha256": hashlib.sha256(raw).hexdigest(),
        "text_address": text.address,
        "text_bytes": len(text.data),
        "loops": sorted(loops, key=lambda loop: loop["header"]),
        "cyclic_regions": sorted(regions, key=lambda r: r["nodes"][0]),
        "unresolved": sorted(unresolved, key=lambda u: u["address"]),
        "execution_proven": False,
        "scope": "decoded_direct_intraprocedural_cfg",
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("nso")
    parser.add_argument("--max-bytes", type=int, default=64 * 1024 * 1024)
    parser.add_argument("--max-instructions", type=int, default=200000)
    parser.add_argument("--max-region", type=int, default=2048)
    args = parser.parse_args(argv)
    try:
        if args.max_bytes < 1:
            raise ValueError("invalid input byte budget")
        fd = os.open(args.nso, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as f:
            info = os.fstat(f.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("NSO input must be a regular file")
            if info.st_size > args.max_bytes:
                raise ValueError("NSO input byte limit exceeded")
            raw = f.read(args.max_bytes + 1)
        result = analyze(
            raw,
            max_bytes=args.max_bytes,
            max_instructions=args.max_instructions,
            max_region=args.max_region,
        )
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    except (OSError, ValueError) as exc:
        print(f"【红】ARM64 loops: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
