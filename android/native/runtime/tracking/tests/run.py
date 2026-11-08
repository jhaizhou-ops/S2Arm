#!/usr/bin/env python3
"""Linux host 实际 VM 测试；不下载工具，不安装 signal dispatcher，不替代 Android 验收。"""
import argparse
import os
from pathlib import Path
import platform
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    args = parser.parse_args()
    if platform.system() != "Linux":
        parser.error("需要原生 Linux；macOS amd64 翻译器不支持本测试的 mremap(old_size=0)")
    kernel_page = os.sysconf("SC_PAGESIZE")
    models = [page for page in (4096, 16384) if page >= kernel_page and page % kernel_page == 0]
    if not models:
        parser.error(f"宿主内核页 {kernel_page} 字节不支持本测试的 4K / 16K 模型")
    for page in (4096, 16384):
        if page not in models:
            print(f"SKIP {page}-byte model: kernel page is {kernel_page} bytes", flush=True)
    root = Path(__file__).resolve().parents[5]
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    flags = ["-D_GNU_SOURCE", "-std=gnu11", "-O2", "-g", "-Wall", "-Wextra", "-pthread", "-Iruntime/include"]
    track = out / "track.o"
    binary = out / "tracking-test"
    registry_binary = out / "registry-test"
    failure_binary = out / "failure-test"
    module_binary = out / "module-precise-test"
    estale_binary = out / "mirror-estale-test"
    switch_binary = out / "mirror-switch-test"
    off_path_binary = out / "mirror-off-path-test"
    failure_track = out / "track-failure.o"
    estale_track = out / "track-estale.o"
    sources = ["android/native/runtime/tracking/tests/tracking_test.c",
               "android/native/runtime/tracking/platform.c",
               "android/native/runtime/tracking/runtime.c",
               "android/native/runtime/tracking/registry.c",
               "android/native/plat_android.c", "android/native/memory.c",
               "android/native/guest_signal.c", "android/native/tsd.c",
               "runtime/src/layout.c"]   # s2a_app_pool（plat_android.c 经 layout_android.inc 读；5cc359021 只补了两处 CMake，这里漏了）
    commands = [[args.cc, *flags, "-Dgetpagesize=s2a_track_test_pagesize", "-c", "graphics/track/track.c", "-o", str(track)],
                [args.cc, *flags, *sources, str(track), "-Wl,--wrap=open", "-ldl", "-o", str(binary)],
                *[[str(binary), str(page)] for page in models],
                [args.cc, *flags, "android/native/runtime/tracking/tests/registry_test.c", *sources[1:], str(track), "-ldl", "-o", str(registry_binary)],
                [str(registry_binary)],
                [args.cc, *flags, "-Igraphics/track", "-Iandroid/native", "-Iandroid/native/runtime/tracking",
                 "android/native/runtime/tracking/tests/module_precise_test.c", "android/native/module.c",
                 "android/native/runtime/tracking/readonly_copy.c", "android/native/runtime/vm/backing.c",
                 *sources[1:], str(track), "-ldl", "-o", str(module_binary)],
                [str(module_binary)],
                [args.cc, *flags, "-DS2A_TRACK_TEST", "-c", "graphics/track/track.c", "-o", str(failure_track)],
                [args.cc, *flags, "android/native/runtime/tracking/tests/failure_test.c", *sources[1:], str(failure_track), "-ldl", "-o", str(failure_binary)],
                [str(failure_binary)],
                [args.cc, *flags, "-DS2A_TRACK_TEST", "-Dgetpagesize=s2a_track_test_pagesize", "-c", "graphics/track/track.c", "-o", str(estale_track)],
                [args.cc, *flags, "-DS2A_UNIT_TEST", "android/native/runtime/tracking/tests/mirror_estale_test.c", *sources[1:], str(estale_track), "-ldl", "-o", str(estale_binary)],
                [args.cc, *flags, "-DS2A_UNIT_TEST", "android/native/runtime/tracking/tests/mirror_switch_test.c", *sources[1:], str(track), "-ldl", "-o", str(switch_binary)],
                *[[str(switch_binary), str(page), mode] for page in (4096, 16384) for mode in ("off", "on")],
                [args.cc, *flags, "-DS2A_UNIT_TEST", "android/native/runtime/tracking/tests/mirror_off_path_test.c", *sources[1:], str(estale_track), "-ldl", "-o", str(off_path_binary)],
                [str(off_path_binary), "4096"],
                [str(off_path_binary), "16384"],
                [str(estale_binary), "churn", "50", "4096"],
                [str(estale_binary), "churn", "0", "4096"],
                [str(estale_binary), "swap", "in", "4096"],
                [str(estale_binary), "swap", "in", "16384"],
                [str(estale_binary), "swap", "unmap", "4096"],
                [str(estale_binary), "swap", "unmap", "16384"],
                [str(estale_binary), "d2", "0", "4096"],
                [str(estale_binary), "precise", "20", "16384"],
                [str(estale_binary), "writer-timeout", "0", "4096"]]
    for command in commands:
        print("+", " ".join(command), flush=True)
        subprocess.run(command, cwd=root, check=True, timeout=90)


if __name__ == "__main__":
    main()
