# 门禁手动：要真实音频输出：build 之后 run 在两个真实 CoreAudio 进程里分别开 / 关缓冲出声（要传 --build / --out 与 S2A_AUDIO_* 环境）
"""Build without hardware; explicitly run on/off in separate real CoreAudio processes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from analyze import Incomplete, analyze

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def save(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", help="CPU only, cached packages via an empty feed")
    build.add_argument("--source-root", type=Path, default=ROOT)
    build.add_argument("--out", type=Path, required=True)
    run = commands.add_parser("run", help="opens audio hardware; coordinate hardware access first")
    run.add_argument("--build", type=Path, required=True, help="completed build output from this tool")
    run.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    dotnet = os.environ.get("DOTNET", "dotnet")
    env = dict(os.environ, DOTNET_PROCESSOR_COUNT="2", DOTNET_CLI_USE_MSBUILD_SERVER="0", MSBUILDDISABLENODEREUSE="1")
    fixture = {str(path.relative_to(HERE)): sha(path) for path in sorted(HERE.iterdir()) if path.suffix in (".cs", ".csproj", ".py")}
    if args.command == "build":
        source = args.source_root.resolve()
        paths = [source / "compat/tree/Directory.Build.props",
                 *sorted((source / "compat/tree/src/Ryujinx.Audio.Backends.Apple").rglob("*.cs")),
                 *sorted((source / "compat/tree/src/Ryujinx.Audio/Backends/Common").glob("*.cs"))]
        paths = [path for path in paths if not {"bin", "obj"}.intersection(path.relative_to(source).parts)]
        before = {str(path.relative_to(source)): sha(path) for path in paths}
        head = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
        diff = subprocess.check_output(["git", "-C", str(source), "diff", "HEAD", "--", "compat/tree/src/Ryujinx.Audio", "compat/tree/src/Ryujinx.Audio.Backends.Apple"], text=True)
        (out / "source.diff").write_text(diff)
        feed = out / "empty-nuget"
        feed.mkdir()
        argv = [dotnet, "build", str(HERE / "AudioCompletion.csproj"), "-c", "Release", "--artifacts-path", str(out / "artifacts"),
                "--source", str(feed), "-m:2", "-nr:false", "-p:UseSharedCompilation=false", "-p:GeneratePackageOnBuild=false", f"-p:AudioSourceRoot={source}"]
        start = time.monotonic()
        with (out / "build.log").open("xb") as log:
            process = subprocess.run(argv, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        after = {str(path.relative_to(source)): sha(path) for path in paths}
        binary = out / "artifacts/bin/AudioCompletion/release/AudioCompletion.dll"
        dlls = {path.name: sha(path) for path in sorted(binary.parent.glob("*.dll"))}
        identity = dict(source_root=str(source), source_head=head, argv=argv, exit=process.returncode,
                        wall_seconds=time.monotonic() - start, fixture=fixture, source_before=before,
                        source_after=after, source_unchanged=before == after, binary=str(binary), dll_sha256=dlls)
        save(out / "identity.json", identity)
        print(json.dumps({key: identity[key] for key in ("exit", "source_head", "source_unchanged", "wall_seconds", "binary")}))
        return process.returncode or (0 if before == after else 1)
    build_identity = json.loads((args.build.resolve() / "identity.json").read_text())
    if build_identity["exit"] != 0 or not build_identity["source_unchanged"] or fixture != build_identity["fixture"]:
        raise ValueError("Build was unsuccessful, source changed while building, or this fixture differs from its build")
    binary = Path(build_identity["binary"])
    if {path.name: sha(path) for path in binary.parent.glob("*.dll")} != build_identity["dll_sha256"]:
        raise ValueError("Actual dependency DLLs differ from the recorded real build")
    save(out / "build-identity.json", build_identity)
    results = []
    for mode in ("on", "off"):
        directory = out / mode
        run_env = dict(env, S2A_AUDIO_CUSHION="1" if mode == "on" else "0", S2A_AUDIO_CH2="1", S2A_AUDIO_WAV=str(directory / "queue"))
        argv = [dotnet, str(binary), "--run", "--cushion", mode, "--out", str(directory)]
        start = time.monotonic()
        with (out / f"{mode}.log").open("xb") as log:
            process = subprocess.run(argv, cwd=ROOT, env=run_env, stdout=log, stderr=subprocess.STDOUT, timeout=15)
        if process.returncode != 0:
            result = dict(exit=1, verdict="collector_failed", collector_exit=process.returncode)
        else:
            try:
                result = analyze(directory)
            except Incomplete as error:
                result = dict(exit=2, verdict="incomplete_observation", reason=str(error))
        result.update(mode=mode, argv=argv, collector_exit=process.returncode, wall_seconds=time.monotonic() - start)
        save(out / f"{mode}-result.json", result)
        results.append(result)
    code = 1 if any(row["exit"] == 1 for row in results) else 2 if any(row["exit"] == 2 for row in results) else 0
    save(out / "result.json", dict(exit=code, results=results))
    print(json.dumps(dict(exit=code, modes=[{key: row[key] for key in ("mode", "exit", "verdict")} for row in results])))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
