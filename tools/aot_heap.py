"""Read-only LLDB heap census for the tested .NET 10.0.12 NativeAOT WKS layout.

Importing this module only registers the command. Before running the target:
  command script import /absolute/path/tools/aot_heap.py
  aot-heap --output /absolute/path/snapshots --runtime-version 10.0.12
  run

The runtime version is the operator's attestation, not automatic detection.
Only a completed blocking gen2 GC is sampled. This tool never calls target
functions or requests GC. Heap reads are discarded after extracting metadata;
the output contains counts and sizes, never object payloads or reference graphs.
shallowBytes includes object headers and alignment, not referenced objects.
gcReferenceSlots counts GC-described slots, including nulls, not non-null references
or measured mark/card-table scan work. Frozen slots are reported separately.
Sources: dotnet/runtime v10.0.12, nativeaot/Runtime/inc/MethodTable.h,
nativeaot/Runtime/ObjectLayout.h, gc/gc.cpp, gc/gcpriv.h, gc/gcdesc.h,
tools/Common/Internal/Runtime/GCDescEncoder.cs, gc/env/gcenv.base.h.
Attach is performed by LLDB, not this command; an attach error cannot produce a
census or callback failure JSON. Check LLDB's attach result before continuing.
"""

import argparse
import json
import os
from pathlib import Path
import shlex
import struct
import tempfile
import time

import lldb


_sessions = {}


class CommandParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


def _integer(value):
    if not value.IsValid() or value.GetError().Fail():
        raise RuntimeError(f"Cannot read {value.GetName()}: {value.GetError()}")
    return value.GetValueAsUnsigned()


def _field(value, name):
    result = value.GetChildMemberWithName(name)
    if not result.IsValid():
        raise RuntimeError(f"Missing DWARF field {value.GetName()}.{name}")
    return result


def _global(target, name):
    value = target.FindFirstGlobalVariable(name)
    if not value.IsValid():
        raise RuntimeError(f"Missing DWARF global {name}; only NativeAOT WKS is supported")
    return value


def _layout(target, address):
    if target.GetAddressByteSize() != 8 or target.GetByteOrder() != lldb.eByteOrderLittle:
        raise RuntimeError("Only little-endian 64-bit NativeAOT WKS is supported")
    mt_type = target.FindFirstType("MethodTable")
    if not mt_type.IsValid():
        raise RuntimeError("Missing MethodTable DWARF")
    # NativeAOT's first two words are a flags/component-size union and base size.
    probe = target.CreateValueFromAddress("mt_layout", target.ResolveLoadAddress(address), mt_type)
    for name, offset in (("m_uFlags", 0), ("m_uBaseSize", 4)):
        member = _field(probe, name)
        if member.GetType().GetByteSize() != 4 or member.GetLoadAddress() != address + offset:
            raise RuntimeError(f"Unsupported MethodTable layout: {name}")
    return mt_type


def _snapshot(frame, session):
    started_unix = time.time()
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    settings = _global(target, "WKS::gc_heap::settings")
    if _integer(_field(settings, "condemned_generation")) != 2:
        return None
    if _integer(_field(settings, "concurrent")):
        return None
    if _integer(_global(target, "WKS::gc_heap::gc_background_running")):
        return None
    free_type = _integer(_global(target, "g_pFreeObjectEEType"))
    if not free_type or free_type & 7:
        raise RuntimeError("Invalid GC free-object MethodTable")
    mt_type = _layout(target, free_type)
    generations = _global(target, "WKS::gc_heap::generation_table")
    if generations.GetNumChildren() != 5:
        raise RuntimeError("Expected five NativeAOT WKS generations (SOH/LOH/POH)")
    metadata = {}
    types = {}
    segments = []
    seen = set()
    free_bytes = 0
    object_count = 0
    started = time.monotonic()

    def read(address, size):
        error = lldb.SBError()
        data = process.ReadMemory(address, size, error)
        if error.Fail() or len(data) != size:
            raise RuntimeError(f"Cannot read {size} bytes at {address:#x}: {error}")
        return data

    def method_table(address):
        if address not in metadata:
            value = target.CreateValueFromAddress("mt", target.ResolveLoadAddress(address), mt_type)
            flags = _integer(_field(value, "m_uFlags"))
            base = _integer(_field(value, "m_uBaseSize"))
            component = flags & 0xffff if flags & 0x80000000 else 0
            series = []
            repeating_slots = None
            if address != free_type and flags & 0x01000000:
                # GCDesc grows backwards from MT. Mirror gcdesc.h GetNumPointers;
                # never inspect the reference values stored in these slots.
                series_count, = struct.unpack("<q", read(address - 8, 8))
                if not 0 < abs(series_count) <= 65536:
                    raise RuntimeError(f"Invalid GCDesc series count at {address:#x}: {series_count}")
                if series_count > 0:
                    for index in range(series_count):
                        series.append(struct.unpack("<qQ", read(address - 24 - index * 16, 16)))
                else:
                    if not component:
                        raise RuntimeError(f"Repeating GCDesc without component size at {address:#x}")
                    repeating_slots = 0
                    stride = 0
                    for index in range(-series_count):
                        pointers, skip = struct.unpack("<II", read(address - 24 - index * 8, 8))
                        if not pointers or skip & 7:
                            raise RuntimeError(f"Invalid repeating GCDesc at {address:#x}")
                        repeating_slots += pointers
                        stride += pointers * 8 + skip
                    if stride != component:
                        raise RuntimeError(f"GCDesc stride differs from component size at {address:#x}")
            symbol = target.ResolveLoadAddress(address).GetSymbol()
            symbol_address = symbol.GetStartAddress().GetLoadAddress(target) if symbol.IsValid() else None
            name = symbol.GetName() if symbol.IsValid() else None
            offset = address - symbol_address if symbol_address is not None else None
            metadata[address] = (base, component, name, offset, series, repeating_slots)
        return metadata[address]

    def reference_slots(series, repeating_slots, raw_size, count):
        if repeating_slots is not None:
            return repeating_slots * count
        slots = 0
        for adjustment, offset in series:
            length = adjustment + raw_size
            if length < 0 or length & 7 or offset < 8 or offset & 7 or offset + length > raw_size - 8:
                raise RuntimeError("GCDesc reference series exceeds object bounds or is unaligned")
            slots += length // 8
        if slots > raw_size // 8:
            raise RuntimeError("GCDesc slot count exceeds object size")
        return slots

    for gen in range(5):
        pointer = _field(generations.GetChildAtIndex(gen), "start_segment")
        chain = set()
        while _integer(pointer):
            address = _integer(pointer)
            if address in chain:
                raise RuntimeError("Cycle in segment chain")
            chain.add(address)
            segment = pointer.Dereference()
            pointer = _field(segment, "next")
            if address in seen:
                continue
            seen.add(address)
            start = _integer(_field(segment, "mem"))
            end = _integer(_field(segment, "allocated"))
            flags = _integer(_field(segment, "flags"))
            if not start or start & 7 or end < start or end & 7:
                raise RuntimeError(f"Invalid segment: {start:#x}..{end:#x}")
            frozen = bool(flags & 1)
            segments.append(dict(firstGenerationChain=gen, start=hex(start), end=hex(end), flags=flags, frozen=frozen))
            current = start
            window_start = window_end = 0
            window = b""
            while current < end:
                object_count += 1
                if object_count > session["maxObjects"]:
                    raise RuntimeError(f"Object limit exceeded ({session['maxObjects']}); no complete census")
                if end - current < 24:
                    raise RuntimeError(f"Truncated object at {current:#x}")
                if current < window_start or current + 12 > window_end:
                    window_start = current
                    window = read(current, min(65536, end - current))
                    window_end = window_start + len(window)
                mt, count = struct.unpack_from("<QI", window, current - window_start)
                if mt & 7 or not mt:
                    raise RuntimeError(f"Invalid MethodTable at {current:#x}: {mt:#x}")
                base, component, symbol, offset, series, repeating_slots = method_table(mt)
                raw_size = base + component * count
                size = (raw_size + 7) & ~7
                if size < 24 or current + size > end:
                    raise RuntimeError(f"Invalid object size at {current:#x}: {size}")
                if mt == free_type:
                    free_bytes += size
                else:
                    key = (mt, frozen)
                    if key not in types:
                        types[key] = dict(methodTable=hex(mt), symbol=symbol, symbolOffset=offset,
                                          typeName=symbol if offset == 0 else None,
                                          typeNameConfirmed=bool(symbol) and offset == 0,
                                          count=0, shallowBytes=0, gcReferenceSlots=0, sizes={})
                    row = types[key]
                    row["count"] += 1
                    row["shallowBytes"] += size
                    row["gcReferenceSlots"] += reference_slots(series, repeating_slots, raw_size, count)
                    row["sizes"][size] = row["sizes"].get(size, 0) + 1
                current += size
    for row in types.values():
        row["sizeHistogram"] = [dict(shallowBytes=size, count=count) for size, count in sorted(row.pop("sizes").items())]
    return dict(schema=2, status="complete", runtimeVersionAttestation="10.0.12", layout="NativeAOT-WKS-64LE",
                gcIndex=_integer(_field(_field(settings, "gc_index"), "m_val")), generation=2, concurrent=False,
                backgroundRunning=False, processId=process.GetProcessID(), moduleUuid=target.GetModuleAtIndex(0).GetUUIDString(),
                startedUnixSeconds=started_unix, finishedUnixSeconds=time.time(),
                snapshotSeconds=time.monotonic()-started, freeBytes=free_bytes, segments=segments,
                types=sorted((row for (mt, frozen), row in types.items() if not frozen), key=lambda row: row["shallowBytes"], reverse=True),
                frozenTypes=sorted((row for (mt, frozen), row in types.items() if frozen), key=lambda row: row["shallowBytes"], reverse=True))


def _write(path, result):
    # Publish only a fully serialized result; an I/O error cannot leave heap-N.json partial.
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     prefix=path.name + ".", suffix=".tmp", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(result, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            os.link(temporary, path)
        finally:
            temporary.unlink()


def on_gc(frame, bp_loc, internal_dict):
    session = _sessions.get(bp_loc.GetBreakpoint().GetID())
    if session is None:
        print("aot-heap FAILED: missing callback configuration; target remains stopped", flush=True)
        return True
    try:
        result = _snapshot(frame, session)
        if result is None:
            return False
        path = session["output"] / f"heap-{session['sequence'] + 1:03d}.json"
        _write(path, result)
        session["sequence"] += 1
        print(f"aot-heap complete: {path}", flush=True)
        return bool(session["stopAfter"] and session["sequence"] >= session["stopAfter"])
    except Exception as error:
        # Fail closed. No partial histogram is published; all target threads stay stopped.
        failure = dict(schema=1, status="failed", error=f"{type(error).__name__}: {error}",
                       processId=frame.GetThread().GetProcess().GetProcessID(), targetRemainsStopped=True)
        path = session["output"] / f"failure-{time.time_ns()}.json"
        try:
            _write(path, failure)
            print(f"aot-heap FAILED: {failure['error']}; {path}; target remains stopped", flush=True)
        except OSError as write_error:
            print(f"aot-heap FAILED: {failure['error']}; failure result could not be written: {write_error}; target remains stopped", flush=True)
        return True


def configure(debugger, command, result, internal_dict):
    parser = CommandParser(prog="aot-heap", add_help=False,
                           description="Read-only census at blocking gen2 GC end; tested only .NET 10.0.12 NativeAOT WKS 64LE")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--runtime-version", required=True, choices=["10.0.12"])
    parser.add_argument("--max-objects", type=int, default=10000000)
    parser.add_argument("--stop-after", type=int, default=0,
                        help="Leave the target stopped after N complete snapshots (0: continue sampling)")
    try:
        args = parser.parse_args(shlex.split(command))
        if args.max_objects < 1:
            raise ValueError("--max-objects must be positive")
        if args.stop_after < 0:
            raise ValueError("--stop-after must be nonnegative")
        target = debugger.GetSelectedTarget()
        if not target.IsValid():
            raise ValueError("Select the NativeAOT target before configuring the census")
        if _sessions:
            raise ValueError("A census is already configured in this LLDB session")
        if target.GetAddressByteSize() != 8 or target.GetByteOrder() != lldb.eByteOrderLittle:
            raise ValueError("Only little-endian 64-bit targets are supported")
        output = args.output.expanduser().resolve()
        output.mkdir(parents=True, exist_ok=True)
        if any(output.iterdir()):
            raise ValueError("Output directory must be empty; use a new directory for each run")
        bp = target.BreakpointCreateByName("GCToEEInterface::DiagGCEnd")
        if bp.GetNumLocations() != 1:
            count = bp.GetNumLocations()
            target.BreakpointDelete(bp.GetID())
            raise ValueError(f"Expected exactly one DiagGCEnd symbol, got {count}")
        _sessions[bp.GetID()] = dict(output=output, sequence=0, maxObjects=args.max_objects, stopAfter=args.stop_after)
        bp.SetScriptCallbackFunction(__name__ + ".on_gc")
        result.AppendMessage(f"NativeAOT WKS census enabled: {output}; runtime 10.0.12 attested by operator")
    except (ValueError, OSError) as error:
        result.SetError(str(error))


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(f"command script add -f {__name__}.configure aot-heap")
