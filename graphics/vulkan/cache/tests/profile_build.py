"""Private, observed builds for the profile CPU runner; no production project edits."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


SCOPES = ("compat/tree", "graphics/vulkan/cache", "graphics/vulkan/core", "graphics/vulkan/wsi", "graphics/tools/shbake", "graphics/metal/cs/caps", "graphics/widen/shader")
IGNORED = {"bin", "obj", "build", ".git", "__pycache__"}
OUTPUT_PROPERTIES = ("TargetPath", "TargetDir", "TargetRefPath", "OutDir", "OutputPath", "BaseOutputPath",
    "IntermediateOutputPath", "BaseIntermediateOutputPath", "MSBuildProjectExtensionsPath", "RestoreOutputPath", "ArtifactsPath",
    "ArtifactsBinOutputPath", "ArtifactsObjOutputPath", "ArtifactsPublishOutputPath", "PackageOutputPath",
    "PublishDir", "DocumentationFile", "CompilerGeneratedFilesOutputPath", "GeneratedAssemblyInfoFile",
    "GeneratedGlobalUsingsFile", "IntermediateRefAssembly")
# These inherited properties can bypass the explicit private paths or inject another
# output configuration. Fail before invoking MSBuild rather than cleaning user outputs.
OUTPUT_ENV = {name.casefold() for name in (*OUTPUT_PROPERTIES, "PublishUrl", "UseArtifactsOutput",
    "DirectoryBuildPropsPath", "DirectoryBuildTargetsPath", "CustomBeforeMicrosoftCommonTargets",
    "CustomAfterMicrosoftCommonTargets")}
OBSERVER = """<Project>
  <Target Name="S2AObserveProfileCompile" BeforeTargets="CoreCompile">
    <ItemGroup><_S2AProfileImport Include="$(MSBuildAllProjects)" /></ItemGroup>
    <WriteLinesToFile File="$(S2AProfileInputs)/$(MSBuildProjectName).items" Overwrite="true" Encoding="UTF-8"
      Lines="Project|$(MSBuildProjectFullPath);Assembly|$(AssemblyName);TargetPath|$(TargetPath);Configuration|$(Configuration);TargetFramework|$(TargetFramework);OutDir|$(OutDir);RyuGpu|$(RyuGpu);@(Compile->'Compile|%(FullPath)');@(ReferencePathWithRefAssemblies->'CscReference|%(FullPath)|%(ReferenceSourceTarget)|%(MSBuildSourceProjectFile)');@(ProjectReference->'ProjectReference|%(FullPath)');@(_S2AProfileImport->'Import|%(FullPath)');@(Analyzer->'Analyzer|%(FullPath)');@(AdditionalFiles->'AdditionalFile|%(FullPath)')" />
  </Target>
</Project>
"""


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def files(root):
    result = {}
    for directory, names, leaves in os.walk(root):
        names[:] = sorted(n for n in names if n not in IGNORED)
        for name in [*names, *leaves]:
            if (Path(directory) / name).is_symlink():
                raise RuntimeError("Source mirror rejects symlinks: " + str(Path(directory) / name))
        for name in sorted(leaves):
            path = Path(directory) / name
            result[path.relative_to(root).as_posix()] = digest(path)
    return result


def copy_source(root, destination):
    if destination.exists():
        raise RuntimeError("Source mirror already exists: " + str(destination))
    for relative in SCOPES:
        shutil.copytree(root / relative, destination / relative,
                        ignore=shutil.ignore_patterns(*IGNORED), symlinks=True)
    # This root response file disables node reuse. It was missing from the old mirror.
    shutil.copyfile(root / "Directory.Build.rsp", destination / "Directory.Build.rsp")
    return files(destination)


def preflight_java(sdk, javac=None):
    sdk = Path(sdk).resolve()
    jar, aapt = sdk / "platforms/android-36/android.jar", sdk / "build-tools/36.0.0/aapt2"
    if not jar.is_file() or not aapt.is_file():
        raise RuntimeError("Android preflight requires installed platform android-36 and build-tools 36.0.0: " + str(sdk))
    selected = javac or shutil.which("javac")
    if not selected:
        raise RuntimeError("Android preflight: javac is missing from PATH; select an installed JDK >=17 before running")
    selected = str(Path(selected).resolve())
    try:
        probe = subprocess.run([selected, "-version"], text=True, capture_output=True)
    except OSError as error:
        raise RuntimeError("Android preflight cannot execute javac " + selected + ": " + str(error)) from error
    version = (probe.stdout + "\n" + probe.stderr).strip()
    match = re.search(r"(?m)^javac\s+(?:1\.)?(\d+)(?:[.\s+\-]|$)", version)
    if probe.returncode or not match or int(match.group(1)) < 17:
        raise RuntimeError(f"Android preflight requires javac >=17; selected {selected}; exit={probe.returncode}; version={version!r}")
    return {"javac": selected, "version": version, "major": int(match.group(1)), "android_jar": str(jar), "aapt2": str(aapt)}


def discover_dotnet_sdk(executable, run):
    reject_output_overrides()
    launcher = Path(executable).absolute()
    version = run([launcher, "--version"]).stdout.strip()
    listing = run([launcher, "--list-sdks"]).stdout
    roots = set()
    for line in listing.splitlines():
        match = re.fullmatch(r"(\S+)\s+\[(.+)\]\s*", line)
        if match and match.group(1) == version and Path(match.group(2)).is_absolute():
            roots.add(Path(match.group(2)).resolve())
    if len(roots) != 1:
        raise RuntimeError(f"Cannot identify one selected .NET SDK from {launcher}: version={version!r}; --list-sdks={listing!r}")
    sdk_base = roots.pop()
    sdk = sdk_base / version
    root = sdk_base.parent
    if (sdk_base.name != "sdk" or not sdk.is_dir() or sdk.resolve().parent != sdk_base
            or not (sdk / "MSBuild.dll").is_file() or not (root / "packs").is_dir()):
        raise RuntimeError("Cannot verify selected .NET SDK directory and packs root: " + str(sdk))
    return {"launcher": str(launcher), "resolved_launcher": str(launcher.resolve()),
            "launcher_sha256": digest(launcher), "sdk_version": version,
            "sdk_directory": str(sdk), "sdk_root": str(root)}


def require_negative(result, expected):
    if result.returncode == 0 or expected not in result.stdout + result.stderr:
        raise RuntimeError("Negative control did not fail at its required consumer assertion: " + expected)


def under(path, root):
    return path == root or path.is_relative_to(root)


def reject_output_overrides(environment=None):
    environment = os.environ if environment is None else environment
    rejected = sorted(name for name, value in environment.items() if value and name.casefold() in OUTPUT_ENV)
    if rejected:
        raise RuntimeError("Inherited MSBuild output/config overrides are not allowed: " + ", ".join(rejected) +
                           "; unset them before this private build")


def private_output(value, workspace, project, name):
    if not value or any(token in value for token in ("$(", "@(", ";", "|", "\n", "\r")):
        raise RuntimeError("Missing or unresolved private output " + name + ": " + repr(value))
    path = Path(value)
    if not path.is_absolute():
        path = Path(project).parent / path
    path = path.resolve()
    if not under(path, Path(workspace).resolve()):
        raise RuntimeError("Output escapes private workspace: " + name + "=" + str(path))
    return path


def check_outputs(properties, workspace, project):
    private_output(properties.get("TargetPath"), workspace, project, "TargetPath")
    for name in OUTPUT_PROPERTIES:
        if properties.get(name):
            private_output(properties[name], workspace, project, name)


def audit_inputs(source, workspace, seal, inputs, dependency_roots):
    source, workspace = source.resolve(), workspace.resolve()
    dependency_roots = [Path(p).resolve() for p in dependency_roots]
    receipts = []
    for path in sorted(inputs.glob("*.items")):
        properties, observed = {}, []
        for line in path.read_text(encoding="utf-8-sig").splitlines():
            if not line:
                continue
            parts = line.split("|")
            if parts[0] in {"Project", "Assembly", "TargetPath", "Configuration", "TargetFramework", "OutDir", "RyuGpu"}:
                properties[parts[0]] = parts[1]
            else:
                observed.append(parts)
        if not under(Path(properties["Project"]).resolve(), source):
            raise RuntimeError("Observed project escapes source mirror: " + properties["Project"])
        check_outputs(properties, workspace, properties["Project"])
        if properties["Configuration"] != "Release":
            raise RuntimeError("Observed project did not compile Release: " + properties["Project"])
        receipts.append({"project": properties, "inputs": observed})
    if not receipts:
        raise RuntimeError("No CoreCompile input receipts were produced")
    assemblies = {item["project"]["Assembly"] + ".dll" for item in receipts}
    for receipt in receipts:
        checked = []
        for item in receipt["inputs"]:
            kind, name = item[:2]
            path = Path(name).resolve()
            relative = path.relative_to(source).as_posix() if under(path, source) else None
            if relative in seal:
                if digest(path) != seal[relative]:
                    raise RuntimeError("Compiled source/config changed after selection: " + str(path))
                classification = "selected-source"
            elif kind == "Compile":
                if not under(path, workspace / "art"):
                    raise RuntimeError("Unselected authored Compile input: " + str(path))
                classification = "private-generated"
            elif kind == "ProjectReference":
                raise RuntimeError("ProjectReference escapes selected source: " + str(path))
            elif under(path, workspace):
                classification = "private-generated"
            elif any(under(path, root) for root in dependency_roots):
                classification = "sdk-or-package"
            else:
                raise RuntimeError("Compiler input escapes private build/SDK/package roots: " + str(path))
            if kind == "CscReference" and (path.name in assemblies or (len(item) > 2 and item[2] == "ProjectReference")):
                if not under(path, workspace):
                    raise RuntimeError("Production assembly was not rebuilt in this private workspace: " + str(path))
            checked.append({"kind": kind, "path": str(path), "sha256": digest(path),
                            "classification": classification, "metadata": item[2:]})
        receipt["inputs"] = checked
    memory = [r for r in receipts if r["project"]["Assembly"] == "Ryujinx.Memory"]
    gpu = [r for r in receipts if r["project"]["Assembly"] == "Ryujinx.Graphics.Gpu"]
    if not memory or not gpu:
        raise RuntimeError("Actual Memory/GPU CoreCompile inputs are missing")
    memory_compile = {Path(i["path"]).name for r in memory for i in r["inputs"] if i["kind"] == "Compile"}
    if not {"MultiRange.cs", "INonOverlappingRange.cs"}.issubset(memory_compile):
        raise RuntimeError("Actual Memory compilation omits required range sources")
    if not any(Path(i["path"]).name == "Ryujinx.Memory.dll" for r in gpu for i in r["inputs"] if i["kind"] == "CscReference"):
        raise RuntimeError("GPU Csc did not receive the observed Memory reference assembly")
    if files(source) != seal:
        raise RuntimeError("Private source/config changed during build")
    return receipts


class PrivateBuild:
    def __init__(self, root, workspace, run, dependency_roots, mutation=None):
        reject_output_overrides()
        self.workspace = workspace.resolve()
        self.source = self.workspace / "source"
        self.run = run
        self.dependency_roots = dependency_roots
        original = copy_source(root, self.source)
        if mutation:
            name, before, after = mutation
            target = self.source / name
            content = target.read_text()
            if content.count(before) != 1:
                raise RuntimeError("Negative control no longer matches production source: " + name)
            target.write_text(content.replace(before, after))
        self.seal = files(self.source)
        changed = [name for name in original if original[name] != self.seal[name]]
        if changed != ([mutation[0]] if mutation else []):
            raise RuntimeError("Unexpected source mirror mutations: " + repr(changed))
        self.record = {"source_sha256": self.seal, "mutated_sources": changed, "builds": []}
        self.inputs = self.workspace / "inputs"
        self.inputs.mkdir()
        observer = self.workspace / "observe.targets"
        observer.write_text(OBSERVER)
        self.record["observer_sha256"] = digest(observer)
        self.properties = ["-p:Configuration=Release", "-p:UseArtifactsOutput=true",
            "-p:ArtifactsPath=" + str(self.workspace / "art"),
            "-p:RyuGpu=" + str(self.source / "compat/tree"),
            "-p:CustomBeforeMicrosoftCommonTargets=" + str(observer),
            "-p:S2AProfileInputs=" + str(self.inputs), "-p:UseSharedCompilation=false", "-p:NuGetAudit=false"]

    def preflight(self, project):
        # Evaluation only: inspect each selected project before restore/build can write.
        pending, seen, result = [self.source / project], set(), []
        while pending:
            path = pending.pop().resolve()
            relative = path.relative_to(self.source).as_posix() if under(path, self.source) else None
            if relative not in self.seal or digest(path) != self.seal[relative]:
                raise RuntimeError("Preflight project is not selected source: " + str(path))
            if path in seen:
                continue
            seen.add(path)
            evaluated = self.run(["dotnet", "msbuild", path, *self.properties, "-m:1", "-nr:false",
                "-getProperty:" + ",".join(OUTPUT_PROPERTIES), "-getItem:ProjectReference"], cwd=self.source)
            data = json.loads(evaluated.stdout)
            check_outputs(data["Properties"], self.workspace, path)
            result.append({"project": str(path), "outputs": data["Properties"]})
            pending.extend(Path(item["FullPath"]) for item in data.get("Items", {}).get("ProjectReference", []))
        return result

    def executable(self, value):
        path = private_output(str(value), self.workspace, self.source / "entry.csproj", "TargetPath")
        if not path.is_file():
            raise RuntimeError("Private build target is missing: " + str(path))
        return path

    def build(self, project):
        reject_output_overrides()
        preflight = self.preflight(project)
        path = self.source / project
        self.run(["dotnet", "restore", path, "--configfile", self.source / "graphics/vulkan/cache/tests/NuGet.Config",
                  "--disable-parallel", *self.properties, "-m:1", "-nr:false"], cwd=self.source)
        self.run(["dotnet", "build", path, "--no-restore", *self.properties, "-m:1", "-nr:false",
                  "-bl:" + str(self.workspace / (path.stem + ".binlog"))], cwd=self.source)
        if digest(self.workspace / "observe.targets") != self.record["observer_sha256"]:
            raise RuntimeError("Compiler observation target changed during build")
        observed = audit_inputs(self.source, self.workspace, self.seal, self.inputs, self.dependency_roots)
        self.record["builds"].append({"project": project, "preflight": preflight, "observed": observed})
        target = next(item["project"]["TargetPath"] for item in observed
                      if Path(item["project"]["Project"]).resolve() == path.resolve())
        return self.executable(target)
