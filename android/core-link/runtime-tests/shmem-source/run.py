#!/usr/bin/env python3
# 门禁手动：只能 Linux ARM64（脚本断言 Linux + aarch64），本机跑不了
"""真实 Linux ARM64 共享内存源对齐；16 KiB 仅为准入模型。"""
import argparse
import hashlib
import json
import pathlib
import platform
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[4]
TEST = pathlib.Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--thread-source", type=pathlib.Path)
    args = parser.parse_args()
    assert platform.system() == "Linux" and platform.machine() in ("aarch64", "arm64")
    out = args.out.resolve()
    assert out != ROOT and ROOT not in out.parents
    out.mkdir(parents=True, exist_ok=True)
    thread = args.thread_source or ROOT / "runtime/src/thread.c"
    sources = [thread, ROOT / "android/native/plat_android.c", TEST / "wrap_test.c"]
    record = {"source_sha256": {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
              "commands": [], "android_device_executed": False, "real_kernel_page_size": 4096}

    def run(command, name, absent=None):
        result = subprocess.run([str(x) for x in command], capture_output=True, text=True, timeout=30)
        (out / (name + ".log")).write_text(result.stdout + result.stderr)
        valid_log = absent is None or absent not in result.stdout + result.stderr
        record["commands"].append({"argv": [str(x) for x in command], "exit": result.returncode,
                                   "log": name + ".log", "valid_log": valid_log})
        (out / "results.json").write_text(json.dumps(record, indent=2) + "\n")
        if result.returncode or not valid_log:
            raise SystemExit(1)

    flags = ["-D_GNU_SOURCE", "-D__ANDROID__", "-DS2A_UNIT_TEST", "-std=gnu11", "-O2",
             "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-Wno-unused-variable",
             "-Wno-unused-parameter", "-Wno-misleading-indentation", "-ffunction-sections",
             "-fdata-sections", "-pthread", "-I" + str(ROOT / "runtime/src"),
             "-I" + str(ROOT / "runtime/include"), "-I" + str(ROOT / "platform")]
    objects = []
    for index, source in enumerate(sources):
        obj = out / f"source-{index}.o"
        run(["cc", *flags, "-c", source, "-o", obj], f"compile-{index}")
        objects.append(obj)
    exe = out / "wrap-test"
    run(["cc", "-pthread", *objects, "-Wl,--gc-sections", "-Wl,--wrap=plat_page_size", "-o", exe], "link")
    for case in ("real-4k", "modeled-16k"):
        run([exe, case], case, absent="s2a_shmem_wrap：大小" if case == "real-4k" else None)
    record["pass"] = True
    (out / "results.json").write_text(json.dumps(record, indent=2) + "\n")
    print("PASS real-4k wrap/alias and modeled-16k admission")


if __name__ == "__main__":
    main()
