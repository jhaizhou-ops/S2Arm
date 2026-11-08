#!/usr/bin/env python3
"""Offline Vulkan-only equivalents of the NVN Metal postprocessing passes.

Uses SPIRV-Tools for parsing validation and binary assembly, never compiles MSL.
Only original caller-provided SPIR-V is read. Errors leave the output unchanged.
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile


class PassError(ValueError):
    pass


@dataclasses.dataclass
class Instruction:
    op: str
    args: list[str]
    result: str | None = None

    def line(self) -> str:
        return (f"{self.result} = " if self.result else "") + " ".join([self.op, *self.args])


def instruction(line: str) -> Instruction:
    words = re.findall(r'"(?:\\.|[^"\\])*"|[^\s]+', line.strip())
    if len(words) > 2 and words[1] == "=":
        return Instruction(words[2], words[3:], words[0])
    return Instruction(words[0], words[1:])


@dataclasses.dataclass(frozen=True)
class Output:
    variable: str
    type_id: str
    indices: tuple[int, ...]
    location: int | None
    builtin: str | None
    decorations: tuple[str, ...] = ()


class Module:
    def __init__(self, text: str):
        self.code = [instruction(line) for line in text.splitlines()
                     if line.strip() and not line.lstrip().startswith(";")]
        self.counter = 0

    def text(self) -> str:
        return "\n".join(i.line() for i in self.code) + "\n"

    def new_id(self) -> str:
        used = {i.result for i in self.code}
        while True:
            self.counter += 1
            value = f"%s2a_vk_{self.counter}"
            if value not in used:
                return value

    def definitions(self) -> dict[str, Instruction]:
        return {i.result: i for i in self.code if i.result}

    def declaration(self, op: str, args: list[str], reuse: bool = True) -> str:
        if reuse:
            for i in self.code:
                if i.op == op and i.args == args:
                    return i.result
        result = self.new_id()
        at = next(n for n, i in enumerate(self.code) if i.op == "OpFunction")
        self.code.insert(at, Instruction(op, args, result))
        return result

    def annotation(self, op: str, args: list[str], result: str | None = None):
        at = next(n for n, i in enumerate(self.code)
                  if i.op.startswith("OpType") or i.op == "OpFunction")
        self.code.insert(at, Instruction(op, args, result))

    def marker(self, name: str) -> bool:
        literal = json.dumps("s2a.vk." + name)
        return any(i.op == "OpString" and i.args == [literal] for i in self.code)

    def mark(self, name: str):
        # OpString is available in SPIR-V 1.0; OpModuleProcessed is not.
        at = next(n for n, i in enumerate(self.code)
                  if i.op in ("OpName", "OpMemberName", "OpDecorate", "OpMemberDecorate")
                  or i.op.startswith("OpType"))
        self.code.insert(at, Instruction("OpString", [json.dumps("s2a.vk." + name)], self.new_id()))

    def entry(self, name: str, model: str = "Vertex") -> Instruction:
        entries = [i for i in self.code if i.op == "OpEntryPoint" and i.args[0] == model]
        if len(entries) != 1 or entries[0].args[2] != json.dumps(name):
            raise PassError(f"expected exactly one {model} entry named {name!r}")
        return entries[0]

    def scalar_vector(self, type_id: str) -> tuple[str, int, int]:
        defs = self.definitions()
        node = defs[type_id]
        count = 1
        if node.op == "OpTypeVector":
            count = int(node.args[1])
            node = defs[node.args[0]]
        if node.op == "OpTypeFloat":
            return "float", int(node.args[0]), count
        if node.op == "OpTypeInt":
            return "signed" if node.args[1] == "1" else "unsigned", int(node.args[0]), count
        raise PassError(f"unsupported interface type {type_id} ({node.op})")

    def interfaces(self, entry: Instruction, storage: str) -> list[Output]:
        defs = self.definitions()
        decorations: dict[str, dict[str, list[str]]] = {}
        members: dict[tuple[str, int], dict[str, list[str]]] = {}
        for i in self.code:
            if i.op in ("OpDecorationGroup", "OpGroupDecorate", "OpGroupMemberDecorate"):
                raise PassError("grouped interface decorations are unsupported")
            if i.op == "OpDecorate":
                decorations.setdefault(i.args[0], {})[i.args[1]] = i.args[2:]
            if i.op == "OpMemberDecorate":
                members.setdefault((i.args[0], int(i.args[1])), {})[i.args[2]] = i.args[3:]
        out: list[Output] = []
        for variable in entry.args[3:]:
            var = defs.get(variable)
            if not var or var.op != "OpVariable" or var.args[1] != storage:
                continue
            ptr = defs[var.args[0]]
            if ptr.op != "OpTypePointer" or ptr.args[0] != storage:
                raise PassError("invalid interface pointer")

            def walk(type_id: str, indices: tuple[int, ...], attrs: dict[str, list[str]]):
                node = defs[type_id]
                if storage == "Input" and "BuiltIn" in attrs and "Location" not in attrs:
                    # FS system inputs (including bool FrontFacing) do not
                    # participate in VS/FS user-Location pairing.
                    return
                if node.op == "OpTypeStruct":
                    if "Location" in attrs:
                        raise PassError("block-level Location requires explicit member Locations")
                    for index, child in enumerate(node.args):
                        child_attrs = {**attrs, **members.get((type_id, index), {})}
                        walk(child, (*indices, index), child_attrs)
                    return
                if node.op in ("OpTypeArray", "OpTypeRuntimeArray", "OpTypeMatrix"):
                    # gl_PerVertex includes ClipDistance/CullDistance scalar arrays;
                    # neither needs float4 initialization or Position remapping.
                    if attrs.get("BuiltIn", [None])[0] in ("ClipDistance", "CullDistance"):
                        return
                    raise PassError(f"unsupported aggregate interface {node.op}")
                if "Component" in attrs and attrs["Component"] != ["0"]:
                    raise PassError("nonzero interface Component is unsupported")
                if "Index" in attrs and attrs["Index"] != ["0"]:
                    raise PassError("dual-source interface Index is unsupported")
                kind, bits, count = self.scalar_vector(type_id)
                if bits != 32 or not 1 <= count <= 4:
                    raise PassError("interface must use 32-bit scalar/vector components")
                location = int(attrs["Location"][0]) if "Location" in attrs else None
                builtin = attrs.get("BuiltIn", [None])[0]
                interpolation = tuple(k for k in ("Flat", "NoPerspective", "Centroid", "Sample") if k in attrs)
                out.append(Output(variable, type_id, indices, location, builtin, interpolation))

            walk(ptr.args[1], (), decorations.get(variable, {}))
        return out

    def default(self, type_id: str) -> str:
        kind, width, count = self.scalar_vector(type_id)
        if kind != "float" or width != 32 or count != 4:
            raise PassError("missing paired locations must be float32 vec4")
        scalar = self.definitions()[type_id].args[0]
        zero = self.declaration("OpConstant", [scalar, "0"])
        one = self.declaration("OpConstant", [scalar, "1"])
        return self.declaration("OpConstantComposite", [type_id, zero, zero, zero, one])

    def pointer(self, output: Output) -> tuple[list[Instruction], str]:
        if not output.indices:
            return [], output.variable
        integer = self.declaration("OpTypeInt", ["32", "0"])
        indexes = [self.declaration("OpConstant", [integer, str(i)]) for i in output.indices]
        pointer_type = self.declaration("OpTypePointer", ["Output", output.type_id])
        value = self.new_id()
        return [Instruction("OpAccessChain", [pointer_type, output.variable, *indexes], value)], value

    def function_bounds(self, function: str) -> tuple[int, int]:
        start = next(n for n, i in enumerate(self.code) if i.op == "OpFunction" and i.result == function)
        end = next(n for n in range(start + 1, len(self.code)) if self.code[n].op == "OpFunctionEnd")
        return start, end

    def prologue(self, function: str, code: list[Instruction]):
        start, end = self.function_bounds(function)
        at = next(n for n in range(start + 1, end) if self.code[n].op == "OpLabel") + 1
        while at < end and self.code[at].op in ("OpVariable", "OpLine", "OpNoLine"):
            at += 1
        self.code[at:at] = code


def precise(module: Module, name: str, fragments: list[Module]):
    imports = {i.result for i in module.code if i.op == "OpExtInstImport" and i.args == ['"GLSL.std.450"']}
    replacements = {"FMin": "NMin", "FMax": "NMax", "FClamp": "NClamp"}
    for i in module.code:
        if i.op == "OpExtInst" and i.args[1] in imports and i.args[2] in replacements:
            i.args[2] = replacements[i.args[2]]


def vs_pad(module: Module, name: str, fragments: list[Module]):
    if not fragments:
        raise PassError("vs_pad requires at least one paired --fragment")
    entry = module.entry(name)
    existing = {o.location: o for o in module.interfaces(entry, "Output") if o.location is not None}
    wanted: dict[int, tuple[tuple[str, int, int], tuple[str, ...]]] = {}
    for fragment in fragments:
        fs_entry = fragment.entry("main", "Fragment")
        for item in fragment.interfaces(fs_entry, "Input"):
            if item.location is None:
                continue
            signature = fragment.scalar_vector(item.type_id)
            required = (signature, item.decorations)
            if item.location in wanted and wanted[item.location] != required:
                raise PassError(f"paired fragments disagree at Location {item.location}")
            wanted[item.location] = required
    additions: list[Instruction] = []
    for location, (signature, interpolation) in sorted(wanted.items()):
        if location in existing:
            if module.scalar_vector(existing[location].type_id) != signature:
                raise PassError(f"VS/FS type mismatch at Location {location}")
            continue
        if signature != ("float", 32, 4):
            raise PassError("missing paired fragment user inputs must be float32 vec4")
        scalar = module.declaration("OpTypeFloat", ["32"])
        vector = module.declaration("OpTypeVector", [scalar, "4"])
        pointer_type = module.declaration("OpTypePointer", ["Output", vector])
        variable = module.declaration("OpVariable", [pointer_type, "Output"], reuse=False)
        module.annotation("OpDecorate", [variable, "Location", str(location)])
        for decoration in interpolation:
            module.annotation("OpDecorate", [variable, decoration])
        entry.args.append(variable)
        additions.append(Instruction("OpStore", [variable, module.default(vector)]))
    module.prologue(entry.args[1], additions)


def vs_init(module: Module, name: str, fragments: list[Module]):
    if module.marker("vs_init.v1"):
        raise PassError("vs_init was already applied; start from the original module")
    entry = module.entry(name)
    initializers: list[Instruction] = []
    for output in module.interfaces(entry, "Output"):
        if module.scalar_vector(output.type_id) != ("float", 32, 4):
            continue
        access, pointer = module.pointer(output)
        value = module.default(output.type_id)
        initializers.extend(access)
        initializers.append(Instruction("OpStore", [pointer, value]))
    # vs_pad has already initialized its new outputs. Remove only exact stores
    # to those direct outputs from the leading prologue, not user body writes.
    start, end = module.function_bounds(entry.args[1])
    label = next(n for n in range(start + 1, end) if module.code[n].op == "OpLabel")
    expected = {tuple(i.args) for i in initializers if i.op == "OpStore"}
    at = label + 1
    while at < len(module.code) and module.code[at].op in ("OpVariable", "OpLine", "OpNoLine"):
        at += 1
    while at < len(module.code) and module.code[at].op == "OpStore" and tuple(module.code[at].args) in expected:
        del module.code[at]
    module.prologue(entry.args[1], initializers)
    module.mark("vs_init.v1")


def vs_depth(module: Module, name: str, fragments: list[Module]):
    if module.marker("vs_depth.v1"):
        raise PassError("vs_depth was already applied; start from the original module")
    entry = module.entry(name)
    variant = name + "_depth"
    if any(i.op == "OpEntryPoint" and i.args[2] == json.dumps(variant) for i in module.code):
        raise PassError(f"entry {variant!r} already exists")
    positions = [o for o in module.interfaces(entry, "Output") if o.builtin == "Position"]
    if len(positions) != 1 or module.scalar_vector(positions[0].type_id) != ("float", 32, 4):
        raise PassError("vs_depth requires one float32 vec4 BuiltIn Position")
    position = positions[0]
    original_id = entry.args[1]
    start, end = module.function_bounds(original_id)
    definition = module.code[start]
    defs = module.definitions()
    if defs[definition.args[0]].op != "OpTypeVoid" or defs[definition.args[2]].args != [definition.args[0]]:
        raise PassError("vertex entry must return void and take no arguments")
    implementation = module.new_id()
    definition.result = implementation
    depth_id = module.new_id()
    vector = position.type_id
    scalar = module.definitions()[vector].args[0]
    half = module.declaration("OpConstant", [scalar, "0.5"])
    access, pointer = module.pointer(position)
    # IDs allocated before insertion must remain unique across both wrappers.
    def new_result(op: str, args: list[str]) -> Instruction:
        return Instruction(op, args, module.new_id())
    normal_label = new_result("OpLabel", [])
    normal_call = new_result("OpFunctionCall", [definition.args[0], implementation])
    depth_label = new_result("OpLabel", [])
    depth_call = new_result("OpFunctionCall", [definition.args[0], implementation])
    loaded = new_result("OpLoad", [vector, pointer])
    z = new_result("OpCompositeExtract", [scalar, loaded.result, "2"])
    w = new_result("OpCompositeExtract", [scalar, loaded.result, "3"])
    zhalf = new_result("OpFMul", [scalar, z.result, half])
    whalf = new_result("OpFMul", [scalar, w.result, half])
    mapped = new_result("OpFAdd", [scalar, zhalf.result, whalf.result])
    changed = new_result("OpCompositeInsert", [vector, mapped.result, loaded.result, "2"])
    module.code.extend([
        Instruction("OpFunction", definition.args.copy(), original_id), normal_label, normal_call,
        Instruction("OpReturn", []), Instruction("OpFunctionEnd", []),
        Instruction("OpFunction", definition.args.copy(), depth_id), depth_label, depth_call,
        *access, loaded, z, w, zhalf, whalf, mapped, changed,
        Instruction("OpStore", [pointer, changed.result]), Instruction("OpReturn", []), Instruction("OpFunctionEnd", []),
    ])
    at = module.code.index(entry) + 1
    module.code.insert(at, Instruction("OpEntryPoint", ["Vertex", depth_id, json.dumps(variant), *entry.args[3:]]))
    for mode in list(module.code):
        if mode.op in ("OpExecutionMode", "OpExecutionModeId") and mode.args[0] == original_id:
            module.code.insert(module.code.index(mode) + 1, Instruction(mode.op, [depth_id, *mode.args[1:]]))
    module.mark("vs_depth.v1")


PASSES = {"vs_pad": vs_pad, "vs_init": vs_init, "precise": precise, "vs_depth": vs_depth}


def run_tool(command: list[str]):
    try:
        completed = subprocess.run(command, text=True, capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PassError(f"{command[0]}: {error}") from error
    if completed.returncode:
        raise PassError(f"{command[0]} exited {completed.returncode}: {completed.stderr.strip()}")


def transform(source: Path, output: Path, passes: list[str], fragment_paths: list[Path], entry: str, target: str):
    if not passes or len(set(passes)) != len(passes) or any(p not in PASSES for p in passes):
        raise PassError("provide a nonempty, nonrepeated list of known passes")
    order = [p for p in PASSES if p in passes]
    if passes != order:
        raise PassError("pass order must be vs_pad,vs_init,precise,vs_depth (omissions allowed)")
    for tool in ("spirv-val", "spirv-dis", "spirv-as"):
        if shutil.which(tool) is None:
            raise PassError(f"missing required tool: {tool}")
    data = source.read_bytes()
    if len(data) < 20 or len(data) % 4 or struct.unpack_from("<I", data)[0] != 0x07230203:
        raise PassError("input is not little-endian SPIR-V")
    version = struct.unpack_from("<I", data, 4)[0]
    if version >> 16 != 1 or ((version >> 8) & 255) > 6 or version & 255:
        raise PassError("unsupported SPIR-V version")
    with tempfile.TemporaryDirectory(prefix="s2a-vk-pass-") as temp:
        directory = Path(temp)
        def read_module(path: Path, index: int) -> Module:
            run_tool(["spirv-val", "--target-env", target, str(path)])
            assembly = directory / f"input-{index}.spvasm"
            run_tool(["spirv-dis", "--raw-id", str(path), "-o", str(assembly)])
            return Module(assembly.read_text())
        module = read_module(source, 0)
        fragments = [read_module(path, n + 1) for n, path in enumerate(fragment_paths)]
        for name in passes:
            PASSES[name](module, entry, fragments)
        assembly = directory / "output.spvasm"
        binary = directory / "output.spv"
        assembly.write_text(module.text())
        run_tool(["spirv-as", "--target-env", f"spv1.{(version >> 8) & 255}", str(assembly), "-o", str(binary)])
        run_tool(["spirv-val", "--target-env", target, str(binary)])
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=output.parent, prefix=f".{output.name}.", delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(binary.read_bytes())
            os.replace(temporary, output)
            temporary = None
        finally:
            if temporary is not None:
                temporary.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("-o", "--output", type=Path, required=True)
    parser.add_argument("--passes", required=True, help="ordered comma-separated pass names")
    parser.add_argument("--fragment", type=Path, action="append", default=[])
    parser.add_argument("--entry", default="main")
    parser.add_argument("--target-env", default="vulkan1.1", choices=["vulkan1.0", "vulkan1.1", "vulkan1.2", "vulkan1.3"])
    args = parser.parse_args()
    try:
        transform(args.input, args.output, args.passes.split(","), args.fragment, args.entry, args.target_env)
    except (PassError, OSError, KeyError, StopIteration) as error:
        print(f"[RED] SPIR-V transform: {error}", file=sys.stderr)
        return 1
    print(f"[OK] {args.passes}: {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
