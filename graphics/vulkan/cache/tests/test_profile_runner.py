"""Runner protocol/containment tests; authored tool replies are not Java/GPU evidence."""
import json
from pathlib import Path
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from profile_build import (SCOPES, PrivateBuild, audit_inputs, check_outputs, copy_source, discover_dotnet_sdk, files, preflight_java,
                           private_output, reject_output_overrides, require_negative)


class ProfileRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sdk = self.root / "sdk"
        for rel in ("platforms/android-36/android.jar", "build-tools/36.0.0/aapt2"):
            path = self.sdk / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("authored SDK-path fixture")

    def tool(self, name, body):
        path = self.root / "tools" / name
        path.parent.mkdir(exist_ok=True)
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)
        return path

    def test_java_missing_has_actionable_error(self):
        with mock.patch("profile_build.shutil.which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "javac is missing.*JDK >=17"):
                preflight_java(self.sdk)

    def test_java_old_unknown_and_failed_version_rejected_with_actual_path(self):
        for version, code in (("javac 1.8.0_412", 0), ("unrecognized", 0), ("javac 17.0.9", 1)):
            with self.subTest(version=version, code=code):
                path = self.tool("javac", "printf '%s\\n' '" + version + "' >&2; exit " + str(code))
                with self.assertRaises(RuntimeError) as error:
                    preflight_java(self.sdk, str(path))
                self.assertIn(str(path), str(error.exception))
                self.assertIn(version, str(error.exception))
                self.assertIn("requires javac >=17", str(error.exception))

    def test_java_17_and_later_real_version_process_responses(self):
        for version, major in (("javac 17.0.9", 17), ("javac 21.0.4", 21)):
            path = self.tool("javac", "printf '%s\\n' '" + version + "'")
            result = preflight_java(self.sdk, str(path))
            self.assertEqual(result["major"], major)
            self.assertEqual(result["javac"], str(path.resolve()))

    def test_dotnet_bin_wrapper_uses_independent_sdk_without_source_or_assembly_admission(self):
        install = self.root / "actual-dotnet"
        sdk_base = install / "sdk"
        sdk = sdk_base / "10.0.401"
        sdk.mkdir(parents=True)
        (sdk / "MSBuild.dll").write_text("authored SDK layout fixture, not executable MSBuild")
        reference = install / "packs/ref/Microsoft.CSharp.dll"
        reference.parent.mkdir(parents=True)
        reference.write_text("authored framework reference fixture")
        host = install / "dotnet"
        host.write_text("#!/bin/sh\ncase \"$1\" in\n--version) printf '%s\\n' '10.0.401';;\n"
            "--list-sdks) printf '%s\\n' " + shlex.quote("10.0.401 [" + str(sdk_base) + "]") + ";;\n*) exit 98;;\nesac\n")
        host.chmod(0o755)
        launcher = self.root / "Cellar/dotnet/bin/dotnet"
        launcher.parent.mkdir(parents=True)
        launcher.write_text("#!/bin/sh\nexec " + shlex.quote(str(host)) + " \"$@\"\n")
        launcher.chmod(0o755)
        def run(argv):
            return subprocess.run(list(map(str, argv)), text=True, capture_output=True, check=True)
        selected = discover_dotnet_sdk(launcher, run)
        self.assertEqual(selected["launcher"], str(launcher))
        self.assertEqual(selected["sdk_root"], str(install.resolve()))
        self.assertNotEqual(selected["sdk_root"], str(launcher.parent))
        self.assertEqual(discover_dotnet_sdk(host, run)["sdk_root"], selected["sdk_root"])
        source, workspace, seal, inputs, rows = self.audit_fixture()
        (inputs / "gpu.items").write_text("\n".join(rows["gpu"] + [f"CscReference|{reference}||", f"Analyzer|{reference}"]) + "\n")
        audit_inputs(source, workspace, seal, inputs, [install])
        for kind, path, error in (("Compile", install / "External.cs", "Unselected authored Compile"),
                ("CscReference", install / "packs/ref/Ryujinx.Memory.dll", "not rebuilt in this private workspace"),
                ("CscReference", launcher.parent / "adjacent.dll", "escapes private build/SDK/package roots")):
            path.write_text("authored rejected input fixture")
            (inputs / "gpu.items").write_text("\n".join(rows["gpu"] + [f"{kind}|{path}"]) + "\n")
            with self.subTest(kind=kind, path=path), self.assertRaisesRegex(RuntimeError, error):
                audit_inputs(source, workspace, seal, inputs, [install])

    def test_dotnet_sdk_discovery_rejects_ambiguous_missing_or_unverified_roots(self):
        launcher = self.tool("dotnet", "exit 98")
        first, second = self.root / "first/sdk", self.root / "second/sdk"
        for listing, error in (("10.0.402 [" + str(first) + "]", "Cannot identify one selected"),
                ("10.0.401 [" + str(first) + "]\n10.0.401 [" + str(second) + "]", "Cannot identify one selected"),
                ("10.0.401 [relative/sdk]", "Cannot identify one selected"),
                ("10.0.401 [" + str(first) + "]", "Cannot verify selected")):
            def run(argv):
                text = "10.0.401\n" if argv[1] == "--version" else listing
                return subprocess.CompletedProcess(argv, 0, text, "")
            with self.subTest(listing=listing), self.assertRaisesRegex(RuntimeError, error):
                discover_dotnet_sdk(launcher, run)

    def test_old_javac_cli_stops_before_any_dotnet_process(self):
        marker = self.root / "dotnet-was-executed"
        for name in ("dotnet", "spirv-val", "clang++"):
            self.tool(name, "touch '" + str(marker) + "'; exit 97")
        self.tool("javac", "printf 'javac 1.8.0_412\\n' >&2")
        output = self.root / "output"
        env = {**os.environ, "PATH": str(self.root / "tools")}
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("run_profile_consumers.py")),
            "--out", str(output), "--android-sdk", str(self.sdk)], env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("javac >=17", result.stderr)
        self.assertFalse(marker.exists())
        report = json.loads((output / "result.json").read_text())
        self.assertEqual(report["commands"], [])
        self.assertEqual(report["status"], "failed")

    def test_existing_output_is_preserved(self):
        output = self.root / "existing"
        output.mkdir()
        keep = output / "keep"
        keep.write_text("keep")
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("run_profile_consumers.py")),
            "--out", str(output)], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(keep.read_text(), "keep")

    def test_negative_requires_the_specific_assertion_not_build_or_load_failure(self):
        expected = "FAIL profile-consumer: required assertion"
        require_negative(subprocess.CompletedProcess([], -6, "", expected), expected)
        for code, text in ((0, expected), (1, "CS0246"), (1, "Could not load assembly"),
                           (1, "FAIL profile-consumer: different assertion")):
            with self.subTest(text=text), self.assertRaises(RuntimeError):
                require_negative(subprocess.CompletedProcess([], code, "", text), expected)

    def test_mirror_preserves_root_response_file_and_rejects_reuse(self):
        root = self.root / "original"
        for relative in SCOPES:
            (root / relative).mkdir(parents=True, exist_ok=True)
        (root / "Directory.Build.rsp").write_text("-nodeReuse:false\n")
        destination = self.root / "mirror"
        manifest = copy_source(root, destination)
        self.assertEqual((destination / "Directory.Build.rsp").read_bytes(), (root / "Directory.Build.rsp").read_bytes())
        self.assertIn("Directory.Build.rsp", manifest)
        with self.assertRaises(RuntimeError):
            copy_source(root, destination)

    def audit_fixture(self):
        workspace = self.root / "private"
        source, inputs = workspace / "source", workspace / "inputs"
        inputs.mkdir(parents=True)
        for name in ("memory.csproj", "gpu.csproj", "MultiRange.cs", "INonOverlappingRange.cs", "gpu.cs"):
            path = source / name
            path.parent.mkdir(exist_ok=True)
            path.write_text("authored input " + name)
        generated = workspace / "art/generated.cs"
        generated.parent.mkdir()
        generated.write_text("generated fixture")
        reference = workspace / "art/Ryujinx.Memory.dll"
        reference.write_text("reference-path fixture, not an executable assembly")
        rows = {
            "memory": [f"Project|{source / 'memory.csproj'}", "Assembly|Ryujinx.Memory", "Configuration|Release", f"TargetPath|{reference}", f"OutDir|{reference.parent}/",
                f"Compile|{source / 'MultiRange.cs'}", f"Compile|{source / 'INonOverlappingRange.cs'}", f"Compile|{generated}"],
            "gpu": [f"Project|{source / 'gpu.csproj'}", "Assembly|Ryujinx.Graphics.Gpu", "Configuration|Release", f"TargetPath|{workspace / 'art/Ryujinx.Graphics.Gpu.dll'}", f"OutDir|{workspace / 'art'}/",
                f"Compile|{source / 'gpu.cs'}", f"CscReference|{reference}|ProjectReference|{source / 'memory.csproj'}"],
        }
        for name, lines in rows.items():
            (inputs / (name + ".items")).write_text("\n".join(lines) + "\n")
        return source, workspace, files(source), inputs, rows

    def test_actual_input_audit_accepts_private_generated_sources(self):
        source, workspace, seal, inputs, _ = self.audit_fixture()
        result = audit_inputs(source, workspace, seal, inputs, [])
        self.assertEqual(len(result), 2)
        self.assertTrue(any(i["classification"] == "private-generated" for r in result for i in r["inputs"]))

    def test_actual_input_audit_rejects_unselected_source(self):
        source, workspace, seal, inputs, rows = self.audit_fixture()
        injected = source / "extra.cs"
        injected.write_text("unselected")
        (inputs / "gpu.items").write_text("\n".join(rows["gpu"] + [f"Compile|{injected}"]) + "\n")
        with self.assertRaisesRegex(RuntimeError, "Unselected authored Compile"):
            audit_inputs(source, workspace, seal, inputs, [])

    def test_actual_input_audit_rejects_external_project_reference(self):
        source, workspace, seal, inputs, rows = self.audit_fixture()
        outside = self.root / "outside.csproj"
        outside.write_text("external")
        (inputs / "gpu.items").write_text("\n".join(rows["gpu"] + [f"ProjectReference|{outside}"]) + "\n")
        with self.assertRaisesRegex(RuntimeError, "ProjectReference escapes"):
            audit_inputs(source, workspace, seal, inputs, [])

    def test_actual_input_audit_rejects_production_dll_even_in_package_root(self):
        source, workspace, seal, inputs, rows = self.audit_fixture()
        package = self.root / "packages"
        package.mkdir()
        outside = package / "Ryujinx.Memory.dll"
        outside.write_text("stale production reference")
        rows["gpu"][-1] = f"CscReference|{outside}||"
        (inputs / "gpu.items").write_text("\n".join(rows["gpu"]) + "\n")
        with self.assertRaisesRegex(RuntimeError, "not rebuilt in this private workspace"):
            audit_inputs(source, workspace, seal, inputs, [package])

    def test_actual_input_audit_rejects_package_and_sdk_compile(self):
        source, workspace, seal, inputs, rows = self.audit_fixture()
        for name in ("packages", "sdk-cache"):
            dependency = self.root / name
            dependency.mkdir()
            injected = dependency / "ProfileFreezeSelfTest.cs"
            injected.write_text("class ExternalProductionSource {}")
            (inputs / "gpu.items").write_text("\n".join(rows["gpu"] + [f"Compile|{injected}"]) + "\n")
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, "Unselected authored Compile"):
                audit_inputs(source, workspace, seal, inputs, [dependency])

    def test_dependency_references_remain_allowed_without_source_admission(self):
        source, workspace, seal, inputs, rows = self.audit_fixture()
        dependency = self.root / "packages"
        dependency.mkdir()
        external = dependency / "Dependency.dll"
        external.write_text("dependency reference fixture")
        (inputs / "gpu.items").write_text("\n".join(rows["gpu"] + [f"CscReference|{external}||", f"Analyzer|{external}"]) + "\n")
        result = audit_inputs(source, workspace, seal, inputs, [dependency])
        self.assertTrue(any(i["classification"] == "sdk-or-package" for r in result for i in r["inputs"]))

    def test_audit_rejects_external_targetpath_and_outdir(self):
        source, workspace, seal, inputs, rows = self.audit_fixture()
        for name in ("TargetPath", "OutDir"):
            outside = self.root / "outside/S2A.SpecTest.dll"
            changed = rows["gpu"] + [f"{name}|{outside}"]
            (inputs / "gpu.items").write_text("\n".join(changed) + "\n")
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, "Output escapes private workspace"):
                audit_inputs(source, workspace, seal, inputs, [])

    def test_private_output_rejects_parent_and_symlink_escapes(self):
        workspace = self.root / "workspace"
        workspace.mkdir()
        project = workspace / "source/project.csproj"
        for value in (str(self.root / "outside.dll"), "../../outside.dll"):
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, "Output escapes"):
                private_output(value, workspace, project, "TargetPath")
        (workspace / "escaped.dll").symlink_to(self.root / "outside.dll")
        with self.assertRaisesRegex(RuntimeError, "Output escapes"):
            private_output(str(workspace / "escaped.dll"), workspace, project, "TargetPath")

    def test_output_environment_rejected_before_dotnet_or_external_writes(self):
        marker = self.root / "dotnet-executed"
        for name in ("dotnet", "spirv-val", "clang++"):
            self.tool(name, "printf executed > '" + str(marker) + "'; exit 97")
        outside = self.root / "outside-output"
        for index, key in enumerate(("OutDir", "outDIR", "OutputPath", "BaseOutputPath", "IntermediateOutputPath",
                    "MSBuildProjectExtensionsPath", "RestoreOutputPath", "restoreOUTPUTpath", "ArtifactsPath", "PublishDir", "TargetPath")):
            with self.subTest(key=key):
                reject = {key: str(outside)}
                with self.assertRaisesRegex(RuntimeError, "output/config overrides"):
                    reject_output_overrides(reject)
                output = self.root / ("case-" + str(index) + "-" + key)
                env = {**os.environ, "PATH": str(self.root / "tools"), **reject}
                result = subprocess.run([sys.executable, str(Path(__file__).with_name("run_profile_consumers.py")),
                    "--out", str(output)], env=env, text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(key, result.stderr)
                self.assertFalse(marker.exists())
                self.assertFalse(outside.exists())
                self.assertEqual(json.loads((output / "result.json").read_text())["commands"], [])

    def test_restore_output_defaults_and_private_paths_remain_allowed(self):
        workspace = self.root / "private"
        project = workspace / "source/fake.csproj"
        for value in ("", str(workspace / "art/obj/fake")):
            with self.subTest(value=value):
                check_outputs({"TargetPath": str(workspace / "art/bin/fake.dll"), "RestoreOutputPath": value},
                              workspace, project)

    def test_effective_output_preflight_rejects_before_restore_or_build(self):
        root = self.root / "original"
        for relative in SCOPES:
            (root / relative).mkdir(parents=True, exist_ok=True)
        (root / "Directory.Build.rsp").write_text("-nodeReuse:false\n")
        relative = "graphics/vulkan/cache/fake.csproj"
        (root / relative).write_text("<Project />")
        workspace = self.root / "private"
        outside = self.root / "outside-output"
        calls = []
        def evaluate_only(argv, **kwargs):
            calls.append(argv)
            self.assertEqual(argv[1], "msbuild")
            self.assertFalse(any(arg in ("restore", "build") for arg in argv))
            self.assertIn("RestoreOutputPath", next(arg for arg in argv if str(arg).startswith("-getProperty:")))
            properties = {"TargetPath": str(workspace / "art/bin/fake.dll"), name: str(outside)}
            data = {"Properties": properties,
                    "Items": {"ProjectReference": []}}
            return subprocess.CompletedProcess(argv, 0, json.dumps(data), "")
        builder = PrivateBuild(root, workspace, evaluate_only, [])
        for index, name in enumerate(("TargetPath", "OutDir", "RestoreOutputPath")):
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, "Output escapes private workspace"):
                builder.build(relative)
            self.assertEqual(len(calls), index + 1)
        self.assertFalse(outside.exists())
        with self.assertRaisesRegex(RuntimeError, "Output escapes"):
            builder.executable(outside / "fake.dll")

    def test_actual_input_audit_rejects_debug_and_missing_memory_sources(self):
        source, workspace, seal, inputs, rows = self.audit_fixture()
        (inputs / "gpu.items").write_text("\n".join(rows["gpu"]).replace("Configuration|Release", "Configuration|Debug"))
        with self.assertRaisesRegex(RuntimeError, "did not compile Release"):
            audit_inputs(source, workspace, seal, inputs, [])
        (inputs / "gpu.items").write_text("\n".join(rows["gpu"]))
        (inputs / "memory.items").write_text("\n".join(x for x in rows["memory"] if "MultiRange.cs" not in x))
        with self.assertRaisesRegex(RuntimeError, "omits required range sources"):
            audit_inputs(source, workspace, seal, inputs, [])


if __name__ == "__main__":
    unittest.main()
