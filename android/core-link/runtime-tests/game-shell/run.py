#!/usr/bin/env python3
# 门禁手动：只能 Linux（非 Linux 直接退出）且要传 --vulkan-include 头目录，本机 macOS 跑不了
"""Real AndroidWindow + wsi_lease host consumer; platform/Vulkan endpoints are fakes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--vulkan-include", type=Path, required=True,
                        help="include directory containing vulkan/vulkan.h (headers only; no driver)")
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    parser.add_argument("--cxx", default=os.environ.get("CXX", "c++"))
    args = parser.parse_args()
    if platform.system() != "Linux":
        parser.error("this host fixture requires Linux pthread_condattr_setclock; no clock stub is substituted")
    out = args.out.resolve()
    if out == ROOT or ROOT in out.parents:
        parser.error("--out must be outside the source checkout")
    include = args.vulkan_include.resolve()
    if not (include / "vulkan/vulkan.h").is_file():
        parser.error("--vulkan-include must contain actual Vulkan headers")
    out.mkdir(parents=True, exist_ok=True)
    # An NDK sysroot may supply these headers; never add that entire include
    # directory and accidentally replace the host's libc/pthread headers.
    headers = out / "vulkan-headers"
    headers.mkdir(exist_ok=True)
    for name in ("vulkan", "vk_video"):
        target = include / name
        link = headers / name
        if not target.is_dir():
            continue
        if link.is_symlink() and link.resolve() == target:
            continue
        if link.exists() or link.is_symlink():
            parser.error("output header link already belongs to another input: " + str(link))
        link.symlink_to(target, target_is_directory=True)
    native = ROOT / "android/native"
    sources = [native / "window.cpp", native / "wsi_lease.c", HERE / "window_game_test.cpp"]
    inputs = sources + [native / name for name in ("window.h", "presenter.h", "host_android.h", "wsi_lease.h")]
    inputs += list(sorted((HERE / "fakes/android").glob("*.h"))) + [Path(__file__).resolve()]
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    records = []

    def run(command, name):
        result = subprocess.run(list(map(str, command)), capture_output=True, text=True, timeout=30)
        (out / (name + ".log")).write_text(result.stdout + result.stderr)
        records.append({"name": name, "command": list(map(str, command)), "exit": result.returncode})
        (out / "results.json").write_text(json.dumps({"source": hashes, "records": records,
            "scope": "real Window/lease; fake Android refcounts, host registration, Vulkan/Presenter; no GPU"}, indent=2) + "\n")
        if result.returncode:
            raise RuntimeError(f"{name} failed; see {out / (name + '.log')}")
        return result.stdout + result.stderr

    flags = ["-O2", "-Wall", "-Wextra", "-Werror", "-UNDEBUG", "-pthread", "-D_POSIX_C_SOURCE=200809L",
             "-I" + str(HERE / "fakes"), "-I" + str(native), "-I" + str(ROOT / "runtime/include"),
             "-I" + str(headers), "-DVK_USE_PLATFORM_ANDROID_KHR"]
    obj = out / "wsi.o"
    run([args.cc, "-std=c11", *flags, "-c", native / "wsi_lease.c", "-o", obj], "compile-wsi")
    binary = out / "window-game"
    run([args.cxx, "-std=c++17", *flags, native / "window.cpp", HERE / "window_game_test.cpp",
         obj, "-o", binary], "compile-window")
    log = run([binary], "window-game")
    assert "Window game mode:" in log and "PASS" in log
    assert hashes == {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    print(log, end="")


if __name__ == "__main__":
    main()
