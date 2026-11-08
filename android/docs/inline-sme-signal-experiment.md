# Inline SME signal context experiment

Status: local opt-in candidate; not gameplay or performance acceptance.

Some Android ARM64 kernels include `TPIDR2_MAGIC` and header-only `ZA_MAGIC`
records in an otherwise ordinary data-abort signal frame. The existing strict
parser rejects unknown records and therefore rejects the ESR and real startup
fault probe before guest entry. A native 4 KiB Android 16 / Adreno 840 device
reproduced this with the unmodified integration source.

The experiment accepts exactly sized inline TPIDR2 and inactive ZA records and
preserves them in the existing complete ucontext save/restore. ZA vector length
and reserved fields are validated. Active ZA payloads, external context pointers,
unknown records, duplicates and malformed records remain failures. This is not
complete SME support and does not infer memory access direction without ESR.

The default is off. The Activity reads this Boolean extra only during creation:

```sh
adb -s <authorized-device> shell am start -W -n <game-package>/org.s2arm.android.MainActivity --ez s2arm.experimental_inline_sme_context true
```

Use a cold process for each comparison. Omitting the extra selects the existing
strict behavior. The process freezes the setting before fault thread setup;
later changes fail with EBUSY. Do not use Activity recreation to switch a live
session. Guest signal handlers, tracker/readback, scheduler and rendering remain
the existing providers; the startup probe is never bypassed.

Validation on the device used the same NDK 29 real signal fixture. The old
binary and the new binary with the experiment off both exited 124. With
`S2A_TEST_INLINE_SME=1`, the full fixture passed 84 checks and its real-only
mode passed 38, including SEG-to-normal-stack-to-BRK retry, SIMD/GPR restoration,
xstack cursor and final startup probe. Tracker and xstack registration in this
fixture are explicit fixture providers; this is not NativeAOT/GPU readback proof.
The APK build, lint, alignment and signature checks passed.

The same experimental APK reproduced the original startup crash with the flag
off. With it on, SDK initialization and nnMain were reached on the authorized
device. A later GPU DMA Memmove access violation was reproduced with a second
experiment off in the same APK. With the default-off DMA preservation read
experiment enabled, the device reached the opening movie and main menu. This
narrow result is being coordinated with the existing AR02 owner; it does not
resolve their buffer/WSI failures generally. No sustained gameplay,
normal exit, Android power/FPS or Apple acceptance is claimed. Ryujinx stub
warnings remain visible. The candidate remains default-off and requires maintainer review and platform gates.
