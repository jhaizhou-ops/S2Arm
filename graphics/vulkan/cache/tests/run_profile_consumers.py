#!/usr/bin/env python3
"""Offline production profile consumers. CPU only; no VkDevice or Android session."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import os

from profile_build import PrivateBuild, discover_dotnet_sdk, preflight_java, reject_output_overrides, require_negative


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="new absolute directory outside checkout")
    parser.add_argument("--negative-controls", action="store_true", help="remove actual consumer paths in private source mirrors")
    parser.add_argument("--android-sdk", type=Path, help="optional installed Android SDK for actual Java source compilation")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[4]
    out = args.out
    if not out.is_absolute() or out.exists() or out.resolve().is_relative_to(root):
        parser.error("--out must be a new absolute directory outside checkout")
    for command in ("dotnet", "spirv-val", "clang++"):
        if not shutil.which(command):
            parser.error("required installed offline tool: " + command)
    dotnet_launcher = Path(shutil.which("dotnet")).absolute()
    out.mkdir(parents=True)
    report = {"gpu_executed": False, "native_device_initialized": False,
              "android_session_executed": False, "commands": [], "status": "failed"}

    def run(argv, *, cwd=root, expected=0):
        argv = list(map(str, argv))
        if argv[0] == "dotnet":
            argv[0] = str(dotnet_launcher)
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
        report["commands"].append({"argv": argv, "cwd": str(cwd), "returncode": p.returncode,
                                   "stdout": p.stdout, "stderr": p.stderr})
        if (expected == 0 and p.returncode != 0) or (expected != 0 and p.returncode == 0):
            raise RuntimeError("unexpected result: " + str(argv[0]) + "\n" + p.stdout[-3000:] + p.stderr[-3000:])
        return p

    try:
        reject_output_overrides()
        java_tools = preflight_java(args.android_sdk) if args.android_sdk else None
        if java_tools:
            report["java"] = java_tools
        sdk = discover_dotnet_sdk(dotnet_launcher, run)
        report["dotnet"] = sdk
        dotnet_root = Path(sdk["sdk_root"])
        package_root = Path(os.environ.get("NUGET_PACKAGES", Path.home() / ".nuget/packages")).resolve()
        report["dependency_roots"] = [str(dotnet_root), str(package_root)]
        report["dotnet_sdk_version"] = sdk["sdk_version"]
        report["git_head"] = run(["git", "rev-parse", "HEAD"]).stdout.strip()
        report["git_status"] = run(["git", "status", "--short"]).stdout
        paths = [root / "graphics/vulkan/cache", root / "graphics/tools/shbake",
                 root / "compat/tree/src/Ryujinx.Graphics.GAL", root / "compat/tree/src/Ryujinx.Graphics.Gpu/Shader",
                 root / "compat/tree/src/Ryujinx.Graphics.Vulkan"]
        report["source_sha256"] = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                                   for base in paths for p in sorted(base.rglob("*.cs"))}
        project = "graphics/tools/shbake/S2A.ShBake.csproj"
        positive = PrivateBuild(root, out / "positive", run, [dotnet_root, package_root])
        report["private_builds"] = {"positive": positive.record}
        binary = positive.build(project)
        consumer = run(["dotnet", positive.executable(binary), "selftest-profile-freeze", out / "consumer"])
        print(consumer.stdout, end="")
        for stage in ("compute", "fragment"):
            run(["spirv-val", "--target-env", "vulkan1.1", out / "consumer" / (stage + ".spv")])
        apple = run(["dotnet", positive.executable(binary), "selftest-vtg"])
        print(apple.stdout, end="")
        renderer_binary = positive.build("graphics/vulkan/cache/tests/renderer/RendererProfile.Tests.csproj")
        renderer = run(["dotnet", positive.executable(renderer_binary)])
        print(renderer.stdout, end="")

        # Compile and execute the exact production JNI setter with only JNI typedefs and
        # the host-exists state supplied by a CPU fixture. No Android host is instantiated.
        bridge = (root / "android/native/bridge.cpp").read_text()
        start = bridge.index('extern "C" JNIEXPORT jint JNICALL\nJava_org_s2arm_android_NativeBridge_configureProfileFreeze')
        end = bridge.index('\n}\n', start) + 3
        setter = bridge[start:end]
        harness = """#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <cstdio>
#define JNIEXPORT
#define JNICALL
using jint = int; using jboolean = unsigned char; using jclass = void*; struct JNIEnv;
static void *g_game_host = nullptr;
""" + setter + """
int main() {
#ifdef S2A_ANDROID_GAME_RUNTIME
    if (Java_org_s2arm_android_NativeBridge_configureProfileFreeze(nullptr,nullptr,0) || std::strcmp(std::getenv("S2A_W9_PROFILE_FREEZE"),"0")) return 1;
    if (Java_org_s2arm_android_NativeBridge_configureProfileFreeze(nullptr,nullptr,1) || std::strcmp(std::getenv("S2A_W9_PROFILE_FREEZE"),"1")) return 2;
    g_game_host = reinterpret_cast<void*>(1);
    if (Java_org_s2arm_android_NativeBridge_configureProfileFreeze(nullptr,nullptr,0) != EBUSY || std::strcmp(std::getenv("S2A_W9_PROFILE_FREEZE"),"1")) return 3;
    if (Java_org_s2arm_android_NativeBridge_configureProfileFreeze(nullptr,nullptr,1) != EBUSY) return 4;
    std::puts("ANDROID_PROFILE_FLAG checks=4 host_created=false");
#else
    if (Java_org_s2arm_android_NativeBridge_configureProfileFreeze(nullptr,nullptr,0) != ENOSYS) return 5;
    if (Java_org_s2arm_android_NativeBridge_configureProfileFreeze(nullptr,nullptr,1) != ENOSYS) return 6;
    std::puts("ANDROID_PROFILE_FLAG checks=2 game_runtime_compiled=false");
#endif
}
"""
        cpp = out / "profile_flag.cpp"
        cpp.write_text(harness)
        for enabled in (False, True):
            target = out / ("profile-flag-game" if enabled else "profile-flag-diagnostic")
            run(["clang++", "-std=c++17", *(["-DS2A_ANDROID_GAME_RUNTIME"] if enabled else []), cpp, "-o", target])
            print(run([target]).stdout, end="")
        activity = (root / "android/app/src/main/java/org/s2arm/android/MainActivity.java").read_text()
        flag = activity.index('getBooleanExtra("s2arm.diag_profile_freeze", false)')
        assert flag < activity.index('NativeBridge.configureProfileFreeze(profileFreeze)') < activity.index('host = gameMode ? NativeBridge.createGame()')
        runtime = (root / "graphics/vulkan/runtime/AndroidVulkanRuntime.cs").read_text()
        assert runtime.index('GetEnvironmentVariable("S2A_W9_PROFILE_FREEZE") == "1"') < runtime.index('vulkan.S2AConfigureProgramProfileFreeze(')
        renderer_source = (root / "compat/tree/src/Ryujinx.Graphics.Vulkan/VulkanRenderer.cs").read_text()
        assert 'SetupContext(logLevel);\n            S2ASelectProgramProfile();' in renderer_source
        assert runtime.index('_renderer.Initialize(GraphicsDebugLevel.None);') < runtime.index('_device.Gpu.SetGpuThread();') < runtime.index('ExportProfileIfRequested();') < runtime.index('_device.Gpu.InitializeShaderCache(_cancel.Token);')
        print("PROFILE_ENTRY static_order_checks=4 android_activity_executed=false")

        if args.android_sdk:
            jar, aapt, javac = (java_tools[key] for key in ("android_jar", "aapt2", "javac"))
            java = out / "java"
            java.mkdir()
            manifest = (root / "android/app/src/main/AndroidManifest.xml").read_text()
            manifest = manifest.replace('xmlns:android=', 'package="org.s2arm.android" xmlns:android=', 1)
            manifest = manifest.replace('${appLabel}', 'Profile CPU compile').replace('${screenOrientation}', 'landscape')
            (java / "AndroidManifest.xml").write_text(manifest)
            run([aapt, "compile", "--dir", root / "android/app/src/main/res", "-o", java / "resources.zip"])
            run([aapt, "link", "-I", jar, "--manifest", java / "AndroidManifest.xml", "--java", java / "generated",
                 "-o", java / "resources.apk", java / "resources.zip"])
            sources = [*sorted((root / "android/app/src/main/java").rglob("*.java")),
                       *sorted((java / "generated").rglob("*.java"))]
            run([javac, "-encoding", "UTF-8", "-source", "17", "-target", "17", "-classpath", jar, "-d", java / "classes", *sources])
            report["android_java_compiled"] = True
            print("ANDROID_JAVA actual_sources_compiled=true activity_executed=false")

        if args.negative_controls:
            # Private source mirrors, no Git worktree/branch and no changes to checked-out sources.
            for name, path, before, after, assertion in (
                ("dynamic-options", "compat/tree/src/Ryujinx.Graphics.Gpu/Shader/ShaderCache.cs",
                 'if (selected != null)\n            {', 'if (false)\n            {',
                 'static language change after freeze cannot rewrite actual translated SPIR-V'),
                ("mutable-context", "compat/tree/src/Ryujinx.Graphics.Gpu/Shader/GpuAccessorBase.cs",
                 '_s2aProfile != null ? _s2aProfileProvider.FrozenTranslationCapabilities : context.Capabilities', 'context.Capabilities',
                 'old and newly created accessors ignore post-freeze context capability edits'),
            ):
                negative = PrivateBuild(root, out / name, run, [dotnet_root, package_root], (path, before, after))
                report["private_builds"][name] = negative.record
                negative_bin = negative.build(project)
                result = run(["dotnet", negative.executable(negative_bin), "selftest-profile-freeze", out / name / "consumer"],
                             cwd=negative.source, expected=1)
                require_negative(result, "FAIL profile-consumer: " + assertion)
                print("NEGATIVE_CONTROL " + name + " rejected_by_real_consumer=true")
        report["status"] = "cpu_consumers_pass"
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
