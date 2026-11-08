#!/usr/bin/env python3
"""Original GLSL -> real glslang/SPIRV-Tools regression; no game assets."""
import ast
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
TOOL = Path(os.environ.get("SPIRV_PASS_TEST_TOOL", HERE / "spirv_passes.py"))
spec = importlib.util.spec_from_file_location("checked_spirv_passes", TOOL)
passes = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = passes
spec.loader.exec_module(passes)


def run(args):
    process = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=60)
    if process.returncode:
        raise AssertionError(f"command failed ({process.returncode}): {args}\n{process.stdout}\n{process.stderr}")
    return process.stdout


def disassemble(path):
    return run(["spirv-dis", "--raw-id", path])


def parse(text):
    # Independent oracle parser: do not call the implementation's Module parser.
    definitions, statements = {}, []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(";"):
            continue
        match = re.fullmatch(r"(%\w+) = (Op\w+)(?: (.*))?", line)
        if match:
            identifier, operation, operands = match.groups()
            operands = (operands or "").split()
            definitions[identifier] = (operation, operands)
        else:
            operation, *operands = line.split()
            identifier = None
        statements.append((identifier, operation, operands or []))
    return definitions, statements


def locations(text, storage):
    defs, statements = parse(text)
    return {int(args[2]): args[0] for _, op, args in statements
            if op == "OpDecorate" and len(args) == 3 and args[1] == "Location"
            and defs.get(args[0], (None, []))[0] == "OpVariable"
            and defs[args[0]][1][1] == storage}


def default_values(text):
    defs, _ = parse(text)
    result = []
    for identifier, (op, args) in defs.items():
        if op != "OpConstantComposite" or len(args) != 5:
            continue
        components = [defs[x] for x in args[1:]]
        if all(operation == "OpConstant" for operation, _ in components):
            if [float(operands[1]) for _, operands in components] == [0, 0, 0, 1]:
                result.append(identifier)
    return result


class PassTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for tool in ("glslangValidator", "spirv-as", "spirv-dis", "spirv-val"):
            if shutil.which(tool) is None:
                raise RuntimeError(f"missing required tool: {tool}; NOT a skipped pass")
        cls.temp = tempfile.TemporaryDirectory(prefix="s2a-vk-tests-")
        cls.directory = Path(cls.temp.name)
        cls.inputs = {}
        for name in ("pair.vert", "pair.frag", "precise.frag"):
            output = cls.directory / (name + ".spv")
            run(["glslangValidator", "-V", "--target-env", "vulkan1.1", HERE / "fixtures" / name, "-o", output])
            run(["spirv-val", "--target-env", "vulkan1.1", output])
            cls.inputs[name] = output

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def apply(self, selected, source="pair.vert", fragments=(), target="vulkan1.1"):
        output = self.directory / (self._testMethodName + ".spv")
        passes.transform(self.inputs[source], output, selected,
                         [self.inputs[n] for n in fragments], "main", target)
        run(["spirv-val", "--target-env", target, output])
        return output, disassemble(output)

    def test_precise(self):
        before = disassemble(self.inputs["precise.frag"])
        _, after = self.apply(["precise"], "precise.frag")
        for old, new in (("FMin", "NMin"), ("FMax", "NMax"), ("FClamp", "NClamp")):
            old_count = len(re.findall(r"\b" + old + r"\b", before))
            self.assertGreater(old_count, 0)
            self.assertEqual(len(re.findall(r"\b" + new + r"\b", after)), old_count)
            self.assertNotRegex(after, r"\b" + old + r"\b")

    def test_vs_pad(self):
        _, after = self.apply(["vs_pad"], fragments=("pair.frag",))
        required = locations(disassemble(self.inputs["pair.frag"]), "Input")
        actual = locations(after, "Output")
        self.assertTrue(set(required).issubset(actual))
        self.assertEqual(set(actual), {0, 1, 3})
        self.assertTrue(any(f"OpStore {actual[3]} {default}" in after for default in default_values(after)))

    def test_vs_init(self):
        _, after = self.apply(["vs_init"])
        user_output = locations(after, "Output")[0]
        defaults = default_values(after)
        self.assertEqual(len(defaults), 1)
        self.assertEqual(after.count(f"OpStore {user_output} {defaults[0]}"), 1)
        # Original GLSL writes only xyz; the float4 initializer must precede it.
        self.assertLess(after.index(f"OpStore {user_output} {defaults[0]}"), after.index("OpVectorShuffle"))
        defs, instructions = parse(after)
        initialized = [args[0] for _, op, args in instructions if op == "OpStore" and args[1] == defaults[0]]
        self.assertEqual(len(initialized), 2)  # user float4 and gl_PerVertex.Position
        self.assertTrue(any(defs[p][0] == "OpAccessChain" for p in initialized))

    def test_vs_depth(self):
        _, after = self.apply(["vs_depth"])
        self.assertRegex(after, r'OpEntryPoint Vertex %\w+ "main"')
        self.assertRegex(after, r'OpEntryPoint Vertex %\w+ "main_depth"')
        defs, statements = parse(after)
        entry = re.search(r'OpEntryPoint Vertex (%\w+) "main_depth"', after)[1]
        start = next(n for n, (result, op, _) in enumerate(statements) if result == entry and op == "OpFunction")
        end = next(n for n in range(start + 1, len(statements)) if statements[n][1] == "OpFunctionEnd")
        body = statements[start + 1:end]
        for vector, expected_z in [([2, 3, -8, 2], -3), ([2, 3, 0, 2], 1), ([2, 3, 6, 2], 4), ([1, 9, 3, -1], 1)]:
            values = {i: float(args[1]) for i, (op, args) in defs.items() if op == "OpConstant" and len(args) == 2}
            stores = []
            for result, op, args in body:
                if op == "OpLoad": values[result] = vector[:]
                elif op == "OpCompositeExtract": values[result] = values[args[1]][int(args[2])]
                elif op == "OpFMul": values[result] = values[args[1]] * values[args[2]]
                elif op == "OpFAdd": values[result] = values[args[1]] + values[args[2]]
                elif op == "OpCompositeInsert":
                    values[result] = values[args[2]][:]
                    values[result][int(args[3])] = values[args[1]]
                elif op == "OpStore": stores.append(values[args[1]])
            self.assertEqual(stores, [[vector[0], vector[1], expected_z, vector[3]]])
        original = re.search(r'OpEntryPoint Vertex (%\w+) "main"', after)[1]
        start = next(n for n, (result, op, _) in enumerate(statements) if result == original and op == "OpFunction")
        self.assertEqual([op for _, op, _ in statements[start:start + 5]],
                         ["OpFunction", "OpLabel", "OpFunctionCall", "OpReturn", "OpFunctionEnd"])

    def test_all_passes_and_duplicate_rejection(self):
        selected = ["vs_pad", "vs_init", "precise", "vs_depth"]
        output, text = self.apply(selected, fragments=("pair.frag",))
        self.assertIn('"main_depth"', text)
        self.assertEqual(set(locations(text, "Output")), {0, 1, 3})
        _, statements = parse(text)
        defaults = default_values(text)
        self.assertEqual(sum(op == "OpStore" and args[1] in defaults for _, op, args in statements), 3)
        # Markers are a rejection guard, not proof that untrusted input is
        # already correct. Never silently accept a marker as a successful pass.
        second = self.directory / "repeat.spv"
        with self.assertRaisesRegex(passes.PassError, "already applied"):
            passes.transform(output, second, ["vs_init"], [], "main", "vulkan1.1")
        with self.assertRaisesRegex(passes.PassError, "already applied"):
            passes.transform(output, second, ["vs_depth"], [], "main", "vulkan1.1")
        self.assertFalse(second.exists())

    def test_reject_missing_pair_without_overwriting_output(self):
        output = self.directory / "sentinel.spv"
        output.write_bytes(b"untouched output")
        with self.assertRaises(passes.PassError):
            passes.transform(self.inputs["pair.vert"], output, ["vs_pad"], [], "main", "vulkan1.1")
        self.assertEqual(output.read_bytes(), b"untouched output")

    def test_reject_unsupported_interface_without_overwriting_output(self):
        source = self.directory / "vec3.frag"
        source.write_text("#version 450\nlayout(location=5) in vec3 x; layout(location=0) out vec4 y; void main(){y=vec4(x,1);}\n")
        fragment = source.with_suffix(".spv")
        run(["glslangValidator", "-V", source, "-o", fragment])
        output = self.directory / "unsupported.spv"
        output.write_bytes(b"unchanged")
        with self.assertRaisesRegex(passes.PassError, "float32 vec4"):
            passes.transform(self.inputs["pair.vert"], output, ["vs_pad"], [fragment], "main", "vulkan1.1")
        self.assertEqual(output.read_bytes(), b"unchanged")

    def test_fragment_builtins_do_not_become_user_locations(self):
        source = self.directory / "builtins.frag"
        source.write_text("#version 450\nlayout(location=3) in vec4 x; layout(location=0) out vec4 y; void main(){y=gl_FrontFacing?x:gl_FragCoord;}\n")
        fragment = source.with_suffix(".spv")
        run(["glslangValidator", "-V", source, "-o", fragment])
        output = self.directory / "builtins-output.spv"
        passes.transform(self.inputs["pair.vert"], output, ["vs_pad"], [fragment], "main", "vulkan1.1")
        run(["spirv-val", "--target-env", "vulkan1.1", output])
        self.assertEqual(set(locations(disassemble(output), "Output")), {0, 1, 3})

    def test_vulkan10_preserves_spirv10(self):
        vertex = self.directory / "v10.spv"
        fragment = self.directory / "f10.spv"
        run(["glslangValidator", "-V", "--target-env", "vulkan1.0", HERE / "fixtures/pair.vert", "-o", vertex])
        run(["glslangValidator", "-V", "--target-env", "vulkan1.0", HERE / "fixtures/pair.frag", "-o", fragment])
        output = self.directory / "v10-output.spv"
        passes.transform(vertex, output, ["vs_pad", "vs_init", "precise", "vs_depth"], [fragment], "main", "vulkan1.0")
        self.assertEqual(output.read_bytes()[4:8], vertex.read_bytes()[4:8])
        run(["spirv-val", "--target-env", "vulkan1.0", output])

    def test_existing_vec2_pair_allows_missing_vec4_padding(self):
        vertex_source = self.directory / "mixed.vert"
        fragment_source = self.directory / "mixed.frag"
        vertex_source.write_text("#version 450\nlayout(location=0) out vec2 uv; void main(){uv=vec2(2,3); gl_Position=vec4(0,0,0,1);}\n")
        fragment_source.write_text("#version 450\nlayout(location=0) in vec2 uv; layout(location=3) in vec4 pad; layout(location=0) out vec4 color; void main(){color=vec4(uv,0,1)+pad;}\n")
        vertex = vertex_source.with_suffix(".vert.spv")
        fragment = fragment_source.with_suffix(".frag.spv")
        for source, output in ((vertex_source, vertex), (fragment_source, fragment)):
            run(["glslangValidator", "-V", source, "-o", output])
        output = self.directory / "mixed-output.spv"
        passes.transform(vertex, output, ["vs_pad"], [fragment], "main", "vulkan1.1")
        run(["spirv-val", "--target-env", "vulkan1.1", output])
        text = disassemble(output)
        self.assertEqual(set(locations(text, "Output")), {0, 3})
        self.assertTrue(any(f"OpStore {locations(text, 'Output')[3]} {default}" in text for default in default_values(text)))
        definitions, _ = parse(text)
        original_output = definitions[locations(text, "Output")[0]][1][0]
        vector = definitions[original_output][1][1]
        self.assertEqual(definitions[vector][1][1], "2")

    def test_precise_is_idempotent(self):
        output, text = self.apply(["precise"], "precise.frag")
        second = self.directory / "precise-repeat.spv"
        passes.transform(output, second, ["precise"], [], "main", "vulkan1.1")
        self.assertEqual(disassemble(second), text)

    def test_invalid_input_does_not_publish(self):
        invalid = self.directory / "invalid.spv"
        invalid.write_bytes(b"not SPIR-V")
        output = self.directory / "not-published.spv"
        with self.assertRaises(passes.PassError):
            passes.transform(invalid, output, ["precise"], [], "main", "vulkan1.1")
        self.assertFalse(output.exists())

    def test_cli_and_original_inputs_unchanged(self):
        snapshots = {p: p.read_bytes() for p in self.inputs.values()}
        output = self.directory / "cli.spv"
        run([sys.executable, TOOL, self.inputs["pair.vert"], "-o", output,
             "--passes", "vs_pad,vs_init,precise,vs_depth", "--fragment", self.inputs["pair.frag"]])
        run(["spirv-val", "--target-env", "vulkan1.1", output])
        self.assertEqual({p: p.read_bytes() for p in self.inputs.values()}, snapshots)


def negative_controls():
    """Mutate a private copy, never add a production bypass switch."""
    source = (HERE / "spirv_passes.py").read_text()
    nodes = {n.name: n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef)}
    lines = source.splitlines(keepends=True)
    with tempfile.TemporaryDirectory(prefix="s2a-vk-negative-") as temp:
        for name in ("vs_pad", "vs_init", "precise", "vs_depth"):
            node = nodes[name]
            mutant = Path(temp) / f"{name}.py"
            mutant.write_text("".join(lines[:node.lineno] + ["    return  # negative-control deletion\n"] + lines[node.end_lineno:]))
            env = {**os.environ, "SPIRV_PASS_TEST_TOOL": str(mutant)}
            result = subprocess.run([sys.executable, __file__, f"PassTests.test_{name}"],
                                    env=env, capture_output=True, text=True, timeout=90)
            if result.returncode == 0 or "FAIL:" not in result.stderr:
                raise AssertionError(f"negative control {name} did not fail its oracle\n{result.stdout}\n{result.stderr}")
            print(f"[OK] deletion of {name}: semantic oracle fails (rc={result.returncode})")


if __name__ == "__main__":
    if sys.argv[1:] == ["--negative-controls"]:
        negative_controls()
    else:
        unittest.main(verbosity=2)
