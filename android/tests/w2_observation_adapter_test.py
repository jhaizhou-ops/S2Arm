#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Actual adapter exec/guest bodies + real observer/owner, CPU synthetic boundaries.

No NDK, Android runtime, compiler worker, Vulkan driver, game input or download.
Record types/opcode values and the tested functions are extracted verbatim from
production, matching device_retirement_test.py's source-body approach. Record
callbacks are controlled mocks; guest read/write and pthread waits are real.
--baseline-ref additionally compares full outputs against frozen pre-observer
adapter bodies. The normal gate does not require historical Git objects.
"""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "android/native"
ADAPTER = "android/native/nvn/mtl_vk_adapter.c"
HERE = Path(__file__).with_suffix(".c")


def body(text, signature):
    start = text.index(signature)
    begin = text.index("{", start)
    depth, end = 1, begin + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


def bodies(text):
    names = ["static uint64_t adapter_thread_token(", "static uint64_t adapter_now_ns(",
             "static int guest_rd(", "static int guest_wr("]
    # 本支生产在 exec/guest 回放前新增了“GPU 侧事件写要有完成证明”的闸门
    # （mtl_vk_adapter.c:911 adapter_event_completion_gate，:921 是它的入参/target 宏，
    # 证明边界是 nvn_vk_first_draw_pass_break 的关 pass+提交+等 fence）。这里连同宏一起
    # 从生产原文整段抽出，夹具跑的就是生产闸门本身；宿主的“有没有证明”由 .c 里可控桩驱动。
    # 旧主线/冻结基线没有这两个函数（main 树 grep 为零），条件抽取保证 --baseline-ref 仍可用。
    prefix = ""
    if "#define S2A_EVENT_NV_WAIT_BIT" in text:
        start = text.index("#define S2A_EVENT_NV_WAIT_BIT")
        prefix = text[start:text.index("\n", start) + 1] + "\n"
    if "static int s2a_vk_adapter_exec_impl(" in text:
        events = []
        if "static int adapter_event_completion_gate(" in text:
            events = ["static int adapter_event_signal_needs_proof(",
                      "static int adapter_event_completion_gate("]
        names += events + ["static void observation_expect_shader(",
                           "static int s2a_vk_adapter_exec_impl(",
                           "static int s2a_vk_adapter_exec_guest_impl("]
    names += ["int s2a_vk_adapter_exec(", "int s2a_vk_adapter_exec_guest("]
    return prefix + "\n\n".join(body(text, name) for name in names) + "\n"


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError("mutation anchor changed: " + old)
    return text.replace(old, new, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", help="optional pre-observer Git revision for byte A/B and functional red")
    parser.add_argument("--keep-output", type=Path, help="new directory for binaries, extracted sources and evidence")
    parser.add_argument("--sanitize", action="store_true", help="ASan/UBSan positive run (no historical or mutant runs)")
    args = parser.parse_args()
    if args.keep_output:
        directory = args.keep_output.resolve(); directory.mkdir(parents=True, exist_ok=False)
        temporary = None
    else:
        temporary = tempfile.TemporaryDirectory(prefix="w2-observation-adapter-")
        directory = Path(temporary.name)
    try:
        current = (ROOT / ADAPTER).read_text()
        original_bodies = bodies(current)
        observer = (NATIVE / "direct/w2_observation.inc").read_text()
        record = (NATIVE / "direct/vk_record.h").read_text()
        obj = (ROOT / "graphics/nvn/gfx/nvn/nvn_obj.h").read_text()
        types = "\n".join(body(record, s) + ";" for s in
                          ("struct s2a_record_memory {", "enum s2a_record_code {", "struct s2a_record_result {"))
        types += "\n" + obj[obj.index("typedef struct { uint32_t op, size; } op_hdr;"):
                                obj.index("// Payload (immediately follows op_hdr)")]
        (directory / "w2_adapter_types.h").write_text(types)
        cc = shlex.split(os.environ.get("CC", "cc"))
        flags = ["-std=c11", "-O0", "-g", "-Wall", "-Wextra", "-Werror", "-pedantic", "-pthread",
                 "-I" + str(directory), "-I" + str(NATIVE), "-I" + str(NATIVE / "direct")]
        if args.sanitize:
            flags += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-fno-pie", "-no-pie"]
        harness = HERE.read_text()

        def compile_variant(name, extracted=original_bodies, core=observer, test=harness):
            (directory / "w2_adapter_bodies.h").write_text(extracted)
            (directory / "w2_observation.inc").write_text(core)
            c = directory / (name + ".c"); c.write_text(test)
            exe = directory / name
            command = cc + flags + [str(c), str(NATIVE / "nvn/nvn_vk_exec_owner.c"), "-o", str(exe)]
            built = subprocess.run(command, text=True, capture_output=True, timeout=30)
            (directory / (name + "-compile.log")).write_text(" ".join(command) + "\n" + built.stdout + built.stderr)
            if built.returncode:
                raise RuntimeError(name + ": compile failure is NOT a valid negative\n" + built.stderr)
            (directory / (name + "-bodies.h")).write_text(extracted)
            (directory / (name + "-observer.inc")).write_text(core)
            return exe

        def invoke(exe, *arguments):
            env = dict(os.environ)
            if args.sanitize:
                env["ASAN_OPTIONS"] = "detect_leaks=0:halt_on_error=1"
                env["UBSAN_OPTIONS"] = "halt_on_error=1"
            result = subprocess.run([str(exe), *map(str, arguments)], text=True,
                                    capture_output=True, timeout=10, env=env)
            (directory / (exe.name + "-" + str(arguments[0]) + "-run.log")).write_text(
                "exit=" + str(result.returncode) + "\n" + result.stdout + result.stderr)
            return result

        def red(exe, case, expected):
            result = invoke(exe, case)
            # Signals, timeout and compile failures are not accepted as evidence.
            if result.returncode != 1 or "FAIL " + expected not in result.stderr:
                raise RuntimeError(exe.name + ": expected assertion red was not observed\n" + result.stdout + result.stderr)
            print(exe.name + ": expected assertion red: " + result.stderr.strip(), flush=True)

        controls = []
        for label, signature in (("omit-direct-scope", "int s2a_vk_adapter_exec("),
                                 ("omit-guest-scope", "int s2a_vk_adapter_exec_guest(")):
            original = body(original_bodies, signature)
            mutant = original.replace("s2a_w2_scope_enter(&observation);", "/* deliberately omitted scope entry */")
            mutant = mutant.replace("s2a_w2_scope_leave(&observation, rc == S2A_RECORD_OK);", "/* deliberately omitted scope leave */")
            controls.append((label, replace_once(original_bodies, original, mutant), observer, harness,
                             "complete", "test_complete"))
        controls.append(("omit-expect", replace_once(original_bodies,
            "s2a_w2_scope_expect_shader(scope);", "(void)scope; /* omitted expectation */"),
            observer, harness, "expected", "test_expected_shader"))
        controls.append(("omit-seal", original_bodies, observer, replace_once(harness,
            "    CHECK(s2a_w2_seal(w, 1, 1) == 0);\n    struct s2a_w2_snapshot d = snapshot(w);",
            "    /* deliberately omitted seal */\n    struct s2a_w2_snapshot d = snapshot(w);"), "complete", "finish"))
        controls.append(("seal-with-guest-lease", original_bodies, replace_once(observer,
            "else if (w->data.inflight_scopes || w->data.inflight_shaders)",
            "else if (w->data.inflight_shaders)"), harness, "guest-wait", "test_guest_wait_lease"))
        controls.append(("ack-incomplete-after-unlock", original_bodies, replace_once(observer,
            "if (result != 0 || (s && s->metadata_complete)) result = s2a_w2_ack(w, s, result == 0);\n    else result = -1;",
            "result = s2a_w2_ack(w, s, result == 0);"), harness,
            "unlock-export", "test_guest_unlock_export_race"))
        # First establish an executed functional red before the positive build.
        if not args.sanitize:
            name, extracted, core, test, case, expected = controls[0]
            red(compile_variant(name, extracted, core, test), case, expected)
        positive = compile_variant("production-adapter")
        cases = ("complete", "expected", "safe-header", "not-ready", "inflight", "guest-wait", "unlock-export", "event-gate", "tls", "late")
        for case in cases:
            result = invoke(positive, case)
            if result.returncode:
                raise RuntimeError("production " + case + " failed\n" + result.stdout + result.stderr)
            print(result.stdout.strip(), flush=True)
        outputs = []
        for enabled in (0, 1):
            path = directory / ("production-" + str(enabled) + ".bin")
            result = invoke(positive, "bytes", enabled, path)
            if result.returncode: raise RuntimeError(result.stdout + result.stderr)
            outputs.append(path.read_bytes()); print(result.stdout.strip(), flush=True)
        if outputs[0] != outputs[1]: raise RuntimeError("off/on full behavior bytes differ")
        if args.baseline_ref and not args.sanitize:
            frozen = subprocess.check_output(["git", "show", args.baseline_ref + ":" + ADAPTER], cwd=ROOT, text=True)
            baseline = compile_variant("frozen-adapter", bodies(frozen))
            path = directory / "frozen.bin"; result = invoke(baseline, "bytes", 0, path)
            if result.returncode: raise RuntimeError(result.stdout + result.stderr)
            if path.read_bytes() != outputs[0]: raise RuntimeError("frozen/current off/on full behavior bytes differ")
            red(baseline, "complete", "test_complete")
            print("PASS frozen A/B: " + args.baseline_ref + " full behavior bytes identical", flush=True)
        if not args.sanitize:
            for name, extracted, core, test, case, expected in controls[1:]:
                red(compile_variant(name, extracted, core, test), case, expected)
        print(f"PASS: 50 adapter cases (44 existing + 6 event completion gate); 20 behavior rows x off/on, {len(outputs[0]) * 2} bytes identical; "
              f"{0 if args.sanitize else len(controls)} assertion-based negative controls; "
              "real exec/guest bodies and owner; mock record boundary; no GPU/device/acceptance claim")
    finally:
        if temporary: temporary.cleanup()


if __name__ == "__main__":
    main()
