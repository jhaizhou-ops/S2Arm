#!/usr/bin/env python3
"""Offline local-draft codec gate, using real linked GAL definitions. No GPU or devices."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="new absolute directory outside checkout")
    parser.add_argument("--metadata-boundaries", action="store_true", help="run the metadata regression cases only")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    root = here.parents[3]
    output = args.out
    if not output.is_absolute() or output.exists() or output.resolve().is_relative_to(root):
        parser.error("--out must be a new absolute directory outside this checkout")
    required = ("dotnet", "spirv-as", "spirv-val")
    paths = {tool: shutil.which(tool) for tool in required}
    if not all(paths.values()):
        parser.error("required installed offline tools: " + ", ".join(required))
    output.mkdir(parents=True)
    result = {"gpu_executed": False, "production_loader_connected": False, "status": "failed", "commands": []}

    def run(command):
        completed = subprocess.run(command, cwd=root, text=True, capture_output=True)
        result["commands"].append({"argv": list(map(str, command)), "returncode": completed.returncode,
                                   "stdout": completed.stdout, "stderr": completed.stderr})
        if completed.returncode:
            raise RuntimeError("command failed: " + str(command[0]))
        return completed.stdout

    try:
        result["git_head"] = run(["git", "rev-parse", "HEAD"]).strip()
        result["git_status"] = run(["git", "status", "--short"])
        project = here / "CodecTests.csproj"
        properties = {p.tag: p.text for group in ET.parse(project).getroot().findall("PropertyGroup") for p in group}
        sources = set(here.parent.glob("*.cs")) | set(here.glob("*"))
        for item in ET.parse(project).getroot().findall(".//Compile"):
            for name in item.attrib["Include"].split(";"):
                for key, value in properties.items():
                    name = name.replace("$(" + key + ")", value or "")
                if "*" not in name:
                    sources.add((here / name).resolve())
        result["source_sha256"] = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in sorted(sources) if p.is_file()}
        result["tools"] = {tool: {"path": path, "version": run([path, "--version"])}
                           for tool, path in paths.items()}
        for stage in ("compute", "vertex", "fragment"):
            binary = output / (stage + ".spv")
            run([paths["spirv-as"], "--target-env", "vulkan1.2", str(here / (stage + ".spvasm")), "-o", str(binary)])
            run([paths["spirv-val"], "--target-env", "vulkan1.2", str(binary)])
        artifacts = output / "build"
        run([paths["dotnet"], "restore", str(project), "--configfile", str(here / "NuGet.Config"), "--artifacts-path", str(artifacts)])
        run([paths["dotnet"], "build", str(project), "--no-restore", "--artifacts-path", str(artifacts), "-c", "Release"])
        binary = artifacts / "bin" / "CodecTests" / "release" / "CodecTests.dll"
        command = [paths["dotnet"], str(binary), str(output)]
        if args.metadata_boundaries:
            command.append("--metadata-boundaries")
        report = run(command)
        print(report, end="")
        result["status"] = "host_pass"
    finally:
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
