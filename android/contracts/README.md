# Android A0 contracts (v1)

This directory is the machine-readable side of Android A0. It is the handoff
between the import/packaging side and the runtime side; it does not describe an
implementation.

## Flow

```text
NSP/XCI
  -> inspect / resolve        -> game-input-manifest.v1.json
  -> build / pack             -> game-build-artifact.v1.json + package
  -> install                  -> files/games/<titleId>/revisions/<contentRoot>/
                                 files/games/<titleId>/current.json
  -> Android shell            -> boot-spec.v1.json (session config)
  -> native loader            -> load modules, ReadyToPlay, run guest
```

`current.json` is the only activation pointer. The runtime never scans
`revisions/`, never parses `control.nacp` to find modules, and never guesses a
path outside the artifact.

## Files

| File | Producer | Consumer |
|---|---|---|
| `game-input-manifest.v1.schema.json` | `A4 inspect/resolve` | `A4 build/pack`, build report |
| `game-build-artifact.v1.schema.json` | `A4 build/pack` | installer, runtime, support report |
| `current.v1.schema.json` | installer / activation | Android shell, runtime |
| `boot-spec.v1.schema.json` | Android shell | native loader, services |
| `run-manifest.v1.schema.json` | test harness / runner | report, support, CI |
| `job-request.v1.schema.json` | CLI / frontend | local job engine |
| `job-event.v1.schema.json` | local job engine | CLI / frontend |
| `samples/` | synthetic only | contract tests, docs |

## Invariants

1. **One activation pointer.** `current.json` lives at the game root and points
   to exactly one revision. It is written last, by `temp -> fsync -> rename`.
2. **No `boot.tsv`.** The boot index is `current.json` plus the artifact; do not
   add a second activation format.
3. **Relative paths only.** Every path in an artifact is relative to its
   declared root (the revision root, or `apk.assetRoot` for an `apk-asset`
   module), uses `/`, has no `.` / `..` component, and is not absolute.
4. **Title ID is identity.** `titleId` is 16 uppercase hex digits and must equal
   the directory name under `files/games/`.
5. **Content root is immutable.** `contentRoot` names a verified snapshot; the
   revision directory is `revisions/<contentRoot>`.
6. **Rewrite ABI is explicit.** The runtime rejects an artifact whose
   `rewriteAbi` it does not implement. The first Linux-safe Android ABI is
   `android-sp-safe-v1` (no live register below `sp`). The rewriter writes
   `# REWRITE_ABI<TAB>android-sp-safe-v1` in every module's `.fixups.tsv`; the
   importer copies that value into `game-build-artifact.json.rewriteAbi`.
7. **Input identity is bound when present.** `game-build-artifact.json.input`
   records the input manifest path/hash, its content root and titleId. A formal
   build sets it; the dev bridge may omit it. If present, the validator checks
   the hash and titleId, rejects duplicate module names, and requires exactly
   the same static module names and buildIds on both sides. An artifact module
   cannot omit its buildId to bypass this binding. `input.contentRoot` is the
   selected input RomFS root; `contentRoot` is the installed revision identity.
8. **Module source is explicit.** Each module has `source: "apk-asset"` or
   `source: "revision"`. A `revision` module is a file under the revision root
   (the development bridge uses this). An `apk-asset` module lives inside the
   per-game APK; its `apk.assetRoot` + module path is the asset location, and
   the artifact must carry the `apk` object (package name, versionCode, APK
   SHA-256, signing certificate SHA-256, asset root). The per-game package name
   is `org.s2arm.game.t<titleId lowercase>`, optionally followed by the fixed Debug test suffix `.w2` (no other suffix). The suffix never changes title/program/module identity. Schema acceptance is structural only: test import and execution additionally require this exact installed APK identity, its actual debuggable flag, and both unified DebugGate gates; release/default behavior is unchanged. `assetRoot`
   is `game/modules` for the per-game APK. `BootContract` checks the fields; on
   every launch the Android shell verifies only `packageName`, `versionCode` and
   the signing certificate (PackageManager `GET_SIGNING_CERTIFICATES`), not the
   whole APK hash. `apk.sha256` belongs to the A4 deployment transaction and
   export audit. The artifact lives in the revision, never inside the APK it
   hashes, so there is no self-reference. The shell/loader does not look for the
   modules under `revisions/`. For both sources, `image`, `fixups` and `gates` share one
   directory and module name: `path/main.patched.bin`, `path/main.fixups.tsv`,
   `path/main.gates.tsv`. The validator and runtime enforce these exact paths,
   since the current native loader derives sidecar paths from the image name.
   The loader maps only the artifact's listed images, never a directory scan.
9. **Import verifies bytes; runtime verifies the pointer.** The installer checks
   every package file's size and SHA-256. The runtime checks `current.json`, the
   artifact hash, the artifact's path rules and the rewrite ABI; it does not
   re-hash the whole package at every launch.
10. **Versioning.** A breaking field change bumps the file's `version` and adds a
    new schema; readers reject unknown versions. See the compatibility rules
    below before adding a field or an enum value.

## Extension and compatibility rules

All contract documents have optional top-level `extensions` and
`requiredFeatures`.
Omission means `{}` and `[]` respectively; existing v1 documents keep working.
This is part of the pre-release v1 baseline; readers predating this envelope
must be updated before producers emit nonempty `requiredFeatures`.
Core objects remain closed (`additionalProperties: false`) so misspelled or
unimplemented configuration does not silently become a default.

```json
{
  "extensions": {
    "org.s2arm.build": { "synthetic": true, "note": "local build" }
  },
  "requiredFeatures": []
}
```

- `extensions` maps namespaced names to JSON objects. Unknown entries are
  ignorable metadata; they must not override identity, paths, module selection,
  rewrite ABI, networking policy or other core semantics. A new reporting or
  support field can live here without changing the core schema.
- `requiredFeatures` lists unique namespaced capabilities. Every consumer must
  reject unsupported entries before consuming the document or mapping modules.
  This v1 implementation supports no additional required features yet; a new
  feature needs its schema, producer, consumer and rejection tests together.
  A syntax-only JSON Schema check is not capability negotiation.
- Names use lowercase dot-separated namespaces, for example
  `org.s2arm.gpu-profile.v1`. Extensions with incompatible payload meanings use
  a new namespaced identifier and, when required, a matching feature requirement.
- Adding a core optional field still requires coordinated schema/reader
  updates: old closed schemas reject it. Renaming fields, changing their type or
  meaning, adding required fields, changing identity rules, or adding a new
  execution/module-source enum value requires a new document version/schema.
  Do not use an ignored extension to introduce required execution behavior.

Module storage remains explicit through `modules[].source`; supporting a new
storage model requires a loader and a compatible contract update. Vulkan
profiles and deployment state should receive typed contracts when their owning
stages land, rather than becoming unchecked configuration inside `extensions`.

## Local job protocol v1

`job-request.v1.json` and `job-event.v1.json` describe the existing
`pack/jobs/main.py` entry point: a private, versioned JSON request and NDJSON
events. Core fields (`schema`, `taskId`/`jobId`, `operation`, `privateRoot`,
`seq`, `timestamp`, `type`, `state`) are stable; operation-specific request
fields and type-specific event payloads are allowed and are validated by the
operation. The protocol is local-only: the request file must be owned by the
user and private (0600), and there is no daemon or network endpoint.

`jobId` is an alias for `taskId`; if both are present they must match. The
sample cross-check in `validate.py` enforces that the first event belongs to the
request. `job_contract_test.py` covers missing/unknown operations, relative
private roots, unknown event types, bad sequence numbers and bad timestamps.

## Run manifest v1

`run-manifest.v1.json` is the per-run report header, not a build input. It binds
the app/artifact/input/module identity, device/driver/profile, session modes and
the evidence file paths (`device_caps.json`, `effective_profile.json`,
`host.log`, `lifecycle.jsonl`, `frames.tsv`, `compile_events.jsonl`,
`cache_report.json`, `memory.tsv`, `power.json`, `result.json`, `truth.tsv`,
`shots/`).

Required fields are deliberate: if one is missing, the run is **untested**, not
passed. `validate.py` also cross-checks the sample run against `current.json` /
`game-build-artifact.json` (artifact hash, title/content root, module names,
buildIds and sources). A run must not claim a different artifact or module set
than the one it was produced from.

## BootSpec Android injection

The Android shell supplies the session fields; the shared layer must not guess
them:

- `gameRoot`, `paths.userRoot`, `paths.saveRoot` and `paths.cacheRoot` are
  absolute paths from `Context` (`getFilesDir()` / `getCacheDir()`); multi-user
  storage (`/data/user/<n>`) and adoptable storage (`/mnt/expand/<uuid>/...`)
  are valid. `cacheRoot` is only the cache root; the backend derives
  `cache/shaders/<profileHash>` and `cache/gpu/<driverKey>/<profileHash>` after
  device creation.
- `user.language` is `LocaleList.getDefault().get(0).toLanguageTag()`.
  `user.region` is optional: an Android language may have an empty country; the
  shared layer derives a default from the language.
- `user.timezone` is a canonical IANA name after
  `android.icu.util.TimeZone.getCanonicalID`; fixed offsets become `Etc/GMT±N`
  or fall back to UTC with a diagnostic, and the name must exist in the
  system-data lock.
- `screen` is the game Surface's actual pixel size for this session (first
  version landscape), not the Display size; whether system bars/cutouts count is
  part of the §7.4 input mapping. `refreshHz` is `Display.getRefreshRate()`.
- `consoleMode` defaults to `handheld`, `network` to `offline`; the shell passes
  the actual values.

## Samples

`samples/` is a synthetic set with title ID `0100000000ABCDEF` and no game data.
It exists so both sides can test parsing and rejection without a real dump.

Run the schema and cross-file checks with:

```sh
python3 android/contracts/validate.py
```

`android/test.sh` runs the same check, so a contract change that breaks
the samples fails the normal host test gate. It also runs negative regressions
against both sample and `--game` validation, including input hash/title/module
binding, sidecar paths and extension compatibility.

## Content-addressed object store

An installed revision may keep file content in
`<gameRoot>/objects/<aa>/<sha256>` and expose it through **relative symlinks** at
the artifact paths. `BootContract.under()` resolves the symlink and accepts the
target only when it is exactly `objects/<two lowercase hex>/<64 lowercase hex>`
under the same game root; a link to anywhere else is still `escapes`. The
installer creates the symlinks, and the runtime/native loader follows them
(including `npdm`, `control`, `romfs` files and module images/sidecars).

## Development bridge

`android/tools/stage_a0.py` takes a package already produced by
`android/tools/make_pack.py` in a `games/<titleId>/` directory, copies
it (an independent copy, not a hard link) into `revisions/<contentRoot>/`,
writes `game-build-artifact.json`, then `current.json` last. It is a dev bridge
for exercising the runtime side before the real A4 import lands; it is not the
production installer.

`android/tests/stage_a0_test.sh` runs the whole path with a synthetic
package: make_pack -> rewriter -> stage_a0 -> schema validation -> BootContract.

## Not in A0 v1

- Per-device Vulkan profile and shader cache keys (A5)
- APK deployment transaction details (A4); the artifact records the APK identity
  and hash, not the install/rollback protocol
- Save-file format; saves follow LibHac semantics and live outside the revision
- NRO / dynamic module discovery beyond the static module list
