#!/usr/bin/env python3
"""Build real #116 inputs through the production offline tools, without fabricated GALI.

Two authored fragment programs, each with RGBA8 and BGRA8 full descriptors.
The output manifest is: library path, vertex function, fragment function (TSV).
This is a compiler fixture, not game coverage or a performance measurement.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--gal-xc", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
src = out / "source"
spv = out / "spv"
pack = out / "pack"
for directory in (src, spv, pack, out / "logs", out / "cache", out / "chunk"):
    directory.mkdir()
commands = []


def run(name, argv, extra=None):
    env = os.environ.copy()
    env.update(extra or {})
    result = subprocess.run([str(a) for a in argv], env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=600)
    (out / "logs" / (name + ".log")).write_bytes(result.stdout)
    commands.append({"name": name, "argv": [str(a) for a in argv],
                     "environment": extra or {}, "exit": result.returncode})
    (out / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    result.check_returncode()
    return result.stdout.decode().strip()


for name in ("m3archive.vert", "m3archive_red.frag", "m3archive_blue.frag"):
    shutil.copyfile(Path(__file__).parent / name, src / name)
    run(name + "-compile", ["glslangValidator", "-V", "--target-env", "vulkan1.0",
                            src / name, "-o", spv / (name + ".spv")])
    run(name + "-validate", ["spirv-val", "--target-env", "vulkan1.0", spv / (name + ".spv")])

run("offline", ["python3", root / "graphics/metal/tools/gal_offline.py", spv, pack, "macos"],
    {"GAL_XC": str(args.gal_xc.resolve()), "GAL_AIR_CACHE": str(out / "cache" / "air")})
for failures in ("xc_failed.txt", "metal_failed.txt"):
    path = pack / failures
    if path.exists() and path.read_text().strip():
        raise RuntimeError(f"production compiler reported failures: {path}")

# Read actual compiler records; never construct or patch the index.
index = (pack / "gal.idx").read_bytes()
if index[:4] != b"GALI":
    raise ValueError("compiler did not emit GALI")
count = struct.unpack_from("<I", index, 16)[0]
stages = {}
for i in range(count):
    key, offset, length = struct.unpack_from("<QII", index, 24 + i * 16)
    if offset + length > len(index):
        raise ValueError("truncated compiler record")
    stage = struct.unpack_from("<I", index, offset + 8)[0]
    stages.setdefault(stage, []).append(f"{key:016x}")
if len(stages.get(1, [])) != 1 or len(stages.get(5, [])) != 2 or count != 3:
    raise ValueError(f"unexpected actual shader stages: {stages}")
vs = stages[1][0]
fragments = sorted(stages[5])
shards = [(int(k, 16), pack / name) for k, name in
          (line.split("\t") for line in (pack / "gal.shards").read_text().splitlines())]
if len(shards) != 1:
    raise ValueError("small fixture must remain in one actual library")
library = shards[0][1]
programs = out / "programs.tsv"
programs.write_text("idx\torigin\tstatus\tkind\tsource\tstages\tspv\tms\terr\n" +
                    "".join(f"{i}\tfixture\tok\tgraphics\tauthored-glsl\tvertex,fragment\t{vs},{fs}\t0\t\n"
                            for i, fs in enumerate(fragments)))
# Explicit fixture inputs, not claimed to be observations from a game.
spec = out / "full-descriptors.tsv"
spec.write_text("# Authored pipeline inputs: two programs x RGBA8/BGRA8, no blending.\n" +
                "".join(f"v2 s{vs} s{fs} 0 1 0 0 1 0:{pf}:15:0:0:1:0:0:1:0" +
                        "".join(f" {i}:0:15:0:0:1:0:0:1:0" for i in range(1, 8)) + "\n"
                        for fs in fragments for pf in (70, 80)))
run("pso-gen", ["python3", root / "graphics/tools/shbake/pso_gen.py", programs,
                pack / "gal.idx", pack / "gal.shards", pack / "pso", "300",
                pack / "metal_failed.txt", pack / "msl", spec], {"PSO_M3": "1"})
shutil.copyfile(pack / "pso.idx", pack / "gal_pso.idx")

run("gpu-arch-build", ["xcrun", "clang", "-fobjc-arc", "-O1",
                       root / "graphics/tools/shbake/gpu_arch.m", "-framework", "Metal",
                       "-framework", "Foundation", "-o", out / "gpu_arch"])
arch = run("gpu-arch", [out / "gpu_arch"])
os_version = run("os-version", ["sw_vers", "-productVersion"])
sdk = run("sdk-version", ["xcrun", "--sdk", "macosx", "--show-sdk-version"])
tool_version = run("metal-tt-version", ["xcrun", "-sdk", "macosx", "metal-tt", "-version"])
chunk_env = {"PSO_M3": "1", "PSO_M3VER": ".".join(os_version.split(".")[:2]),
             "PSO_A": arch, "PSO_PLAT": "macos", "PSO_M": os_version.split(".")[0],
             "PSO_SV": sdk, "PSO_NTV": tool_version.splitlines()[0],
             "PSO_SIG": "m3archive-production-fixture", "PSO_O": str(pack),
             "PSO_W": str(out / "chunk"), "PSO_PC": str(out / "cache" / "pso")}
scripts = sorted(pack.glob("pso.*.mtlp-json"))
if not scripts:
    raise RuntimeError("no pipeline scripts emitted")
for script in scripts:
    run(script.stem + "-chunk", ["bash", root / "graphics/tools/shbake/pso_chunk.sh", script], chunk_env)
if list((out / "chunk").glob("*.fail")):
    raise RuntimeError("pso_chunk reported a failed archive; see retained chunk logs")
archives = sorted(pack.glob("gal_pso.*.bin"))
if len(archives) != len(scripts) or any(p.stat().st_size == 0 for p in archives):
    raise RuntimeError("pipeline archive output missing")
manifest = out / "manifest.tsv"
manifest.write_text("".join(f"{library}\ts{vs}\ts{fs}\n" for fs in fragments))
(pack / "shader_pack.key").write_text(hashlib.sha256(index).hexdigest() + "\n")
identity_paths = [args.gal_xc.resolve(), args.gal_xc.resolve().parent / "libnxgal.dylib",
                  Path(__file__).resolve(), root / "graphics/metal/tools/gal_offline.py",
                  root / "graphics/tools/shbake/pso_gen.py", root / "graphics/tools/shbake/pso_chunk.sh"]
identity_paths += sorted(p for p in out.rglob("*") if p.is_file())
identity = {str(p): {"sha256": hashlib.sha256(p.read_bytes()).hexdigest(), "bytes": p.stat().st_size}
            for p in identity_paths}
(out / "identity.json").write_text(json.dumps(identity, indent=2) + "\n")
print(json.dumps({"manifest": str(manifest), "pack": str(pack), "programs": 2,
                  "full_descriptors": 4, "archives": len(archives), "arch": arch,
                  "os": os_version}, indent=2))
