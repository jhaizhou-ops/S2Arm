# A-W12 first-slice host evidence

The first section is historical evidence for `a1cb154b`, before the metadata-boundary
correction. The final implementation is `d93399e09f45baa66c2996c2633ca39c1ffb7893`;
its independent clean-tree result is recorded at the end of this document. Do not use
the earlier 68-check receipt as the final 97-check result.

This is a codec/real-GAL-structure host result, not a connected renderer or GPU result.
Source base is `ce9db716c393d6a78ea0f6925415d7637dadc9d5`. Only this directory changed.
No Android/Docker/APK/Mesa build, ADB, external message, game input, key or save was used.

Executed on macOS ARM64 with already installed .NET SDK 10.0.401 and SPIRV-Tools v2026.4.
The installed SPIRV-Tools version banner reports an unknown tool source hash; it is not
presented as a verified compiler-source closure. The receipt records actual tool paths,
version banners, 35 compile/fixture/project input hashes, commands, stdout/stderr and exits.

Final command from the worktree root:

```sh
python3 graphics/vulkan/cache/tests/run_host.py --out /tmp/sgm-s2arm-w12-host-r6
```

The output path is a one-run local evidence location, not a program default. Reproduction
uses a different new private output directory as described in README.md.

Observed result:

- Three authored modules assembled and passed `spirv-val --target-env vulkan1.2`.
- Offline restore with package sources cleared; C# Release build: 0 warnings, 0 errors.
- 68 named host checks passed, including actual production metadata round trips and
  production-struct field drift assertions.
- Every truncated prefix of the compute envelope was rejected.
- 512 deterministic, rehashed payload mutation probes: 222 retained legal values exactly,
  290 rejected with RecipeException. Accepted arbitrary mutations are not claimed valid
  Vulkan programs; semantic SPIR-V and active pipeline legality remain outside the codec.
- `gpu_executed=false`, `production_loader_connected=false`.
- Receipt `result.json` SHA256:
  `feea19ad04cc855b2a23f91d5cb275f732dba2fda3172f11e85ad7d633f20018`.

A previous mutation run failed because a byte-backed ResourceStages cast silently dropped
high integer bits. The final version rejects the full integer before narrowing; an explicit
regression check now rejects that rehashed payload with LAYOUT. Earlier development receipts
are not substituted for this final result. A later host test edit briefly failed to compile
because of a local-name collision; that failure is preserved separately in the private run
outputs and is not counted as a passing test.

`dotnet format whitespace graphics/vulkan/cache --folder --verbosity quiet` ran only on this
owned directory. An initial invocation combining --folder with --no-restore was rejected by
the formatter CLI; it was corrected to folder-only mode, which does not load/restore a project.
No third-party source was formatted. Python runner syntax was compiled in memory.

Remaining gates: agreed unified W9 identity producer and known binding ABI mapping, real
program-artifact protocol, owner-reviewed GetBinary/LoadProgramBinary/specialization hooks,
actual normal Vulkan program/pipeline creation and authored GPU positive/negative oracles,
device/cache lifecycle and persistence, VTG/TF/helper support, layout preparation, gameplay
and cold/warm performance. No whole-project Android test.sh or Apple game gate was run in
this independently scoped slice.

## Metadata boundary correction after a1cb154b

The follow-up changes only this owned directory. The same public Encode/Decode seam links
the actual GAL definitions; it does not execute PipelineConverter, create Vulkan objects,
or claim device limits from host round trips.

The three relationships were checked against the locked production consumers/producers:

- `compat/tree/src/Ryujinx.Graphics.Vulkan/PipelineConverter.cs:225-245` reads active
  attributes, adds one to a non-zero BufferIndex and indexes `vbScalarSizes[bufferIndex-1]`.
  `PipelineBase.cs:1165-1189` also indexes the real buffer array with the raw index.
  `Ryujinx.Graphics.Gpu/Shader/ShaderCache.cs:298` declares the ordinary pipeline's full
  buffer span. The codec now rejects active non-zero indices outside its declared span;
  ignored IsZero indices and dormant attribute/buffer slots remain byte-preserved.
- `PipelineLayoutFactory.cs:53-58` allocates descriptor Count, whereas
  `ShaderCollection.cs:325-342` and `DescriptorSetTemplate.cs:74-80` derive updates from
  usage ArrayLength. A matching binding/type/stage mask alone does not prove capacity.
  The codec now also requires usage ArrayLength <= descriptor Count.
- `Ryujinx.Graphics.Gpu/Shader/GpuAccessor.cs:181-191` returns uniform-buffer byte size / 8;
  `Ryujinx.Graphics.Shader/Translation/Optimizations/BindlessToArray.cs:206-208` retains that
  length, and `ShaderInfoBuilder.cs:203-207,260-265` writes it into descriptor/usage metadata.
  A 64 KiB guest buffer yields an 8192-element array. These two scalar fields allocate no
  per-element codec storage. Positive signed-int extents are retained; selected-device
  limits remain a required later admission gate. Per-collection and total record budgets
  stay unchanged, and wire counts are still bounded before collection allocation.

Red command, with the original GalMetadata byte-for-byte unchanged from a1cb154b:

```sh
python3 graphics/vulkan/cache/tests/run_host.py --metadata-boundaries --out /tmp/sgm-s2arm-w12-metadata-red-r1
```

The host build succeeded and the test process exited 1: **25 cases, 10 passed, 15 failed**.
Both Encode and rehashed Decode accepted bad active indices and capacity mismatch;
8192/16384/int.MaxValue scalar extents were wrongly rejected. Receipt SHA256:
`ab8d3fa967a34cc6fb8db7638c89852c5e9c155f7b116ddaabca9704b6c80992`.
The receipt records original GalMetadata SHA256
`5b7b6919cf78eda4001b509eec014a06cd2fb794df569f0a6897425f313d5845`.

The identical 25 cases then passed after the three checks were corrected, before adding
four independent record-budget controls. Receipt `/tmp/sgm-s2arm-w12-metadata-green-r1/result.json`
SHA256: `51f3a93030f5cff4c81afe737c147d237e325b27420114eb7f57ade865cf7dd8`.

Full suite including those controls:

```sh
python3 graphics/vulkan/cache/tests/run_host.py --out /tmp/sgm-s2arm-w12-metadata-full-r1
```

Observed **97 host checks passed**, including **29 metadata boundary cases**; Release
build had zero warnings/errors, all three authored SPIR-V modules passed the existing
validator commands. Of the 512 deterministic rehashed mutation probes, 227 were retained
losslessly and 285 rejected with RecipeException. Receipt SHA256:
`ff4d8ac1198adaa4a784a3aa10337e088033a6f9f4cfeca88be2f6cae3277a70`.

No wire fields, envelope version, producer identity/key, runtime call site or GAL source
changed. Previously valid in-range encodings keep the same bytes; malformed metadata now
fails closed. No GPU, production loader, APK, Docker, ADB or gameplay gate was run.

For this correction, `git diff --check` and Python in-memory syntax checking passed.
The unified `tools/style.py` entry point was not run because its pinned Python dependencies
were not prepared. Per the task owner's instruction, no formatter was called directly and
no new tool environment was installed; existing local style was retained. Formatting is
voluntary at this repository stage and is not reported as a passing check here.

## Independent final verification at d93399e0

The final implementation was independently rerun from a clean worktree on macOS ARM64
using .NET SDK 10.0.401 and the existing SPIRV-Tools. All 36 source/fixture/project
input hashes matched the author run. Offline Release build reported zero warnings/errors.

- 97/97 host checks passed, including 29/29 metadata boundary cases.
- All three authored modules passed `spirv-as` and `spirv-val --target-env vulkan1.2`.
- Of 512 deterministic rehashed payload mutations, 227 re-encoded losslessly and 285
  were rejected with RecipeException; acceptance does not prove Vulkan legality.
- Independent receipt SHA-256:
  `8a1c8dcacd08b5cffd923c3c7c2e0ee6957bfc811fe940c79d839f9096140cf3`.

The receipt and logs are local evidence, not artifacts distributed by the repository.
Reproduce with the README command and a new private output directory. This documentation
and the Android CHANGELOG entry do not change any validated source or fixture input.
No GPU, production loader, Android APK, device or gameplay acceptance is implied.

## S1a/S1b production connection (2026-10-24)

The codec was promoted to the renderer while keeping the A-W12 evidence above as history.
This receipt is from a Linux host, not the macOS A-W12 machine:

- Base: `android/integration@c6cfcc04`.
- The production Vulkan project and the Android AOT project both build in Release.
- `CodecTests` source-links the production codec, profile, compile lane, driver-cache
  wrapper and failed-program placeholder, plus the real GAL types.
- 124 host checks pass, including 29/29 metadata boundaries.
- New checks cover: program-profile determinism, SPIR-V target rotation, translator-closure
  rotation, effective-capability rotation, complete `Capabilities` field coverage,
  compile-lane value/exception propagation, owner pump while busy, stop joining the
  in-flight call, queued-work cancellation and post-stop rejection, driver-cache
  wrapper/identity/UUID/backend/digest/embedded-header rejection, atomic replace and
  rebuildable miss.
- `gpu_executed=false`. No VkDevice, real pipeline, APK, Android device or game was run.
- The connected renderer path (`GetBinary`/`LoadProgramBinary`, host-file discriminator,
  single compile lane, driver cache load/save) is compiled but only CPU-tested here.

## S2 producer host result (2026-10-24)

One run, new private output directory, from the `android/shader-cache` worktree after the S2
producer slice:

```sh
python3 graphics/vulkan/cache/tests/run_host.py --out /tmp/sgm-s2arm-s2-host-r1
```

Observed: `status host_pass`, **152 host checks passed** (124 S1 checks + 28 S2 producer checks),
`METADATA_BOUNDARIES 29/29`, `gpu_executed=false`,
`production_loader_connected=false`. The new S2 checks cover:

- canonical profile payload round-trip, trailing-byte and truncation rejection;
- profile JSON identity recomputation, capability payload swapped under a foreign identity,
  Vulkan version mismatch, unknown schema/field, non-Vulkan capabilities and malformed
  translator closure;
- pack manifest round-trip (identity/files/counts/pack key), title/content/identity/
  translator-mismatch rejection, changed file digest, unlisted file, path traversal,
  duplicate file entry, symlinked pack entry, host-record count without a host file,
  unknown field and truncated JSON;
- pack layout (content root from `revisions/<contentRoot>`, pack/cache paths) and installer
  behaviour: first seed, same-pack no-op keeping runtime learning, re-seed after a missing
  file, payload swapped after manifest creation rejected with no cache left behind, symlink
  rejected at import with no cache left behind.

Not evidence for: `shbake bake --vulkan-profile` on a real extracted game (no game dump or
device-exported profile exists on this host, so the bake path is compiled but not executed),
Android pack mount/import (not implemented yet), driver-cache data in a package, or game
pixels. The device profile exporter requires a live VkDevice and was not exercised.

## S2 installer host result (2026-10-24)

One run after the mount/installer slice, new private output directory:

```sh
python3 graphics/vulkan/cache/tests/run_host.py --out /tmp/sgm-s2arm-s2b-host-r1
```

Observed `status host_pass`, **176 host checks passed** (124 S1 + 52 S2), 29/29 metadata
boundary cases, `gpu_executed=false`, `production_loader_connected=false`. The installer
checks copy a real pack through the production manifest/layout code and assert: first seed
writes every file plus the pack stamp; the same pack is a no-op that keeps a runtime-added
file; a cache missing a listed file is re-seeded; a payload swapped after manifest creation
is rejected with no cache directory left behind; a symlinked pack file is rejected at import
with no cache left behind; a leftover staging directory from a killed import is removed; archive extraction (profile tree, foreign profile, traversal entry); game content identity excludes `shaders/` rows and follows game content; layout derivation (content root from `revisions/<contentRoot>`,
pack path, lower-case cache path) and invalid key/title rejection.

Not evidence for: Android mount on a device, actual cache hit across processes, or game
pixels. The mount was not executed (no VkDevice / APK / game here); the profile export path
was also not executed.

## S2b backing control regression (2026-10-24)

The Android backing-control fixture compiles the actual `Ryujinx.Graphics.Gpu` sources and the
production `AndroidVulkanRuntime.cs` (including the new mount point) against a controlled
surface/platform. After linking the real `Ryujinx.Graphics.Vulkan` assembly and its managed
`Silk.NET.*` dependencies into the fixture's dependency directory:

```sh
python3 graphics/vulkan/runtime/control-tests/run.py   --dotnet $(command -v dotnet) --dependencies <built deps>   --gpu-source compat/tree/src/Ryujinx.Graphics.Gpu --output <new output>
```

Observed: **299 production Runtime backing handshake assertions** pass; the mount path is
inert (no game data directory) and does not disturb backing admission or retirement.
No GPU, Android page protection or native writer quiescence was exercised.
