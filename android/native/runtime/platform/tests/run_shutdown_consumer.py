#!/usr/bin/env python3
# 门禁手动：只能 Linux ARM64（含 TPIDR2_MAGIC 的 UAPI 头），见 android/tests/gate_not_default.tsv
"""Execute real Linux ARM64 thread/fault/lifecycle shutdown consumers.

The module classifier, tracker and managed endpoints are explicit fixtures.
The production writer epoch, signal dispatcher, fault callback, xstack and
lifecycle are linked unchanged. No Android or managed-runtime pass is claimed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import time

ROOT = Path(__file__).resolve().parents[5]
PLATFORM = ROOT / "android/native/runtime/platform"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--peer-root", type=Path, default=ROOT)
    parser.add_argument("--runtime-source", type=Path)
    parser.add_argument("--vulkan-include", type=Path, required=True,
                        help="directory containing vulkan/vulkan_core.h, vulkan_android.h and vulkan_vi.h (e.g. NDK sysroot/usr/include)")
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() not in ("aarch64", "arm64"):
        parser.error("requires native Linux ARM64")
    peer = args.peer_root.resolve()
    out = args.out.resolve()
    if ROOT == out or ROOT in out.parents or peer == out or peer in out.parents:
        parser.error("output must be outside both source trees")
    out.mkdir(parents=True, exist_ok=True)
    fault = peer / "android/native/runtime/fault"
    runtime = (args.runtime_source or peer / "android/native/runtime/runtime.c").resolve()
    lifecycle = ROOT / "runtime/src/lifecycle.c"
    sources = [lifecycle, PLATFORM / "lifecycle_android.c", PLATFORM / "tests/shutdown_consumer.c",
               PLATFORM / "tests/shutdown_guest.S", peer / "runtime/src/crash.c", peer / "runtime/src/xstack.c",
               fault / "fault.c", fault / "trampoline.S", fault / "elf_host.c", fault / "tests/guest_stack.S",
               peer / "android/native/guest_signal.c", peer / "android/native/redzone.S",
               PLATFORM / "tests/shutdown_status_provider.c", PLATFORM / "tests/shutdown_vk.c"]
    native = peer / "android/native"
    vk_source = native / "direct_vk.c"
    inputs = sources + [peer / "runtime/src/thread.c", peer / "runtime/src/thread_wait_diag.inc", fault / "thread_android.inc", fault / "fault.h",
                        runtime, runtime.parent / "runtime.h", runtime.parent / "services_abi.h",
                        PLATFORM / "lifecycle_android.h", Path(__file__).resolve(), vk_source, native / "direct_vk.h",
                        native / "direct_vk_commands.inc", native / "direct_wsi.inc", native / "direct_wsi_plan.h",
                        native / "direct_objects.inc", native / "direct_allocator.inc", native / "wsi_lease.h"]
    before = {str(p): digest(p) for p in inputs}
    receipt = {"kind": "real thread-fault-lifecycle consumer", "android_executed": False,
               "managed_executed": False, "inputs": before, "records": []}

    def run(argv, name, expected=0):
        start = time.monotonic()
        result = subprocess.run(list(map(str, argv)), capture_output=True, text=True, timeout=15)
        elapsed = time.monotonic() - start
        log = result.stdout + result.stderr
        (out / (name + ".log")).write_text(log)
        receipt["records"].append({"name": name, "command": list(map(str, argv)), "exit": result.returncode,
                                   "expected": expected, "seconds": elapsed})
        (out / "results.json").write_text(json.dumps(receipt, indent=2))
        assert result.returncode == expected, (name, result.returncode, expected, log)
        return log, elapsed

    flags = [os.environ.get("CC", "cc"), "-O2", "-D_GNU_SOURCE", "-D__ANDROID__", "-DS2A_UNIT_TEST",
             '-DS2A_SHUTDOWN_THREAD_SOURCE="' + str(peer / "runtime/src/thread.c") + '"',
             '-DS2A_SHUTDOWN_RUNTIME_SOURCE="' + str(runtime) + '"',
             "-ffunction-sections", "-fdata-sections", "-Wall", "-Wextra"]
    flags += ["-I" + str(runtime.parent), "-I" + str(fault.parent),
              "-I" + str(peer / "android/native"), "-I" + str(args.vulkan_include.resolve())]
    for root in (peer, ROOT):
        flags += ["-I" + str(root), "-I" + str(root / "runtime/src"), "-I" + str(root / "runtime/include")]
    run([flags[0], "--version"], "compiler")

    def build(first, name, vk=None):
        binary = out / name
        extra = ['-DS2A_SHUTDOWN_VK_SOURCE="' + str(vk) + '"'] if vk else []
        run(flags + extra + [first] + sources[1:] + ["-Wl,--gc-sections", "-pthread", "-ldl", "-o", binary], "build-" + name)
        return binary

    binary = build(lifecycle, "consumer")
    for mode in ("guest-owner-exit", "guest-owner-break"):
        log, _ = run([binary, mode], mode)
        assert "vk-terminal-clean" in log and "优雅退出完成" in log, log
    for mode, status in (("normal", 0), ("zero", 0), ("serial-owner", 0), ("serial-gap", 0), ("serial-hang", 124),
                         ("touch-hang", 124), ("self-touch", 125),
                         ("cleanup-fail", 125), ("stop-only", 125), ("wrong-session", 125), ("query-fail", 125)):
        log, elapsed = run([binary, mode], mode, status)
        if mode not in ("touch-hang", "self-touch", "serial-hang"):
            assert "managed-dispose-after-real-quiesce" in log
        else:
            assert "managed-dispose" not in log
        assert ("优雅退出完成" in log) == (status == 0)
        if mode in ("touch-hang", "serial-hang"):
            assert 1.3 < elapsed < 3.0
    # Vulkan shutdown phases with a fake driver and a guest allocator that may enter an SVC.
    drained = "收局排空：已受理Vulkan调用全部出账"
    for mode in ("vk-svc", "vk-core"):  # original P1 interleavings A / B, admitted token frames
        log, _ = run([binary, mode], mode)
        assert drained in log and "vk-terminal-clean" in log and "终止清场完成" in log, log
        assert "vk-callback-parked-in-svc" not in log and "优雅退出完成" in log, log
    log, _ = run([binary, "guest-owner"], "guest-owner")  # S2A_CORES=1 owner + concurrent non-terminal epoch
    assert "vk-concurrent-epoch-ok" in log and drained in log and "优雅退出完成" in log, log
    log, _ = run([binary, "vk-passthrough"], "vk-passthrough", 125)  # untokened frame frozen in its callback
    assert "vk-callback-parked-in-svc" in log and "vk-terminal-busy" in log and "冻结在驱动帧里" in log, log
    assert "终止清场完成" not in log and "优雅退出完成" not in log, log
    original = lifecycle.read_text()
    marker = "int error = tracking_installed ? android_shutdown_writers_begin() : 0;"
    assert original.count(marker) == 1
    mutant = out / "missing-quiesce.c"
    mutant.write_text(original.replace(marker, "int error = 0;").replace(
        '"../../android/native/runtime/platform/lifecycle_android.h"',
        '"' + str(PLATFORM / "lifecycle_android.h") + '"'))
    broken = build(mutant, "missing-quiesce")
    log, _ = run([broken, "normal"], "reject-actual-touch-race", 86)
    assert "FAIL shutdown consumer: actual fault callback drained before Dispose" in log
    assert "managed-dispose" not in log and "优雅退出完成" not in log
    lifecycle_text = lifecycle.read_text()
    vk_text = vk_source.read_text()
    header = ('"../../android/native/runtime/platform/lifecycle_android.h"',
              '"' + str(PLATFORM / "lifecycle_android.h") + '"')
    drain_begin = "    // 失败时不调 host_wait_end"
    drain_end = 'S2A_SHUTDOWN_STAGE("排空已受理Vulkan调用", t0); }\n'
    assert lifecycle_text.count(drain_begin) == 1 and lifecycle_text.count(drain_end) == 1
    start = lifecycle_text.index(drain_begin); stop = lifecycle_text.index(drain_end) + len(drain_end)
    drain_block, without_drain = lifecycle_text[start:stop], lifecycle_text[:start] + lifecycle_text[stop:]
    def moved(after):
        anchor = '    S2A_SHUTDOWN_STAGE("' + after + '", t0);\n'
        assert without_drain.count(anchor) == 1, after
        return without_drain.replace(anchor, anchor + drain_block).replace(*header)
    def write(name, text):
        path = out / name; path.write_text(text); return path
    guard = "    if(s2a_svc_stopping()){"
    frozen_check = "    if(frozen){"
    assert vk_text.count(guard) == 1 and vk_text.count(frozen_check) == 1
    unguarded = write("vk-unguarded.c", vk_text.replace(guard, "    if(0 && s2a_svc_stopping()){"))
    unchecked = write("vk-unchecked.c", vk_text.replace(frozen_check, "    if(0 && frozen){"))
    late_svc = write("late-drain-svc.c", moved("停住系统调用"))
    late_writer = write("late-drain-writer.c", moved("停稳访存writer"))
    host_wait = "      s2a_android_guest_host_wait_begin();\n"
    assert lifecycle_text.count(host_wait) == 1
    no_wait = write("no-host-wait.c", lifecycle_text.replace(host_wait, "").replace(*header))
    # Reverse mutants must each be stopped, and for the reason the case models.
    log, _ = run([build(late_svc, "late-drain-svc-guarded"), "vk-svc"], "reject-late-drain-guarded", 125)
    assert "终局 SVC 停机门已发布" in log and "managed-dispose" not in log, log
    log, _ = run([build(late_svc, "late-drain-svc", unguarded), "vk-svc"], "reject-late-drain-svc", 125)
    assert "vk-callback-parked-in-svc" in log and "未返回" in log and "managed-dispose" not in log, log
    log, _ = run([build(late_writer, "late-drain-writer", unguarded), "vk-core"], "reject-late-drain-writer", 125)
    assert "未返回" in log and "vk-callback-parked-in-svc" not in log and "managed-dispose" not in log, log
    log, _ = run([build(no_wait, "no-host-wait"), "guest-owner"], "reject-no-host-wait", 125)
    assert "vk-concurrent-epoch-ok" not in log and "managed-dispose" not in log, log
    # Control: without the frozen-callback check the same frame is reported as cleaned.
    log, _ = run([build(lifecycle, "unchecked-frozen", unchecked), "vk-passthrough"], "control-unchecked-frozen", 0)
    assert "vk-callback-parked-in-svc" in log and "终止清场完成" in log and "vk-terminal-clean" in log, log
    receipt["sources_unchanged"] = before == {str(p): digest(p) for p in inputs}
    receipt["pass"] = receipt["sources_unchanged"]
    (out / "results.json").write_text(json.dumps(receipt, indent=2))
    assert receipt["pass"], "source changed during execution; repeat against frozen providers"
    print("PASS real thread/fault shutdown consumers, Vulkan phase cases and reverse mutants")


if __name__ == "__main__":
    main()
