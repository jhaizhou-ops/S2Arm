# Vulkan program binary, compile lane and driver pipeline cache

> 合流说明（2026-10-28）：本页说明与验证记录取 main；本线只有同一段落的旧版描述，已被 main 取代。本目录源码冲突已解；G1 的树侧适配见 [合并分析 §13.23](../../../android/docs/direct-main-merge-analysis-20261028.md)。原验证记录不代表本次候选重新通过。

This directory is the Android Vulkan backend's program-cache implementation. It started as
the isolated A-W12 codec draft (`ce9db716`) and is now connected to the production renderer
as the S1a/S1b slice:

- `ProgramBinaryCodec` / `ProgramBinaryMetadata` / `ProgramBinarySpirv`: **VKPB v1**, a
  bounded, versioned record holding completed SPIR-V stages, the complete GAL
  `ShaderInfo` (`ResourceLayout` descriptors/usages, optional `ProgramPipelineState`,
  `FragmentOutputMap`) and per-stage specialization maps.
- `ProgramBinaryProfile`: the Android Vulkan translation profile. It pins the backend,
  SPIR-V target, translator/codegen closure (assembly MVIDs) and every translation-affecting
  `Capabilities` field. The same token is added to the shared host-cache file name, so a
  profile change starts a new host file instead of appending to an unusable one.
- `CompileWorker`: one renderer-owned, serialized lane for `vkCreateShaderModule` and
  `vkCreate*Pipelines`. The owner waits through a bounded pump loop (WSI lease poll), never
  an unbounded `Task.Wait`; queued work is cancelled and the in-flight driver call is joined
  at renderer stop. A driver call that does not return keeps the device alive. The helper
  pipeline shares the main `VkPipelineCache`, so one cache file is saved rather than two
  independent caches overwriting each other.
- `PipelineCacheFile`: application wrapper around the driver's `VkPipelineCache` blob.
  It validates the application schema, vendor/device/raw driver version/API version,
  `pipelineCacheUUID`, the embedded `VkPipelineCacheHeaderVersionOne`, length and SHA-256.
  Save uses temp + atomic rename; a rejected file is a rebuildable miss.
- `FailedProgram`: a rejected record reports `ProgramLinkStatus.Failure` and
  `IProgramBinaryLoadFailure`. The lazy materializer checks that interface before wrapping
  the program, so the same lookup translates on demand instead of binding a placeholder
  that `SetProgram` cannot cast. It never fakes cache hits.
- `IHostProgramCachePolicy` (in GAL): the shared GPU cache uses it to disable the old
  "load, wait, dispose" host prefetch for this backend only. Apple's NxGal renderer does
  not implement it, so its prefetch behavior is unchanged.

## Production call boundary

```csharp
// Renderer-owned identity; callers never invent a profile or binding ABI.
ProgramBinaryIdentity identity = renderer.S2AProgramBinaryIdentity;
ProgramBinary recipe = ProgramBinaryCodec.Capture(identity, options, sources, info, specs);
byte[] binary = ProgramBinaryCodec.Encode(recipe);
ProgramBinary restored = ProgramBinaryCodec.Decode(binary, expectedIdentity);
```

`ShaderCollection.GetBinary` snapshots the `ShaderSource` bytes and GAL metadata at
creation time; it never reconstructs them from a `VkShaderModule`. GLSL-only sources and
minimal-layout/helper programs return `null` instead of writing empty bytes. Compute and
graphics programs (including the three parts of `S2AVtg` and vertex/geometry-as-compute)
use the same record. Transform-feedback and composite container layouts remain explicit
future versions; they are rejected, not silently degraded.

`VulkanRenderer.LoadProgramBinary` decodes the record, validates the caller's fragment flag
against the recorded stages, and reconstructs `ShaderCollection` from the record's own
`ShaderInfo`; the shared disk cache's empty `ShaderInfo` is not consumed. Decode failure
returns `FailedProgram`; OOM/device-loss/real Vulkan creation failures are not converted to
cache misses.

## Scope and exclusions

- VKPB is an application program record, not a `VkPipeline`, driver machine code or a
  portable Android GPU binary. Driver results are the separate pipeline cache above.
- The record does not contain Vk handles, native pointers, pool addresses, guest addresses
  or runtime hash codes. Resource descriptor `Count`/`ArrayLength` are scalar extents.
- The default v1 identity covers the Vulkan and Shader assemblies and effective GAL
  capabilities. The explicit opt-in v2 path below also freezes GPU-layer language/options
  and the registered storage-window decisions; existing guest/shared matching remains authoritative.
- This slice does not implement the Android side of offline packaging, full pipeline
  recipes/warm lists (S3), the device-level ready pool, or D0 identity/fact-variant mapping.
- Old host files for other profiles are left on disk; this slice starts a new file rather
  than reusing or repeatedly appending to a stale one.

## Offline package (S2 producer)

The producer side of S2 exists; the Android mount/import is not implemented yet.

- `VulkanProfile` (`VulkanProfile.cs`) is the explicit translation profile. The JSON carries
  the canonical capability payload (the exact bytes hashed into the profile key), the Vulkan
  target version and the two assembly ids of the translator closure. Parsing recomputes
  `ProgramBinaryProfile.Create` and rejects any file whose declared identity does not match
  the payload, so a hand-edited or stale profile cannot be used to translate programs.
- `VulkanRenderer.S2ASerializeProgramProfile()` exports that file from a real device when
  `S2A_SHADER_PROFILE_OUT=<directory>` is set on the Android runtime. A failed export is
  logged as 🔴 and does not change the game path; the file is not a capability guess.
- `shbake bake … --vulkan-profile <profile.json> --content-root <sha256-…>` translates with
  the profile capabilities (not Apple's `NxCaps`), writes VKPB host records under the same
  identity, validates every recorded SPIR-V with `spirv-val --target-env <profile env>` and
  writes `vulkan/generic/<profileKey>/{profile.json, manifest.json, shcache/<titleId>/}`.
  `GpuContext.S2AHostProgramCacheDiscriminator` is set from the identity so the offline host
  file names equal the ones the device reads.
- `ShaderPackManifest` (`ShaderPackManifest.cs`) is the single pack validator both sides use:
  schema/mode/backend, title id, A0 content root, VKPB identity, translator build identity,
  per-file size and SHA-256, and an exact file set (an unlisted file rejects the pack).
- VTG composite programs, transform feedback and the generated geometry passthrough stage
  are outside VKPB v1. They are counted as `unsupported`, logged 🔴, and left to on-demand
  translation; the guest/shared entry is still written. Encoding/metadata failures are
  `failed` and make the bake exit 1.
- Verification rejects symlinks in every path component, unlisted files, duplicate or
  inconsistent file/count records, and any identity/title/content/translator mismatch. It is
  a compatibility and integrity check, not an authenticity check: a pack that names the
  device identity is trusted like any local cache seed.
- `ShaderPackInstaller` seeds the runtime cache on the GPU thread after `Initialize` and
  before `InitializeShaderCache`. The pack directory comes from
  `<game>/shaders/vulkan/generic/<profileKey>` (or from the per-game APK's
  `assets/game/shaders.zip`, see below) and the cache directory from `AppDomain` data
  (`<games>/<title>/cache/shader`). The pack's content identity is the installed revision's
  `index.tsv` without the cache rows under `shaders/` (`ShaderPackLayout.GameContentRoot`),
  so shipping the pack inside the game package does not change the identity it claims while
  a game/content update still does; a producer computes the same value from the package's
  `index.tsv` before adding the pack. Every file is hashed while it is copied
  into a staging directory next to the cache; only a complete, digest-matching copy is
  renamed into place, so a swapped/truncated source never leaves a half-imported cache. A
  pack that is already seeded (same pack key, all files present at the recorded size) is left
  alone, keeping what the session learned. A different pack replaces the cache wholesale
  (program numbers from two generations are never mixed) and then re-learns on demand.
  Failures are logged as 🔴 and the game continues with on-demand translation; they never
  become a silent cache hit.
- For package delivery, build the pack from the package's `index.tsv` without shaders and
  attach it afterwards with `android/tools/attach_shaders.py <resource package>
  <per-profile pack dir>`; the tool keeps the game rows' order, appends the pack rows and
  rewrites the index/manifest/artifact consistently.
- A pack can also travel inside the per-game APK as `assets/game/shaders.zip` (layout
  `vulkan/generic/<profileKey>/`). The runtime copies the asset to private storage and
  `ShaderPackArchive` extracts it with the same bounded, traversal-free rules before the
  normal manifest verification; a missing asset is not an error, a corrupt one is 🔴.
- A pack must be produced by the same translator toolchain as the app build. A JIT runtime
  compares the `Ryujinx.Graphics.Shader` assembly MVID recorded by the producer. A NativeAOT
  runtime does not preserve that MVID, so it compares the profile's translator closure
  instead (the same semantic identity the direct package path uses); a different closure is
  still rejected as `PACK_TRANSLATOR`.
- Not implemented yet: driver-cache data in the pack, and S3 recipes/warm lists.

## Verification

```sh
python3 graphics/vulkan/cache/tests/run_host.py --out <new-private-host-output>
```

The host suite compiles the production codec and real GAL types, assembles/validates
authored SPIR-V, and covers VKPB round trips, every truncation prefix, rehashed metadata
mutations, pipeline/source field drift, the program profile field coverage, compile-lane
ordering/cancel/stop, driver-cache wrapper/atomic-replace negative cases, and the S2
profile/pack contract (168 checks total), including the pack installer. It does not create a VkDevice, execute a real
pipeline or prove game output; those remain separate GPU and device gates. Historical A-W12
receipts are in [VALIDATION.md](VALIDATION.md).

## W9 execution source and frozen v2 candidate (#431)

The new path is **off by default**. A per-game Android candidate enables it on a cold launch:

```sh
adb shell am start -S -n <application-id>/org.s2arm.android.MainActivity --ez s2arm.diag_profile_freeze true
```

Omit the extra or pass `false` for the existing path. `MainActivity` calls the JNI setter
before `createGame`; once a host exists the setter returns `EBUSY`, including a repeated
request. It sets `S2A_W9_PROFILE_FREEZE=0/1`; `AndroidVulkanRuntime.CreateRenderer` reads it
and configures the real renderer before `Initialize`. It is an explicit candidate switch,
not a persisted player setting. CPU checks do not authorize making it the default; device
A/B and Android-maintainer review remain required. No device command is run by the tests.

`Initialize` finishes `SetupContext` (including the optional SSBO recorder) and then publishes
one `ProgramBinaryProfileSnapshot` before `SetGpuThread`, export, package import or shader-cache
consumption. Profile identity, serialized export and the narrow GAL provider share the same
object. Preselection access and use after retirement fail explicitly. A rebuilt device uses
a new renderer/owner; an old accessor checks the provider object and cannot switch generations.
Owner tokens and retirement state are **in memory only**: equivalent devices/builds can still
reuse portable disk records. `MaximumGpuMemory` is read separately for runtime resource capacity
and never enters the canonical profile or overwrites selected translation facts.

`ComputeTranslationProfile` contains four fixed executable expressions: requested Vulkan
SPIR-V/GLSL language, ordinary-compute `DebugMode|Compute` flags, `!Enabled.robustBufferAccess`
for the host-window clamp, and clamp plus an actually created recorder for OOB recording.
The same expressions generate both the exported rule artifact and the values consumed by
`ShaderCache`, GPU accessors and the renderer capability producer. All valid combinations of
these inputs are covered by an independent truth table; impossible Enabled/Raw and recorder
combinations are rejected. Unknown or extra compute flags are rejected, never discarded.

The JSON keeps Raw robustness, Enabled robustness, requested language and recorder creation
separate from Effective decisions. Raw support is provenance, never a substitute for an enabled
feature. Other effective capabilities retain the existing producer; their complete Raw/Enabled
mapping and format-specific qualification are not claimed by this slice.

`computeProfile.executionRulesHash` locates the exact canonical executable expression artifact.
It is a new scoped domain (`s2a-compute-expressions-v1`), **not** the W9 draft's `rulesHash`,
normalization/hash algorithm, W9 `translationKey`, or an authenticated A0/run-manifest
`rulesVersion`. Unknown artifacts are rejected even after recomputing their hash and the VKPB
profile identity. No formal run-manifest is produced or certified here. The existing W9
codec pin, public keys and candidate-only contracts are unchanged.

V2 explicitly adds this artifact hash and effective selection to the capability profile key.
Pure build changes go separately into VKPB producer identity: actual Shader/Vulkan assembly
ids plus GPU and GAL/rule assembly ids. A changed GPU/rule producer does not invent a new
execution-rule hash. ShBake checks its actual GPU, GAL/rule **and Shader** assembly ids before
consuming v2; the renderer half of the existing closure is carried as an external source
reference and is not authenticated by ShBake. A matching hash is compatibility/integrity,
not proof of origin or a device feature grant.

`VulkanProfile.Create(...)`, the v1 canonical capability payload, identity algorithm and parser
remain available with their historical bytes. V2 is explicit (`s2a-vulkan-profile-v2`), selected
only by the opt-in runtime and consumed by `MakeContext(VulkanProfile)`. Switching versions starts
a different host profile; old records stay on disk and cannot be silently relabeled. The two
F1 capability flags and their optional-byte semantics from #427 remain intact.

ShBake's exact existing `MakeContext(Capabilities)` / `BakeRenderer.Create(Capabilities)` entry
points remain. V2 uses the provider for language, full selected translation capabilities,
resource layout and host file names; later edits to the context/global language input do not
rewrite them. Graphics keeps its existing offline host producer and flags, with the shared
language frozen too. Its exported coverage is explicitly `legacy-capability-only`; this is
not complete graphics, VTG/TF, format-matching, device admission, or same-session/PID export
certification. NativeAOT/device build identities must actually match the offline consumer;
a mismatch is rejected, not filled with a sample/version string.

```sh
# All dependencies are installed/prepared separately. Neither runner downloads anything.
python3 graphics/vulkan/cache/tests/run_host.py --out <new-directory-outside-checkout>
python3 graphics/vulkan/cache/tests/run_profile_consumers.py \
  --out <another-new-directory-outside-checkout> --negative-controls \
  --android-sdk <installed-android-sdk>
```

The second runner builds real ShBake/GPU/Vulkan projects using an empty NuGet source list,
runs actual translation/accessor/layout/host-name consumers and the existing Apple CPU VTG
suite, and validates the authored compute/fragment SPIR-V. Its renderer checks execute the
real profile commit, identity and export methods with captured CPU facts while deliberately
bypassing native device construction. The JNI setter is compiled from its production body
with a supplied host-exists state, in game-runtime and diagnostic build variants. Optional
Android SDK/JDK checks compile the actual Java sources/resources, without executing Activity.
Two private source mirrors restore the old dynamic-options/context behavior and must fail at
the intended consumer assertions. Receipts and source hashes are written to `result.json`.
These are CPU/source-consumer checks: no `VkDevice`, real pipeline, GPU/readback, Android APK,
Android session/game, Apple GPU/game, power or performance result is asserted.


## Private build receipts and Java preflight (#445)

`run_profile_consumers.py` now builds the positive case and both negative cases from separate,
new private source mirrors. Each mirror includes the renderer's source-linked core/WSI inputs
and the repository root `Directory.Build.rsp`. The source manifest is checked after compilation;
a negative case changes exactly its one intended GPU source, with the original C# assertions
preserved. Existing output directories are rejected.

Restore and build receive the same `Release`, selected private `RyuGpu`, artifacts path and
observation properties. Builds use one MSBuild node, disable node reuse/shared compilation,
and no longer override the whole graph with one `OutDir`. Ordinary project artifacts retain
per-project directories; the projects' existing fixed output paths stay inside the private
mirror. Production projects and the original checkout's build outputs are not edited or used
as substitutes for the private production assemblies.

Inherited MSBuild output/config overrides (including case variants of `OutDir`,
`OutputPath`, NuGet's `RestoreOutputPath`, intermediate/artifact paths and target paths) are rejected before any dotnet
process. Before restore, evaluation without a target recursively checks each selected
project reference and its effective output paths. Every output must resolve inside that
private workspace, including through symlinks. The compile receipt, build return and each
dotnet execution check the target path again; an existing target outside the workspace
cannot be selected as the executable.

A temporary read-only MSBuild target observes `CoreCompile`: actual `Compile`, Csc's
`ReferencePathWithRefAssemblies`, project references, imports, analyzers and additional files.
The receipt records resolved paths and content hashes. Selected authored inputs must match
the source manifest; other `Compile` inputs must stay in the private workspace's `art`
directory. SDK/NuGet roots allow dependency references/analyzers, never unselected authored
`Compile` inputs. Dependencies are recorded separately. Project references and production
assemblies outside the selected private build are rejected, including a production DLL
placed under an otherwise allowed package root. The GPU receipt must contain the private Memory reference assembly, and Memory's
actual compilation must include `MultiRange.cs` and `INonOverlappingRange.cs`.

The SDK dependency root comes from the selected launcher's actual `--version` and
`--list-sdks`, with one matching absolute SDK directory, its version's `MSBuild.dll` and
`packs` root verified on disk. Ambiguous, missing or unverifiable SDK locations fail; the
launcher directory is never a fallback dependency root. All dotnet commands use that same
selected launcher. Receipts record its selected/resolved path and hash separately from the
verified SDK directory/root, so a `bin/dotnet` wrapper can use an SDK in `libexec` without
admitting its whole installation prefix. SDK/NuGet authored Compile and external production
assembly rejection remain unchanged; an old receipt does not supply the allowed SDK root.

The original 145 CS0246 errors have **not been reproduced by the author** on the available
.NET 10.0.401 host. In the later [maintainer review](https://github.com/jhaizhou-ops/S2Arm/pull/474#issuecomment-6410187588),
the old `64ed1371` runner did reproduce 145 errors: the Memory ref contained the types,
but GPU's actual Csc references omitted `Ryujinx.Memory.dll`. This identifies a missing
reference in that old run; why upstream reference resolution omitted it remains unproved.
Neither shared `OutDir`, node reuse nor .NET version is established as its cause.
A distinct first attempt at a fully private positive renderer exposed one
CS2001: the old mirror scope omitted `DeviceFeatureSnapshot.cs`; core/WSI are now included.
These are separate findings. A build failure, missing tool, loader exception or a different
assertion never counts as a successful negative control. Each negative must fail at its
original specific profile-consumer assertion.

With `--android-sdk`, the runner resolves `javac` and executes `-version` before any dotnet
process or private build. Missing javac, an unrecognized response or a version below 17 fails
with the selected path/version and an actionable diagnostic. The same resolved executable
compiles the actual Java sources later; its real path and version are in `result.json`.
Dependencies are installed/prepared separately; there is no automatic installation or network
source. A missing Android36 platform/build-tools36 also fails in this preflight.

```sh
python3 -m unittest discover -s graphics/vulkan/cache/tests -p test_profile_runner.py -v
python3 graphics/vulkan/cache/tests/run_profile_consumers.py \
  --out <new-private-directory> --negative-controls --android-sdk <installed-sdk>
```

The lightweight tests include authored tool-version responses and containment fixtures;
they are not evidence of Java/GPU execution. The full runner's actual source/resource Java
compilation and CPU consumer/negative receipts remain distinct. No GPU, APK/NativeAOT,
device A/B or performance result is implied.

Integration revalidation on 2026-10-26 used clean merge `2a889670` with
`android/integration@f5bcb5ec` (macOS 14.8.5/arm64, .NET 10.0.401): 18/18 lightweight tests
and the complete 77-command runner passed, including consumer 14, renderer 14, Apple CPU VTG
28, JNI 6, four static order checks and both original assertion negatives. The current
21 authored Java files (including `RuntimeLibrary.java`) plus generated `R.java` compiled
with actual javac 17.0.21 and Android36 resources. The profile configuration still precedes
`createGame()`; the JNI setter body is unchanged by that upstream merge. Current Java,
resources, manifest, JNI and runtime order inputs were checked against the receipt commit;
16,321 recorded compiler input entries retained their hashes. This new receipt belongs to
that clean merge, while the earlier P2 receipt belongs to `a7fc083a` with the three dirty
Python fixes. Later documentation commits do not change either receipt's recorded HEAD.

A subsequent narrow check of `RestoreOutputPath` found that the earlier property list
omitted NuGet's restore metadata output: on `0a768ed0`, real offline restore wrote five
metadata files outside the private workspace. The list now includes this standard property,
so both inherited case variants fail before dotnet and an external project property fails
after real evaluation, before restore. The default no-package .NET 10 project still restored
successfully, with all five metadata files in private `art`; 19/19 lightweight tests and
52 evaluation-only project checks across the three existing private mirrors (four entry
points) passed. This follow-up did not rebuild or execute the full chain. Production C#,
project/config bytes and restore/build parameters still match the complete `2a889670`
receipt; only the observed output property list and its protocol regressions changed.

SDK discovery revalidation used the already installed official .NET 10.0.401 on
macOS 14.8.5/arm64. A Homebrew-shaped `Cellar/.../bin/dotnet` script set `DOTNET_ROOT` and
forwarded to `libexec`, which linked to that existing SDK; this was not an actual Homebrew
10.0.402 installation. The wrapper and direct official host each completed a separate
78-command full CPU/Java chain, with consumer 14, renderer 14, Apple CPU VTG 28, JNI 6,
four static order checks, two validated SPIR-V modules and both original assertion negatives.
Each run's 16,321 compiler input records retained their hashes, including legitimate SDK
framework references outside the wrapper's `bin`; Memory/GPU Compile remained 52+2/188+2
and the private Memory ref was present. All 21 lightweight tests passed, including a
wrapper-layout fixture and rejection of ambiguous/unverified SDKs, SDK authored source,
external production DLL and an adjacent non-SDK dependency. These new receipts record
`36989905` with three dirty Python fixes, not a later commit; earlier 74/77-command evidence
retains its separate maintainer/author ownership. No device, GPU, APK/NativeAOT or game ran.
