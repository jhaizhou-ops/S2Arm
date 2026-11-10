# S2Arm evidence

[Back to README](../../README.md) · [简体中文](证据.md)

Every highlight on the README has a section here: what it claims, the number, how it is counted, and where the code lives. Every number carries its cut-off date.

## Native port

**Claim**: the game's ARM64 code is rewritten at build time and runs directly on the device's processor, with no CPU emulator; graphics calls are translated straight to Metal, and system services come from a native host.

**Code**:
- Rewriter: `runtime/rewriter/`, build entry `runtime/build.mk`
- Direct graphics layer: `graphics/nvn/`, shared graphics library `graphics/dsx/`; Metal backend: `graphics/metal/`; shader translator: `translator/`
- System services: `services/`

## One app, whole library

**Claim**: every game is imported into the same S2Arm app and chosen from its library; the whole library takes one App slot on your developer account.

**Code**:
- Shell build and cache: `pack/shell/` (see `pack/shell/README.md`)
- App bundle layout: `pack/APP_BUNDLE.md`
- iOS library UI and host bridge: `shell/`

## Graphical launchers

**Claim**: the Mac and Windows launchers handle import, build and install in a window; a welcome page reduces first-time setup to three steps (get this computer ready, add keys, add games); components are bundled or fetched in one click, with no command line; several games can queue up and build one after another.

**Code**:
- Mac launcher: `launchers/macos/`; bundled runtime (Python, .NET, shader tools and more): `launchers/macos/bundle_runtime.py`
- Windows launcher: `launchers/windows/launcher/`; ships the official Impactor and plumesign builds, SHA-256 checked at packaging time: `pack/jobs/impactor.py`, `launchers/windows/bundle_win.py`
- Job layer shared by both: `pack/jobs/main.py`

## AI at the wheel

**Claim**: the Mac and Windows launchers expose the `s2armctl` control interface; an AI can import, build, install and read progress and errors, with every step visible in the window; a self-check, self-fix and feedback toolkit comes with it; a full recording shows an AI diagnosing and fixing a real problem.

**Code**:
- Control client: `launchers/macos/s2armctl.py`, tests `launchers/macos/Tests/test_s2armctl.py`
- Operator manual for AI: `launchers/macos/skill/s2arm-operator/SKILL.md`. The AI advances with `s2armctl next`, follows the prescription for each error code (retry, rebuild in compatibility mode), and when it cannot fix the problem it creates a diagnostic bundle with `s2armctl diag export` / `diag pull` for the player to file with the problem-report template
- Developer diagnosis and root-fix skills: `skills/`
- Self-check and problem-report templates: `.github/ISSUE_TEMPLATE/`

**Recording**: an uncut session of an AI handling a real failure through `s2armctl`, from the error through diagnosis and fix to the game on screen, linked to the matching issue or commit.

## Tested at scale

**Claim**: 211 games surveyed with a 95% first-try build success rate; 4,700+ test runs on real iOS devices and 1,000+ on macOS.

| Item | Value | Method |
|---|---|---|
| Games surveyed | **211** | Games in the library with a formal survey or re-check verdict, one entry per game, latest verdict wins; experimental batches excluded |
| First-try build success | **196 / 205 = 95.6%** | Denominator = 211 minus 6: 4 with damaged game files, 2 that need another architecture (see [unsupported games](#unsupported-games)). "First try" means the first build passes the run check with no manual intervention, including maintainer hands-on confirmation. Counting the 2 Switch 2 games with build and in-game records gives 198 / 207 = 95.7%. Scoring rules: `tools/census/score.py`, `tools/census/hand_test_list.py` |
| iOS device runs | **4,704** | All test-run records from the first one (2026-10-19) to the cut-off date, one count per run, passes and failures alike. Runs that never reached the game (install, signing or transfer failures) are excluded |
| macOS runs | **1,022** | Survey runs that actually ran the game on a Mac, one count per game per batch, including formal and comparison batches |

Cut-off date: 2026-11-08.

## Speed and efficiency

**Claim**: cold builds on a MacBook Air take 6.4 minutes for Diablo III, 8.6 minutes for a 12 GB life-sim game and 34 minutes for a 17.5 GB open-world game; a Switch 2 game on an iPhone 17 Pro Max holds 60 fps while cool, 37–43 fps once hot, at about 0.15 J per frame.

### Cold build

| Game | Game files | Shaders | Import | Build | Total |
|---|---|---|---|---|---|
| Diablo III | 23.49 GB | 1,222 | 11 s | 371 s | **382 s (6.4 min)** |
| Life-sim game (program ID 01006F8002326000) | 11.97 GB | 9,315 | 6 s | 511 s | **517 s (8.6 min)** |
| Open-world game (program ID 0100F2C0115B6000) | 17.48 GB | 26,999 | 8 s | 2032 s | **2040 s (34 min)** |

**Method**: MacBook Air (M3, 16 GB), 2026-11-08. A fresh library, an empty work area and no caches. Timing starts at importing the game and ends when the app and resource pack are done, excluding install. Measured through the launcher's normal job flow on a dedicated machine, one game at a time. Build time depends mainly on shader count, not game size.

### Frame rate and energy per frame

A Switch 2 game, iPhone 17 Pro Max, 2026-11-07.

| Phone state | Frame rate |
|---|---|
| Cool | **60.0 fps** |
| Lightly warm | 48.7 fps |
| Hot under sustained load | 37.4 fps |

Over the same 240-second measurement window: **43.3 fps** on average, 6.63 W for the whole device, **0.153 J per frame**.

**Method**:
- Energy per frame = whole-device power ÷ frame rate.
- Only release-configuration measurements count: anything taken with diagnostic probes, frame recording or profiling enabled is excluded.
- Phone state is the system-reported thermal state, segmented in 300-frame windows.

## Platforms

**Claim**: iPhone / iPad from iOS / iPadOS 18; Mac on Apple silicon from macOS 15, building and playing locally; Windows builds and installs for iPhone / iPad; Android / HarmonyOS coming soon.

**Code**:
- Minimum OS: `MACOSX_DEPLOYMENT_TARGET=15.0` and `IPHONEOS_DEPLOYMENT_TARGET=18.0` in `tools/toolchain.env`, read by the host, codec libraries, Metal renderer and offline shader libraries; the iOS library UI `shell/Package.swift` also targets iOS 18
- Mac launcher: `launchers/macos/Package.swift`
- Windows launcher: `launchers/windows/launcher/`
- Android: `android/`

## Unsupported games

**Claim**: S2Arm runs 64-bit (AArch64) games; 32-bit games and games that need a 36-bit address space are not supported.

**Why**: Apple silicon has no 32-bit ARM execution state. S2Arm runs game code natively, so 32-bit games would need a separate ahead-of-time 32-to-64-bit translator and a matching system-service layer, which is not on the current roadmap.

| Game | Version | Reason |
|---|---|---|
| Ni no Kuni: Wrath of the White Witch | 1.0.2 | 32-bit |
| Goat Simulator | 1.0.0 | 32-bit |
| A side-scrolling action game | 1.0.0 | 32-bit |
| Monster Hunter XX (Nintendo Switch Ver.) | 1.5.0 | 32-bit |
| Minecraft: Story Mode | — | Needs a 36-bit address space |

**Method**: each game's main executable (NSO) is read to confirm its instruction set; the executable actually read is authoritative. A puzzle game is 64-bit after update 1.1.0 and passed the survey, so it is not listed. Newly found unsupported games are added here with their version.
