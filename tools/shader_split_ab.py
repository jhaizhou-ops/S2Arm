#!/usr/bin/env python3
"""手动 A/B 工具：需要真实私有输入，不进门禁；输入与输出仅本机保留。"""
import argparse
import cProfile
import csv
import filecmp
import hashlib
import importlib
import json
import os
from pathlib import Path
import pstats
import resource
import subprocess
import sys
import time


def write(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def load_cases(path):
    cases = json.loads(path.read_text())
    if not isinstance(cases, list) or not cases:
        raise ValueError("cases JSON must be a nonempty array")
    names = set()
    for case in cases:
        name = case["name"]
        if not name or name in (".", "..") or Path(name).name != name or name in names:
            raise ValueError(f"invalid or duplicate case name: {name!r}")
        names.add(name)
        for field in ("romfs", "mains"):
            if not isinstance(case[field], list) or not case[field]:
                raise ValueError(f"{name}: {field} must be a nonempty array")
            case[field] = [str((path.parent / entry).absolute()) for entry in case[field]]
        case["profile"] = str((path.parent / case["profile"]).absolute())
        if len(case["romfs"]) != len(case["mains"]) or any(
                "," in entry for field in ("romfs", "mains") for entry in case[field]):
            raise ValueError(f"{name}: equal-length arrays and comma-free paths required")
        for directory in [case["profile"], *case["romfs"]]:
            if not Path(directory).is_dir():
                raise FileNotFoundError(directory)
        for filename in [str(Path(case["profile"]) / "game.tsv"), *case["mains"]]:
            if not Path(filename).is_file():
                raise FileNotFoundError(filename)
        env = case.setdefault("env", {})
        if set(env) - {"DM_UE_SHADERS", "DM_GLSLC_CAPTURE", "J"}:
            raise ValueError(f"{name}: env only accepts DM_UE_SHADERS/DM_GLSLC_CAPTURE/J")
        for key, value in env.items():
            if key == "J":
                if not str(value).isdigit() or int(value) < 1:
                    raise ValueError(f"{name}: J must be a positive integer")
                env[key] = str(value)
                continue
            env[key] = str((path.parent / value).absolute())
            if not Path(env[key]).is_dir():
                raise FileNotFoundError(env[key])
        if "DM_GLSLC_CAPTURE" in env and not any(Path(env["DM_GLSLC_CAPTURE"]).glob("*.glslc")):
            raise ValueError(f"{name}: explicit capture directory has no real .glslc inputs")
    return cases


def inputs(case):
    profile = Path(case["profile"])
    return {"mains": {p: sha(Path(p)) for p in sorted(set(case["mains"]))},
            "profile": {str(p.relative_to(profile)): sha(p) for p in sorted(profile.rglob("*")) if p.is_file()}}


def child(source, cases_path, index, directory, variant):
    source, directory = Path(source), Path(directory)
    case = load_cases(Path(cases_path))[int(index)]
    for key in ("DM_GLSLC_CAPTURE", "DM_UE_SHADERS", "DM_OODLE_JOB"):
        os.environ.pop(key, None)
    os.environ.update(case["env"], DM_GAME=case["profile"])
    (directory / "pkg").mkdir()
    tables = [directory / f"shader_{name}.tsv" for name in ("map", "facts", "pairs")]
    argv = [str(source), ",".join(case["romfs"]), ",".join(case["mains"]), str(directory / "pkg"), *map(str, tables)]
    before = inputs(case)
    source_sha = sha(source)
    expected = len(case["mains"]) if variant == "baseline" else len({os.path.realpath(p) for p in case["mains"]})
    write(directory / "identity.json", {"argv": argv, "process_argv": sys.argv, "source_sha256": source_sha,
          "case": case, "before": before, "python": sys.version, "jobs": os.environ.get("J", "unset")})
    sys.path.insert(0, str(source.parent))
    module = importlib.import_module("shader_split")
    if Path(module.__file__).resolve() != source.resolve():
        raise RuntimeError(f"wrong imported module: {module.__file__}")
    sys.argv = argv
    profiler = cProfile.Profile()
    start = time.monotonic()
    try:
        profiler.runcall(module.main)
    finally:
        elapsed = time.monotonic() - start
        profiler.dump_stats(str(directory / "profile.pstats"))
        calls = {name: {"total": 0, "from_main": 0} for name in ("nso_image", "scan_blob", "glslc_shaders")}
        for (filename, _, name), (_, total, _, _, callers) in pstats.Stats(profiler).stats.items():
            if filename == str(source) and name in calls:
                calls[name]["total"] += total
                calls[name]["from_main"] += sum(v[1] for k, v in callers.items() if k[0] == str(source) and k[2] == "main")
        after = inputs(case)
        rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        result = {"main_wall_seconds_profiled": elapsed, "maxrss_parent_bytes": rss if sys.platform == "darwin" else rss * 1024,
                  "rss_scope": "extractor parent only, excludes worker processes", "calls": calls, "after": after,
                  "expected_nso_main_calls": expected, "input_hash_scope": "NSO and profile files; excludes full RomFS",
                  "inputs_unchanged": before == after, "source_unchanged": sha(source) == source_sha}
        write(directory / "result.json", result)
    assert result["inputs_unchanged"] and result["source_unchanged"], "input/source changed"
    assert all(calls[name]["from_main"] == expected for name in ("nso_image", "scan_blob")), calls
    for table in tables:
        if not table.is_file():
            raise FileNotFoundError(table)


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog="Run with the extractor dependencies installed. Cases: [{\"name\":\"label\",\"profile\":\"profile-dir\",\"romfs\":[\"romfs\"],\"mains\":[\"exefs/main\"],\"env\":{}}]. Paths are relative to the cases JSON. J controls existing extractor concurrency. No sample data is supplied.")
    for name in ("baseline", "candidate", "cases", "output"):
        parser.add_argument(name, type=Path, help={"baseline": "baseline shader_split.py", "candidate": "candidate shader_split.py", "cases": "private real-input cases JSON", "output": "new local output directory; must not exist"}[name])
    args = parser.parse_args()
    args.baseline, args.candidate, args.cases = (p.resolve(strict=True) for p in (args.baseline, args.candidate, args.cases))
    cases = load_cases(args.cases)
    args.output = args.output.absolute()
    args.output.mkdir(parents=True)
    write(args.output / "suite.json", {"argv": sys.argv, "cases_sha256": sha(args.cases), "python": sys.executable,
          "limits": "Serial baseline then candidate, cProfile enabled, filesystem cache not reset; parent RSS only. No gameplay/performance acceptance."})
    comparisons = {}
    for index, case in enumerate(cases):
        directories, results, identities = [], [], []
        for variant in ("baseline", "candidate"):
            directory = args.output / f"{case['name']}-{variant}"
            directory.mkdir()
            command = [sys.executable, str(Path(__file__).resolve()), "--child", str(getattr(args, variant)), str(args.cases), str(index), str(directory), variant]
            start = time.monotonic()
            with (directory / "run.log").open("x") as log:
                process = subprocess.run(command, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}, stdout=log, stderr=subprocess.STDOUT)
            write(directory / "process.json", {"command": command, "exit_code": process.returncode, "wall_seconds": time.monotonic() - start})
            if process.returncode:
                raise SystemExit(f"{case['name']} {variant} failed ({process.returncode}); see {directory / 'run.log'}")
            directories.append(directory)
            results.append(json.loads((directory / "result.json").read_text()))
            identities.append(json.loads((directory / "identity.json").read_text()))
        assert identities[0]["before"] == identities[1]["before"], "inputs changed between runs"
        files = [{str(p.relative_to(d)): p for p in [*(d / "pkg").glob("*.bin"), *(d.glob("*.tsv"))]} for d in directories]
        assert files[0].keys() == files[1].keys(), "output file sets differ"
        for name in files[0]:
            assert filecmp.cmp(files[0][name], files[1][name], shallow=False), f"output bytes differ: {name}"
        with (directories[0] / "shader_map.tsv").open() as stream:
            main_sources = sum(len(row) >= 5 and row[4].startswith("main") for row in csv.reader(stream, delimiter="\t"))
        comparisons[case["name"]] = {"byte_identical_files": sorted(files[0]), "main_source_rows": main_sources, "results": dict(zip(("baseline", "candidate"), results))}
        print(f"{case['name']}: {len(files[0])} byte-identical files; main sources {main_sources}", flush=True)
    write(args.output / "comparison.json", comparisons)


if __name__ == "__main__":
    child(*sys.argv[2:]) if sys.argv[1:2] == ["--child"] else main()
