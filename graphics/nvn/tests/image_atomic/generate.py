"""Authored GLSL -> actual SPIR-V/MSL -> supported production reflection CLI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--out", required=True, type=Path)
parser.add_argument("--dsh", required=True, type=Path)
args = parser.parse_args()
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
OUT = args.out.resolve()
OUT.mkdir(parents=True, exist_ok=True)
(OUT / "generated.stamp").unlink(missing_ok=True)
DLL = args.dsh.resolve()
if not DLL.is_file():
    raise FileNotFoundError(DLL)
for name in ("glslangValidator", "spirv-cross", "xcrun", "dotnet"):
    if not shutil.which(name):
        raise RuntimeError("missing required tool: " + name)
commands = []


def run(argv, name):
    start = time.monotonic()
    with (OUT / (name + ".log")).open("w") as log:
        result = subprocess.run(list(map(str, argv)), cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    commands.append({"argv": list(map(str, argv)), "exit": result.returncode,
                     "wall_seconds": time.monotonic() - start})
    (OUT / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    if result.returncode:
        raise RuntimeError(f"{name}: exit {result.returncode}; see {OUT / (name + '.log')}")


entries, cases = [], []
for label, source, signed, version in (
    ("uint3d", "atomic3d.comp", False, 30100), ("int3d", "atomic3d.comp", True, 30100),
    ("uint-observe", "observe3d.comp", False, 30100), ("int-observe", "observe3d.comp", True, 30100),
    ("buffer", "atomicbuffer.comp", False, 20300), ("buffer-observe", "observebuffer.comp", False, 20300),
    ("buffer30100", "atomicbuffer.comp", False, 30100), ("alias3d", "alias3d.comp", False, 30100),
    ("unbound-uint-buffer", "unboundbuffer.comp", False, 30100),
    ("unbound-int-buffer", "unboundbuffer.comp", True, 30100),
    ("array-negative", "array_negative.comp", False, 30100)):
    spv, msl, reflection = (OUT / (label + ext) for ext in (".spv", ".metal", ".spv-reflect.json"))
    run(["glslangValidator", "-V", "--target-env", "vulkan1.1", "-S", "comp",
         *(["-DSIGNED_IMAGE=1"] if signed else []), HERE / source, "-o", spv], label + ".glslang")
    run(["spirv-cross", "--msl", "--msl-version", str(version), "--msl-argument-buffers",
         "--msl-texture-buffer-native", "--msl-pad-fragment-output", spv, "--output", msl], label + ".cross")
    run(["spirv-cross", spv, "--reflect", "--output", reflection], label + ".reflect")
    raw = json.loads(reflection.read_text())
    if raw.get("ssbos"):
        raise ValueError("fixture unexpectedly contains an SSBO: " + label)
    # The real modules contain only images. Preserve actual reflection and its
    # proven empty storage-buffer list; never invent Maxwell cbuf metadata.
    cases.append({"fn": "reflect", "args": ["cs", msl.read_text(), {**raw, "sbufs": []}]})
    run(["xcrun", "-sdk", "macosx", "metal", "-c", "-fpreserve-invariance",
         "-mmacosx-version-min=15.0", msl, "-o", OUT / (label + ".air")], label + ".metal")
    run(["xcrun", "-sdk", "macosx", "metallib", OUT / (label + ".air"), "-o", OUT / (label + ".metallib")], label + ".metallib")
    ep = raw["entryPoints"][0]
    entries.append({"label": label, "source": source, "msl_version": version,
                    "spirv_entry": ep["name"], "workgroup_size": ep["workgroup_size"],
                    "expect_reflect_error": label == "array-negative"})
(OUT / "reflect-cases.json").write_text(json.dumps(cases, indent=2) + "\n")
run(["dotnet", DLL, "--fn", OUT / "reflect-cases.json", OUT / "reflect-results.json"], "production-reflect")
answers = json.loads((OUT / "reflect-results.json").read_text())
if len(answers) != len(entries):
    raise ValueError("production reflection result count mismatch")
for entry, answer in zip(entries, answers):
    if entry["expect_reflect_error"]:
        if answer.get("err") != "DshError:reflect failed":
            raise ValueError(f"real array receiver was not rejected: {answer}")
        (OUT / (entry["label"] + ".reflection-error.json")).write_text(json.dumps(answer, indent=2) + "\n")
        entry["actual_reflect_error"] = answer["err"]
        continue
    if "ok" not in answer:
        raise ValueError(f"production reflection failed: {entry['label']}: {answer}")
    bindings = answer["ok"]
    if not bindings or any(b["kind"] != "img" or b["reg"] not in (0, 1) for b in bindings):
        raise ValueError(f"unexpected real bindings for {entry['label']}: {bindings}")
    # Only container metadata is assembled here. All bindings come directly
    # from production Reflect, and local size comes from actual SPIR-V reflection.
    result = {"route": "B", "bindings": bindings, "threadgroup_size": entry["workgroup_size"]}
    (OUT / (entry["label"] + ".nvn.json")).write_text(json.dumps(result, indent=2) + "\n")
    entry["bindings"] = bindings
files = list(HERE.glob("*.comp")) + list(OUT.glob("*.spv")) + list(OUT.glob("*.metal")) + [DLL]
identity = {"entries": entries, "commands": commands,
            "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "files": {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}
(OUT / "generation.json").write_text(json.dumps(identity, indent=2) + "\n")
(OUT / "generated.stamp").touch()
print(f"generated {len(entries)} real GLSL entries; production reflection accepted 10 and rejected array receiver; GPU not executed")
