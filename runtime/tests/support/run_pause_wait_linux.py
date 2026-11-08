# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁手动：只能 Linux（真 pthread/futex/EINTR；非 Linux 直接报错退出），本机 macOS 跑不了，门禁 Linux 路径本轮没实跑验证
"""Linux host protocol only: verbatim production functions, real pthread/futex/EINTR.

The small fixture substitutes thread metadata, core accounting and VM publication;
it does not execute a guest, real VM census, ARM64 handler, Bionic or a device.
Native Linux ARM64 acceptance remains fault/tests/run_thread.py and writers-gate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess

from run_pause_wait_host import function

ROOT = Path(__file__).resolve().parents[3]
FAULT = Path("android/native/runtime/fault/thread_android.inc")


def production(root):
    android = (root / FAULT).read_text()
    thread = (root / "runtime/src/thread.c").read_text()
    parts = []
    names = ["android_futex_wake", "android_vm_park_poll", "android_vm_barrier_poll", "android_vm_barrier",
             "android_wait_pause_init", "android_wait_pause_on", "android_wait_pause_locked"]
    if "static void android_wait_pause_poll(" in android:
        names.append("android_wait_pause_poll")
    names.append("android_condition_wait")
    for name in names:
        match = re.search(r"static (?:void|int) " + name + r"\(", android)
        if not match:
            raise RuntimeError("missing production function " + name)
        parts.append(function(android, match[0]))
    for signature in ["static int thread_condition_wait(", "static void wait_unlink(",
                      "static int64_t block(", "static void pause_park(",
                      "static void sleep_wait_boundary(", "static void sleep_ontime_until("]:
        # A declaration is not the definition. Match through the opening brace.
        match = re.search(re.escape(signature) + r"[^;{]*\{", thread)
        parts.append(function(thread[match.start():], signature))
    for signature in ["static uint32_t thr_pause(", "static uint32_t thr_unpause("]:
        parts.append(function(thread[thread.rindex(signature):], signature))
    return "\n\n".join(parts) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--case", action="append")
    args = parser.parse_args()
    if platform.system() != "Linux":
        parser.error("Linux host required; this is not a native ARM64 substitute")
    root, out = args.source_root.resolve(), args.out.resolve()
    if out == ROOT or ROOT in out.parents or out == root or root in out.parents:
        parser.error("output must be outside both checkouts")
    out.mkdir(parents=True, exist_ok=False)
    source = production(root)
    (out / "production.inc").write_text(source)
    harness = Path(__file__).with_name("pause_wait_linux_host.c")
    result = {"host": platform.platform(), "native_arm64_acceptance": False,
              "android_executed": False, "commands": [],
              "fixture_sha256": hashlib.sha256(harness.read_bytes()).hexdigest(),
              "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "source_sha256": {str(p): hashlib.sha256((root / p).read_bytes()).hexdigest()
                                for p in [FAULT, Path("runtime/src/thread.c")]}}
    def run(name, command, expected=0, env=None, contains=None):
        p = subprocess.run(list(map(str, command)), env=env, capture_output=True, timeout=20)
        output = p.stdout + p.stderr
        (out / (name + ".log")).write_bytes(output)
        ok = (p.returncode == expected and (expected != 0 or not re.search(rb"\bFAIL\b", output))
              and (contains is None or contains.encode() in output))
        result["commands"].append({"name": name, "argv": list(map(str, command)),
                                   "exit": p.returncode, "expected_exit": expected, "pass": ok})
        (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        print(name, p.returncode, flush=True)
        if not ok:
            raise RuntimeError(name + ": " + output.decode()[-2000:])
    def build(name, code):
        private = out / name
        private.mkdir()
        (private / "production.inc").write_text(code)
        binary = private / "protocol"
        run(name + "-compile", [args.cc, "-std=gnu11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                               "-Wno-unused-function", "-pthread", "-I" + str(private), harness, "-o", binary])
        return binary
    run("compiler", [args.cc, "--version"])
    binary = build("candidate", source)
    env = dict(os.environ, S2A_ANDROID_WAIT_PAUSE="1")
    for case in args.case or ["basic", "vm-first", "pause-first", "vm-first-masked", "pause-first-masked", "deadline", "expired",
                              "sleep-basic", "sleep-vm-first", "sleep-pause-first", "sleep-deadline", "sleep-expired"]:
        run(case, [binary, case], env=env, contains="PASS Linux host protocol")
    if not args.case:
        for state in (None, "0", "invalid"):
            disabled = dict(os.environ)
            disabled.pop("S2A_ANDROID_WAIT_PAUSE", None)
            if state is not None:
                disabled["S2A_ANDROID_WAIT_PAUSE"] = state
            run("disabled-" + str(state), [binary, "basic"], expected=1, env=disabled,
                contains="FAIL target acknowledges pause within original 2s")
        for case in ("sleep-basic", "sleep-vm-first", "sleep-pause-first", "sleep-deadline", "sleep-expired"):
            run("disabled-" + case, [binary, case], env=dict(env, S2A_ANDROID_WAIT_PAUSE="0"),
                contains="PASS Linux host protocol")
        mutations = [
            ("no-vm-pause-poll", "? android_wait_pause_poll : NULL", "? NULL : NULL", "vm-first",
             "FAIL target acknowledges pause within original 2s"),
            ("no-futex-notification", "if (atomic_load(&t->vm_ack)) android_futex_wake(&android_vm_epoch);", "/* removed notification */",
             "vm-first-masked", "FAIL target acknowledges pause within original 2s"),
            ("no-wait-notification", "if (!already && android_wait_pause_on() && t->vm_wait_safe) pthread_cond_signal(&t->cv);", "/* removed notification */",
             "basic", "FAIL target acknowledges pause within original 2s"),
            ("retry-deadline-reset", "int rc = thread_condition_wait(t, &t->cv, ns > 0 ? &dl : NULL);",
             "if (ns > 0) { ++dl.tv_nsec; if (dl.tv_nsec == 1000000000) { dl.tv_sec++; dl.tv_nsec = 0; } }\n"
             "        int rc = thread_condition_wait(t, &t->cv, ns > 0 ? &dl : NULL);",
             "deadline", "FAIL same operation preserves absolute deadline"),
            ("sleep-no-pause-poll", "android_vm_barrier_poll(sleeper, sleep_wait_boundary);", "android_vm_barrier_poll(sleeper, NULL);",
             "sleep-vm-first", "FAIL target acknowledges pause within original 2s"),
            ("lost-result", "thread->vm_wait_safe=0;\n    atomic_store(&thread->paused_ack,0);",
             "thread->wres=R_TIMEOUT;\n    thread->vm_wait_safe=0;\n    atomic_store(&thread->paused_ack,0);",
             "basic", "FAIL original Result preserved"),
            ("no-return-barrier", "android_vm_barrier_poll(thread, condition!=&g_pause_cv && android_wait_pause_on()\n                           ? android_wait_pause_poll : NULL);",
             "/* removed return barrier */", "vm-first", "FAIL target reaches actual futex return barrier"),
        ]
        for name, before, after, case, expected in mutations:
            if source.count(before) != 1:
                raise RuntimeError("mutation target " + name)
            changed = build(name, source.replace(before, after))
            run(name, [changed, case], expected=1, env=env, contains=expected)
        # A requester-written ACK must not make target-boundary assertions green.
        helper = function(source, "static void android_wait_pause_locked(")
        forged = source.replace(helper, "static void android_wait_pause_locked(thr_t *thread) { (void)thread; }")
        before = "int ack=atomic_load_explicit(&t->paused_ack,memory_order_acquire);"
        if forged.count(before) != 1:
            raise RuntimeError("requester ACK mutation target")
        forged = forged.replace(before, "atomic_store(&t->paused_ack,1); " + before)
        changed = build("requester-fake-ack", forged)
        run("requester-fake-ack", [changed, "basic"], expected=1, env=env,
            contains="FAIL target boundary actually executed")
    result["source_unchanged"] = all(hashlib.sha256((root / p).read_bytes()).hexdigest() == sha
                                     for p, sha in result["source_sha256"].items())
    (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    if not result["source_unchanged"]:
        raise RuntimeError("production source changed")
    print("PASS Linux host protocol only; no ARM64/Bionic/census/scheduler acceptance")


if __name__ == "__main__":
    main()
