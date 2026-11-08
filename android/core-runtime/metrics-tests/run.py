#!/usr/bin/env python3
"""离线跑 PR209 实际写出器与精确 WSI→runtime 采样接缝；硬件/时钟为受控输入。"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def section(text, start, end):
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError("生产接缝边界变化，拒绝猜选: " + start)
    return text[text.index(start):text.index(end)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dotnet", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    runtime = ROOT / "graphics/vulkan/runtime/AndroidVulkanRuntime.cs"
    window = ROOT / "graphics/vulkan/wsi/AndroidWindow.cs"
    surface = ROOT / "graphics/vulkan/wsi/AndroidVulkanSurface.cs"
    ledger = ROOT / "graphics/vulkan/wsi/RetirementLedger.cs"
    producer = HERE.parent / "AndroidRunMetrics.cs"
    services = HERE.parent / "AndroidGameRuntime.cs"
    runtime_body = section(runtime.read_text(), "                    Action<ulong> sample = FramePresented;", "                    s2aPresents++;")
    window_text = window.read_text()
    window_admission = section(window_text, "        Poll();\n        // Single GPU owner:", "        Semaphore acquire;")
    # Keep the acceptance/counter consumer; subsequent first-frame/600-frame logging
    # belongs to the upstream diagnostics, not this controlled present boundary.
    acceptance = section(window_text, "        Result outer;\n", "        if (!_s2aFirstPresentLogged)")
    counter = next(line for line in surface.read_text().splitlines() if "public ulong QueuedGamePresents =>" in line)
    fixture = (HERE / "PresentWiring.cs.in").read_text().replace("RUNTIME_PRESENT_BODY", runtime_body)
    fixture = fixture.replace("WINDOW_ADMISSION", window_admission).replace("WINDOW_ACCEPTANCE", acceptance).replace("SURFACE_COUNTER", counter)
    services_text = services.read_text()
    binding = next(line for line in services_text.splitlines() if "if (_metrics != null) _gpu.FramePresented = _metrics.Present;" in line)
    cleanup = section(services_text, "        private static void Cleanup()", "        private static RegionCode Region(")
    fixture = fixture.replace("SERVICE_BINDING", binding).replace("SERVICE_CLEANUP", cleanup)
    paths = [runtime, window, surface, ledger, producer, services, HERE / "Program.cs", HERE / "PresentWiring.cs.in", Path(__file__).resolve()]
    (out / "sources.json").write_text(json.dumps({str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}, indent=2) + "\n")
    results = []
    cases = (("producer", (HERE / "Program.cs").read_text(), None),
             ("old-close-order", (HERE / "Program.cs").read_text(), "interval close must wait for in-flight callback clock"),
             ("wiring", fixture, None),
             ("missing-callback", fixture.replace("if (presents != previousPresents) sample(presents);", "if (false) sample(presents);"), "success/suboptimal callback must write four rows"),
             ("wrong-acceptance", fixture.replace("if (!accepted)", "if (false)"), "empty or failed present must not write a row"),
             ("truncated-tail", fixture, "stop clock includes tail"),
             ("missing-binding", fixture.replace(binding, ""), "success/suboptimal callback must write four rows"),
             ("missing-stop-boundary", fixture.replace("StopGpu(); // If this cannot quiesce, keep HLE memory and owner alive.", "// negative: cleanup skips GPU stop"), "unproven GPU stop must reject cleanup"))
    cases += (("missing-audio-stop", fixture.replace("Host.DisposeAudioForShutdown();", ""), "audio workers must stop before driver event disposal"),)
    for name, program, expected in cases:
        directory = out / name
        directory.mkdir()
        (directory / "Program.cs").write_text(program)
        text = producer.read_text()
        if name == "old-close-order":
            close = text.index("        public void Dispose()")
            begin = text.index("            lock (_intervalLock)", close)
            settle = text.index("                if (_interval >= 0)", begin)
            text = text[:begin] + "            if (_disposed) return;\n            _endUs = _clock();\n            _disposed = true;\n            lock (_intervalLock)\n            {\n" + text[settle:]
        if name == "truncated-tail":
            text = text.replace("_endUs = _clock();", "_endUs = _lastUs;")
        (directory / "AndroidRunMetrics.cs").write_text(text)
        if name not in ("producer", "old-close-order"): shutil.copyfile(ledger, directory / ledger.name)
        (directory / "Proof.csproj").write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><AllowUnsafeBlocks>true</AllowUnsafeBlocks><InvariantGlobalization>true</InvariantGlobalization><JsonSerializerIsReflectionEnabledByDefault>false</JsonSerializerIsReflectionEnabledByDefault></PropertyGroup></Project>')
        (directory / "NuGet.Config").write_text('<configuration><packageSources><clear /></packageSources></configuration>')
        build = [str(args.dotnet), "build", str(directory / "Proof.csproj"), "--configfile", str(directory / "NuGet.Config"), "-v:q"]
        built = subprocess.run(build, capture_output=True, text=True, timeout=90)
        (directory / "build.log").write_text(built.stdout + built.stderr)
        if built.returncode: raise SystemExit(built.stdout + built.stderr)
        command = [str(args.dotnet), str(directory / "bin/Debug/net10.0/Proof.dll"), str(directory / "capture")]
        run = subprocess.run(command, capture_output=True, text=True, timeout=30)
        output = run.stdout + run.stderr
        (directory / "run.log").write_text(output)
        passed = run.returncode == 0 if expected is None else run.returncode != 0 and "FAIL " + expected in output
        results.append({"name": name, "build": build, "command": command, "exit": run.returncode, "expectedFailure": expected, "passed": passed})
        (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(name, "PASS" if passed else "FAIL")
        if not passed: raise SystemExit(output)


if __name__ == "__main__":
    main()
