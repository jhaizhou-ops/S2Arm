#!/usr/bin/env python3
# 门禁手动：要真机：经 adb 在 arm64 安卓设备上跑 writers-gate 用例（还要 NDK）
"""真实 Android/Bionic aarch64：同一 writers-gate 用例与私有负控，经 adb 在设备上运行。

Linux ARM64 宿主入口仍是 run.py；本脚本只补 W3.3 所需的真机 AArch64 运行证据，不替代
Linux/glibc 回归。需要 adb、Android NDK 与一台 arm64 设备；输出目录必须在仓库外。
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run as host  # noqa: E402  (只复用源清单/用例表/哈希，不执行宿主测试)

ROOT = host.ROOT
FAULT = host.FAULT
SOURCES = host.SOURCES
CASES = host.CASES
W3_CASES = [
    "race-stack", "race-unmap", "race-heap",
    "busy-before", "busy-published", "unmap-before", "unmap-published",
    "stack-before", "stack-published", "query-default", "query-ondemand",
    "invalid-published", "timeout-published", "nested-fatal",
    "stop-published", "stop-acquired-published", "query-stop-published",
    "callback-map", "callback-unmap", "callback-unmap-stuck",
    "callback-map-adjacent", "callback-map-16k-adjacent", "callback-map-partial16", "map-partial16",
    "fast-map-rollback", "fast-stop", "race-map-map", "race-map-unmap",
    "lifetime-peer", "lifetime-wake", "lifetime-publication",
]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--serial", default=os.environ.get("ANDROID_SERIAL"))
    parser.add_argument("--cc", default=None)
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--all", action="store_true", help="run every host-default case on the device")
    parser.add_argument("--skip-negative", action="store_true")
    args = parser.parse_args()
    out = args.out.resolve()
    if out == ROOT or ROOT in out.parents:
        parser.error("output must be outside checkout")
    out.mkdir(parents=True, exist_ok=False)

    adb = ["adb"]
    if args.serial:
        adb += ["-s", args.serial]
    try:
        devices = subprocess.run(adb + ["get-state"], capture_output=True, text=True, timeout=15)
    except Exception as error:
        parser.error("adb unavailable: %s" % error)
    if devices.returncode != 0 or devices.stdout.strip() != "device":
        parser.error("one arm64 device required (set --serial/ANDROID_SERIAL)")

    ndk = Path(os.environ.get("ANDROID_NDK_HOME") or os.environ.get("ANDROID_NDK_ROOT") or "/opt/android-ndk")
    cc = args.cc or str(ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android31-clang")
    if not Path(cc).exists():
        parser.error("NDK clang missing: " + cc)
    remote = "/data/local/tmp/s2a-w3-writers-gate-%d" % os.getpid()
    result = {"commands": [], "device": None, "android_executed": True, "managed_gpu_executed": False,
              "page_size": None, "compiler": cc, "remote": remote}

    def run_local(command, name, expected=0, contains=None):
        p = subprocess.run([str(x) for x in command], cwd=ROOT, capture_output=True, text=True, timeout=120)
        log = p.stdout + p.stderr
        (out / (name + ".log")).write_text(log)
        passed = p.returncode == expected and (contains is None or contains in log)
        result["commands"].append({"argv": [str(x) for x in command], "exit": p.returncode,
                                   "expected_exit": expected, "passed": passed, "log": name + ".log"})
        if not passed:
            raise RuntimeError(name + ": " + log[-2000:])
        print(name, "PASS", flush=True)

    def run_device(binary, label, case_args, expected=0, contains=None, check_case=None):
        adb_push = adb + ["push", str(binary), remote + "/" + label]
        p = subprocess.run(adb_push, capture_output=True, text=True, timeout=120)
        if p.returncode:
            raise RuntimeError("adb push failed: " + p.stdout + p.stderr)
        command = "cd %s && timeout 30 ./%s %s" % (remote, label, " ".join(shlex.quote(x) for x in case_args))
        p = subprocess.run(adb + ["shell", command], capture_output=True, text=True, timeout=45)
        log = p.stdout + p.stderr
        (out / (label + ".log")).write_text(log)
        check_case = check_case or case_args[0]
        passed = p.returncode == expected and (contains is None or contains in log)
        if check_case in ("callback-unmap-stuck", "callback-map-partial16"):
            passed &= ("writer协调到期" in log and "state=host-callback" in log
                       and "callback=unknown" in log and "errno=110" in log)
        if check_case.startswith("diag-") and expected:
            passed &= (log.count("MapMemory首失败：") <= 1)
        result["commands"].append({"argv": ["adb", "shell", command], "exit": p.returncode,
                                   "expected_exit": expected, "passed": passed, "log": label + ".log"})
        (out / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        if not passed:
            raise RuntimeError(label + ": " + log[-2000:])
        print(label, "PASS", flush=True)

    def compile_source(root, source, obj):
        flags = ["-D__ANDROID__", "-DS2A_UNIT_TEST", "-std=gnu11", "-O2", "-g", "-Wall", "-Wextra",
                 "-Werror", "-Wno-unused-parameter", "-Wno-unused-function", "-Wno-unused-variable",
                 "-Wno-missing-field-initializers", "-Wno-misleading-indentation",
                 "-ffunction-sections", "-fdata-sections", "-pthread",
                 "-I" + str(root / "runtime/include"), "-I" + str(root / "android/native")]
        if source in [Path("runtime/src/" + x + ".c") for x in ("crash", "xstack", "gate", "svc_mem", "det", "os")] or source.name == "memory.c":
            flags += ["-D_GNU_SOURCE"]
        if source.name == "plat_android.c":
            flags += ["-Dplat_tsd_init=unused_plat_tsd_init", "-Dplat_tsd_base=unused_plat_tsd_base",
                      "-Dplat_tsd_offset=unused_plat_tsd_offset"]
        if source == Path("graphics/track/track.c"):
            flags.remove("-D__ANDROID__")
        run_local([cc, *flags, "-MMD", "-MF", obj.with_suffix(".d"), "-c", root / source, "-o", obj], obj.stem)

    def link(objects, name):
        binary = out / name
        run_local([cc, "-pthread", *objects, "-Wl,--gc-sections", "-Wl,--wrap=pthread_mutex_trylock",
                   "-Wl,--wrap=calloc", "-Wl,--wrap=free", "-Wl,--wrap=pthread_create",
                   "-Wl,--wrap=pthread_mutex_lock", "-Wl,--wrap=pthread_mutex_unlock",
                   "-Wl,--wrap=nanosleep", "-Wl,--wrap=s2a_track_backing_begin",
                   "-Wl,--wrap=mmap", "-Wl,--wrap=plat_page_size", "-llog", "-ldl",
                   "-o", binary], name + "-link")
        return binary

    try:
        run_local([cc, "--version"], "compiler")
        subprocess.run(adb + ["shell", "mkdir -p " + remote], check=True, timeout=20)
        result["device"] = subprocess.run(adb + ["shell", "getprop ro.product.model"], capture_output=True, text=True, timeout=15).stdout.strip()
        result["api"] = subprocess.run(adb + ["shell", "getprop ro.build.version.sdk"], capture_output=True, text=True, timeout=15).stdout.strip()
        result["page_size"] = subprocess.run(adb + ["shell", "getconf PAGE_SIZE"], capture_output=True, text=True, timeout=15).stdout.strip()

        objects = []
        for i, source in enumerate(SOURCES):
            obj = out / ("candidate-%d.o" % i)
            compile_source(ROOT, source, obj)
            objects.append(obj)
        files = set(SOURCES)
        for obj in objects:
            dependencies = shlex.split(obj.with_suffix(".d").read_text().replace("\\\n", " "))[1:] if obj.with_suffix(".d").exists() else []
            for dependency in dependencies:
                path = Path(dependency).resolve()
                if path.is_relative_to(ROOT):
                    files.add(path.relative_to(ROOT))
        # NDK clang 的 -MMD 依赖文件未生成也不影响；显式把本次改动文件纳入哈希。
        files.update({Path("runtime/src/svc_mem.c"), Path("runtime/src/thread.c"),
                      FAULT / "thread_android.inc", FAULT / "fault.h", Path("android/native/runtime/vm/writers.h")})
        hashes = {str(p): sha(ROOT / p) for p in sorted(files)}
        result["source_sha256"] = hashes
        binary = link(objects, "writers-gate")
        result["binary_sha256"] = sha(binary)

        cases = args.case or ([c for c in CASES if c != "external-published"] if args.all else W3_CASES)
        for case in cases:
            expected = 134 if case in ("timeout-published", "nested-fatal", "progress-stall-published",
                                       "diag-writer-fatal", "diag-mprotect-fatal",
                                       "callback-unmap-stuck", "callback-map-partial16", "det-poison") else 0
            if case == "det-poison":
                contains = "确定性共享内存无法恢复地址保留"
            elif expected:
                contains = "宿主writer协调失败 errno=" + ("35" if case == "nested-fatal" else "110")
            else:
                contains = {"callback-map": "PASS callback-map", "callback-unmap": "PASS callback-unmap",
                            "callback-map-adjacent": "PASS callback-map-adjacent", "callback-map-16k-adjacent": "PASS callback-map-16k-adjacent", "map-partial16": "PASS map-partial16",
                            "fast-map-rollback": "PASS fast-map-rollback", "fast-stop": "PASS fast-stop",
                            "race-map-map": "PASS race-map-map", "race-map-unmap": "PASS race-map-unmap"}.get(case, "PASS actual-gate")
            if case.startswith("diag-") and expected:
                contains = None
            run_device(binary, case, CASES[case] or [case], expected, contains)

        if not args.skip_negative:
            svc_index = SOURCES.index(Path("runtime/src/svc_mem.c"))
            test_object = objects[0]
            for label, before, after, case, expected, contains in [
                ("negative-fast-full", "    int fast = num == 0x2C && physical_growth_empty(regs[0], regs[1]);",
                 "    int fast = 0;", "callback-map", 134, "宿主writer协调失败 errno=110"),
                ("negative-unmap-fast", "    int fast = num == 0x2C && physical_growth_empty(regs[0], regs[1]);",
                 "    int fast = num == 0x2D || (num == 0x2C && physical_growth_empty(regs[0], regs[1]));",
                 "callback-unmap", 1, "FAIL unmap cannot complete while callback is live"),
            ]:
                private = out / (label + "-source")
                for path in files:
                    target = private / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(ROOT / path, target)
                path = private / "runtime/src/svc_mem.c"
                text = path.read_text()
                if text.count(before) != 1:
                    raise RuntimeError("negative control target changed: " + label)
                path.write_text(text.replace(before, after))
                mutant_obj = out / (label + ".o")
                compile_source(private, Path("runtime/src/svc_mem.c"), mutant_obj)
                mutant = link([*objects[:svc_index], mutant_obj, *objects[svc_index + 1:]], label)
                run_device(mutant, label, CASES[case] or [case], expected, contains)

            # 删除真实准入等待：busy-published 必须由真实并发击穿，不能以任意崩溃代红。
            private = out / "negative-admission-source"
            for path in files:
                target = private / path
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / path, target)
            path = private / FAULT / "thread_android.inc"
            before = "    if (error == EBUSY) error = android_vm_wait_serial(self, deadline);"
            text = path.read_text()
            if text.count(before) != 1:
                raise RuntimeError("negative admission control target changed")
            path.write_text(text.replace(before, "    /* test-only: omit admission wait */"))
            mutant_obj = out / "negative-admission.o"
            compile_source(private, SOURCES[0], mutant_obj)
            mutant = link([mutant_obj, *objects[1:]], "negative-admission")
            run_device(mutant, "negative-admission", ["busy-published"], 134, "宿主writer协调失败 errno=16")

        result["source_unchanged"] = hashes == {str(p): sha(ROOT / p) for p in sorted(files)}
        result["passed"] = result["source_unchanged"] and all(c["passed"] for c in result["commands"])
        (out / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        if not result["passed"]:
            raise RuntimeError("production source changed during test")
        print("PASS real writers gate/VM on Android/Bionic aarch64; 16K is modeled, not a real 16K device")
    finally:
        subprocess.run(adb + ["shell", "rm -rf " + remote], capture_output=True, text=True, timeout=20)


if __name__ == "__main__":
    main()
