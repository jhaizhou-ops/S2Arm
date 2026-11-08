# Android savecommit tests

## Current test layers (2026-10-30)

- The original native suites below remain unchanged and test production C primitives.
- [Managed CPU interop](managed/README.md) compiles the actual upstream interface,
  Android adapter and AOT module initializer; 64 real-native checks, 43 missing-binding
  checks and an effective missing-registration negative control.
- [APP-domain native harness](apk/README.md) contains source-only Instrumentation
  wrappers for the original two native suites. It is manual and never a device gate.
- NativeAOT target linking, APP-domain managed execution, the complete shared save
  transaction and game kill/reopen acceptance remain separate results. Do not infer
  them from CPU passes. Latest scope: [owner division](https://github.com/jhaizhou-ops/S2Arm/pull/1109#issuecomment-6527246048).

The following sections retain the original native-only snapshots and limitations;
counts and policies refer to their stated revisions, not all later layers.

## Native host tests

The two suites call all seven approved production C primitives from
`../../../native/s2a_savecommit.c`, plus the private fd-close helper.
They do **not** test a reimplementation. The first suite covers the six original
primitives; the second covers OpenRead and its ownership cleanup.
The expected file bytes, FNV-1a hashes,
metadata, token lengths, and errno rules are fixed independently of production output.

## Reproduce

From this directory, with Linux GCC 14 and libc headers already installed:

```sh
./run-native-host.sh
./run-openread-host.sh
./build/native_host_test "$PWD" fake-exchange  # must exit 1
./run-openread-host.sh fake-open-success      # must exit 1
```

The test executable creates a unique `native-fixture-XXXXXX` directory beneath the
absolute path passed as its first argument. It removes only that owned directory,
without following symlinks. Use this tests directory as the fixture parent.
Both runners compile with C11 and `-Wall -Wextra -Werror -Wpedantic`; the
six-primitives runner also uses pthreads. Set `CC` to the verified Linux compiler
path when it differs from the runners' `gcc-14` default. Negative-control exit 1
is expected and must not be reported as a positive gate pass.

## Scope and negative control

- Nested binary and empty-file clone; independent byte and per-file hash checks.
- Existing destination (including symlink) returns EEXIST and remains unchanged;
  overlap, source symlink, entry symlink, and FIFO are rejected.
- Zero FICLONE calls (including the legacy forced-unsupported trap), seven-byte
  writes, write EACCES/EPERM/EIO/ENOSPC cleanup, and original hash survival.
  File and directory mode bits and nanosecond mtime are preserved.
- Read-only subtree reaches final metadata then injected fsync EIO: only newly
  owned destination is removed; original data remains unchanged.
- Actual RENAME_EXCHANGE swaps different old/new bytes and hashes. Absent name
  returns ENOENT. Injected EXDEV, ENOSYS, EOPNOTSUPP propagate without fallback or
  tree mutation; **EXDEV injection is not a physical cross-filesystem test**.
- Token absent/zero/64-byte round trips, 65-byte EINVAL with old token unchanged,
  ERANGE actual length, directory-symlink rejection. Forced unsupported xattrs
  exercise committed fallback files, fallback cloning, and write-error preservation.
- SyncDirectory succeeds normally and rejects a symlink with a nonzero errno;
  no particular symlink errno is prescribed.
- 86 capability probes across serial calls and four distinct concurrent directories:
  PID/random prefix, unique names, and no residue; simulated unavailable exchange
  returns false with cleanup. Each worker performs 20 token/read/sync cycles.
- Negative control uses GNU ld wrapping to replace only the public exchange call
  with false success, with no swap. Unchanged expectations then fail on old/new
  content/hash assertions and error propagation. Production source is never edited.

Fault injection uses only test-side GNU ld `--wrap`; there are no production hooks.
The syscall wrapper explicitly accepts SYS_renameat2 only and aborts for any other
number rather than forwarding variadic arguments incorrectly.

## Evidence and limitations

`logs/baseline-missing-source.log` records the initial missing `.c` compile failure;
this is **absence evidence only, not a behavioral pre-fix regression proof**.
`logs/host-green.log`, `logs/negative-exchange.log`, and `logs/host-environment.log`
record the earlier six-primitives snapshot on Linux x86_64 overlayfs, GCC 14.2.0.
The current seven-primitives source is covered by
`logs/native-after-openread-green.log` and the OpenRead evidence listed below.
Logs and build outputs are local-only ignored artifacts, not PR attachments;
publish only sanitized summaries and the reproducible synthetic test sources.
`logs/sanitizer.log` preserves default LeakSanitizer failure under host ptrace;
`logs/asan-ubsan-no-leakcheck.log` runs ASAN/UBSAN with leak checking disabled.
No leak-check pass is claimed.

Host green is not Android NDK/arm64 compilation, ext4/f2fs power-loss durability,
physical cross-volume EXDEV, or full shared save-protocol recovery. Shared seam,
C# transaction state machine, Boot registration, and kill/reopen game-save device
acceptance are outside this native primitive test's scope. Target acceptance
belongs to Zhangbu (fallback n06ody) under the approved issue discussion.

### Recorded result (2026-10-30)

| Case | Expected → observed |
|---|---|
| Missing-source baseline | compile fails → exit 1 (absence only) |
| Existing nested destination on pre-fix source SHA256 prefix `cbd142f3` | EEXIST → EINVAL; 1/129 checks red |
| Initial native source SHA256 prefix `5a553ac0` (six-primitives suite rerun) | 0 failures → 129 checks, 0 failures |
| False-success/no-swap exchange negative control | red → 13/129 checks fail, exit 1 |
| ASAN + UBSAN, leak check disabled | 0 failures → 129 checks, 0 failures |
| Native reflink observation | 5 real ioctl attempts; last errno 95, copy fallback succeeds |
| Test fixture cleanup | zero owned fixture directories remain |

The nested-existing red is a genuine behavioral regression test, preserved in
`logs/nested-existing-red.log` and paired with its source hash. The change gives
preexistence EEXIST precedence over overlap rejection; no existing destination is
modified. Original baseline compile absence remains separately identified.

## Approved OpenRead extension (2026-10-30 09:27 UTC)

The additional seventh primitive is tested separately against the same production
source. Approval: [#1072 comment 6518511391](https://github.com/jhaizhou-ops/S2Arm/issues/1072#issuecomment-6518511391) and
[maintainer confirmation 6518522553](https://github.com/jhaizhou-ops/S2Arm/issues/1072#issuecomment-6518522553).
`open_read_host_test.c` verifies binary bytes through the returned caller-owned fd,
actual fstat regular-file type, read-only access, caller close invalidation, symlink
and trailing-slash-symlink rejection, directory/FIFO/missing/relative/null paths,
null output pointer rejection, and `out_fd == -1` on every failure. The private
adapter close helper also has success/closed-fd and invalid-fd EBADF checks.

```sh
./run-openread-host.sh
./run-openread-host.sh fake-open-success  # must exit 1
ASAN_OPTIONS=detect_leaks=0 SANITIZE=1 ./run-openread-host.sh
```

The FIFO has no writer. An open wrapper enforces `O_RDONLY | O_NOFOLLOW |
O_NONBLOCK` before forwarding calls. If an unsafe implementation omits a flag,
this guard refuses to execute a potentially blocking open **and** records an
explicit test failure; it cannot silently turn the unsafe implementation green.
Elapsed time is checked against a one-second host regression budget, not a product
latency guarantee. fstat EIO is injected after a real fd is acquired to exercise
cleanup. `/proc/self/fd` is counted before and after 64 repeated success/error
cycles (including 65 injected fstat failures), without any process enumeration,
signals, external timeout utility, or process-group operation.

| OpenRead result | Observed |
|---|---|
| Initial undefined-symbol link baseline | exit 1; absence evidence only |
| Strict host suite | 746 checks, 0 failures |
| FIFO rejection, no writer | 0.000009 seconds |
| Open fd count | 4 → 4 |
| False-success/no-fd negative control | 396 failures / 675 checks; exit 1 |
| ASAN/UBSAN (leak checking disabled) | 746 checks, 0 failures |
| Previous six-primitives suite rerun | 129 checks, 0 failures |

The negative control denominator differs because valid-descriptor-only assertions
are skipped when the deliberately broken implementation returns no fd. Failure
assertions still catch the invalid ownership result and false success for rejected
paths. No production source modifications or hooks are used.

Evidence: `logs/openread-{missing-symbol-red,green,negative,asan-ubsan}.log`,
`logs/native-after-openread-green.log`, and `logs/openread-source.sha256`.
The initial test-run source C SHA256 was
`5a553ac03c461865c403a6e5123852a373d0aa086c91ec3c8d0af1f6fc929573`,
header SHA256 is
`f9d587cb0f9bb0974676dd0ae9c7c8c2f973220bb2372bf1fff8c3ab2f4cadfd`.
Both remained unchanged across the test runs. Counts above are raw checks/assertions,
not independent test scenarios. All earlier target/device/shared protocol limitations
continue to apply; this is native host evidence only. That initial isolated draft did not run full-checkout checks. Subsequent integration
and the search-only-ancestor regression are recorded below; managed integration
and Boot registration remain pending.

## Main integration (native-only slice)

The Linux host CTest targets are registered in `android/CMakeLists.txt`:
`android_savecommit_host` and `android_savecommit_openread`. The existing
`android/linux_ctest.sh` route includes these through CTest (including
its Darwin-to-Linux-VM path). They are not registered as runnable Darwin tests.
Standalone runners return 75 with `ENV_NOT_READY` on non-Linux or a missing CC,
not a pass. No dependencies are downloaded by these tests.

```sh
cmake -S android -B /tmp/s2a-savecommit-build -DCMAKE_BUILD_TYPE=Debug
cmake --build /tmp/s2a-savecommit-build --target savecommit_host_test savecommit_openread_test --parallel 2
ctest --test-dir /tmp/s2a-savecommit-build -R '^android_savecommit_' --output-on-failure
```

At clean Git main baseline `841e26e313e0a61caba7da12fdc149b7e306842c`,
Linux x86_64 GCC 14.2.0 / CMake 3.31.6: configure, both targeted builds and
CTest exited 0 (2/2). The two executable negative controls exited 1 with
13/129 and 396/675 failing assertions respectively. The native source/header
hashes above remain unchanged from the earlier isolated host verification.
Full first-layer results belong in the PR summary after committing the changes;
these targeted results alone do not claim first-layer completion.
The full Android gate, Android cross-compilation/device and durability tests,
Darwin VM execution and managed integration remain unverified.

## Search-only ancestor regression (2026-10-30)

An owned `0100` ancestor containing accessible `0700` directories reproduces
Android-style search-without-listing permissions. The suite first requires an
actual `O_RDONLY|O_DIRECTORY` open to fail with EACCES; if elevated privileges
bypass DAC it returns 75 (`ENV_NOT_READY`), never a false pass. The observed host
was uid 1000 with no effective/permitted/bounding capabilities.

Before the fix, 22/177 assertions failed (exit 1), including successful clone and
exchange expectations returning EACCES. The fix opens ancestors with
`O_PATH|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC` for inode metadata only; actual source,
destination and final-component access policies are unchanged. After the fix:
177/177 host checks pass (exit 0); false-success exchange gives 47/177 failures
(exit 1); OpenRead remains 746/746 (exit 0). Tests cover same-inode `..` aliases,
both ancestor directions, existing destinations, final symlinks and repeated
failure-path fd cleanup. All prior assertions remain present.

Updated C SHA256:
`465526debca59e8b4d4e437d63e9cbd1f9a3f896e43f86d17c98723f44a1e9ee`.
NDK r29 API 29 ARM64 cross-compilation of both suites exited 0. This is not a
fixed-device pass: the original Y700 run also could not create FIFO fixtures
under its shell SELinux domain. Those assertions are unchanged; that independent
fixture precondition and device rerun remain outstanding. No SELinux or device
permission settings were changed.

## Explicit Android ordinary-copy policy (2026-10-30)

Per the owner contract at PR #1109 comment 6523526154, this Android native
implementation selects normal read/write copying, with no runtime reflink probe
and no permission-error fallback. The default platform policy is ordinary copy;
a managed capability field/Boot wiring belongs to the later adapter slice, not
a new shared API invented here. Apple clonefile behavior is unchanged.

The new policy regression on the preceding `9cab0695b` source failed 3/200
assertions (exit 1), observing 10 real FICLONE calls. Removing the optional probe
passes 200/200 (exit 0), with both real and injected reflink counts zero.
The error matrix injects EACCES, EPERM, EIO and ENOSPC on writes: each retains
its exact error, preserves original bytes/hash, removes only its new destination,
and leaves the fd count unchanged. Old copy, metadata, partial-write, rollback,
Exchange and search-only-ancestor tests remain. False-success Exchange fails
47/200 checks (exit 1); OpenRead still passes 746/746 on Linux.

C SHA256: `5482303f4c8ef5a348dc48b55a83f88c89742dff2d30949e9c6750a498c02d65`.
Header SHA256: `3806df50789f5fd28c5be58b14667f1869da53ccf514c69860674fb6f69a6f3b`.
This policy is not an APP-domain pass. Owner acceptance requires APP-domain
validation and the requested additional device/durability/game coverage; none
of those are claimed here. Shell-domain evidence is reference only. No SELinux,
permissions, domains or device state are modified by these host tests.
