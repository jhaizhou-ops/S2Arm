#!/usr/bin/env python3
"""Find one supported NVN slot loader using the repository's NSO/EH parsers.

This is a static census, not a call graph or runtime-use measurement. NSO and
EH-frame parsing use loader_census/nso_fnmap; no game profile or address is consulted.
"""

import argparse
import collections
import csv
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import tempfile

import capstone

from nvn_got_reads import slot_reads
import loader_census as decoder
import nso_fnmap as boundaries


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def discover(image, words, functions, decoder):
    """Name references are evidence for candidates, never a largest-table vote."""
    names = {m.start(): m.group()[:-1].decode("ascii")
             for m in re.finditer(rb"nvn[A-Z][A-Za-z0-9_]+\x00", image)}
    groups = collections.defaultdict(list)
    uncovered = []
    engine = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_LITTLE_ENDIAN)
    engine.detail = True
    for i, word in enumerate(words):
        # ADR is the linker's relaxed form when the name is within +/-1 MiB.
        # Capstone supplies the decoded target; no NSO bytes are rewritten.
        if word & 0x9f00001f == 0x10000001:
            instruction = next(engine.disasm(image[i * 4:i * 4 + 4], i * 4))
            address = instruction.operands[1].imm
            if address in names:
                row = dict(offset=hex(i * 4), name=names[address], addressKind="adr",
                           nameAddress=hex(address), addressInstructionOffset=hex(i * 4))
                start = functions.func(i * 4)
                if start is None:
                    uncovered.append(row)
                else:
                    groups[start].append(row)
            continue
        page = decoder.adrp(word, i * 4)
        if page is None:
            continue
        for j in range(i + 1, min(i + 9, len(words))):
            add = decoder.addimm(words[j])
            if add and add[1] == page[0] and add[0] == 1 and page[1] + add[2] in names:
                row = dict(offset=hex(j * 4), name=names[page[1] + add[2]],
                           addressKind="adrp_add", nameAddress=hex(page[1] + add[2]),
                           addressInstructionOffset=hex(i * 4))
                start = functions.func(j * 4)
                if start is None:
                    uncovered.append(row)
                else:
                    groups[start].append(row)
                break
            if decoder.is_call(words[j]) or words[j] == 0xd65f03c0:
                break
            if words[j] & 31 == page[0]:
                break
    return groups, uncovered


def inspect_candidate(start, references, functions, words):
    end = start + functions.size[start]
    reasons = []
    if start & 3 or end & 3 or end > len(words) * 4:
        reasons.append("Function boundary is outside aligned text")
        return dict(start=hex(start), functionEndExclusive=hex(end), references=references,
                    supported=False, rejectionReasons=reasons)
    body = words[start // 4:end // 4]
    returns = [start + i * 4 for i, word in enumerate(body) if word == 0xd65f03c0]
    indirect = [word for word in body if word & 0xfffffc1f == 0xd63f0000]
    # The register proof follows one linear loader. Reject branching functions
    # rather than reading a different path or into another function.
    branches = [word for word in body if
                word & 0x7c000000 == 0x14000000 or
                word & 0xff000010 == 0x54000000 or
                word & 0x7e000000 in (0x34000000, 0x36000000) or
                word & 0xfffffc1f == 0xd61f0000]
    if returns != [end - 4]:
        reasons.append("Requires exactly one final RET within the EH-frame function")
    if branches:
        reasons.append("Conditional/direct/tail branches are outside the supported linear loader shape")
    if len(indirect) != len(references) or not indirect:
        reasons.append("NVN x1 name-reference count does not match indirect fetch-call count")
    if len({(word >> 5) & 31 for word in indirect}) != 1:
        reasons.append("Fetch calls do not use one function-pointer register")
    if len({row["name"] for row in references}) != len(references):
        reasons.append("Repeated names make the fetch-table interpretation ambiguous")
    return dict(start=hex(start), functionEndExclusive=hex(end),
                returnInstructionOffset=hex(end - 4), references=references,
                nameReferenceCount=len(references), indirectFetchCallCount=len(indirect),
                supported=not reasons, rejectionReasons=reasons)


def verify_register_liveness(image, chosen, decoder, relocations):
    """Recover name/slot pairs through live GOT or direct address chains."""
    engine = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_LITTLE_ENDIAN)
    engine.detail = True
    start = int(chosen["start"], 16)
    end = int(chosen["functionEndExclusive"], 16)
    references = {int(row["offset"], 16): row for row in chosen["references"]}
    pages, pointers = {}, {}
    slots = []
    pending_name = fetched = fetch_register = None
    calls = stores = instructions = 0
    last_call = max(pc for pc in range(start, end, 4)
                    if decoder.is_call(struct.unpack_from("<I", image, pc)[0]))
    control_groups = {capstone.CS_GRP_JUMP, capstone.CS_GRP_CALL,
                      capstone.CS_GRP_RET, capstone.CS_GRP_INT,
                      capstone.CS_GRP_IRET, capstone.CS_GRP_PRIVILEGE,
                      capstone.CS_GRP_BRANCH_RELATIVE}

    def register(instruction, identifier):
        name = instruction.reg_name(identifier)
        if name in ("fp", "lr"):
            return {"fp": 29, "lr": 30}[name]
        if name[:1] in ("x", "w") and name[1:].isdigit():
            return int(name[1:])
        return None

    for instruction in engine.disasm(image[start:end], start):
        pc = instruction.address
        if pc != start + instructions * 4 or instruction.size != 4:
            raise ValueError("Capstone did not decode the complete aligned loader")
        instructions += 1
        word = struct.unpack_from("<I", image, pc)[0]
        adrp = decoder.adrp(word, pc)
        add = decoder.addimm(word)
        load = decoder.ldr64(word)
        store = decoder.str_x0(word)
        call = instruction.id == capstone.arm64.ARM64_INS_BLR
        final_return = word == 0xd65f03c0 and pc == end - 4
        if (control_groups.intersection(instruction.groups) and not (call or final_return)) or instruction.id == capstone.arm64.ARM64_INS_UDF:
            raise ValueError(f"Unsupported loader control flow {instruction.mnemonic} at {pc:#x}")
        _, written = instruction.regs_access()
        writes = {register(instruction, identifier) for identifier in written}
        writes.discard(None)
        source_page = pages.get(add[1]) if add and add[1] != 31 else None
        load_page = pages.get(load[1]) if load and load[1] != 31 else None
        store_pointer = pointers.get(store[0]) if store and store[0] != 31 else None
        store_address = pages.get(store[0]) if store and store[0] != 31 else None

        if pending_name is not None and 1 in writes:
            raise ValueError(f"NVN name in x1 is overwritten before its fetch at {pc:#x}")
        if fetched is not None and 0 in writes:
            raise ValueError(f"Fetched NVN pointer in x0 is overwritten before its store at {pc:#x}")
        if fetch_register is not None and pc <= last_call and fetch_register in writes:
            raise ValueError(f"Fetch-call register is overwritten between calls at {pc:#x}")
        for destination in writes:
            pages.pop(destination, None)
            pointers.pop(destination, None)

        # Register 31 is XZR for ADRP/LDR destinations, but SP for these bases.
        # Discarded results must never become an address attributed to SP.
        if adrp is not None and adrp[0] != 31:
            pages[adrp[0]] = (adrp[1], pc)
        if add is not None and add[0] != 31 and source_page is not None:
            pages[add[0]] = (source_page[0] + add[2], source_page[1])
        if pc in references:
            reference = references[pc]
            if reference["addressKind"] == "adr":
                if (instruction.id != capstone.arm64.ARM64_INS_ADR or
                        instruction.operands[0].reg != capstone.arm64.ARM64_REG_X1 or
                        instruction.operands[1].imm != int(reference["nameAddress"], 16)):
                    raise ValueError(f"NVN name ADR target disagrees with discovery at {pc:#x}")
            elif (add is None or add[0] != 1 or source_page is None or
                  source_page[1] != int(reference["addressInstructionOffset"], 16) or
                  source_page[0] + add[2] != int(reference["nameAddress"], 16)):
                raise ValueError(f"NVN name ADRP/ADD address chain is not live at {pc:#x}")
            pending_name = reference["name"]
        if load is not None and load[0] != 31 and load_page is not None:
            pointers[load[0]] = load_page[0] + load[2]
        if call:
            target = register(instruction, instruction.operands[0].reg)
            if pending_name is None or fetched is not None or target is None:
                raise ValueError(f"Fetch call has no live NVN name, an unstored previous result, or an invalid target at {pc:#x}")
            if target <= 18 or target == 30:
                raise ValueError(f"Fetch-call register is caller-clobbered at {pc:#x}")
            if fetch_register is not None and target != fetch_register:
                raise ValueError(f"Fetch-call register changes at {pc:#x}")
            fetch_register = target
            fetched, pending_name = pending_name, None
            calls += 1
            for destination in (*range(19), 30):
                pages.pop(destination, None)
                pointers.pop(destination, None)
        if store is not None and fetched is not None:
            if store_pointer is not None:
                if store_pointer not in relocations:
                    raise ValueError(f"GOT entry {store_pointer:#x} has no resolved relocation")
                slot = relocations[store_pointer] + store[1]
            elif store_address is not None:
                slot = store_address[0] + store[1]
            else:
                raise ValueError(f"Fetched NVN pointer lacks a live GOT or direct ADRP/ADD slot address at {pc:#x}")
            if slot < 0 or slot & 7:
                raise ValueError(f"Fetched NVN pointer resolves to an invalid global slot at {pc:#x}")
            slots.append(dict(name=fetched, got=store_pointer, slot=slot))
            fetched = None
            stores += 1
    if start + instructions * 4 != end:
        raise ValueError("Capstone did not decode the complete loader")
    if pending_name is not None or fetched is not None or calls != len(references) or stores != calls:
        raise ValueError("Loader does not consume and store each NVN fetch exactly once")
    got_entries = [row['got'] for row in slots if row['got'] is not None]
    if len(set(got_entries)) != len(got_entries) or len({row['slot'] for row in slots}) != calls:
        raise ValueError("Loader stores multiple fetched names through one GOT entry or global slot")
    return (dict(capstoneVersion=capstone.__version__, instructions=instructions,
                 fetchCalls=calls, resultStores=stores, fetchRegister=f"x{fetch_register}",
                 gotStores=len(got_entries), directStores=stores - len(got_entries)), slots)


def analyze_nso(path, report):
    if sys.flags.optimize:
        raise ValueError("Python optimization (-O / PYTHONOPTIMIZE) disables required EH-frame checks")
    nso = Path(path).resolve(strict=True)
    if nso.read_bytes()[:4] != b"NSO0":
        raise ValueError("Input must be an NSO, not a raw image")
    report["input"] = dict(sha256=digest(nso), bytes=nso.stat().st_size)
    report["sourceSha256"] = {name: digest(Path(__file__).with_name(name)) for name in
                             ('nvn_got_census.py', 'nvn_got_reads.py', 'loader_census.py', 'nso_fnmap.py')}
    image, text_size = decoder.image(str(nso))
    if text_size <= 0 or text_size & 3 or text_size > len(image):
        raise ValueError("Invalid text size returned by loader_census")
    report["textBytes"] = text_size
    words = struct.unpack_from(f"<{text_size // 4}I", image)
    with tempfile.TemporaryDirectory(prefix="nvn-got-census-") as temporary:
        work = Path(temporary)
        raw = work / "module.bin"
        raw.write_bytes(image)
        functions = boundaries.Img(str(raw))
        groups, uncovered = discover(image, words, functions, decoder)
        candidates = [inspect_candidate(start, refs, functions, words)
                      for start, refs in sorted(groups.items())]
        report["candidates"] = candidates
        report["uncoveredNameReferences"] = uncovered
        if uncovered:
            raise ValueError("NVN x1 name references lack supported EH-frame boundaries; coverage is unknown")
        supported = [row for row in candidates if row["supported"]]
        if len(supported) != 1:
            detail = '; '.join(f"{row['start']}: {', '.join(row['rejectionReasons']) or 'supported'}"
                               for row in candidates) or 'no NVN x1 name-reference candidates'
            raise ValueError(f"Expected one structurally supported loader, found {len(supported)}; {detail}")
        chosen = supported[0]
        relocations = decoder.got_values(image)
        chosen["registerLiveness"], slots = verify_register_liveness(image, chosen, decoder, relocations)
        start, end = int(chosen["start"], 16), int(chosen["functionEndExclusive"], 16)
        reads = slot_reads(words, start, end, slots, decoder)
        count, used, sites = len(slots), sum(bool(value) for value in reads.values()), sum(map(len, reads.values()))
        report.update(status="complete", loaderStart=hex(start),
                      loaderReturnInstructionOffset=hex(end - 4), loaderEndExclusive=hex(end),
                      fetchedNames=count, namesWithSlotReads=used, staticSlotReadSites=sites,
                      resolvedGotRelocations=len(relocations),
                      slotReadImplementationSha256=digest(Path(__file__).with_name('nvn_got_reads.py')))
        return slots, reads


def census(args, report):
    slots, reads = analyze_nso(args.nso, report)
    write_json(args.output / "candidates.json", report)
    with (args.output / "slots.tsv").open('w', encoding='utf-8', newline='') as stream:
        stream.write('# kind: evidence  NVN fetch slots and static use sites (nvn_got_census.py; upstream read heuristic)\n')
        writer = csv.writer(stream, delimiter='\t', lineterminator='\n')
        writer.writerow(('name', 'slot', 'nuses', 'first_use'))
        for row in slots:
            uses = reads[row['slot']]
            writer.writerow((row['name'], f"{row['slot']:x}", len(uses), f'{uses[0]:x}' if uses else '-'))
    report["slotsTsvSha256"] = digest(args.output / "slots.tsv")
    write_json(args.output / "census.json", report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("nso", type=Path)
    parser.add_argument("--output", type=Path, required=True, help="New private output directory")
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    report = dict(schemaVersion=3, status="in_progress", command=sys.argv,
                  pythonVersion=sys.version, pythonOptimize=sys.flags.optimize,
                  limitations="Only one linear NVN x1/(ADR or ADRP+ADD) loader with EH-frame boundaries and GOT or direct ADRP/ADD slot addresses is supported. Static slot reads are heuristic references, not runtime calls, an exhaustive call graph, or whole-game graphics coverage.")
    try:
        census(args, report)
    except Exception as error:
        report.update(status="failed", error=f"{type(error).__name__}: {error}")
        if 'candidates' in report:
            write_json(args.output / "candidates.json", report)
        write_json(args.output / "failure.json", report)
        print(f"NVN slot census failed: {error}; evidence: {args.output}", file=sys.stderr)
        return 1
    print(json.dumps({key: report[key] for key in ("loaderStart", "loaderEndExclusive", "fetchedNames", "namesWithSlotReads", "staticSlotReadSites")}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
